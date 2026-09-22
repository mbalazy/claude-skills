#!/bin/sh
# compactions.sh <session-id> - how many times a session's context was
# auto-compacted, counted from its transcript. The state file only knows the
# compactions the session noticed; the transcript has every one.
# Prints the count. Exit 2 when there is no transcript for the id.
id=$1
[ -n "$id" ] || { echo "usage: compactions.sh <session-id>" >&2; exit 2; }
# Transcripts live under <config dir>/projects. Every Claude config dir next
# to ~/.claude (a second account, a worker dir) is scanned too, and
# CLAUDE_CONFIG_DIR first when it is set.
for root in ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR/projects"} "$HOME"/.claude*/projects; do
  for f in "$root"/*/"$id".jsonl; do
    if [ -f "$f" ]; then
      grep -o '"subtype":"compact_boundary"' "$f" | wc -l | tr -d ' '
      exit 0
    fi
  done
done
echo "compactions.sh: no transcript for $id" >&2
exit 2
