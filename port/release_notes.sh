#!/usr/bin/env bash
# port/release_notes.sh — single source of truth for GitHub Release body text.
#
# Sourced by port/make_release.sh (create + body refresh) and by
# port/repair_release_body.sh (after-the-fact provenance repair).  One writer
# is the point: two copies of this template is exactly how the body and the
# asset drifted apart on 2026-10-21 (the body kept citing the previous build
# while --clobber replaced the deb).
#
# release_notes_body <out> <firefox> <port> <deb> <lead> <digest> \
#   <termux_commit> <server> <repo> <run_id> <validation> \
#   [section_title] [section_file]
#
# The optional section is appended only when both a title and a non-empty file
# are given, so create/refresh ("Rebuild history") and repair ("Repair
# history") share every other line byte-for-byte.
release_notes_body() {
  local out="$1" firefox="$2" port="$3" deb="$4" lead="$5" digest="$6"
  local commit="$7" server="$8" repo="$9" run="${10}" validation="${11}"
  local title="${12:-}" extra="${13:-}"
  {
    echo "Firefox **${firefox}** (upstream source) on sandbox port **${port}** — this release is the versioned identity snapshot for exactly this (port, Firefox) pair; its deb is the only build it carries."
    echo
    echo "- package: \`${deb}\`  (Debian version = package-version lead \`${lead}\` + revision ending in the port version \`${port}\`; the lead intentionally differs from the source version \`${firefox}\` — see port/DESIGN.md 'Release identity')"
    echo "- sha256: \`${digest}\`"
    echo "- termux-packages commit: \`${commit}\`"
    echo "- build run: ${server}/${repo}/actions/runs/${run}"
    echo "- validation: ${validation}"
    echo
    echo "Upgrade channel: APT (\`deb [trusted=yes arch=aarch64] https://ytoaa.github.io/termux-firefox-sandbox stable main\`) remains cumulative across Firefox versions; GitHub Releases are per-version snapshots."
  } > "$out"
  if [ -n "$title" ] && [ -n "$extra" ] && [ -s "$extra" ]; then
    {
      echo
      echo "## ${title}"
      echo
      cat "$extra"
    } >> "$out"
  fi
}

# Provenance parsers — the previous body is the only memory of what it cited,
# so both the refresh and repair paths read it back from the body itself.
body_sha() { sed -n 's/^- sha256: `\([0-9a-f]\{64\}\)`.*/\1/p' "$1" | head -n1; }
body_run() { sed -n 's|^- build run: .*/runs/\([0-9][0-9]*\).*|\1|p' "$1" | head -n1; }
history_lines() { awk '/^## (Rebuild|Repair) history/{f=1;next} f' "$1" | sed '/^[[:space:]]*$/d'; }
