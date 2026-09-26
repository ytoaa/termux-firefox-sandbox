#!/usr/bin/env bash
# Auto-merge gate for Renovate upstream firefox bump PRs (exception-only policy).
#
# Policy: the maintainer is NOT a steady-state gate.  A Renovate PR that
# updates port/upstream.renovate is merged automatically ONLY when every
# check below passes; anything else leaves the PR open and escalates it with
# a needs-human comment (the sole human touchpoints, per repo policy).
#
# Fail-closed checks (all required for accept):
#   1. head branch matches ^renovate/termux-firefox-upstream-
#   2. PR changes exactly one file: port/upstream.renovate
#   3. the proposed termuxFirefoxVersion parses as N[.0[.k]]
#   4. proposed == TERMUX_PKG_VERSION in the LIVE Termux recipe (ground truth)
#   5. proposed > current anchor (semantic-ordered; rejects downgrades)
#   6. second segment is 0 (N.1 packaging-lead invariant; mirrors ci.sh)
#
# Never trust PR author or labels: Renovate runs with GITHUB_TOKEN, so both
# appear as the repo owner and labels may be absent (observed in PR #1).
#
# Post-merge build note: merges performed with GITHUB_TOKEN do NOT fire the
# repository's `push` trigger (GitHub recursion suppression).  The workflow
# that calls this script must run the build explicitly via workflow_call with
# force=true.  Manual human merges still use the push trigger fast path.
#
# Env: DRY_RUN=true  -> evaluate and comment only, never merge.
#      PR_NUMBER     -> evaluate that single PR (manual dispatch testing).
# Expects: /tmp/build.sh (live recipe), repo checkout in CWD, gh authed.
set -uo pipefail

ANCHOR="port/upstream.renovate"
DRY_RUN="${DRY_RUN:-false}"
PR_NUMBER="${PR_NUMBER:-}"
ESCALATION_MARKER="AUTO-MERGE-REJECT"

log() { printf '[auto-merge] %s\n' "$*"; }

anchor_value() {
  sed -n 's/^termuxFirefoxVersion *= *"\([0-9][0-9.]*\)".*/\1/p' "$ANCHOR" | head -n1
}

live_value() {
  sed -n 's/^TERMUX_PKG_VERSION="\{0,1\}\([^"#[:space:]]*\)"\{0,1\}.*/\1/p' /tmp/build.sh | head -n1
}

# true if $1 < $2 by dot-numeric ordering (locale-pinned: sort -V must not be
# affected by runner locale)
version_lt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]
}

escalate() {
  local pr="$1" reasons="$2"
  local existing
  existing=$(gh pr view "$pr" --json comments --jq '[.comments[].body | contains("'"$ESCALATION_MARKER"'")] | any' 2>/dev/null || echo false)
  if [ "$existing" = "true" ]; then
    log "PR #$pr already escalated; skipping duplicate comment"
    return 0
  fi
  gh pr comment "$pr" --body "**$ESCALATION_MARKER** — auto-merge gate declined this PR. Reasons: $reasons.

Leaving this PR open for maintainer decision. Checks applied: branch pattern, single-file diff, live-recipe match, forward bump, N.1 invariant. See port/auto_merge_upstream.sh." || log "WARN: escalation comment failed for PR #$pr"
  gh pr edit "$pr" --add-label needs-human 2>/dev/null || log "note: needs-human label not applied (permissions/label missing)"
  log "PR #$pr ESCALATED to human: $reasons"
}

accept_merge() {
  local pr="$1" current="$2" proposed="$3" headsha="$4"
  gh pr comment "$pr" --body "AUTO-MERGE-ACCEPT — policy checks passed (single-file anchor bump $current -> $proposed, verified against live Termux recipe, invariant OK, head pinned to $headsha). Merging per exception-only maintainer policy; the build will be triggered by the auto-merge workflow via workflow_call(force=true)." || log "WARN: accept comment failed"
  if [ "$DRY_RUN" = "true" ]; then
    log "PR #$pr ACCEPT verdict (dry-run: not merging)"
    return 0
  fi
  # --match-head-commit closes the evaluation-vs-merge TOCTOU window: a
  # force-push to the PR head (trivially possible for fork-PR authors;
  # headRefName is the bare fork branch name) between our checks and the
  # merge makes the merge fail instead of landing mutated content.
  gh pr merge "$pr" --merge --match-head-commit "$headsha" \
    || { escalate "$pr" "merge-command-failed (head likely changed since evaluation)"; return 1; }
  log "PR #$pr MERGED (anchor $current -> $proposed @ $headsha)"
  MERGED=1
}

MERGED=0
live="$(live_value)"
if [ -z "$live" ]; then
  log "ERROR: cannot parse TERMUX_PKG_VERSION from live recipe (shape change?)"
  exit 2
fi
log "live Termux firefox = $live"

if [ -n "$PR_NUMBER" ]; then
  candidates="$PR_NUMBER"
else
  candidates=$(gh pr list --state open --json number,headRefName \
    --jq '.[] | select(.headRefName | test("^renovate/termux-firefox-upstream-")) | .number | tostring')
fi
if [ -z "$candidates" ]; then
  log "no candidate PRs; nothing to do"
  echo "merged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

current="$(anchor_value)"
[ -n "$current" ] || { log "ERROR: anchor file unreadable/malformed: $ANCHOR"; exit 2; }
log "anchor = $current"

for pr in $candidates; do
  head_ref=$(gh pr view "$pr" --json headRefName --jq .headRefName)
  headsha=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
  files=$(gh pr view "$pr" --json files --jq '[.files[].path] | join(",")')
  reasons=()

  [[ "$head_ref" =~ ^renovate/termux-firefox-upstream- ]] || reasons+=("branch-not-renovate-pattern:$head_ref")
  [ "$files" = "$ANCHOR" ] || reasons+=("unexpected-files:$files")

  # One diff fetch for this PR; the bump must be exactly one + / one -
  # anchor line.  A multi-line diff would make the parsed proposal diverge
  # from the final file state (multi-value assignment smuggling).
  diff=$(gh pr diff "$pr")
  nplus=$(printf '%s\n' "$diff" | grep -c '^+termuxFirefoxVersion' || true)
  nminus=$(printf '%s\n' "$diff" | grep -c '^-termuxFirefoxVersion' || true)
  { [ "$nplus" = "1" ] && [ "$nminus" = "1" ]; } || reasons+=("diff-shape-not-single-bump:+$nplus/-$nminus")

  proposed=$(printf '%s\n' "$diff" | sed -n 's/^+termuxFirefoxVersion *= *"\([0-9][0-9.]*\)".*/\1/p' | head -n1)
  if [ -z "$proposed" ]; then
    reasons+=("proposed-version-unparsable")
  else
    [ "$proposed" = "$live" ] || reasons+=("proposed-$proposed-differs-from-live-$live")
    version_lt "$current" "$proposed" || reasons+=("not-a-forward-bump:$current->$proposed")
    seg2="${proposed#*.}"; seg2="${seg2%%.*}"
    [ "$seg2" = "0" ] || reasons+=("invariant-N.1-collision:$proposed")
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    escalate "$pr" "$(IFS='; '; echo "${reasons[*]}")"
  else
    accept_merge "$pr" "$current" "$proposed" "$headsha" || true
  fi
done

echo "merged=$([ "$MERGED" = "1" ] && echo true || echo false)" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "merged_pr_version=$proposed" >> "${GITHUB_OUTPUT:-/dev/null}"
