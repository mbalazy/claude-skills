#!/bin/bash
# android-rig-check.sh - prove the Android emulator is running YOUR code before you trust
# any reading. The Android counterpart of rig-check.sh, with the same contract: it does not
# check causes, it checks the EFFECT. A unique marker goes in as the first line of the
# entry file, the app is cold-started, and the marker is read back out of logcat
# (ReactNativeJS). Marker seen = your tree reaches the app. No marker = the rig is dead and
# NO observation from this session is valid, including "the screen looks right".
#
# Usage:
#   android-rig-check.sh [options]
#     --repo PATH       tree that must reach the app (default: git root of cwd)
#     --package PKG     app under test (default: the `android package` line of
#                       <repo>/.simulator-verify/config.md, else its `bundle id` line; a worktree
#                       without the config reads the main worktree's)
#     --entry FILE      entry file to mark, relative to repo (default: the file `main` names in
#                       package.json when it exists - index.ts in an Expo app - else index.js)
#     --serial SERIAL   emulator (default: $ANDROID_SERIAL, else the only attached device;
#                       several and none named = exit 2 with the list - never a guess)
#     --port N          Metro port (default: the Metro whose cwd is <repo>, else refused)
#     --reload          trigger with the app's reload broadcast instead of a cold start - only
#                       on an app that is already up: a reload during startup left a lasting
#                       redbox in 9 of 12 runs (Reanimated)
#     --timeout N       seconds to wait for the marker (default 30)
#
# Where the app loads JS from: a debug build reads the Metro host from the
# `debug_http_host` string in its shared_prefs (there are no launch arguments on Android).
# This check sets it to 10.0.2.2:<port> (the emulator's address of this Mac) by merging that
# one key into the file - every other key survives - and LEAVES it set, so the next plain
# start comes back on the same Metro. The output says what it was before. An Expo
# dev-client (an exp+<slug> scheme) is started through its exp+<slug>://expo-development-client
# link instead, which writes the same pref itself.
#
# Exit: 0 = RIG OK, 1 = RIG DEAD, 2 = bad usage or an ambiguous device.
# The marker is always removed again, including on Ctrl-C or an error mid-run.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/android-lib.sh"
PREFS="$HERE/android_prefs.py"

REPO=""; PKG=""; ENTRY=""; PORT=""; PORT_EXPLICIT=""; TRIGGER="cold"; TIMEOUT=30

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--package|--entry|--serial|--port|--timeout)
      [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --repo)    REPO="${2:-}"; shift 2 ;;
    --package) PKG="${2:-}"; shift 2 ;;
    --entry)   ENTRY="${2:-}"; shift 2 ;;
    --serial)  export ANDROID_SERIAL="${2:-}"; shift 2 ;;
    --port)    PORT="${2:-}"; PORT_EXPLICIT=1; shift 2 ;;
    --reload)  TRIGGER="reload"; shift ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "--timeout must be whole seconds, got '$TIMEOUT'" >&2; exit 2; }
[ -z "$PORT" ] || [[ "$PORT" =~ ^[0-9]+$ ]] || { echo "--port must be a port number, got '$PORT'" >&2; exit 2; }

NOTES=()
note() { NOTES+=("$1"); }
INSTALLED_AT=""

verdict() {   # OK|DEAD "reason"
  echo
  echo "----------------------------------------------------------------"
  if [ "$1" = OK ]; then
    echo "RIG OK - the app is running code from $REPO"
    # JS is live from Metro, the native layer is what was installed. Said on EVERY green
    # verdict: a native change merged after the install is simply absent.
    [ -n "$INSTALLED_AT" ] && echo "  native binary installed $INSTALLED_AT - native changes made after that are NOT in this app"
  else
    echo "RIG DEAD: $2"
    echo "  => no observation from this session is valid, including screenshots."
  fi
  echo "----------------------------------------------------------------"
  printf '  %s\n' "${NOTES[@]+"${NOTES[@]}"}"
  [ "$1" = OK ] && exit 0
  exit 1
}

