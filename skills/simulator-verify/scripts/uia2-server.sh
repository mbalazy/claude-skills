#!/bin/bash
# uia2-server.sh - the UiAutomator2 server the Android driver (android-ui.sh) talks to:
# install the pinned build, start it, prove it answers, stop it. The Android counterpart
# of wda-sim.sh. android-ui.sh never starts the server itself; its errors name `ensure`.
#
#   uia2-server.sh ensure [SERIAL]   # install if needed, start, forward a port, prove it: READY or NOT READY
#   uia2-server.sh check  [SERIAL]   # the same proof without installing or starting anything
#   uia2-server.sh stop   [SERIAL]   # stop this driver's server on SERIAL and remove its forward
#   uia2-server.sh fetch             # put the pinned APKs into the cache (npm pack) and verify them
#
# SERIAL: the argument, else $ANDROID_SERIAL, else the only attached device (several and
# none named = exit 2). Port: $U2_PORT, else the device's existing forward to tcp:6790,
# else the first free port in 8210-8229 (android-lib.sh). Exit: 0 READY / stopped,
# 1 NOT READY (the cause on the same line), 2 bad usage, ambiguous device or a refused port.
#
# What READY proves: the forward on the printed port belongs to SERIAL, the server opened
# (or reused) its session with waitForIdleTimeout=0 and disableIdLocatorAutocompletion=true,
# and a real /source came back within 3 s. /status alone proves nothing: after an adbd
# restart it says ready while /source waits 10 s and fails.
#
# The server is the open-source appium-uiautomator2-server, run WITHOUT Appium (am
# instrument + adb forward + HTTP). Version and sha256 are pinned below; the APKs live in
# a host cache ($UIA2_SERVER_HOME, default ~/.cache/uia2-server/<version>), never in this
# repository. `--no-window-animation` is never passed: it sets all three animation scales
# to 0 while the server runs (the app then sees reduce motion) and writes 1.0 back after.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/android-lib.sh"

UIA2_VERSION="11.2.4"
SERVER_APK="appium-uiautomator2-server-v$UIA2_VERSION.apk"
TEST_APK="appium-uiautomator2-server-debug-androidTest.apk"
SERVER_SHA="f67810787737130898f04de6767940fa0daaa2f4b3d5e4c4c3ce008daf102e7c"
TEST_SHA="f8c352d52da664bb97b09c4a80a0b58c36e058d061aa862307dc654e02ce6ade"
CACHE="${UIA2_SERVER_HOME:-$HOME/.cache/uia2-server}/$UIA2_VERSION"
START_TIMEOUT="${UIA2_START_TIMEOUT:-20}"

die_usage() { grep '^#   uia2-server.sh' "$0" | sed 's/^# *//' >&2; exit 2; }
not_ready() { echo "NOT READY: $*"; exit 1; }
sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# Both cached APKs present with the pinned sha256, or NOT READY naming the file.
verify_cache() {
  local f want got
  for f in "$SERVER_APK:$SERVER_SHA" "$TEST_APK:$TEST_SHA"; do
    want="${f#*:}"; f="${f%%:*}"
    [ -f "$CACHE/$f" ] || return 3
    got="$(sha_of "$CACHE/$f")"
    if [ "$got" != "$want" ]; then
      not_ready "sha256 mismatch for $CACHE/$f: $got, pinned $want - delete $CACHE and run '$(basename "$0") fetch'"
    fi
  done
  return 0
}

fetch() {
  local tmp f
  command -v npm >/dev/null 2>&1 || not_ready "npm not found - it fetches appium-uiautomator2-server@$UIA2_VERSION"
  tmp="$(mktemp -d -t uia2-fetch)"
  echo "fetching appium-uiautomator2-server@$UIA2_VERSION (npm pack) ..."
  if ! ( cd "$tmp" && npm pack "appium-uiautomator2-server@$UIA2_VERSION" >/dev/null 2>&1 \
         && tar xzf appium-uiautomator2-server-*.tgz package/apks ); then
    rm -rf "$tmp"; not_ready "npm pack appium-uiautomator2-server@$UIA2_VERSION failed"
  fi
  mkdir -p "$CACHE"
  for f in "$SERVER_APK:$SERVER_SHA" "$TEST_APK:$TEST_SHA"; do
    if [ "$(sha_of "$tmp/package/apks/${f%%:*}")" != "${f#*:}" ]; then
      rm -rf "$tmp"; not_ready "the downloaded ${f%%:*} does not match the pinned sha256 ${f#*:} - not installing it"
    fi
  done
  # The .idsig files make `adb install` incremental (~0.1 s); they are signed data the
  # device verifies against the APK, so they need no pin of their own.
  cp "$tmp/package/apks/"*.apk "$tmp/package/apks/"*.idsig "$CACHE/" 2>/dev/null || cp "$tmp/package/apks/"*.apk "$CACHE/"
  rm -rf "$tmp"
  echo "cached in $CACHE"
}

