#!/usr/bin/env bash
# Existence check before a timeline seed.
#   exit 0  the project has no timeline entry yet - go on
#   exit 1  it has one - prints "timeline exists: N entries, latest state <date|none>", stop
#   exit 2  cannot tell (no `pm timeline`, project not found) - prints why, stop
# Usage: check.sh [project-slug]   (no slug: pm detects the project from the cwd)
set -u

slug="${1:-}"

if ! pm timeline --help >/dev/null 2>&1; then
  echo "cannot check: the pm on PATH has no 'pm timeline' - install a pm build that has the project timeline" >&2
  exit 2
fi

args=(timeline --json)
[ -n "$slug" ] && args=(timeline "$slug" --json)
if ! out=$(pm "${args[@]}" 2>&1); then
  echo "cannot check: $(printf '%s\n' "$out" | tail -1)" >&2
  exit 2
fi

printf '%s' "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
total = r.get("total", 0)
if total == 0:
    print("no timeline yet")
    sys.exit(0)
state = r.get("state") or {}
date = state.get("ts", "")[:10] or "none"
print(f"timeline exists: {total} entries, latest state {date}")
sys.exit(1)
'
