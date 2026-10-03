#!/usr/bin/env bash
# Fixture-driven test harness for port/auto_merge_upstream.sh (FIX-7 seed).
#
# Runs the gate against a stubbed `gh` (PATH shim) so every fail-closed check
# is exercised WITHOUT touching GitHub.  The review panel required this
# harness to ship WITH the gate change (dogfooding: the merge-authority
# script gets tested in the same commit that changes it).
#
# Usage:  bash port/tests/run_tests.sh
# Exit:   0 = all scenarios pass, 1 = any failure (details on stdout).
# Needs:  bash, jq, coreutils.
set -uo pipefail

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TESTDIR/../.." && pwd)"
GATE="$REPO_ROOT/port/auto_merge_upstream.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ff-gate-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; RST=""; }

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_MAIN=cccccccccccccccccccccccccccccccccccccc
BLOB_MAIN=1111111111111111111111111111111111111111
BLOB_HEAD=2222222222222222222222222222222222222222

mkdir -p "$WORK/bin" "$WORK/repo/port" "$WORK/fixtures"
cp "$GATE" "$WORK/gate_copy.sh"

b64_anchor() { printf 'termuxFirefoxVersion = "%s"\n' "$1" | base64 | tr -d '\n'; }

mk_blob() { # file version blobsha
  jq -nc --arg c "$(b64_anchor "$2")" --arg s "$3" '{sha:$s, content:$c}' > "$WORK/fixtures/$1"
}

# the stub gh ---------------------------------------------------------------
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
W="@@WORK@@"
CALLS="$W/calls.log"
fail_if() { [ "${FAIL_MODE:-}" = "$1" ] && { echo "stub: simulated failure ($1)" >&2; exit 1; }; }
printf '%s\n' "$*" >> "$CALLS"

