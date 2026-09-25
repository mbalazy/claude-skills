#!/bin/bash
# sim-ui.sh - drive the iOS simulator without mobile-mcp.
# Lifecycle via `xcrun simctl`, UI observation/interaction via WebDriverAgent HTTP API
# (same backend mobile-mcp uses; the WDA runner app must be installed on the sim).
#
# Usage:
#   sim-ui.sh elements [--all] [--settled]  # a11y element tree as compact JSON (--all: every visible element incl. unlabeled;
#                                           #  --settled: two reads $SIMUI_SETTLE_SECONDS (2) apart, exit 3 if they differ = still animating)
#   sim-ui.sh tap X Y                       # coordinates in pt
#   sim-ui.sh doubletap X Y
#   sim-ui.sh longpress X Y [DURATION_MS]
#   sim-ui.sh swipe X1 Y1 X2 Y2 [DURATION_MS]
#   sim-ui.sh type "text"                   # types into the focused element
#   sim-ui.sh button HOME|ENTER|VOLUME_UP|VOLUME_DOWN
#   sim-ui.sh alert                         # text of the alert on screen now (exit 1 if none)
#   sim-ui.sh alert wait [SECONDS]          # poll until an alert shows up (default 15s)
#   sim-ui.sh alert accept [--all]          # accept the front alert; --all drains the queue
#   sim-ui.sh alert dismiss
#   sim-ui.sh screenshot [OUT.png] [--width N]   # default: resampled to device pt width (1px == 1pt); --width N overrides, 0 = full res
#   sim-ui.sh launch  BUNDLE_ID [ARG...]    # terminate+launch = guaranteed cold start not included; plain launch/foreground
#   sim-ui.sh relaunch BUNDLE_ID [ARG...]   # terminate first -> fresh JS bundle from Metro
#                                           # ARG... goes to `simctl launch`, e.g. -RCT_jsLocation localhost:8090
#   sim-ui.sh terminate BUNDLE_ID
#   sim-ui.sh openurl URL
#   sim-ui.sh devices                       # booted simulators
#   sim-ui.sh waitfor REGEX [--timeout S] [--all]   # poll the tree until it matches (beats a fixed sleep)
#   sim-ui.sh wait [SECONDS]                # plain pause, for use inside `do`
#   sim-ui.sh do 'STEP' 'STEP' ...          # run several of the above in ONE process and ONE round trip
#                                           # (steps read from stdin when no args; '?step' may fail; '#step' is a comment)
#
# Device selection: $SIM_UDID if set, else the only booted simulator (or, with no
# simulator booted, the only physical iPhone plugged in). With more than one candidate
# and $SIM_UDID unset the script REFUSES rather than picking one, and it checks that the
# WDA answering on $WDA_PORT really drives that device.
#
# A PHYSICAL iPhone is a first-class target: put its udid (the 0000XXXX-XXXXXXXXXXXXXXXX
# shape that `xcrun devicectl list devices` prints) in $SIM_UDID and every command above
# works unchanged. The script tells the two apart by the udid's shape and switches the
# plumbing underneath: lifecycle through `xcrun devicectl` instead of `simctl`,
# WebDriverAgent reached through an `iproxy <port> 8100 -u <udid>` tunnel (found by the
# udid in the iproxy command line when $WDA_PORT is unset; never auto-started - see
# wda-device.sh), screen geometry from WDA instead of simctl, screenshots via devicectl,
# and `type` sends ONE character per request with a pause, because a burst drops
# characters on a device (measured: "5125550199" arrived as "(519) 9").
#
# Coordinates are POINTS. Screenshots are PIXELS - divide by the device scale (3 on
# every current iPhone) before tapping what you measured on an image.

set -euo pipefail

WDA_PORT_GIVEN="${WDA_PORT:-}"
WDA_PORT="${WDA_PORT:-8100}"
WDA="http://localhost:${WDA_PORT}"
WDA_RUNNER="com.facebook.WebDriverAgentRunner.xctrunner"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- setup caches -----------------------------------------------------------
# Every command used to re-derive the same three immutable facts: the device's screen
# geometry (3 `simctl getenv` round trips), which simulator owns $WDA_PORT (lsof + ps),
# and a fresh WDA session (POST + DELETE). Measured on an idle sim that was ~1.0s of
# the 1.4s a `tap` cost. The geometry of a given UDID can never change, so it is cached
# on disk; the other two are memoised per process, which is what makes `do` (a whole
# route in one invocation) cheap without weakening a single check.
# SIMUI_NO_CACHE=1 disables the disk cache.
SIMUI_CACHE_DIR="${SIMUI_CACHE_DIR:-${TMPDIR:-/tmp}/sim-ui-cache}"
_MEMO_POINTS=""      # "<w-pt> <h-pt> <scale>" for the target device
_MEMO_WDA=""         # non-empty once WDA answered AND was confirmed to drive our sim
_MEMO_SID=""         # a WDA session reused by every interaction in this process
_MEMO_KIND=""        # "sim" or "device", decided once from the udid's shape

