#!/bin/bash
# usage: mark.sh <text-file> --report <verifier-report.md>
# Writes ~/.claude/claim-check/<hash>.ok for the text file, only when the verifier
# report exists and holds no REFUTED verdict. The hook claim-check-gate.py reads it.
set -u
file="${1:-}"; shift || true
report=""
while [ $# -gt 0 ]; do case "$1" in --report) report="$2"; shift 2;; *) shift;; esac; done
[ -f "$file" ] || { echo "mark.sh: text file not found: $file" >&2; exit 1; }
[ -n "$report" ] && [ -f "$report" ] || { echo "mark.sh: --report <verifier-report.md> is required and must exist" >&2; exit 1; }
if grep -Eq '\|[[:space:]]*REFUTED[[:space:]]*\|' "$report"; then
  echo "mark.sh: the report still holds a REFUTED verdict - fix the text first:" >&2
  grep -En '\|[[:space:]]*REFUTED[[:space:]]*\|' "$report" >&2; exit 1
fi
hash=$(python3 ~/.claude/hooks/claim-check-gate.py --hash "$file") || exit 1
dir=~/.claude/claim-check; mkdir -p "$dir"
python3 - "$dir/$hash.ok" "$file" "$report" <<'PY'
import json, os, sys, time
out, f, r = sys.argv[1:4]
json.dump({"file": os.path.abspath(f), "report": os.path.abspath(r), "cwd": os.getcwd(),
           "marked_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, open(out, "w"), indent=1)
PY
echo "marked $hash -> $dir/$hash.ok (valid 6h; any edit to the text invalidates it)"
