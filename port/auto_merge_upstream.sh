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
#   2. PR head is the SAME repository as base (head.repo.full_name ==
#      base.repo.full_name) and author_association is OWNER or MEMBER.
#      Renovate runs with GITHUB_TOKEN, so legit bump PRs are same-repo with
#      author_association=OWNER (live-verified PRs #1/#3).  Do NOT use
#      isCrossRepository: the key is absent on this repo's PR responses and
#      jq's `null == false` is false, which would silently drop every legit
#      PR (panel struck-claim (g), 2026-09-28).
#   3. PR changes exactly one file: port/upstream.renovate
#   4. the proposed termuxFirefoxVersion parses as N[.0[.k]]
#   5. proposed == TERMUX_PKG_VERSION in the LIVE Termux recipe (ground truth,
#      fetched at a pinned termux-packages commit; see TERMUX_PACKAGES_SHA)
#   6. proposed > current anchor (semantic-ordered; rejects downgrades)
#   7. second segment is 0 (N.1 packaging-lead invariant; mirrors ci.sh)
#
# Atomicity (panel finding F-01): every per-PR fact comes from ONE gh api
# round-trip, the diff is fetched after that read, and head.sha is RE-READ
# after evaluation; any drift aborts the merge (the next watcher cycle re-evaluates
# the new head cleanly).  The merge itself pins --match-head-commit, so no
# window remains between the final re-read and GitHub's own verification.
#
# Escalation integrity (F-06): a declined PR MUST end up with the
# needs-human label; comment dedup never skips the label.  Any escalation
# write failure makes the run exit nonzero (a silent decline is a
# policy-integrity failure).  DRY_RUN performs no writes at all.
#
# Audit record (compliance C-1): the full evaluation tuple (head sha,
# termux-packages commit SHA used for the live-recipe check, anchor
# transition, gate-script hash, run URL) is written into the MERGE COMMIT
# MESSAGE on protected main — append-only, not erasable by the audited
# subject.  The AUTO-MERGE-ACCEPT PR comment is posted only after the merge
# lands and is a convenience copy, not the record.
#
# Post-merge build note: merges performed with GITHUB_TOKEN do NOT fire the
# repository's `push` trigger (GitHub recursion suppression).  The workflow
# that calls this script must run the build explicitly via workflow_call with
# force=true.  Manual human merges still use the push trigger fast path.
#
# Env: DRY_RUN=true  -> evaluate only; no merge, no PR writes.
#      PR_NUMBER     -> evaluate that single PR (manual dispatch testing).
#      TERMUX_PACKAGES_SHA -> commit SHA the live recipe was fetched at
#                             (audit tuple; empty tolerated, logged as unknown).
# Expects: /tmp/build.sh (live recipe at TERMUX_PACKAGES_SHA), repo checkout
# in CWD, gh authed (GITHUB_TOKEN). Tests: port/tests/run_tests.sh.
set -uo pipefail

ANCHOR="port/upstream.renovate"
DRY_RUN="${DRY_RUN:-false}"
PR_NUMBER="${PR_NUMBER:-}"
ESCALATION_MARKER="AUTO-MERGE-REJECT"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-unknown}"
TERMUX_PACKAGES_SHA="${TERMUX_PACKAGES_SHA:-}"

log() { printf '[auto-merge] %s\n' "$*"; }

# stderr sink for retry diagnostics (never a hardcoded /tmp path: some
# sandboxes mount it read-only)
GH_RETRY_ERR="$(mktemp 2>/dev/null || echo "${TMPDIR:-.}/gh_retry_err.$$")"

# Retry a gh call (transient API failures must not masquerade as declines or
# empty candidate sets — F-10).  Usage: gh_retry <max> -- <args...>
gh_retry() {
  local max="$1"; shift; [ "${1:-}" = "--" ] && shift
  local attempt=1 rc=0 out
  while [ "$attempt" -le "$max" ]; do
    if out=$("$@" 2>"$GH_RETRY_ERR"); then
      printf '%s' "$out"; return 0
    else
      # capture INSIDE else: after `fi` the exit status is fi's own (0),
      # which silently disabled fail-closed checks in an earlier revision.
      rc=$?
    fi
    log "WARN: attempt $attempt/$max failed (rc=$rc): $* — $(head -c 200 "$GH_RETRY_ERR" 2>/dev/null)"
    attempt=$((attempt+1)); sleep 2
  done
  return "$rc"
}

