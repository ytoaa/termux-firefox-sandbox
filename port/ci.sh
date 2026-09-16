#!/usr/bin/env bash
set -euo pipefail

: "${TERMUX_BUILDER_IMAGE_NAME:=termux-firefox-builder:sccache}"
export TERMUX_BUILDER_IMAGE_NAME

usage() {
  cat <<'EOF'
Usage:
  ci.sh prepare-zram-workspace <termux-packages-dir>
  ci.sh prepare-builder <termux-packages-dir>
  ci.sh build <termux-packages-dir>
  ci.sh verify-binary <termux-packages-dir>
  ci.sh stats <termux-packages-dir>
  ci.sh diagnostics <termux-packages-dir>
  ci.sh check-upstream --build-sh <fetched-build.sh> --port-toml <port.toml> [--force true|false]
  ci.sh collect <termux-packages-dir> <portrepo-dir> <metadata.json> <recipe.diff> <artifacts-dir>
EOF
}

need_termux_dir() {
  local d="$1"
  d="$(realpath "$d")"
  test -x "$d/scripts/run-docker.sh"
  test -x "$d/build-package.sh"
  printf '%s\n' "$d"
}

run_docker() {
  local d="$1"; shift
  (
    cd "$d"
    ./scripts/run-docker.sh "$@"
  )
}

prepare_zram_workspace() {
  local d workspace action key
  d="$(realpath "$1")"
  workspace="${GITHUB_WORKSPACE:-}"
  if [ -z "$workspace" ]; then
    echo "ERROR: GITHUB_WORKSPACE is not set" >&2
    return 2
  fi
  workspace="$(realpath "$workspace")"
  action="$d/.github/actions/zram/action.yml"
  key="$d/scripts/linux-kernel-signing-keys.gpg"

  test -f "$action"
  test -f "$key"

  # termux-packages' local zram action currently assumes that termux-packages
  # itself was checked out at github.workspace.  Our workflow deliberately
  # keeps it in a subdirectory, so expose only the two workspace-root inputs
  # that the upstream action references.  The generated zram module/cache also
  # lives under workspace/scripts and therefore needs no extra bridge.
  mkdir -p "$workspace/scripts" "$workspace/.github/actions/zram"
  cp -f "$key" "$workspace/scripts/linux-kernel-signing-keys.gpg"
  cp -f "$action" "$workspace/.github/actions/zram/action.yml"

  # Fail closed if the known upstream contract disappears.  That indicates
  # the composite action changed and this tiny compatibility bridge should be
  # reviewed instead of silently guessing at new paths.
  grep -Fq '${{ github.workspace }}/scripts/linux-kernel-signing-keys.gpg' "$action"
  grep -Fq "path: scripts/zram.ko.zst" "$action"

  echo "Prepared Termux zram workspace bridge:"
  ls -l "$workspace/scripts/linux-kernel-signing-keys.gpg" \
        "$workspace/.github/actions/zram/action.yml"
}

prepare_builder() {
  local d cache base pulled attempt
  d="$(need_termux_dir "$1")"
  cache="$d/.sccache"
  base="ghcr.io/termux/package-builder:latest"

  mkdir -p "$cache"
  sudo chown -R "$(id -u):$(id -g)" "$cache"
  chmod -R a+rwX "$cache"

  pulled=0
  for attempt in 1 2 3 4 5; do
    if docker pull "$base"; then
      pulled=1
      break
    fi
    if [ "$attempt" -lt 5 ]; then
      sleep $((attempt * 15))
    fi
  done
  if [ "$pulled" -ne 1 ]; then
    docker build -t "$base" "$d/scripts/"
    docker buildx prune -af || true
  fi

  cat > /tmp/Dockerfile.firefox-sccache <<'DOCKERFILE'
FROM ghcr.io/termux/package-builder:latest
USER root
RUN apt-get update \
    && apt-get install -yq --no-install-recommends sccache \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
USER builder:builder
WORKDIR /home/builder/termux-packages
DOCKERFILE

  docker build \
    -f /tmp/Dockerfile.firefox-sccache \
    -t "$TERMUX_BUILDER_IMAGE_NAME" \
    "$d"

  docker rm -f termux-package-builder 2>/dev/null || true
  export TERMUX_DOCKER_RUN_EXTRA_ARGS="--volume ${cache}:/home/builder/.cache/sccache"
  run_docker "$d" true

  run_docker "$d" bash -lc '
    set -euxo pipefail
    export SCCACHE_DIR=/home/builder/.cache/sccache
    export SCCACHE_CACHE_SIZE=6G
    command -v sccache
    sccache --version
    echo test > "$SCCACHE_DIR/.write-test"
    rm "$SCCACHE_DIR/.write-test"
  '

  # Ubuntu runner compatibility workaround retained from the proven workflow.
  sed -i '/ruby3\.2-doc/d' "$d/scripts/free-space.sh"
  ! grep -q 'ruby3.2-doc' "$d/scripts/free-space.sh"

  df -h
  (cd "$d" && ./scripts/free-space.sh)
  df -h

  run_docker "$d" env \
    SCCACHE_DIR=/home/builder/.cache/sccache \
    SCCACHE_CACHE_SIZE=6G \
    sccache --zero-stats
}

