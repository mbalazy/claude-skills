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
#   android-ui.sh waitfor REGEX [--timeout S] [--all]   # poll the tree until it matches (beats a fixed sleep)
#   android-ui.sh foreground                # package + pid + activity of the app in front; a system window holding focus is named
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
         | awk -F': *' '/Physical density/ { p = $2 } /Override density/ { o = $2 } END { print (o != "" ? o : p) }')"
    [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -gt 0 ] || { echo "ERROR: could not read the screen density of $_MEMO_SERIAL (wm density)" >&2; exit 1; }
    _MEMO_SCALE="$(awk -v d="$d" 'BEGIN { printf "%.4f", d / 160 }')"
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
trap '_rc=$?; [ "$_rc" = 0 ] && [ -z "$_DONE" ] && _rc=1; exit $_rc' EXIT

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

  *)
    grep '^#   android-ui.sh' "$0" | sed 's/^# *//'
    exit 1
    ;;
esac
}

dispatch "$@"
_DONE=1
