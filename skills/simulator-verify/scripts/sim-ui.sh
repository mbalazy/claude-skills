#!/bin/bash
# sim-ui.sh - drive the iOS simulator without mobile-mcp.
# Lifecycle via `xcrun simctl`, UI observation/interaction via WebDriverAgent HTTP API
# (same backend mobile-mcp uses; the WDA runner app must be installed on the sim).
#
# Usage:
#   sim-ui.sh elements [--all]              # a11y element tree as compact JSON (--all: every visible element incl. unlabeled)
#   sim-ui.sh tap X Y                       # coordinates in pt
#   sim-ui.sh doubletap X Y
#   sim-ui.sh longpress X Y [DURATION_MS]
#   sim-ui.sh swipe X1 Y1 X2 Y2 [DURATION_MS]
#   sim-ui.sh type "text"                   # types into the focused element
#   sim-ui.sh button HOME|ENTER|VOLUME_UP|VOLUME_DOWN
#   sim-ui.sh screenshot [OUT.png] [--width N]   # default: resampled to device pt width (1px == 1pt); --width N overrides, 0 = full res
#   sim-ui.sh launch  BUNDLE_ID             # terminate+launch = guaranteed cold start not included; plain launch/foreground
#   sim-ui.sh relaunch BUNDLE_ID            # terminate first -> fresh JS bundle from Metro
#   sim-ui.sh terminate BUNDLE_ID
#   sim-ui.sh openurl URL
#   sim-ui.sh devices                       # booted simulators
#
# Device selection: $SIM_UDID if set, else the first booted simulator.

set -euo pipefail

WDA_PORT="${WDA_PORT:-8100}"
WDA="http://localhost:${WDA_PORT}"
WDA_RUNNER="com.facebook.WebDriverAgentRunner.xctrunner"

udid() {
  if [ -n "${SIM_UDID:-}" ]; then echo "$SIM_UDID"; return; fi
  xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1
}

ensure_wda() {
  if curl -s -m 2 "$WDA/status" >/dev/null 2>&1; then return; fi
  # SIMCTL_CHILD_ is load-bearing: WDA reads USE_PORT from the ENVIRONMENT, and
  # anything after the bundle id is a launch argument simctl never turns into one.
  # Without the prefix this relaunch lands on WDA's default 8100 whatever WDA_PORT says.
  SIMCTL_CHILD_USE_PORT="$WDA_PORT" xcrun simctl launch "$(udid)" "$WDA_RUNNER" >/dev/null
  for _ in $(seq 1 20); do
    sleep 1
    if curl -s -m 2 "$WDA/status" >/dev/null 2>&1; then return; fi
  done
  echo "ERROR: WebDriverAgent did not come up on :$WDA_PORT" >&2
  # Name the likely cause instead of sending the reader off to reinstall a runner
  # that is installed and healthy one port over.
  if [ "$WDA_PORT" != "8100" ] && curl -s -m 2 "http://localhost:8100/status" >/dev/null 2>&1; then
    echo "  WDA IS answering on the default :8100, so the runner is installed and running." >&2
    echo "  It was almost certainly launched without the SIMCTL_CHILD_USE_PORT=$WDA_PORT prefix" >&2
    echo "  (a bare 'simctl launch <udid> $WDA_RUNNER USE_PORT=$WDA_PORT' is silently ignored)." >&2
    echo "  Either relaunch WDA with that prefix, or re-run with WDA_PORT=8100." >&2
  else
    echo "  Nothing is answering on :8100 either - is $WDA_RUNNER installed on $(udid)?" >&2
  fi
  exit 1
}

session() {
  curl -s -X POST "$WDA/session" -H 'Content-Type: application/json' \
    -d '{"capabilities":{"alwaysMatch":{"platformName":"iOS"}}}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['value']['sessionId'])"
}

end_session() { curl -s -X DELETE "$WDA/session/$1" -o /dev/null; }

pointer_actions() {
  local sid; sid=$(session)
  curl -s -X POST "$WDA/session/$sid/actions" -H 'Content-Type: application/json' \
    -d "{\"actions\":[{\"type\":\"pointer\",\"id\":\"f1\",\"parameters\":{\"pointerType\":\"touch\"},\"actions\":$1}]}" -o /dev/null
  end_session "$sid"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  devices)
    xcrun simctl list devices booted | grep -i booted
    ;;

  elements)
    ensure_wda
    ALL=""
    [ "${1:-}" = "--all" ] && ALL=1
    curl -s -m 20 "$WDA/source?format=json" | ALL="$ALL" python3 -c '
