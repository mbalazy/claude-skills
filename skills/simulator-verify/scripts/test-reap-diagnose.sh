#!/usr/bin/env bash
# test-reap-diagnose.sh - the orphaned `devicectl diagnose` collector is reaped however a
# phone's WDA run ends. No phone, no xcodebuild, no iproxy: the collectors are `sleep`
# processes renamed to `devicectl diagnose --devices <fake udid>`, and the run is either a
# throwaway screen session or wda-device.sh driving stubbed xcodebuild / iproxy / idevice_id.
# Only processes carrying this test's fake udids are ever killed.
#
# Usage: test-reap-diagnose.sh [-v]
# Exit:  0 all cases pass, 1 a case failed.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=""; [[ "${1:-}" == "-v" ]] && VERBOSE=1
T="$(mktemp -d -t test-reap-diagnose)"
FAKE="0000FFFF-$(printf '%016X' $$)"        # never a real phone: 0000FFFF is no Apple chip id
OTHER="0000FFFE-$(printf '%016X' $$)"
cleanup() {
  pkill -f "devicectl diagnose --devices $FAKE" 2>/dev/null
  pkill -f "devicectl diagnose --devices $OTHER" 2>/dev/null
  pkill -f "reap-diagnose.sh $FAKE" 2>/dev/null
  screen -S "reaptest-$$" -X quit >/dev/null 2>&1
  screen -S "wda-${FAKE:0:8}" -X quit >/dev/null 2>&1
  screen -S "iproxy-${FAKE:0:8}" -X quit >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }
# collector <udid> - a stand-in collector; prints its pid
collector() { ( exec -a "devicectl diagnose --devices $1" sleep 120 ) >/dev/null 2>&1 & echo $!; }
alive() { kill -0 "$1" 2>/dev/null; }
# gone_within <pid> <seconds>
gone_within() { local i; for ((i = 0; i < $2 * 4; i++)); do alive "$1" || return 0; sleep 0.25; done; return 1; }

# --- reap-diagnose.sh on its own ---------------------------------------------------------
screen -dmS "reaptest-$$" sleep 5
RUN="$(screen -ls | grep -oE "[0-9]+\.reaptest-$$" | cut -d. -f1)"
REAP_INTERVAL=1 REAP_TAIL=4 "$HERE/reap-diagnose.sh" "$FAKE" "$RUN" > "$T/reaper.log" 2>&1 &
REAPER=$!
sleep 1
C1="$(collector "$FAKE")"; C2="$(collector "$OTHER")"
gone_within "$C1" 3 && ok "a collector for the phone dies while the run lives" || bad "collector $C1 survived during the run"
alive "$C2" && ok "a collector for another phone is left alone" || bad "collector $C2 for $OTHER was killed"
kill "$C2" 2>/dev/null
while alive "$RUN"; do sleep 0.25; done
sleep 1
C3="$(collector "$FAKE")"
gone_within "$C3" 3 && ok "a collector spawned after the run ended dies in the tail" || bad "collector $C3 survived the tail"
gone_within "$REAPER" 8 && ok "the reaper exits after its tail" || bad "the reaper $REAPER is still running after its tail"
C4="$(collector "$FAKE")"; sleep 1.5
alive "$C4" && ok "nothing reaps once the reaper is gone (it does not linger)" || bad "collector $C4 died with no reaper running"
kill "$C4" 2>/dev/null
grep -q "killed 'devicectl diagnose --devices $FAKE' pid $C1" "$T/reaper.log" && ok "kills are logged" || bad "no log line for $C1: $(cat "$T/reaper.log")"
[[ -n "$VERBOSE" ]] && sed 's/^/      | /' "$T/reaper.log"

# --- wda-device.sh: a run that ends by itself -------------------------------------------
# The 2026-11-20 path: the test run fails on its own, xcodebuild leaves a collector behind
# and exits; nobody calls --stop.
mkdir -p "$T/bin" "$T/home/package/WebDriverAgent.xcodeproj" "$T/home/package/WebDriverAgentRunner"
VERSION="$(grep -m1 '^WDA_VERSION=' "$HERE/wda-device.sh" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
printf '{\n  "version": "%s",\n}\n' "$VERSION" > "$T/home/package/package.json"
touch "$T/home/package/WebDriverAgent.xcodeproj/project.pbxproj"
echo "    [FBConfiguration.sharedInstance configureDefaultKeyboardPreferences];" > "$T/home/package/WebDriverAgentRunner/UITestingUITests.m"
cat > "$T/bin/idevice_id" <<EOF
#!/bin/bash
echo "$FAKE"
EOF
cat > "$T/bin/iproxy" <<'EOF'
#!/bin/bash
exec sleep 60
EOF
cat > "$T/bin/xcodebuild" <<EOF
#!/bin/bash
# a run that fails by itself and leaves its collector behind; the real collector outlives the
# screen's hangup (2026-11-20: found with parent 1), so this one ignores SIGHUP too
( trap '' HUP; exec -a "devicectl diagnose --devices $FAKE" sleep 120 ) >/dev/null 2>&1 &
echo "\$!" > "$T/collector.pid"
sleep 2
echo "** TEST FAILED **"
exit 65
EOF
chmod +x "$T/bin/"*
PORT=""
for p in $(seq 8299 -1 8280); do lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || { PORT="$p"; break; }; done
OUT="$(PATH="$T/bin:$PATH" WDA_DEVICE_HOME="$T/home" "$HERE/wda-device.sh" "$FAKE" --team TESTTEAM --port "$PORT" --timeout 20 2>&1)"
RC=$?
[[ -n "$VERBOSE" ]] && printf '%s\n' "$OUT" | sed 's/^/      | /'
[[ "$RC" == 1 ]] && grep -q "the xcodebuild test run ended" <<< "$OUT" \
  && ok "wda-device.sh reports the run that ended by itself" || bad "wda-device.sh exit $RC: $OUT"
COLL="$(cat "$T/collector.pid" 2>/dev/null)"
if [[ -z "$COLL" ]]; then
  bad "the stub xcodebuild never ran"
else
  gone_within "$COLL" 12 && ok "its leftover collector is reaped without --stop" || bad "collector $COLL is still alive"
fi
grep -q "killed 'devicectl diagnose --devices $FAKE'" "$T/home/wda-$FAKE-reaper.log" 2>/dev/null \
  && ok "the reaper logged to <home>/wda-<udid>-reaper.log" || bad "no kill in $T/home/wda-$FAKE-reaper.log"
for ((i = 0; i < 60; i++)); do pgrep -f "reap-diagnose.sh $FAKE" >/dev/null || break; sleep 0.25; done
pgrep -f "reap-diagnose.sh $FAKE" >/dev/null && bad "the run's reaper is still running" || ok "the run's reaper has exited"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
