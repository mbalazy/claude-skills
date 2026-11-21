#!/bin/bash
# android-regress.sh - run the Android driver's behaviour cases against a live emulator or phone and
# keep what each one printed. One file per case (command, stdout + stderr, exit code) plus
# a PASS/FAIL line per case against its expected exit code and output patterns.
#
#   ANDROID_SERIAL=<serial> [OTHER_SERIAL=<serial>] android-regress.sh <outdir> [GROUP ...]
#
# GROUP: core (device selection, server lifecycle, session), read (elements, el, waitid,
# waitfor, foreground, --settled on the fixture app), input (tapid, typeid, coordinates,
# type, button, lock), app (launch, relaunch, terminate, activate, openurl, screenshot,
# orientation, alert, wait, do), rig (android-rig-check.sh verdicts; needs FIXTURE_REPO,
# the fixture's tree, served by a Metro on RIG_PORT, default 8121; on a phone also the
# adb reverse cases, which touch only rules the run itself added) - default: every group.
# read, input and app need the fixture (tests/android-fixture) installed and running its JS, and the
# server READY (core leaves it running). FIXTURE_PKG / FIXTURE_SCHEME default to
# com.example.svcli / svp2cli; OTHER_PKG names a second app with the same testIDs (the
# fixture's embedded-bundle flavor) for the case where it starts over the first, and for
# the app chooser (two apps with one scheme). EXPO_PKG (com.example.svp2expo) is the Expo
# dev-client fixture, its dev server on EXPO_PORT (8120); absent or down = SKIPPED.
# OTHER_SERIAL: a second attached device for the cases that need two (ambiguity, a port
# forwarded to the other device); without it those cases are SKIPPED, not passed.
# ADBD_RESTART=1 adds the case that restarts adbd on ANDROID_SERIAL (`adb root` + `unroot`)
# to prove a server that says ready but cannot answer is detected and repaired; a `user`
# build (a retail phone) refuses `adb root`, so there it is SKIPPED with that reason.
# A physical device (not an emulator): the input group's lock cases are SKIPPED unless
# LOCK_ON_DEVICE=1 - a phone with a PIN stays locked after them, and every later case
# would run against the keyguard.
#
# The cases change the device: they stop and start the UiAutomator2 server and run a
# `uiautomator dump` loop for a few seconds. They leave the server RUNNING on
# ANDROID_SERIAL. read revokes the fixture's notification permission to show the dialog;
# input locks and unlocks the screen and leaves the fixture app on its home screen; app
# grants and revokes the notification permission (revoked at the end) and restarts the apps.
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
GROUPS_WANTED="${*:-core read input app rig}"
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
      !*) grep -qE -- "${p#!}" <<< "$out" && { ok=0; why="${why:+$why; }matched '${p#!}'"; } ;;
      *)  grep -qE -- "$p" <<< "$out" || { ok=0; why="${why:+$why; }no '$p'"; } ;;
    esac
  done
  if [ "$ok" = 1 ]; then PASS=$((PASS + 1)); echo "PASS $name"
  else FAIL=$((FAIL + 1)); echo "FAIL $name ($why) - $OUT/$name.txt"; fi
}
skip() { SKIP=$((SKIP + 1)); echo "SKIP $1 ($2)"; echo "skipped: $2" > "$OUT/$1.txt"; }

scales() {
  "$ADB" -s "$SERIAL" shell 'settings get global window_animation_scale; settings get global transition_animation_scale; settings get global animator_duration_scale' | tr -d '\r' | tr '\n' ' '
}

IS_EMULATOR=0
android_is_emulator "$SERIAL" && IS_EMULATOR=1
BUILD_TYPE="$("$ADB" -s "$SERIAL" shell getprop ro.build.type </dev/null | tr -d '\r')"

SCALES_BEFORE="$(scales)"
echo "target $SERIAL ($([ "$IS_EMULATOR" = 1 ] && echo emulator || echo "physical device, $BUILD_TYPE build")), other ${OTHER:-none}, groups: $GROUPS_WANTED, animation scales: $SCALES_BEFORE"

