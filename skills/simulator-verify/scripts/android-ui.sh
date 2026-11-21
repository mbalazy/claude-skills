#!/bin/bash
# android-ui.sh - drive an Android emulator (or a device over adb) with the same command
# vocabulary, flags and exit codes as sim-ui.sh drives the iOS simulator.
# Lifecycle via adb, UI observation/interaction via the UiAutomator2 server's HTTP API
# (the open-source appium-uiautomator2-server, run without Appium - see uia2-server.sh).
#
# Usage:
#   android-ui.sh elements [--all] [--settled] [--grep REGEX] [--names]
#                                           # element tree as compact JSON, rects in dp (--all: every visible node;
#                                           #  --settled: two reads $SIMUI_SETTLE_SECONDS (2) apart, exit 3 if they differ;
#                                           #  --grep: keep elements where ONE field (type, label, name or value) matches;
#                                           #  --names: one line per element instead of JSON)
#   android-ui.sh waitid ID [--timeout S] [--exists]   # poll until the element with that testID is displayed, on screen,
#                                           #  in the focused app's window (--exists: anywhere in the tree - cannot tell
#                                           #  "scrolled out of a list" from "absent": off-screen rows have no node)
#   android-ui.sh el ID                     # type/label/value/checked/hint/rect/displayed/package of every element with that testID
#   android-ui.sh tapid ID                  # tap the one element with that testID that waitid would accept (refused: none, or two apart)
#   android-ui.sh typeid ID TEXT [--append] [--expect VALUE]   # set a field's text by testID, then read it back (exit 1 if it differs);
#                                           #  a trailing newline is Return, pressed after the read-back
#   android-ui.sh tap X Y                   # coordinates in dp (whole numbers, as `elements` prints them)
#   android-ui.sh doubletap X Y
#   android-ui.sh longpress X Y [DURATION_MS]
#   android-ui.sh swipe X1 Y1 X2 Y2 [DURATION_MS]
#   android-ui.sh drag X1 Y1 X2 Y2 [SECONDS]    # press, hold SECONDS (default 0.5), drag (reordering, sliders)
#   android-ui.sh type "text"               # into the field with keyboard focus, APPENDED at its end (not at the cursor);
#                                           #  exit 1 when no field has focus - prefer typeid when the field has a testID
#   android-ui.sh button HOME|ENTER|VOLUME_UP|VOLUME_DOWN|BACK   # BACK is Android's system back (no iOS twin)
#   android-ui.sh lock | unlock | locked    # screen off / on + keyguard dismissed (no PIN); `locked` prints true/false
#   android-ui.sh waitfor REGEX [--timeout S] [--all]   # poll the tree until it matches (beats a fixed sleep)
#   android-ui.sh foreground                # package + pid + activity of the app in front; a system window holding focus is named
#   android-ui.sh activate PACKAGE          # bring an app to the foreground WITHOUT restarting it (same pid)
#   android-ui.sh launch   PACKAGE          # start it (an Expo dev-client that is not running starts INTO the app, below)
#   android-ui.sh relaunch PACKAGE          # force-stop + start -> a new process and a fresh JS bundle from Metro
#   android-ui.sh terminate PACKAGE         # force-stop (exit 1 when it was not running)
#                                           #  No launch arguments on Android: the Metro an app loads from is the
#                                           #  debug_http_host pref, which the rig check sets - extra ARGs are refused.
#                                           #  An Expo dev-client (an exp+<slug> scheme) is started with its
#                                           #  exp+<slug>://expo-development-client/?url=... link, so it lands in the app
#                                           #  and not on the launcher's server list; the server is the app's own
#                                           #  debug_http_host, else 10.0.2.2:$METRO_PORT. Its FIRST start after an install
#                                           #  covers the app with the dev menu's intro sheet: tap its Continue once.
#   android-ui.sh openurl URL [--package PACKAGE]   # deep link INTO that package ($ANDROID_PACKAGE when no flag):
#                                           #  without one, two apps with the scheme bring up the system chooser. A link
#                                           #  sent while the JS bundle is still loading is lost - waitid first.
#   android-ui.sh orientation               # PORTRAIT / LANDSCAPE of the screen now
#   android-ui.sh alert                     # text of the system dialog in front (permission, app chooser, Play Protect,
#                                           #  any system window over the app); exit 1 if none. An app's own Alert.alert
#                                           #  is part of the app's window: read it with `elements`, tap it with `tapid`/`tap`
#   android-ui.sh alert buttons             # labels of the dialog's buttons
#   android-ui.sh alert wait [SECONDS]      # poll until a dialog shows up (default 15s)
#   android-ui.sh alert accept [--all]      # allow a permission dialog; --all drains the queue
#   android-ui.sh alert dismiss [--all]     # deny a permission dialog, close a chooser; other windows are refused
#   android-ui.sh screenshot [OUT.png] [--width N]   # default: resampled to the screen's dp width (1 px == 1 dp);
#                                           #  --width N overrides, 0 = full resolution
#   android-ui.sh wait [SECONDS]            # plain pause, for use inside `do`
#   android-ui.sh do 'STEP' 'STEP' ...      # run several of the above in ONE process and ONE round trip
#                                           # (steps read from stdin when no args; '?step' may fail; '#step' is a comment;
#                                           #  a failing step prints the front app and the visible labelled elements)
#   android-ui.sh devices                   # attached devices: serial, AVD name (emulator) or model, state
#   android-ui.sh session                   # the UiAutomator2 session every command reuses, with its two settings
#
# Exit codes (as sim-ui.sh): 0 ok, 1 the step failed, 2 bad usage or an ambiguous device,
# 3 `elements --settled` saw the screen change. Errors go to stderr with the cause named.
#
# Device selection: $ANDROID_SERIAL if set, else the only attached device. With more than
# one attached and $ANDROID_SERIAL unset the script REFUSES rather than picking one.
# Server: $U2_PORT if set, else this device's `adb forward` to tcp:6790. A U2_PORT that
# `adb forward --list` shows forwarded for ANOTHER device is refused: two emulators from
# one system image answer every request identically, so the wrong one would answer as
# confidently as the right one. The server is never started here - its absence is an
# error naming the command that starts it (uia2-server.sh ensure <serial>).
#
# Session: the server keeps one session; a second POST /session silently replaces the
# first and resets its settings to waitForIdleTimeout=10000 (every call on an animated
# screen then takes 10 s) and disableIdLocatorAutocompletion=false (a bare testID is then
# never found). So every process reuses the session from GET /sessions and re-applies
# waitForIdleTimeout=0 and disableIdLocatorAutocompletion=true before its first request.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/android-lib.sh"

