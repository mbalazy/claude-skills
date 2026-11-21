#!/bin/bash
# android-regress.sh - run the Android driver's behaviour cases against a live emulator and
# keep what each one printed. One file per case (command, stdout + stderr, exit code) plus
# a PASS/FAIL line per case against its expected exit code and output patterns.
#
#   ANDROID_SERIAL=<serial> [OTHER_SERIAL=<serial>] android-regress.sh <outdir> [GROUP ...]
#
# GROUP: core (device selection, server lifecycle, session), read (elements, el, waitid,
# waitfor, foreground, --settled on the fixture app) - default: every group.
# read needs the fixture (tests/android-fixture) installed and running its JS, and the
# server READY (core leaves it running). FIXTURE_PKG / FIXTURE_SCHEME default to
# com.example.svcli / svp2cli; OTHER_PKG names a second app with the same testIDs (the
# fixture's embedded-bundle flavor) for the case where it starts over the first.
# OTHER_SERIAL: a second attached device for the cases that need two (ambiguity, a port
# forwarded to the other device); without it those cases are SKIPPED, not passed.
# ADBD_RESTART=1 adds the case that restarts adbd on ANDROID_SERIAL (`adb root` + `unroot`)
# to prove a server that says ready but cannot answer is detected and repaired.
#
# The cases change the device: they stop and start the UiAutomator2 server and run a
# `uiautomator dump` loop for a few seconds. They leave the server RUNNING on
# ANDROID_SERIAL. read revokes the fixture's notification permission to show the dialog.
# Animation scales are read before and after: a change is a FAIL.
# Exit 0 = every case passed, 1 = at least one FAIL.

set -uo pipefail

OUT="${1:?usage: android-regress.sh <outdir> [GROUP ...]}"; shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="$HERE/android-ui.sh"
U="$HERE/uia2-server.sh"
. "$HERE/android-lib.sh"
SERIAL="${ANDROID_SERIAL:?set ANDROID_SERIAL to the emulator the cases run on}"
OTHER="${OTHER_SERIAL:-}"
GROUPS_WANTED="${*:-core read}"
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

if want_group read; then
  # The read commands against the fixture app (tests/android-fixture), already installed
  # and showing its JS (Metro running): screens are opened by deep link, controls tapped
  # with `adb input` at the centre `el` reports - the driver's own tap comes later.
  export ANDROID_SERIAL="$SERIAL"
  PKG="${FIXTURE_PKG:-com.example.svcli}"
  SCHEME="${FIXTURE_SCHEME:-svp2cli}"
  DENSITY="$("$ADB" -s "$SERIAL" shell wm density </dev/null | tr -d '\r' \
    | awk -F': *' '/Physical density/ { p = $2 } /Override density/ { o = $2 } END { print (o != "" ? o : p) }')"
  open_screen() {   # NAME TITLE-ID
    "$ADB" -s "$SERIAL" shell am start -W -a android.intent.action.VIEW -d "$SCHEME://screen/$1" "$PKG" >/dev/null 2>&1 </dev/null
    "$A" waitid "$2" --timeout 15 >/dev/null 2>&1 || echo "WARN: $2 did not appear"
  }
  tap_id() {
    local xy
    xy="$("$A" el "$1" 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)[0]["rect"]; s = float(sys.argv[1]) / 160
print("%d %d" % ((r[0] + r[2] / 2) * s, (r[1] + r[3] / 2) * s))' "$DENSITY")" || { echo "WARN: cannot tap $1"; return 1; }
    # shellcheck disable=SC2086
    "$ADB" -s "$SERIAL" shell input tap $xy </dev/null
  }

  case_ read_usage_waitid 2 'usage: waitid ID' -- "$A" waitid
  case_ read_usage_waitfor 2 'usage: waitfor REGEX' -- "$A" waitfor
  case_ read_bad_flag    2 'unknown flag for elements' -- "$A" elements --frob
  case_ read_bad_grep    2 'not a valid regular expression' -- "$A" elements --grep '('
  case_ read_bad_timeout 2 'must be a non-negative number' -- "$A" waitid X --timeout abc
  case_ read_el_flag     2 'unknown flag for el' -- "$A" el X --exists

  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  open_screen components Comp-title
  case_ elements_components 0 '"name":"Comp-switch"' '"name":"Comp-text"' '"name":"Comp-busy"' \
    '!Comp-text-inner' '!Comp-opacity0' -- "$A" elements
  case_ elements_names   0 "$(printf '^Comp-switch\tSwitch\t')" -- "$A" elements --names
  case_ elements_grep    0 'Comp-busy' '!Comp-text' -- "$A" elements --grep busy
  case_ elements_all_more 0 '^more with --all' -- bash -c '
    a="$("$1" elements --all | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" || exit 1
    d="$("$1" elements | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")" || exit 1
    [ "$a" -gt "$d" ] && echo "more with --all ($a > $d)" || echo "not more ($a, $d)"' _ "$A"
  case_ el_switch        0 '"checked":false' -- "$A" el Comp-switch
  case_ el_missing       1 "no element with id 'Nope-id'" -- "$A" el Nope-id
  case_ waitid_hit       0 '"name":"Comp-text"' "matched id 'Comp-text'" -- "$A" waitid Comp-text --timeout 5
  case_ waitid_missing   1 'nothing displayed on screen' -- "$A" waitid Nope-id --timeout 1
  case_ waitid_exists    0 '"name":"Comp-switch"' -- "$A" waitid Comp-switch --exists --timeout 2
  case_ waitfor_hit      0 'Plain text' -- "$A" waitfor 'Plain text' --timeout 5
  case_ waitfor_miss     1 'nothing matching' 'on screen now' 'Comp-switch' -- "$A" waitfor 'zz-not-there' --timeout 1
  case_ settled_still    0 'Comp-switch' -- "$A" elements --settled
  case_ foreground_app   0 "^$PKG pid [0-9]+" '!focus:' -- "$A" foreground

  # Motion: the tree is read at every frame (waitForIdleTimeout=0), so endless loops do
  # not slow a read and --settled is what tells a moving screen from a still one.
  open_screen anim Anim-title
  tap_id Anim-toggle-loop; tap_id Anim-toggle-rea; sleep 0.5
  case_ elements_anim_fast 0 '^fast' -- bash -c '
    t0=$(python3 -c "import time; print(time.time())"); "$1" elements >/dev/null || exit 1
    python3 -c "import sys, time; d = time.time() - float(sys.argv[1]); print(\"%s %.2fs\" % (\"fast\" if d < 0.5 else \"slow\", d))" "$t0"' _ "$A"
  case_ settled_loops    3 'changed between two reads' -- "$A" elements --settled
  tap_id Anim-toggle-loop; tap_id Anim-toggle-rea; sleep 0.5
  tap_id Anim-slide
  case_ settled_slide    3 'changed between two reads' -- "$A" elements --settled
  case_ settled_after_slide 0 -- "$A" elements --settled
  tap_id Anim-modal-open
  case_ waitid_modal_on_screen 0 '^on screen' -- bash -c '
    r="$("$1" waitid Anim-modal-close --timeout 5)" || exit 1
    printf "%s" "$r" | python3 -c "
