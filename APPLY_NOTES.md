# v2.4.5 — Action r3 (validated)

This tree is based on the device-validated v2.4.4/r2 Action and adds only the
next isolated compatibility delta.

## New in r3

- Restore upstream Linux `MOZ_CUBEB_REMOTING` semantics after Termux's stock
  `0008-fix-macros.patch` compiles them out.
- Add a Termux compile-time AudioIPC guard.
- Add an early Rust-side AudioIPC source contract: Linux gkrust must still enable
  `cubeb-remoting`, and that feature must still pull both audioipc2 client/server.
- Add a final `libxul.so` AudioIPC binary gate driven by marker strings in
  `port.toml`.
- Centralize the X11 socket endpoint as `kX11SocketPrefix`, mapping Linux
  `/tmp/.X11-unix/X*` to `$PREFIX/tmp/.X11-unix/X*` on Termux.
- Add fail-closed guards against direct PulseAudio Content bypass, broad
  `$PREFIX/tmp` rdwrcr access, direct X11 literals, and broad GMP runtime-path
  inheritance.
- Candidate detection now considers both Firefox version and port version.

## Deliberately not added

- no Content `MAY_CONNECT` to PulseAudio;
- no broad `prctl`/`umask` allowance;
- no GMP runtime-path expansion;
- no broad `/proc` or `$PREFIX/tmp` tree grant.

## Validation state

All four gates passed on 2026-09-14 (run #25 + device):

1. GitHub Actions build succeeds (run #25, head dde080f);
2. the binary AudioIPC gate passes (4/4 markers PRESENT, independently
   re-verified from the released deb);
3. the device level-6 regression passes with a live PulseAudio daemon,
   including AudioIPC cubeb-server output for AAC and YouTube with audible
   playback confirmed by the user;
4. the level-4 X11 diagnostic passes (broker CONNECT policy for
   $PREFIX/tmp/.X11-unix/X, no denial).

Post-rc1 fixes folded in: exclude the `atp_set_real_time_limit` call-site on
Termux (audio_thread_priority builds that symbol for target_os=linux only),
and the binary gate no longer depends on runner host python3.

## Apply

Copy `.github/workflows/firefox-sandbox.yml` and `port/` over the repository,
review the diff, then run the workflow.