_MEMO_SERIAL=""     # the target serial, decided once per process
_MEMO_PORT=""       # host port of that serial's server, owner-checked
_MEMO_SID=""        # the reused session, settings applied
_MEMO_SCALE=""      # px per dp of the target (wm density / 160)

# Prints the serial. Inside $(...) `set -e` is NOT inherited (bash 3.2), so a refusal
# is passed on with an explicit exit, or the caller would get an empty serial.
serial() {
  if [ -z "$_MEMO_SERIAL" ]; then _MEMO_SERIAL="$(android_serial)" || exit $?; fi
  echo "$_MEMO_SERIAL"
}

# Resolves the serial and its server port once per process. Call it directly (not in
# $(...)): the memo would die with the subshell.
ensure_u2() {
  local rc
  [ -n "$_MEMO_PORT" ] && return 0
  _MEMO_SERIAL="$(serial)"
  if _MEMO_PORT="$(android_u2_port "$_MEMO_SERIAL")"; then :; else
    rc=$?; _MEMO_PORT=""
    if [ "$rc" = 3 ]; then
      echo "  No UiAutomator2 server is reachable for $_MEMO_SERIAL. Start it with:" >&2
      echo "    $HERE/uia2-server.sh ensure $_MEMO_SERIAL" >&2
      exit 1
    fi
    exit "$rc"
  fi
}

# Sets $_MEMO_SID (never call as sid=$(session)) and $_SESSION_INFO.
session() {
  local out
  [ -n "$_MEMO_SID" ] && return 0
  ensure_u2
  if ! out="$(python3 "$HERE/u2_client.py" session --port "$_MEMO_PORT" 2>&1)"; then
    echo "ERROR: $out" >&2
    echo "  Check the server: $HERE/uia2-server.sh check $_MEMO_SERIAL (ensure restarts it)" >&2
    exit 1
  fi
  _MEMO_SID="${out%% *}"
  _SESSION_INFO="$out"
}

# px per dp: `wm density` / 160 (420 dpi emulator = 2.625, a 480 dpi phone = 3). An
# override (`wm density N`) is what the app renders with, so it wins over the physical one.
scale() {
  local d
  if [ -z "$_MEMO_SCALE" ]; then
    d="$("$ADB" -s "$_MEMO_SERIAL" shell wm density 2>/dev/null </dev/null | tr -d '\r' \
         | awk -F': *' '/Physical density/ { p = $2 } /Override density/ { o = $2 } END { print (o != "" ? o : p) }' || true)"
    [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -gt 0 ] || { echo "ERROR: could not read the screen density of $_MEMO_SERIAL (wm density)" >&2; exit 1; }
    _MEMO_SCALE="$(awk -v d="$d" 'BEGIN { printf "%.4f", d / 160 }')"
  fi
}

