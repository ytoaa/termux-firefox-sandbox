#!/usr/bin/env bash
# Publish a validated build as the repo's GitHub Release (FIX-3).
#
# Invoked by .github/workflows/firefox-sandbox.yml `release` job, which runs
# only after a fully successful build+gates.  The logic lives here so the
# stub-gh harness (port/tests/run_tests.sh) can exercise every branch —
# including the GitHub-404/POST-default classes we have already been bitten
# by — without burning an hour-long real build per iteration.
#
# Contract (fail-closed, DRY_RUN = zero writes):
#   make_release.sh <artifacts-dir> <port_version> <firefox_version> <termux_commit>
#   env: REPO (owner/name), GH_TOKEN, DRY_RUN ('true' disables all writes),
#        GIT_SHA (target commit for newly created releases)
#
# Behavior:
#   1. Locate the deb, verify its SHA256 against the collected SHA256SUMS.
#   2. Ensure release tag v<port_version> exists (created only when missing;
#      an existing release body is NEVER edited — it may be hand-written).
#   3. Ensure the deb asset exists with the exact local digest (upload only
#      when absent or digest-different; --clobber replaces the rebuild).
#   4. Read back the release from the API and assert name+size+digest match
#      before declaring success.
set -euo pipefail

ART_DIR="${1:?usage: make_release.sh <artifacts-dir> <port_version> <firefox_version> <termux_commit>}"
PORT_VERSION="${2:?}"
FIREFOX_VERSION="${3:?}"
TERMUX_COMMIT="${4:?}"
REPO="${REPO:?}"
DRY_RUN="${DRY_RUN:-false}"
GIT_SHA="${GIT_SHA:-}"

log() { echo "[make-release] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[ -d "$ART_DIR" ] || die "artifacts dir missing: $ART_DIR"

# 1) deb + digest verification ------------------------------------------------
deb=$(find "$ART_DIR" -maxdepth 1 -type f -name 'firefox_*.deb' -print -quit)
[ -n "$deb" ] || die "no firefox_*.deb in $ART_DIR (collect step broken?)"
deb_name=$(basename "$deb")
echo "$deb_name" | grep -qE '^firefox_[0-9][0-9A-Za-z.~+-]*_aarch64\.deb$' \
  || die "unexpected deb filename shape: $deb_name"
[ -f "$ART_DIR/SHA256SUMS" ] || die "SHA256SUMS missing in $ART_DIR"
( cd "$ART_DIR" && sha256sum -c SHA256SUMS >/dev/null ) \
  || die "SHA256SUMS verification FAILED for $deb_name"
local_digest=$(sha256sum "$deb" | cut -d' ' -f1)
local_size=$(stat -c%s "$deb")
log "deb: $deb_name size=$local_size sha256=${local_digest:0:16}..."

TAG="v${PORT_VERSION}"

# 2/3/4) release + asset reconciliation ----------------------------------------
# GET only: `gh api` defaults to POST when -f is passed (09-29 outage lesson).
get_release() {
  gh api "repos/${REPO}/releases/tags/${TAG}" 2>/dev/null || true
}

rel_json=$(get_release)

if [ -z "$rel_json" ]; then
  log "release $TAG does not exist"
  if [ "$DRY_RUN" = "true" ]; then
    log "DRY_RUN: would create release $TAG and upload $deb_name"
    exit 0
  fi
  notes=$(mktemp)
  {
    echo "Termux Firefox **${FIREFOX_VERSION}** on sandbox port **${PORT_VERSION}** — validated by CI (build + binary gate + diagnostics)."
    echo
    echo "- package: \`${deb_name}\`"
    echo "- sha256: \`${local_digest}\`"
    echo "- termux-packages commit: \`${TERMUX_COMMIT}\`"
    echo "- build run: ${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  } > "$notes"
  create_args=(gh release create "$TAG" --title "Termux Firefox ${FIREFOX_VERSION} (port ${PORT_VERSION})" --notes-file "$notes")
  [ -n "$GIT_SHA" ] && create_args+=(--target "$GIT_SHA")
  "${create_args[@]}" || die "gh release create failed for $TAG"
  log "created release $TAG"
elif [ "$DRY_RUN" = "true" ]; then
  log "DRY_RUN: release $TAG exists; would reconcile asset $deb_name"
  exit 0
fi

asset_state=$(gh api "repos/${REPO}/releases/tags/${TAG}" \
  --jq "[.assets[]? | select(.name==\"${deb_name}\")][0] | if . == null then \"missing\" else \"\(.size) \(.digest // \"none\")\" end") \
  || die "release read-back failed for $TAG"

case "$asset_state" in
  missing)
    log "asset $deb_name absent -> uploading"
    gh release upload "$TAG" "$deb" || die "gh release upload failed"
    ;;
  "${local_size} sha256:${local_digest}")
    log "asset $deb_name already published with identical digest -> no upload"
    ;;
  *)
    log "asset digest differs ($asset_state) -> replacing with clobber (rebuild of same port version)"
    gh release upload "$TAG" "$deb" --clobber || die "gh release upload --clobber failed"
    ;;
esac

# 4) final read-back: the published asset MUST equal the local file ----------
verify=$(gh api "repos/${REPO}/releases/tags/${TAG}" \
  --jq "[.assets[]? | select(.name==\"${deb_name}\")][0] | if . == null then \"MISSING\" else \"\(.size) \(.digest // \"none\")\" end") \
  || die "final release read-back failed"
[ "$verify" = "${local_size} sha256:${local_digest}" ] \
  || die "read-back MISMATCH: expected '$local_size sha256:$local_digest', got '$verify'"

log "RELEASE OK: $TAG asset=$deb_name size=$local_size digest=${local_digest:0:16}..."
