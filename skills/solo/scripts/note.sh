#!/bin/bash
# Append one timestamped line to the state file's Log (the last section).
# The Log is the ONLY part of the state file this script touches; the sections
# above it are edited with state.py.
#
# usage: note.sh <state-file> <text...>
#        note.sh <state-file> task-start <task-id>
#        note.sh <state-file> task-end <task-id> <done|parked> <detail...>
#
# task-start / task-end and their arguments are SEPARATE shell arguments:
#   note.sh "$ST" task-start vega-1            <- right
#   note.sh "$ST" "task-start vega-1"          <- wrong, refused below
# Quoted as one argument, task-start looks like ordinary text and the epoch
# stamp tick.sh reads is never written (solo journal 20260911-1cca).
set -euo pipefail
STATE="$1"; shift
[ -f "$STATE" ] || { echo "no state file: $STATE" >&2; exit 1; }
case "${1:-}" in
  "task-start "*|"task-end "*)
    echo "note.sh: '$1' is ONE argument - split it:" >&2
    echo "  note.sh \"\$ST\" ${1%% *} ${1#* }" >&2
    echo "  (as one argument the epoch stamp is not written and tick.sh has no clock)" >&2
    exit 1 ;;
esac
TS=$(date '+%Y-%m-%d %H:%M')
if [ "${1:-}" = "task-start" ]; then
  [ -n "${2:-}" ] || { echo "note.sh: task-start needs a task id" >&2; exit 1; }
  echo "- $TS task-start $2 epoch=$(date +%s)" >> "$STATE"
else
  echo "- $TS $*" >> "$STATE"
fi
tail -1 "$STATE"
