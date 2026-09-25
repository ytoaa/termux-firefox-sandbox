# Termux Firefox native sandbox port — maintenance model

## Goal

Keep Firefox's Linux sandbox enabled on Termux/Android while carrying the
smallest possible Termux/Bionic compatibility layer. The port is deliberately
**fail-closed**: a new upstream source shape is not granted broader access
silently.

## Single sources of truth

- `port.toml` owns the port version, validation state, X11 path translation and
  the final AudioIPC binary contract.
- `firefox_sandbox_port.py` owns Firefox-source compatibility changes.
- `prepare_recipe.py` owns Termux recipe changes only.
- The GitHub workflow is orchestration only. It must not contain C++ patches or
  embedded Python patchers.

A candidate is now raised for either a Firefox version change or a port version
change. This avoids the old blind spot where a new sandbox patch on the same
Firefox release looked "validated" merely because `last_validated_firefox`
matched.

## Upgrade behavior

A Termux Firefox version bump does **not** automatically fail just because the
version changed. `prepare_recipe.py` marks it as a candidate build. During
`termux_step_pre_configure`, the semantic source transformer locates the actual
C++ classes/functions and applies the known compatibility contract.

Three outcomes are expected:

1. `APPLIED` — known upstream/Termux form was found and the compatibility rule
   was added.
2. `ALREADY_PRESENT` — the source already has the expected form.
3. `PORT ERROR` — the source contract changed or is ambiguous. Stop and review.

Only after runtime regression passes should the current port be marked as the
validated port in `port.toml`.

## Broker policy mapping

Ordinary Linux policies give Content/RDD/Socket/Utility read-only access to
system runtime paths such as `/usr/lib`, `/etc`, and `/usr/share`. Termux keeps
those resources under `$TERMUX_PREFIX`.

The port defines one helper, `AddTermuxRuntimeReadPaths()`, and calls it from the
four known process policies. `/system/fonts` remains Content-only. `/proc` is
never opened by tree/prefix; only exact own-process files proven necessary are
added.

`AddLdconfigPaths()` becomes a global no-op on Termux because its
`/etc/ld.so.conf` model belongs to glibc. `libandroid-glob` remains linked for
now so this policy refactor does not also remove a build dependency.

## X11 socket mapping

Firefox desktop Linux uses `/tmp/.X11-unix/X*`. Termux:X11 exposes the same Unix
socket namespace under `$TERMUX_PREFIX/tmp/.X11-unix/X*`.

The port defines one `kX11SocketPrefix` and uses it in both
`AddX11Dependencies()` and the RDD X11/XWayland fallback. The verifier rejects
new direct `/tmp/.X11-unix/X` broker literals outside that central constant.
This is a path translation only; it does not add a new class of socket access.

## AudioIPC / PulseAudio model

Termux's stock Firefox patch `0008-fix-macros.patch` explicitly excludes
`__TERMUX__` from `MOZ_CUBEB_REMOTING`. That is compatible with the stock package
only because the content sandbox is disabled there. With content sandbox level
4 or higher, direct Content -> PulseAudio access is intentionally blocked by
Firefox's Linux sandbox.

The sandbox port therefore restores the upstream Linux cubeb remoting condition
instead of adding a direct PulseAudio `MAY_CONNECT` exception to Content:

```
Content -> AudioIPC -> parent cubeb server -> PulseAudio
```

The source transformer adds a Termux compile guard. Before the long build, its
verifier also checks the Rust side: Linux `gkrust` must still enable the
`cubeb-remoting` feature and that Cargo feature must still include both
`audioipc2-client` and `audioipc2-server`. CI then performs a final `libxul.so`
binary gate. The four binary marker strings live in `port.toml`, so future source
changes require updating one contract rather than duplicating the list across
workflow code.

Security rule: **do not add `$XDG_RUNTIME_DIR/pulse/native` or
`$PREFIX/tmp/pulse/native` MAY_CONNECT to Content as a workaround.** If AudioIPC
fails on Bionic, fix the exact AudioIPC/Bionic failure instead.

## Explicit over-grant guards

The verifier rejects:

- a new direct Linux X11 socket literal outside `kX11SocketPrefix`;
- broad `$PREFIX/tmp` read/write/create tree/prefix grants;
- broad Termux runtime-library access in `GMPSandboxPolicy`;
- a direct PulseAudio socket bypass in Content;
- broad `/proc` tree/prefix grants.

GMP/EME remains a separate, unvalidated boundary. It is not granted the ordinary
Content/RDD/Socket/Utility runtime path helper automatically.

## Syscall policy

Termux-only syscall exceptions remain argument- or syscall-specific. The known
Utility exception is exact `__NR_fstatfs`, matching observed AArch64 runtime
behavior. It does not add pathname permission.

Do not add `prctl`, `umask`, or other syscall exceptions merely because they
appear in logs. A new exception requires a reproducible functional failure and
an exact operation/argument contract.

## Regression gate

The candidate should not be marked validated until a real device confirms:

- seccomp-BPF + TSYNC active;
- Content effective level 6;
- no fatal SIGSYS / rejected-syscall regression;
- WebRender/Adreno unchanged;
- H.264, VP9, AV1, AAC and Opus capability;
- no real `$PREFIX/lib/libavcodec.so.*` broker EACCES;
- no Utility `fstatfs` violation;
- AudioIPC markers present in installed `libxul.so`;
- with a live PulseAudio daemon, AudioIPC is used and actual audio playback
  reaches the sink without a Content -> PulseAudio broker denial;
- YouTube playback;
- a separate level-4 diagnostic confirms the Termux:X11 socket mapping.

## Future policy discovery

The verifier scans for previously unknown `Get*Policy` broker functions that
carry Linux runtime-library paths. It never grants Termux runtime paths to a new
process type automatically. A new security boundary stops the candidate for
manual review.

## Package version lead

The published deb version is deliberately **`<major>.1`** while the real
Firefox source is `major.0.x` (Termux channel version).  This keeps a device
that has our sandbox build installed strictly ahead of every Termux package of
the same series in dpkg ordering, so `pkg upgrade firefox` can never silently
replace the sandboxed browser with the official sandbox-off build when
Termux publishes a version or dot bump.  Prepared by `prepare_recipe.py`:
the `${TERMUX_PKG_VERSION#*really}`-interpolating SRCURL is materialized to
the real source version first, then `TERMUX_PKG_VERSION` is raised to
`<major>.1` and `TERMUX_PKG_REVISION` bumped.

Safety of the `N.1` space: verified 2026-09-16 against the full
archive.mozilla.org release listing — Firefox >= 100 has never shipped a
second segment != 0 (167 releases, all `N.0[.k]`, dots only in segment 3,
observed up to `N.0.6`).  A re-run over an already-prepared recipe recovers
the true source version from the materialized SRCURL.

Consequences accepted by this policy:

- The upstream gate rebuilds only on minor (0.1-level) moves; same-version
  revision/source-hash drift is reported without scheduling a build because
  the version lead already protects installs through it.  Firefox dot
  releases carry security fixes, so adopting them waits for the next minor
  rebuild unless a human dispatches the workflow with `force=true`.
- Between a Termux major bump (e.g. 157.0) and our first 157 build, Termux's
  new major temporarily outranks our stale `156.1` lead.  The daily gate /
  manual dispatch closes this window; `apt-mark hold firefox` removes it
  entirely for users who prefer no automatic replacement at all.
- Package managers and `about:support` show different numbers on purpose:
  deb version `156.1` (packaging) vs Firefox 156.0 (actual source).
  Metadata records both as `packaged_version` and `firefox_version`.