# The fixture app (tests/android-fixture) the read and input groups drive.
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
lbl() {   # the label (else value) of the first element with that id
  "$A" el "$1" 2>/dev/null | python3 -c 'import json, sys
e = json.load(sys.stdin)[0]; print(e.get("label", e.get("value", "")))'
}
# Puts the fixture's notification permission back to "never asked", so its request shows
# the dialog. Some vendor builds refuse `pm revoke` and `pm clear-permission-flags` from the
# shell (SecurityException: the shell lacks REVOKE_RUNTIME_PERMISSIONS); there the last
# answer stays, and the dialog still appears only while the permission is neither granted
# nor fixed by a second "Don't allow". Exit 1 with the reason when it cannot appear.
# A revoke that works kills the app.
perm_reset() {
  local o st
  o="$("$ADB" -s "$SERIAL" shell pm revoke "$PKG" android.permission.POST_NOTIFICATIONS 2>&1 </dev/null)"
  "$ADB" -s "$SERIAL" shell pm clear-permission-flags "$PKG" android.permission.POST_NOTIFICATIONS user-set user-fixed >/dev/null 2>&1 </dev/null
  st="$("$ADB" -s "$SERIAL" shell dumpsys package "$PKG" </dev/null | tr -d '\r' | grep -m1 'POST_NOTIFICATIONS: granted')"
  case "$st" in *granted=false*) case "$st" in *USER_FIXED*) ;; *) return 0 ;; esac ;; esac
  case "$o" in
    *SecurityException*) echo "the device refuses pm revoke from the shell and the permission stays ${st#*: } - uninstall and install the fixture (install -r keeps it)" ;;
    *) echo "the permission is ${st#*: } after pm revoke" ;;
  esac
  return 1
}

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

  if [ "${ADBD_RESTART:-}" = 1 ] && [ "$BUILD_TYPE" = user ]; then
    skip adbd_check "a user build refuses adb root"; skip adbd_repair "a user build refuses adb root"
  elif [ "${ADBD_RESTART:-}" = 1 ]; then
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
  if _why="$(perm_reset)"; then
    open_screen perm Perm-title
    tap_id Perm-notif; sleep 1.5
    case_ foreground_dialog 0 "^$PKG pid" '^focus: .*permissioncontroller' -- "$A" foreground
    case_ elements_dialog   0 'SYSTEM window' 'permission_deny_button' -- "$A" elements --names
    case_ waitid_under_dialog 1 'SYSTEM window' -- "$A" waitid Perm-title --timeout 1
    tap_id com.android.permissioncontroller:id/permission_deny_button; sleep 1
    case_ foreground_back   0 "^$PKG pid" -- "$A" foreground
  else
    for c in foreground_dialog elements_dialog waitid_under_dialog foreground_back; do skip "$c" "$_why"; done
  fi

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

