# Termux Firefox native sandbox port — maintenance model

## Goal

Keep Firefox's Linux sandbox enabled on Termux/Android while carrying the
smallest possible Termux/Bionic compatibility layer. The port is deliberately
**fail-closed**: a new upstream source shape is not granted broader access
silently.

## Single sources of truth

- `port.toml` owns the port version and the last Firefox version validated on a
  real Termux device.
- `firefox_sandbox_port.py` owns Firefox-source compatibility changes.
- `prepare_recipe.py` owns Termux recipe changes only.
- The GitHub workflow is orchestration only. It must not contain C++ patches or
  embedded Python patchers.

## Upgrade behavior

A Termux Firefox version bump does **not** automatically fail just because the
version changed. `prepare_recipe.py` marks it as a candidate build. During
`termux_step_pre_configure`, the semantic source transformer locates the actual
C++ classes/functions and applies the known compatibility contract.

Three outcomes are expected:

1. `APPLIED` — known upstream form was found and the Termux rule was added.
2. `ALREADY_PRESENT` — the source already has the expected Termux form.
3. `PORT ERROR` — the source contract changed or is ambiguous. Stop and review.

Only after runtime regression passes should `last_validated_firefox` in
`port.toml` be advanced.

## Broker policy mapping

The ordinary Linux policies give Content/RDD/Socket/Utility read-only access to
system runtime paths such as `/usr/lib`, `/etc`, and `/usr/share`. Termux keeps
those resources under `$TERMUX_PREFIX`.

The port defines one helper, `AddTermuxRuntimeReadPaths()`, and calls it from the
four known process policies. This avoids four duplicated path lists and makes a
future prefix/path change a one-location edit.

`/system/fonts` remains Content-only. `/proc` is never opened by tree/prefix;
only the exact own-process files proven necessary are added.

`AddLdconfigPaths()` becomes a global no-op on Termux because its
`/etc/ld.so.conf` model belongs to glibc. For this first semantic-port release,
`libandroid-glob` remains linked so this refactor does not combine a sandbox
policy change with a build/link dependency removal. Removing that dependency is
a later isolated cleanup once the new runtime passes.

## Syscall policy

Termux-only syscall exceptions remain argument- or syscall-specific. The new
Utility exception is exact `__NR_fstatfs`, matching the observed AArch64 runtime
violation. It does not add any pathname permission.

Do not replace narrow rules with broad `Allow()` blocks. In particular:

- no broad `getrlimit`; only `RLIMIT_STACK` is accepted;
- no broad `/proc` tree or prefix;
- no blanket socket allowance;
- no blanket auxiliary-sandbox disable mode in the runtime helper.

## Regression gate

The release candidate should not be marked validated until the device test has
confirmed at least:

- seccomp-BPF + TSYNC active;
- Content sandbox effective level 6;
- no fatal SIGSYS / rejected syscall regression;
- WebRender/Adreno regression unchanged;
- H.264, VP9, AV1 video capability;
- AAC and Opus capability with Utility sandbox enabled;
- local H.264+AAC playback reaches the media sink (PulseAudio sink failure is
  expected only when audio output was intentionally disabled);
- YouTube playback;
- no `libavcodec.so.*` broker EACCES;
- no Utility `__NR_fstatfs` violation.

## Future policy discovery

The verifier scans for previously unknown `Get*Policy` broker functions that
carry Linux runtime-library paths. It does **not** automatically grant Termux
runtime paths to a new process type. Such a discovery stops the candidate build
for review. This is intentional: source-format drift should usually be cheap,
but a new security boundary should never be accepted automatically.
