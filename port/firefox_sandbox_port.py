#!/usr/bin/env python3
"""Semantic Termux/Bionic port layer for Firefox's Linux sandbox.

This script runs after the normal Termux Firefox patches have been applied and
before Firefox is configured.  It intentionally edits by C++ symbol/scope and
stable semantic anchors instead of patch line numbers.

Commands are idempotent:
  apply  - add the Termux compatibility layer, then verify it
  verify - verify the already-applied layer without changing files

The contract is fail-closed: a changed upstream shape that cannot be identified
unambiguously stops the build instead of broadening the sandbox automatically.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
import tomllib
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

def load_port_config() -> dict:
    here = Path(__file__).resolve().parent
    for name in ("port.toml", "termux-native-sandbox-port.toml"):
        cfg = here / name
        if cfg.is_file():
            return tomllib.loads(cfg.read_text())
    return {
        "port": {"version": "unknown"},
        "compatibility": {
            "runtime_policy_scopes": ["Content", "RDD", "Socket", "Utility"],
            "runtime_read_subdirs": ["lib", "etc", "share"],
            "content_android_read_paths": ["/system/fonts"],
        },
    }


PORT_CONFIG = load_port_config()
PORT_VERSION = str(PORT_CONFIG["port"]["version"])

FILTER = Path("security/sandbox/linux/SandboxFilter.cpp")
BROKER = Path("security/sandbox/linux/broker/SandboxBrokerPolicyFactory.cpp")
SANDBOX = Path("security/sandbox/linux/Sandbox.cpp")
REPORTER = Path("security/sandbox/linux/reporter/SandboxReporterCommon.h")
LOCK = Path("security/sandbox/chromium/base/synchronization/lock_impl_posix.cc")
SHMEM = Path("ipc/glue/SharedMemoryPlatform_posix.cpp")


class PortError(RuntimeError):
    pass


@dataclass
class Change:
    name: str
    path: str
    status: str
    detail: str = ""


class Port:
    def __init__(self, root: Path, prefix: str) -> None:
        self.root = root.resolve()
        self.prefix = prefix.rstrip("/")
        if not self.prefix.startswith("/"):
            raise PortError("--prefix must be an absolute path")
        compat = PORT_CONFIG["compatibility"]
        self.runtime_policy_scopes = list(compat["runtime_policy_scopes"])
        self.runtime_read_subdirs = list(compat["runtime_read_subdirs"])
        self.content_android_read_paths = list(compat["content_android_read_paths"])
        self.changes: list[Change] = []
        self.before_sha: dict[str, str] = {}
        self.after_sha: dict[str, str] = {}
        self.before_text: dict[str, str] = {}

    def p(self, rel: Path) -> Path:
        path = self.root / rel
        if not path.is_file():
            raise PortError(f"required source file missing: {rel}")
        return path

    @staticmethod
    def sha(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def remember_before(self, rel: Path) -> None:
        key = str(rel)
        path = self.p(rel)
        self.before_sha.setdefault(key, self.sha(path))
        self.before_text.setdefault(key, path.read_text())

    def remember_after(self, rel: Path) -> None:
        self.after_sha[str(rel)] = self.sha(self.p(rel))

    def record(self, name: str, rel: Path, status: str, detail: str = "") -> None:
        self.changes.append(Change(name, str(rel), status, detail))
        print(f"[{status:>15}] {name}: {detail}".rstrip())

    @staticmethod
    def _code_brace_match(text: str, open_pos: int) -> int:
        """Return matching } while ignoring braces in strings/comments."""
        if open_pos < 0 or text[open_pos] != "{":
            raise PortError("internal error: brace matcher needs an opening brace")
        depth = 0
        i = open_pos
        state = "code"
        quote = ""
        while i < len(text):
            c = text[i]
            n = text[i + 1] if i + 1 < len(text) else ""
            if state == "code":
                if c == "/" and n == "/":
                    state = "line_comment"
                    i += 2
                    continue
                if c == "/" and n == "*":
                    state = "block_comment"
                    i += 2
                    continue
                if c in ('"', "'"):
                    quote = c
                    state = "string"
                    i += 1
                    continue
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        return i
                i += 1
                continue
            if state == "line_comment":
                if c == "\n":
                    state = "code"
                i += 1
                continue
            if state == "block_comment":
                if c == "*" and n == "/":
                    state = "code"
                    i += 2
                else:
                    i += 1
                continue
            if state == "string":
                if c == "\\":
                    i += 2
                    continue
                if c == quote:
                    state = "code"
                i += 1
                continue
        raise PortError("unbalanced C++ scope while locating semantic anchor")

    @classmethod
    def scope_bounds(cls, text: str, needle: str, label: str) -> tuple[int, int]:
        count = text.count(needle)
        if count != 1:
            raise PortError(f"{label}: expected exactly one scope anchor {needle!r}, found {count}")
        start = text.index(needle)
        open_pos = text.find("{", start + len(needle))
        if open_pos < 0:
            raise PortError(f"{label}: opening brace not found")
        close_pos = cls._code_brace_match(text, open_pos)
        return start, close_pos + 1

    def replace_once(self, rel: Path, name: str, old: str, new: str) -> None:
        path = self.p(rel)
        self.remember_before(rel)
        text = path.read_text()
        if new in text:
            self.record(name, rel, "ALREADY_PRESENT")
            return
        count = text.count(old)
        if count != 1:
            raise PortError(f"{name}: expected exactly one old form, found {count}")
        path.write_text(text.replace(old, new, 1))
        self.record(name, rel, "APPLIED")
        self.remember_after(rel)

    def mutate_scope(
        self,
        rel: Path,
        scope_needle: str,
        name: str,
        mutator: Callable[[str], tuple[str, str]],
    ) -> None:
        path = self.p(rel)
        self.remember_before(rel)
        text = path.read_text()
        start, end = self.scope_bounds(text, scope_needle, name)
        original = text[start:end]
        changed, status = mutator(original)
        if status not in {"APPLIED", "ALREADY_PRESENT"}:
            raise PortError(f"{name}: invalid mutator status {status}")
        if status == "APPLIED":
            path.write_text(text[:start] + changed + text[end:])
            self.remember_after(rel)
        self.record(name, rel, status)

    @staticmethod
    def _insert_after_once(text: str, anchor: str, addition: str, label: str) -> str:
        count = text.count(anchor)
        if count != 1:
            raise PortError(f"{label}: expected one insertion anchor, found {count}")
        return text.replace(anchor, anchor + addition, 1)

    @staticmethod
    def _insert_before_once(text: str, anchor: str, addition: str, label: str) -> str:
        count = text.count(anchor)
        if count != 1:
            raise PortError(f"{label}: expected one insertion anchor, found {count}")
        return text.replace(anchor, addition + anchor, 1)

    # ------------------------------------------------------------------
    # Simple source adaptations
    # ------------------------------------------------------------------
    def patch_reporter(self) -> None:
        self.replace_once(
            REPORTER,
            "sandbox reporter time_t include",
            '#include <sys/types.h>\n',
            '#include <time.h>\n#include <sys/types.h>\n',
        )

    def patch_priority_inheritance(self) -> None:
        self.replace_once(
            LOCK,
            "disable PI mutexes on Termux",
            '#if BUILDFLAG(IS_FUCHSIA)\n#define PRIORITY_INHERITANCE_LOCKS_POSSIBLE() 0',
            '#if BUILDFLAG(IS_FUCHSIA) || defined(__TERMUX__)\n#define PRIORITY_INHERITANCE_LOCKS_POSSIBLE() 0',
        )

    def patch_glibc_lazy_init(self) -> None:
        path = self.p(SANDBOX)
        self.remember_before(SANDBOX)
        text = path.read_text()
        marker = "#if !defined(__TERMUX__)\nstatic void RunGlibcLazyInitializers()"
        if marker in text and "#if !defined(__TERMUX__)\n  RunGlibcLazyInitializers();\n#endif" in text:
            self.record("skip glibc shm lazy init on Bionic", SANDBOX, "ALREADY_PRESENT")
            return
        fn_needle = "static void RunGlibcLazyInitializers()"
        start, end = self.scope_bounds(text, fn_needle, "RunGlibcLazyInitializers")
        fn = text[start:end]
        wrapped = "#if !defined(__TERMUX__)\n" + fn + "\n#endif"
        text = text[:start] + wrapped + text[end:]
        call = "  RunGlibcLazyInitializers();"
        if text.count(call) != 1:
            raise PortError("SandboxLateInit: expected exactly one glibc lazy-init call")
        text = text.replace(call, "#if !defined(__TERMUX__)\n" + call + "\n#endif", 1)
        path.write_text(text)
        self.remember_after(SANDBOX)
        self.record("skip glibc shm lazy init on Bionic", SANDBOX, "APPLIED")

    # ------------------------------------------------------------------
    # Broker policy adaptations
    # ------------------------------------------------------------------
    def patch_broker(self) -> None:
        rel = BROKER
        path = self.p(rel)
        self.remember_before(rel)
        text = path.read_text()
        changed = False

        # POSIX shm lives in $PREFIX/tmp in the Termux Firefox package.
        termux_shm = f'#if defined(__TERMUX__)\n  std::string shmPath("{self.prefix}/tmp");\n#else\n  std::string shmPath("/dev/shm");\n#endif'
        if termux_shm not in text:
            old = '  std::string shmPath("/dev/shm");'
            if text.count(old) != 1:
                raise PortError("AddSharedMemoryPaths: /dev/shm anchor changed")
            text = text.replace(old, termux_shm, 1)
            changed = True
            self.record("Termux POSIX shm broker root", rel, "APPLIED")
        else:
            self.record("Termux POSIX shm broker root", rel, "ALREADY_PRESENT")

        # Central runtime mapping.  All Linux process policies that rely on
        # /usr/lib,/etc,/usr/share call this one helper on Termux.
        runtime_lines = "".join(
            f'  aPolicy->AddTree(rdonly, "{self.prefix}/{leaf}");\n'
            for leaf in self.runtime_read_subdirs
        )
        helper = (
            "#if defined(__TERMUX__)\n"
            "static void AddTermuxRuntimeReadPaths(SandboxBroker::Policy* aPolicy) {\n"
            + runtime_lines
            + "}\n"
            "#endif\n\n"
        )
        if "static void AddTermuxRuntimeReadPaths" not in text:
            _, mem_end = self.scope_bounds(text, "static void AddMemoryReporting", "AddMemoryReporting")
            insert_at = mem_end
            text = text[:insert_at] + "\n\n" + helper.rstrip("\n") + text[insert_at:]
            changed = True
            self.record("central Termux runtime read-path helper", rel, "APPLIED")
        else:
            for leaf in self.runtime_read_subdirs:
                expected = f'"{self.prefix}/{leaf}"'
                if expected not in text:
                    raise PortError(f"AddTermuxRuntimeReadPaths is partial: missing {expected}")
            self.record("central Termux runtime read-path helper", rel, "ALREADY_PRESENT")

        # Centralize glibc ld.so.conf behavior.  The function remains compiled
        # for now (to avoid simultaneously removing libandroid-glob),
        # but every caller automatically becomes a no-op on Bionic.
        ld_start, ld_end = self.scope_bounds(text, "static void AddLdconfigPaths", "AddLdconfigPaths")
        ld_scope = text[ld_start:ld_end]
        guard = "#if defined(__TERMUX__)\n  return;\n#endif\n"
        if guard not in ld_scope:
            brace = ld_scope.find("{")
            if brace < 0:
                raise PortError("AddLdconfigPaths: malformed function")
            ld_scope = ld_scope[: brace + 1] + "\n" + guard + ld_scope[brace + 1 :]
            text = text[:ld_start] + ld_scope + text[ld_end:]
            changed = True
            self.record("Bionic ldconfig global no-op", rel, "APPLIED")
        else:
            self.record("Bionic ldconfig global no-op", rel, "ALREADY_PRESENT")

        # Add process-scoped calls using stable function declarations rather
        # than relying on the location/order of upstream /usr paths.
        targets = [
            ("void SandboxBrokerPolicyFactory::InitContentPolicy()", "  SandboxBroker::Policy* policy = new SandboxBroker::Policy;", True, "Content"),
            ("SandboxBrokerPolicyFactory::GetRDDPolicy(int aPid)", "  auto policy = MakeUnique<SandboxBroker::Policy>();", False, "RDD"),
            ("SandboxBrokerPolicyFactory::GetSocketProcessPolicy(int aPid)", "  auto policy = MakeUnique<SandboxBroker::Policy>();", False, "Socket"),
            ("SandboxBrokerPolicyFactory::GetUtilityProcessPolicy(int aPid)", "  auto policy = MakeUnique<SandboxBroker::Policy>();", False, "Utility"),
        ]
        for needle, policy_anchor, is_content, label in targets:
            start, end = self.scope_bounds(text, needle, f"{label} broker policy")
            scope = text[start:end]
            call = "  AddTermuxRuntimeReadPaths(policy);" if is_content else "  AddTermuxRuntimeReadPaths(policy.get());"
            block_lines = ["#if defined(__TERMUX__)", call]
            if is_content:
                for android_path in self.content_android_read_paths:
                    line = f'  policy->AddTree(rdonly, "{android_path}");'
                    if line not in scope:
                        block_lines.append(line)
            block_lines.append("#endif")
            block = "\n".join(block_lines) + "\n"
            if call not in scope:
                if scope.count(policy_anchor) != 1:
                    raise PortError(f"{label}: policy construction anchor changed")
                scope = scope.replace(policy_anchor, policy_anchor + "\n\n" + block, 1)
                text = text[:start] + scope + text[end:]
                changed = True
                self.record(f"{label} Termux runtime mapping", rel, "APPLIED")
            else:
                if is_content:
                    for android_path in self.content_android_read_paths:
                        line = f'policy->AddTree(rdonly, "{android_path}");'
                        if line not in scope:
                            raise PortError(f"Content runtime mapping exists but {android_path} is missing")
                self.record(f"{label} Termux runtime mapping", rel, "ALREADY_PRESENT")

        # Utility/Bionic reads these exact own-process proc files.  Never open a
        # /proc tree or prefix here.
        util_needle = "SandboxBrokerPolicyFactory::GetUtilityProcessPolicy(int aPid)"
        ustart, uend = self.scope_bounds(text, util_needle, "Utility broker proc policy")
        utility = text[ustart:uend]
        stat_line = '  policy->AddPath(rdonly, nsPrintfCString("/proc/%d/stat", aPid).get());'
        maps_line = '  policy->AddPath(rdonly, nsPrintfCString("/proc/%d/maps", aPid).get());'
        has_stat = stat_line in utility
        has_maps = maps_line in utility
        if has_stat != has_maps:
            raise PortError("Utility broker: partial stat/maps policy")
        if not has_stat:
            exe = '  policy->AddPath(rdonly, nsPrintfCString("/proc/%d/exe", aPid).get());'
            if utility.count(exe) != 1:
                raise PortError("Utility broker: /proc/%d/exe anchor changed")
            block = "#if defined(__TERMUX__)\n" + stat_line + "\n" + maps_line + "\n#endif\n"
            utility = utility.replace(exe, exe + "\n" + block.rstrip("\n"), 1)
            text = text[:ustart] + utility + text[uend:]
            changed = True
            self.record("Utility exact own stat/maps paths", rel, "APPLIED")
        else:
            self.record("Utility exact own stat/maps paths", rel, "ALREADY_PRESENT")

        if changed:
            path.write_text(text)
            self.remember_after(rel)

    # ------------------------------------------------------------------
    # Seccomp filter adaptations
    # ------------------------------------------------------------------
    def _patch_prctl_scope(self, class_scope: str, label: str) -> tuple[str, bool]:
        marker = "ResultExpr PrctlPolicy() const override"
        if marker not in class_scope:
            marker = "virtual ResultExpr PrctlPolicy() const"
        start, end = self.scope_bounds(class_scope, marker, f"{label} PrctlPolicy")
        method = class_scope[start:end]
        have_dump = "PR_GET_DUMPABLE" in method
        have_pac = "PR_PAC_RESET_KEYS" in method
        if have_dump and have_pac:
            return class_scope, False
        if have_dump != have_pac:
            raise PortError(f"{label} PrctlPolicy: partial Termux rules")
        default = "        .Default(InvalidSyscall());"
        if method.count(default) != 1:
            raise PortError(f"{label} PrctlPolicy: .Default anchor changed")
        rules = (
            "#if defined(__TERMUX__)\n"
            "        .Case(PR_GET_DUMPABLE, Allow())\n"
            "#  if defined(__aarch64__)\n"
            "        .Case(PR_PAC_RESET_KEYS,\n"
            "              If(arg2 == PR_PAC_APIAKEY, Allow())\n"
            "                  .Else(InvalidSyscall()))\n"
            "#  endif\n"
            "#endif\n"
        )
        method = method.replace(default, rules + default, 1)
        return class_scope[:start] + method + class_scope[end:], True

    def patch_filter(self) -> None:
        rel = FILTER
        path = self.p(rel)
        self.remember_before(rel)
        text = path.read_text()
        changed = False

        if "#include <sys/resource.h>" not in text:
            anchor = "#include <sys/prctl.h>\n"
            if text.count(anchor) != 1:
                raise PortError("SandboxFilter: sys/prctl.h include anchor changed")
            text = text.replace(anchor, anchor + "#include <sys/resource.h>\n", 1)
            changed = True
            self.record("RLIMIT header", rel, "APPLIED")
        else:
            self.record("RLIMIT header", rel, "ALREADY_PRESENT")

        pac_defs = (
            "#if defined(__TERMUX__) && defined(__aarch64__)\n"
            "#  ifndef PR_PAC_RESET_KEYS\n"
            "#    define PR_PAC_RESET_KEYS 54\n"
            "#  endif\n"
            "#  ifndef PR_PAC_APIAKEY\n"
            "#    define PR_PAC_APIAKEY (1UL << 0)\n"
            "#  endif\n"
            "#endif\n"
        )
        if "#    define PR_PAC_APIAKEY (1UL << 0)" not in text:
            anchor = "#ifndef PR_SET_VMA_ANON_NAME\n#  define PR_SET_VMA_ANON_NAME 0\n#endif\n"
            if text.count(anchor) != 1:
                raise PortError("SandboxFilter: PR_SET_VMA_ANON_NAME anchor changed")
            text = text.replace(anchor, anchor + "\n" + pac_defs, 1)
            changed = True
            self.record("AArch64 PAC constants", rel, "APPLIED")
        else:
            self.record("AArch64 PAC constants", rel, "ALREADY_PRESENT")

        old_desktop = "#ifndef ANDROID\n#  define DESKTOP\n#endif"
        new_desktop = "#if !defined(ANDROID) || defined(__TERMUX__)\n#  define DESKTOP\n#endif"
        if new_desktop not in text:
            if text.count(old_desktop) != 1:
                raise PortError("SandboxFilter: DESKTOP macro anchor changed")
            text = text.replace(old_desktop, new_desktop, 1)
            changed = True
            self.record("Termux desktop sandbox semantics", rel, "APPLIED")
        else:
            self.record("Termux desktop sandbox semantics", rel, "ALREADY_PRESENT")

        # Common prctl policy.
        cstart, cend = self.scope_bounds(text, "class SandboxPolicyCommon", "SandboxPolicyCommon")
        common = text[cstart:cend]
        common, did = self._patch_prctl_scope(common, "SandboxPolicyCommon")
        if did:
            text = text[:cstart] + common + text[cend:]
            changed = True
            self.record("Common Termux prctl rules", rel, "APPLIED")
        else:
            self.record("Common Termux prctl rules", rel, "ALREADY_PRESENT")

        # Re-locate after edits and add getrlimit(RLIMIT_STACK) only.
        cstart, cend = self.scope_bounds(text, "class SandboxPolicyCommon", "SandboxPolicyCommon")
        common = text[cstart:cend]
        if "resource == RLIMIT_STACK" not in common:
            eval_marker = "ResultExpr EvaluateSyscall(int sysno) const override"
            estart, eend = self.scope_bounds(common, eval_marker, "SandboxPolicyCommon::EvaluateSyscall")
            method = common[estart:eend]
            time_marker = method.find("// Timekeeping")
            if time_marker < 0:
                raise PortError("SandboxPolicyCommon::EvaluateSyscall Timekeeping anchor changed")
            switch_pos = method.rfind("    switch (sysno) {\n", 0, time_marker)
            if switch_pos < 0:
                raise PortError("SandboxPolicyCommon::EvaluateSyscall main switch changed")
            switch_end = switch_pos + len("    switch (sysno) {\n")
            rule = (
                "#if defined(__TERMUX__) && defined(__NR_getrlimit)\n"
                "      case __NR_getrlimit: {\n"
                "        Arg<int> resource(0);\n"
                "        return If(resource == RLIMIT_STACK, Allow())\n"
                "            .Else(SandboxPolicyBase::EvaluateSyscall(sysno));\n"
                "      }\n"
                "#endif\n\n"
            )
            method = method[:switch_end] + rule + method[switch_end:]
            common = common[:estart] + method + common[eend:]
            text = text[:cstart] + common + text[cend:]
            changed = True
            self.record("getrlimit(RLIMIT_STACK) only", rel, "APPLIED")
        else:
            self.record("getrlimit(RLIMIT_STACK) only", rel, "ALREADY_PRESENT")

        # Bionic may use the fixed-address form while reallocating.  Preserve
        # the narrow allow-list proven by runtime tests.
        termux_mremap = (
            "#if defined(__TERMUX__)\n"
            "        return If(flags == 0, Allow())\n"
            "            .ElseIf(flags == MREMAP_MAYMOVE, Allow())\n"
            "            .ElseIf(flags == (MREMAP_MAYMOVE | MREMAP_FIXED), Allow())\n"
            "            .Else(SandboxPolicyBase::EvaluateSyscall(sysno));\n"
            "#else\n"
            "        return If((flags & ~MREMAP_MAYMOVE) == 0, Allow())\n"
            "            .Else(SandboxPolicyBase::EvaluateSyscall(sysno));\n"
            "#endif"
        )
        if termux_mremap not in text:
            old = (
                "        return If((flags & ~MREMAP_MAYMOVE) == 0, Allow())\n"
                "            .Else(SandboxPolicyBase::EvaluateSyscall(sysno));"
            )
            if text.count(old) != 1:
                raise PortError("SandboxFilter: mremap policy anchor changed")
            text = text.replace(old, termux_mremap, 1)
            changed = True
            self.record("narrow Termux mremap flags", rel, "APPLIED")
        else:
            self.record("narrow Termux mremap flags", rel, "ALREADY_PRESENT")

        # Content must follow desktop socket brokering even though Bionic makes
        # the target look Android at the libc/compiler level.
        cstart, cend = self.scope_bounds(text, "class ContentSandboxPolicy", "ContentSandboxPolicy")
        content = text[cstart:cend]
        old = "#ifdef ANDROID\n      case SYS_SOCKET:"
        new = "#if defined(ANDROID) && !defined(__TERMUX__)\n      case SYS_SOCKET:"
        if new not in content:
            if content.count(old) != 1:
                raise PortError("ContentSandboxPolicy socket branch anchor changed")
            content = content.replace(old, new, 1)
            text = text[:cstart] + content + text[cend:]
            changed = True
            self.record("Termux content socket brokering", rel, "APPLIED")
        else:
            self.record("Termux content socket brokering", rel, "ALREADY_PRESENT")

        # Socket and Utility override PrctlPolicy, so mirror the narrow Termux
        # rules into those overrides instead of weakening the common default.
        for class_name in ("SocketProcessSandboxPolicy", "UtilitySandboxPolicy"):
            s, e = self.scope_bounds(text, f"class {class_name}", class_name)
            scope = text[s:e]
            scope, did = self._patch_prctl_scope(scope, class_name)
            if did:
                text = text[:s] + scope + text[e:]
                changed = True
                self.record(f"{class_name} Termux prctl rules", rel, "APPLIED")
            else:
                self.record(f"{class_name} Termux prctl rules", rel, "ALREADY_PRESENT")

        # Actual AArch64/Bionic runtime evidence: Utility calls fstatfs on an
        # already-open fd.  Keep this Termux-only and do not add path access.
        ustart, uend = self.scope_bounds(text, "class UtilitySandboxPolicy", "UtilitySandboxPolicy")
        utility = text[ustart:uend]
        fstatfs_rule = (
            "#if defined(__TERMUX__) && defined(__NR_fstatfs)\n"
            "      case __NR_fstatfs:\n"
            "        return Allow();\n"
            "#endif"
        )
        if fstatfs_rule not in utility:
            eval_marker = "ResultExpr EvaluateSyscall(int sysno) const override"
            estart, eend = self.scope_bounds(utility, eval_marker, "UtilitySandboxPolicy::EvaluateSyscall")
            method = utility[estart:eend]
            anchor = "      // Required by FFmpeg\n"
            if method.count(anchor) != 1:
                raise PortError("UtilitySandboxPolicy fstatfs insertion anchor changed")
            method = method.replace(anchor, fstatfs_rule + "\n\n" + anchor, 1)
            utility = utility[:estart] + method + utility[eend:]
            text = text[:ustart] + utility + text[uend:]
            changed = True
            self.record("Utility Termux fstatfs", rel, "APPLIED")
        else:
            self.record("Utility Termux fstatfs", rel, "ALREADY_PRESENT")

        if changed:
            path.write_text(text)
            self.remember_after(rel)

    def apply(self) -> None:
        self.patch_reporter()
        self.patch_priority_inheritance()
        self.patch_glibc_lazy_init()
        self.patch_broker()
        self.patch_filter()
        self.verify()

    # ------------------------------------------------------------------
    # Fail-closed verification
    # ------------------------------------------------------------------
    def require(self, rel: Path, token: str, label: str, *, count: int | None = None) -> None:
        text = self.p(rel).read_text()
        actual = text.count(token)
        if count is None:
            if actual < 1:
                raise PortError(f"verify {label}: missing {token!r}")
        elif actual != count:
            raise PortError(f"verify {label}: expected count {count}, got {actual}: {token!r}")

    def verify_broker(self) -> None:
        text = self.p(BROKER).read_text()
        helper_start, helper_end = self.scope_bounds(text, "static void AddTermuxRuntimeReadPaths", "runtime helper")
        helper = text[helper_start:helper_end]
        for leaf in self.runtime_read_subdirs:
            token = f'aPolicy->AddTree(rdonly, "{self.prefix}/{leaf}");'
            if helper.count(token) != 1:
                raise PortError(f"runtime helper: expected exactly one {leaf} read-only mapping")
        for bad in ("rdwr,", "rdwrcr,", "MAY_WRITE", "MAY_CREATE"):
            if bad in helper:
                raise PortError(f"runtime helper unexpectedly grants write/create: {bad}")

        targets = [
            ("void SandboxBrokerPolicyFactory::InitContentPolicy()", "AddTermuxRuntimeReadPaths(policy);", "Content"),
            ("SandboxBrokerPolicyFactory::GetRDDPolicy(int aPid)", "AddTermuxRuntimeReadPaths(policy.get());", "RDD"),
            ("SandboxBrokerPolicyFactory::GetSocketProcessPolicy(int aPid)", "AddTermuxRuntimeReadPaths(policy.get());", "Socket"),
            ("SandboxBrokerPolicyFactory::GetUtilityProcessPolicy(int aPid)", "AddTermuxRuntimeReadPaths(policy.get());", "Utility"),
        ]
        labels = [label for _, _, label in targets]
        if labels != self.runtime_policy_scopes:
            raise PortError(
                f"port.toml runtime_policy_scopes {self.runtime_policy_scopes!r} "
                f"does not match implemented policy map {labels!r}"
            )
        for needle, call, label in targets:
            s, e = self.scope_bounds(text, needle, f"verify {label}")
            scope = text[s:e]
            if scope.count(call) != 1:
                raise PortError(f"{label}: Termux runtime helper call count != 1")
        cs, ce = self.scope_bounds(text, targets[0][0], "verify Content")
        content = text[cs:ce]
        for android_path in self.content_android_read_paths:
            token = f'policy->AddTree(rdonly, "{android_path}");'
            if content.count(token) != 1:
                raise PortError(f"Content: {android_path} must be exactly one read-only rule")

        ls, le = self.scope_bounds(text, "static void AddLdconfigPaths", "verify AddLdconfigPaths")
        ld = text[ls:le]
        if "#if defined(__TERMUX__)\n  return;\n#endif" not in ld:
            raise PortError("AddLdconfigPaths is not globally no-op on Termux")

        us, ue = self.scope_bounds(text, targets[-1][0], "verify Utility")
        utility = text[us:ue]
        for p in ("stat", "maps"):
            token = f'nsPrintfCString("/proc/%d/{p}", aPid).get()'
            if utility.count(token) != 1:
                raise PortError(f"Utility exact own /proc/{p} rule count != 1")
        for bad in (
            'AddTree(rdonly, "/proc',
            'AddPrefix(rdonly, "/proc',
            'AddTree(rdwr, "/proc',
            'AddPrefix(rdwr, "/proc',
            'AddTree(rdwrcr, "/proc',
            'AddPrefix(rdwrcr, "/proc',
        ):
            if bad in utility:
                raise PortError(f"Utility broad /proc policy detected: {bad}")

    def verify_filter(self) -> None:
        text = self.p(FILTER).read_text()
        required = (
            "#include <sys/resource.h>",
            "#if !defined(ANDROID) || defined(__TERMUX__)",
            "PR_PAC_RESET_KEYS",
            "PR_PAC_APIAKEY",
            "resource == RLIMIT_STACK",
            "MREMAP_MAYMOVE | MREMAP_FIXED",
            "#if defined(ANDROID) && !defined(__TERMUX__)",
        )
        for token in required:
            if token not in text:
                raise PortError(f"SandboxFilter verification missing: {token}")

        # Enforce exact getrlimit restriction rather than a broad Allow().
        if "case __NR_getrlimit:\n        return Allow();" in text:
            raise PortError("broad getrlimit Allow() detected")

        us, ue = self.scope_bounds(text, "class UtilitySandboxPolicy", "verify UtilitySandboxPolicy")
        utility = text[us:ue]
        rule = "#if defined(__TERMUX__) && defined(__NR_fstatfs)\n      case __NR_fstatfs:\n        return Allow();\n#endif"
        if utility.count(rule) != 1:
            raise PortError("Utility fstatfs Termux-only rule missing or duplicated")

        for class_name in ("SandboxPolicyCommon", "SocketProcessSandboxPolicy", "UtilitySandboxPolicy"):
            s, e = self.scope_bounds(text, f"class {class_name}", f"verify {class_name}")
            scope = text[s:e]
            if "PR_GET_DUMPABLE" not in scope or "PR_PAC_RESET_KEYS" not in scope:
                raise PortError(f"{class_name}: Termux prctl compatibility incomplete")

    def verify_upstream_policy_parity(self) -> None:
        """Detect a new Linux process policy that likely needs Termux mapping.

        We never grant access automatically to an unknown policy.  This scan is
        intentionally conservative: if a Get*Policy function contains Linux
        runtime trees but has no Termux helper, the next Firefox release stops
        for review.
        """
        text = self.p(BROKER).read_text()
        # The four known policies are handled explicitly above.  Scan other
        # Get*Policy definitions for system runtime trees.
        pattern = re.compile(r"SandboxBrokerPolicyFactory::(Get[A-Za-z0-9_]*Policy)\s*\([^)]*\)\s*\{")
        known = {"GetRDDPolicy", "GetSocketProcessPolicy", "GetUtilityProcessPolicy"}
        for match in pattern.finditer(text):
            name = match.group(1)
            if name in known:
                continue
            start = match.start()
            open_pos = text.find("{", match.start(), match.end() + 1)
            if open_pos < 0:
                continue
            end = self._code_brace_match(text, open_pos) + 1
            scope = text[start:end]
            linux_runtime = any(p in scope for p in ('"/usr/lib', '"/lib64"', 'AddLdconfigPaths('))
            if linux_runtime and "AddTermuxRuntimeReadPaths" not in scope:
                raise PortError(
                    f"new/unknown broker policy {name} has Linux runtime-library access "
                    "but no Termux mapping; manual review required"
                )

    def verify_termux_package_assumptions(self) -> None:
        shmem = self.p(SHMEM).read_text()
        if f'{self.prefix}/tmp/' not in shmem:
            raise PortError("Termux POSIX shm package patch is missing or prefix changed")

    def verify(self) -> None:
        self.require(REPORTER, "#include <time.h>", "sandbox reporter")
        self.require(LOCK, "BUILDFLAG(IS_FUCHSIA) || defined(__TERMUX__)", "PI mutex")
        self.require(SANDBOX, "#if !defined(__TERMUX__)\nstatic void RunGlibcLazyInitializers()", "glibc lazy init")
        self.verify_broker()
        self.verify_filter()
        self.verify_upstream_policy_parity()
        self.verify_termux_package_assumptions()
        print("[VERIFY SUCCESS] Termux Firefox native sandbox structural contract")


    def write_patch(self, path: Path) -> None:
        chunks: list[str] = []
        for key in sorted(self.before_text):
            before = self.before_text[key]
            after = (self.root / key).read_text()
            if before == after:
                continue
            chunks.extend(
                difflib.unified_diff(
                    before.splitlines(keepends=True),
                    after.splitlines(keepends=True),
                    fromfile=f"a/{key}",
                    tofile=f"b/{key}",
                    n=3,
                )
            )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(chunks))

    def report(self, command: str) -> dict:
        for rel in (FILTER, BROKER, SANDBOX, REPORTER, LOCK, SHMEM):
            path = self.p(rel)
            self.after_sha.setdefault(str(rel), self.sha(path))
        return {
            "port_version": PORT_VERSION,
            "command": command,
            "source_root": str(self.root),
            "termux_prefix": self.prefix,
            "changes": [asdict(c) for c in self.changes],
            "before_sha256": self.before_sha,
            "after_sha256": self.after_sha,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("apply", "verify"))
    parser.add_argument("--src", type=Path, default=Path.cwd())
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--patch", type=Path)
    args = parser.parse_args()

    port = Port(args.src, args.prefix)
    try:
        if args.command == "apply":
            port.apply()
        else:
            port.verify()
    except PortError as exc:
        print(f"PORT ERROR: {exc}", file=sys.stderr)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            data = port.report(args.command)
            data["error"] = str(exc)
            args.report.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        return 2

    if args.patch and args.command == "apply":
        port.write_patch(args.patch)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(port.report(args.command), indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