# sha256 of the APK a package is installed from, empty when not installed.
installed_sha() {
  local p
  p="$("$ADB" -s "$SERIAL" shell pm path "$1" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -1 || true)"
  [ -n "$p" ] || return 0
  "$ADB" -s "$SERIAL" shell sha256sum "$p" 2>/dev/null | tr -d '\r' | cut -d' ' -f1 || true
}

install_pinned() {
  local f pkg want out
  for f in "$SERVER_PKG_SPEC" "$TEST_PKG_SPEC"; do
    pkg="${f%%:*}"; f="${f#*:}"; want="${f#*:}"; f="${f%%:*}"
    if [ "$(installed_sha "$pkg")" = "$want" ]; then
      echo "$pkg: pinned $UIA2_VERSION installed"
      continue
    fi
    [ "$MODE" = ensure ] || not_ready "$pkg is not the pinned $UIA2_VERSION build (run: $(basename "$0") ensure $SERIAL)"
    echo "$pkg: installing the pinned $UIA2_VERSION build"
    out="$("$ADB" -s "$SERIAL" install -r -g "$CACHE/$f" 2>&1)" || true
    case "$out" in
      *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
        not_ready "another build of $pkg (different signing key) is installed - it belongs to another tool; remove it only if it is yours: $ADB -s $SERIAL uninstall $pkg" ;;
    esac
    [ "$(installed_sha "$pkg")" = "$want" ] || not_ready "adb install of $f did not leave the pinned build installed: $(printf '%s' "$out" | tail -1)"
  done
}
SERVER_PKG_SPEC="$U2_SERVER_PKG:$SERVER_APK:$SERVER_SHA"
TEST_PKG_SPEC="$U2_TEST_PKG:$TEST_APK:$TEST_SHA"

# Other UiAutomation clients on the device, sampled twice: a `uiautomator dump` loop has
# gaps between its processes. Prints them, returns 1 when there is one.
foreign_now() {
  local ps1 ps2
  ps1="$("$ADB" -s "$SERIAL" shell ps -A -o PID,NAME,ARGS 2>/dev/null | tr -d '\r')"
  sleep 0.3
  ps2="$("$ADB" -s "$SERIAL" shell ps -A -o PID,NAME,ARGS 2>/dev/null | tr -d '\r')"
  printf '%s\n%s\n' "$ps1" "$ps2" | sort -u -n | python3 "$HERE/u2_client.py" foreign
}

server_pid() { "$ADB" -s "$SERIAL" shell pidof "$U2_SERVER_PKG" 2>/dev/null | tr -d '\r' || true; }

server_stop_device() {
  "$ADB" -s "$SERIAL" shell am force-stop "$U2_TEST_PKG" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell am force-stop "$U2_SERVER_PKG" >/dev/null 2>&1 || true
}

status_ready() { curl -s -m 2 "http://127.0.0.1:$1/status" 2>/dev/null | grep -q '"ready" *: *true'; }

# The proof: session reused or opened, settings applied and read back, a real /source.
prove() {
  local s h
  s="$(python3 "$HERE/u2_client.py" session --port "$PORT" 2>&1)" || {
    case "$s" in
      *"UiAutomation not connected"*)
        not_ready "the server runs but UiAutomation is held by another client ($s)" ;;
    esac
    not_ready "$s"; }
  echo "session ${s}"
  h="$(python3 "$HERE/u2_client.py" health --port "$PORT" --timeout 3 2>&1)" \
    || not_ready "/status may say ready, but a real /source did not come back in 3 s: $h"
  echo "READY $SERIAL ($(android_name "$SERIAL")) :$PORT - /source $h bytes"
  echo "  drive it with: ANDROID_SERIAL=$SERIAL U2_PORT=$PORT $HERE/android-ui.sh ..."
}