sh_dev() { "$ADB" -s "$SERIAL" shell "$@" </dev/null 2>/dev/null | tr -d '\r'; }
# `X | grep -q RE` under pipefail is false whenever grep matches EARLY: it exits, X dies of
# SIGPIPE, and the pipeline's status is X's 141 (an APK with a bundle read as one without).
# `X | has RE` reads all of X first.
has() { local t; t="$(cat)"; grep -qE -- "$1" <<< "$t"; }

# --- repo, entry, package ----------------------------------------------------------------
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || { echo "not in a git repo and no --repo given" >&2; exit 2; }
fi
[ -d "$REPO" ] || { echo "--repo is not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"   # physical path: lsof reports cwd resolved
if [ -z "$ENTRY" ]; then
  ENTRY="index.js"
  if [ -f "$REPO/package.json" ]; then
    _main="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("main") or "")' "$REPO/package.json" 2>/dev/null || true)"
    [ -n "$_main" ] && [ -f "$REPO/$_main" ] && ENTRY="$_main"
  fi
fi
ENTRY_PATH="$REPO/$ENTRY"
[ -f "$ENTRY_PATH" ] || { echo "entry file not found: $ENTRY_PATH (pass --entry)" >&2; exit 2; }
note "repo:    $REPO"
_sha="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)"
[ -n "$_sha" ] && note "branch:  $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $_sha"
note "entry:   $ENTRY"

# `.simulator-verify/` is per-project and normally gitignored, so a fresh worktree lacks it;
# the main worktree's copy describes the same project (as rig-check.sh).
CONFIG="$REPO/.simulator-verify/config.md"
if [ ! -f "$CONFIG" ]; then
  _common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$_common" ] && [ -f "$(dirname "$_common")/.simulator-verify/config.md" ]; then
    CONFIG="$(dirname "$_common")/.simulator-verify/config.md"
    note "config:  $REPO has no .simulator-verify/ - read from the main worktree's"
  fi
fi
if [ -z "$PKG" ] && [ -f "$CONFIG" ]; then
  PKG="$( { grep -m1 -i 'android package' "$CONFIG" || grep -m1 -i 'bundle id' "$CONFIG" || true; } \
          | grep -oE '`[A-Za-z0-9._]+`' | head -1 | tr -d '`')"
fi
[ -n "$PKG" ] || { echo "no package (no 'android package' or 'bundle id' line in $CONFIG) - pass --package" >&2; exit 2; }
note "package: $PKG"

# --- device ---------------------------------------------------------------------------------
SERIAL="$(android_serial)" || exit $?
case "$SERIAL" in
  emulator-*) ;;
  *) verdict DEAD "$SERIAL is not an emulator - this check drives emulators only (a phone reaches the Mac's Metro through adb reverse, which it does not set up)" ;;
esac
note "device:  $SERIAL ($(android_name "$SERIAL"))"

# --- Metro listeners -----------------------------------------------------------------------
# Who listens where, and on which tree: a Metro serving another tree feeds the app someone
# else's code. An emulator's connections all belong to one host process, so - unlike the
# simulator - they do not say which emulator talks to which Metro; the device comes from
# --serial, the port from the tree.
METRO_FOR_REPO=""; REPO_PORTS=" "; WEDGED_METRO=""; OTHER_METRO=""; LISTEN_PORTS=" "
while read -r cmd pid port; do
  [ -n "$pid" ] || continue
  LISTEN_PORTS="$LISTEN_PORTS$port "
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2- || true)"
  if [ "$cwd" = "$REPO" ]; then
    if curl -s -m 2 "http://127.0.0.1:$port/status" 2>/dev/null | has 'packager-status:running'; then
      [ -n "$METRO_FOR_REPO" ] || METRO_FOR_REPO="$port"
      REPO_PORTS="$REPO_PORTS$port "
      note "listen:  :$port $cmd pid $pid  <- serves this repo"
    elif [ "$cmd" = node ]; then
      WEDGED_METRO="$port"
      note "listen:  :$port $cmd pid $pid  <- node serving this repo, but /status is silent: WEDGED Metro"
    else
      note "listen:  :$port $cmd pid $pid  (this repo's cwd, but not a packager - ignored)"
    fi
  else
    OTHER_METRO=1
    note "listen:  :$port $cmd pid $pid cwd ${cwd:-?}  (not this repo)"
  fi
