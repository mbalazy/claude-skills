#!/bin/bash
# test-wda-diagnostics.sh - the WDA failure branches of sim-ui.sh and the wda-sim.sh gate,
# run against stubbed xcrun/curl/lsof/ps/pgrep/open so that no simulator is touched and a
# failure that would need breaking a live runner is still exercised. Prints one line per
# case and exits non-zero when any expectation fails.
#
#   test-wda-diagnostics.sh            # all cases
#   test-wda-diagnostics.sh -v         # also print each case's full output
#
# The live halves (a fresh simulator without the runner, the healthy path, repeated
# ensure) cannot be faked meaningfully and are run by hand on a disposable simulator.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=""; [ "${1:-}" = "-v" ] && VERBOSE=1
FX="$(mktemp -d -t wda-fixture)"
trap 'rm -rf "$FX"' EXIT

TARGET="11111111-1111-1111-1111-111111111111"
OTHER="22222222-2222-2222-2222-222222222222"
BIN="$FX/bin"; mkdir -p "$BIN"

cat > "$BIN/xcrun" <<'EOF'
#!/bin/bash
[ "$1" = devicectl ] && exit 0
shift
case "$1 ${2:-} ${3:-}" in
  "list devices booted") for u in $FX_BOOTED; do echo "    iPhone 17 Pro ($u) (Booted)"; done ;;
  "list devices -j")
    printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-2":['
    sep=""; for u in $FX_BOOTED; do printf '%s{"udid":"%s","state":"Booted"}' "$sep" "$u"; sep=","; done
    printf ']}}\n' ;;
  "list devices "*) for u in $FX_BOOTED; do echo "    iPhone 17 Pro ($u) (Booted)"; done ;;
  get_app_container*)
    case "$FX_INSTALL" in
      installed) echo "/fx/Devices/$2/data/Containers/Bundle/Application/X/WebDriverAgentRunner-Runner.app" ;;
      absent) echo "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):" >&2
              echo "No such file or directory" >&2; exit 2 ;;
      *) echo "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):" >&2
         echo "Unable to lookup in current state: Shutdown" >&2; exit 149 ;;
    esac ;;
  launch*) [ -n "${FX_LAUNCH_OUT:-}" ] && echo "$FX_LAUNCH_OUT" >&2; exit "${FX_LAUNCH_RC:-0}" ;;
  install*) exit 0 ;;
  getenv*) exit 1 ;;
  *) echo "xcrun stub: unhandled: simctl $*" >&2; exit 99 ;;
esac
EOF

cat > "$BIN/lsof" <<'EOF'
#!/bin/bash
port="$(printf '%s\n' "$*" | grep -oE 'tcp:[0-9]+' | cut -d: -f2)"
for l in $FX_LISTEN; do [ "${l%%:*}" = "$port" ] && { echo $((50000 + port)); exit 0; }; done
exit 1
EOF

cat > "$BIN/ps" <<'EOF'
#!/bin/bash
pid="${@: -1}"; port=$((pid - 50000))
for l in $FX_LISTEN; do
  [ "${l%%:*}" = "$port" ] || continue
  owner="${l#*:}"
  if [ "$owner" = "?" ]; then echo "/usr/bin/some-daemon"; else
    echo "/Users/x/Library/Developer/CoreSimulator/Devices/$owner/data/Containers/Bundle/Application/X/WebDriverAgentRunner-Runner.app/WebDriverAgentRunner-Runner"; fi
done
EOF

cat > "$BIN/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"; for a in "$@"; do case "$a" in http://*) url="$a" ;; esac; done
port="$(printf '%s\n' "$url" | sed -nE 's#http://localhost:([0-9]+).*#\1#p')"
for l in $FX_LISTEN; do
  [ "${l%%:*}" = "$port" ] || continue
  case "$url" in
    */status) echo '{"value":{"ready":true}}' ;;
    */source*) echo '{"value":{"type":"XCUIElementTypeApplication","label":"Home","rect":{"x":0,"y":0,"width":402,"height":874},"isVisible":"1","children":[{"type":"XCUIElementTypeIcon","label":"Maps","rect":{"x":20,"y":80,"width":64,"height":64},"isVisible":"1"}]}}' ;;
    *) echo '{"value":{}}' ;;
  esac
  exit 0