if [ "${1:-}" = "pr" ]; then
  case "${2:-}" in
    list)   fail_if list_fail
            jqv=""
            all=("$@"); for ((i=0;i<${#all[@]};i++)); do [ "${all[$i]}" = "--jq" ] && jqv="${all[$((i+1))]}"; done
            if [ -n "$jqv" ]; then jq -r "$jqv" < "$W/fixtures/pr_list"; else cat "$W/fixtures/pr_list"; fi
            exit 0;;
    diff)   cat "$W/fixtures/diff"; exit 0;;
    view)   what="${5:-}"; jqv=""
            shift 5
            while [ $# -gt 0 ]; do case "$1" in --jq) jqv="${2:-}"; shift 2;; *) shift;; esac; done
            case "$what" in
              files) out=$(cat "$W/fixtures/files.json");;
              comments) out=$(cat "$W/fixtures/comments.json" 2>/dev/null || echo '{"comments":[]}');;
              *) out='{}';;
            esac
            if [ -n "$jqv" ]; then printf '%s' "$out" | jq -r "$jqv"; else printf '%s' "$out"; fi
            exit 0;;
    edit)   fail_if label_fail; exit 0;;
    comment) fail_if comment_fail; exit 0;;
    merge)  fail_if merge_fail; exit 0;;
  esac
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  path="${2:-}"; shift 2
  jqexpr=""; ref=""; method=""; has_fields=0
  while [ $# -gt 0 ]; do case "$1" in
    --jq) jqexpr="${2:-}"; shift 2;;
    -X|--method) method="${2:-}"; shift 2;;
    -f|-F|--field|--raw-field|-i|--input) has_fields=1
           case "${2:-}" in ref=*) ref="${2#ref=}";; esac; shift 2;;
    *) shift;;
  esac; done
  # Mimic real gh: passing fields flips the default method to POST
  # (this exact semantics shipped the 09-29 auto-merge 404 outage).
  [ -n "$method" ] || { [ "$has_fields" = 1 ] && method=POST || method=GET; }
  case "$path" in
    repos/*/commits*)
        # read-only list endpoint: POST has no route -> GitHub answers 404
        if [ "$method" = POST ]; then
          echo "gh: Not Found (HTTP 404)" >&2; exit 1
        fi ;;
    repos/*/contents/*)
        # read-only GET here; POST = create-file which our contents:read
        # token cannot do -> GitHub answers 403
        if [ "$method" = POST ]; then
          echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1
        fi ;;
  esac
  case "$path" in
    repos/*/pulls*)
        # post-evaluation re-read returns pr2.json (head-changed simulation)
        if [ -f "$W/.seen_first_read" ] && [ -f "$W/fixtures/pr2.json" ]; then
          out=$(cat "$W/fixtures/pr2.json")
        else
          out=$(cat "$W/fixtures/pr.json"); : > "$W/.seen_first_read"
        fi ;;
    repos/*/branches/main)
        out=$(cat "$W/fixtures/branch_main.json") ;;
    repos/*/contents/*)
        # before any merge call: main blob = OLD.  after merge call (unless
        # STUB_FORCE_STALE_MAIN): main blob reflects the landed head version.
        if [ "$ref" != "main" ] && [ -n "$ref" ]; then
          out=$(cat "$W/fixtures/blob_head.json")
        elif grep -q "pr merge" "$CALLS" 2>/dev/null && [ -z "${STUB_FORCE_STALE_MAIN:-}" ]; then
          out=$(cat "$W/fixtures/blob_head.json")
        else
          out=$(cat "$W/fixtures/blob_main.json")
        fi ;;
    *) out='{}' ;;
  esac
  if [ -n "$jqexpr" ]; then printf '%s' "$out" | jq -r "$jqexpr"; else printf '%s' "$out"; fi
  exit 0
fi
exit 0
STUB
sed -i "s|@@WORK@@|$WORK|" "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"

mk_pr_json() { # head_ref head_sha head_repo association
  jq -n --arg ref "$1" --arg sha "$2" --arg repo "$3" --arg assoc "$4" \
    '{head:{ref:$ref, sha:$sha, repo:{full_name:$repo}},
      base:{ref:"main", repo:{full_name:"ytoaa/termux-firefox-sandbox"}},
      author_association:$assoc}' -c > "$WORK/fixtures/pr.json"
}
mk_diff() { printf -- '--- a/port/upstream.renovate\n+++ b/port/upstream.renovate\n@@ -1 +1 @@\n-termuxFirefoxVersion = "156.0"\n+termuxFirefoxVersion = "%s"\n' "$1" > "$WORK/fixtures/diff"; }

reset_env() {
  rm -f "$WORK/calls.log" "$WORK/.seen_first_read" "$WORK/fixtures/pr2.json" \
        "$WORK/fixtures/comments.json" "$WORK/output"
  : > "$WORK/calls.log"
  printf 'termuxFirefoxVersion = "156.0"\n' > "$WORK/repo/port/upstream.renovate"
  printf 'TERMUX_PKG_VERSION="156.0.1"\n' > "$WORK/fixtures/live_build.sh"
  mk_blob blob_main.json 156.0 "$BLOB_MAIN"
  mk_blob blob_head.json 156.0.1 "$BLOB_HEAD"
  jq -nc '[{number:7, headRefName:"renovate/termux-firefox-upstream-156"}]' > "$WORK/fixtures/pr_list"
  jq -nc '{files:[{path:"port/upstream.renovate"}]}' > "$WORK/fixtures/files.json"
  jq -nc --arg s "$SHA_MAIN" '{commit:{sha:$s}}' > "$WORK/fixtures/branch_main.json"
}

run_gate() {
  ( cd "$WORK/repo"
    env PATH="$WORK/bin:$PATH" \
        GITHUB_REPOSITORY="ytoaa/termux-firefox-sandbox" \
        GITHUB_RUN_ID=99 \
        LIVE_RECIPE="$WORK/fixtures/live_build.sh" \
        GITHUB_OUTPUT="$WORK/output" \
        TERMUX_PACKAGES_SHA=dddddddddddddddddddddddddddddddddddddddd \
        "$@" bash "$WORK/gate_copy.sh" >"$WORK/stdout" 2>&1 )
  echo $? > "$WORK/exit"
}

expect() { # desc, cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$GRN" "$RST" "$desc"
  else
    FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$RED" "$RST" "$desc"
    echo "    --- stdout(tail) ---"; tail -12 "$WORK/stdout" | sed 's/^/    /'
    echo "    --- calls ---"; tail -6 "$WORK/calls.log" | sed 's/^/    /'
  fi
}
contains() { grep -q -- "$1" "$2"; }
absent() { ! grep -q -- "$1" "$2"; }
good_pr() { mk_pr_json "renovate/termux-firefox-upstream-156" "$SHA_A" "ytoaa/termux-firefox-sandbox" "OWNER"; }

echo "== FIX-1 gate harness =="

echo "[1] accept: same-repo OWNER, valid forward bump"
reset_env; good_pr; mk_diff 156.0.1; run_gate
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "merged=true output" contains "merged=true" "$WORK/output"
expect "merge pinned to head sha" contains "--match-head-commit $SHA_A" "$WORK/calls.log"
expect "audit tuple: head_sha" contains "head_sha=$SHA_A" "$WORK/calls.log"
expect "audit tuple: termux-packages pin" contains "termux-packages=dddddddddddddddddddddddddddddddddddddddd" "$WORK/calls.log"
expect "accept comment posted after merge line" bash -c 'm=$(grep -n "pr merge" "'"$WORK"'/calls.log" | head -1 | cut -d: -f1); c=$(grep -n "AUTO-MERGE-ACCEPT" "'"$WORK"'/calls.log" | head -1 | cut -d: -f1); [ -n "$m" ] && [ -n "$c" ] && [ "$c" -gt "$m" ]'
expect "no reject comment" absent "AUTO-MERGE-REJECT" "$WORK/calls.log"

echo "[2] decline: cross-repo head (fork attack)"
reset_env; mk_pr_json "renovate/termux-firefox-upstream-156" "$SHA_A" "evil/fork-repo" "OWNER"; mk_diff 156.0.1; run_gate
expect "declined head-repo" contains "head-repo-not-same-repo:evil/fork-repo" "$WORK/stdout"
expect "label applied" contains "pr edit 7 --add-label needs-human" "$WORK/calls.log"
expect "reject comment posted" contains "AUTO-MERGE-REJECT" "$WORK/calls.log"
expect "no merge" absent "pr merge" "$WORK/calls.log"

echo "[3] decline: author_association CONTRIBUTOR"
reset_env; mk_pr_json "renovate/termux-firefox-upstream-156" "$SHA_A" "ytoaa/termux-firefox-sandbox" "CONTRIBUTOR"; mk_diff 156.0.1; run_gate
expect "declined association" contains "author-association-not-trusted:CONTRIBUTOR" "$WORK/stdout"
expect "no merge" absent "pr merge" "$WORK/calls.log"

echo "[4] decline: wrong branch pattern"
reset_env; mk_pr_json "evil/renovate-lookalike" "$SHA_A" "ytoaa/termux-firefox-sandbox" "OWNER"; mk_diff 156.0.1; run_gate
expect "declined branch pattern" contains "branch-not-renovate-pattern" "$WORK/stdout"

echo "[5] abort: head changed during evaluation (TOCTOU F-01)"
reset_env; good_pr; mk_diff 156.0.1
jq -nc --arg s "$SHA_B" '{head:{ref:"renovate/termux-firefox-upstream-156", sha:$s, repo:{full_name:"ytoaa/termux-firefox-sandbox"}}, base:{ref:"main", repo:{full_name:"ytoaa/termux-firefox-sandbox"}}, author_association:"OWNER"}' > "$WORK/fixtures/pr2.json"
run_gate
expect "escalated head-changed" contains "head-changed-during-evaluation" "$WORK/stdout"
expect "no merge" absent "pr merge" "$WORK/calls.log"
expect "exit 0 despite abort" test "$(cat "$WORK/exit")" = 0

echo "[6] skip: anchor blob already landed (no-op refusal, F-13)"
reset_env; good_pr; mk_blob blob_head.json 156.0 "$BLOB_MAIN"; mk_diff 156.0.1; run_gate
expect "skipped already-landed" contains "already landed on main" "$WORK/stdout"
expect "no merge" absent "pr merge" "$WORK/calls.log"
expect "no escalation spam" absent "AUTO-MERGE-REJECT" "$WORK/calls.log"

echo "[7] decline: downgrade"
reset_env; good_pr; printf 'TERMUX_PKG_VERSION="155.0.2"\n' > "$WORK/fixtures/live_build.sh"
mk_blob blob_head.json 155.0.2 3333333333333333333333333333333333333333; mk_diff 155.0.2; run_gate
expect "declined not-forward" contains "not-a-forward-bump" "$WORK/stdout"

echo "[8] decline: N.1 invariant"
reset_env; good_pr; printf 'TERMUX_PKG_VERSION="157.1.0"\n' > "$WORK/fixtures/live_build.sh"
mk_blob blob_head.json 157.1.0 4444444444444444444444444444444444444444; mk_diff 157.1.0; run_gate
expect "declined invariant" contains "invariant-N.1-collision" "$WORK/stdout"

echo "[9] decline: proposed != live"
reset_env; good_pr; mk_blob blob_head.json 156.0.2 5555555555555555555555555555555555555555; mk_diff 156.0.2; run_gate
expect "declined differs-from-live" contains "differs-from-live" "$WORK/stdout"

echo "[10] decline: multi-bump diff shape"
reset_env; good_pr
printf -- '--- a/port/upstream.renovate\n+++ b/port/upstream.renovate\n@@\n-termuxFirefoxVersion = "156.0"\n+termuxFirefoxVersion = "156.0.1"\n+termuxFirefoxVersion = "999.0"\n' > "$WORK/fixtures/diff"
run_gate
expect "declined diff-shape" contains "diff-shape-not-single-bump:+2/-1" "$WORK/stdout"

echo "[11] fail-closed: needs-human label write fails => exit 4 (F-06)"
reset_env; mk_pr_json "evil/branch" "$SHA_A" "ytoaa/termux-firefox-sandbox" "OWNER"; mk_diff 156.0.1
run_gate FAIL_MODE=label_fail
expect "exit 4" test "$(cat "$WORK/exit")" = 4
expect "escalation-write-failed logged" contains "escalation writes failed" "$WORK/stdout"

echo "[12] fail-closed: listing failure => exit 3, no false 'no candidates' (F-10)"
reset_env; run_gate FAIL_MODE=list_fail
expect "exit 3" test "$(cat "$WORK/exit")" = 3
expect "refused-empty-report logged" contains "refusing to report" "$WORK/stdout"

echo "[13] fail-closed: live recipe unparseable => exit 2"
reset_env; printf 'no version here\n' > "$WORK/fixtures/live_build.sh"; mk_diff 156.0.1; run_gate
expect "exit 2" test "$(cat "$WORK/exit")" = 2

echo "[14] dry-run performs no writes"
reset_env; good_pr; mk_diff 156.0.1; run_gate DRY_RUN=true
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "dry verdict logged" contains "dry-run: not merging" "$WORK/stdout"
expect "zero gh writes (calls.log empty apart from reads)" bash -c '! grep -qE "pr (merge|edit|comment)" "'"$WORK"'/calls.log"'

echo "[15] merge command failure => no false MERGED"
reset_env; good_pr; mk_diff 156.0.1; run_gate FAIL_MODE=merge_fail
expect "merged=false output" contains "merged=false" "$WORK/output"
expect "escalated merge-failed" contains "merge-command-failed" "$WORK/stdout"

echo "[16] post-merge verify catches anchor mismatch => merged stays false"
reset_env; good_pr; mk_diff 156.0.1; run_gate STUB_FORCE_STALE_MAIN=1
expect "verify failure logged" contains "post-merge verify FAILED" "$WORK/stdout"
expect "merged=false output" contains "merged=false" "$WORK/output"

echo "[17] syntax check (bash -n) on the merge-authority script"
if bash -n "$GATE"; then PASS=$((PASS+1)); printf '  %sPASS%s bash -n clean\n' "$GRN" "$RST";
else FAIL=$((FAIL+1)); printf '  %sFAIL%s bash -n\n' "$RED" "$RST"; fi

# ===========================================================================
# make_release.sh — release reconciliation harness (FIX-3)
# Second stub gh (binrel) simulating: GET /releases/tags (404 when no state
# file), gh release create, gh release upload [--clobber], digest read-back.
# ===========================================================================
MAKE_REL="$REPO_ROOT/port/make_release.sh"
mkdir -p "$WORK/binrel"
cat > "$WORK/binrel/gh" <<'RSTUB'
#!/usr/bin/env bash
W="@@WORK@@"
CALLS="$W/calls.log"
STATE="$W/rel_state.json"
printf 'rel:%s\n' "$*" >> "$CALLS"
[ "${FAIL_MODE:-}" = "upload_fail" ] && [ "${1:-}" = "release" ] && [ "${2:-}" = "upload" ] && { echo "stub: upload failed" >&2; exit 1; }
if [ "${1:-}" = "api" ]; then
  path="${2:-}"; shift 2; jqexpr=""
  while [ $# -gt 0 ]; do case "$1" in --jq) jqexpr="${2:-}"; shift 2;; *) shift;; esac; done
  case "$path" in
    repos/*/releases/tags/*)
      [ -f "$STATE" ] || exit 1   # GitHub 404 emulation
      if [ -n "$jqexpr" ]; then jq -r "$jqexpr" < "$STATE"; else cat "$STATE"; fi
      exit 0;;
    *) exit 0;;
  esac
fi
if [ "${1:-}" = "release" ]; then
  case "${2:-}" in
    create)
      # write a state with no assets (release exists but empty)
      jq -nc '{assets:[]}' > "$STATE"; exit 0;;
    upload)
      tag="$3"; deb="$4"; clobber="${5:-}"
      if [ "${FAIL_MODE:-}" = "readback_corrupt" ]; then
        jq -nc --arg n "$(basename "$deb")" --arg d "sha256:deadbeef" --argjson s 1 '{assets:[{name:$n,size:$s,digest:$d}]}' > "$STATE"
      else
        sz=$(stat -c%s "$deb"); dg="sha256:$(sha256sum "$deb" | cut -d' ' -f1)"
        jq -nc --arg n "$(basename "$deb")" --argjson s "$sz" --arg d "$dg" '{assets:[{name:$n,size:$s,digest:$d}]}' > "$STATE"
      fi
      exit 0;;
  esac
  exit 0
fi
exit 0
RSTUB
sed -i "s|@@WORK@@|$WORK|" "$WORK/binrel/gh"
chmod +x "$WORK/binrel/gh"

REL_DEB="firefox_9.9.9-1.9.9.9_aarch64.deb"
mk_pkg() { # rebuild a fresh artifacts dir with valid SHA256SUMS (fresh state)
  rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg"; rm -f "$WORK/rel_state.json"
  head -c 2048 /dev/urandom > "$WORK/pkg/$REL_DEB"
  ( cd "$WORK/pkg" && sha256sum "$REL_DEB" > SHA256SUMS )
}
run_rel() { # extra env passed as VAR=val args; state persists for pre-seeded scenarios
  rm -f "$WORK/calls.log"
  PATH="$WORK/binrel:$PATH" REPO="ytoaa/termux-firefox-sandbox" GIT_SHA=eeeeeeee \
    env "$@" bash "$MAKE_REL" "$WORK/pkg" 9.9.9 156.0.1 dddddddd > "$WORK/stdout" 2>&1
  echo $? > "$WORK/exit"
}

echo "[18] release: create path when tag missing"
mk_pkg; run_rel
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "release created" contains "rel:release create v9.9.9" "$WORK/calls.log"
expect "deb uploaded" contains "rel:release upload v9.9.9" "$WORK/calls.log"
exp_dg="sha256:$(sha256sum "$WORK/pkg/$REL_DEB" | cut -d' ' -f1)"
expect "read-back digest equals local" jq -e --arg d "$exp_dg" '.assets[0].digest == $d' "$WORK/rel_state.json"

echo "[19] release: idempotent — identical asset already published, zero writes"
mk_pkg
dg="sha256:$(sha256sum "$WORK/pkg/$REL_DEB" | cut -d' ' -f1)"
sz=$(stat -c%s "$WORK/pkg/$REL_DEB")
jq -nc --arg n "$REL_DEB" --argjson s "$sz" --arg d "$dg" '{assets:[{name:$n,size:$s,digest:$d}]}' > "$WORK/rel_state.json"
run_rel
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "no create" absent "rel:release create" "$WORK/calls.log"
expect "no upload" absent "rel:release upload" "$WORK/calls.log"
expect "no-edit message logged" contains "identical digest" "$WORK/stdout"

echo "[20] release: differing digest -> clobber replace"
mk_pkg
jq -nc --arg n "$REL_DEB" '{assets:[{name:$n,size:99,digest:"sha256:old"}]}' > "$WORK/rel_state.json"
run_rel
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "clobbered" contains "rel:release upload v9.9.9" "$WORK/calls.log"
expect "clobber branch logged" contains "replacing with clobber" "$WORK/stdout"
expect "no release create on existing tag" absent "rel:release create" "$WORK/calls.log"

echo "[21] release: tampered deb (digest mismatch vs SHA256SUMS) -> fail closed"
mk_pkg; printf 'TAMPER' >> "$WORK/pkg/$REL_DEB"
run_rel
expect "exit 1" test "$(cat "$WORK/exit")" = 1
expect "no writes before verification" absent "rel:release" "$WORK/calls.log"

echo "[22] release: deb missing in artifacts -> fail closed"
rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg"; : > "$WORK/pkg/SHA256SUMS"; rm -f "$WORK/rel_state.json"
run_rel
expect "exit 1" test "$(cat "$WORK/exit")" = 1

echo "[23] release: DRY_RUN on missing release performs zero writes"
mk_pkg; run_rel DRY_RUN=true
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "no create/write" absent "rel:release create" "$WORK/calls.log"

echo "[24] release: read-back corruption -> fail closed after upload"
mk_pkg; run_rel FAIL_MODE=readback_corrupt
expect "exit 1" test "$(cat "$WORK/exit")" = 1
expect "mismatch logged" contains "read-back MISMATCH" "$WORK/stdout"

echo "[25] release: upload command failure -> fail closed"
mk_pkg; run_rel FAIL_MODE=upload_fail
expect "exit 1" test "$(cat "$WORK/exit")" = 1

echo "[26] syntax check (bash -n) on make_release.sh"
if bash -n "$MAKE_REL"; then PASS=$((PASS+1)); printf '  %sPASS%s bash -n clean\n' "$GRN" "$RST";
else FAIL=$((FAIL+1)); printf '  %sFAIL%s bash -n\n' "$RED" "$RST"; fi

# ===========================================================================
# publish_apt.sh — apt channel index + publish harness (FIX-4)
# Uses dpkg-deb --build to fabricate real debs and a local bare repo as the
# publish origin — no network, no GitHub.
# ===========================================================================
PUB="$REPO_ROOT/port/publish_apt.sh"

mk_fake_deb() { # path package version
  local p="$1" pkg="$2" ver="$3" d="$WORK/fakebuild"
  rm -rf "$d"; mkdir -p "$d/DEBIAN"
  {
    echo "Package: $pkg"
    echo "Version: $ver"
    echo "Architecture: aarch64"
    echo "Maintainer: test <t@example.invalid>"
    echo "Description: fake test package"
    echo "Priority: optional"
  } > "$d/DEBIAN/control"
  mkdir -p "$d/usr/share/doc/$pkg"; echo x > "$d/usr/share/doc/$pkg/README"
  chmod 755 "$d" "$d/DEBIAN"
  dpkg-deb --build --root-owner-group -Zgzip "$d" "$p" >/dev/null
}

echo "[27] apt index: fields + Release digests"
rm -rf "$WORK/aptrepo"
mk_fake_deb "$WORK/firefox_9.9.9-1.9.9.9_aarch64.deb" firefox 9.9.9-1.9.9.9
bash "$PUB" index "$WORK/firefox_9.9.9-1.9.9.9_aarch64.deb" "$WORK/aptrepo" stable aarch64 > "$WORK/stdout" 2>&1
expect "index exit 0" test "$?" = 0
PKGS="$WORK/aptrepo/dists/stable/main/binary-aarch64/Packages"
POOLDEB="$WORK/aptrepo/pool/main/f/firefox/firefox_9.9.9-1.9.9.9_aarch64.deb"
want=$(sha256sum "$POOLDEB" | cut -d' ' -f1)
expect "Packages stanza present" grep -q "^Package: firefox$" "$PKGS"
expect "Filename points into pool" grep -q "^Filename: pool/main/f/firefox/firefox_9.9.9-1.9.9.9_aarch64.deb$" "$PKGS"
expect "SHA256 field equals file" grep -q "^SHA256: ${want}$" "$PKGS"
expect "Size field equals file" grep -q "^Size: $(stat -c%s "$POOLDEB")$" "$PKGS"
expect "Packages.gz decompresses equal" bash -c 'gzip -dc "$1" | cmp - "$2"' _ "${PKGS}.gz" "$PKGS"
rele=$(sha256sum "$PKGS" | cut -d' ' -f1)
expect "Release SHA256Sum matches Packages" grep -qE " ${rele} [0-9]+ main/binary-aarch64/Packages$" "$WORK/aptrepo/dists/stable/Release"
expect "Release declares arch" grep -q "^Architectures: aarch64$" "$WORK/aptrepo/dists/stable/Release"

echo "[28] apt index: second deb accumulates; re-index is deterministic"
mk_fake_deb "$WORK/firefox_9.10.0-1.9.9.9_aarch64.deb" firefox 9.10.0-1.9.9.9
bash "$PUB" index "$WORK/firefox_9.10.0-1.9.9.9_aarch64.deb" "$WORK/aptrepo" stable aarch64 > "$WORK/stdout" 2>&1
expect "index2 exit 0" test "$?" = 0
expect "both debs indexed" bash -c '[ "$(grep -c "^Package: firefox$" "$1")" = 2 ]' _ "$PKGS"
cp "$PKGS" "$WORK/packages.snapshot"
bash "$PUB" index "$WORK/firefox_9.10.0-1.9.9.9_aarch64.deb" "$WORK/aptrepo" stable aarch64 > /dev/null 2>&1
expect "re-index byte-identical (determinism)" cmp -s "$WORK/packages.snapshot" "$PKGS"

echo "[29] apt publish: orphan branch, accumulate, idempotent no-op"
git init -q --bare "$WORK/origin.git"
git init -q "$WORK/pushsrc-seed" && touch "$WORK/pushsrc-seed/README" \
  && git -C "$WORK/pushsrc-seed" -c user.name=t -c user.email=t@i add -A \
  && git -C "$WORK/pushsrc-seed" -c user.name=t -c user.email=t@i commit -qm init \
  && git -C "$WORK/pushsrc-seed" push -q "$WORK/origin.git" HEAD:refs/heads/main
git clone -q "$WORK/origin.git" "$WORK/pushsrc"
( cd "$WORK/pushsrc" && GIT_USER_NAME=t GIT_USER_EMAIL=t@i bash "$PUB" publish "$WORK/aptrepo" gh-pages "$WORK/origin.git" ) > "$WORK/stdout" 2>&1
expect "publish exit 0" test "$?" = 0
gp=$(git -C "$WORK/origin.git" rev-parse gh-pages 2>/dev/null)
expect "branch created" test -n "$gp"
expect "pushed branch has deb" git -C "$WORK/origin.git" cat-file -e "$gp:pool/main/f/firefox/firefox_9.10.0-1.9.9.9_aarch64.deb"
expect "pushed branch has Release" git -C "$WORK/origin.git" cat-file -e "$gp:dists/stable/Release"
( cd "$WORK/pushsrc" && GIT_USER_NAME=t GIT_USER_EMAIL=t@i bash "$PUB" publish "$WORK/aptrepo" gh-pages "$WORK/origin.git" ) > "$WORK/stdout2" 2>&1
expect "re-publish exit 0" test "$?" = 0
expect "no-op on identical tree" contains "nothing new" "$WORK/stdout2"

echo "[30] syntax check (bash -n) on publish_apt.sh"
if bash -n "$PUB"; then PASS=$((PASS+1)); printf '  %sPASS%s bash -n clean\n' "$GRN" "$RST";
else FAIL=$((FAIL+1)); printf '  %sFAIL%s bash -n\n' "$RED" "$RST"; fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