# dp -> px for `input`: the scale is the one every rect was divided by.
px() { awk -v v="$1" -v s="$_MEMO_SCALE" 'BEGIN { printf "%d", v * s + 0.5 }'; }

# Coordinates are whole dp inside the screen as it is NOW (`cur=` follows the rotation).
# An unreadable size warns and lets the call through, as sim-ui.sh does.
assert_in_bounds() {
  local cur w h x y
  cur="$("$ADB" -s "$_MEMO_SERIAL" shell dumpsys window displays 2>/dev/null </dev/null | tr -d '\r' \
         | grep -m1 -oE 'cur=[0-9]+x[0-9]+' || true)"
  while [ "$#" -ge 2 ]; do
    x="$1"; y="$2"; shift 2
    case "$x,$y" in
      ,*|*,|*[!0-9,]*) echo "ERROR: coordinates must be non-negative whole dp, got '$x','$y'" >&2; exit 2 ;;
    esac
    [ -n "$cur" ] || continue
    cur="${cur#cur=}"
    w="$(awk -v v="${cur%x*}" -v s="$_MEMO_SCALE" 'BEGIN { printf "%d", v / s }')"
    h="$(awk -v v="${cur#*x}" -v s="$_MEMO_SCALE" 'BEGIN { printf "%d", v / s }')"
    if [ "$x" -ge "$w" ] || [ "$y" -ge "$h" ]; then
      echo "ERROR: $x,$y is off-screen - this device is ${w}x${h} dp now." >&2
      echo "  Screenshots of it are ${cur} PIXELS: divide by $_MEMO_SCALE to get dp." >&2
      exit 2
    fi
    cur="cur=$cur"
  done
  [ -n "$cur" ] || echo "WARN: could not read the screen size - coordinates not range-checked." >&2
}

# `input` without a session: taps and swipes go through the system's input injection,
# which needs no UiAutomation and works while the server is busy.
adb_input() {
  "$ADB" -s "$_MEMO_SERIAL" shell input "$@" </dev/null
}

# The lock state as `locked` reports it: the screen is asleep, or the keyguard is up.
lock_state() {
  local wake kg
  wake="$("$ADB" -s "$_MEMO_SERIAL" shell dumpsys power 2>/dev/null </dev/null | tr -d '\r' \
          | sed -nE 's/^ *mWakefulness=([A-Za-z]+).*/\1/p' | head -1 || true)"
  kg="$("$ADB" -s "$_MEMO_SERIAL" shell dumpsys window 2>/dev/null </dev/null | tr -d '\r' \
        | grep -m1 -oE 'isKeyguardShowing=(true|false)' || true)"
  if [ -z "$wake" ] || [ -z "$kg" ]; then
    echo "ERROR: could not read the lock state of $_MEMO_SERIAL (dumpsys power: '${wake}', dumpsys window: '${kg}')" >&2
    exit 1
  fi
  if [ "$wake" != Awake ] || [ "$kg" = isKeyguardShowing=true ]; then echo true; else echo false; fi
}

# The package is installed: `pm path` prints a `package:` line for every APK of it.
need_pkg() {
  local p
  p="$("$ADB" -s "$_MEMO_SERIAL" shell pm path "$1" 2>/dev/null </dev/null | tr -d '\r' || true)"
  case "$p" in package:*) ;; *) echo "ERROR: $1 is not installed on $_MEMO_SERIAL" >&2; exit 1 ;; esac
}

