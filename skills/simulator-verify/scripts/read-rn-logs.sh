#!/usr/bin/env bash
# Read React Native JS console logs from the booted iOS simulator - no Metro copy-paste.
#
# RN routes console.* through RCTLog -> Apple os_log:
#   subsystem == "com.facebook.react.log"
#   category  == "javascript"  (your console.log/warn/error)   | "native" (RN bridge)
# JS logs land at INFO level, so `log show` needs --info --debug or it returns nothing.
#
# Usage:
#   read-rn-logs.sh [seconds]                 # JS logs from the last N seconds (default 20)
#   read-rn-logs.sh --since "YYYY-MM-DD HH:MM:SS"   # JS logs since an exact timestamp
#   read-rn-logs.sh --grep PATTERN [seconds]  # only lines matching PATTERN
#   read-rn-logs.sh --all [seconds]           # include RN native-bridge logs too
#   read-rn-logs.sh --udid UDID [...]         # pin the simulator explicitly
#
# "Only new logs": record a timestamp before your action, then pass it with --since:
#   set TS (date '+%Y-%m-%d %H:%M:%S'); curl -s localhost:8081/reload >/dev/null; sleep 6
#   read-rn-logs.sh --since "$TS"
# (or just `read-rn-logs.sh 8` right after the action - the relative window is the timestamp).
#
# Device: --udid, else $SIMCTL_DEVICE, else $SIM_UDID (the variable sim-ui.sh takes),
# else the only booted sim. With several booted and none of those set it REFUSES
# instead of picking one - reading the wrong simulator returns an empty result that
# looks exactly like "the instrumentation never fired" (journal sim-rig 20260805-9155,
# 20260809-4464, 20260809-c2f3).
set -euo pipefail

DEVICE="${SIMCTL_DEVICE:-${SIM_UDID:-}}"
SECONDS_BACK=20
SINCE=""
CATEGORY='category == "javascript"'
GREP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --all)   CATEGORY=""; shift ;;
    --grep)  GREP="$2"; shift 2 ;;
    --udid)  DEVICE="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *)       SECONDS_BACK="$1"; shift ;;
  esac
done

if [[ -z "$DEVICE" ]]; then
  BOOTED=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' || true)
  if [[ $(printf '%s\n' "$BOOTED" | grep -c . || true) -gt 1 ]]; then
    echo "ERROR: several simulators are booted and no device was given - refusing to guess." >&2
    xcrun simctl list devices booted | grep -i booted | sed 's/^/  /' >&2
    echo "  Pin one: --udid <udid>, or export SIM_UDID / SIMCTL_DEVICE." >&2
    exit 2
  fi
  DEVICE="booted"
fi

# Name the device in any message, so an empty result is never anonymous.
DEVICE_LABEL="$DEVICE"
if [[ "$DEVICE" == "booted" ]]; then
  DEVICE_LABEL="$(xcrun simctl list devices booted | grep -i booted | head -1 | sed 's/^ *//')"
else
  DEVICE_LABEL="$(xcrun simctl list devices | grep -i "$DEVICE" | head -1 | sed 's/^ *//')"
  [[ -n "$DEVICE_LABEL" ]] || DEVICE_LABEL="$DEVICE"
fi

PRED='subsystem == "com.facebook.react.log"'
[[ -n "$CATEGORY" ]] && PRED="$PRED AND $CATEGORY"

if [[ -n "$SINCE" ]]; then
  START="$SINCE"
else
  START=$(date -v-"${SECONDS_BACK}"S '+%Y-%m-%d %H:%M:%S')
fi

OUT=$(xcrun simctl spawn "$DEVICE" log show --start "$START" --info --debug \
  --predicate "$PRED" --style compact 2>/dev/null \
  | grep -vE '^Timestamp|^Filtering|getpwuid' || true)

if [[ -n "$GREP" ]]; then
  RESULT=$(printf '%s\n' "$OUT" | grep -- "$GREP" || true)
else
  RESULT="$OUT"
fi

# An empty result is the dangerous one: it reads as "the code never ran". Say which
# device and which window produced it, so the first suspect is the query, not the app.
if [[ -z "${RESULT//[$'\n\t ']/}" ]]; then
  echo "no matching lines" >&2
  echo "  device: $DEVICE_LABEL" >&2
  echo "  since:  $START${GREP:+   pattern: $GREP}" >&2
  exit 1
fi

printf '%s\n' "$RESULT"