# A simulator udid is 8-4-4-4-12 hex; a physical iPhone's is 0000XXXX-<16 hex> (2018+
# hardware) or 40 bare hex digits (older). The shape decides which plumbing every command
# below uses, so a phone never has to be announced with a flag somebody forgets.
udid_kind() {
  if [[ "$1" =~ ^0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}$ || "$1" =~ ^[0-9a-f]{40}$ ]]; then
    echo device
  else
    echo sim
  fi
}

kind() {
  [ -n "$_MEMO_KIND" ] || _MEMO_KIND="$(udid_kind "$(udid)")"
  echo "$_MEMO_KIND"
}

# Physical iPhones currently plugged in (USB), one udid per line.
connected_devices() {
  xcrun devicectl list devices 2>/dev/null \
    | awk '$0 ~ /physical/ && $0 ~ /connected/' \
    | grep -oE '0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}|\b[0-9a-f]{40}\b'
}

# Pid of the app's main process on the phone, or nothing when it is not running.
# devicectl only terminates by pid, and the process list names executables by bundle
# path rather than by bundle id, so this resolves the path first.
device_app_pid() {
  local dev="$1" bundle="$2" apps procs
  apps="$(mktemp -t simui-apps)"; procs="$(mktemp -t simui-procs)"
  xcrun devicectl device info apps --device "$dev" --bundle-id "$bundle" --json-output "$apps" >/dev/null 2>&1
  xcrun devicectl device info processes --device "$dev" --json-output "$procs" >/dev/null 2>&1
  python3 - "$apps" "$procs" <<'PYEOF'
import json, sys, urllib.parse
try:
    apps = json.load(open(sys.argv[1]))["result"]["apps"]
    procs = json.load(open(sys.argv[2]))["result"]["runningProcesses"]
except Exception:
    sys.exit(0)
for app in apps:
    prefix = urllib.parse.unquote(app.get("url", "")).replace("file://", "").rstrip("/")
    if not prefix:
        continue
    for p in procs:
        exe = urllib.parse.unquote(p.get("executable", "")).replace("file://", "")
        if exe.startswith(prefix + "/") and "/PlugIns/" not in exe[len(prefix):]:
            print(p["processIdentifier"]); sys.exit(0)
PYEOF
  rm -f "$apps" "$procs"
}

udid() {
  if [ -n "${SIM_UDID:-}" ]; then echo "$SIM_UDID"; return; fi
  local booted count phones pcount
  booted="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}')"
  count="$(printf '%s\n' "$booted" | grep -c . || true)"
  # Picking the first of several booted sims is a coin flip that looks like a
  # decision - and the wrong device answers just as confidently as the right one.
  if [ "$count" -gt 1 ]; then
    echo "ERROR: $count simulators are booted and SIM_UDID is not set - refusing to guess." >&2
    xcrun simctl list devices booted | grep -i booted | sed 's/^/  /' >&2
    echo "  Pin one: SIM_UDID=<udid> $(basename "$0") ..." >&2
    exit 2
  fi
  if [ "$count" -eq 0 ]; then
    # No simulator at all: a single plugged-in iPhone is the only thing this could
    # mean. A phone is never picked over a booted simulator implicitly - a phone
    # left on the cable to charge must not silently become the target.
    phones="$(connected_devices)"
    pcount="$(printf '%s\n' "$phones" | grep -c . || true)"
    if [ "$pcount" -eq 1 ]; then
      echo "NOTE: no simulator booted - targeting the plugged-in iPhone $phones (pin it with SIM_UDID to silence this)." >&2
      printf '%s\n' "$phones"; return
    elif [ "$pcount" -gt 1 ]; then
      echo "ERROR: no simulator booted and $pcount iPhones plugged in - refusing to guess. Pin one: SIM_UDID=<udid>" >&2
      xcrun devicectl list devices 2>/dev/null | awk '$0 ~ /physical/ && $0 ~ /connected/' | sed 's/^/  /' >&2
      exit 2
    fi
  fi
  printf '%s\n' "$booted" | head -1
}

