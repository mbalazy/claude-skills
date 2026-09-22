#!/bin/bash
# Close a solo run: refuse while a task is still open, record the compaction
# count, then remove the run's per-session marker and print how long it ran.
#
# usage: shift-close.sh <session-id>          close that run
#        shift-close.sh                       close the only marker (errors when several)
#        shift-close.sh --stale               remove every marker older than its MAX_HOURS + 2h
#        shift-close.sh <session-id> --force  close even with a task still open
#
# A task is open when the state file's Log has `task-start <id>` with no later
# `task-end <id>`: 6 of 58 tasks ended that way, and the retro then has no
# minutes and no outcome for them. --force closes anyway and writes the
# missing task-end line itself (parked, reason: shift-close --force).
#
# SOLO_DIR overrides the marker directory (tests).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${SOLO_DIR:-$HOME/.claude/solo}"
NOW=$(date +%s)
FORCE=0

# open_tasks <state-file> - print the ids started but never ended, in order.
open_tasks() {
  local state="$1"
  [ -f "$state" ] || return 0
  awk '
    /^- .* task-start [^ ]+/ { for (i=1;i<=NF;i++) if ($i=="task-start") { started[$(i+1)]=1; order[++n]=$(i+1) } }
    /^- .* task-end [^ ]+/   { for (i=1;i<=NF;i++) if ($i=="task-end")   { delete started[$(i+1)] } }
    END { for (i=1;i<=n;i++) if (order[i] in started) { print order[i]; delete started[order[i]] } }
  ' "$state"
}

close_one() {
  local m="$1"
  local started shift_id min state open n
  started=$(grep '^STARTED=' "$m" | cut -d= -f2 || echo "$NOW")
  shift_id=$(grep '^SHIFT_ID=' "$m" | cut -d= -f2 || echo "?")
  state=$(grep '^STATE_FILE=' "$m" | cut -d= -f2- || echo "")

  if [ -n "$state" ] && [ -f "$state" ]; then
    open=$(open_tasks "$state")
    if [ -n "$open" ]; then
      if [ "$FORCE" = "1" ]; then
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          "$SCRIPT_DIR/note.sh" "$state" task-end "$id" parked "shift-close --force" >/dev/null
          echo "task-end written for open task: $id (parked, shift-close --force)"
        done <<< "$open"
      else
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          echo "open task: $id" >&2
        done <<< "$open"
        echo "shift-close: $shift_id NOT closed, marker kept - write task-end for each id above (scripts/note.sh \"$state\" task-end <id> <done|parked> <one line>) or re-run with --force" >&2
        return 1
      fi
    fi
    # Compactions: the transcript's count, into the state file, also when 0.
    if out=$("$SCRIPT_DIR/compactions.sh" "$shift_id" 2>&1); then
      "$SCRIPT_DIR/state.py" "$state" append "Compactions noticed" "compactions.sh: $out (transcript)" || true
    else
      "$SCRIPT_DIR/state.py" "$state" append "Compactions noticed" "$out" || true
    fi
  elif [ -n "$state" ]; then
    echo "note: STATE_FILE=$state from the marker does not exist - no open-task check, no compaction count" >&2
  fi

  min=$(( (NOW - ${started:-$NOW}) / 60 ))
  rm -f "$m"
  echo "solo run closed: $shift_id after ${min} min; guard is off for that session"
}

ARGS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS+"${ARGS[@]}"}

if [ "${1:-}" = "--stale" ]; then
  n=0
  for m in "$DIR"/*.active; do
    [ -f "$m" ] || continue
    started=$(grep '^STARTED=' "$m" | cut -d= -f2 || echo 0)
    maxh=$(grep '^MAX_HOURS=' "$m" | cut -d= -f2 || echo 4)
    # A stale marker belongs to a session that is gone, so it is never held
    # back by an open task nobody can close any more: --stale closes as
    # --force does (the missing task-end lines get written, parked).
    if [ $(( NOW - started )) -gt $(( (maxh + 2) * 3600 )) ]; then
      FORCE=1; close_one "$m"; n=$((n+1))
    fi
  done
  echo "stale markers removed: $n"; exit 0
fi
if [ -n "${1:-}" ]; then
  M="$DIR/$1.active"
  if [ -f "$M" ]; then close_one "$M"; exit $?; fi
  echo "no marker for $1"; exit 0
fi
set -- "$DIR"/*.active
if [ ! -f "${1:-}" ]; then echo "no open solo run (no marker in $DIR)"; exit 0; fi
if [ $# -gt 1 ]; then echo "several markers - name the session id:" >&2; ls "$DIR"/*.active >&2; exit 1; fi
close_one "$1"