anchor_value() {
  sed -n 's/^termuxFirefoxVersion *= *"\([0-9][0-9.]*\)".*/\1/p' "$ANCHOR" | head -n1
}

live_value() {
  sed -n 's/^TERMUX_PKG_VERSION="\{0,1\}\([^"#[:space:]]*\)"\{0,1\}.*/\1/p' "${LIVE_RECIPE:-/tmp/build.sh}" | head -n1
}

# true if $1 < $2 by dot-numeric ordering (locale-pinned: sort -V must not be
# affected by runner locale)
version_lt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]
}

# sha256 of the anchor file blob at a given ref (content-addressed skip:
# a PR whose anchor blob already equals main's blob is already landed — F-13).
anchor_blob_sha() {
  # -X GET is REQUIRED: gh flips to POST when -f is passed, and POST
  # /repos/*/contents/* is not this call (live-verified 404 class, 09-29).
  gh_retry 3 -- gh api "repos/${REPO}/contents/${ANCHOR}" -X GET -f ref="$1" 2>/dev/null \
    | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1
}

ESCALATION_WRITE_FAILED=0

escalate() {
  local pr="$1" reasons="$2"
  if [ "$DRY_RUN" = "true" ]; then
    log "PR #$pr DECLINED verdict (dry-run: no PR writes): $reasons"
    return 0
  fi
  local rc=0
  # Label FIRST and always: it is the durable escalation signal the heartbeat
  # keys on; comment dedup must never starve it.
  if ! gh_retry 3 -- gh pr edit "$pr" --add-label needs-human; then
    log "ERROR: could not apply needs-human label to PR #$pr — escalation is NOT visible"
    rc=1
  fi
  local existing
  existing=$(gh_retry 2 -- gh pr view "$pr" --json comments \
    --jq '[.comments[].body | contains("'"$ESCALATION_MARKER"'")] | any' 2>/dev/null || echo false)
  if [ "$existing" = "true" ]; then
    log "PR #$pr already has an escalation comment; skipping duplicate (label still enforced)"
  elif ! gh_retry 3 -- gh pr comment "$pr" --body "**$ESCALATION_MARKER** — auto-merge gate declined this PR. Reasons: $reasons.

Leaving this PR open for maintainer decision. Checks applied: same-repo identity + association, branch pattern, single-file diff, live-recipe match, forward bump, N.1 invariant. See port/auto_merge_upstream.sh. Run: ${RUN_URL}"; then
    log "ERROR: escalation comment failed for PR #$pr (label attempted separately)"
    rc=1
  fi
  [ "$rc" = "0" ] || ESCALATION_WRITE_FAILED=1
  log "PR #$pr ESCALATED to human: $reasons"
  return 0
}