import sys, json, os
src = json.load(sys.stdin)["value"]
show_all = bool(os.environ.get("ALL"))
ACCEPTED = {"TextField","Button","Switch","Icon","SearchField","StaticText","Image"}
out = []
seen = set()
def walk(n):
    r = n.get("rect", {})
    visible = n.get("isVisible") == "1" and r.get("width", 0) > 0 and r.get("height", 0) > 0
    labeled = n.get("label") or n.get("name") or n.get("rawIdentifier")
    if n.get("type") in ("TextField", "SearchField"):
        labeled = labeled or n.get("value")
    if visible and (show_all or (n.get("type") in ACCEPTED and labeled)):
        e = {"type": n.get("type")}
        if n.get("label"): e["label"] = n["label"]
        if n.get("name") and n.get("name") != n.get("label"): e["name"] = n["name"]
        if n.get("value"): e["value"] = n["value"]
        e["rect"] = [round(r["x"]), round(r["y"]), round(r["width"]), round(r["height"])]
        key = json.dumps(e)
        if key not in seen:
            seen.add(key)
            out.append(e)
    for c in n.get("children") or []:
        walk(c)
walk(src)
print(json.dumps(out, separators=(",", ":")))
'
    ;;

  tap)
    ensure_wda
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":100},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "tapped $1,$2"
    ;;

  doubletap)
    ensure_wda
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":50},{\"type\":\"pointerUp\",\"button\":0},{\"type\":\"pause\",\"duration\":100},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":50},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "double-tapped $1,$2"
    ;;

  longpress)
    ensure_wda
    dur="${3:-800}"
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pause\",\"duration\":$dur},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "long-pressed $1,$2 (${dur}ms)"
    ;;

  swipe)
    ensure_wda
    dur="${5:-300}"
    pointer_actions "[{\"type\":\"pointerMove\",\"duration\":0,\"x\":$1,\"y\":$2},{\"type\":\"pointerDown\",\"button\":0},{\"type\":\"pointerMove\",\"duration\":$dur,\"x\":$3,\"y\":$4},{\"type\":\"pointerUp\",\"button\":0}]"
    echo "swiped $1,$2 -> $3,$4"
    ;;

  type)
    ensure_wda
    sid=$(session)
    printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps({"value":[sys.stdin.read()]}))' \
      | curl -s -X POST "$WDA/session/$sid/wda/keys" -H 'Content-Type: application/json' -d @- -o /dev/null
    end_session "$sid"
    echo "typed: $1"
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
    sid=$(session)
    curl -s -X POST "$WDA/session/$sid/wda/pressButton" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\"}" -o /dev/null
    end_session "$sid"
    echo "pressed $1"
    ;;

  screenshot)
    out="${1:-/tmp/sim-ui-shot.png}"
    width=""
    if [ "${2:-}" = "--width" ]; then width="${3:-}"; fi
    dev="$(udid)"
    xcrun simctl io "$dev" screenshot "$out" >/dev/null 2>&1
    if [ -z "$width" ]; then
      # default: resample to the device's point width so 1px == 1pt on any simulator
      pxw=$(sips -g pixelWidth "$out" | awk '/pixelWidth/ {print $2}')
      scale=$(xcrun simctl getenv "$dev" SIMULATOR_MAINSCREEN_SCALE 2>/dev/null | cut -d. -f1)
      width=$(( pxw / ${scale:-3} ))
    fi
    if [ "$width" != "0" ]; then
      sips --resampleWidth "$width" "$out" >/dev/null 2>&1
    fi
    echo "$out"
    ;;

  launch)     xcrun simctl launch "$(udid)" "$1" ;;
  relaunch)   xcrun simctl terminate "$(udid)" "$1" 2>/dev/null || true; xcrun simctl launch "$(udid)" "$1" ;;
  terminate)  xcrun simctl terminate "$(udid)" "$1" ;;
  openurl)    xcrun simctl openurl "$(udid)" "$1" ;;

  *)
    grep '^#   sim-ui.sh' "$0" | sed 's/^# *//'
    exit 1
    ;;
esac