if want_group input; then
  export ANDROID_SERIAL="$SERIAL"
  case_ in_usage_tapid   2 'usage: tapid ID' -- "$A" tapid
  case_ in_usage_typeid  2 'usage: typeid ID TEXT' -- "$A" typeid X
  case_ in_typeid_flag   2 'unknown flag for typeid' -- "$A" typeid X y --frob
  case_ in_usage_type    2 'usage: type' -- "$A" type
  case_ in_usage_button  2 'usage: button' -- "$A" button
  case_ in_bad_button    1 'unsupported button: FOO' -- "$A" button FOO
  case_ in_tap_fraction  2 'whole dp' -- "$A" tap 1.5 3
  case_ in_tap_offscreen 2 'is off-screen' -- "$A" tap 5000 100
  case_ in_longpress_bad 2 'DURATION_MS must be' -- "$A" longpress 10 10 abc
  case_ in_drag_bad      2 'SECONDS must be' -- "$A" drag 10 10 20 20 x

  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  open_screen components Comp-title
  case_ tapid_hit        0 'tapped id Comp-pressable-text' -- "$A" tapid Comp-pressable-text
  case_ tapid_effect     0 '^taps 1$' -- lbl Comp-taps
  case_ tapid_absent     1 "no element with id 'Nope-id'" -- "$A" tapid Nope-id
  case_ tapid_switch     0 '"checked":true' -- bash -c '"$1" tapid Comp-switch >/dev/null && sleep 0.3 && "$1" el Comp-switch' _ "$A"
  case_ tap_dp_centre    0 '^taps 2$' -- bash -c '
    c="$("$1" el Comp-pressable-text | python3 -c "import json,sys; r=json.load(sys.stdin)[0][\"rect\"]; print(r[0]+r[2]//2, r[1]+r[3]//2)")" || exit 1
    "$1" tap $c >/dev/null && sleep 0.4 && "$1" el Comp-taps | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"

  # A button sliding in from below the screen is not tapped mid-flight, and the screen
  # it belongs to is left as it was (the modal stays open).
  open_screen anim Anim-title
  tap_id Anim-modal-open
  case_ tapid_offscreen  1 'outside the screen' -- "$A" tapid Anim-modal-close
  case_ tapid_offscreen_untouched 0 '"name":"Anim-modal-close"' -- "$A" waitid Anim-modal-close --timeout 3
  "$ADB" -s "$SERIAL" shell input keyevent 4 </dev/null; sleep 1

  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  open_screen gest Gest-title
  case_ tapid_twice      1 '2 DISPLAYED elements' -- "$A" tapid Gest-dup
  case_ gestures         0 '^taps 3 doubles 1 longs 1$' -- bash -c '
    c="$("$1" el Gest-pad | python3 -c "import json,sys; r=json.load(sys.stdin)[0][\"rect\"]; print(r[0]+r[2]//2, r[1]+r[3]//2)")" || exit 1
    "$1" tap $c >/dev/null && "$1" doubletap $c >/dev/null && "$1" longpress $c >/dev/null || exit 1
    sleep 0.6; "$1" el Gest-counts | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  case_ drag_hold        0 '^drag dx (9[5-9]|10[0-5]) dy 0 held (1[12][0-9][0-9])$' -- bash -c '
    r="$("$1" el Gest-drag | python3 -c "import json,sys; r=json.load(sys.stdin)[0][\"rect\"]; print(r[0]+20, r[1]+r[3]//2)")" || exit 1
    set -- "$1" $r; "$1" drag "$2" "$3" $(( $2 + 100 )) "$3" 1.2 >/dev/null || exit 1
    sleep 0.4; "$1" el Gest-drag-out | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  case_ swipe_scrolls    0 '^scroll y [1-9][0-9]+$' -- bash -c '
    r="$("$1" el Gest-scroll | python3 -c "import json,sys; r=json.load(sys.stdin)[0][\"rect\"]; print(r[0]+r[2]//2, r[1]+r[3]-20, r[1]+20)")" || exit 1
    set -- "$1" $r; "$1" swipe "$2" "$3" "$2" "$4" >/dev/null || exit 1
    sleep 0.8; "$1" el Gest-scroll-y | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"

  # Text: the server sets it whole, so nothing is lost and Unicode arrives intact.
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  open_screen inputs Input-title
  _word="$(python3 -c 'print("word" * 25)')"
  for _f in controlled uncontrolled plain; do
    case_ "typeid_${_f}_100"   0 "typed into id Input-$_f: '$_word' \(read back\)" -- "$A" typeid "Input-$_f" "$_word"
    case_ "typeid_${_f}_pl"    0 "'zażółć' \(read back\)" -- "$A" typeid "Input-$_f" 'zażółć'
    case_ "typeid_${_f}_emoji" 0 "'😀 emoji' \(read back\)" -- "$A" typeid "Input-$_f" '😀 emoji'
    case_ "typeid_${_f}_quote" 0 'O.{1,2}Brien "x"' -- "$A" typeid "Input-$_f" "O'Brien \"x\""
    case_ "typeid_${_f}_mirror" 0 '^\[O.Brien "x"\]$' -- lbl "Input-$_f-mirror"
  done
  case_ typeid_append    0 'O.{1,2}Brien "x" tail. \(read back\)' -- "$A" typeid Input-controlled ' tail' --append
  case_ typeid_mask      1 "holds '\(512\) 555-0199', expected '5125550199'" -- "$A" typeid Input-phone 5125550199
  case_ typeid_expect    0 "'\(512\) 555-0199' \(read back\)" -- "$A" typeid Input-phone 5125550199 --expect '(512) 555-0199'
  case_ typeid_empty     0 "Input-controlled: '' \(read back\)" -- "$A" typeid Input-controlled ''
  case_ typeid_empty_el  0 '"value":"","hint":"Controlled"' -- "$A" el Input-controlled
  case_ typeid_append_placeholder 0 "Input-controlled: 'abc' \(read back\)" -- "$A" typeid Input-controlled abc --append
  # Return reaches the field: its onSubmitEditing counter moves.
  case_ typeid_return    0 '^changes [0-9]+ submits 1$' -- bash -c '"$1" typeid Input-controlled $'"'"'go\n'"'"' >/dev/null && sleep 0.5 && "$1" el Input-counts | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  case_ typeid_backslash_n 1 'backslash followed by n' -- "$A" typeid Input-controlled 'go\n'
  # A field without a placeholder: the text is replaced, not appended to what it holds.
  case_ typeid_plain_replace 0 "Input-plain: 'xyz' \(read back\)" -- bash -c '"$1" typeid Input-plain abc >/dev/null && "$1" typeid Input-plain xyz' _ "$A"
  case_ typeid_plain_append  0 "Input-plain: 'xyzq' \(read back\)" -- "$A" typeid Input-plain q --append
  case_ typeid_plain_clear   0 "Input-plain: '' \(read back\)" -- "$A" typeid Input-plain ''
  case_ typeid_not_field 1 'not a text field' -- "$A" typeid Input-counts x
  # A fresh start: no field has focus and no keyboard is up (a BACK with no keyboard
  # would send the app away instead).
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  open_screen inputs Input-title
  case_ type_no_focus    1 'no text field has keyboard focus' -- "$A" type zz
  tap_id Input-uncontrolled; sleep 0.6
  "$A" typeid Input-uncontrolled '' >/dev/null 2>&1
  case_ type_focused     0 'appended at its end' -- "$A" type 'ab ża'
  case_ type_focused_back 0 '^\[ab ża\]$' -- lbl Input-uncontrolled-mirror
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null

  # BACK: the app's BackHandler, a Modal's onRequestClose, and on the home screen the
  # app goes to the background with its process alive.
  open_screen back Back-title
  case_ back_handler     0 '^back presses 1$' -- bash -c '"$1" button BACK >/dev/null && sleep 0.5 && "$1" el Back-count | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  tap_id Back-open-modal; "$A" waitid Back-modal-text --timeout 5 >/dev/null 2>&1
  case_ back_modal       0 '^modal closes 1$' -- bash -c '"$1" button BACK >/dev/null && sleep 0.8 && "$1" el Back-modal-closes | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  open_screen home Home-title
  case_ back_home        0 '^alive [0-9]+' '!'"^$PKG pid" -- bash -c '"$1" button BACK >/dev/null && sleep 1 && "$1" foreground && echo "alive $("$2" -s "$3" shell pidof "$4" </dev/null)"' _ "$A" "$ADB" "$SERIAL" "$PKG"

  if [ "$IS_EMULATOR" = 1 ] || [ "${LOCK_ON_DEVICE:-}" = 1 ]; then
    case_ locked_before    0 '^false$' -- "$A" locked
    case_ lock             0 '^locked$' -- "$A" lock
    sleep 1
    case_ locked_after     0 '^true$' -- "$A" locked
    case_ lock_again       0 '^true$' -- bash -c '"$1" lock >/dev/null && sleep 0.5 && "$1" locked' _ "$A"
    case_ unlock           0 '^unlocked$' -- "$A" unlock
    case_ locked_unlocked  0 '^false$' -- "$A" locked
  else
    case_ locked_before    0 '^false$' -- "$A" locked
    for c in lock locked_after lock_again unlock locked_unlocked; do
      skip "$c" "a physical device: a PIN would keep it locked (LOCK_ON_DEVICE=1 runs it)"
    done
  fi
  open_screen home Home-title
