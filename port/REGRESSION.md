# Device regression gate — v2.4.5 / action r3

This candidate changes two security-relevant paths relative to validated
v2.4.4: cubeb AudioIPC is restored, and the X11 socket prefix is translated to
Termux. Test those independently and keep every other variable unchanged.

## 1. Installed binary gate

The bundled runtime helper performs this automatically when `port.toml` is next
to it. A manual equivalent is:

```bash
LIBXUL="$(dpkg -L firefox | grep '/libxul\.so$' | head -n1)"
for s in \
  'Starting cubeb server...' \
  'audioipc_server_start failed' \
  'SendCreateAudioIPCConnection failed: invalid FD' \
  'audioipc_server_new_client failed'
do
  grep -aFq "$s" "$LIBXUL" && echo "PRESENT  $s" || echo "ABSENT   $s"
done
```

All four must be `PRESENT`. An `ABSENT` result means
`MOZ_CUBEB_REMOTING` was compiled out and runtime testing should stop.

## 2. Level-6 full-sandbox baseline

Run with every sandbox enabled first:

```bash
pkill -TERM firefox 2>/dev/null || true
unset MOZ_DISABLE_SOCKET_PROCESS_SANDBOX
unset MOZ_DISABLE_UTILITY_SANDBOX
unset MOZ_DISABLE_RDD_SANDBOX

FIREFOX_SANDBOX_LEVEL=6 \
FIREFOX_MOZ_LOG='cubeb:5,PlatformDecoderModule:5,FFmpegAudio:5,FFmpegLib:5' \
FIREFOX_SANDBOX_URL=about:blank \
./termux-firefox-native-sandbox-test.sh
```

Required baseline:

- Content seccomp uses TSYNC and effective content level is 6.
- No fatal `SIGSYS`, `Bad system call`, `MOZ_CRASH`, or rejected-syscall loop.
- No Utility syscall 44 / `fstatfs` violation.
- Known non-fatal Android fallback probes alone are not grounds for widening
  the policy.

## 3. Decoder regression

Open the bundled `media-capabilities.html`, wait a few seconds, then reload once.
For both `file` and `media-source` all five must be supported:

- H.264
- VP9
- AV1
- AAC
- Opus

Then test the local H.264, AAC and Opus samples and YouTube. The sandbox log
must not show broker EACCES for the real Termux `$PREFIX/lib/libavcodec.so.*`.

## 4. AudioIPC / live PulseAudio gate

For this candidate, an intentionally disabled audio daemon is **not sufficient**
to validate the new AudioIPC path. Start/use the normal Termux PulseAudio setup
and first confirm the daemon/socket is actually live.

Then run an AAC sample with cubeb logging:

```bash
pkill -TERM firefox 2>/dev/null || true
FIREFOX_SANDBOX_LEVEL=6 \
FIREFOX_MOZ_LOG='cubeb:5' \
FIREFOX_SANDBOX_URL='file:///data/data/com.termux/files/home/Downloads/test-aac.m4a' \
./termux-firefox-native-sandbox-test.sh
```

Required:

- AudioIPC/cubeb-server path is observed (`Starting cubeb server...` or
  equivalent AudioIPC activity).
- The sandboxed Content PID must not directly connect to
  `$PREFIX/tmp/pulse/native`.
- No `OnMediaSinkAudioError` when the PulseAudio daemon is known live.
- Actual audible/output progress should be confirmed in the normal desktop
  environment.

If this fails, do **not** add a Content PulseAudio `MAY_CONNECT` rule. Capture
only the exact AudioIPC/Bionic failure and fix that layer.

## 5. X11 path diagnostic

Level 6 Content is headless in this Firefox policy, so use a separate level-4
run to exercise the normal X11 broker path:

```bash
pkill -TERM firefox 2>/dev/null || true
FIREFOX_SANDBOX_LEVEL=4 \
FIREFOX_SANDBOX_URL=about:blank \
./termux-firefox-native-sandbox-test.sh
```

Confirm the real socket exists at the Termux path (normally
`$PREFIX/tmp/.X11-unix/X0`) and that there is no broker connect denial for it.
Do not treat this level-4 diagnostic as the shipping sandbox level; the release
baseline remains level 6.

## 6. One-variable A/B only

If a regression appears, disable only the suspected process sandbox or lower
only the content level needed to isolate the path. Never disable Socket +
Utility + RDD together, and never ship with a disable switch.

## 7. Graphics

Keep the previously validated WebRender/Turnip setup unchanged. Confirm actual
KGSL activity under load and no rendering regression. Graphics driver
workarounds remain separate from sandbox policy.