# Which simulator does the process listening on a port belong to? CoreSimulator
# runs every simulated process out of .../Devices/<UDID>/..., so the answer is in
# the process path. Empty output = could not tell.
port_owner_udid() {
  local pid cmd
  pid="$(lsof -ti tcp:"$1" -sTCP:LISTEN 2>/dev/null | head -1)"
  [ -n "$pid" ] || return 0
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  case "$cmd" in
    # An iproxy tunnel to a physical iPhone names its device on the command line
    # (`iproxy <local> 8100 -u <udid>`), which is the phone-side answer to the
    # same question.
    iproxy*|*/iproxy*) printf '%s\n' "$cmd" | grep -oE -- '-u +[0-9A-Fa-f-]+' | awk '{print $2}' | head -1 ;;
    *) printf '%s\n' "$cmd" | sed -nE 's#.*/Devices/([0-9A-F-]{36})/.*#\1#p' | head -1 ;;
  esac
}

# The iproxy tunnel (local port) that leads to a given phone's WebDriverAgent, if one
# is up. Ports are scanned by listener, not guessed from a table.
device_wda_port() {
  local want="$1" pid port cmd
  for pid in $(pgrep -x iproxy 2>/dev/null); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    printf '%s\n' "$cmd" | grep -qE -- "-u +$want\b" || continue
    port="$(printf '%s\n' "$cmd" | awk '{for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}')"
    [ -n "$port" ] && { echo "$port"; return 0; }
  done
  return 0
}

# A live WDA on the port proves something is listening - NOT that it drives the
# simulator you asked for. When it does not, every element tree and every tap
# silently goes to the other device (journal sim-rig 20260809-c2f3, 20260811-8beb).
assert_wda_owner() {
  local want="$1" owner p other
  owner="$(port_owner_udid "$WDA_PORT")"
  if [ -z "$owner" ]; then
    echo "WARN: something answers on :$WDA_PORT but its owning simulator could not be" >&2
    echo "      determined (no listening process found via lsof) - continuing unverified." >&2
    return 0
  fi
  [ "$owner" = "$want" ] && return 0
  echo "ERROR: :$WDA_PORT is WebDriverAgent for simulator $owner, not $want." >&2
  echo "  Everything read or tapped through this port would land on the other device." >&2
  for p in $(seq 8100 8110); do
    [ "$p" = "$WDA_PORT" ] && continue
    other="$(port_owner_udid "$p")"
    if [ "$other" = "$want" ]; then
      echo "  WDA for $want is already up on :$p - re-run with WDA_PORT=$p." >&2
      exit 1
    fi
  done
  if [ "$(kind)" = device ]; then
    other="$(device_wda_port "$want")"
    if [ -n "$other" ]; then
      echo "  An iproxy tunnel to $want is already up on :$other - re-run with WDA_PORT=$other (or unset it)." >&2
    else
      echo "  No iproxy tunnel to $want is up. Bring WebDriverAgent up on the phone with:" >&2
      echo "    $HERE/wda-device.sh $want" >&2
    fi
    exit 1
  fi
  echo "  No WDA for $want found on :8100-8110. Start one on a free port:" >&2
  echo "    SIMCTL_CHILD_USE_PORT=<free-port> xcrun simctl launch $want $WDA_RUNNER" >&2
  echo "    then re-run with WDA_PORT=<free-port>." >&2
  exit 1
}

# Why the XCTest runner may refuse to start on an otherwise healthy, booted simulator.
# WDA is an XCTest bundle, and Xcode will not background a test runner on a device that
# has no Simulator.app window - a sim booted by `simctl boot` while Simulator.app is
# closed, or created fresh and never opened (`XCTest 10300, failed to background test
# runner`, journal sim-rig 20260811-8beb). That never shows up in the 20 s of silence this
# function otherwise ends in, so name it. The booted-sim COUNT is printed as context only:
# three windowed sims hosted WDA fine on 2026-08-20, so the count alone is not a cause.
wda_start_diagnostics() {
  local want="$1" name windows booted
  name="$(xcrun simctl list devices 2>/dev/null | grep -F "($want)" | head -1 | sed -E 's/^ *//; s/ \(.*//' || true)"
  if ! pgrep -x Simulator >/dev/null 2>&1; then
    echo "  Simulator.app is NOT running: the device is booted headless (simctl boot), and the" >&2
    echo "  XCTest runner does not start on a sim without a window. Start Simulator.app on it, then retry:" >&2
    echo "    open -a Simulator --args -CurrentDeviceUDID $want" >&2
  else
    windows="$(osascript -e 'tell application "System Events" to get name of every window of process "Simulator"' 2>/dev/null || true)"
    if [ -n "$name" ] && [ -n "$windows" ] && ! printf '%s\n' "$windows" | grep -qF "$name"; then
      echo "  Simulator.app shows no window for '$name' ($want) - a booted device without a" >&2
      echo "  window cannot host the XCTest runner. A device booted WHILE Simulator.app runs gets" >&2
      echo "  a window (open --args is ignored by a running Simulator.app), so re-boot it, then retry:" >&2
      echo "    xcrun simctl shutdown $want && xcrun simctl boot $want" >&2
    fi
  fi
  booted="$(xcrun simctl list devices booted 2>/dev/null | grep -c '(Booted)' || true)"
  if [ "${booted:-0}" -ge 2 ]; then
    echo "  booted simulators now ($booted):" >&2
    xcrun simctl list devices booted 2>/dev/null | grep '(Booted)' | sed 's/^ */    /' >&2
  fi
}

