#!/bin/bash
# wda-sim.sh - WebDriverAgent on a SIMULATOR: is the runner installed, where a usable
# runner bundle comes from, and the readiness gate a prep runs before handing a
# simulator to an unattended session. The physical-iPhone counterpart is wda-device.sh.
#
#   wda-sim.sh status <udid>              # installed | absent | unknown (exit 0 | 1 | 3)
#   wda-sim.sh source <udid>              # path of a usable runner bundle for <udid> (exit 1 = none)
#   wda-sim.sh build                      # build a simulator runner into the cache (minutes, once)
#   wda-sim.sh ensure <udid> --port <p>   # install if absent, start on <p>, prove it; READY or NOT READY
#   wda-sim.sh check  <udid> --port <p>   # the same proof without installing or starting anything
#
# Why a gate and not "RIG OK": rig-check.sh proves the app runs the checkout's JS. A
# simulator created for a run has no runner at all, and that was only discovered mid-shift
# when sim-ui.sh could not start it (journal sim-rig 20260928-4ccb). Installed is not
# ready either: READY means the listener on <p> belongs to <udid> and an element tree
# came back through it.
#
# Runner sources, first usable one wins:
#   1. $WDA_SIM_RUNNER - an explicitly supplied .app; if it is unusable the answer is
#      "none", never a silent fallback to something else.
#   2. The build product of `wda-sim.sh build` ($WDA_SIM_DERIVED, default
#      ~/.cache/wda-device/DerivedData-sim).
#   3. A runner already installed on another simulator ($WDA_SIM_SEARCH_ROOT, default
#      ~/Library/Developer/CoreSimulator/Devices), same iOS runtime as the target first.
#      Found by globbing at run time: the container path differs per simulator and per
#      install, so none is ever written down as the source.
# "Usable" = bundle id com.facebook.WebDriverAgentRunner.xctrunner, built for
# iphonesimulator, contains this Mac's architecture, and its MinimumOSVersion is not
# above the target's runtime. A copy from a different runtime passes that check but is
# unproven until the gate's element probe succeeds.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WDA_RUNNER="com.facebook.WebDriverAgentRunner.xctrunner"
WDA_HOME="${WDA_DEVICE_HOME:-$HOME/.cache/wda-device}"
SIM_DERIVED="${WDA_SIM_DERIVED:-$WDA_HOME/DerivedData-sim}"
BUILT_RUNNER="$SIM_DERIVED/Build/Products/Debug-iphonesimulator/WebDriverAgentRunner-Runner.app"
SEARCH_ROOT="${WDA_SIM_SEARCH_ROOT:-$HOME/Library/Developer/CoreSimulator/Devices}"
START_TIMEOUT="${WDA_SIM_START_TIMEOUT:-30}"

die_usage() { grep '^#   wda-sim.sh' "$0" | sed 's/^# *//' >&2; exit 2; }

is_device_udid() {
  [[ "$1" =~ ^0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}$ || "$1" =~ ^[0-9a-f]{40}$ ]]
}

# "installed", "absent" or "unknown: <simctl's words>". Only simctl's own "no such file"
# for this bundle id is absence; a shutdown or unknown device is a failed inspection.
install_state() {
  local out rc
  out="$(xcrun simctl get_app_container "$1" "$WDA_RUNNER" app 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then echo installed; return; fi
  if printf '%s\n' "$out" | grep -q 'NSPOSIXErrorDomain, code=2'; then echo absent; return; fi
  echo "unknown: $(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g') (simctl exit $rc)"
}

# "<runtime version> <state>" of a simulator, e.g. "26.2 Booted"; empty when unknown.
sim_info() {
  xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, re, sys
want = sys.argv[1]
try:
    devs = json.load(sys.stdin)["devices"]
except Exception:
    sys.exit(0)
for rt, lst in devs.items():
    for d in lst:
        if d.get("udid") == want:
            m = re.search(r"iOS-(\d+)-(\d+)", rt)
            print((m.group(1) + "." + m.group(2)) if m else "?", d.get("state", "?"))
            sys.exit(0)
' "$1"
}

