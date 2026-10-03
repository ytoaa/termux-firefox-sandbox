#!/usr/bin/env bash
# port/watcher_assert.sh — Renovate-watcher outcome assertion (I-9 class catcher).
#
# WHY: the 10-02 incident class was a GREEN no-op — the repo
# 'GitHub Actions is not permitted to create or approve pull requests' toggle
# 403'd every POST /pulls, Renovate logged it only at DEBUG and exited 0, so
# the watcher reported success for days while the pipeline was mission-failing.
# Exit-code-as-health-signal is structurally blind to that class (panel ruling
# (a), GITHUB_DEFECT_OR_LIMIT ledger line 6b = RENOVATE_DEFECT).
#
# CONTRACT (outcome-based, not process-based): after every real watcher run,
#   anchor == live            -> nothing expected; pass
#   anchor != live            -> an OPEN renovate/* bump PR MUST exist; if it
#                               does not, PR creation was silently lost -> FAIL
# Any evaluation itself failing (fetch/query error) also FAILS closed: an
# unevaluated check must never read as green.
#
# Env: GITHUB_REPOSITORY (required), DRY (skip when non-empty & not 'null'),
#      ANCHOR_FILE (default port/upstream.renovate), LIVE_FILE (default: fetch
#      the live termux recipe), LIVE_URL override for the fetch.
# Exit: 0 outcome consistent | 1 assertion FAILED (report red) | 2 unevaluable
#       (fail-closed, also report red — distinct code for forensics).
set -uo pipefail

ANCHOR_FILE="${ANCHOR_FILE:-port/upstream.renovate}"
LIVE_URL="${LIVE_URL:-https://raw.githubusercontent.com/termux/termux-packages/master/x11-packages/firefox/build.sh}"

if [ -n "${DRY:-}" ] && [ "${DRY}" != "null" ]; then
  echo "watcher-assert: skipped (dry-run dispatch: dry_run=${DRY})"
  exit 0
fi

[ -n "${GITHUB_REPOSITORY:-}" ] || { echo "::error::watcher-assert: GITHUB_REPOSITORY missing"; exit 2; }

anchor=$(sed -n 's/^termuxFirefoxVersion[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$ANCHOR_FILE" 2>/dev/null | head -1)
[ -n "$anchor" ] || { echo "::error::watcher-assert: anchor parse FAILED ($ANCHOR_FILE)"; exit 2; }

if [ -n "${LIVE_FILE:-}" ]; then
  live_src=$(cat "$LIVE_FILE" 2>/dev/null) || { echo "::error::watcher-assert: LIVE_FILE read FAILED"; exit 2; }
else
  live_src=$(curl -fsS --max-time 30 "$LIVE_URL") || { echo "::error::watcher-assert: live recipe fetch FAILED"; exit 2; }
fi
live=$(printf '%s\n' "$live_src" | sed -n 's/^TERMUX_PKG_VERSION="\([0-9][0-9.]*\)".*/\1/p' | head -1)
[ -n "$live" ] || { echo "::error::watcher-assert: live recipe parse FAILED"; exit 2; }

if [ "$anchor" = "$live" ]; then
  echo "watcher-assert: anchor == live ($anchor) — no bump PR expected"
  exit 0
fi

echo "watcher-assert: anchor ($anchor) != live ($live) — an OPEN renovate bump PR is REQUIRED"
# `gh pr list --json` exposes the head branch name as the FLAT field
# `headRefName` (cli/cli's pullRequest struct; there is NO `head.ref` in its
# --json vocabulary — live-verified 10-02 against real gh 2.102.0: the old
# `--json head.ref` form dies with "Unknown JSON field").  The earlier form
# only ever "passed" because the test-stub gh accepted arbitrary fields;
# against real gh it is a query failure (fail-closed red, never green).
# Pattern is anchored to OUR bump branch family (^renovate/termux-firefox-
# upstream-), NOT any renovate/* PR: an unrelated renovate PR (e.g. an
# Actions pin bump) must never mask a lost bump PR.
prs=$(gh pr list --repo "$GITHUB_REPOSITORY" --state open \
        --json number,headRefName 2>&1) \
  || { echo "::error::watcher-assert: open-PR query FAILED: $prs"; exit 2; }
n=$(printf '%s' "$prs" | jq '[.[] | select(.headRefName | test("^renovate/termux-firefox-upstream-"))] | length' 2>/dev/null)
if ! printf '%s' "${n:-}" | grep -qE '^[0-9]+$'; then
  echo "::error::watcher-assert: PR query result unparseable (not a number) — fail closed, not green"
  exit 2
fi
if [ "$n" -ge 1 ]; then
  echo "watcher-assert: $n open renovate bump PR(s) — outcome OK"
  exit 0
fi
echo "::error::watcher-assert: anchor!=live and NO open renovate bump PR — Renovate likely failed PR-creation (top suspect: repo Actions 'create and approve pull requests' toggle is OFF; see the DEBUG-only 403 in the job log). Turn the toggle on or open the PR manually from the Renovate branch."
exit 1