# PACKAGE -> its launcher activity (pkg/.Activity). Called in $(...): pass the exit on.
launcher_activity() {
  local act
  act="$("$ADB" -s "$_MEMO_SERIAL" shell cmd package resolve-activity --brief "$1" 2>/dev/null </dev/null \
         | tr -d '\r' | tail -1 || true)"
  case "$act" in
    "$1"/*) echo "$act" ;;
    *) echo "ERROR: $1 has no launcher activity on $_MEMO_SERIAL (resolve-activity said '$act')" >&2; exit 1 ;;
  esac
}

# `adb shell` joins its arguments with spaces and hands them to the DEVICE's shell, so
# every argument is single-quoted here: an unquoted URL with `&` was cut at it and its
# tail run as a second command. `am start` exits 0 on its own errors ("Error: Activity
# not started, unable to resolve Intent"), so its output decides as much as the exit
# code. A "Warning: Activity not started, intent has been delivered to currently running
# top-most instance" is a success (the app was in front).
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
am_start() {
  local o c="am start -W" rc=0 x
  for x in "$@"; do c="$c $(shq "$x")"; done
  o="$("$ADB" -s "$_MEMO_SERIAL" shell "$c" 2>&1 </dev/null)" || rc=$?
  o="$(printf '%s\n' "$o" | tr -d '\r')"
  if [ "$rc" != 0 ] || grep -qE '^(Error|Exception|java\.)|not found' <<< "$o"; then
    echo "ERROR: am start failed (exit $rc):" >&2
    printf '%s\n' "$o" | grep -vE '^\s*$' | sed 's/^/  /' >&2
    return 1
  fi
  return 0
}

app_pid() { "$ADB" -s "$_MEMO_SERIAL" shell pidof "$1" 2>/dev/null </dev/null | tr -d '\r' || true; }

# An Expo dev-client declares an exp+<slug> scheme (the slug keeps `.`, `+` and `-`);
# prints it, or nothing for any other app. A release build of an app with expo-dev-client
# carries the scheme too, but its launcher is compiled out: only a DEBUGGABLE package is
# started through the link.
expo_scheme() {
  local d
  d="$("$ADB" -s "$_MEMO_SERIAL" shell dumpsys package "$1" 2>/dev/null </dev/null | tr -d '\r' || true)"
  grep -qE 'pkgFlags=\[[^]]*DEBUGGABLE' <<< "$d" || return 0
  printf '%s\n' "$d" | grep -oE 'exp\+[a-z0-9.+-]+' | head -1 || true
}

# The dev server a dev-client should load: its own debug_http_host pref (the launcher
# writes it on every start through its link), else 10.0.2.2:$METRO_PORT (the emulator's
# address of the host). Called in $(...): pass the exit on.
dev_server() {
  local h
  h="$("$ADB" -s "$_MEMO_SERIAL" shell "run-as $1 cat shared_prefs/$1_preferences.xml" 2>/dev/null </dev/null \
       | tr -d '\r' | sed -nE 's/.*<string name="debug_http_host">([^<]+)<.*/\1/p' | head -1 || true)"
  if [ -z "$h" ] && [ -n "${METRO_PORT:-}" ]; then h="10.0.2.2:$METRO_PORT"; fi
  if [ -z "$h" ]; then
    echo "ERROR: $1 is an Expo dev-client with no debug_http_host pref yet and \$METRO_PORT is unset -" >&2
    echo "  it would start on the launcher's server list, not in the app. Set METRO_PORT to its dev server's port." >&2
    exit 1
  fi
  echo "$h"
}

# Starts PACKAGE in front: a dev-client through its link (into the app), any other app
# by its launcher activity. -W waits until the first frame is drawn.
start_app() {
  local scheme host url
  scheme="$(expo_scheme "$1")"
  if [ -n "$scheme" ]; then
    host="$(dev_server "$1")" || exit $?
    url="$scheme://expo-development-client/?url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "http://$host")"
    am_start -a android.intent.action.VIEW -d "$url" "$1" || exit 1
  else
    am_start -n "$(launcher_activity "$1")" || exit 1
  fi
}

no_launch_args() {   # CMD PACKAGE [ARG...]
  if [ "$#" -gt 2 ]; then
    echo "ERROR: $1 takes no launch arguments on Android (got: ${*:3}) - there are none to pass. The Metro an app" >&2
    echo "  loads from is its debug_http_host pref; point it there with the rig check, then $1 $2." >&2
    exit 2
  fi
}

# Validates a number of seconds given on the command line (as sim-ui.sh does).
need_num() {
  local re='^[0-9]+([.][0-9]+)?$'
  [ "${3:-}" = int ] && re='^[0-9]+$'
  if [[ ! "${2:-}" =~ $re ]]; then
    echo "ERROR: $1 must be a non-negative ${3:+whole }number, got '${2:-}'" >&2
    exit 2
  fi
}

# A polling helper runs as a CHILD this shell waits for, so a TERM or INT sent to the
# script (`timeout`, a killed batch) takes the child down too instead of leaving it polling.
_CHILD=""
run_child() {
  local rc=0
  trap '[ -n "$_CHILD" ] && kill "$_CHILD" 2>/dev/null; exit 143' TERM
  trap '[ -n "$_CHILD" ] && kill "$_CHILD" 2>/dev/null; exit 130' INT
  "$@" & _CHILD=$!
  wait "$_CHILD" || rc=$?
  _CHILD=""
  return "$rc"
}