version_le() {
  python3 -c 'import sys; a, b = ([int(x) for x in v.split(".")] for v in sys.argv[1:3]); sys.exit(0 if a <= b else 1)' "$1" "$2"
}

# Empty output = usable for runtime $2; otherwise the reason it is not.
bundle_problem() {
  local app="$1" runtime="$2" plist exe id plat min
  plist="$app/Info.plist"
  [ -f "$plist" ] || { echo "no Info.plist at $app"; return; }
  id="$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null || true)"
  [ "$id" = "$WDA_RUNNER" ] || { echo "bundle id is '${id:-?}', not $WDA_RUNNER"; return; }
  plat="$(plutil -extract DTPlatformName raw "$plist" 2>/dev/null || true)"
  [ "$plat" = iphonesimulator ] || { echo "built for '${plat:-?}', not iphonesimulator"; return; }
  exe="$app/$(plutil -extract CFBundleExecutable raw "$plist" 2>/dev/null || echo WebDriverAgentRunner-Runner)"
  lipo -archs "$exe" 2>/dev/null | tr ' ' '\n' | grep -qx "$(uname -m)" \
    || { echo "executable has no $(uname -m) slice"; return; }
  min="$(plutil -extract MinimumOSVersion raw "$plist" 2>/dev/null || echo 0)"
  if [ "$runtime" != "?" ] && ! version_le "$min" "$runtime"; then
    echo "needs iOS $min, target runs $runtime"; return
  fi
}

# Runtime version of the simulator whose container holds an installed runner copy.
copy_runtime() {
  local u
  u="$(printf '%s\n' "$1" | sed -nE 's#.*/([0-9A-F-]{36})/data/Containers/.*#\1#p')"
  [ -n "$u" ] && sim_info "$u" | awk '{print $1}'
}

# Prints "<path>\t<origin>" of the first usable runner for $1, or the reasons nothing was.
find_source() {
  local want="$1" runtime copy same=() other=() why
  runtime="$(sim_info "$want" | awk '{print $1}')"; runtime="${runtime:-?}"
  if [ -n "${WDA_SIM_RUNNER:-}" ]; then
    why="$(bundle_problem "$WDA_SIM_RUNNER" "$runtime")"
    if [ -z "$why" ]; then printf '%s\tsupplied via WDA_SIM_RUNNER\n' "$WDA_SIM_RUNNER"; return 0; fi
    echo "WDA_SIM_RUNNER=$WDA_SIM_RUNNER is not usable: $why" >&2
    return 1
  fi
  if [ -d "$BUILT_RUNNER" ]; then
    why="$(bundle_problem "$BUILT_RUNNER" "$runtime")"
    if [ -z "$why" ]; then printf '%s\tbuilt by wda-sim.sh build\n' "$BUILT_RUNNER"; return 0; fi
    echo "build product $BUILT_RUNNER is not usable: $why" >&2
  fi
  shopt -s nullglob
  for copy in "$SEARCH_ROOT"/*/data/Containers/Bundle/Application/*/WebDriverAgentRunner-Runner.app; do
    case "$copy" in */"$want"/*) continue ;; esac
    why="$(bundle_problem "$copy" "$runtime")"
    if [ -n "$why" ]; then echo "skipped $copy: $why" >&2; continue; fi
    if [ "$(copy_runtime "$copy")" = "$runtime" ]; then same+=("$copy"); else other+=("$copy"); fi
  done
  shopt -u nullglob
  if [ "${#same[@]}" -gt 0 ]; then printf '%s\tinstalled on another iOS %s simulator\n' "${same[0]}" "$runtime"; return 0; fi
  if [ "${#other[@]}" -gt 0 ]; then printf '%s\tinstalled on a simulator with a different runtime (unproven on iOS %s)\n' "${other[0]}" "$runtime"; return 0; fi
  return 1
}

obtain_hint() {
  echo "  No usable simulator runner bundle was found. Obtain one, then re-run:" >&2
  echo "    $HERE/wda-sim.sh build" >&2
  echo "  (downloads appium-webdriveragent with npm into $WDA_HOME if needed and builds it for" >&2
  echo "  the iOS Simulator, a few minutes once), or point WDA_SIM_RUNNER=<path to a" >&2
  echo "  WebDriverAgentRunner-Runner.app built for iphonesimulator> at one you have." >&2
}

port_owner_udid() {
  local pid cmd
  pid="$(lsof -ti tcp:"$1" -sTCP:LISTEN 2>/dev/null | head -1)"
  [ -n "$pid" ] || return 0
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  printf '%s\n' "$cmd" | sed -nE 's#.*/Devices/([0-9A-F-]{36})/.*#\1#p' | head -1
}

