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
# Release identity (2026-10-02 policy): one GitHub Release == exactly one
# (Firefox source version, port version) pair — tag v<port>-ff<firefox>.
# Different Firefox versions must NEVER share a release; the APT channel
# (port/publish_apt.sh) is the cumulative upgrade surface instead.
#
# Behavior:
#   1. Locate the deb, verify its SHA256 against the collected SHA256SUMS.
#   1b. Cross-check the deb version against (firefox_version, port_version):
#       derive the Debian lead via prepare_recipe.packaged_version() and
#       require deb name firefox_<lead>-<rev>.<port>_aarch64.deb.  This makes
#       a wrong-Firefox build uploading to another Firefox's release fail
#       closed (and rejects passing the lead, e.g. 157.1, as source version).
#   2. Ensure release tag v<port_version>-ff<firefox_version> exists (created
#      only when missing; an existing release body is NEVER edited — it may
#      be hand-written).
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

# 1b) provenance cross-check: the deb must belong to THIS (firefox, port) pair.
# FIREFOX_VERSION must be the upstream SOURCE version (157.0, 157.0.1), never
# the Debian package-version lead (157.1) — packaged_version() enforces the
# N.0 invariant and raises otherwise.
echo "$FIREFOX_VERSION" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)*$' \
  || die "firefox_version must be a dotted source version (got '$FIREFOX_VERSION')"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lead=$(cd "$SELF_DIR" && python3 -c 'import sys; from prepare_recipe import packaged_version; print(packaged_version(sys.argv[1]))' "$FIREFOX_VERSION" 2>&1) \
  || die "firefox_version '$FIREFOX_VERSION' rejected as source version: $lead"
lead_esc=$(printf '%s' "$lead" | sed 's/\./\\./g')
port_esc=$(printf '%s' "$PORT_VERSION" | sed 's/\./\\./g')
echo "$deb_name" | grep -qE "^firefox_${lead_esc}-[0-9]+\\.${port_esc}_aarch64\\.deb$" \
  || die "deb '$deb_name' does not match (firefox $FIREFOX_VERSION -> lead $lead, port $PORT_VERSION) — refusing to reconcile against the wrong release"
log "provenance: deb lead=$lead matches firefox $FIREFOX_VERSION on port $PORT_VERSION"

TAG="v${PORT_VERSION}-ff${FIREFOX_VERSION}"

# 2/3/4) release + asset reconciliation ----------------------------------------
# GET only: `gh api` defaults to POST when -f is passed (09-29 outage lesson).
# real gh prints the HTTP error BODY to stdout with exit 1 (live-verified gh
# 2.102.0, 2026-10-02): a missing release must be detected by status+body,
# never by "empty stdout"; and a 5xx/transport failure must NOT be mistaken
# for "absent" (it must fail closed, else a flaky API silently skips create).
get_release() {
  local out="" rc=0
  out=$(gh api "repos/${REPO}/releases/tags/${TAG}" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *'"status":"404"'*|*'"message":"Not Found"'*) return 0 ;;  # absent
      *) die "release lookup failed for $TAG (gh rc=$rc): ${out:-<no body>}" ;;
    esac
  fi
  printf '%s' "$out"
}

rel_json=$(get_release)

if [ -z "$rel_json" ]; then
  log "release $TAG does not exist"
  if [ "$DRY_RUN" = "true" ]; then
    log "DRY_RUN: would create release $TAG and upload $deb_name"
    exit 0
  fi
  # Validation wording is deliberately conservative: claim only what the
  # pipeline itself proves.  A device level-6 claim is added ONLY when the
  # port.toml validation ledger names exactly this (firefox, port) pair and
  # carries a well-formed source hash; ambiguity never claims device passes.
  validation="CI validated: semantic port verification PASS; AudioIPC binary gate PASS."
  device_claim=""
  if [ -f "$SELF_DIR/port.toml" ]; then
    device_claim=$(python3 - "$SELF_DIR/port.toml" "$FIREFOX_VERSION" "$PORT_VERSION" <<'PY'
import re, sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        port = tomllib.load(fh).get("port", {})
except Exception:
    sys.exit(0)
if (port.get("last_validated_firefox") == sys.argv[2]
        and port.get("last_validated_port") == sys.argv[3]
        and re.fullmatch(r"[0-9a-f]{64}", str(port.get("last_validated_srcsha256", "")))
        and str(port.get("last_validated_revision", "")) != ""):
    print(" Device level-6 validated on maintainer device per port.toml ledger"
          " (last_validated_firefox=%s, last_validated_port=%s)."
          % (port["last_validated_firefox"], port["last_validated_port"]))
PY
)
  fi
  notes=$(mktemp)
  {
    echo "Firefox **${FIREFOX_VERSION}** (upstream source) on sandbox port **${PORT_VERSION}** — this release is the immutable snapshot of exactly this (port, Firefox) pair; its deb is the only build it carries."
    echo
    echo "- package: \`${deb_name}\`  (Debian version = package-version lead \`${lead}\` + revision ending in the port version \`${PORT_VERSION}\`; the lead intentionally differs from the source version \`${FIREFOX_VERSION}\` — see port/DESIGN.md 'Release identity')"
    echo "- sha256: \`${local_digest}\`"
    echo "- termux-packages commit: \`${TERMUX_COMMIT}\`"
    echo "- build run: ${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-unknown}"
    echo "- validation: ${validation}${device_claim}"
    echo
    echo "Upgrade channel: APT (\`deb [trusted=yes arch=aarch64] https://ytoaa.github.io/termux-firefox-sandbox stable main\`) remains cumulative across Firefox versions; GitHub Releases are per-version snapshots."
  } > "$notes"
  create_args=(gh release create "$TAG" --title "Firefox ${FIREFOX_VERSION} — Sandbox Port ${PORT_VERSION}" --notes-file "$notes")
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
