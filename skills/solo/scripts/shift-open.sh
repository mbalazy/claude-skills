#!/bin/bash
# Open a solo run: write the per-session marker the guard hook reads.
# usage: shift-open.sh --project <slug> --shift <session-id> --state <state-file> [--push] [--pr] [--max-hours H] [--base <branch>] [--budget MIN]
# --budget: the per-task budget tick.sh enforces (default 120; a queue of one gets the shift's ceiling minus the close, see SKILL.md)
# The shift id MUST be this session's id (`pm session-id`): the guard matches
# the marker against the session_id Claude Code passes to the hook.
set -euo pipefail
DIR="$HOME/.claude/solo"
PROJECT=""; SHIFT=""; STATE=""; PUSH=0; PR=0; MAX_HOURS=4; BASE=""; BUDGET=120
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --shift) SHIFT="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --pr) PR=1; PUSH=1; shift ;;
    --max-hours) MAX_HOURS="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$SHIFT" ] && [ -n "$STATE" ] || { echo "need --project, --shift, --state" >&2; exit 1; }
mkdir -p "$DIR"
MARKER="$DIR/$SHIFT.active"
if [ -f "$MARKER" ]; then
  echo "WARNING: a marker for this session already exists - overwriting:" >&2
  cat "$MARKER" >&2
fi
cat > "$MARKER" <<EOF
# solo guard marker (per session) - remove with shift-close.sh $SHIFT
SHIFT_ID=$SHIFT
PROJECT=$PROJECT
STATE_FILE=$STATE
PUSH=$PUSH
PR=$PR
MAX_HOURS=$MAX_HOURS
BASE=$BASE
BUDGET=$BUDGET
STARTED=$(date +%s)
EOF
echo "solo run open: $SHIFT project=$PROJECT push=$PUSH pr=$PR max_hours=$MAX_HOURS budget=${BUDGET}min marker=$MARKER"
OTHERS=$( { ls "$DIR"/*.active 2>/dev/null || true; } | { grep -v "$SHIFT.active" || true; } | wc -l | tr -d ' ')
[ "$OTHERS" = "0" ] || echo "note: $OTHERS other marker(s) in $DIR (other sessions' runs; they do not affect this one)"