wda_answers() { curl -s -m 2 "http://localhost:$1/status" >/dev/null 2>&1; }

not_ready() { echo "WDA NOT READY on $UDID: $*" >&2; exit 1; }

# The proof shared by check and ensure: listener on $PORT is $UDID's, and an element
# tree comes back through sim-ui.sh with both pinned.
prove() {
  local owner pid tree n
  owner="$(port_owner_udid "$PORT")"
  pid="$(lsof -ti tcp:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)"
  [ -n "$owner" ] || not_ready "the listener on :$PORT (pid ${pid:-none}) could not be attributed to any simulator"
  [ "$owner" = "$UDID" ] || not_ready ":$PORT is served by simulator $owner - not this one"
  echo "listener :$PORT pid $pid runs out of Devices/$owner - owned by the target"
  tree="$(SIM_UDID="$UDID" WDA_PORT="$PORT" "$HERE/sim-ui.sh" elements --all 2>/dev/null)" \
    || not_ready "sim-ui.sh elements --all failed with SIM_UDID=$UDID WDA_PORT=$PORT"
  n="$(printf '%s' "$tree" | python3 -c 'import sys,json
try:
    v = json.load(sys.stdin); print(len(v) if isinstance(v, list) else 0)
except Exception:
    print(0)')"
  [ "$n" -gt 0 ] || not_ready "sim-ui.sh elements --all returned no elements"
  echo "elements --all: $n elements via SIM_UDID=$UDID WDA_PORT=$PORT"
  echo "WDA READY on $UDID :$PORT"
}