fi

if want_group app; then
  export ANDROID_SERIAL="$SERIAL"
  OTHERP="${OTHER_PKG:-}"
  EXPO="${EXPO_PKG:-com.example.svp2expo}"
  EXPO_PORT="${EXPO_PORT:-8120}"
  case_ app_usage_launch   2 'usage: launch PACKAGE' -- "$A" launch
  case_ app_launch_args    2 'no launch arguments on Android' -- "$A" relaunch "$PKG" -RCT_jsLocation localhost:1
  case_ app_not_installed  1 'is not installed' -- "$A" launch com.example.notinstalled
  case_ app_openurl_nopkg  2 'needs the target package' -- env -u ANDROID_PACKAGE "$A" openurl "$SCHEME://screen/home"
  case_ app_openurl_flag   2 'unknown flag for openurl' -- "$A" openurl "$SCHEME://x" --frob
  case_ app_alert_sub      2 'unknown: alert frob' -- "$A" alert frob
  case_ app_shot_width     2 'must be a non-negative whole number' -- "$A" screenshot --width x

  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  case_ terminate_stopped  1 'is not running' -- "$A" terminate "$PKG"
  case_ launch_cold        0 "^launched $PKG pid [0-9]+$" -- "$A" launch "$PKG"
  "$A" waitid Home-title --timeout 15 >/dev/null 2>&1
  pid_cmp() {   # CMD -> "same"/"new" pid of the fixture across CMD
    local b a
    b="$("$ADB" -s "$SERIAL" shell pidof "$PKG" </dev/null | tr -d '\r')"
    "$A" "$1" "$PKG" >/dev/null || return 1
    a="$("$ADB" -s "$SERIAL" shell pidof "$PKG" </dev/null | tr -d '\r')"
    [ -n "$a" ] || { echo "no pid after $1"; return 1; }
    if [ "$a" = "$b" ]; then echo "same pid $a"; else echo "new pid $b -> $a"; fi
  }
  case_ activate_same_pid  0 '^same pid' -- pid_cmp activate
  case_ launch_running     0 '^same pid' -- pid_cmp launch
  case_ relaunch_new_pid   0 '^new pid' -- pid_cmp relaunch
  "$A" waitid Home-title --timeout 15 >/dev/null 2>&1
  case_ openurl_pkg        0 "opened $SCHEME://screen/inputs in $PKG" -- "$A" openurl "$SCHEME://screen/inputs" --package "$PKG"
  case_ openurl_landed     0 '"name":"Input-title"' -- "$A" waitid Input-title --timeout 5
  case_ openurl_env_pkg    0 "in $PKG" -- env ANDROID_PACKAGE="$PKG" "$A" openurl "$SCHEME://screen/home"
  # The URL reaches the app whole: `&`, a quote and a space survive the device's shell.
  case_ openurl_quoting    0 "deep link $SCHEME://screen/home\\?a=1&b=it's x\$" -- bash -c '
    t="$("$1" -s "$2" shell "date \"+%m-%d %H:%M:%S.000\"" </dev/null | tr -d "\r")"
    "$3" openurl "$4://screen/home?a=1&b=it'"'"'s x" --package "$5" >/dev/null || exit 1
    sleep 1; "$1" -s "$2" logcat -d -T "$t" -s ReactNativeJS:V </dev/null | grep -o "deep link .*"' _ "$ADB" "$SERIAL" "$A" "$SCHEME" "$PKG"
  case_ openurl_bad_intent 1 'unable to resolve Intent' -- "$A" openurl 'nosuchscheme://x' --package "$PKG"
  case_ terminate_running  0 "^terminated $PKG$" -- "$A" terminate "$PKG"
  case_ terminate_dead     0 '^dead$' -- bash -c '[ -z "$("$1" -s "$2" shell pidof "$3" </dev/null | tr -d "\r")" ] && echo dead' _ "$ADB" "$SERIAL" "$PKG"

  # Screen geometry: 1 px of the default screenshot is 1 dp; --width 0 is the device's pixels.
  _pxw="$("$ADB" -s "$SERIAL" shell dumpsys window displays </dev/null | tr -d '\r' | grep -m1 -oE 'cur=[0-9]+' | cut -d= -f2)"
  _dpw="$(awk -v v="$_pxw" -v d="$DENSITY" 'BEGIN { printf "%d", v / (d / 160) + 0.5 }')"
  _shot="$OUT/shot.png"
  case_ orientation        0 '^PORTRAIT$' -- "$A" orientation
  case_ screenshot_dp      0 "pixelWidth: $_dpw\$" -- bash -c '"$1" screenshot "$2" >/dev/null && sips -g pixelWidth "$2"' _ "$A" "$_shot"
  case_ screenshot_full    0 "pixelWidth: $_pxw\$" -- bash -c '"$1" screenshot "$2" --width 0 >/dev/null && sips -g pixelWidth "$2"' _ "$A" "$_shot"
  case_ screenshot_width   0 'pixelWidth: 200$' -- bash -c '"$1" screenshot "$2" --width 200 >/dev/null && sips -g pixelWidth "$2"' _ "$A" "$_shot"
  case_ wait_note          0 'fixed pause 2.5s' -- "$A" wait 2.5

  # The notification permission dialog: pm revoke kills the app, so it comes after.
  _perm_ok=1; _why="$(perm_reset)" || _perm_ok=0
  open_screen perm Perm-title
  case_ alert_none         1 'no system dialog on screen' -- "$A" alert
  case_ alert_dismiss_none 1 'no system dialog on screen' -- "$A" alert dismiss
  case_ alert_wait_none    1 'no system dialog appeared within 1s' -- "$A" alert wait 1
  if [ "$_perm_ok" = 1 ]; then
    tap_id Perm-notif
    case_ alert_wait         0 'send you notifications' -- "$A" alert wait 5
    case_ alert_text         0 'send you notifications' -- "$A" alert
    case_ alert_buttons      0 '^\["Allow","Don.t allow"\]$' -- "$A" alert buttons
    case_ alert_accept       0 '^accepted: .*notifications' -- "$A" alert accept
    case_ alert_granted      0 'POST_NOTIFICATIONS: granted=true' -- bash -c '"$1" -s "$2" shell dumpsys package "$3" </dev/null | grep -m1 "POST_NOTIFICATIONS: granted"' _ "$ADB" "$SERIAL" "$PKG"
    case_ alert_result       0 '^notif: granted$' -- bash -c 'sleep 0.5; "$1" el Perm-result | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  else
    for c in alert_wait alert_text alert_buttons alert_accept alert_granted alert_result; do skip "$c" "$_why"; done
  fi
  if _why="$(perm_reset)"; then
    open_screen perm Perm-title
    tap_id Perm-notif
    "$A" alert wait 5 >/dev/null 2>&1
    case_ alert_dismiss      0 '^dismissed: ' -- "$A" alert dismiss
    case_ alert_denied       0 '^notif: denied' -- bash -c 'sleep 0.5; "$1" el Perm-result | python3 -c "import json,sys; print(json.load(sys.stdin)[0][\"label\"])"' _ "$A"
  else
    for c in alert_dismiss alert_denied; do skip "$c" "$_why"; done
  fi
  perm_reset >/dev/null

  # The system chooser: two installed apps with one scheme and no package on the intent.
  if [ -n "$OTHERP" ] && "$ADB" -s "$SERIAL" shell pm path "$OTHERP" </dev/null 2>/dev/null | grep -q package:; then
    "$A" launch "$PKG" >/dev/null 2>&1; "$A" waitid Home-title --timeout 15 >/dev/null 2>&1
    "$ADB" -s "$SERIAL" shell am start -a android.intent.action.VIEW -d "$SCHEME://screen/home" >/dev/null 2>&1 </dev/null
    case_ chooser_alert    0 'Open with' -- bash -c 'sleep 1; "$1" alert' _ "$A"
    case_ chooser_accept   1 'has no allow button' -- "$A" alert accept
    case_ chooser_dismiss  0 '^dismissed: ' -- "$A" alert dismiss
    case_ chooser_gone     0 "^$PKG pid" '!ResolverActivity' -- bash -c 'sleep 0.5; "$1" foreground' _ "$A"
  else
    for c in chooser_alert chooser_accept chooser_dismiss chooser_gone; do skip "$c" "no OTHER_PKG installed"; done
  fi

  # An Expo dev-client: relaunch lands in the app; a plain start lands on its launcher.
  if "$ADB" -s "$SERIAL" shell pm path "$EXPO" </dev/null 2>/dev/null | grep -q package: \
     && curl -s -m 2 "http://127.0.0.1:$EXPO_PORT/status" | grep -q running; then
    case_ expo_relaunch    0 "^relaunched $EXPO pid [0-9]+$" -- "$A" relaunch "$EXPO"
    case_ expo_in_app      0 '"name":"Home-title"' "\"package\":\"$EXPO\"" -- "$A" waitid Home-title --timeout 20
    case_ expo_metro       0 'node' -- bash -c 'lsof -nP -iTCP:'"$EXPO_PORT"' -sTCP:ESTABLISHED | awk "NR > 1 { print \$1 }" | sort -u'
    "$ADB" -s "$SERIAL" shell am force-stop "$EXPO" </dev/null
    case_ expo_launch_cold 0 '"name":"Home-title"' -- bash -c '"$1" launch "$2" >/dev/null && "$1" waitid Home-title --timeout 20' _ "$A" "$EXPO"
    "$ADB" -s "$SERIAL" shell am force-stop "$EXPO" </dev/null
    case_ expo_plain_start 0 'DevLauncherActivity' -- bash -c '"$1" -s "$2" shell am start -W -n "$3/.MainActivity" </dev/null >/dev/null; sleep 1; "$4" foreground' _ "$ADB" "$SERIAL" "$EXPO" "$A"
    "$ADB" -s "$SERIAL" shell am force-stop "$EXPO" </dev/null
  else
    for c in expo_relaunch expo_in_app expo_metro expo_launch_cold expo_plain_start; do skip "$c" "$EXPO not installed or no dev server on :$EXPO_PORT"; done
  fi

  # A whole route in one call; a failing step names itself and prints the screen.
  case_ do_route           0 'typed into id Input-controlled' '^\[O.Brien x\]|\[O.Brien x\]' '!step failed$' -- "$A" do \
    "relaunch $PKG" 'waitid Home-title --timeout 15' "openurl $SCHEME://screen/inputs --package $PKG" \
    'waitid Input-title --timeout 5' 'tapid Input-uncontrolled' 'typeid Input-controlled "O'"'"'Brien x"' \
    '# a comment' '?tapid Nope-id' 'waitid Input-controlled-mirror'
  case_ do_tolerated       0 'step failed - tolerated' -- "$A" do '?tapid Nope-id' 'orientation'
  case_ do_stops           1 'the batch stopped at: tapid Nope-id' "front app: $PKG pid" 'Input-title' '!PORTRAIT' -- "$A" do 'tapid Nope-id' 'orientation'
  case_ do_stdin           0 '^PORTRAIT$' -- bash -c 'printf "orientation\n# c\n" | "$1" do' _ "$A"
  case_ do_usage           2 'usage: tapid ID' '!the batch stopped' -- "$A" do 'tapid'
  "$ADB" -s "$SERIAL" shell input keyevent 4 </dev/null
  open_screen home Home-title
