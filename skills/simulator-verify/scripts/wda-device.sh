#!/usr/bin/env bash
# wda-device.sh - bring WebDriverAgent up on a PHYSICAL iPhone and tunnel it to localhost,
# so sim-ui.sh can drive the phone exactly like a simulator.
#
# Why a script: WDA on a device is an XCTest run. The runner app that `xcodebuild test`
# leaves on the phone cannot be started with devicectl (FBSOpenApplicationServiceErrorDomain
# 1/3) - only a test run starts it - and the phone's :8100 is reachable from the Mac only
# through an `iproxy` USB tunnel. Two long-lived processes, two screens, a five-minute
# first build; forgetting any one of them looks like "WDA is broken on devices".
#
# Usage:
#   wda-device.sh [<udid>] [--port N] [--team TEAM_ID] [--bundle-id ID] [--timeout S]
#   wda-device.sh [<udid>] --status
#   wda-device.sh [<udid>] --stop
#
#   <udid>        the phone (0000XXXX-XXXXXXXXXXXXXXXX from `xcrun devicectl list devices`);
#                 optional when exactly one iPhone is plugged in
#   --port N      local port of the iproxy tunnel (default $WDA_DEVICE_PORT or 8200)
#   --team ID     Apple team whose Xcode-managed profile lists this phone
#                 (default $WDA_TEAM_ID - REQUIRED, there is no sensible guess)
#   --bundle-id   PRODUCT_BUNDLE_IDENTIFIER for the runner (default $WDA_BUNDLE_ID or
#                 com.$USER.WebDriverAgentRunner); the installed runner is <id>.xctrunner
#   --timeout S   how long to wait for /status (default 420: a cold build takes ~5 min)
#   --status      report whether the tunnel and WDA answer, exit 0/1, change nothing
#   --stop        end this phone's WDA and iproxy screens
#
# Where things live: the WDA sources are `npm pack appium-webdriveragent`, unpacked once
# into $WDA_DEVICE_HOME (default ~/.cache/wda-device); the build goes to a DerivedData
# next to it; the xcodebuild log is <home>/wda-<udid>.log (the run is ready when it
# prints ServerURLHere). Both processes run in `screen` sessions named wda-<udid8> and
# iproxy-<udid8>, where udid8 is the first 8 characters of the udid.
#
# Signing, learned the hard way: automatic signing with an existing Xcode-managed wildcard
# profile ("iOS Team Provisioning Profile: *") that already lists the phone needs no Apple
# account in Xcode; manual signing with that profile is refused ("profile is Xcode
# managed", "WebDriverAgentLib does not support provisioning profiles"). So this passes
# CODE_SIGN_STYLE=Automatic and the team, nothing else.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${WDA_DEVICE_HOME:-$HOME/.cache/wda-device}"
PORT="${WDA_DEVICE_PORT:-8200}"
TEAM="${WDA_TEAM_ID:-}"
BUNDLE="${WDA_BUNDLE_ID:-com.${USER}.WebDriverAgentRunner}"
TIMEOUT=420
MODE="up"
UDID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --team)      TEAM="$2"; shift 2 ;;
    --bundle-id) BUNDLE="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --status)    MODE="status"; shift ;;
    --stop)      MODE="stop"; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           UDID="$1"; shift ;;
  esac
done

connected_devices() {
  xcrun devicectl list devices 2>/dev/null \
    | awk '$0 ~ /physical/ && $0 ~ /connected/' \
    | grep -oE '0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}|\b[0-9a-f]{40}\b'
}

if [[ -z "$UDID" ]]; then
  PHONES="$(connected_devices)"
  N="$(printf '%s\n' "$PHONES" | grep -c . || true)"
  if [[ "$N" -ne 1 ]]; then
    echo "ERROR: $N iPhones plugged in - pass the udid (xcrun devicectl list devices)." >&2
    exit 2
  fi
  UDID="$PHONES"
elif ! connected_devices | grep -qx "$UDID"; then
  echo "ERROR: $UDID is not a plugged-in physical iPhone right now:" >&2
  xcrun devicectl list devices 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

U8="${UDID:0:8}"
SCREEN_WDA="wda-$U8"
SCREEN_PROXY="iproxy-$U8"
LOG="$HOME_DIR/wda-$UDID.log"
PKG="$HOME_DIR/package"
DD="$HOME_DIR/DerivedData"

# `screen -ls` exits non-zero when every session is detached, which under pipefail
# would hide a match - so its status is dropped and grep's is the answer.
screen_up() { { screen -ls 2>/dev/null || true; } | grep -qE "[0-9]+\.$1[[:space:]]"; }

# The tunnel that already leads to this phone, whatever port it was started on.
existing_tunnel_port() {
  local pid cmd
  for pid in $(pgrep -x iproxy 2>/dev/null); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    printf '%s\n' "$cmd" | grep -qE -- "-u +$UDID\b" || continue
    printf '%s\n' "$cmd" | awk '{for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}'
    return 0
  done
}

wda_answers() { curl -s -m 3 "http://localhost:$1/status" 2>/dev/null | grep -q '"ready" : true\|"ready":true'; }
wda_built() { curl -s -m 3 "http://localhost:$1/status" 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["value"]["build"]["time"])
except Exception: print("?")'; }

