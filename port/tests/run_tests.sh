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
SHA_MAIN=cccccccccccccccccccccccccccccccccccccccc  # exactly 40 hex (the old 38-char fixture was itself an unvalidated malformed read)
BLOB_MAIN=1111111111111111111111111111111111111111
BLOB_HEAD=2222222222222222222222222222222222222222

mkdir -p "$WORK/bin" "$WORK/repo/port" "$WORK/fixtures"
cp "$GATE" "$WORK/gate_copy.sh"

b64_anchor() { printf 'termuxFirefoxVersion = "%s"\n' "$1" | base64 | tr -d '\n'; }

mk_blob() { # file version blobsha
  jq -nc --arg c "$(b64_anchor "$2")" --arg s "$3" '{sha:$s, content:$c}' > "$WORK/fixtures/$1"
}

# the stub gh ---------------------------------------------------------------
# IMPORTANT: this stub MODELS REAL GH SEMANTICS, not the script's wishes.
# Real `gh pr list --json <fields>` hard-errors on unknown field names
# (live-verified: gh 2.102.0 "Unknown JSON field" on head.ref), so the stub
# validates every --json field against gh's documented vocabulary.  The
# previous stub accepted ANY field, which is exactly how the
# `--json head.ref` / `.head.ref` bug hid behind a green harness: the script
# and the stub were wrong together.
cat > "$WORK/bin/gh" <<'STUB' 
#!/usr/bin/env bash
W="@@WORK@@"
CALLS="$W/calls.log"
fail_if() { [ "${FAIL_MODE:-}" = "$1" ] && { echo "stub: simulated failure ($1)" >&2; exit 1; }; }
printf '%s\n' "$*" >> "$CALLS"
# one-shot flaky mode: fail the very FIRST gh call, succeed afterwards
# (models a transient API failure followed by a successful retry)
if [ "${FAIL_MODE:-}" = first_flaky ]; then
  printf x >> "$W/call_count"
  [ "$(wc -c < "$W/call_count" 2>/dev/null || echo 1)" = 1 ] && { echo "stub: transient first-call failure" >&2; exit 1; }
fi
valid_json_field() {
  # exact vocabulary of gh pr list --json, captured live from real gh 2.102.0
  # ('Unknown JSON field' error listing, 10-02) — not a hand-guess.
  case "$1" in
    additions|assignees|author|autoMergeRequest|baseRefName|baseRefOid|body|changedFiles|closed|closedAt|closingIssuesReferences|comments|commits|createdAt|deletions|files|fullDatabaseId|headRefName|headRefOid|headRepository|headRepositoryOwner|id|isCrossRepository|isDraft|labels|latestReviews|maintainerCanModify|mergeCommit|mergeStateStatus|mergeable|mergedAt|mergedBy|milestone|number|potentialMergeCommit|projectCards|projectItems|reactionGroups|reviewDecision|reviewRequests|reviews|state|statusCheckRollup|title|updatedAt|url) return 0;;
    *) return 1;;
  esac
}
check_json_fields() { # $1 = comma list from --json
  local f
  [ -n "$1" ] || return 0
  local IFS=,
  for f in $1; do
    valid_json_field "$f" || { echo "gh: Unknown JSON field: \"$f\" (see: gh pr list --help)" >&2; exit 1; }
  done
}

