# Device regression gate

Run with every sandbox enabled first. Do not use a disable switch unless the
normal run fails and an A/B isolation is needed.

```bash
pkill -TERM firefox 2>/dev/null || true
unset MOZ_DISABLE_SOCKET_PROCESS_SANDBOX
unset MOZ_DISABLE_UTILITY_SANDBOX
unset MOZ_DISABLE_RDD_SANDBOX

FIREFOX_SANDBOX_LEVEL=6 \
FIREFOX_SANDBOX_URL=about:blank \
./termux-firefox-native-sandbox-test.sh
```

Expected baseline:

- Content seccomp uses TSYNC and effective content level is 6.
- No fatal `SIGSYS`, `Bad system call`, `MOZ_CRASH`, or rejected-syscall loop.
- Known non-fatal Android timezone/logd probes are not grounds for widening the
  policy by themselves.

## Media

Open the bundled `media-capabilities.html`, wait a few seconds after Firefox
startup, and reload it once. Required results for both `file` and
`media-source`:

- H.264 video: `supported: true`
- VP9 video: `supported: true`
- AV1 video: `supported: true`
- AAC audio: `supported: true`
- Opus audio: `supported: true`

Then test the local AAC/Opus samples and YouTube. If PulseAudio was deliberately
disabled for VNC, an `OnMediaSinkAudioError` is not a decoder regression; a
`no decoder found for audio/mp4a-latm` error is.

The sandbox log must not show broker EACCES for the real Termux
`$PREFIX/lib/libavcodec.so.*`, and Utility must not report an AArch64 syscall 44
(`fstatfs`) sandbox violation.

## One-variable A/B only

If audio fails, isolate Utility only:

```bash
FIREFOX_SANDBOX_DISABLE_UTILITY=1 \
FIREFOX_SANDBOX_LEVEL=6 \
./termux-firefox-native-sandbox-test.sh
```

Do not disable Socket + Utility + RDD together. A successful Utility-off A/B is
an instruction to inspect the exact Utility denial, not to ship with Utility
sandbox disabled.

## Graphics

Keep the previously validated WebRender/Turnip setup unchanged while testing
this sandbox patch. Confirm actual KGSL activity under a graphics workload and
ensure no rendering regression. Graphics driver workarounds must not be folded
into the sandbox policy.