ensure_wda() {
  local want launch_out tunnel
  [ -n "$_MEMO_WDA" ] && return 0
  want="$(udid)"
  if [ "$(kind)" = device ]; then
    # WDA on a phone is an XCTest run that only `xcodebuild test` can start (an
    # already-installed runner cannot be launched with devicectl), so it is never
    # auto-started here. What can be derived is the tunnel: with WDA_PORT unset the
    # iproxy whose command line names this udid is the port.
    if [ -z "$WDA_PORT_GIVEN" ]; then
      tunnel="$(device_wda_port "$want")"
      if [ -z "$tunnel" ]; then
        echo "ERROR: no iproxy tunnel to iPhone $want is up, so its WebDriverAgent is unreachable." >&2
        echo "  Bring it up (WDA via xcodebuild test in a screen + iproxy), then retry:" >&2
        echo "    $HERE/wda-device.sh $want" >&2
        exit 1
      fi
      WDA_PORT="$tunnel"; WDA="http://localhost:${WDA_PORT}"
    fi
    if curl -s -m 3 "$WDA/status" >/dev/null 2>&1; then assert_wda_owner "$want"; _MEMO_WDA=1; return; fi
    echo "ERROR: nothing answers on :$WDA_PORT for iPhone $want." >&2
    if [ -n "$(port_owner_udid "$WDA_PORT")" ]; then
      echo "  The iproxy tunnel is up but WebDriverAgent on the phone is not answering through it:" >&2
      echo "  the xcodebuild test run has ended or is still starting (its log ends in ServerURLHere when ready)." >&2
    fi
    echo "  Restart it with: $HERE/wda-device.sh $want" >&2
    exit 1
  fi
  if curl -s -m 2 "$WDA/status" >/dev/null 2>&1; then assert_wda_owner "$want"; _MEMO_WDA=1; return; fi
  # SIMCTL_CHILD_ is load-bearing: WDA reads USE_PORT from the ENVIRONMENT, and
  # anything after the bundle id is a launch argument simctl never turns into one.
  # Without the prefix this relaunch lands on WDA's default 8100 whatever WDA_PORT says.
  # `|| true`: under set -e a refused launch would end the script here, before the
  # diagnostics below get to say why it was refused.
  launch_out="$(SIMCTL_CHILD_USE_PORT="$WDA_PORT" xcrun simctl launch "$want" "$WDA_RUNNER" 2>&1 || true)"
  for _ in $(seq 1 20); do
    sleep 1
    if curl -s -m 2 "$WDA/status" >/dev/null 2>&1; then assert_wda_owner "$want"; _MEMO_WDA=1; return; fi
  done
  echo "ERROR: WebDriverAgent did not come up on :$WDA_PORT" >&2
  # simctl's own words first - a refused launch says why here and nowhere else.
  case "$launch_out" in
    "$WDA_RUNNER: "[0-9]*) ;;   # "<bundle>: <pid>" = launched normally, nothing to add
    "") ;;
    *) printf '%s\n' "$launch_out" | sed 's/^/  simctl: /' >&2 ;;
  esac
  wda_start_diagnostics "$want"
  # Name the likely cause instead of sending the reader off to reinstall a runner
  # that is installed and healthy one port over.
  if [ "$WDA_PORT" != "8100" ] && curl -s -m 2 "http://localhost:8100/status" >/dev/null 2>&1; then
    echo "  WDA IS answering on the default :8100, so the runner is installed and running." >&2
    echo "  It was almost certainly launched without the SIMCTL_CHILD_USE_PORT=$WDA_PORT prefix" >&2
    echo "  (a bare 'simctl launch <udid> $WDA_RUNNER USE_PORT=$WDA_PORT' is silently ignored)." >&2
    echo "  Either relaunch WDA with that prefix, or re-run with WDA_PORT=8100." >&2
  else
    echo "  Nothing is answering on :8100 either - is $WDA_RUNNER installed on $want?" >&2
  fi
  exit 1
}

