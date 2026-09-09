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


def bump_revision_once(text: str) -> tuple[str, int]:
    if REV_MARK in text:
        revision = read_scalar(text, "TERMUX_PKG_REVISION")
        return text, int(revision or "0")

    m = re.search(r"^TERMUX_PKG_REVISION=(\d+)\s*$", text, re.MULTILINE)
    if m:
        revision = int(m.group(1)) + 1
        replacement = f"TERMUX_PKG_REVISION={revision}\n{REV_MARK}"
        return text[: m.start()] + replacement + text[m.end() :], revision

    v = re.search(r"^TERMUX_PKG_VERSION=.*$", text, re.MULTILINE)
    if not v:
        raise RecipeError("TERMUX_PKG_VERSION not found")
    revision = 1
    insertion = f"\nTERMUX_PKG_REVISION={revision}\n{REV_MARK}"
    return text[: v.end()] + insertion + text[v.end() :], revision


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--firefox-dir", type=Path, required=True)
    ap.add_argument("--metadata", type=Path, required=True)
    args = ap.parse_args()

    here = Path(__file__).resolve().parent
    cfg = tomllib.loads((here / "port.toml").read_text())
    port_version = cfg["port"]["version"]
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
    original_revision = int(read_scalar(original, "TERMUX_PKG_REVISION") or "0")

    ensure_mozconfig(mozconfig)

    text = original
    text = ensure_dependency(text)
    text = ensure_linker_flag(text)
    text = ensure_preconfigure_hook(text)
    text, custom_revision = bump_revision_once(text)
    build.write_text(text)

    # The Termux builder mounts termux-packages, not this port repository, so
    # copy the semantic source transformer into the package builder directory.
    shutil.copy2(here / "firefox_sandbox_port.py", firefox_dir / "termux-native-sandbox-port.py")
    shutil.copy2(here / "port.toml", firefox_dir / "termux-native-sandbox-port.toml")

    candidate = version != last_validated
    metadata = {
        "port_version": port_version,
        "firefox_version": version,
        "last_validated_firefox": last_validated,
        "candidate": candidate,
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
