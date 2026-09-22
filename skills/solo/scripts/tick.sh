#!/bin/bash
# Print the time spent on the current task and on the whole run; exit 1 when
# either budget is over. Call it at the top of every step - the model has no
# clock, this is it.
# usage: tick.sh <state-file> [task-budget-min]   (default: BUDGET= from the run's marker, else 120)
# The run's marker is the one naming this state file (resume-safe), else the one
# named by the state file's <date>-<session-id>.md.
set -euo pipefail
STATE="$1"; BUDGET="${2:-}"
# The marker: the newest one whose STATE_FILE is this state file (a resumed
# shift runs under a NEW session id, so the file name's id may be the old one).
MARKER=$(grep -l "^STATE_FILE=$STATE\$" "$HOME"/.claude/solo/*.active 2>/dev/null | xargs -I{} stat -f '%m {}' {} 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [ -z "$MARKER" ]; then
  SHIFT=$(basename "$STATE" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
  MARKER="$HOME/.claude/solo/$SHIFT.active"
fi
if [ -z "$BUDGET" ]; then
  [ -f "$MARKER" ] && BUDGET=$(grep "^BUDGET=" "$MARKER" | cut -d= -f2)
  BUDGET="${BUDGET:-120}"
fi
NOW=$(date +%s)
OVER=0
LINE=$(grep -E '^- .* task-start [^ ]+ epoch=[0-9]+' "$STATE" | tail -1 || true)
if [ -n "$LINE" ]; then
  TASK=$(echo "$LINE" | sed -E 's/.* task-start ([^ ]+) epoch=.*/\1/')
  EPOCH=$(echo "$LINE" | sed -E 's/.*epoch=([0-9]+).*/\1/')
  MIN=$(( (NOW - EPOCH) / 60 ))
  if [ "$MIN" -ge "$BUDGET" ]; then
    echo "TASK $TASK: ${MIN} min - OVER BUDGET (${BUDGET}); commit what is green, park it, move on"; OVER=1
  else
    echo "task $TASK: ${MIN} min of ${BUDGET}"
  fi
else
  echo "no task-start line in $STATE (run note.sh <state> task-start <id> first)"
fi
if [ -f "$MARKER" ]; then
  STARTED=$(grep '^STARTED=' "$MARKER" | cut -d= -f2)
  MAXH=$(grep '^MAX_HOURS=' "$MARKER" | cut -d= -f2)
  SMIN=$(( (NOW - STARTED) / 60 ))
  if [ "$SMIN" -ge $(( MAXH * 60 )) ]; then
    echo "RUN: ${SMIN} min - OVER --max-hours ${MAXH}; finish this step, write state, report"; OVER=1
  else
    echo "run: ${SMIN} min of $(( MAXH * 60 ))"
  fi
else
  echo "no marker for $STATE (guard off?)"
fi
exit $OVER
