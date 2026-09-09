#!/data/data/com.termux/files/usr/bin/bash
set -u

LEVEL="${FIREFOX_SANDBOX_LEVEL:-6}"
PROFILE="${FIREFOX_SANDBOX_PROFILE:-$HOME/.mozilla/firefox-termux-sandbox-test}"
LOG="${FIREFOX_SANDBOX_LOG:-$HOME/firefox-native-sandbox-runtime.log}"
START_URL="${FIREFOX_SANDBOX_URL:-about:blank}"

mkdir -p "$PROFILE"
cat > "$PROFILE/user.js" <<EOF
user_pref("security.sandbox.content.level", ${LEVEL});
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage", "about:blank");
EOF

set_toggle() {
  local control="$1" env_name="$2"
  if [ "${!control:-0}" = "1" ]; then
    export "$env_name=1"
  else
    unset "$env_name" 2>/dev/null || true
  fi
}

# A/B switches are deliberately per-process. There is no blanket "disable all
# auxiliary sandboxes" mode because that hides which policy caused a failure.
set_toggle FIREFOX_SANDBOX_DISABLE_SOCKET MOZ_DISABLE_SOCKET_PROCESS_SANDBOX
set_toggle FIREFOX_SANDBOX_DISABLE_UTILITY MOZ_DISABLE_UTILITY_SANDBOX
set_toggle FIREFOX_SANDBOX_DISABLE_RDD MOZ_DISABLE_RDD_SANDBOX

echo "======================================"
echo "Termux Firefox native sandbox runtime test"
echo "======================================"
echo "level       : $LEVEL"
echo "profile     : $PROFILE"
echo "log         : $LOG"
echo "url         : $START_URL"
echo "socket off  : ${FIREFOX_SANDBOX_DISABLE_SOCKET:-0}"
echo "utility off : ${FIREFOX_SANDBOX_DISABLE_UTILITY:-0}"
echo "RDD off     : ${FIREFOX_SANDBOX_DISABLE_RDD:-0}"
echo
uname -a || true
getprop ro.build.version.release 2>/dev/null || true
getprop ro.build.version.sdk 2>/dev/null || true

set +e
if [ -n "${FIREFOX_MOZ_LOG:-}" ]; then
  MOZ_SANDBOX_LOGGING=1 \
  MOZ_LOG="$FIREFOX_MOZ_LOG" \
    firefox --no-remote --profile "$PROFILE" "$START_URL" 2>&1 | tee "$LOG"
else
  MOZ_SANDBOX_LOGGING=1 \
    firefox --no-remote --profile "$PROFILE" "$START_URL" 2>&1 | tee "$LOG"
fi
rc=${PIPESTATUS[0]}
set -e

echo
echo "======================================"
echo "Sandbox-focused runtime log"
echo "======================================"
grep -nEi \
  'sandbox|seccomp|sigsys|violation|syscall|rejected|bad system call|channel error|MOZ_CRASH|PR_PAC|PR_GET_DUMPABLE|getrlimit|RLIMIT_STACK|fstatfs|mremap|/proc/self/|/proc/[0-9]+/|libavcodec|libavutil|FFmpeg|PDM|decoder|logdw|timezone|tzdata|__properties__|org\.mozilla\.ipc|system/fonts' \
  "$LOG" | tail -n 1200 || true

echo
echo "Firefox exit code: $rc"
exit "$rc"
