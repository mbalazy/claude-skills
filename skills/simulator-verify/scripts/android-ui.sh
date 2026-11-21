#!/bin/bash
# android-ui.sh - drive an Android emulator (or a device over adb) with the same command
# vocabulary, flags and exit codes as sim-ui.sh drives the iOS simulator.
# Lifecycle via adb, UI observation/interaction via the UiAutomator2 server's HTTP API
# (the open-source appium-uiautomator2-server, run without Appium - see uia2-server.sh).
#
# Usage:
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

  *)
    grep '^#   android-ui.sh' "$0" | sed 's/^# *//'
    exit 1
    ;;
esac
}

dispatch "$@"
_DONE=1