gate() {
  local mode="$1" info runtime state st src origin p other
  is_device_udid "$UDID" && { echo "ERROR: $UDID is a physical iPhone - use wda-device.sh" >&2; exit 2; }
  info="$(sim_info "$UDID")"
  [ -n "$info" ] || not_ready "no simulator with this udid (xcrun simctl list devices)"
  runtime="${info%% *}"; state="${info#* }"
  [ "$state" = Booted ] || not_ready "simulator is $state - boot it first: xcrun simctl boot $UDID"
  echo "target $UDID, iOS $runtime, $state"
  for p in $(seq 8100 8110); do
    [ "$p" = "$PORT" ] && continue
    other="$(port_owner_udid "$p")"
    [ "$other" = "$UDID" ] && not_ready "WDA for this simulator already listens on :$p - use --port $p (not starting a second one)"
  done
  if lsof -ti tcp:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    other="$(port_owner_udid "$PORT")"
    [ "$other" = "$UDID" ] || not_ready ":$PORT is taken by ${other:+simulator }${other:-an unattributed process} - pick a free port"
  fi
  st="$(install_state "$UDID")"
  case "$st" in
    installed) echo "runner $WDA_RUNNER: installed - not reinstalling" ;;
    absent)
      echo "runner $WDA_RUNNER: absent"
      [ "$mode" = ensure ] || not_ready "$WDA_RUNNER is not installed (run: $HERE/wda-sim.sh ensure $UDID --port $PORT)"
      src="$(find_source "$UDID")" || { obtain_hint; not_ready "no usable runner bundle to install"; }
      origin="${src#*$'\t'}"; src="${src%%$'\t'*}"
      echo "installing from $src ($origin)"
      xcrun simctl install "$UDID" "$src" || not_ready "simctl install failed"
      [ "$(install_state "$UDID")" = installed ] || not_ready "simctl install returned but the runner is still not installed"
      ;;
    *) not_ready "could not inspect installation state - $st" ;;
  esac
  if ! wda_answers "$PORT"; then
    [ "$mode" = ensure ] || not_ready "nothing answers on :$PORT"
    echo "starting WDA on :$PORT"
    SIMCTL_CHILD_USE_PORT="$PORT" xcrun simctl launch "$UDID" "$WDA_RUNNER" >/dev/null 2>&1 || true
    for _ in $(seq 1 "$START_TIMEOUT"); do
      wda_answers "$PORT" && break
      sleep 1
    done
    wda_answers "$PORT" || not_ready "runner is installed but WDA did not answer on :$PORT within ${START_TIMEOUT}s (diagnose: SIM_UDID=$UDID WDA_PORT=$PORT $HERE/sim-ui.sh elements)"
  else
    echo "WDA already answering on :$PORT"
  fi
  prove
}

cmd="${1:-}"; shift || true
case "$cmd" in
  status)
    [ -n "${1:-}" ] || die_usage
    st="$(install_state "$1")"
    echo "$st"
    case "$st" in installed) exit 0 ;; absent) exit 1 ;; *) exit 3 ;; esac
    ;;
  source)
    [ -n "${1:-}" ] || die_usage
    if src="$(find_source "$1")"; then printf '%s\n' "${src%%$'\t'*}"; echo "  (${src#*$'\t'})" >&2; exit 0; fi
    obtain_hint; exit 1
    ;;
  build)
    PKG="$WDA_HOME/package"
    for tool in npm xcodebuild; do
      command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found" >&2; exit 1; }
    done
    mkdir -p "$WDA_HOME"
    if [[ ! -f "$PKG/WebDriverAgent.xcodeproj/project.pbxproj" ]]; then
      echo "fetching appium-webdriveragent into $WDA_HOME ..."
      ( cd "$WDA_HOME" && rm -rf package && npm pack appium-webdriveragent >/dev/null 2>&1 \
          && tar xzf appium-webdriveragent-*.tgz && rm -f appium-webdriveragent-*.tgz ) \
        || { echo "ERROR: npm pack appium-webdriveragent failed" >&2; exit 1; }
    fi
    echo "building $PKG for the iOS Simulator into $SIM_DERIVED (log $SIM_DERIVED.log) ..."
    xcodebuild -project "$PKG/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SIM_DERIVED" \
      CODE_SIGNING_ALLOWED=NO build-for-testing > "$SIM_DERIVED.log" 2>&1 \
      || { echo "ERROR: xcodebuild failed - tail of $SIM_DERIVED.log:" >&2; tail -20 "$SIM_DERIVED.log" >&2; exit 1; }
    [ -d "$BUILT_RUNNER" ] || { echo "ERROR: build succeeded but $BUILT_RUNNER is missing" >&2; exit 1; }
    echo "$BUILT_RUNNER"
    ;;
  ensure|check)
    UDID="${1:-}"; shift || true
    [ -n "$UDID" ] || die_usage
    PORT=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --port) PORT="${2:-}"; shift 2 ;;
        *) die_usage ;;
      esac
    done
    [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "ERROR: --port <number> is required - an explicit port, never a default another simulator may own" >&2; exit 2; }
    gate "$cmd"
    ;;
  *) die_usage ;;
esac
