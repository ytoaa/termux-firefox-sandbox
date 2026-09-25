#!/usr/bin/env python3
"""Prepare the upstream Termux Firefox recipe for the native sandbox port.

Only recipe-level concerns live here. Firefox source edits are delegated to
firefox_sandbox_port.py at termux_step_pre_configure time, after normal Termux
patches have been applied.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tomllib
from pathlib import Path

MARK_BEGIN = "\t# BEGIN termux-firefox-sandbox semantic port"
MARK_END = "\t# END termux-firefox-sandbox semantic port"
REV_MARK = "# termux-firefox-sandbox: custom package revision applied"


class RecipeError(RuntimeError):
    pass


def replace_exact_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RecipeError(f"{label}: expected exactly one old form, found {count}")
    return text.replace(old, new, 1)


def read_scalar(text: str, key: str) -> str | None:
    m = re.search(rf'^{re.escape(key)}=(?:"([^"]*)"|([^\s#]+))\s*$', text, re.MULTILINE)
    if not m:
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def ensure_mozconfig(path: Path) -> None:
    text = path.read_text()
    if "ac_add_options --enable-sandbox" not in text:
        text = replace_exact_once(
            text,
            "ac_add_options --disable-sandbox",
            "ac_add_options --enable-sandbox",
            "sandbox configure option",
        )
    if "ac_add_options --disable-sandbox" in text:
        raise RecipeError("mozconfig still contains --disable-sandbox")
    for line in (
        "ac_add_options --disable-forkserver",
        "ac_add_options --with-ccache=sccache",
    ):
        if line not in text:
            text = text.rstrip() + "\n" + line + "\n"
    path.write_text(text)


def ensure_dependency(text: str) -> str:
    m = re.search(r'^TERMUX_PKG_DEPENDS="([^"]*)"$', text, re.MULTILINE)
    if not m:
        raise RecipeError("TERMUX_PKG_DEPENDS not found")
    deps = [x.strip() for x in m.group(1).split(",") if x.strip()]
    if "libandroid-glob" not in deps:
        try:
            pos = deps.index("libandroid-shmem") + 1
        except ValueError:
            pos = len(deps)
        deps.insert(pos, "libandroid-glob")
        new_line = 'TERMUX_PKG_DEPENDS="' + ", ".join(deps) + '"'
        text = text[: m.start()] + new_line + text[m.end() :]
    return text


def ensure_linker_flag(text: str) -> str:
    if "-landroid-glob" in text:
        return text
    # Be tolerant of nearby Termux changes: locate the one LDFLAGS line that
    # already links android-shmem and android-spawn, then add glob beside them.
    lines = text.splitlines(keepends=True)
    hits = [i for i, line in enumerate(lines) if "LDFLAGS+=" in line and "-landroid-shmem" in line and "-landroid-spawn" in line]
    if len(hits) != 1:
        raise RecipeError(f"Firefox Android LDFLAGS anchor count is {len(hits)}, expected 1")
    i = hits[0]
    lines[i] = lines[i].replace("-landroid-spawn", "-landroid-spawn -landroid-glob", 1)
    return "".join(lines)


def ensure_preconfigure_hook(text: str) -> str:
    block = (
        f"{MARK_BEGIN}\n"
        "\tpython3 \"$TERMUX_PKG_BUILDER_DIR/termux-native-sandbox-port.py\" apply \\\n"
        "\t\t--src \"$TERMUX_PKG_SRCDIR\" \\\n"
        "\t\t--prefix \"$TERMUX_PREFIX\" \\\n"
        "\t\t--report \"$TERMUX_PKG_TMPDIR/firefox-native-sandbox-port-report.json\" \\\n"
        "\t\t--patch \"$TERMUX_PKG_TMPDIR/firefox-native-sandbox.generated.patch\"\n"
        f"{MARK_END}\n"
    )
    if MARK_BEGIN in text or MARK_END in text:
        if text.count(MARK_BEGIN) != 1 or text.count(MARK_END) != 1:
            raise RecipeError("partial/duplicated semantic-port preconfigure marker")
        return text

    fn = "termux_step_pre_configure() {\n"
    if text.count(fn) != 1:
        raise RecipeError("termux_step_pre_configure function anchor changed")
    return text.replace(fn, fn + block, 1)


def bump_revision_once(text: str, port_version: str) -> tuple[str, str]:
    """Compose the Debian revision as <upstream_rev+1>.<port_version>.

    The port_version suffix makes same-source port rebuilds apt-visible
    (156.1.1-1.2.4.6 -> 156.1.1-1.2.4.7 is a real upgrade).  Re-runs over an
    already-prepared recipe rewrite only the suffix, keeping the +1 base.
    """
    m = re.search(r"^TERMUX_PKG_REVISION=(\d+)(?:\.\d+(?:\.\d+)*)?\s*$", text, re.MULTILINE)
    if REV_MARK in text:
        if not m:
            raise RecipeError("prepared recipe has unreadable TERMUX_PKG_REVISION")
        revision = f"{int(m.group(1))}.{port_version}"
        return text[: m.start()] + f"TERMUX_PKG_REVISION={revision}" + text[m.end():], revision
    if m:
        revision = f"{int(m.group(1)) + 1}.{port_version}"
        replacement = f"TERMUX_PKG_REVISION={revision}\n{REV_MARK}"
        return text[: m.start()] + replacement + text[m.end():], revision

    v = re.search(r"^TERMUX_PKG_VERSION=.*$", text, re.MULTILINE)
    if not v:
        raise RecipeError("TERMUX_PKG_VERSION not found")
    revision = f"1.{port_version}"
    insertion = f"\nTERMUX_PKG_REVISION={revision}\n{REV_MARK}"
    return text[: v.end()] + insertion + text[v.end():], revision


# Debian-ordered package version lead over the Termux channel package.
#
# Motivation: with equal versions, `pkg upgrade firefox` on a device that has
# our sandbox deb installed can silently replace it with Termux's official
# sandbox-off build whenever Termux bumps its version.  Publishing our deb
# strictly above every same-series Termux release keeps the sandboxed browser
# installed until an explicit port rebuild changes it.
#
# Scheme (decision B, 2026-09-25): source `M.m.p` publishes as `M.(m+1).p`,
# with the trailing `.0` patch dropped.  156.0 -> 156.1, 156.0.1 -> 156.1.1.
# Carrying the real patch segment makes Firefox dot releases (which carry
# security fixes) *upgrade-visible* under apt across our own builds, while the
# +1 minor lead still strictly outranks every Termux channel build of the same
# major series.  Verified 2026-09-16 against archive.mozilla.org (167 rapid
# releases, all N.0[.k]) that Firefox >= 100 never ships a second segment != 0
# nor a real N.1, so the lead space is collision-free; ci.sh re-checks that
# invariant fail-closed at every gate run.  On a new major the gate rebuilds
# and the lead moves to the next <major>.1.
def packaged_version(source_version: str) -> str:
    parts = source_version.split(".")
    if len(parts) not in (2, 3) or not all(p.isdigit() for p in parts):
        raise RecipeError(f"cannot derive packaged version from {source_version!r}")
    major, minor = parts[0], int(parts[1])
    patch = int(parts[2]) if len(parts) == 3 else 0
    lead = f"{major}.{minor + 1}"
    return lead if patch == 0 else f"{lead}.{patch}"


def raise_package_version(text: str, source_version: str) -> str:
    """Pin the source URL to the real version, then publish at <major>.1."""
    target = packaged_version(source_version)
    old_line = re.search(r'^TERMUX_PKG_VERSION=(?:"([^"]*)"|([^\s#]+))\s*$', text, re.MULTILINE)
    if not old_line:
        raise RecipeError("TERMUX_PKG_VERSION line not found for version lead")
    current = old_line.group(1) or old_line.group(2)
    if current == target:
        return text  # idempotent
    # The Termux SRCURL interpolates ${TERMUX_PKG_VERSION#*really}; materialize
    # it against the real source version BEFORE raising the published version.
    def materialize(m: re.Match) -> str:
        return m.group(0).replace("${TERMUX_PKG_VERSION#*really}", source_version)

    text = re.sub(r'^TERMUX_PKG_SRCURL=.*$', materialize, text, count=1, flags=re.MULTILINE)
    if source_version not in text:
        raise RecipeError("SRCURL did not materialize to the real source version")
    text = text[: old_line.start()] + f'TERMUX_PKG_VERSION="{target}"' + text[old_line.end():]
    return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--firefox-dir", type=Path, required=True)
    ap.add_argument("--metadata", type=Path, required=True)
    args = ap.parse_args()

    here = Path(__file__).resolve().parent
    cfg = tomllib.loads((here / "port.toml").read_text())
    port_version = cfg["port"]["version"]
    if not re.fullmatch(r"\d+(\.\d+)*", str(port_version)):
        raise RecipeError(
            f"port.version {port_version!r} must be dot-separated numbers: Debian splits the"
            " version at the LAST hyphen, so an rc suffix would rank ABOVE the final build"
            " (keep -rcN only in git tags)"
        )
    last_validated_port = cfg["port"].get("last_validated_port", port_version)
    last_validated = cfg["port"]["last_validated_firefox"]

    firefox_dir = args.firefox_dir.resolve()
    build = firefox_dir / "build.sh"
    mozconfig = firefox_dir / "mozconfig.cfg"
    if not build.is_file() or not mozconfig.is_file():
        raise RecipeError(f"not a Termux Firefox package directory: {firefox_dir}")

    original = build.read_text()
    version = read_scalar(original, "TERMUX_PKG_VERSION")
    if not version:
        raise RecipeError("could not parse TERMUX_PKG_VERSION")
    # On re-runs over an already-prepared recipe, the published VERSION is the
    # lead `M.1[.p]` (packaged_version of the true source).  Firefox >= 100
    # never releases a real N.1 (verified against the full archive; ci.sh
    # enforces the invariant fail-closed), so this form is unambiguous:
    # recover the true source version from the materialized SRCURL instead of
    # misreading the lead.
    if REV_MARK in original and re.fullmatch(r"\d+\.1(?:\.\d+)?", version):
        m = re.search(r"/releases/([^/]+)/source/", read_scalar(original, "TERMUX_PKG_SRCURL") or "")
        if not m:
            raise RecipeError("prepared recipe lacks a materialized source URL to recover the true version")
        version = m.group(1)
    # Termux omits TERMUX_PKG_REVISION when it is 0.  On re-runs the line holds
    # our composed "<base>.<port_version>" where base = upstream_rev + 1, so
    # recover the upstream value by stripping the suffix and the +1.
    rev_raw = read_scalar(original, "TERMUX_PKG_REVISION") or "0"
    rev_m = re.match(r"(\d+)", rev_raw)
    if not rev_m:
        raise RecipeError(f"unparsable TERMUX_PKG_REVISION {rev_raw!r}")
    original_revision = int(rev_m.group(1)) - (1 if REV_MARK in original else 0)

    ensure_mozconfig(mozconfig)

    text = original
    text = ensure_dependency(text)
    text = ensure_linker_flag(text)
    text = ensure_preconfigure_hook(text)
    text, custom_revision = bump_revision_once(text, port_version)
    # Publish at `M.(m+1).p` so our deb strictly outranks Termux channel builds
    # of the same series while dot drift stays upgrade-visible (see
    # packaged_version rationale above).
    text = raise_package_version(text, version)
    build.write_text(text)

    # The Termux builder mounts termux-packages, not this port repository, so
    # copy the semantic source transformer into the package builder directory.
    shutil.copy2(here / "firefox_sandbox_port.py", firefox_dir / "termux-native-sandbox-port.py")
    shutil.copy2(here / "port.toml", firefox_dir / "termux-native-sandbox-port.toml")

    candidate_reasons = []
    if version != last_validated:
        candidate_reasons.append("firefox-version")
    if port_version != last_validated_port:
        candidate_reasons.append("port-version")
    candidate = bool(candidate_reasons)
    metadata = {
        "port_version": port_version,
        "last_validated_port": last_validated_port,
        "firefox_version": version,
        "packaged_version": packaged_version(version),
        "last_validated_firefox": last_validated,
        "candidate": candidate,
        "candidate_reasons": candidate_reasons,
        "original_revision": original_revision,
        "custom_revision": custom_revision,
        "termux_source_url_template": read_scalar(original, "TERMUX_PKG_SRCURL"),
        "termux_source_sha256": read_scalar(original, "TERMUX_PKG_SHA256"),
        "policy_mode": cfg["port"]["policy_mode"],
    }
    args.metadata.parent.mkdir(parents=True, exist_ok=True)
    args.metadata.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")

    # Final recipe contract.
    final_build = build.read_text()
    final_moz = mozconfig.read_text()
    for token in (
        "libandroid-glob",
        "-landroid-glob",
        MARK_BEGIN,
        MARK_END,
        "termux-native-sandbox-port.py\" apply",
        REV_MARK,
    ):
        if token not in final_build:
            raise RecipeError(f"recipe verification missing {token!r}")
    # Version lead contract: published version at `M.(m+1).p`, source URL pinned
    # to the real source version (no unexpanded template referencing VERSION).
    if read_scalar(final_build, "TERMUX_PKG_VERSION") != packaged_version(version):
        raise RecipeError("package version lead not applied")
    if "${TERMUX_PKG_VERSION" in (read_scalar(final_build, "TERMUX_PKG_SRCURL") or ""):
        raise RecipeError("SRCURL still interpolates TERMUX_PKG_VERSION after materialization")
    for token in (
        "ac_add_options --enable-sandbox",
        "ac_add_options --disable-forkserver",
        "ac_add_options --with-ccache=sccache",
    ):
        if token not in final_moz:
            raise RecipeError(f"mozconfig verification missing {token!r}")
    if "ac_add_options --disable-sandbox" in final_moz:
        raise RecipeError("mozconfig verification found --disable-sandbox")

    print(json.dumps(metadata, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RecipeError as exc:
        print(f"RECIPE ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