import json, sys
e = json.load(sys.stdin)[0]; y = e[\"rect\"][1]
print((\"on screen\" if e[\"on_screen\"] and y < float(sys.argv[1]) else \"NOT on screen\") + \" y=%s\" % y)" "$2"' \
    _ "$A" "$("$ADB" -s "$SERIAL" shell wm size </dev/null | tr -d '\r' \
             | awk -v d="$DENSITY" -F'[ x]' '/size/ { h = $NF } END { print h * 160 / d }')"
  "$ADB" -s "$SERIAL" shell input keyevent 4 </dev/null; sleep 1

  # A fresh start empties the inputs; the placeholder must not read as a value.
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  open_screen inputs Input-title
  case_ el_empty_input   0 '"value":""' '"hint":"Controlled"' -- "$A" el Input-controlled
  tap_id Input-controlled; sleep 0.8
  "$ADB" -s "$SERIAL" shell input text abc </dev/null; sleep 0.8
  case_ el_typed_input   0 '"value":"abc"' '!"hint"' -- "$A" el Input-controlled
  "$ADB" -s "$SERIAL" shell input keyevent 4 </dev/null; sleep 0.5

  # A system window in front: the permission dialog is the active window.
  "$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 </dev/null
  "$ADB" -s "$SERIAL" shell pm clear-permission-flags "$PKG" android.permission.POST_NOTIFICATIONS user-set user-fixed >/dev/null 2>&1 </dev/null
  open_screen perm Perm-title
  tap_id Perm-notif; sleep 1.5
  case_ foreground_dialog 0 "^$PKG pid" '^focus: .*permissioncontroller' -- "$A" foreground
  case_ elements_dialog   0 'SYSTEM window' 'permission_deny_button' -- "$A" elements --names
  case_ waitid_under_dialog 1 'SYSTEM window' -- "$A" waitid Perm-title --timeout 1
  tap_id com.android.permissioncontroller:id/permission_deny_button; sleep 1
  case_ foreground_back   0 "^$PKG pid" -- "$A" foreground

  # Another app with the same testIDs starting over this one: for a moment the tree
  # still holds this app's window, and that must not count as a hit.
  if [ -n "${OTHER_PKG:-}" ]; then
    open_screen home Home-title
    "$ADB" -s "$SERIAL" shell am force-stop "$OTHER_PKG" </dev/null
    _act="$("$ADB" -s "$SERIAL" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$OTHER_PKG" </dev/null | tr -d '\r' | tail -1)"
    # waitid starts once focus has left this app (else a hit on it would be correct): the
    # tree still shows this app's window for a few tens of ms after that.
    "$ADB" -s "$SERIAL" shell am start -n "$_act" >/dev/null 2>&1 </dev/null &
    for _i in $(seq 1 50); do
      _f="$("$ADB" -s "$SERIAL" shell dumpsys window </dev/null 2>/dev/null | grep -m1 mCurrentFocus || true)"
      case "$_f" in *" $PKG/"*) ;; *) break ;; esac
    done
    case_ waitid_new_window 0 "\"package\":\"$OTHER_PKG\"" -- "$A" waitid Home-title --timeout 10
    wait
    "$ADB" -s "$SERIAL" shell am force-stop "$OTHER_PKG" </dev/null
  else
    skip waitid_new_window "no OTHER_PKG (an app with the same testIDs, e.g. the fixture's embedded-bundle flavor)"
  fi
fi

SCALES_AFTER="$(scales)"
if [ "$SCALES_AFTER" = "$SCALES_BEFORE" ]; then PASS=$((PASS + 1)); echo "PASS animation_scales_unchanged ($SCALES_AFTER)"
else FAIL=$((FAIL + 1)); echo "FAIL animation_scales_unchanged (before $SCALES_BEFORE, after $SCALES_AFTER)"; fi

echo "$PASS passed, $FAIL failed, $SKIP skipped - $OUT"
[ "$FAIL" = 0 ]