if [ "${1:-}" = "pr" ]; then
  case "${2:-}" in
    list)   fail_if list_fail
            jqv=""; jsonspec=""
            all=("$@"); for ((i=0;i<${#all[@]};i++)); do
              [ "${all[$i]}" = "--jq" ] && jqv="${all[$((i+1))]}"
              [ "${all[$i]}" = "--json" ] && jsonspec="${all[$((i+1))]}"
            done
            check_json_fields "$jsonspec"
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
        if [ -n "${STUB_BRANCH_SHA_EMPTY:-}" ]; then out='{}'; else out=$(cat "$W/fixtures/branch_main.json"); fi ;;
    repos/*/contents/*)
        if [ -n "${STUB_POSTVERIFY_EMPTY:-}" ] && [ "$ref" = "main" ] && grep -q "pr merge" "$CALLS" 2>/dev/null; then
          out='{}'   # POST-merge contents read returns an object with no content field
        elif [ "$ref" != "main" ] && [ -n "$ref" ]; then
          # before any merge call: main blob = OLD.  after merge call (unless
          # STUB_FORCE_STALE_MAIN): main blob reflects the landed head version.
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
        "$WORK/fixtures/comments.json" "$WORK/output" "$WORK/call_count"
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

echo "[16] post-merge verify: merge LANDED => merged=true, gate FAILS, loop halts"
# Truth-state model (10-02 review): `gh pr merge` succeeded => main WAS
# changed => merged=true stands even though verification of what landed
# failed.  The old expectation (merged=false on verify failure) was itself
# the bug: it lied about a landed merge and the caller skipped the mandatory
# build of the new main.
reset_env; good_pr; mk_diff 156.0.1; run_gate STUB_FORCE_STALE_MAIN=1
expect "verify failure logged" contains "post-merge verify FAILED" "$WORK/stdout"
expect "merged=true output (merge DID land)" contains "merged=true" "$WORK/output"
expect "gate exits nonzero (5)" test "$(cat "$WORK/exit")" = 5
expect "no AUTO-MERGE-ACCEPT comment when unverified" absent "AUTO-MERGE-ACCEPT" "$WORK/calls.log"
expect "merged_pr_version carries landed version" contains "merged_pr_version=156.0.1" "$WORK/output"

echo "[16b] post-merge verify: contents read EMPTY => merged=true + gate failure"
reset_env; good_pr; mk_diff 156.0.1; run_gate STUB_POSTVERIFY_EMPTY=1
expect "verify failure logged" contains "post-merge verify FAILED" "$WORK/stdout"
expect "merged=true output" contains "merged=true" "$WORK/output"
expect "gate exits 5" test "$(cat "$WORK/exit")" = 5

echo "[16c] post-merge verify: main branch SHA unreadable => fail closed"
reset_env; good_pr; mk_diff 156.0.1; run_gate STUB_BRANCH_SHA_EMPTY=1
expect "verify failure names branch SHA" contains "branch SHA unreadable" "$WORK/stdout"
expect "merged=true output" contains "merged=true" "$WORK/output"
expect "gate exits 5" test "$(cat "$WORK/exit")" = 5

echo "[16d] post-merge verify failure halts candidate loop (no second merge)"
reset_env; good_pr; mk_diff 156.0.1
jq -nc '[{number:7, headRefName:"renovate/termux-firefox-upstream-156"},
         {number:8, headRefName:"renovate/termux-firefox-upstream-156.1"}]' > "$WORK/fixtures/pr_list"
run_gate STUB_FORCE_STALE_MAIN=1
expect "first candidate merged" contains "pr merge 7" "$WORK/calls.log"
expect "second candidate NOT merged after verify failure" absent "pr merge 8" "$WORK/calls.log"
expect "gate exits 5" test "$(cat "$WORK/exit")" = 5

echo "[16e] transient first-API-failure -> retry succeeds with CLEAN payload"
# 4-A: retry diagnostics on stdout used to be captured INTO the payload
# (candidates=$(gh_retry ...)).  A polluted parse would escalate a bogus
# candidate and never merge; correct behavior = WARN seen in the combined
# log, exactly one merge, merged=true.
reset_env; good_pr; mk_diff 156.0.1; run_gate FAIL_MODE=first_flaky
expect "retry warning logged" contains "WARN: attempt 1/4 failed" "$WORK/stdout"
n_pl=$(grep -c "pr list" "$WORK/calls.log" || true)
expect "candidate listing retried (2 pr list calls)" test "$n_pl" = 2
expect "payload unpolluted: merge happened" contains "pr merge 7" "$WORK/calls.log"
expect "payload unpolluted: no bogus candidate escalated" absent "AUTO-MERGE-REJECT" "$WORK/calls.log"
expect "merged=true output" contains "merged=true" "$WORK/output"
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "no WARN token inside gh calls" absent "pulls/WARN" "$WORK/calls.log"

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
  # real gh 2.102.0 (live-verified 2026-10-02): `gh api` prints the HTTP error
  # body to STDOUT and exits 1 — a 404 is NOT an empty stdout.  A 5xx also
  # exits non-zero with a body; callers must not conflate them.
  if [ "${FAIL_MODE:-}" = "api_500" ]; then
    echo '{"message":"Internal Server Error","status":"500"}'; exit 1
  fi
  path="${2:-}"; shift 2; jqexpr=""
  while [ $# -gt 0 ]; do case "$1" in --jq) jqexpr="${2:-}"; shift 2;; *) shift;; esac; done
  case "$path" in
    repos/*/releases/tags/*)
      if [ ! -f "$STATE" ]; then   # GitHub 404 emulation, real gh semantics
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/releases#get-a-release-by-tag-name","status":"404"}'
        exit 1
      fi
      if [ -n "$jqexpr" ]; then jq -r "$jqexpr" < "$STATE"; else cat "$STATE"; fi
      exit 0;;
    *) exit 0;;
  esac
fi
if [ "${1:-}" = "release" ]; then
  case "${2:-}" in
    create)
      # capture the release body so fixtures can assert validation wording
      shift 2
      while [ $# -gt 0 ]; do
        case "$1" in --notes-file) [ -n "${2:-}" ] && cp "$2" "$W/rel_notes.txt" 2>/dev/null;; esac
        shift
      done
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

REL_DEB="firefox_156.1.1-1.9.9.9_aarch64.deb"   # lead 156.1.1 = packaged_version("156.0.1"), rev 1.<port>
mk_pkg_named() { # fresh artifacts dir with an arbitrary deb name + valid SHA256SUMS
  rm -rf "$WORK/pkg"; mkdir -p "$WORK/pkg"; rm -f "$WORK/rel_state.json" "$WORK/rel_notes.txt"
  head -c 2048 /dev/urandom > "$WORK/pkg/$1"
  ( cd "$WORK/pkg" && sha256sum "$1" > SHA256SUMS )
}
mk_pkg() { mk_pkg_named "$REL_DEB"; }
run_rel() { # extra env passed as VAR=val args; TEST_PORT/TEST_FF also steer args
  local a port="9.9.9" ff="156.0.1"
  for a in "$@"; do case "$a" in TEST_PORT=*) port="${a#TEST_PORT=}";; TEST_FF=*) ff="${a#TEST_FF=}";; esac; done
  rm -f "$WORK/calls.log"
  PATH="$WORK/binrel:$PATH" REPO="ytoaa/termux-firefox-sandbox" GIT_SHA=eeeeeeee \
    env "$@" bash "$MAKE_REL" "$WORK/pkg" "$port" "$ff" dddddddd > "$WORK/stdout" 2>&1
  echo $? > "$WORK/exit"
}

echo "[18] release: create path when tag missing (version-pair tag)"
mk_pkg; run_rel
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "tag = v<port>-ff<firefox>" contains "rel:release create v9.9.9-ff156.0.1" "$WORK/calls.log"
expect "title = Firefox <v> — Sandbox Port <p>" contains "--title Firefox 156.0.1 — Sandbox Port 9.9.9" "$WORK/calls.log"
expect "deb uploaded to pair tag" contains "rel:release upload v9.9.9-ff156.0.1" "$WORK/calls.log"
exp_dg="sha256:$(sha256sum "$WORK/pkg/$REL_DEB" | cut -d' ' -f1)"
expect "read-back digest equals local" jq -e --arg d "$exp_dg" '.assets[0].digest == $d' "$WORK/rel_state.json"
expect "body records firefox+port+sha+commit+CI wording" bash -c 'grep -q "156.0.1" "$1" && grep -q "156.1.1-1.9.9.9" "$1" && grep -q "sha256" "$1" && grep -q "dddddddd" "$1" && grep -q "CI validated: semantic port verification PASS; AudioIPC binary gate PASS." "$1"' _ "$WORK/rel_notes.txt"
expect "no device claim for unvalidated pair (real ledger says 157.0/2.4.7)" bash -c '! grep -q "Device level-6 validated" "$1"' _ "$WORK/rel_notes.txt"

echo "[18b] release: 157.0 + port 2.4.7 -> tag v2.4.7-ff157.0"
mk_pkg_named firefox_157.1-1.2.4.7_aarch64.deb
run_rel TEST_PORT=2.4.7 TEST_FF=157.0
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "pair tag correct" contains "rel:release create v2.4.7-ff157.0" "$WORK/calls.log"

echo "[18c] release: dot release 157.0.1 -> lead 157.1.1, tag v2.4.7-ff157.0.1"
mk_pkg_named firefox_157.1.1-1.2.4.7_aarch64.deb
run_rel TEST_PORT=2.4.7 TEST_FF=157.0.1
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "dot-release tag correct" contains "rel:release create v2.4.7-ff157.0.1" "$WORK/calls.log"

echo "[18d] release: 157 deb must NEVER reconcile against the ff156 release"
mk_pkg_named firefox_157.1-1.9.9.9_aarch64.deb   # 157 build
run_rel TEST_FF=156.0.1                          # but caller claims 156.0.1
expect "exit 1 (provenance mismatch)" test "$(cat "$WORK/exit")" = 1
expect "refusal logged" contains "does not match (firefox 156.0.1 -> lead 156.1.1" "$WORK/stdout"
expect "no release writes at all" absent "rel:release" "$WORK/calls.log"

echo "[18e] release: Debian lead passed as source version -> rejected"
mk_pkg_named firefox_157.1-1.9.9.9_aarch64.deb
run_rel TEST_FF=157.1
expect "exit 1 (lead not a source version)" test "$(cat "$WORK/exit")" = 1
expect "invariant message surfaced" contains "rejected as source version" "$WORK/stdout"
expect "no release writes" absent "rel:release" "$WORK/calls.log"

echo "[18f] release: device claim ONLY when port.toml ledger names the pair"
mkdir -p "$WORK/relalt"
cp "$REPO_ROOT/port/make_release.sh" "$REPO_ROOT/port/prepare_recipe.py" "$WORK/relalt/"
cat > "$WORK/relalt/port.toml" <<'LEDGER'
[port]
version = "9.9.9"
last_validated_port = "9.9.9"
last_validated_firefox = "156.0.1"
last_validated_revision = "1"
last_validated_srcsha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
policy_mode = "fail-closed"
LEDGER
mk_pkg   # 156.0.1 pair deb
run_rel MAKE_REL_ALT=1
expect "baseline: real script has no device claim" bash -c '! grep -q "Device level-6 validated" "$1"' _ "$WORK/rel_notes.txt"
rm -f "$WORK/rel_notes.txt" "$WORK/rel_state.json"   # force alt run down the CREATE path
PATH="$WORK/binrel:$PATH" REPO="ytoaa/termux-firefox-sandbox" GIT_SHA=eeeeeeee \
  env TEST_PORT=9.9.9 TEST_FF=156.0.1 bash "$WORK/relalt/make_release.sh" \
  "$WORK/pkg" 9.9.9 156.0.1 dddddddd > "$WORK/stdout" 2>&1
expect "alt-ledger run exit 0" test "$?" = 0
expect "ledger-matched pair claims device level-6" bash -c 'grep -q "Device level-6 validated" "$1" && grep -q "CI validated" "$1"' _ "$WORK/rel_notes.txt"

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
expect "clobbered" contains "rel:release upload v9.9.9-ff156.0.1" "$WORK/calls.log"
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

echo "[25b] release: gh api 5xx (not 404) -> fail closed, never create/upload"
mk_pkg; run_rel FAIL_MODE=api_500
expect "exit 1" test "$(cat "$WORK/exit")" = 1
expect "lookup failure surfaced" contains "release lookup failed" "$WORK/stdout"
expect "no create on API error" absent "rel:release create" "$WORK/calls.log"
expect "no upload on API error" absent "rel:release upload" "$WORK/calls.log"

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
expect "Release SHA256 section matches Packages" bash -c 'awk -v h="$2" "/^SHA256:/{f=1;next} /^[A-Za-z0-9]+:/{f=0} f && index(\$0,h)==2 {ok=1} END{exit !ok}" "$1"' _ "$WORK/aptrepo/dists/stable/Release" "$rele"
expect "Release hash labels are apt-parseable (SHA256:, not SHA256Sum:)" bash -c 'grep -q "^SHA256:$" "$1" && ! grep -q "Sum:" <(grep -E "^SHA" "$1")' _ "$WORK/aptrepo/dists/stable/Release"
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
if bash -n "$PUB"; then PASS=*** printf '  %sPASS%s bash -n clean\n' "$GRN" "$RST";
else FAIL=$((FAIL+1)); printf '  %sFAIL%s bash -n\n' "$RED" "$RST"; fi

# ===========================================================================
# watcher_assert.sh — outcome-assertion fixtures (10-02 ruling (a)).
# The I-9 class: Renovate exits 0 after a 403'd POST /pulls, so the watcher
# stays green while the pipeline mission-fails. The assertion must go RED on
# anchor!=live with no open renovate PR, and must NEVER read green when it
# cannot evaluate (fail-closed). Uses the same stub gh on PATH; `gh pr list`
# without --jq cats fixtures/pr_list, so each scenario seeds it directly.
# ===========================================================================
ASSERT="$REPO_ROOT/port/watcher_assert.sh"
WA="$WORK/wa"
mkdir -p "$WA"
cp "$ASSERT" "$WA/assert_copy.sh"

wa_anchor() { printf 'termuxFirefoxVersion = "%s"\n' "$1" > "$WA/anchor"; }
wa_live()   { printf 'TERMUX_PKG_VERSION="%s"\n' "$1" > "$WA/live"; }

run_assert() {
  ( cd "$WORK/repo"
    env PATH="$WORK/bin:$PATH" \
        GITHUB_REPOSITORY="ytoaa/termux-firefox-sandbox" \
        ANCHOR_FILE="$WA/anchor" LIVE_FILE="$WA/live" \
        "$@" bash "$WA/assert_copy.sh" >"$WORK/stdout" 2>&1 )
  echo $? > "$WORK/exit"
}

echo "[31] anchor==live => exit 0, no PR expected"
wa_anchor 157.0; wa_live 157.0
jq -nc '[]' > "$WORK/fixtures/pr_list"; run_assert
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "reports anchor==live" contains "anchor == live" "$WORK/stdout"

echo "[32] anchor!=live with OPEN renovate bump PR => exit 0 (outcome OK)"
# REAL gh `pr list --json` output shape: FLAT headRefName (the old
# {head:{ref:...}} fixture shape described a GraphQL payload that gh pr list
# never emits — and the stub used to accept it, hiding the field bug).
wa_anchor 156.0.1; wa_live 157.0
jq -nc '[{number:9, headRefName:"renovate/termux-firefox-upstream-157.x"}]' > "$WORK/fixtures/pr_list"; run_assert
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "reports bump PR found" contains "outcome OK" "$WORK/stdout"

echo "[32b] STUB FIDELITY: gh rejects --json head.ref (real-gh semantics)"
PATH="$WORK/bin:$PATH" gh pr list --repo x/y --json head.ref >/dev/null 2>&1
expect "head.ref rejected by stub gh (exit 1)" test "$?" = 1
PATH="$WORK/bin:$PATH" gh pr list --repo x/y --json number,headRefName >/dev/null 2>&1
expect "headRefName accepted by stub gh (exit 0)" test "$?" = 0

echo "[33] I-9 FIXTURE: anchor!=live, PR-creation silently lost (no open PR) => exit 1"
wa_anchor 156.0.1; wa_live 157.0
jq -nc '[]' > "$WORK/fixtures/pr_list"; run_assert
expect "exit 1 (red, was green x4 on 10-01)" test "$(cat "$WORK/exit")" = 1
expect "names the toggle suspect" contains "create and approve pull requests" "$WORK/stdout"

echo "[34] non-renovate open PRs do NOT satisfy the assertion => exit 1"
wa_anchor 156.0.1; wa_live 157.0
jq -nc '[{number:5, headRefName:"feature/unrelated"}]' > "$WORK/fixtures/pr_list"; run_assert
expect "exit 1" test "$(cat "$WORK/exit")" = 1

echo "[34b] UNRELATED renovate PR must NOT mask a lost bump PR => exit 1"
# The old `startswith("renovate/")` accepted ANY renovate branch (e.g. a
# pin bump) as proof the bump PR existed. Only OUR bump family counts.
wa_anchor 156.0.1; wa_live 157.0
jq -nc '[{number:6, headRefName:"renovate/actions-checkout-5.x"}]' > "$WORK/fixtures/pr_list"; run_assert
expect "exit 1 (unrelated renovate PR rejected)" test "$(cat "$WORK/exit")" = 1

echo "[35] PR query FAILS => exit 2 (fail-closed: unevaluated never reads green)"
wa_anchor 156.0.1; wa_live 157.0
jq -nc '[]' > "$WORK/fixtures/pr_list"; run_assert FAIL_MODE=list_fail
expect "exit 2" test "$(cat "$WORK/exit")" = 2
expect "query failure logged" contains "open-PR query FAILED" "$WORK/stdout"

echo "[35b] query OUTPUT UNPARSEABLE (not JSON) => exit 2, not exit-1 green-adjacent"
wa_anchor 156.0.1; wa_live 157.0
printf 'this is not json\n' > "$WORK/fixtures/pr_list"; run_assert
expect "exit 2" test "$(cat "$WORK/exit")" = 2
expect "unparseable logged" contains "unparseable" "$WORK/stdout"

echo "[36] anchor/live parse failure => exit 2 (fail-closed)"
printf 'no anchor here\n' > "$WA/anchor"; wa_live 157.0; run_assert
expect "exit 2" test "$(cat "$WORK/exit")" = 2
expect "parse failure logged" contains "anchor parse FAILED" "$WORK/stdout"
wa_anchor 156.0.1; printf 'no version here\n' > "$WA/live"; run_assert
expect "live parse failure => exit 2" test "$(cat "$WORK/exit")" = 2
expect "live parse failure logged" contains "live recipe parse FAILED" "$WORK/stdout"

echo "[37] dry-run dispatch skips the assertion => exit 0"
wa_anchor 156.0.1; wa_live 157.0; jq -nc '[]' > "$WORK/fixtures/pr_list"
: > "$WORK/calls.log"
run_assert DRY=full
expect "exit 0" test "$(cat "$WORK/exit")" = 0
expect "skip logged" contains "dry-run" "$WORK/stdout"
expect "no gh calls on dry-run" bash -c '! grep -q "pr list" "'"$WORK"'/calls.log"'

echo "[38] syntax check (bash -n) on watcher_assert.sh"
if bash -n "$ASSERT"; then PASS=*** printf '  %sPASS%s bash -n clean\n' "$GRN" "$RST";
else FAIL=$((FAIL+1)); printf '  %sFAIL%s bash -n\n' "$RED" "$RST"; fi

# ===========================================================================
# apt pool preservation — the CI seeding sequence end-to-end (10-02 review)
# Real defect: the release job's RUNNER_TEMP starts EMPTY; index+publish then
# REPLACED the gh-pages tree, dropping every previously published deb (the
# 157 build wiped the 156 deb from the channel).  The workflow now seeds the
# pool from the published branch before indexing; this fixture models that
# exact sequence against the local bare origin.
# ===========================================================================
echo "[39] apt: seeded re-publish preserves the existing pool (accumulation)"
rm -rf "$WORK/aptrepo2"
mkdir -p "$WORK/aptrepo2/pool"
( cd "$WORK/pushsrc" && git fetch -q origin gh-pages && git archive FETCH_HEAD pool ) | tar -x -C "$WORK/aptrepo2"
expect "seed brought the previously published deb" test -f "$WORK/aptrepo2/pool/main/f/firefox/firefox_9.10.0-1.9.9.9_aarch64.deb"
mk_fake_deb "$WORK/firefox_9.11.0-1.9.9.9_aarch64.deb" firefox 9.11.0-1.9.9.9
bash "$PUB" index "$WORK/firefox_9.11.0-1.9.9.9_aarch64.deb" "$WORK/aptrepo2" stable aarch64 > "$WORK/stdout" 2>&1
expect "index(seed+new) exit 0" test "$?" = 0
PKGS2="$WORK/aptrepo2/dists/stable/main/binary-aarch64/Packages"
# [29] had published 9.9.9 + 9.10.0; seeded pool brings both, index adds 9.11.0
expect "Packages lists ALL pool versions" bash -c '[ "$(grep -c "^Package: firefox$" "'"$PKGS2"'")" = 3 ]'
( cd "$WORK/pushsrc" && GIT_USER_NAME=t GIT_USER_EMAIL=t@i bash "$PUB" publish "$WORK/aptrepo2" gh-pages "$WORK/origin.git" ) > "$WORK/stdout" 2>&1
expect "publish exit 0" test "$?" = 0
gp=$(git -C "$WORK/origin.git" rev-parse gh-pages)
expect "branch keeps old deb" git -C "$WORK/origin.git" cat-file -e "$gp:pool/main/f/firefox/firefox_9.10.0-1.9.9.9_aarch64.deb"
expect "branch gains new deb" git -C "$WORK/origin.git" cat-file -e "$gp:pool/main/f/firefox/firefox_9.11.0-1.9.9.9_aarch64.deb"

# ===========================================================================
# prepare_recipe.py — version-lead invariant units (10-02 review item 7)
# ===========================================================================
echo "[40] prepare_recipe: packaging-lead + SRCURL invariant units"
cat > "$WORK/test_prepare.py" <<'PYPY'
import sys
sys.path.insert(0, sys.argv[1])
from prepare_recipe import packaged_version, raise_package_version, bump_revision_once, RecipeError, REV_MARK

SRCURL = ('TERMUX_PKG_SRCURL="https://archive.mozilla.org/pub/firefox/releases/'
          '${TERMUX_PKG_VERSION#*really}/source/firefox-${TERMUX_PKG_VERSION#*really}.source.tar.xz"')
def recipe(ver):
    return f'TERMUX_PKG_VERSION="{ver}"\n{SRCURL}\nTERMUX_PKG_SHA256=abc\n'

def raises(fn, *a):
    try:
        fn(*a)
        return False
    except RecipeError:
        return True

assert packaged_version("157.0") == "157.1", "157.0 -> 157.1"
assert packaged_version("156.0.1") == "156.1.1", "156.0.1 -> 156.1.1"
assert packaged_version("155.0.12") == "155.1.12"
# N.1 invariant: direct invocation must refuse colliding leads (mirror of ci.sh)
assert raises(packaged_version, "157.1")
assert raises(packaged_version, "157.2.3")
assert raises(packaged_version, "157")          # major-only
assert raises(packaged_version, "157.a")         # non-numeric
assert raises(packaged_version, "157.0.1.2")     # 4 segments
# raise_package_version: materialize + lead + idempotency
t = raise_package_version(recipe("157.0"), "157.0")
assert 'TERMUX_PKG_VERSION="157.1"' in t
assert "/releases/157.0/source/" in t
assert "${TERMUX_PKG_VERSION" not in t.split("SRCURL")[1]
assert raise_package_version(t, "157.0") == t, "idempotent re-run"
# SRCURL shape change (no template, no version) => fail closed EVEN THOUGH
# the version string appears elsewhere in the text (the old containment bug)
assert raises(raise_package_version, 'TERMUX_PKG_VERSION="157.0"\nTERMUX_PKG_SRCURL="https://example.invalid/other.tgz"\n', "157.0")
assert raises(raise_package_version, 'TERMUX_PKG_VERSION="157.0"\n', "157.0")  # SRCURL absent entirely
# revision composition: fresh bump (+1) and prepared re-run (suffix rewrite)
txt, rev = bump_revision_once('TERMUX_PKG_VERSION="157.0"\nTERMUX_PKG_REVISION=0\n', "2.4.8")
assert rev == "1.2.4.8" and REV_MARK in txt, f"fresh revision {rev}"
prepared = f'TERMUX_PKG_VERSION="157.1"\nTERMUX_PKG_REVISION={rev}\n{REV_MARK}\n'
txt2, rev2 = bump_revision_once(prepared, "2.4.9")
assert rev2 == "1.2.4.9", f"re-run keeps +1 base: {rev2}"
print("OK")
PYPY
python3 "$WORK/test_prepare.py" "$REPO_ROOT/port" > "$WORK/stdout" 2>&1
expect "unit asserts all pass" contains "OK" "$WORK/stdout"
if ! grep -q OK "$WORK/stdout"; then
  echo "    --- prepare failure detail ---"; tail -6 "$WORK/stdout" | sed 's/^/    /'
fi
if python3 -m py_compile "$REPO_ROOT/port/prepare_recipe.py" "$REPO_ROOT/port/firefox_sandbox_port.py" 2>"$WORK/stdout"; then
  PASS=*** printf '  %sPASS%s py_compile clean\n' "$GRN" "$RST"
else
  FAIL=$((FAIL+1)); printf '  %sFAIL%s py_compile\n' "$RED" "$RST"; cat "$WORK/stdout"
fi

# ===========================================================================
# Workflow wiring structure — regressions the YAML harness cannot execute but
# CAN grep: the provenance chain (gate-evaluated SHA -> build checkout) and
# the harness trigger coverage are load-bearing invariants (10-02 review).
# ===========================================================================
echo "[41] workflow wiring: provenance + trigger structure"
cat > "$WORK/test_wiring.py" <<'PYPY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
wf = root / ".github" / "workflows"
am = (wf / "auto-merge-upstream.yml").read_text()
fs = (wf / "firefox-sandbox.yml").read_text()
ci = (wf / "ci-tests.yml").read_text()
gate = (root / "port" / "auto_merge_upstream.sh").read_text()
wa = (root / "port" / "watcher_assert.sh").read_text()

# provenance: triage exports the exact evaluated SHA; build consumes it
assert "termux_commit: ${{ steps.live.outputs.termux_commit }}" in am
assert "termux_ref: ${{ needs.triage.outputs.termux_commit }}" in am
assert re.search(r"termux_ref:\s*master", am) is None, "build-after-merge must NOT use mutable 'master'"
assert "if: always() && needs.triage.outputs.merged == 'true'" in am, "verify-failed merge must still build"
# firefox-sandbox: single resolution point feeding check+build+apt seed
assert "id: resolve" in fs
assert "steps.resolve.outputs.termux_commit" in fs
assert "needs.check-upstream.outputs.termux_commit" in fs
assert "[0-9a-f]{40}" in fs, "resolve must validate 40-hex"
assert "git archive FETCH_HEAD pool" in fs, "apt pool seeding from published branch"
# harness triggers on EVERY PR (no workflow-only blind spot)
assert re.search(r"^\s*pull_request:\s*$", ci, re.MULTILINE), "ci-tests must trigger on all PRs"
ci_nocomments = "\n".join(l for l in ci.splitlines() if not l.lstrip().startswith("#"))
assert "paths:" not in ci_nocomments, "no paths filter allowed on the pre-merge harness"
# build workflow push trigger must NEVER fire on tag pushes (10-02 incident:
# a PAT-created release tag fired a full build running the OLD tag policy)
fs_nocomments = "\n".join(l for l in fs.splitlines() if not l.lstrip().startswith("#"))
m = re.search(r"^  push:\n((?:    .*\n)*)", fs_nocomments, re.MULTILINE)
assert m, "firefox-sandbox must keep the push trigger"
assert re.search(r"^    branches:\n      - main\n", m.group(1), re.MULTILINE), \
    "push trigger MUST pin branches: [main] (bare push: fires on tag pushes -> stale-ref builds)"
# gate/watcher: real gh semantics only (positive form; prose may cite the dead field)
assert "--json number,headRefName" in gate, "gate candidate listing must use headRefName"
assert "--json number,headRefName" in wa, "watcher assertion must use headRefName"
assert 'test("^renovate/termux-firefox-upstream-")' in wa, "assertion must anchor to the bump family"
assert "--method GET" in gate, "contents read must pin GET against gh -f POST default"
# truth-state model present
assert "POST_MERGE_VERIFY_FAILED" in gate and "MERGED=1" in gate
print("OK")
PYPY
python3 "$WORK/test_wiring.py" "$REPO_ROOT" > "$WORK/stdout" 2>&1
expect "workflow wiring invariants hold" contains "OK" "$WORK/stdout"
if ! grep -q OK "$WORK/stdout"; then
  echo "    --- wiring failure detail ---"; tail -6 "$WORK/stdout" | sed 's/^/    /'
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