done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
          | awk 'NR > 1 { n = split($9, a, ":"); p = a[n] + 0; if (p >= 8080 && p <= 8199) print $1, $2, p }' \
          | sort -u -k3,3n)

# --- the installed app ---------------------------------------------------------------------
APKS="$(sh_dev pm path "$PKG" | sed -n 's/^package://p')"
if [ -z "$APKS" ]; then
  # An install the device holds for consent (Play Protect) is not installed yet: say that,
  # not "not installed" - only a person at the device can let it through.
  # "Active install sessions:" is a header printed with an empty list too: only a session
  # of THIS package, listed before the finalized ones, counts.
  if sh_dev dumpsys window | has 'mFocusedApp=.*PlayProtectDialogsActivity' \
     || sh_dev dumpsys package | awk -v p="appPackageName=$PKG" '/^Active install sessions:/ { a = 1; next }
          /^[A-Z][a-z]+ install sessions:/ { a = 0 } a && index($0, p) { f = 1 } END { exit !f }'; then
    verdict DEAD "$PKG is waiting for consent on $SERIAL (Play Protect / an active install session) - a person at the device must approve the install"
  fi
  verdict DEAD "$PKG is not installed on $SERIAL"
fi
BASE_APK="$(awk '/\/base\.apk$/ { print; exit }' <<< "$APKS")"
[ -n "$BASE_APK" ] || BASE_APK="$(head -1 <<< "$APKS")"
if [ "$(printf '%s\n' "$APKS" | grep -c .)" -gt 1 ]; then
  note "apk:     $BASE_APK (split install, $(printf '%s\n' "$APKS" | grep -c .) APKs - the JS bundle and the sha are read from base.apk)"
else
  note "apk:     $BASE_APK"
fi
DUMP="$(sh_dev dumpsys package "$PKG")"
INSTALLED_AT="$(printf '%s\n' "$DUMP" | sed -nE 's/^ *lastUpdateTime=(.*)$/\1/p' | head -1)"
note "installed: ${INSTALLED_AT:-?} (lastUpdateTime)"

# Binary age: the installed APK against this tree's own builds. No local build = a note.
DEV_SHA="$(sh_dev sha256sum "$BASE_APK" | awk '{ print $1 }')"
LOCAL="$(find "$REPO/android/app/build/outputs/apk" -name '*.apk' 2>/dev/null | while read -r f; do
           printf '%s %s\n' "$(stat -f %m "$f")" "$f"; done | sort -rn || true)"
if [ "$(printf '%s\n' "$APKS" | grep -c .)" -gt 1 ]; then
  # A split install comes from an app bundle: its base.apk is cut by bundletool and never
  # equals an APK the build wrote, so a sha comparison would always say "no match".
  note "binary:  split install - its base.apk cannot match a local APK; compare lastUpdateTime with the bundle's build time"
elif [ -z "$LOCAL" ]; then
  note "binary:  no local build under android/app/build/outputs/apk - cannot tell whether the installed APK is current"
