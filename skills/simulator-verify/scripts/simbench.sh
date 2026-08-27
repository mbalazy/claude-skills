#!/bin/bash
# simbench.sh - measure where simulator-driving time actually goes.
#
# Reference numbers, iPhone 17 Pro Max simulator, RN 0.83 app, 2026-08-27:
#   tap 0.68s | elements 1.07s | screenshot 0.27s | rig-check 8.6s | rig-check --reload 5.7s
#   an 11-step reach run one-command-per-call: 62s wall = 26s tool + 36s round-trip gaps
#   the same reach as one `sim-ui.sh do` call:  25s wall, 1 round trip (mean of 3)
# Re-measure before claiming an optimization; the gaps are the number that moves.
#
# Two costs are being separated:
#   TOOL time  - the seconds a command spends talking to WDA / simctl.
#   GAP  time  - the seconds between one command finishing and the next starting,
#                i.e. the model round trip. This is invisible to any in-script timer,
#                so it is recovered from the wall-clock gaps in the log.
#
# Usage:
#   simbench.sh run <label> -- <cmd...>   run cmd, log start/end/duration
#   simbench.sh mark <label>              log a bare timestamp
#   simbench.sh report [logfile]          per-label durations + gaps between calls
#   simbench.sh reset                     truncate the log
#
# Log format (one line per event): <epoch_ms> <event> <label> [<dur_ms>]
set -uo pipefail
LOG="${BENCH_LOG:-/tmp/simbench.log}"
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

case "${1:-}" in
  reset) : > "$LOG"; echo "reset $LOG" ;;
  mark)  echo "$(now_ms) MARK ${2:-unlabeled}" >> "$LOG" ;;
  run)
    label="${2:?label required}"; shift 2
    [ "${1:-}" = "--" ] && shift
    s=$(now_ms)
    echo "$s START $label" >> "$LOG"
    "$@"; rc=$?
    e=$(now_ms)
    echo "$e END $label $((e - s))" >> "$LOG"
    exit $rc
    ;;
  report)
    python3 - "${2:-$LOG}" <<'PY'
import sys, collections
path = sys.argv[1]
ev = []
for line in open(path):
    p = line.split()
    if len(p) < 3: continue
    ev.append((int(p[0]), p[1], p[2], int(p[3]) if len(p) > 3 else None))
if not ev:
    print("empty log"); sys.exit()
tool = collections.OrderedDict()
for t, kind, label, dur in ev:
    if kind == "END":
        tool.setdefault(label, []).append(dur)
print("TOOL time per label (ms)")
print(f"  {'label':<34} {'n':>3} {'mean':>7} {'min':>7} {'max':>7}")
tot = 0
for label, ds in tool.items():
    tot += sum(ds)
    print(f"  {label:<34} {len(ds):>3} {sum(ds)//len(ds):>7} {min(ds):>7} {max(ds):>7}")
print(f"  {'TOTAL tool time':<34} {'':>3} {tot:>7}")
gaps = []
prev_end = None
for t, kind, label, dur in ev:
    if kind == "START" and prev_end is not None:
        gaps.append((t - prev_end, label))
    if kind in ("END", "MARK"):
        prev_end = t
print()
print("GAP time between calls (ms) - model round trip, not tool")
if gaps:
    for g, label in gaps:
        print(f"  ->{label:<32} {g:>7}")
    gs = [g for g, _ in gaps]
    print(f"  {'n gaps':<34} {len(gs):>7}")
    print(f"  {'mean gap':<34} {sum(gs)//len(gs):>7}")
    print(f"  {'TOTAL gap time':<34} {sum(gs):>7}")
    span = ev[-1][0] - ev[0][0]
    print()
    print(f"  wall span {span} ms;  tool {tot} ms ({100*tot//max(span,1)}%);  gap {sum(gs)} ms ({100*sum(gs)//max(span,1)}%)")
else:
    print("  (single call - no gaps)")
PY
    ;;
  *) sed -n '2,20p' "$0" ;;
esac