# "<width-pt> <height-pt> <scale>" for the target device, or nothing if unreadable.
device_points() {
  local w h s f
  if [ -n "$_MEMO_POINTS" ]; then echo "$_MEMO_POINTS"; return 0; fi
  f="$SIMUI_CACHE_DIR/points-$1"
  if [ -z "${SIMUI_NO_CACHE:-}" ] && [ -s "$f" ]; then
    _MEMO_POINTS="$(cat "$f")"; echo "$_MEMO_POINTS"; return 0
  fi
  if [ "$(udid_kind "$1")" = device ]; then
    # A phone has no simctl environment; WebDriverAgent reports the geometry
    # (/wda/screen: screenSize in points + scale). Screenshots work without WDA,
    # so a phone without a tunnel just loses the range check and the pt resampling.
    if [ -z "$_MEMO_WDA" ]; then
      _p="$WDA_PORT"; [ -z "$WDA_PORT_GIVEN" ] && _p="$(device_wda_port "$1")"
      if [ -n "$_p" ] && curl -s -m 2 "http://localhost:$_p/status" >/dev/null 2>&1; then ensure_wda; fi
    fi
    if [ -n "$_MEMO_WDA" ]; then
      session
      read -r w h s < <(curl -s -m 10 "$WDA/session/$_MEMO_SID/wda/screen" | python3 -c '
import sys, json
try:
    v = json.load(sys.stdin)["value"]; ss = v["screenSize"]
    print(int(ss["width"]), int(ss["height"]), int(v["scale"]))
except Exception:
    pass')
    fi
  else
    w="$(xcrun simctl getenv "$1" SIMULATOR_MAINSCREEN_WIDTH 2>/dev/null || true)"
    h="$(xcrun simctl getenv "$1" SIMULATOR_MAINSCREEN_HEIGHT 2>/dev/null || true)"
    s="$(xcrun simctl getenv "$1" SIMULATOR_MAINSCREEN_SCALE 2>/dev/null | cut -d. -f1 || true)"
    [ -n "$w" ] && [ -n "$h" ] && [ -n "$s" ] && [ "$s" -gt 0 ] 2>/dev/null || return 0
    w=$((w / s)); h=$((h / s))
  fi
  [ -n "${w:-}" ] && [ -n "${h:-}" ] && [ -n "${s:-}" ] && [ "$s" -gt 0 ] 2>/dev/null || return 0
  _MEMO_POINTS="$w $h $s"
  if [ -z "${SIMUI_NO_CACHE:-}" ]; then
    mkdir -p "$SIMUI_CACHE_DIR" 2>/dev/null || true
    printf '%s\n' "$_MEMO_POINTS" > "$f" 2>/dev/null || true
  fi
  echo "$_MEMO_POINTS"
}

# WDA accepts an out-of-screen tap without complaining and nothing happens, which
# reads exactly like a frozen app (journal sim-rig 20260803-8f3d). The usual source
# is a coordinate measured on a screenshot, which is in pixels.
assert_in_bounds() {
  local dims w h s x y
  dims="$(device_points "$(udid)")"
  if [ -z "$dims" ]; then
    echo "WARN: could not read the screen size - coordinates not range-checked." >&2
    return 0
  fi
  read -r w h s <<<"$dims"
  while [ "$#" -ge 2 ]; do
    x="$1"; y="$2"; shift 2
    case "$x,$y" in
      ,*|*,|*[!0-9,]*) echo "ERROR: coordinates must be non-negative integers, got '$x','$y'" >&2; exit 2 ;;
    esac
    if [ "$x" -ge "$w" ] || [ "$y" -ge "$h" ]; then
      echo "ERROR: $x,$y is off-screen - this device is ${w}x${h} POINTS." >&2
      echo "  Screenshots of it are $((w * s))x$((h * s)) PIXELS: divide by $s to get points." >&2
      exit 2
    fi
  done
}

# One session per PROCESS, not per command: a batch of taps through `do` pays the
# create/delete round trip once.
#
# It sets the global $_MEMO_SID instead of printing the id, and it must NOT be called
# as `sid=$(session)`: a command substitution is a subshell, so both the assignment and
# any trap installed inside it would die with that subshell - measured 2026-08-27 as a
# tap that reported "tapped 220,904" while the session had already been torn down and
# nothing happened on screen. Teardown is the one EXIT trap installed below.
session() {
  [ -n "$_MEMO_SID" ] && return 0
  _MEMO_SID="$(curl -s -X POST "$WDA/session" -H 'Content-Type: application/json' \
    -d '{"capabilities":{"alwaysMatch":{"platformName":"iOS"}}}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['value']['sessionId'])")"
}