else
  MATCH=""
  while read -r _e f; do
    [ "$(shasum -a 256 "$f" | awk '{ print $1 }')" = "$DEV_SHA" ] && { MATCH="$f"; break; }
  done <<< "$LOCAL"
  NEWEST="$(printf '%s\n' "$LOCAL" | head -1)"
  if [ -n "$MATCH" ]; then
    note "binary:  the installed APK IS ${MATCH#$REPO/}"
  else
    note "binary:  the installed APK matches NO local build; newest local: ${NEWEST#* } ($(date -r "${NEWEST%% *}" '+%Y-%m-%d %H:%M'))"
    note "         a native change built there is not on the device - adb -s $SERIAL install -r <that apk> keeps the app's data"
  fi
fi

# Debuggable: run-as is the only way to the prefs, and a release build has no dev support.
if ! "$ADB" -s "$SERIAL" shell run-as "$PKG" true </dev/null >/dev/null 2>&1; then
  verdict DEAD "$PKG is not debuggable on $SERIAL - the host pref cannot be set and a release build does not load JS from Metro. Install a debug build."
fi

# Embedded bundle: present is a suspect, not a cause (a debug build with one still prefers
# Metro); it becomes the cause when the app reports Metro unreachable.
EMBEDDED=""
if sh_dev unzip -l "$BASE_APK" | has 'assets/index\.android\.bundle'; then
  EMBEDDED=1
  note "SUSPECT: the APK carries assets/index.android.bundle - it runs that frozen JS whenever it finds no Metro"
else
  note "jsbundle: none in the APK (loads JS from Metro only)"
fi

EXPO_SCHEME=""
if printf '%s\n' "$DUMP" | has 'pkgFlags=\[[^]]*DEBUGGABLE'; then
  EXPO_SCHEME="$(printf '%s\n' "$DUMP" | grep -oE 'exp\+[a-z0-9.+-]+' | head -1 || true)"
fi
[ -n "$EXPO_SCHEME" ] && note "expo:    dev-client ($EXPO_SCHEME) - started through its expo-development-client link"

# --- Metro port -------------------------------------------------------------------------------
if [ -z "$PORT" ]; then
  if [ -z "$METRO_FOR_REPO" ]; then
    [ -n "$WEDGED_METRO" ] && verdict DEAD "Metro on :$WEDGED_METRO is WEDGED - it holds the port for $REPO but does not answer packager-status:running, so the app finds no packager. Restart it."
    [ -n "$EMBEDDED" ] && verdict DEAD "no Metro is serving $REPO, and the APK carries an EMBEDDED bundle (assets/index.android.bundle): started now, the app would run that frozen JS, not your code. Start this tree's Metro."
    [ -n "$OTHER_METRO" ] && verdict DEAD "no Metro for this tree - the Metro(s) listening serve other trees (listeners and their cwd above). Start one in $REPO (or pass --port if the app talks to another tree's Metro on purpose)."
    verdict DEAD "no Metro is running at all (nothing listens on 8080-8199). Start one in $REPO."
  fi
  PORT="$METRO_FOR_REPO"
fi
PORT_OURS=""
case "$REPO_PORTS" in *" $PORT "*) PORT_OURS=1 ;; esac
[ -n "$PORT_OURS" ] || note "WARN:    no Metro of this repo on :$PORT; using it as told - it may belong to another tree or session"
HOST="10.0.2.2:$PORT"