build_firefox() {
  local d
  d="$(need_termux_dir "$1")"
  (
    cd "$d"
    set -o pipefail
    echo "======================================"
    echo "Firefox native sandbox port ${PORT_VERSION:-unknown}"
    echo "Firefox: ${FIREFOX_VERSION:-unknown} candidate=${FIREFOX_CANDIDATE:-unknown}"
    echo "======================================"
    ./scripts/run-docker.sh env \
      SCCACHE_DIR=/home/builder/.cache/sccache \
      SCCACHE_CACHE_SIZE=6G \
      ./build-package.sh -f -I -a aarch64 firefox \
      2>&1 | tee firefox-build.log
  )
}

verify_binary() (
  local d cfg deb tmp libxul report
  d="$(need_termux_dir "$1")"
  cfg="$d/x11-packages/firefox/termux-native-sandbox-port.toml"
  report="$d/firefox-native-sandbox-binary-gate.json"

  test -f "$cfg"
  deb="$(find "$d/output" -type f -name 'firefox_*.deb' -print -quit)"
  if [ -z "$deb" ]; then
    echo "ERROR: Firefox deb not found for binary gate" >&2
    return 2
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  dpkg-deb -x "$deb" "$tmp"
  mapfile -t libxuls < <(find "$tmp" -type f -path '*/lib/firefox/libxul.so' -print)
  if [ "${#libxuls[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one libxul.so, found ${#libxuls[@]}" >&2
    printf '%s\n' "${libxuls[@]}" >&2
    return 2
  fi
  libxul="${libxuls[0]}"

  # Extract required_binary_strings from our own port.toml without any host
  # python3 dependency: the runner environment after the zram/builder steps
  # has lost python3 on PATH (run #24: "python3: command not found" -> empty
  # array -> fail-closed exit).  The layout of this file is fixed by
  # "Validate port tools", so sed extraction is deterministic here.
  mapfile -t required < <(
    sed -n '/^required_binary_strings = \[/,/^\]/p' "$cfg" \
      | sed -e '/required_binary_strings = \[/d' -e '/^\]/d' \
            -e 's/^[[:space:]]*"//' -e 's/",\{0,1\}[[:space:]]*$//'
  )
  if [ "${#required[@]}" -eq 0 ]; then
    echo "ERROR: audioipc.required_binary_strings is empty" >&2
    return 2
  fi

  status=0
  json_items=()
  echo "======================================"
  echo "AudioIPC binary contract"
  echo "======================================"
  echo "deb    : $deb"
  echo "libxul : $libxul"
  for needle in "${required[@]}"; do
    if grep -aFq -- "$needle" "$libxul"; then
      printf 'PRESENT  %s\n' "$needle"
      json_items+=("$needle=present")
    else
      printf 'ABSENT   %s\n' "$needle" >&2
      json_items+=("$needle=absent")
      status=1
    fi
  done

  # Write the gate report with printf (no host python3 needed).  Marker
  # strings are plain ASCII without quotes or backslashes by the Validate
  # port tools contract; reject anything else rather than emit broken JSON.
  for item in "${json_items[@]}"; do
    key="${item%=*}"
    case "$key" in
      *'"'*|*'\'*)
        echo "ERROR: marker string contains JSON-unsafe character: $key" >&2
        return 2 ;;
    esac
  done
  {
    printf '{\n'
    printf '  "deb": "%s",\n' "$(basename "$deb")"
    printf '  "audioipc_binary_contract": "%s",\n' "$([ "$status" -eq 0 ] && echo pass || echo fail)"
    printf '  "checks": {\n'
    for i in "${!json_items[@]}"; do
      key="${json_items[i]%=*}"
      val="${json_items[i]#*=}"
      sep=,
      [ "$i" -eq $(( ${#json_items[@]} - 1 )) ] && sep=
      printf '    "%s": "%s"%s\n' "$key" "$val" "$sep"
    done
    printf '  }\n}\n'
  } > "$report"

  if [ "$status" -ne 0 ]; then
    echo "ERROR: AudioIPC was compiled out of libxul.so" >&2
    return 2
  fi
)

show_stats() {
  local d
  d="$(need_termux_dir "$1")"
  run_docker "$d" env \
    SCCACHE_DIR=/home/builder/.cache/sccache \
    SCCACHE_CACHE_SIZE=6G \
    sccache --show-stats || true
}

diagnostics() {
  local d
  d="$(need_termux_dir "$1")"
  set +e

  run_docker "$d" bash -lc '
    TMP=/home/builder/.termux-build/firefox/tmp
    OUT=/home/builder/termux-packages
    for f in \
      firefox-native-sandbox-port-report.json \
      firefox-native-sandbox.generated.patch; do
      if [ -f "$TMP/$f" ]; then
        cp -v "$TMP/$f" "$OUT/$f"
      fi
    done
  ' 2>/dev/null || true

  echo "======================================"
  echo "Semantic port report"
  echo "======================================"
  cat "$d/firefox-native-sandbox-port-report.json" 2>/dev/null || true

  echo
  echo "======================================"
  echo "AudioIPC binary gate"
  echo "======================================"
  cat "$d/firefox-native-sandbox-binary-gate.json" 2>/dev/null || true

  echo
  echo "======================================"
  echo "Generated source patch"
  echo "======================================"
  cat "$d/firefox-native-sandbox.generated.patch" 2>/dev/null || true

  echo
  echo "======================================"
  echo "Final structural verification"
  echo "======================================"
  run_docker "$d" bash -lc '
    SRC=/home/builder/.termux-build/firefox/src
    TOOL=/home/builder/termux-packages/x11-packages/firefox/termux-native-sandbox-port.py
    if [ -f "$SRC/security/sandbox/linux/SandboxFilter.cpp" ]; then
      python3 "$TOOL" verify \
        --src "$SRC" \
        --prefix /data/data/com.termux/files/usr
    fi
  ' 2>&1 || true

  echo
  echo "======================================"
  echo "Patch rejects"
  echo "======================================"
  run_docker "$d" bash -lc '
    find /home/builder/.termux-build/firefox -type f -name "*.rej" -print
  ' 2>/dev/null || true

  echo
  echo "======================================"
  echo "Focused build diagnostics"
  echo "======================================"
  grep -nEi \
    'PORT ERROR|RECIPE ERROR|semantic port|VERIFY SUCCESS|sandbox|seccomp|PR_PAC|PR_GET_DUMPABLE|RLIMIT_STACK|getrlimit|fstatfs|MREMAP_FIXED|AddTermuxRuntimeReadPaths|kX11SocketPrefix|MOZ_CUBEB_REMOTING|AudioIPC|audioipc|cubeb|libpulse|libavcodec|FFmpeg|PDM|Utility|undefined symbol|duplicate symbol|ld\.lld: error|Hunk.*FAILED|reject' \
    "$d/firefox-build.log" 2>/dev/null | tail -n 1200 || true

  find "$d/output" -type f -name 'firefox_*.deb' -print 2>/dev/null || true
  tail -n 900 "$d/firefox-build.log" 2>/dev/null || true
  set -e
}

check_upstream() {
  local build_sh="" toml="" force="false" version validated should reason
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --build-sh) build_sh="${2:?--build-sh requires a value}"; shift 2 ;;
      --port-toml) toml="${2:?--port-toml requires a value}"; shift 2 ;;
      --force) force="${2:-false}"; shift 2 ;;
      *) echo "ERROR: unknown check-upstream argument: $1" >&2; return 2 ;;
    esac
  done
  test -f "$build_sh" || { echo "ERROR: upstream build.sh not fetched: $build_sh" >&2; return 2; }
  test -f "$toml" || { echo "ERROR: port.toml not found: $toml" >&2; return 2; }

  version="$(sed -n 's/^TERMUX_PKG_VERSION="\{0,1\}\([^"#[:space:]]*\)"\{0,1\}.*$/\1/p' "$build_sh" | head -n1)"
  if [ -z "$version" ]; then
    echo "ERROR: TERMUX_PKG_VERSION could not be parsed from upstream build.sh (recipe shape changed?)" >&2
    return 2
  fi
  validated="$(sed -n 's/^last_validated_firefox = "\{0,1\}\([^"#[:space:]]*\)"\{0,1\}.*$/\1/p' "$toml" | head -n1)"
  if [ -z "$validated" ]; then
    echo "ERROR: last_validated_firefox missing from port.toml" >&2
    return 2
  fi

  should="false"
  reason="version-matches-last-validated"
  if [ "$version" != "$validated" ]; then
    should="true"
    reason="upstream-version-moved:${validated}->${version}"
  fi
  if [ "$force" = "true" ]; then
    should="true"
    reason="${reason}+forced"
  fi

  echo "upstream firefox=$version last_validated=$validated should_build=$should ($reason)"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "should_build=$should"
      echo "firefox_version=$version"
    } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Termux Firefox upstream check"
      echo ""
      echo "- upstream \`TERMUX_PKG_VERSION\`: \`$version\`"
      echo "- \`last_validated_firefox\`: \`$validated\`"
      echo "- build decision: **$should** ($reason)"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

collect() {
  local d portrepo metadata recipe_diff out deb
  d="$(need_termux_dir "$1")"
  portrepo="$(realpath "$2")"
  metadata="$(realpath "$3")"
  recipe_diff="$(realpath "$4")"
  out="$5"
  mkdir -p "$out"
  out="$(realpath "$out")"

  find "$d/output" -type f -name 'firefox_*.deb' \
    -print -exec cp -v '{}' "$out/" ';'

  cp "$metadata" "$out/"
  cp "$recipe_diff" "$out/"
  cp "$portrepo/port/port.toml" "$out/"
  cp "$portrepo/port/firefox_sandbox_port.py" "$out/"
  cp "$portrepo/port/prepare_recipe.py" "$out/"
  install -m 0755 "$portrepo/port/ci.sh" "$out/ci.sh"
  install -m 0755 "$portrepo/port/runtime-test.sh" "$out/termux-firefox-native-sandbox-test.sh"
  cp "$portrepo/port/media-capabilities.html" "$out/"
  cp "$portrepo/port/DESIGN.md" "$out/"
  cp "$portrepo/port/REGRESSION.md" "$out/"

  [ -f "$d/firefox-native-sandbox-port-report.json" ] \
    && cp "$d/firefox-native-sandbox-port-report.json" "$out/"
  [ -f "$d/firefox-native-sandbox-binary-gate.json" ] \
    && cp "$d/firefox-native-sandbox-binary-gate.json" "$out/"
  [ -f "$d/firefox-native-sandbox.generated.patch" ] \
    && cp "$d/firefox-native-sandbox.generated.patch" "$out/"

  deb="$(find "$out" -maxdepth 1 -type f -name 'firefox_*.deb' -print -quit)"
  test -n "$deb"
  (
    cd "$out"
    sha256sum firefox_*.deb > SHA256SUMS
  )
  ls -lh "$out/"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  prepare-zram-workspace) [ "$#" -eq 1 ] || { usage; exit 2; }; prepare_zram_workspace "$1" ;;
  prepare-builder) [ "$#" -eq 1 ] || { usage; exit 2; }; prepare_builder "$1" ;;
  build) [ "$#" -eq 1 ] || { usage; exit 2; }; build_firefox "$1" ;;
  verify-binary) [ "$#" -eq 1 ] || { usage; exit 2; }; verify_binary "$1" ;;
  stats) [ "$#" -eq 1 ] || { usage; exit 2; }; show_stats "$1" ;;
  diagnostics) [ "$#" -eq 1 ] || { usage; exit 2; }; diagnostics "$1" ;;
  check-upstream) [ "$#" -ge 2 ] || { usage; exit 2; }; check_upstream "$@" ;;
  collect) [ "$#" -eq 5 ] || { usage; exit 2; }; collect "$@" ;;
  *) usage; exit 2 ;;
esac
