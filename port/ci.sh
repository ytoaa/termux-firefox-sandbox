#!/usr/bin/env bash
set -euo pipefail

: "${TERMUX_BUILDER_IMAGE_NAME:=termux-firefox-builder:sccache}"
export TERMUX_BUILDER_IMAGE_NAME

usage() {
  cat <<'EOF'
Usage:
  ci.sh prepare-builder <termux-packages-dir>
  ci.sh build <termux-packages-dir>
  ci.sh stats <termux-packages-dir>
  ci.sh diagnostics <termux-packages-dir>
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
    'PORT ERROR|RECIPE ERROR|semantic port|VERIFY SUCCESS|sandbox|seccomp|PR_PAC|PR_GET_DUMPABLE|RLIMIT_STACK|getrlimit|fstatfs|MREMAP_FIXED|AddTermuxRuntimeReadPaths|libavcodec|FFmpeg|PDM|Utility|undefined symbol|duplicate symbol|ld\.lld: error|Hunk.*FAILED|reject' \
    "$d/firefox-build.log" 2>/dev/null | tail -n 1200 || true

  find "$d/output" -type f -name 'firefox_*.deb' -print 2>/dev/null || true
  tail -n 900 "$d/firefox-build.log" 2>/dev/null || true
  set -e
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
  cp "$portrepo/port/ci.sh" "$out/"
  cp "$portrepo/port/runtime-test.sh" "$out/termux-firefox-native-sandbox-test.sh"
  cp "$portrepo/port/media-capabilities.html" "$out/"
  cp "$portrepo/port/DESIGN.md" "$out/"
  cp "$portrepo/port/REGRESSION.md" "$out/"

  [ -f "$d/firefox-native-sandbox-port-report.json" ] \
    && cp "$d/firefox-native-sandbox-port-report.json" "$out/"
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
  prepare-builder) [ "$#" -eq 1 ] || { usage; exit 2; }; prepare_builder "$1" ;;
  build) [ "$#" -eq 1 ] || { usage; exit 2; }; build_firefox "$1" ;;
  stats) [ "$#" -eq 1 ] || { usage; exit 2; }; show_stats "$1" ;;
  diagnostics) [ "$#" -eq 1 ] || { usage; exit 2; }; diagnostics "$1" ;;
  collect) [ "$#" -eq 5 ] || { usage; exit 2; }; collect "$@" ;;
  *) usage; exit 2 ;;
esac
