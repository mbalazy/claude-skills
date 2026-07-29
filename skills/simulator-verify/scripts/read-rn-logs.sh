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
#
# "Only new logs": record a timestamp before your action, then pass it with --since:
#   set TS (date '+%Y-%m-%d %H:%M:%S'); curl -s localhost:8081/reload >/dev/null; sleep 6
#   read-rn-logs.sh --since "$TS"
# (or just `read-rn-logs.sh 8` right after the action - the relative window is the timestamp).
#
# Device: auto-uses the booted sim. Override with SIMCTL_DEVICE=<udid>.
set -euo pipefail

DEVICE="${SIMCTL_DEVICE:-booted}"
SECONDS_BACK=20
SINCE=""
CATEGORY='category == "javascript"'
GREP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --all)   CATEGORY=""; shift ;;
    --grep)  GREP="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *)       SECONDS_BACK="$1"; shift ;;
  esac
done

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
  printf '%s\n' "$OUT" | grep -- "$GREP" || true
else
  printf '%s\n' "$OUT"
fi