# macOS's /bin/bash (3.2) hands an EXIT trap $?=0 after a shell error such as an unbound
# variable under `set -u`, so a run that died that way would report success. _DONE is
# set only where the script finishes on purpose; a 0 without it becomes 1.
_DONE=""
# A `do` batch that stops on a failed step prints the screen as it was at the failure
# (front app, then the visible labelled elements), because the next call would almost
# always ask for exactly that (as sim-ui.sh). Not for usage errors (2), signals (130,
# 143), a tolerated step (its subshell does not inherit this trap) or a device that was
# never chosen. SIMUI_FAIL_SUMMARY=0 turns it off.
_IN_DO=""; _DO_STEP=""
fail_summary() {
  local port
  [ -n "$_IN_DO" ] && [ -n "$_MEMO_SERIAL" ] && [ "${SIMUI_FAIL_SUMMARY:-1}" != 0 ] || return 0
  case "$1" in 0|2|130|143) return 0 ;; esac
  {
    echo "--- the batch stopped at: $_DO_STEP - the screen now (front app, then visible labelled elements):"
    python3 "$HERE/u2_el.py" --adb "$ADB" --serial "$_MEMO_SERIAL" foreground 2>&1 | sed 's/^/front app: /' || true
    port="$_MEMO_PORT"
    [ -n "$port" ] || port="$(android_u2_port "$_MEMO_SERIAL" 2>/dev/null || true)"
    if [ -n "$port" ]; then
      [ -n "$_MEMO_SCALE" ] || scale 2>/dev/null || true
      python3 "$HERE/u2_tree.py" --port "$port" --scale "${_MEMO_SCALE:-1}" --names 2>/dev/null \
        | awk 'NR <= 40 { print } END { if (NR > 40) print "... and " NR - 40 " more line(s), the bottom of the screen - `elements --names` lists them all" }' || true
    else
      echo "(no UiAutomator2 server for $_MEMO_SERIAL - elements not read)"
    fi
    echo "---"
  } >&2
}
trap '_rc=$?; [ "$_rc" = 0 ] && [ -z "$_DONE" ] && _rc=1; fail_summary "$_rc"; exit $_rc' EXIT

