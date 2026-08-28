#!/bin/bash
# regress.sh - capture what sim-ui.sh actually prints, so a change to it can be shown
# NOT to alter behaviour. Runs the whole command surface, including every guard and
# error path, and writes one file per case (stdout + stderr + exit code).
#
#   SIM_UDID=<udid> WDA_PORT=<port> regress.sh /tmp/before     # on the current script
#   ...edit sim-ui.sh...
#   SIM_UDID=<udid> WDA_PORT=<port> regress.sh /tmp/after
#   diff -r /tmp/before /tmp/after
#
# Cases whose output depends on what is on screen (elements, elements_all, alert_none)
# only compare cleanly when the app is left on the same screen for both runs - park it
# somewhere idle first. Everything else is deterministic.
OUT="${1:?usage: regress.sh <outdir>}"
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sim-ui.sh"
mkdir -p "$OUT"
run() { local name="$1"; shift; { echo "--- rc/stdout/stderr for: $* ---"; "$@" 2>&1; echo "rc=$?"; } > "$OUT/$name.txt"; }

run usage            "$S"
run devices          "$S" devices
run elements         "$S" elements
run elements_all     "$S" elements --all
run tap_ok           "$S" tap 220 700
run tap_oob_x        "$S" tap 999 100
run tap_oob_y        "$S" tap 100 9999
run tap_neg          "$S" tap -5 100
run tap_float        "$S" tap 22.5 100
run tap_missing      "$S" tap
run swipe_oob        "$S" swipe 100 100 100 9999
run alert_none       "$S" alert
run button_bad       "$S" button NOPE
run badcmd           "$S" frobnicate
run waitfor_miss     "$S" waitfor 'zzz-nothing-matches-this' --timeout 2
run waitfor_nopat    "$S" waitfor
run waitfor_badflag  "$S" waitfor 'x' --nope
run waitfor_all_miss "$S" waitfor 'zzz-nothing-matches-this' --all --timeout 2
run do_comment       "$S" do '# just a comment' 'wait 0'
run do_tolerated     "$S" do '?alert' 'wait 0'
# fail-fast: an untolerated failing step must stop the batch, so the marker never prints
run do_failfast      "$S" do 'alert' 'wait 0' '# UNREACHED-MARKER'
run do_stdin         bash -c "printf '%s\n' '# from stdin' 'wait 0' | '$S' do"
# the gesture commands share one bounds check - prove each is actually wired to it
run doubletap_oob    "$S" doubletap 100 9999
run longpress_oob    "$S" longpress 100 9999
run swipe_oob2       "$S" swipe 100 9999 100 100
# the disk geometry cache must not change what a bounds error says
run nocache_tap_oob  env SIMUI_NO_CACHE=1 "$S" tap 999 100
# a WDA on another port drives another simulator: this must REFUSE, not read it
if [ -n "${OTHER_WDA_PORT:-}" ]; then
  run wrong_wda_port env WDA_PORT="$OTHER_WDA_PORT" "$S" elements
fi
# no SIM_UDID with several booted: must REFUSE rather than guess
run no_udid          env -u SIM_UDID "$S" elements

# Screenshots are compared by SIZE, never by bytes: the pixels change with whatever is on
# screen, while the point-width resampling is exactly what a change to the driver can break.
# The output path is `screenshot OUT [--width N]`, so the flags go AFTER it.
shot() {
  local name="$1"; shift
  local f="$OUT/$name.png"
  { echo "--- dims for: screenshot <out> $* ---"
    "$S" screenshot "$f" "$@" >/dev/null 2>&1
    sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | tail -2
    rm -f "$f"
  } > "$OUT/$name.txt"
}
shot screenshot_default
shot screenshot_w300  --width 300
shot screenshot_full  --width 0
echo "captured $(ls "$OUT" | wc -l | tr -d ' ') cases into $OUT"