# --- the host pref --------------------------------------------------------------------------
PREFS_FILE="shared_prefs/${PKG}_preferences.xml"
read_prefs() { "$ADB" -s "$SERIAL" shell "run-as $PKG cat $PREFS_FILE" </dev/null 2>/dev/null | tr -d '\r' | grep -v 'No such file' || true; }
WAS="$(read_prefs | python3 "$PREFS" get debug_http_host || true)"
if [ -z "$EXPO_SCHEME" ] && [ "$TRIGGER" = cold ]; then
  # Read whole, merged on the host, written whole - and never under a live process, which
  # keeps its own copy in memory and writes it back.
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  "$ADB" -s "$SERIAL" shell "run-as $PKG mkdir -p shared_prefs" </dev/null >/dev/null 2>&1
  CUR="$(read_prefs)"
  NEW="$(mktemp -t android-rig-prefs)"
  if ! printf '%s' "$CUR" | python3 "$PREFS" set debug_http_host "$HOST" > "$NEW"; then
    rm -f "$NEW"
    verdict DEAD "$PREFS_FILE of $PKG is not a preferences file this check can merge into - left untouched"
  fi
  "$ADB" -s "$SERIAL" shell "run-as $PKG sh -c 'cat > $PREFS_FILE'" < "$NEW" >/dev/null 2>&1
  rm -f "$NEW"
  NOW="$(read_prefs | python3 "$PREFS" get debug_http_host || true)"
  [ "$NOW" = "$HOST" ] || verdict DEAD "could not set debug_http_host of $PKG to $HOST (it reads '${NOW:-nothing}')"
  note "debug_http_host: was ${WAS:-none}, now $NOW (left set)"
fi

# --- marker -----------------------------------------------------------------------------------
MARKER="RIGCHECK_$(date +%s)_$$"
BACKUP="$(mktemp -t android-rigcheck)"
cp "$ENTRY_PATH" "$BACKUP"
restore() {
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$ENTRY_PATH" && rm -f "$BACKUP"
    if grep -q 'RIGCHECK_' "$ENTRY_PATH" 2>/dev/null; then
      echo "!! FAILED TO RESTORE $ENTRY_PATH - remove the RIGCHECK_ line by hand" >&2
    fi
  fi
}
trap 'restore' EXIT
trap 'restore; exit 130' INT
trap 'restore; exit 143' TERM
if grep -q 'RIGCHECK_' "$BACKUP"; then
  note "WARN:    stale RIGCHECK_ line in $ENTRY - stripping it"
  grep -v 'RIGCHECK_' "$BACKUP" > "$BACKUP.clean" && mv "$BACKUP.clean" "$BACKUP"
fi
{ echo "console.log('$MARKER');"; cat "$BACKUP"; } > "$ENTRY_PATH"
# Metro sees the change through its file watcher; a start that wins the race would be
# served the old file.
sleep 1

# --- trigger ----------------------------------------------------------------------------------
# logcat -T takes the device's clock. One string: `adb shell` would split the format at its
# space and `date` would refuse it, leaving -T empty (logcat then prints its last line only).
dev_now() { sh_dev "date '+%m-%d %H:%M:%S.000'"; }
start_cold() {
  local act url o
  "$ADB" -s "$SERIAL" shell am force-stop "$PKG" </dev/null
  if [ -n "$EXPO_SCHEME" ]; then
    url="$EXPO_SCHEME://expo-development-client/?url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "http://$HOST")"
    o="$("$ADB" -s "$SERIAL" shell "am start -W -a android.intent.action.VIEW -d '$url' $PKG" </dev/null 2>&1 | tr -d '\r')"
  else
    act="$(sh_dev cmd package resolve-activity --brief "$PKG" | tail -1)"
    o="$("$ADB" -s "$SERIAL" shell am start -W -n "$act" </dev/null 2>&1 | tr -d '\r')"
  fi
  if printf '%s\n' "$o" | has '^(Error|Exception)'; then
    note "start:   $(printf '%s\n' "$o" | grep -m1 -E '^(Error|Exception)')"
  fi
}
# logcat is the whole device's: another app on the same Metro logs the marker too when
# Fast Refresh re-runs the entry file in it (seen: the embedded-bundle flavor, still up,
# logged the marker of a run aimed at the other package). So the app's own pid filters
# every read; LOG_PID is the process of the start being judged.
LOG_PID=""
log_since() { "$ADB" -s "$SERIAL" logcat -d -T "$1" ${LOG_PID:+--pid="$LOG_PID"} "${@:2}" </dev/null 2>/dev/null | tr -d '\r'; }