start_server() {
  local log t0 f
  log="${CACHE%/*}/instrument-$SERIAL.log"
  "$ADB" -s "$SERIAL" forward "tcp:$PORT" "tcp:$U2_DEVICE_PORT" >/dev/null \
    || not_ready "adb forward tcp:$PORT tcp:$U2_DEVICE_PORT failed"
  # adb joins its arguments into one device command line, so the format is quoted there.
  t0="$("$ADB" -s "$SERIAL" shell "date '+%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r')"
  mkdir -p "${CACHE%/*}"
  echo "starting the server on $SERIAL (host :$PORT -> device :$U2_DEVICE_PORT, log $log)"
  # The host-side `am instrument -w` only waits; the server keeps running on the device
  # when this adb process goes away.
  nohup "$ADB" -s "$SERIAL" shell am instrument -w -e disableAnalytics true "$U2_RUNNER" \
    > "$log" 2>&1 < /dev/null &
  for _ in $(seq 1 $((START_TIMEOUT * 4))); do
    status_ready "$PORT" && return 0
    if grep -qE 'INSTRUMENTATION_FAILED|Process crashed|INSTRUMENTATION_RESULT' "$log" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done
  # Losing to another UiAutomation client leaves its mark only in logcat.
  if "$ADB" -s "$SERIAL" logcat -d -T "$t0" 2>/dev/null | grep -q 'UiAutomationService.*already registered'; then
    f="$(foreign_now || true)"
    not_ready "UiAutomation is held by another client${f:+: $f} (logcat: UiAutomationService already registered)"
  fi
  not_ready "the server did not report ready on :$PORT within ${START_TIMEOUT}s - last lines of $log: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
}

gate() {
  local f rc pid
  SERIAL="${1:-}"
  [ -n "$SERIAL" ] || SERIAL="$(android_serial)"
  [ -n "${1:-}" ] && ANDROID_SERIAL="$SERIAL" android_serial >/dev/null
  android_assert_ready "$SERIAL"
  echo "target $SERIAL ($(android_name "$SERIAL")), UiAutomator2 server $UIA2_VERSION"

  # Port first: a refused port is a usage error (2) and must not install anything.
  if PORT="$(android_u2_port "$SERIAL" "$([ "$MODE" = ensure ] && echo --allocate)")"; then :; else
    rc=$?
    [ "$rc" = 3 ] && not_ready "no forward to the server on $SERIAL (run: $(basename "$0") ensure $SERIAL)"
    exit "$rc"
  fi

  pid="$(server_pid)"
  if [ -z "$pid" ]; then
    f="$(foreign_now)" && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || not_ready "UiAutomation is held by another client - stop it first, this driver will not fight over it: $(printf '%s' "$f" | tr '\n' ';')"
  fi

  if [ "$MODE" = ensure ]; then
    verify_cache || { [ $? -eq 3 ] && fetch && verify_cache; }
  fi
  install_pinned

  if [ -n "$pid" ]; then
    echo "server already running on $SERIAL (pid $pid)"
    "$ADB" forward --list 2>/dev/null | grep -q "^$SERIAL tcp:$PORT tcp:$U2_DEVICE_PORT\$" \
      || { [ "$MODE" = ensure ] && "$ADB" -s "$SERIAL" forward "tcp:$PORT" "tcp:$U2_DEVICE_PORT" >/dev/null; } \
      || not_ready "the server runs but no forward leads to it (run: $(basename "$0") ensure $SERIAL)"
    if python3 "$HERE/u2_client.py" health --port "$PORT" --timeout 3 >/dev/null 2>&1; then
      prove; return
    fi
    [ "$MODE" = ensure ] || not_ready "the server process lives but does not answer a real /source on :$PORT (an adbd restart does this; run: $(basename "$0") ensure $SERIAL)"
    echo "the server process lives but /source does not answer - restarting it"
    server_stop_device
    sleep 0.5
  else
    [ "$MODE" = ensure ] || not_ready "the server is not running on $SERIAL (run: $(basename "$0") ensure $SERIAL)"
  fi
  start_server
  prove
}

stop() {
  local p removed=0
  SERIAL="${1:-}"
  [ -n "$SERIAL" ] || SERIAL="$(android_serial)"
  for p in $("$ADB" forward --list 2>/dev/null | awk -v s="$SERIAL" -v r="tcp:$U2_DEVICE_PORT" \
              '$1 == s && $3 == r && $2 ~ /^tcp:/ { sub(/^tcp:/, "", $2); print $2 }'); do
    "$ADB" -s "$SERIAL" forward --remove "tcp:$p" && { echo "removed forward :$p -> $SERIAL"; removed=1; }
  done
  if [ -n "$(server_pid)" ]; then
    server_stop_device
    echo "stopped the UiAutomator2 server on $SERIAL"
  elif [ "$removed" = 0 ]; then
    echo "nothing to stop on $SERIAL"
  fi
}

MODE="${1:-}"; shift || true
case "$MODE" in
  ensure|check) [ "$#" -le 1 ] || die_usage; gate "${1:-}" ;;
  stop)         [ "$#" -le 1 ] || die_usage; stop "${1:-}" ;;
  fetch)        [ "$#" -eq 0 ] || die_usage
                if verify_cache; then echo "cached in $CACHE (sha256 verified)"; else fetch; fi ;;
  *) die_usage ;;
esac
