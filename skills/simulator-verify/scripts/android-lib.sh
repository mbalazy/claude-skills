#!/bin/bash
# android-lib.sh - shared by android-ui.sh and uia2-server.sh (sourced, never run).
# Which adb, which device, which host port leads to that device's UiAutomator2 server.
#
# Device: $ANDROID_SERIAL if set, else the only attached device. Several attached and
# $ANDROID_SERIAL unset = exit 2 with the list: two emulators made from one system image
# answer every question identically, so a guess would look exactly like a decision.
# Port: $U2_PORT if set (refused when `adb forward --list` shows it forwarded for another
# device), else this device's existing forward to tcp:6790, else (uia2-server.sh ensure
# only) the first free port in 8210-8229 - outside the ranges Metro, WebDriverAgent and
# the network probe use.

ANDROID_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
U2_SERVER_PKG="io.appium.uiautomator2.server"
U2_TEST_PKG="io.appium.uiautomator2.server.test"
U2_RUNNER="$U2_TEST_PKG/androidx.test.runner.AndroidJUnitRunner"
U2_DEVICE_PORT=6790

# adb from $ANDROID_HOME, then PATH, then the default SDK location on macOS.
android_adb() {
  if [ -n "${ADB:-}" ]; then echo "$ADB"; return; fi
  local c
  for c in "${ANDROID_HOME:-}/platform-tools/adb" "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
           "$(command -v adb 2>/dev/null || true)" "$HOME/Library/Android/sdk/platform-tools/adb"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  echo "ERROR: adb not found (set ANDROID_HOME or put platform-tools on PATH)" >&2
  exit 1
}
ADB="$(android_adb)"

# "<serial> <state>" per attached device (state: device, offline, unauthorized ...).
android_attached() {
  "$ADB" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1, $2 }'
}

# Human name of a device: the AVD name for an emulator (the only reliable serial <-> AVD
# link), the model for anything else. stdin is closed for adb: called inside
# `while read` loops, `adb shell` would otherwise eat the remaining lines.
android_name() {
  local n=""
  case "$1" in
    emulator-*) n="$("$ADB" -s "$1" emu avd name 2>/dev/null </dev/null | head -1 | tr -d '\r' || true)" ;;
  esac
  [ -n "$n" ] || n="$("$ADB" -s "$1" shell getprop ro.product.model 2>/dev/null </dev/null | tr -d '\r' || true)"
  echo "${n:-?}"
}

# The target serial, or exit (2 = ambiguous or unknown, 1 = nothing attached).
android_serial() {
  local all count line
  all="$(android_attached)"
  if [ -n "${ANDROID_SERIAL:-}" ]; then
    if ! printf '%s\n' "$all" | awk -v s="$ANDROID_SERIAL" '$1 == s { f = 1 } END { exit !f }'; then
      echo "ERROR: ANDROID_SERIAL=$ANDROID_SERIAL is not attached (adb devices)." >&2
      [ -n "$all" ] && printf '%s\n' "$all" | sed 's/^/  /' >&2
      exit 2
    fi
    echo "$ANDROID_SERIAL"; return
  fi
  count="$(printf '%s\n' "$all" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "ERROR: no Android device attached (adb devices is empty) - boot an emulator first." >&2
    exit 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "ERROR: $count Android devices are attached and ANDROID_SERIAL is not set - refusing to guess." >&2
    while read -r line; do
      echo "  ${line%% *}  $(android_name "${line%% *}")  ${line#* }" >&2
    done <<<"$all"
    echo "  Pin one: ANDROID_SERIAL=<serial> $(basename "$0") ..." >&2
    exit 2
  fi
  echo "${all%% *}"
}

# Exit 0 for an emulator: its serial (emulator-NNNN) or the property every emulator image
# sets. Anything else is a physical device, which reaches the Mac only through `adb reverse`.
android_is_emulator() {
  case "$1" in emulator-*) return 0 ;; esac
  [ "$("$ADB" -s "$1" shell getprop ro.kernel.qemu 2>/dev/null </dev/null | tr -d '\r' || true)" = 1 ]
}

# The address of the Mac's port N as the device sees it: 10.0.2.2 from an emulator,
# localhost (through an `adb reverse tcp:N tcp:N` rule) from a physical device.
android_host_for() {   # SERIAL PORT
  if android_is_emulator "$1"; then echo "10.0.2.2:$2"; else echo "localhost:$2"; fi
}

# The device must be online and booted; prints nothing, exits 1 with the cause.
android_assert_ready() {
  local st boot
  st="$(android_attached | awk -v s="$1" '$1 == s { print $2 }')"
  if [ "$st" != device ]; then
    echo "ERROR: $1 is ${st:-not attached} (adb devices) - it cannot be driven." >&2
    exit 1
  fi
  boot="$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  if [ "$boot" != 1 ]; then
    echo "ERROR: $1 is still booting (sys.boot_completed='$boot')." >&2
    exit 1
  fi
}

# Host port of the serial's UiAutomator2 server by the rule above. Pass --allocate to get
# a fresh free port when none is forwarded yet. Returns 2 when the port is refused (it
# leads to another device), 3 when no forward exists yet; the reason is on stderr.
android_u2_port() {
  local serial="$1" want=() alloc=() out rc
  [ -n "${U2_PORT:-}" ] && {
    [[ "$U2_PORT" =~ ^[0-9]+$ ]] || { echo "ERROR: U2_PORT must be a port number, got '$U2_PORT'" >&2; exit 2; }
    want=(--want "$U2_PORT"); }
  [ "${2:-}" = --allocate ] && alloc=(--allocate)
  out="$("$ADB" forward --list 2>/dev/null | python3 "$ANDROID_LIB_HERE/u2_client.py" port --serial "$serial" \
         ${want[@]+"${want[@]}"} ${alloc[@]+"${alloc[@]}"} 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: $out" >&2
    return "$rc"
  fi
  echo "$out"
}