accept_merge() {
  local pr="$1" current="$2" proposed="$3" headsha="$4" head_ref="$5" nplus="$6" nminus="$7"
  if [ "$DRY_RUN" = "true" ]; then
    log "PR #$pr ACCEPT verdict (dry-run: not merging)"
    return 0
  fi
  local gate_hash live_note
  gate_hash=$(sha256sum "$0" 2>/dev/null | cut -d' ' -f1 || echo unknown)
  if [ -n "$TERMUX_PACKAGES_SHA" ]; then
    live_note="live=${live}@termux-packages=${TERMUX_PACKAGES_SHA}"
  else
    live_note="live=${live}@termux-packages=UNKNOWN"
  fi
  # --match-head-commit pins the MERGE; the post-evaluation head re-read in
  # the loop above pinned the EVALUATION to the same sha.  Together:
  # eval-vs-merge is sha-atomic.
  local audit="AUTO-MERGE audit tuple (F-01/F-04 FIX-1): head_sha=${headsha} head_ref=${head_ref} anchor=${current}->${proposed} diff=+${nplus}/-${nminus} ${live_note} gate_sha256=${gate_hash} run=${RUN_URL}"
  if ! gh_retry 1 -- gh pr merge "$pr" --merge \
      --subject "Merge pull request #${pr} from ${head_ref} (auto-merge gate)" \
      --body "$audit" \
      --match-head-commit "$headsha"; then
    escalate "$pr" "merge-command-failed (head likely changed since evaluation)"
    return 1
  fi
  log "PR #$pr MERGED (anchor $current -> $proposed @ $headsha)"
  # Verify what LANDED against the branch ref — never the mutable PR object's
  # merge_commit_sha (panel evidence: PR #3's merge_commit_sha is orphaned).
  local main_sha new_anchor
  main_sha=$(gh_retry 3 -- gh api "repos/${REPO}/branches/main" 2>/dev/null | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)
  new_anchor=$(gh_retry 2 -- gh api "repos/${REPO}/contents/${ANCHOR}" -X GET -f ref=main 2>/dev/null \
    | sed -n 's/.*"content":[[:space:]]*"\([A-Za-z0-9+/=]*\)".*/\1/p' | head -n1 \
    | tr -d '\n' | base64 -d 2>/dev/null \
    | sed -n 's/^termuxFirefoxVersion *= *"\([0-9][0-9.]*\)".*/\1/p' | head -n1)
  if [ -n "$new_anchor" ] && [ "$new_anchor" != "$proposed" ]; then
    log "ERROR: post-merge verify FAILED — main anchor '$new_anchor' != expected '$proposed' (main sha ${main_sha:-unknown})"
    return 2
  fi
  log "post-merge verify OK: main=${main_sha:-unknown} anchor=${new_anchor:-$proposed}"
  MERGED=1
  MERGED_VERSION="$proposed"
  # Accept comment AFTER the merge: convenience copy only; the merge commit
  # message on main is the audit record (C-1).
  if ! gh_retry 2 -- gh pr comment "$pr" --body "AUTO-MERGE-ACCEPT — merged per exception-only policy (single-file anchor bump $current -> $proposed, ${live_note}). Audit record: merge commit message on main. Build runs via workflow_call(force=true). Run: ${RUN_URL}"; then
    log "WARN: accept comment failed (merge succeeded; audit record is the merge commit)"
  fi
  return 0
}

MERGED=0
MERGED_VERSION=""
live="$(live_value)"
if [ -z "$live" ]; then
  log "ERROR: cannot parse TERMUX_PKG_VERSION from live recipe (shape change?)"
  exit 2
fi
log "live Termux firefox = $live @ termux-packages=${TERMUX_PACKAGES_SHA:-UNKNOWN}"

if [ -n "$PR_NUMBER" ]; then
  candidates="$PR_NUMBER"
else
  if ! candidates=$(gh_retry 4 -- gh pr list --state open --json number,headRefName \
    --jq '.[] | select(.headRefName | test("^renovate/termux-firefox-upstream-")) | .number | tostring'); then
    log "ERROR: candidate listing failed after retries — refusing to report 'no candidates' (F-10)"
    exit 3
  fi
fi
if [ -z "$candidates" ]; then
  log "no candidate PRs; nothing to do"
  echo "merged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

current="$(anchor_value)"
[ -n "$current" ] || { log "ERROR: anchor file unreadable/malformed: $ANCHOR"; exit 2; }
log "anchor = $current"

main_blob=$(anchor_blob_sha main) || true
if [ -z "$main_blob" ]; then
  log "ERROR: cannot read main anchor blob via contents API (fail closed)"
  exit 3
fi

for pr in $candidates; do
  # Single round-trip for all identity/atomicity facts (F-01/F-04).
  read -r head_ref headsha head_full base_full assoc <<EOF2
