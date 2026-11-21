#!/bin/bash
# android-regress.sh - run the Android driver's behaviour cases against a live emulator and
# keep what each one printed. One file per case (command, stdout + stderr, exit code) plus
# a PASS/FAIL line per case against its expected exit code and output patterns.
#
#   ANDROID_SERIAL=<serial> [OTHER_SERIAL=<serial>] android-regress.sh <outdir> [GROUP ...]
#
# GROUP: core (device selection, server lifecycle, session) - default: every group.
# OTHER_SERIAL: a second attached device for the cases that need two (ambiguity, a port
# forwarded to the other device); without it those cases are SKIPPED, not passed.
# ADBD_RESTART=1 adds the case that restarts adbd on ANDROID_SERIAL (`adb root` + `unroot`)
# to prove a server that says ready but cannot answer is detected and repaired.
#
# The cases change the device: they stop and start the UiAutomator2 server and run a
# `uiautomator dump` loop for a few seconds. They leave the server RUNNING on
# ANDROID_SERIAL. Animation scales are read before and after: a change is a FAIL.
# Exit 0 = every case passed, 1 = at least one FAIL.

set -uo pipefail

OUT="${1:?usage: android-regress.sh <outdir> [GROUP ...]}"; shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="$HERE/android-ui.sh"
U="$HERE/uia2-server.sh"
. "$HERE/android-lib.sh"
SERIAL="${ANDROID_SERIAL:?set ANDROID_SERIAL to the emulator the cases run on}"
OTHER="${OTHER_SERIAL:-}"
GROUPS_WANTED="${*:-core}"
mkdir -p "$OUT"
PASS=0; FAIL=0; SKIP=0

want_group() { case " $GROUPS_WANTED " in *" $1 "*) return 0 ;; esac; return 1; }

# case NAME RC [PATTERN ...] -- CMD...   (PATTERN: an ERE the output must match;
# a leading ! means it must NOT match)
case_() {
  local name="$1" rc_want="$2" pats=() out rc p ok=1 why=""
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do pats+=("$1"); shift; done
  shift
  out="$("$@" 2>&1)"; rc=$?
  { echo "--- $*"; printf '%s\n' "$out"; echo "rc=$rc"; } > "$OUT/$name.txt"
  [ "$rc" = "$rc_want" ] || { ok=0; why="rc $rc, want $rc_want"; }
  for p in ${pats[@]+"${pats[@]}"}; do
    case "$p" in
      !*) printf '%s\n' "$out" | grep -qE -- "${p#!}" && { ok=0; why="${why:+$why; }matched '${p#!}'"; } ;;
      *)  printf '%s\n' "$out" | grep -qE -- "$p" || { ok=0; why="${why:+$why; }no '$p'"; } ;;
    esac
  done
  if [ "$ok" = 1 ]; then PASS=$((PASS + 1)); echo "PASS $name"
  else FAIL=$((FAIL + 1)); echo "FAIL $name ($why) - $OUT/$name.txt"; fi
}
skip() { SKIP=$((SKIP + 1)); echo "SKIP $1 ($2)"; echo "skipped: $2" > "$OUT/$1.txt"; }

scales() {
  "$ADB" -s "$SERIAL" shell 'settings get global window_animation_scale; settings get global transition_animation_scale; settings get global animator_duration_scale' | tr -d '\r' | tr '\n' ' '
}

SCALES_BEFORE="$(scales)"
echo "target $SERIAL, other ${OTHER:-none}, groups: $GROUPS_WANTED, animation scales: $SCALES_BEFORE"