fi

if want_group rig; then
  export ANDROID_SERIAL="$SERIAL"
  RC="$HERE/android-rig-check.sh"
  RREPO="${FIXTURE_REPO:-}"
  RPORT="${RIG_PORT:-8121}"
  RH="$(android_host_for "$SERIAL" 0)"; RH="${RH%:0}"   # the Mac as the device sees it
  # A phone: the reverse rules there now are not this run's to remove.
  RV_BEFORE=""
  [ "$IS_EMULATOR" = 1 ] || RV_BEFORE="$("$ADB" -s "$SERIAL" reverse --list </dev/null | tr -d '\r' | awk '{ print $2 }')"
  rv_ours() { [ "$IS_EMULATOR" = 0 ] && ! grep -qx "tcp:$1" <<< "$RV_BEFORE"; }
  _t="$(mktemp -d)"; echo "console.log('x');" > "$_t/index.js"
  case_ rig_usage          2 'unknown option: --frob' -- "$RC" --frob
  case_ rig_timeout_bad    2 'must be whole seconds' -- "$RC" --timeout x
  case_ rig_no_package     2 'pass --package' -- "$RC" --repo "$_t"
  case_ rig_no_entry       2 'entry file not found' -- "$RC" --repo "$_t" --package "$PKG" --entry nope.js
  case_ rig_not_installed  1 'RIG DEAD: com.example.notinstalled is not installed' -- "$RC" --repo "$_t" --package com.example.notinstalled
  case_ rig_no_metro       1 'RIG DEAD: no Metro (for this tree|is running at all)' -- "$RC" --repo "$_t" --package "$PKG"
  if [ "$(android_attached | grep -c .)" -gt 1 ]; then
    case_ rig_ambiguous    2 'refusing to guess' -- env -u ANDROID_SERIAL "$RC" --repo "$_t" --package "$PKG"
  else
    skip rig_ambiguous "only one device attached"
  fi
  rm -rf "$_t"
  if [ -n "$RREPO" ] && [ -f "$RREPO/index.js" ]; then
    _sum="$(shasum "$RREPO/index.js" | cut -d' ' -f1)"
    case_ rig_ok           0 '^RIG OK' 'marker: +RIGCHECK_[0-9_]+ seen' 'came up clean' -- "$RC" --repo "$RREPO" --package "$PKG" --port "$RPORT"
    case_ rig_marker_gone  0 '^restored$' -- bash -c '[ "$(shasum "$1" | cut -d" " -f1)" = "$2" ] && echo restored' _ "$RREPO/index.js" "$_sum"
    # The redirect keeps every other key of the prefs file.
    "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
    printf '%s\n' "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>" '<map>' '    <int name="regress_keep" value="7" />' \
      "    <string name=\"debug_http_host\">$RH:$RPORT</string>" '</map>' \
      | "$ADB" -s "$SERIAL" shell "run-as $PKG sh -c 'cat > shared_prefs/${PKG}_preferences.xml'"
    case_ rig_dead_port    1 'nothing listens on :8199' "debug_http_host: was $RH:$RPORT, now $RH:8199" -- "$RC" --repo "$RREPO" --package "$PKG" --port 8199 --timeout 8
    case_ rig_prefs_kept   0 'regress_keep' -- "$ADB" -s "$SERIAL" shell "run-as $PKG cat shared_prefs/${PKG}_preferences.xml"
    case_ rig_back         0 '^RIG OK' "was $RH:8199, now $RH:$RPORT" -- "$RC" --repo "$RREPO" --package "$PKG" --port "$RPORT"
    # A phone reaches Metro through adb reverse: the check adds a missing rule, --reload
    # (which writes nothing) names it, and a rule that leads elsewhere is left alone.
    if rv_ours "$RPORT"; then
      "$ADB" -s "$SERIAL" reverse --remove "tcp:$RPORT" </dev/null >/dev/null 2>&1
      case_ rig_reload_no_rule 1 "no adb reverse rule for tcp:$RPORT" -- "$RC" --repo "$RREPO" --package "$PKG" --port "$RPORT" --reload
      case_ rig_rule_added   0 '^RIG OK' "reverse: was none, now tcp:$RPORT -> Mac tcp:$RPORT" -- "$RC" --repo "$RREPO" --package "$PKG" --port "$RPORT"
    else
      for c in rig_reload_no_rule rig_rule_added; do
        skip "$c" "$([ "$IS_EMULATOR" = 1 ] && echo "an emulator needs no reverse rule" || echo "tcp:$RPORT was reversed before the run - not this run's to remove")"
      done
    fi
    if rv_ours 8198; then
      "$ADB" -s "$SERIAL" reverse tcp:8198 "tcp:$RPORT" </dev/null >/dev/null 2>&1
      case_ rig_rule_elsewhere 1 "tcp:8198 is reversed to the Mac's tcp:$RPORT" -- "$RC" --repo "$RREPO" --package "$PKG" --port 8198
      case_ rig_rule_kept    0 "^tcp:$RPORT\$" -- bash -c '"$1" -s "$2" reverse --list </dev/null | awk "\$2 == \"tcp:8198\" { print \$3 }"' _ "$ADB" "$SERIAL"
      "$ADB" -s "$SERIAL" reverse --remove tcp:8198 </dev/null >/dev/null 2>&1
    else
      for c in rig_rule_elsewhere rig_rule_kept; do skip "$c" "$([ "$IS_EMULATOR" = 1 ] && echo "an emulator needs no reverse rule" || echo "tcp:8198 was reversed before the run")"; done
    fi
    if [ -n "${OTHER_PKG:-}" ] && "$ADB" -s "$SERIAL" shell unzip -l "$("$ADB" -s "$SERIAL" shell pm path "$OTHER_PKG" </dev/null | sed -n 's/^package://p' | tr -d '\r')" </dev/null 2>/dev/null | grep 'assets/index.android.bundle' >/dev/null; then
      case_ rig_embedded   1 'runs its EMBEDDED bundle' 'SUSPECT' -- "$RC" --repo "$RREPO" --package "$OTHER_PKG" --port 8199 --timeout 20
      case_ rig_embedded_ok 0 '^RIG OK' 'was NOT used this time' -- "$RC" --repo "$RREPO" --package "$OTHER_PKG" --port "$RPORT"
    else
      for c in rig_embedded rig_embedded_ok; do skip "$c" "no OTHER_PKG with an embedded bundle"; done
    fi
    _ep="${EXPO_PORT:-8120}"
    if curl -s -m 2 "http://127.0.0.1:$_ep/status" | grep running >/dev/null; then
      case_ rig_other_tree 1 "no Metro for this tree on :$_ep" "listen: +:$_ep .*not this repo" -- "$RC" --repo "$RREPO" --package "$PKG" --port "$_ep" --timeout 10
      "$RC" --repo "$RREPO" --package "$PKG" --port "$RPORT" >/dev/null 2>&1
    else
      skip rig_other_tree "no other tree's Metro on :$_ep"
    fi
  else
    for c in rig_ok rig_marker_gone rig_dead_port rig_prefs_kept rig_back rig_reload_no_rule rig_rule_added \
             rig_rule_elsewhere rig_rule_kept rig_embedded rig_embedded_ok rig_other_tree; do
      skip "$c" "FIXTURE_REPO not set"
    done
  fi
  # The reverse rules the checks above added for ports nothing should keep using.
  for _p in 8199 "${EXPO_PORT:-8120}"; do
    rv_ours "$_p" && "$ADB" -s "$SERIAL" reverse --remove "tcp:$_p" </dev/null >/dev/null 2>&1
  done
fi

SCALES_AFTER="$(scales)"
if [ "$SCALES_AFTER" = "$SCALES_BEFORE" ]; then PASS=$((PASS + 1)); echo "PASS animation_scales_unchanged ($SCALES_AFTER)"
else FAIL=$((FAIL + 1)); echo "FAIL animation_scales_unchanged (before $SCALES_BEFORE, after $SCALES_AFTER)"; fi

echo "$PASS passed, $FAIL failed, $SKIP skipped - $OUT"
[ "$FAIL" = 0 ]
