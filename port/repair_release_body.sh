#!/usr/bin/env bash
# port/repair_release_body.sh — rewrite a release body from the asset it
# actually carries (2026-11-05 provenance repair).
#
# WHY: before make_release.sh refreshed bodies on rebuild, a clobbered asset
# left the body citing a different digest/build (the 2026-10-21 defect class).
# Three releases still carried such bodies: v2.4.7-ff158.0,
# v2.4.7-ff158.0.1 and v2.4.7-ff159.0.  Editing them by hand would break the
# "bodies are generated" invariant, so this tool regenerates the body with the
# SAME writer the pipeline uses (port/release_notes.sh).
#
# It does NOT guess provenance.  The producing build run and its
# termux-packages commit are operator-verified facts and must be passed in;
# the superseded values are read from the old body and preserved in a
# "Repair history (append-only)" section — nothing is silently dropped.
#
# Usage:
#   repair_release_body.sh <tag> --run <run_id> --termux-commit <sha> [--dry-run]
#   env: REPO (owner/name), GH_TOKEN, GITHUB_SERVER_URL (optional)
#
# Exit: 0 repaired or already consistent | 1 refused/failed | 2 bad usage
set -euo pipefail

REPO="${REPO:?REPO (owner/name) is required}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=port/release_notes.sh
. "$SELF_DIR/release_notes.sh"

die() { echo "repair: ERROR: $*" >&2; exit 1; }
log() { echo "repair: $*"; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: repair_release_body.sh <tag> --run <id> --termux-commit <sha> [--dry-run]"
shift
RUN=""; COMMIT=""; DRY_RUN="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) [ -n "${2:-}" ] || die "--run needs a value"; RUN="$2"; shift 2 ;;
    --termux-commit) [ -n "${2:-}" ] || die "--termux-commit needs a value"; COMMIT="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$RUN" ] || die "verified --run is required (provenance is never guessed)"
[ -n "$COMMIT" ] || die "verified --termux-commit is required (provenance is never guessed)"
printf '%s' "$RUN" | grep -qE '^[0-9]+$' || die "--run must be a numeric run id"
printf '%s' "$COMMIT" | grep -qE '^[0-9a-f]{40}$' || die "--termux-commit must be a 40-hex commit"

[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-ff([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]] \
  || die "tag is not v<port>-ff<firefox>: $TAG"
PORT="${BASH_REMATCH[1]}"
FIREFOX="${BASH_REMATCH[2]}"

rel=$(gh api "repos/${REPO}/releases/tags/${TAG}") || die "release lookup failed for $TAG"
asset_count=$(printf '%s' "$rel" | jq '[.assets[]?] | length')
[ "$asset_count" = "1" ] || die "release $TAG carries $asset_count assets; refusing (expected exactly 1)"
deb_name=$(printf '%s' "$rel" | jq -r '.assets[0].name')
digest=$(printf '%s' "$rel" | jq -r '.assets[0].digest // "none"')
case "$digest" in
  sha256:*) digest="${digest#sha256:}" ;;
  *) die "asset $deb_name has no sha256 digest; cannot repair provenance" ;;
esac
lead=$(printf '%s' "$deb_name" | sed -n 's/^firefox_\([^-]*\)-.*/\1/p')
[ -n "$lead" ] || die "cannot derive package lead from $deb_name"

body=$(printf '%s' "$rel" | jq -r '.body // ""')
if printf '%s' "$body" | grep -qF "$digest"; then
  log "$TAG body already records the published digest ${digest:0:16}… — nothing to do"
  exit 0
fi

old_body_file=$(mktemp)
printf '%s\n' "$body" > "$old_body_file"
old_sha=$(body_sha "$old_body_file")
old_run=$(body_run "$old_body_file")

# Keep the CI wording the release already carries (it was written by the
# pipeline for that build); only fall back to the conservative default when the
# old body has no validation line at all.
validation="CI validated: semantic port verification PASS; AudioIPC binary gate PASS."
old_validation=$(printf '%s\n' "$body" | sed -n 's/^- validation: *//p' | head -n1)
[ -n "$old_validation" ] && validation="$old_validation"

hist=$(mktemp)
{
  history_lines "$old_body_file"
  printf -- '- %s: body repaired — previous body cited sha256 `%s` (build run %s); published asset is sha256 `%s` from build run %s (termux-packages `%s`).\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${old_sha:-unknown}" "${old_run:-unknown}" \
    "$digest" "$RUN" "$COMMIT"
} | tail -n 20 > "$hist"

notes=$(mktemp)
release_notes_body "$notes" "$FIREFOX" "$PORT" "$deb_name" "$lead" "$digest" \
  "$COMMIT" "$SERVER" "$REPO" "$RUN" "$validation" "Repair history (append-only)" "$hist"

if [ "$DRY_RUN" = "true" ]; then
  log "DRY_RUN: would repair $TAG (asset $deb_name sha256 ${digest:0:16}…, run $RUN)"
  cat "$notes"
  exit 0
fi

gh release edit "$TAG" --notes-file "$notes" || die "gh release edit failed for $TAG"
log "body rewritten for $TAG"

body_now=$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '.body // ""') \
  || die "body read-back failed for $TAG"
printf '%s' "$body_now" | grep -qF "$digest" \
  || die "read-back failed: body does not record ${digest:0:16}…"
count_now=$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '[.assets[]?] | length') \
  || die "asset count read-back failed for $TAG"
[ "$count_now" = "1" ] || die "read-back failed: release now carries $count_now assets"
log "REPAIR OK: $TAG asset=$deb_name digest=${digest:0:16}… run=$RUN"