if want_group core; then
  export ANDROID_SERIAL="$SERIAL"
  case_ usage           1 'android-ui.sh devices' -- "$A"
  case_ badcmd          1 'android-ui.sh devices' -- "$A" frobnicate
  case_ devices         0 "^$SERIAL " -- "$A" devices
  case_ unknown_serial  2 'is not attached' -- env ANDROID_SERIAL=emulator-5999 "$A" session
  case_ u2port_bad      2 'U2_PORT must be a port number' -- env U2_PORT=abc "$A" session
  case_ ensure          0 "READY $SERIAL " 'waitForIdleTimeout=0 disableIdLocatorAutocompletion=true' -- "$U" ensure "$SERIAL"
  case_ ensure_again    0 'server already running' "READY $SERIAL " '!installing' -- "$U" ensure "$SERIAL"
  case_ check           0 "READY $SERIAL " -- "$U" check "$SERIAL"
  case_ session_reused  0 '^same session' -- bash -c '
    a="$("$1" session)" && b="$("$1" session)" || exit 1
    a="${a#*session }"; b="${b#*session }"
    [ "${a%% *}" = "${b%% *}" ] && echo "same session ${a%% *}" || echo "differs: $a / $b"' _ "$A"
  case_ settings_after_new_session 0 'reused waitForIdleTimeout=0 disableIdLocatorAutocompletion=true' -- bash -c '
    curl -s -m 10 -X POST "http://127.0.0.1:$2/session" -H "Content-Type: application/json" \
      -d "{\"capabilities\":{\"alwaysMatch\":{\"platformName\":\"Android\"}}}" >/dev/null || exit 1
    "$1" session' _ "$A" "$(android_u2_port "$SERIAL")"

  if [ -n "$OTHER" ]; then
    case_ ambiguous      2 'refusing to guess' "$SERIAL" "$OTHER" -- env -u ANDROID_SERIAL "$A" session
    case_ ambiguous_srv  2 'refusing to guess' "$SERIAL" "$OTHER" -- env -u ANDROID_SERIAL "$U" check
    case_ pinned_serial  0 "^$SERIAL :" -- "$A" session
    case_ port_of_other  2 "forwarded to $SERIAL" -- env ANDROID_SERIAL="$OTHER" U2_PORT="$(android_u2_port "$SERIAL")" "$A" session
    case_ port_of_other_srv 2 "forwarded to $SERIAL" -- env U2_PORT="$(android_u2_port "$SERIAL")" "$U" ensure "$OTHER"
  else
    for c in ambiguous ambiguous_srv pinned_serial port_of_other port_of_other_srv; do skip "$c" "no OTHER_SERIAL"; done
  fi

  case_ stop            0 'stopped the UiAutomator2 server' -- "$U" stop "$SERIAL"
  case_ check_stopped   1 'NOT READY' -- "$U" check "$SERIAL"
  case_ no_server_proc  0 '^gone$' -- bash -c '"$1" -s "$2" shell ps -A | grep -q uiautomator2 && echo running || echo gone' _ "$ADB" "$SERIAL"
  case_ cmd_without_server 1 'uia2-server.sh ensure' -- "$A" session
  case_ stop_nothing    0 'nothing to stop' -- "$U" stop "$SERIAL"

  # Another UiAutomation client: a `uiautomator dump` loop. The refusal must come in
  # seconds, naming the holder - not as a 10-19 s timeout.
  # Plain background job, killed below: base macOS has no `timeout`.
  "$ADB" -s "$SERIAL" shell 'while true; do uiautomator dump /dev/null >/dev/null 2>&1; done' >/dev/null 2>&1 </dev/null &
  LOOP=$!
  trap 'kill "$LOOP" 2>/dev/null' EXIT
  sleep 1.5
  case_ foreign_client  1 'UiAutomation is held by another client' 'uiautomator' -- bash -c '
    t0=$(date +%s); "$1" ensure "$2"; rc=$?; echo "took $(( $(date +%s) - t0 ))s"; exit $rc' _ "$U" "$SERIAL"
  grep -qE 'took [0-4]s' "$OUT/foreign_client.txt" && echo "PASS foreign_client_fast" && PASS=$((PASS + 1)) \
    || { echo "FAIL foreign_client_fast (not under 5 s) - $OUT/foreign_client.txt"; FAIL=$((FAIL + 1)); }
  kill "$LOOP" 2>/dev/null; wait "$LOOP" 2>/dev/null; trap - EXIT
  "$ADB" -s "$SERIAL" shell pkill -f 'uiautomator dump' >/dev/null 2>&1
  "$ADB" -s "$SERIAL" shell pkill -x uiautomator >/dev/null 2>&1
  sleep 1

  BAD="$(mktemp -d -t uia2-regress)"
  cp -R "${UIA2_SERVER_HOME:-$HOME/.cache/uia2-server}/." "$BAD/" 2>/dev/null
  if [ -f "$BAD/11.2.4/appium-uiautomator2-server-v11.2.4.apk" ]; then
    printf 'X' | dd of="$BAD/11.2.4/appium-uiautomator2-server-v11.2.4.apk" bs=1 seek=1000 count=1 conv=notrunc 2>/dev/null
    # The cache is read only when something must be installed, so the server goes first.
    "$U" stop "$SERIAL" >/dev/null
    "$ADB" -s "$SERIAL" uninstall "$U2_TEST_PKG" >/dev/null 2>&1
    "$ADB" -s "$SERIAL" uninstall "$U2_SERVER_PKG" >/dev/null 2>&1
    case_ sha_mismatch  1 'sha256 mismatch' -- env UIA2_SERVER_HOME="$BAD" "$U" ensure "$SERIAL"
    case_ running_without_cache_setup 0 "READY $SERIAL " -- "$U" ensure "$SERIAL"
    case_ running_without_cache 0 'server already running' "READY $SERIAL " -- env UIA2_SERVER_HOME="$BAD/none" "$U" ensure "$SERIAL"
  else
    skip sha_mismatch "no cached APK to corrupt (run uia2-server.sh fetch)"
  fi
  rm -rf "$BAD"

  case_ ensure_after    0 "READY $SERIAL " '!installing' -- "$U" ensure "$SERIAL"

  if [ "${ADBD_RESTART:-}" = 1 ]; then
    "$ADB" -s "$SERIAL" root >/dev/null 2>&1; sleep 3; "$ADB" -s "$SERIAL" wait-for-device
    "$ADB" -s "$SERIAL" unroot >/dev/null 2>&1; sleep 3; "$ADB" -s "$SERIAL" wait-for-device
    case_ adbd_check    1 'NOT READY' -- "$U" check "$SERIAL"
    case_ adbd_repair   0 'restarting it' "READY $SERIAL " -- "$U" ensure "$SERIAL"
  else
    skip adbd_check "ADBD_RESTART not set"; skip adbd_repair "ADBD_RESTART not set"
  fi
fi

SCALES_AFTER="$(scales)"
if [ "$SCALES_AFTER" = "$SCALES_BEFORE" ]; then PASS=$((PASS + 1)); echo "PASS animation_scales_unchanged ($SCALES_AFTER)"
else FAIL=$((FAIL + 1)); echo "FAIL animation_scales_unchanged (before $SCALES_BEFORE, after $SCALES_AFTER)"; fi

echo "$PASS passed, $FAIL failed, $SKIP skipped - $OUT"
[ "$FAIL" = 0 ]