end_session() { [ -n "${1:-}" ] && curl -s -X DELETE "$WDA/session/$1" -o /dev/null; }
trap 'end_session "$_MEMO_SID" 2>/dev/null || true' EXIT

# Prints the front alert's text, or nothing and returns 1 when there is no alert.
alert_text() {
  curl -s -m 5 "$WDA/session/$1/alert/text" | python3 -c '
import sys, json
try:
    v = json.load(sys.stdin).get("value")
except Exception:
    sys.exit(1)
if v is None or isinstance(v, dict):   # {"error": "no such alert"} arrives as a dict
    sys.exit(1)
print(v)
'
}

pointer_actions() {
  local sid resp
  session; sid="$_MEMO_SID"
  resp="$(curl -s -X POST "$WDA/session/$sid/actions" -H 'Content-Type: application/json' \
    -d "{\"actions\":[{\"type\":\"pointer\",\"id\":\"f1\",\"parameters\":{\"pointerType\":\"touch\"},\"actions\":$1}]}")"
  case "$resp" in
    *'"error"'*) echo "WARN: WebDriverAgent refused the gesture: $resp" >&2 ;;
  esac
}

# Every command lives in this function so `do` can run a whole route inside ONE
# process - one WDA session, one geometry lookup, one ownership check - and, far more
# importantly, inside ONE Claude round trip.
dispatch() {
cmd="${1:-}"; shift || true
case "$cmd" in
  devices)
    xcrun simctl list devices booted | grep -i booted
    # Physical iPhones on the cable, in the same "name (udid) (state)" shape.
    xcrun devicectl list devices 2>/dev/null | awk '$0 ~ /physical/ && $0 ~ /connected/' \
      | sed -E 's/^ *(.*[^ ]) +([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}) \(UDID\).*$/    \1 (\2) (Connected iPhone)/' || true
    ;;

  elements)
    ensure_wda
    ALL=""
    SETTLED=0
    for _a in "$@"; do
      case "$_a" in
        --all) ALL="--all" ;;
        --settled) SETTLED=1 ;;
        *) echo "unknown flag for elements: $_a" >&2; exit 2 ;;
      esac
    done
    # Answering this query makes UITabBarController instantiate EVERY child controller,
    # so a screen you never navigated to can mount just because you measured
    # (journal sim-rig 20260730-74da). Never use it to prove a screen was not mounted.
    echo "NOTE: reading the a11y tree mounts every tab's controller - it is not a passive read." >&2
    if [ "$SETTLED" -eq 0 ]; then
      curl -s -m 20 "$WDA/source?format=json" | python3 "$HERE/wda_tree.py" $ALL
    else
      # One read right after a tap is a FRAME of an animation, not the state: a
      # dismissing keyboard or a sheet mid-transition reads as "gone" and is back
      # in the next frame (2026-08-29: "no keyboard, grabber Expanded" read once,
      # keyboard present 4 s later - a false CONFIRMED for tap-to-dismiss). Two
      # reads that agree are the state; two that differ are refused, with the diff.
      # The status-bar clock is in the tree, so a minute boundary inside the gap
      # would read as motion - compare with every HH:MM label normalised.
      _gap="${SIMUI_SETTLE_SECONDS:-2}"
      _first="$(curl -s -m 20 "$WDA/source?format=json" | python3 "$HERE/wda_tree.py" $ALL)"
      sleep "$_gap"
      _second="$(curl -s -m 20 "$WDA/source?format=json" | python3 "$HERE/wda_tree.py" $ALL)"
      _norm() { sed -E 's/"label":"[0-9]{1,2}:[0-9]{2}"/"label":"HH:MM"/g'; }
      if [ "$(printf '%s' "$_first" | _norm)" != "$(printf '%s' "$_second" | _norm)" ]; then
        echo "ERROR: the a11y tree changed between two reads ${_gap}s apart - the screen is still moving (keyboard, sheet, transition), so neither read is its state. Wait and read again; what changed:" >&2
        diff <(printf '%s\n' "$_first") <(printf '%s\n' "$_second") | head -20 >&2 || true
        exit 3
      fi
      printf '%s\n' "$_second"
    fi
    ;;

  tap)
    ensure_wda
    assert_in_bounds "${1:-}" "${2:-}"
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":100},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "tapped $1,$2"
    ;;

  doubletap)
    ensure_wda
    assert_in_bounds "${1:-}" "${2:-}"
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":50},{\"type\":\"pointerUp\",\"button\":0},{\"type\":\"pause\",\"duration\":100},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":50},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "double-tapped $1,$2"
    ;;

  longpress)
    ensure_wda
    assert_in_bounds "${1:-}" "${2:-}"
    dur="${3:-800}"
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":$dur},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "long-pressed $1,$2 (${dur}ms)"
    ;;

  swipe)
    ensure_wda
    assert_in_bounds "${1:-}" "${2:-}" "${3:-}" "${4:-}"
    dur="${5:-300}"
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pointerMove\",\"duration\":$dur,\"x\":$3,\"y\":$4},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "swiped $1,$2 -> $3,$4"
    ;;

  type)
    ensure_wda
    session; sid="$_MEMO_SID"
    # A device drops characters from a burst ("5125550199" landed as "(519) 9" on an
    # iPhone 12), so on a phone every character is its own request with a pause between
    # them. SIMUI_TYPE_DELAY (seconds) forces that mode on a simulator too - segmented
    # OTP boxes lose characters there the same way.
    _delay="${SIMUI_TYPE_DELAY:-}"
    if [ -z "$_delay" ] && [ "$(kind)" = device ]; then _delay=0.35; fi
    if [ -n "$_delay" ]; then
      printf '%s' "$1" | python3 -c 'import sys,json; [print(json.dumps({"value":[c]})) for c in sys.stdin.read()]' \
        | while IFS= read -r _body; do
            curl -s -X POST "$WDA/session/$sid/wda/keys" -H 'Content-Type: application/json' -d "$_body" -o /dev/null
            sleep "$_delay"
          done
      echo "typed (one character per request, ${_delay}s apart): $1"
    else
      printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps({"value":[sys.stdin.read()]}))' \
        | curl -s -X POST "$WDA/session/$sid/wda/keys" -H 'Content-Type: application/json' -d @- -o /dev/null
      echo "typed: $1"
    fi
    ;;

  button)
    ensure_wda
    case "$1" in
      ENTER) "$0" type $'\n'; exit ;;
      HOME) name="home" ;;
      VOLUME_UP) name="volumeup" ;;
      VOLUME_DOWN) name="volumedown" ;;
      *) echo "unsupported button: $1" >&2; exit 1 ;;
    esac
    session; sid="$_MEMO_SID"
    curl -s -X POST "$WDA/session/$sid/wda/pressButton" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\"}" -o /dev/null
    echo "pressed $1"
    ;;

  # Alerts arrive on their own schedule and QUEUE UP. A single read a few seconds
  # after a tap that came back "no alert" is not evidence the tap did nothing
  # (journal sim-rig 20260811-3699) - wait for one, and drain the queue afterwards.
  alert)
    ensure_wda
    sub="${1:-text}"; shift || true
    session; sid="$_MEMO_SID"
    case "$sub" in
      text)
        if txt=$(alert_text "$sid"); then echo "$txt"; else echo "no alert on screen" >&2; exit 1; fi
        ;;
      wait)
        deadline=$(( SECONDS + ${1:-15} ))
        while [ "$SECONDS" -lt "$deadline" ]; do
          if txt=$(alert_text "$sid"); then echo "$txt"; exit 0; fi
          sleep 1
        done
        echo "no alert appeared within ${1:-15}s" >&2
        exit 1
        ;;
      accept|dismiss)
        all=""; [ "${1:-}" = "--all" ] && all=1
        n=0
        while txt=$(alert_text "$sid"); do
          curl -s -X POST "$WDA/session/$sid/alert/$sub" -H 'Content-Type: application/json' -d '{}' -o /dev/null
          n=$((n + 1))
          echo "${sub}ed: $txt"
          [ -n "$all" ] || break
          sleep 1
        done
        if [ "$n" = "0" ]; then echo "no alert on screen" >&2; exit 1; fi
        # More alerts than you ever saw on screen is the signal that the taps DID land.
        if [ -n "$all" ]; then echo "$n alert(s) drained"; fi
        ;;
      *) echo "unknown: alert $sub (text|wait|accept|dismiss)" >&2; exit 1 ;;
    esac
    ;;

  screenshot)
    out="${1:-/tmp/sim-ui-shot.png}"
    width=""
    if [ "${2:-}" = "--width" ]; then width="${3:-}"; fi
    dev="$(udid)"
    if [ "$(kind)" = device ]; then
      # devicectl reads the phone's display directly; WDA's /screenshot on a device was
      # seen to return a stale frame, so it is not used here.
      xcrun devicectl device capture screenshot --device "$dev" --destination "$out" >/dev/null 2>&1
    else
      xcrun simctl io "$dev" screenshot "$out" >/dev/null 2>&1
    fi
    if [ -z "$width" ]; then
      # default: resample to the device's point width so 1px == 1pt on any simulator.
      # The width comes from the cached geometry - reading it back with `sips -g pixelWidth`
      # plus a `simctl getenv` cost ~0.2s per screenshot for a number that IS the point width.
      dims="$(device_points "$dev")"
      if [ -n "$dims" ]; then
        read -r dpw _dph _dps <<<"$dims"; width="$dpw"
      else
        pxw=$(sips -g pixelWidth "$out" | awk '/pixelWidth/ {print $2}')
        width=$(( pxw / 3 ))
      fi
    fi
    if [ "$width" != "0" ]; then
      sips --resampleWidth "$width" "$out" >/dev/null 2>&1
    fi
    echo "$out"
    ;;

  # Everything after the bundle id is forwarded to `simctl launch` as a launch argument.
  # The one that matters in practice is `-RCT_jsLocation localhost:<port>`, which points the
  # app at another Metro than the port baked into the binary - it belongs to a single launch,
  # so a relaunch without it silently sends the app back to its baked port.
  # On a phone the same four go through devicectl. The `--` before the app's arguments is
  # load-bearing there: without it devicectl parses `-RCT_jsLocation` as its own option.
  launch)
    bundle="$1"; shift
    if [ "$(kind)" = device ]; then
      xcrun devicectl device process launch --device "$(udid)" "$bundle" -- "$@"
    else
      xcrun simctl launch "$(udid)" "$bundle" "$@"
    fi
    ;;
  relaunch)
    bundle="$1"; shift
    if [ "$(kind)" = device ]; then
      xcrun devicectl device process launch --terminate-existing --device "$(udid)" "$bundle" -- "$@"
    else
      xcrun simctl terminate "$(udid)" "$bundle" 2>/dev/null || true; xcrun simctl launch "$(udid)" "$bundle" "$@"
    fi
    ;;
  terminate)
    if [ "$(kind)" = device ]; then
      _pid="$(device_app_pid "$(udid)" "$1")"
      if [ -z "$_pid" ]; then echo "$1 is not running on $(udid)" >&2; exit 1; fi
      xcrun devicectl device process terminate --device "$(udid)" --pid "$_pid"
    else
      xcrun simctl terminate "$(udid)" "$1"
    fi
    ;;
  openurl)
    if [ "$(kind)" = device ]; then
      xcrun devicectl device process openURL --device "$(udid)" "$1"
    else
      xcrun simctl openurl "$(udid)" "$1"
    fi
    ;;

  # --- batching and waiting --------------------------------------------------
  # `do` is the answer to the real cost of driving a simulator: not the milliseconds
  # WDA takes, but the fact that every single step used to be its own Claude round
  # trip. A known route belongs in ONE call.
  #   sim-ui.sh do 'tap 220 904' 'waitfor Schedule' 'elements'
  # Steps are the script's own subcommands. A step prefixed with ? may fail without
  # aborting the batch; a step starting with # is a comment. With no arguments the
  # steps are read from stdin, one per line.
  do)
    if [ "$#" -eq 0 ]; then
      _steps=()
      while IFS= read -r _line; do _steps+=("$_line"); done
    else
      _steps=("$@")
    fi
    for _step in "${_steps[@]}"; do
      _tol=""
      case "$_step" in
        ""|\#*) continue ;;
        \?*) _tol=1; _step="${_step#\?}" ;;
      esac
      printf '\xc2\xbb %s\n' "$_step"
      if [ -n "$_tol" ]; then
        # A subshell, not just `|| true`: several branches report failure with `exit`,
        # which ends the whole script however the caller guards it.
        ( eval "dispatch $_step" ) || echo "  (step failed - tolerated)"
      else
        eval "dispatch $_step"
      fi
    done
    ;;

  # A named pause, so a route reads as a route. Prefer `waitfor` - it costs what the
  # app needs rather than a constant somebody guessed.
  wait)
    sleep "${1:-1}"
    ;;

  # Poll the element tree until something matches, instead of sleeping a fixed number
  # of seconds and hoping. Prints the matching elements; exit 1 on timeout.
  #   sim-ui.sh waitfor 'Sara Jogurt' --timeout 15
  waitfor)
    ensure_wda
    _pat="${1:-}"
    if [ -z "$_pat" ]; then echo "usage: waitfor REGEX [--timeout S] [--all]" >&2; exit 2; fi
    shift
    _wf_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout) _wf_args+=(--timeout "$2"); shift 2 ;;
        --all)     _wf_args+=(--all); shift ;;
        *) echo "unknown flag for waitfor: $1" >&2; exit 2 ;;
      esac
    done
    python3 "$HERE/wda_tree.py" --port "$WDA_PORT" --match "$_pat" "${_wf_args[@]+"${_wf_args[@]}"}"
    ;;

  *)
    grep '^#   sim-ui.sh' "$0" | sed 's/^# *//'
    exit 1
    ;;
esac
}

dispatch "$@"
