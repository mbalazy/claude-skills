#!/usr/bin/env bash
# reap-diagnose.sh - kill the `devicectl diagnose --devices <udid>` collector that xcodebuild
# spawns around a failing WDA test run on a phone, for as long as that run lives and for a
# few seconds after it ends - however it ends.
#
#   reap-diagnose.sh <udid> <pid>
#
#   <udid>  the phone; only collectors for this udid are touched
#   <pid>   the run to outlive: wda-device.sh passes its xcodebuild screen session
#
#   REAP_INTERVAL  seconds between looks while the run lives (default 3)
#   REAP_TAIL      seconds to keep looking after it is gone (default 10)
#
# Why: an orphaned collector holds the CoreDevice DeviceFS mount, and from then on every
# `lsof` and `ps -o args` on the Mac hangs in uninterruptible wait. wda-device.sh --stop
# reaps it, but a run that ends BY ITSELF never goes through --stop (2026-11-20: the runner
# exited unexpectedly, xcodebuild waited 600 s on its own collector, ended with TEST FAILED
# and left two collectors behind; new terminal tabs could not run anything for ~50 minutes).
# xcodebuild starts the collector only for a run that already failed, and a sysdiagnose of
# the phone is never what a WDA run is for, so it is killed during the run as well.
#
# Started by wda-device.sh in the background next to each run; it exits on its own after
# the tail. Kills are logged to stdout with a timestamp.

set -u
[[ $# -eq 2 ]] || { echo "usage: reap-diagnose.sh <udid> <pid>" >&2; exit 2; }
UDID="$1"; RUN_PID="$2"
INTERVAL="${REAP_INTERVAL:-3}"; TAIL="${REAP_TAIL:-10}"

reap() {
  local pid
  for pid in $(pgrep -f "devicectl diagnose --devices $UDID" 2>/dev/null); do
    kill "$pid" 2>/dev/null \
      && echo "$(date '+%Y-%m-%d %H:%M:%S') killed 'devicectl diagnose --devices $UDID' pid $pid (run pid $RUN_PID)"
  done
}

while kill -0 "$RUN_PID" 2>/dev/null; do
  reap
  sleep "$INTERVAL"
done
end=$(( SECONDS + TAIL ))
while (( SECONDS < end )); do
  reap
  sleep 1
done
reap
exit 0