T0="$(dev_now)"
[[ "$T0" =~ ^[0-9]{2}-[0-9]{2}\ [0-9:]{8}\.000$ ]] || verdict DEAD "could not read the clock of $SERIAL (date said '$T0') - the log cannot be read from the start"
if [ "$TRIGGER" = reload ]; then
  "$ADB" -s "$SERIAL" shell am broadcast -a "$PKG.RELOAD_APP_ACTION" -p "$PKG" </dev/null >/dev/null 2>&1
  note "trigger: am broadcast $PKG.RELOAD_APP_ACTION (reload of the running app)"
else
  start_cold
  note "trigger: cold start (force-stop + start)"
fi
PID="$(sh_dev pidof "$PKG")"
[ -n "$PID" ] || { sleep 1; PID="$(sh_dev pidof "$PKG")"; }
LOG_PID="$PID"

FOUND=""; APP_DIED=""; WAITED=0
# No process at all after the start: it died before it could be watched (a crash in
# Application.onCreate). Reading logcat unfiltered then would take another app's marker.
[ -n "$PID" ] || APP_DIED=1
while [ -z "$APP_DIED" ] && [ "$WAITED" -lt "$TIMEOUT" ]; do
  sleep 1; WAITED=$((WAITED + 1))
  if log_since "$T0" -s ReactNativeJS:V | has "$MARKER"; then FOUND=1; break; fi
  if [ "$(sh_dev pidof "$PKG")" != "$PID" ]; then APP_DIED=1; break; fi
  # A crashed process can stay listed for a while (behind the "keeps stopping" dialog, then
  # killed as cached): its crash-buffer line is the earlier signal.
  if log_since "$T0" -b crash | has 'FATAL EXCEPTION|Fatal signal'; then APP_DIED=1; break; fi
  # A thrown bundle never logs the marker; once the error is in, waiting longer adds nothing.
  if log_since "$T0" -s ReactNativeJS:E | has 'runtime not ready'; then sleep 1; break; fi
done

restore
trap - EXIT INT TERM
if [ -n "$EXPO_SCHEME" ]; then
  note "debug_http_host: was ${WAS:-none}, now $(read_prefs | python3 "$PREFS" get debug_http_host || echo none) (the dev launcher writes it)"
fi

# Leave the app running marker-free code: a second cold start (never a reload right after
# the marker - startup and reload race), and say whether it came up clean.
if [ -n "$FOUND" ] && [ "$TRIGGER" = cold ]; then
  T1="$(dev_now)"
  start_cold
  sleep 3
  LOG_PID="$(sh_dev pidof "$PKG")"
  if [ -z "$(sh_dev pidof "$PKG")" ]; then
    note "after:   the second, marker-free start did not stay up - check the app before reading anything"
  elif log_since "$T1" -s ReactNativeJS:E | has 'runtime not ready'; then
    note "after:   the second, marker-free start threw: $(log_since "$T1" -s ReactNativeJS:E | grep -m1 'runtime not ready' | sed -E 's/.*ReactNativeJS: //')"
  else
    note "after:   second cold start without the marker came up clean"
  fi
fi

if [ -n "$FOUND" ]; then
  note "marker:  $MARKER seen in logcat (ReactNativeJS) after ${WAITED}s"
  [ -n "$EMBEDDED" ] && note "         (the embedded bundle is present but was NOT used this time - this run's JS came from Metro)"
  verdict OK ""
fi