$(gh_retry 3 -- gh api "repos/${REPO}/pulls/${pr}" --jq '[.head.ref, .head.sha, .head.repo.full_name, .base.repo.full_name, .author_association] | join(" ")')
EOF2
  if [ -z "${head_ref:-}" ] || [ -z "${headsha:-}" ]; then
    log "ERROR: PR #$pr metadata read failed after retries (not treating as no-candidate)"
    escalate "$pr" "pr-metadata-unreadable (API failure — NOT a policy decline; investigate)"
    continue
  fi

  reasons=()

  [[ "$head_ref" =~ ^renovate/termux-firefox-upstream- ]] || reasons+=("branch-not-renovate-pattern:$head_ref")

  # Identity: same-repo + OWNER/MEMBER association.  Never labels, never
  # author.login (GITHUB_TOKEN PRs are authored by the repo owner).
  [ "$head_full" = "$REPO" ] || reasons+=("head-repo-not-same-repo:$head_full")
  [ "$base_full" = "$REPO" ] || reasons+=("base-repo-unexpected:$base_full")
  case "$assoc" in OWNER|MEMBER) ;; *) reasons+=("author-association-not-trusted:$assoc");; esac

  # Content-addressed already-landed skip (F-13): head anchor blob identical
  # to main's => merging would be a no-op with a lying audit record.
  if [ ${#reasons[@]} -eq 0 ]; then
    head_blob=$(anchor_blob_sha "$headsha")
    if [ -n "$head_blob" ] && [ "$head_blob" = "$main_blob" ]; then
      log "PR #$pr skipped: anchor blob already landed on main (no-op merge refused)"
      continue
    fi
  fi

  files=$(gh_retry 3 -- gh pr view "$pr" --json files --jq '[.files[].path] | join(",")') \
    || { log "ERROR: PR #$pr files read failed after retries"; escalate "$pr" "files-read-failed (API failure — investigate)"; continue; }
  [ "$files" = "$ANCHOR" ] || reasons+=("unexpected-files:$files")

  # One diff fetch for this PR; the bump must be exactly one + / one -
  # anchor line (column-0).  A multi-line diff would make the parsed proposal
  # diverge from the final file state (multi-value assignment smuggling).
  diff=$(gh_retry 3 -- gh pr diff "$pr") \
    || { log "ERROR: PR #$pr diff read failed after retries"; escalate "$pr" "diff-read-failed (API failure — investigate)"; continue; }
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

  # Post-evaluation re-read: the head GitHub evaluated must be the head
  # GitHub merges (F-01).  Any drift between the first read and here => abort;
  # the next watcher cycle re-evaluates the new head cleanly.  Combined with
  # --match-head-commit (atomically verified by GitHub at merge time), no
  # read sits between this re-read and the merge.
  if [ ${#reasons[@]} -eq 0 ]; then
    headsha2=$(gh_retry 2 -- gh api "repos/${REPO}/pulls/${pr}" --jq .head.sha) || headsha2=""
    if [ "$headsha2" != "$headsha" ]; then
      escalate "$pr" "head-changed-during-evaluation ($headsha -> ${headsha2:-unreadable}) — will re-evaluate next cycle"
      continue
    fi
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    escalate "$pr" "$(IFS='; '; echo "${reasons[*]}")"
  else
    accept_merge "$pr" "$current" "$proposed" "$headsha" "$head_ref" "$nplus" "$nminus" || true
    # Re-anchor loop state after a successful merge: the local checkout is a
    # stale snapshot, so refresh main-side facts for subsequent candidates
    # (kills the stale-`current` multi-merge window, F-13).
    if [ "$MERGED" = "1" ]; then
      current="$MERGED_VERSION"
      main_blob=$(anchor_blob_sha main) || main_blob="$main_blob"
    fi
  fi
done

echo "merged=$([ "$MERGED" = "1" ] && echo true || echo false)" >> "${GITHUB_OUTPUT:-/dev/null}"
# merged_pr_version is only truthful for a version that actually merged (F-13).
echo "merged_pr_version=${MERGED_VERSION}" >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$ESCALATION_WRITE_FAILED" = "1" ]; then
  log "ERROR: one or more escalation writes failed — exiting nonzero so the heartbeat sees a failed gate run (F-06)"
  exit 4
fi
exit 0