done
exit 7
EOF

cat > "$BIN/pgrep" <<'EOF'
#!/bin/bash
[ "${FX_SIMPROC:-no}" = yes ] && [ "${@: -1}" = Simulator ] && { echo 4242; exit 0; }
exit 1
EOF

cat > "$BIN/open" <<'EOF'
#!/bin/bash
[ "${FX_SIMAPP:-no}" = yes ] && exit 0
echo "Unable to find application named 'Simulator'" >&2; exit 1
EOF

printf '#!/bin/bash\nexit 0\n' > "$BIN/sleep"
printf '#!/bin/bash\necho "Simulator - iPhone 17 Pro"\n' > "$BIN/osascript"
printf '#!/bin/bash\necho arm64\n' > "$BIN/lipo"
chmod +x "$BIN"/*

# A runner copy "installed on the other simulator", in the layout CoreSimulator uses.
ROOT="$FX/devices"
APP="$ROOT/$OTHER/data/Containers/Bundle/Application/AAAA/WebDriverAgentRunner-Runner.app"
mkdir -p "$APP" "$FX/empty"
touch "$APP/WebDriverAgentRunner-Runner"
plutil -create xml1 "$APP/Info.plist"
plutil -insert CFBundleIdentifier -string com.facebook.WebDriverAgentRunner.xctrunner "$APP/Info.plist"
plutil -insert CFBundleExecutable -string WebDriverAgentRunner-Runner "$APP/Info.plist"
plutil -insert DTPlatformName -string iphonesimulator "$APP/Info.plist"
plutil -insert MinimumOSVersion -string 13.0 "$APP/Info.plist"

FAILS=0
# case NAME EXPECTED_RC 'must-match regex' 'must-not-match regex' -- command...
# (env for the case is passed in front of the call)
case_() {
  local name="$1" want_rc="$2" must="$3" mustnot="$4"; shift 5
  local out rc ok=1 why=""
  out="$(env PATH="$BIN:$PATH" WDA_SIM_SEARCH_ROOT="${FX_ROOT:-$ROOT}" WDA_SIM_DERIVED="$FX/no-build" \
         SIMUI_NO_CACHE=1 "$@" 2>&1)"; rc=$?
  [ "$rc" = "$want_rc" ] || { ok=""; why="exit $rc, wanted $want_rc"; }
  if [ -n "$must" ] && ! printf '%s\n' "$out" | grep -qE -- "$must"; then ok=""; why="${why:+$why; }missing /$must/"; fi
  if [ -n "$mustnot" ] && printf '%s\n' "$out" | grep -qE -- "$mustnot"; then ok=""; why="${why:+$why; }unexpected /$mustnot/"; fi
  if [ -n "$ok" ]; then echo "PASS $name (exit $rc)"; else echo "FAIL $name: $why"; FAILS=$((FAILS + 1)); fi
  if [ -n "$VERBOSE" ] || [ -z "$ok" ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi
}

S="$HERE/sim-ui.sh"; G="$HERE/wda-sim.sh"
export FX_BOOTED="$TARGET $OTHER"

FX_INSTALL=absent FX_LISTEN="" FX_LAUNCH_OUT="Simulator device failed to launch com.facebook.WebDriverAgentRunner.xctrunner." FX_LAUNCH_RC=4 \
case_ runner_missing 1 "com.facebook.WebDriverAgentRunner.xctrunner is NOT installed on $TARGET.*" "open -a Simulator|Possible cause" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=absent FX_LISTEN="" \
case_ runner_missing_install_cmd 1 "^    xcrun simctl install $TARGET $APP$" "" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=absent FX_LISTEN="" FX_ROOT="$FX/empty" \
case_ bundle_unavailable 1 "No usable simulator runner bundle was found" "xcrun simctl install|Bundle/Application" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=installed FX_LISTEN="" FX_SIMAPP=no \
case_ present_but_fails_no_simulator_app 1 "is installed on $TARGET, so the runner exists but did not come up" "open -a Simulator|NOT installed" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=installed FX_LISTEN="" FX_SIMAPP=yes FX_SIMPROC=no \
case_ present_but_fails_simulator_app_closed 1 "Possible cause \(not proven\)[^$]*|open -a Simulator --args -CurrentDeviceUDID $TARGET" "NOT installed" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=error FX_LISTEN="" \
case_ inspection_fails 1 "Could not inspect whether .* is installed on $TARGET" "NOT installed|No usable" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=absent FX_LISTEN="8100:$OTHER" \
case_ other_sims_wda_on_8100_runner_missing 1 "NOT installed on $TARGET" "WDA_PORT=8100|runner is installed and running|belongs to simulator" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=installed FX_LISTEN="8100:$OTHER" \
case_ other_sims_wda_on_8100_runner_present 1 "The WDA answering on :8100 belongs to simulator $OTHER - it says nothing about $TARGET" "Re-run with WDA_PORT=8100|runner is installed and running" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=installed FX_LISTEN="8100:$TARGET" \
case_ own_wda_on_8100 1 "This simulator's WDA IS answering on the default :8100.*|Re-run with WDA_PORT=8100" "" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all
FX_INSTALL=absent FX_LISTEN="8100:$OTHER" \
case_ default_port_owned_by_other_runner_missing 1 ":8100 is WebDriverAgent for simulator $OTHER, not $TARGET" "Start one on a free port|^\[" -- \
  env SIM_UDID=$TARGET "$S" elements
FX_INSTALL=absent FX_LISTEN="8100:$OTHER" \
case_ default_port_owned_by_other_names_missing_runner 1 "NOT installed on $TARGET" "" -- \
  env SIM_UDID=$TARGET "$S" elements
FX_INSTALL=installed FX_LISTEN="8107:$TARGET" \
case_ healthy 0 '"label":"Maps"' "ERROR" -- \
  env SIM_UDID=$TARGET WDA_PORT=8107 "$S" elements --all

FX_INSTALL=absent FX_LISTEN="" FX_ROOT="$FX/empty" \
case_ gate_no_source 1 "WDA NOT READY on $TARGET: no usable runner bundle to install" "WDA READY" -- \
  "$G" ensure $TARGET --port 8107
FX_INSTALL=absent FX_LISTEN="" \
case_ gate_supplied_source_unusable 1 "WDA_SIM_RUNNER=$FX/empty is not usable" "installing from|WDA READY" -- \
  env WDA_SIM_RUNNER="$FX/empty" "$G" ensure $TARGET --port 8107
FX_INSTALL=absent FX_LISTEN="8102:$OTHER" \
case_ gate_port_owned_by_other 1 ":8102 is taken by simulator $OTHER" "installing from|WDA READY" -- \
  "$G" ensure $TARGET --port 8102
FX_INSTALL=installed FX_LISTEN="8107:?" \
case_ gate_unattributed_listener 1 ":8107 is taken by an unattributed process" "WDA READY" -- \
  "$G" ensure $TARGET --port 8107
FX_INSTALL=installed FX_LISTEN="8103:$TARGET" \
case_ gate_already_on_other_port 1 "already listens on :8103 - use --port 8103" "starting WDA" -- \
  "$G" ensure $TARGET --port 8107
FX_INSTALL=absent FX_LISTEN="" \
case_ gate_check_does_not_install 1 "is not installed" "installing from" -- \
  "$G" check $TARGET --port 8107
FX_INSTALL=error FX_LISTEN="" \
case_ gate_inspection_fails 1 "could not inspect installation state" "installing from|WDA READY" -- \
  "$G" ensure $TARGET --port 8107
FX_INSTALL=installed FX_LISTEN="8107:$TARGET" \
case_ gate_ready 0 "WDA READY on $TARGET :8107" "installing from|starting WDA" -- \
  "$G" check $TARGET --port 8107
FX_INSTALL=installed FX_LISTEN="" \
case_ gate_refuses_phone 2 "physical iPhone - use wda-device.sh" "" -- \
  "$G" ensure 00008101-000315363CBA001E --port 8107
FX_INSTALL=installed FX_LISTEN="" \
case_ gate_requires_port 2 "--port <number> is required" "" -- \
  "$G" ensure $TARGET

if [ "$FAILS" -gt 0 ]; then echo "$FAILS case(s) FAILED"; exit 1; fi
echo "all cases passed"