dispatch() {
cmd="${1:-}"; shift || true
case "$cmd" in
  devices)
    _all="$(android_attached)"
    if [ -z "$_all" ]; then echo "no Android device attached (adb devices is empty)" >&2; return 0; fi
    while read -r _line; do
      printf '%s  %s  %s\n' "${_line%% *}" "$(android_name "${_line%% *}")" "${_line#* }"
    done <<<"$_all"
    ;;

  session)
    session
    echo "$_MEMO_SERIAL :$_MEMO_PORT session $_SESSION_INFO"
    ;;

  elements)
    _args=()
    _settled=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --all) _args+=(--all) ;;
        --settled) _settled=1 ;;
        --names) _args+=(--names) ;;
        --grep)
          if [ -z "${2:-}" ]; then echo "usage: elements [--all] [--settled] [--grep REGEX] [--names]" >&2; exit 2; fi
          _args+=(--grep "$2"); shift ;;
        *) echo "unknown flag for elements: $1" >&2; exit 2 ;;
      esac
      shift
    done
    ensure_u2; scale
    if [ -n "$_settled" ]; then
      need_num "SIMUI_SETTLE_SECONDS" "${SIMUI_SETTLE_SECONDS:-2}"
      _args+=(--settled "${SIMUI_SETTLE_SECONDS:-2}")
    fi
    # The comparison of --settled runs on the whole tree (all or filtered); --grep and
    # --names only change what is printed, so a filter can never hide the motion.
    run_child python3 "$HERE/u2_tree.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" "${_args[@]+"${_args[@]}"}"
    ;;

  # --- one element by testID --------------------------------------------------
  waitid|el)
    if [ -z "${1:-}" ]; then echo "usage: $cmd ID$([ "$cmd" = waitid ] && echo ' [--timeout S] [--exists]')" >&2; exit 2; fi
    _id="$1"; shift
    _el_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout) [ "$cmd" = waitid ] || { echo "unknown flag for $cmd: $1" >&2; exit 2; }
                   need_num "--timeout" "${2:-}"
                   _el_args+=(--timeout "$2"); shift 2 ;;
        --exists)  [ "$cmd" = waitid ] || { echo "unknown flag for $cmd: $1" >&2; exit 2; }
                   _el_args+=(--exists); shift ;;
        *) echo "unknown flag for $cmd: $1" >&2; exit 2 ;;
      esac
    done
    ensure_u2; scale
    case "$cmd" in waitid) _sub=wait ;; *) _sub=info ;; esac
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" \
      --serial "$_MEMO_SERIAL" "$_sub" "$_id" "${_el_args[@]+"${_el_args[@]}"}"
    ;;

  tapid)
    if [ -z "${1:-}" ]; then echo "usage: tapid ID" >&2; exit 2; fi
    [ "$#" -eq 1 ] || { echo "unknown flag for tapid: $2" >&2; exit 2; }
    ensure_u2; scale
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" \
      --serial "$_MEMO_SERIAL" tap "$1"
    ;;

  typeid)
    if [ "$#" -lt 2 ]; then echo "usage: typeid ID TEXT [--append] [--expect VALUE]" >&2; exit 2; fi
    _id="$1"; _text="$2"; shift 2
    _ty_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --append) _ty_args+=(--append); shift ;;
        --expect) [ "$#" -ge 2 ] || { echo "usage: typeid ID TEXT [--append] [--expect VALUE]" >&2; exit 2; }
                  _ty_args+=("--expect=$2"); shift 2 ;;
        *) echo "unknown flag for typeid: $1" >&2; exit 2 ;;
      esac
    done
    ensure_u2; scale
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" \
      --serial "$_MEMO_SERIAL" type "$_id" "--text=$_text" "${_ty_args[@]+"${_ty_args[@]}"}"
    ;;

  # --- coordinates (dp) --------------------------------------------------------
  tap)
    _MEMO_SERIAL="$(serial)" || exit $?; scale
    assert_in_bounds "${1:-}" "${2:-}"
    adb_input tap "$(px "$1")" "$(px "$2")"
    echo "tapped $1,$2"
    ;;

  longpress)
    _MEMO_SERIAL="$(serial)" || exit $?; scale
    assert_in_bounds "${1:-}" "${2:-}"
    dur="${3:-800}"; need_num "DURATION_MS" "$dur" int
    adb_input swipe "$(px "$1")" "$(px "$2")" "$(px "$1")" "$(px "$2")" "$dur"
    echo "long-pressed $1,$2 (${dur}ms)"
    ;;

  swipe)
    _MEMO_SERIAL="$(serial)" || exit $?; scale
    assert_in_bounds "${1:-}" "${2:-}" "${3:-}" "${4:-}"
    dur="${5:-300}"; need_num "DURATION_MS" "$dur" int
    adb_input swipe "$(px "$1")" "$(px "$2")" "$(px "$3")" "$(px "$4")" "$dur"
    echo "swiped $1,$2 -> $3,$4"
    ;;

  # Two taps 100 ms apart and a press held before moving: the timing has to be the
  # device's own (W3C pointer actions through the server) - two `input` calls are only
  # as close together as the shell manages to start them.
  doubletap)
    ensure_u2; scale
    assert_in_bounds "${1:-}" "${2:-}"
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" \
      --serial "$_MEMO_SERIAL" gesture doubletap "$(px "$1")" "$(px "$2")"
    echo "double-tapped $1,$2"
    ;;

  drag)
    ensure_u2; scale
    assert_in_bounds "${1:-}" "${2:-}" "${3:-}" "${4:-}"
    _hold="${5:-0.5}"; need_num "SECONDS" "$_hold"
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" \
      --serial "$_MEMO_SERIAL" gesture drag "$(px "$1")" "$(px "$2")" "$(px "$3")" "$(px "$4")" --hold "$_hold"
    echo "dragged $1,$2 -> $3,$4 (${_hold}s hold)"
    ;;

  type)
    if [ "$#" -eq 0 ]; then echo 'usage: type "text"' >&2; exit 2; fi
    ensure_u2; scale
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" \
      --serial "$_MEMO_SERIAL" typefocused "--text=$1"
    ;;

  button)
    if [ -z "${1:-}" ]; then echo "usage: button HOME|ENTER|VOLUME_UP|VOLUME_DOWN|BACK" >&2; exit 2; fi
    case "$1" in
      HOME) _code=3 ;;
      ENTER) _code=66 ;;
      VOLUME_UP) _code=24 ;;
      VOLUME_DOWN) _code=25 ;;
      BACK) _code=4 ;;
      *) echo "unsupported button: $1" >&2; exit 1 ;;
    esac
    _MEMO_SERIAL="$(serial)" || exit $?
    adb_input keyevent "$_code"
    echo "pressed $1"
    ;;

  # KEYCODE_SLEEP / KEYCODE_WAKEUP, never KEYCODE_POWER: that one is a toggle, so a
  # `lock` on a screen that is already off would turn it ON.
  lock)
    _MEMO_SERIAL="$(serial)" || exit $?
    adb_input keyevent KEYCODE_SLEEP
    echo "locked"
    ;;

  unlock)
    _MEMO_SERIAL="$(serial)" || exit $?
    adb_input keyevent KEYCODE_WAKEUP
    "$ADB" -s "$_MEMO_SERIAL" shell wm dismiss-keyguard </dev/null >/dev/null 2>&1 || true
    # The keyguard goes away asynchronously; a PIN, pattern or password keeps it up.
    _st=true
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      _st="$(lock_state)" || exit $?
      [ "$_st" = false ] && break
      sleep 0.3
    done
    if [ "$_st" != false ]; then
      echo "ERROR: the screen is on but the keyguard is still showing - a PIN, pattern or password" \
           "lock needs a person at the device." >&2
      exit 1
    fi
    echo "unlocked"
    ;;

  locked)
    _MEMO_SERIAL="$(serial)" || exit $?
    _st="$(lock_state)" || exit $?
    echo "$_st"
    ;;

  waitfor)
    _pat="${1:-}"
    if [ -z "$_pat" ]; then echo "usage: waitfor REGEX [--timeout S] [--all]" >&2; exit 2; fi
    shift
    _wf_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout) need_num "--timeout" "${2:-}"; _wf_args+=(--timeout "$2"); shift 2 ;;
        --all)     _wf_args+=(--all); shift ;;
        *) echo "unknown flag for waitfor: $1" >&2; exit 2 ;;
      esac
    done
    ensure_u2; scale
    run_child python3 "$HERE/u2_tree.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --match "$_pat" "${_wf_args[@]+"${_wf_args[@]}"}"
    ;;

  # The app in front is the top resumed activity - or, when that is a system activity
  # pushed onto the app's task (a permission dialog), the task's root. The focused WINDOW
  # can still be another one (the dialog, a chooser, a browser the app opened), and that
  # is what every element read sees, so it is named whenever it is not the app's.
  foreground)
    _ser="$(serial)" || exit $?
    run_child python3 "$HERE/u2_el.py" --adb "$ADB" --serial "$_ser" foreground
    ;;

  # A plain start of an Expo dev-client that is not running shows its launcher (the list
  # of dev servers), so launch starts a dev-client through its link unless it is running.
  launch)
    if [ -z "${1:-}" ]; then echo "usage: launch PACKAGE" >&2; exit 2; fi
    no_launch_args launch "$@"
    _MEMO_SERIAL="$(serial)" || exit $?
    need_pkg "$1"
    if [ -n "$(app_pid "$1")" ]; then am_start -n "$(launcher_activity "$1")" || exit 1
    else start_app "$1"; fi
    echo "launched $1 pid $(app_pid "$1")"
    ;;
  relaunch)
    if [ -z "${1:-}" ]; then echo "usage: relaunch PACKAGE" >&2; exit 2; fi
    no_launch_args relaunch "$@"
    _MEMO_SERIAL="$(serial)" || exit $?
    need_pkg "$1"
    "$ADB" -s "$_MEMO_SERIAL" shell am force-stop "$1" </dev/null
    start_app "$1"
    echo "relaunched $1 pid $(app_pid "$1")"
    ;;
  terminate)
    if [ -z "${1:-}" ]; then echo "usage: terminate PACKAGE" >&2; exit 2; fi
    _MEMO_SERIAL="$(serial)" || exit $?
    need_pkg "$1"
    if [ -z "$(app_pid "$1")" ]; then echo "$1 is not running on $_MEMO_SERIAL" >&2; exit 1; fi
    "$ADB" -s "$_MEMO_SERIAL" shell am force-stop "$1" </dev/null
    echo "terminated $1"
    ;;
  activate)
    if [ -z "${1:-}" ]; then echo "usage: activate PACKAGE" >&2; exit 2; fi
    _MEMO_SERIAL="$(serial)" || exit $?
    need_pkg "$1"
    _act="$(launcher_activity "$1")" || exit $?
    am_start -n "$_act" || exit 1
    echo "activated $1"
    ;;

  openurl)
    if [ -z "${1:-}" ]; then echo "usage: openurl URL [--package PACKAGE]" >&2; exit 2; fi
    _url="$1"; shift
    _pkg="${ANDROID_PACKAGE:-}"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --package) [ -n "${2:-}" ] || { echo "usage: openurl URL [--package PACKAGE]" >&2; exit 2; }; _pkg="$2"; shift 2 ;;
        *) echo "unknown flag for openurl: $1" >&2; exit 2 ;;
      esac
    done
    if [ -z "$_pkg" ]; then
      echo "ERROR: openurl needs the target package (--package PACKAGE or \$ANDROID_PACKAGE): without it two apps" >&2
      echo "  with this scheme bring up the system chooser and \`am start\` still says ok." >&2
      exit 2
    fi
    _MEMO_SERIAL="$(serial)" || exit $?
    need_pkg "$_pkg"
    am_start -a android.intent.action.VIEW -d "$_url" "$_pkg" || exit 1
    echo "opened $_url in $_pkg"
    ;;

  # The size the screen has NOW: `cur=` in `dumpsys window displays` follows the rotation
  # (2424x1080 measured in landscape on a 1080x2424 emulator).
  orientation)
    _MEMO_SERIAL="$(serial)" || exit $?
    _cur="$("$ADB" -s "$_MEMO_SERIAL" shell dumpsys window displays 2>/dev/null </dev/null | tr -d '\r' \
            | grep -m1 -oE 'cur=[0-9]+x[0-9]+' || true)"
    if [ -z "$_cur" ]; then echo "ERROR: could not read the screen size of $_MEMO_SERIAL (dumpsys window displays)" >&2; exit 1; fi
    _cur="${_cur#cur=}"
    if [ "${_cur%x*}" -gt "${_cur#*x}" ]; then echo LANDSCAPE; else echo PORTRAIT; fi
    ;;

  screenshot)
    _out="/tmp/android-ui-shot.png"
    case "${1:-}" in ""|--width) ;; *) _out="$1"; shift ;; esac
    _width=""
    if [ "${1:-}" = "--width" ]; then need_num "--width" "${2:-}" int; _width="$2"; fi
    _MEMO_SERIAL="$(serial)" || exit $?
    "$ADB" -s "$_MEMO_SERIAL" exec-out screencap -p > "$_out" </dev/null || { echo "ERROR: screencap failed on $_MEMO_SERIAL" >&2; exit 1; }
    _pxw="$(sips -g pixelWidth "$_out" 2>/dev/null | awk '/pixelWidth/ { print $2 }' || true)"
    if [ -z "$_pxw" ]; then echo "ERROR: $_out is not an image (screencap wrote $(wc -c < "$_out" | tr -d ' ') bytes)" >&2; exit 1; fi
    if [ -z "$_width" ]; then
      # 1 px == 1 dp, as 1 px == 1 pt on iOS: the rects `elements` prints map onto the image.
      scale; _width="$(awk -v v="$_pxw" -v s="$_MEMO_SCALE" 'BEGIN { printf "%d", v / s + 0.5 }')"
    fi
    if [ "$_width" != 0 ] && [ "$_width" != "$_pxw" ]; then
      sips --resampleWidth "$_width" "$_out" >/dev/null 2>&1 || { echo "ERROR: sips could not resample $_out" >&2; exit 1; }
    fi
    echo "$_out"
    ;;

  # System dialogs arrive on their own schedule and QUEUE UP (several permissions asked at
  # once), so wait for one rather than reading once, and drain them with --all.
  alert)
    _sub="${1:-text}"; shift || true
    case "$_sub" in
      text|buttons) _al=() ;;
      wait) need_num "SECONDS" "${1:-15}" int; _al=(--seconds "${1:-15}") ;;
      accept|dismiss)
        _al=()
        case "${1:-}" in "") ;; --all) _al=(--all) ;; *) echo "unknown flag for alert $_sub: $1" >&2; exit 2 ;; esac ;;
      *) echo "unknown: alert $_sub (text|wait|buttons|accept|dismiss)" >&2; exit 2 ;;
    esac
    ensure_u2; scale; session
    run_child python3 "$HERE/u2_el.py" --port "$_MEMO_PORT" --scale "$_MEMO_SCALE" --adb "$ADB" --serial "$_MEMO_SERIAL" \
      alert "$_sub" "${_al[@]+"${_al[@]}"}"
    ;;

  # A named pause, so a route reads as a route. Prefer `waitid` / `waitfor` (as sim-ui.sh).
  wait)
    need_num "SECONDS" "${1:-1}"
    if awk -v s="${1:-1}" 'BEGIN { exit !(s > 2) }'; then
      echo "NOTE: fixed pause ${1}s - if you are waiting for the app, \`waitid ID\` returns the moment it is there and fails loudly when it is not." >&2
    fi
    sleep "${1:-1}"
    ;;

  # A known route belongs in ONE call (as sim-ui.sh): steps are this script's own
  # subcommands, '?step' may fail, '#step' is a comment, stdin when no arguments.
  do)
    if [ "$#" -eq 0 ]; then
      _steps=()
      while IFS= read -r _line; do _steps+=("$_line"); done
    else
      _steps=("$@")
    fi
    _IN_DO=1
    for _step in "${_steps[@]+"${_steps[@]}"}"; do
      _tol=""
      case "$_step" in
        ""|\#*) continue ;;
        \?*) _tol=1; _step="${_step#\?}" ;;
      esac
      _DO_STEP="$_step"
      printf '\xc2\xbb %s\n' "$_step"
      if [ -n "$_tol" ]; then
        # A subshell: several branches end with `exit`, which would end the whole batch.
        ( eval "dispatch $_step" ) || echo "  (step failed - tolerated)"
      else
        eval "dispatch $_step"
      fi
    done
    ;;

  *)
    grep '^#   android-ui.sh' "$0" | sed 's/^# *//'
    exit 1
    ;;
esac
}

dispatch "$@"
_DONE=1
