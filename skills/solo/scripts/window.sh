#!/bin/bash
# Print the auto-compact window this session actually runs with, and where it
# comes from - the model cannot see its own launch flags, this can.
# usage: window.sh            -> "400k (flag --autocompact)" | "600k (settings <path>)"
# Walks up from this shell to the `claude` process and reads `--autocompact <v>`;
# without the flag, reads autoCompactWindow from the config dir's settings.json.
p=$$
flag=""
# A `claude --bg` session: the flags are in $CLAUDE_JOB_DIR/state.json
# `respawnFlags`, not on the supervisor's `claude bg-spare` process.
if [ -n "${CLAUDE_JOB_DIR:-}" ] && [ -f "$CLAUDE_JOB_DIR/state.json" ]; then
  flag=$(python3 -c 'import json,sys
f=json.load(open(sys.argv[1])).get("respawnFlags") or []
for i,a in enumerate(f):
    if a.startswith("--autocompact="): print(a.split("=",1)[1]); break
    if a=="--autocompact" and i+1 < len(f): print(f[i+1]); break' "$CLAUDE_JOB_DIR/state.json" 2>/dev/null)
  [ -n "$flag" ] && found=1
fi
[ -z "$flag" ] && for _ in 1 2 3 4 5 6 7 8; do
  args=$(ps -o args= -p "$p" 2>/dev/null) || break
  exe="${args%% *}"; rest="${args#* }"
  second="${rest%% *}"
  case "$exe" in
    claude|*/claude) found=1 ;;
    *node*) case "$second" in *claude*) found=1 ;; esac ;;
  esac
  if [ -n "${found:-}" ]; then
    flag=$(printf '%s' "$args" | sed -nE 's/.*--autocompact[ =]([^ ]+).*/\1/p')
    break
  fi
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  [ -n "$p" ] && [ "$p" != "1" ] || break
done
if [ -n "$flag" ]; then
  echo "$flag (flag --autocompact)"; exit 0
fi
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$cfg" ]; then
  w=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); w=d.get("autoCompactWindow"); print(f"{w//1000}k" if isinstance(w,int) else "auto")' "$cfg" 2>/dev/null)
  echo "${w:-auto} (settings $cfg${found:+; no --autocompact flag on the claude process})"
else
  echo "auto (no settings.json at $cfg)"
fi