LOG_PID="$PID"
METRO_FALSE=""
[ -n "$PID" ] && METRO_FALSE="$(log_since "$T0" | grep -m1 -E 'isMetroRunning\(\): Async result = false|packager does not seem to be running' || true)"
if [ -n "$APP_DIED" ]; then
  note "marker:  $MARKER never appeared - the app process is gone (checked after ${WAITED}s)"
  sleep 1
  # The record of the process judged here: a fresh crash may not be written yet, and record
  # #0 is then the force-stop of the process before it. The pid is on the timestamp line,
  # the reason on the next one. No pid (died before it was seen) = the newest record.
  R=""
  for _i in 1 2 3; do
    # One process can have several records (a crash, then the kill of what it left
    # behind): the crash or signal one names the cause.
    R="$(sh_dev dumpsys activity exit-info "$PKG" | awk -v p="${PID:-}" '
          / pid=[0-9]+ / { n++; want = (p == "" ? n == 1 : index($0, " pid=" p " ") > 0); next }
          want && /reason=/ { sub(/^ */, ""); if (!first) first = $0
                              if (!cause && $0 ~ /CRASH|SIGNAL|ANR|INIT FAILURE/) cause = $0 }
          END { if (cause) print cause; else if (first) print first }')"
    [ -n "$R" ] && break
    sleep 1
  done
  [ -n "$R" ] && note "exit:    $R"
  C="$(LOG_PID="" log_since "$T0" -b crash | grep -B1 -F "$PKG" | grep -m2 -E 'FATAL|Process:|signal' || true)"
  [ -n "$C" ] && while IFS= read -r l; do note "crash:   $l"; done <<< "$C"
  verdict DEAD "the app TERMINATED instead of running your code - this is not a rig problem to debug through the log. A native crash at start after a dependency change: suspect a JS/native version skew first."
fi

note "marker:  $MARKER NEVER appeared (waited ${WAITED}s)"
if [ -n "$EXPO_SCHEME" ] && sh_dev dumpsys window | has 'mCurrentFocus=.*DevLauncherActivity'; then
  verdict DEAD "the Expo dev-client shows its LAUNCHER (the list of dev servers), not the app - it did not load from http://$HOST. Is that dev server up and serving this tree?"
fi
if [ -n "$EMBEDDED" ] && [ -n "$METRO_FALSE" ]; then
  note "logcat:  $(printf '%s' "$METRO_FALSE" | sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ [VDIWEF] //')"
  verdict DEAD "the app runs its EMBEDDED bundle (assets/index.android.bundle), not your code - it found no Metro at $HOST. JS frozen at build time is all it shows."
fi
# The port the app was pointed at is not this tree's Metro: whatever it ran (another
# tree's bundle, which often throws in this app) is not your code - that is the cause.
if [ -z "$PORT_OURS" ]; then
  [ -n "$WEDGED_METRO" ] && verdict DEAD "the app never ran your code - Metro on :$WEDGED_METRO is WEDGED. Restart that Metro."
  case "$LISTEN_PORTS" in
    *" $PORT "*) verdict DEAD "the app never ran your code - no Metro for this tree on :$PORT: what listens there serves another tree (the listeners and their cwd are listed above)." ;;
  esac
  verdict DEAD "the app never ran your code - nothing listens on :$PORT, no Metro at all there."
fi
JS_ERR="$(log_since "$T0" -s ReactNativeJS:E | grep -m1 'runtime not ready' | sed -E 's/.*ReactNativeJS: //; s/^\[runtime not ready\]: //' || true)"
if [ -n "$JS_ERR" ]; then
  note "js-error: $JS_ERR"
  case "$JS_ERR" in
    *"could not be found"*|*TurboModule*)
      note "binary:  installed ${INSTALLED_AT:-?}; a module the JS requires is not in it"
      verdict DEAD "the app is ALIVE but its JS threw while loading - a module it requires is missing from the NATIVE binary (JS/native skew: the JS is from this tree, the binary is older or from another branch). Build and install this tree's APK."
      ;;
  esac
  verdict DEAD "the app is ALIVE but its JS threw while loading the bundle, before your code could run (see js-error above). Fix that error first - the rig cannot be judged through it."
fi
[ -n "$METRO_FALSE" ] && note "logcat:  $(printf '%s' "$METRO_FALSE" | sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ [VDIWEF] //')"
verdict DEAD "the app never ran your code, and neither the build nor Metro explains why. Check that the app is in front (android-ui.sh foreground) and that it talks to $HOST."