report_status() {
  local t; t="$(existing_tunnel_port)"
  if [[ -n "$t" ]] && wda_answers "$t"; then
    echo "WDA UP for $UDID: http://localhost:$t (runner built $(wda_built "$t"); screens: $(screen_up "$SCREEN_WDA" && echo "$SCREEN_WDA" || echo "no $SCREEN_WDA"), $(screen_up "$SCREEN_PROXY" && echo "$SCREEN_PROXY" || echo "no $SCREEN_PROXY"))"
    echo "  drive it: SIM_UDID=$UDID $HERE/sim-ui.sh elements   (WDA_PORT derives itself from the tunnel)"
    return 0
  fi
  if [[ -n "$t" ]]; then
    echo "WDA DOWN for $UDID: the iproxy tunnel is up on :$t but nothing answers through it."
    echo "  The test run has ended or not reached ServerURLHere yet - log: $LOG"
  else
    echo "WDA DOWN for $UDID: no iproxy tunnel to this phone."
  fi
  return 1
}

case "$MODE" in
  status) report_status; exit $? ;;
  stop)
    for s in "$SCREEN_WDA" "$SCREEN_PROXY"; do
      if screen_up "$s"; then screen -S "$s" -X quit && echo "stopped screen $s"; fi
    done
    # A tunnel started by hand (not in our screen) is still ours to stop: it names the phone.
    for pid in $(pgrep -f -- "iproxy .* -u $UDID" 2>/dev/null); do kill "$pid" 2>/dev/null && echo "stopped iproxy pid $pid"; done
    exit 0
    ;;
esac

# --- up ------------------------------------------------------------------------------
if report_status 2>/dev/null; then exit 0; fi

if [[ -z "$TEAM" ]]; then
  echo "ERROR: no Apple team id - pass --team or set WDA_TEAM_ID (the team whose Xcode-managed" >&2
  echo "       profile lists this phone; the project's .simulator-verify/config.md records it)." >&2
  exit 2
fi
for tool in iproxy screen npm xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found (iproxy: brew install libimobiledevice)" >&2; exit 1; }
done

mkdir -p "$HOME_DIR"
if [[ ! -f "$PKG/WebDriverAgent.xcodeproj/project.pbxproj" ]]; then
  echo "fetching appium-webdriveragent into $HOME_DIR ..."
  ( cd "$HOME_DIR" && rm -rf package && npm pack appium-webdriveragent >/dev/null 2>&1 \
      && tar xzf appium-webdriveragent-*.tgz && rm -f appium-webdriveragent-*.tgz ) \
    || { echo "ERROR: npm pack appium-webdriveragent failed" >&2; exit 1; }
fi
echo "WDA sources: $PKG ($(grep -m1 '"version"' "$PKG/package.json" | tr -d ' ,"' ))"

# Stale pieces first: an iproxy on the port with no WDA behind it, an old test run.
if screen_up "$SCREEN_WDA"; then screen -S "$SCREEN_WDA" -X quit; fi
if screen_up "$SCREEN_PROXY"; then screen -S "$SCREEN_PROXY" -X quit; fi
OLD_T="$(existing_tunnel_port)"
[[ -n "$OLD_T" ]] && for pid in $(pgrep -f -- "iproxy .* -u $UDID"); do kill "$pid" 2>/dev/null; done
if lsof -ti tcp:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: :$PORT is taken by: $(ps -o command= -p "$(lsof -ti tcp:"$PORT" -sTCP:LISTEN | head -1)")" >&2
  echo "       pick another with --port" >&2
  exit 1
fi

: > "$LOG"
screen -dmS "$SCREEN_WDA" bash -c "cd '$PKG' && xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination 'id=$UDID' -derivedDataPath '$DD' CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM='$TEAM' \
  CODE_SIGN_IDENTITY='Apple Development' PRODUCT_BUNDLE_IDENTIFIER='$BUNDLE' test > '$LOG' 2>&1"
screen -dmS "$SCREEN_PROXY" bash -c "iproxy $PORT 8100 -u $UDID"
echo "started screens $SCREEN_WDA (xcodebuild test, log $LOG) and $SCREEN_PROXY (iproxy $PORT -> phone:8100)"
echo "waiting up to ${TIMEOUT}s for WebDriverAgent to answer on :$PORT ..."

WAITED=0
while (( WAITED < TIMEOUT )); do
  sleep 5; WAITED=$((WAITED + 5))
  # Both halves: a runner left on the phone by an EARLIER test run keeps answering
  # /status for a while (measured: "UP after 5s" with the new build 80s away), so the
  # new run must have printed ServerURLHere itself before its answer counts.
  if grep -q ServerURLHere "$LOG" && wda_answers "$PORT"; then
    echo "WDA UP for $UDID after ${WAITED}s: http://localhost:$PORT (runner built $(wda_built "$PORT"))"
    echo "  drive it: SIM_UDID=$UDID $HERE/sim-ui.sh elements"
    exit 0
  fi
  if ! screen_up "$SCREEN_WDA"; then
    echo "ERROR: the xcodebuild test run ended after ${WAITED}s without WDA answering. Tail of $LOG:" >&2
    tail -n 25 "$LOG" | sed 's/^/  /' >&2
    if grep -qiE 'is locked|passcode' "$LOG"; then echo "  => unlock the phone and retry" >&2; fi
    if grep -qiE 'not been trusted|Developer Mode' "$LOG"; then echo "  => trust the Mac on the phone / enable Developer Mode (Settings > Privacy & Security) and retry" >&2; fi
    if grep -qiE 'No profiles|provisioning|Signing for' "$LOG"; then echo "  => signing: the team's Xcode-managed profile must already list this phone (--team)" >&2; fi
    screen -S "$SCREEN_PROXY" -X quit 2>/dev/null
    exit 1
  fi
done
echo "ERROR: WebDriverAgent did not answer within ${TIMEOUT}s; the test run is still going. Tail of $LOG:" >&2
tail -n 15 "$LOG" | sed 's/^/  /' >&2
echo "  leave it and re-run with --status in a minute, or --stop to give up." >&2
exit 1
