#!/bin/bash
# Preflight for a solo run: is THIS claude process launched so that nothing
# will prompt a human tonight? Prints the auto-compact window and the
# permission situation; exit 1 = relaunch before opening the shift.
# usage: launch-check.sh [<repo-root>]   (default: cwd)
# Checks:
#  - the repo's shared .claude/settings.json `ask` rules: they prompt in EVERY
#    mode, bypass included, so a run in such a repo must be launched with
#    `--setting-sources user,local` (project settings skipped) and the shared
#    DENY list mirrored in .claude/settings.local.json so nothing gets weaker.
#  - `--dangerously-skip-permissions` on the process (auto mode falls back to
#    prompts after three blocks in a row).
REPO="${1:-$PWD}"
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
echo "window: $("$HERE/window.sh")"

# the claude process' args. A `claude --bg` session runs under the supervisor,
# whose process argv is `claude bg-spare --bg-spare <sock>` - the launch flags
# live in $CLAUDE_JOB_DIR/state.json `respawnFlags` instead (the cockpit's
# solo launcher, pm-cli-141). Otherwise the same process walk as window.sh.
p=$$; args=""
if [ -n "${CLAUDE_JOB_DIR:-}" ] && [ -f "$CLAUDE_JOB_DIR/state.json" ]; then
  args=$(python3 -c 'import json,sys
f=json.load(open(sys.argv[1])).get("respawnFlags") or []
print("claude " + " ".join(f) if isinstance(f, list) else "claude " + str(f))' "$CLAUDE_JOB_DIR/state.json" 2>/dev/null)
  [ -n "$args" ] && echo "process: background session (flags from $CLAUDE_JOB_DIR/state.json)"
fi
[ -z "$args" ] && for _ in 1 2 3 4 5 6 7 8; do
  a=$(ps -o args= -p "$p" 2>/dev/null) || break
  exe="${a%% *}"; rest="${a#* }"; second="${rest%% *}"
  case "$exe" in claude|*/claude) args="$a" ;; *node*) case "$second" in *claude*) args="$a" ;; esac ;; esac
  [ -n "$args" ] && break
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$p" ] && [ "$p" != "1" ] || break
done
[ -n "$args" ] || { echo "process: claude not found in the process chain (cannot check flags)"; args=""; }

case "$args" in
  *--dangerously-skip-permissions*) echo "mode: bypass (ok)" ;;
  *) echo "mode: NOT bypass - auto/default will prompt after a few blocks; relaunch with --dangerously-skip-permissions"; rc=1 ;;
esac

SRC=$(printf '%s' "$args" | sed -nE 's/.*--setting-sources[ =]([^ ]+).*/\1/p')
SHARED="$REPO/.claude/settings.json"; LOCAL="$REPO/.claude/settings.local.json"
ASK=$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("permissions",{}).get("ask",[])))
except Exception: print(0)' "$SHARED" 2>/dev/null)
if [ "${ASK:-0}" -gt 0 ]; then
  case ",$SRC," in
    *,project,*|",,")
      echo "permissions: $SHARED has $ASK ask rule(s) - they prompt in bypass too; this process loads project settings (--setting-sources=${SRC:-default})."
      echo "  relaunch: claude --dangerously-skip-permissions --autocompact 400k --setting-sources user,local"
      rc=1 ;;
    *)
      echo "permissions: project settings skipped (--setting-sources=$SRC); $ASK ask rule(s) in $SHARED will not prompt"
      python3 - "$SHARED" "$LOCAL" <<'PY' || rc=1
import json, sys
try: shared = json.load(open(sys.argv[1])).get("permissions", {}).get("deny", [])
except Exception: shared = []
try: local = json.load(open(sys.argv[2])).get("permissions", {}).get("deny", [])
except Exception: local = None
if local is None:
    print(f"  WARNING: no {sys.argv[2]} - the shared deny list is NOT in effect; mirror it there before the shift"); sys.exit(1)
missing = [d for d in shared if d not in local]
if missing:
    print(f"  WARNING: {len(missing)} shared deny rule(s) missing from settings.local.json: {missing[:5]} - regenerate the mirror"); sys.exit(1)
print(f"  deny mirror ok ({len(shared)} rules in settings.local.json)")
PY
      ;;
  esac
else
  echo "permissions: no ask rules in $SHARED (project settings may stay loaded)"
fi
exit $rc
