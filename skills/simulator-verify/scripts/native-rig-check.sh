#!/usr/bin/env bash
# native-rig-check.sh - prove a NATIVE app (Swift / Kotlin, no Metro) on the simulator or
# emulator is running the code of the tree under test, before any reading counts.
#
# rig-check.sh and android-rig-check.sh hand over to this script by themselves when the
# config says `- **app type**: \`native\``, with the same arguments; calling it directly is
# the same check. Same contract as the Metro checks: RIG OK = the app runs this tree, RIG
# DEAD = no observation from this session is valid, exit 2 = a question or a setup gap.
#
# The proof is by content, never by a date (lib/native.sh):
#   1. the tree's fingerprint now == the fingerprint native-build.sh recorded for the build;
#   2. the app installed on the device hashes the same as that build's artifact;
#   3. after a fresh start the app's process stays alive (a crash is named, with its report).
# A binary is the whole code of a native app, so 1+2 is what the Metro marker proves for JS.
#
# Usage:
#   native-rig-check.sh [options]
#     --repo PATH        tree that must reach the app (default: git root of cwd)
#     --platform P       ios | android (default: from the config's artifact line)
#     --udid UDID        iOS simulator (default: $SIM_UDID, else the only booted one, else the
#                        one the last native-build.sh installed on; never a guess)
#     --serial SERIAL    Android device (default: $ANDROID_SERIAL, else the only attached one,
#                        else the one the last native-build.sh installed on)
#     --bundle-id ID / --package PKG   app under test (default: the config)
#     --launch-arg ARG   iOS: extra argument for `simctl launch` (repeatable)
#     --no-relaunch      keep the running app (and its navigation state) when its process
#                        started after the install; start it only when it is not running
#     --settle N         seconds the fresh process must stay alive (default 5)
#   Accepted from the Metro checks and ignored with a note: --port, --entry, --host,
#   --no-jslocation, --timeout; --reload means --no-relaunch.
#
# Exit: 0 = RIG OK, 1 = RIG DEAD, 2 = the check could not start (a bad flag, a config gap it
# names, several devices and none identifiable - a question, not a dead rig).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/native.sh"

REPO=""; PLATFORM=""; UDID="${SIM_UDID:-}"; APP_ID=""; RELAUNCH=1; SETTLE=5
LAUNCH_ARGS=(); IGNORED=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--platform|--udid|--serial|--bundle-id|--package|--launch-arg|--settle|--port|--entry|--host|--timeout)
      [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --platform)   PLATFORM="$2"; shift 2 ;;
    --udid)       UDID="$2"; shift 2 ;;
    --serial)     export ANDROID_SERIAL="$2"; shift 2 ;;
    --bundle-id|--package) APP_ID="$2"; shift 2 ;;
    --launch-arg) LAUNCH_ARGS+=("$2"); shift 2 ;;
    --no-relaunch|--reload) RELAUNCH=""; shift ;;
    --settle)     SETTLE="$2"; shift 2 ;;
    --port|--entry|--host|--timeout) IGNORED+=("$1 $2"); shift 2 ;;
    --no-jslocation) IGNORED+=("$1"); shift ;;
    -h|--help)    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$SETTLE" =~ ^[0-9]+$ ]] || { echo "--settle must be whole seconds, got '$SETTLE'" >&2; exit 2; }
case "$PLATFORM" in ""|ios|android) ;; *) echo "--platform must be ios or android, got '$PLATFORM'" >&2; exit 2 ;; esac

NOTES=()
note() { NOTES+=("$1"); }

verdict() {   # OK|DEAD "reason"
  echo
  echo "----------------------------------------------------------------"
  if [ "$1" = OK ]; then
    echo "RIG OK - the app is running code from $REPO"
    echo "  native: the installed app is byte for byte the build of this tree as it is now"
  else
    echo "RIG DEAD: $2"
    echo "  => no observation from this session is valid, including screenshots."
  fi
  echo "----------------------------------------------------------------"
  printf '  %s\n' "${NOTES[@]+"${NOTES[@]}"}"
  [ "$1" = OK ] && exit 0
  exit 1
}

# --- repo, config ----------------------------------------------------------------------------
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || { echo "not in a git repo and no --repo given" >&2; exit 2; }
fi
[ -d "$REPO" ] || { echo "--repo is not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"
CONFIG="$(nv_config_for "$REPO")"
[ -f "$CONFIG" ] || { echo "no config: $CONFIG does not exist - copy $HERE/../references/config-template.md there and fill its native lines" >&2; exit 2; }
TYPE="$(nv_app_type "$CONFIG")"
[ "$TYPE" = native ] || { echo "$CONFIG has no '- **app type**: \`native\`' line${TYPE:+ (it says '$TYPE')} - for an RN / Expo app run rig-check.sh or android-rig-check.sh" >&2; exit 2; }
ART_CFG="$(nv_config_line "$CONFIG" artifact)"
CFG_PLATFORM="$(nv_platform_of "${ART_CFG%/}")"
if [ -n "$PLATFORM" ] && [ -n "$CFG_PLATFORM" ] && [ "$PLATFORM" != "$CFG_PLATFORM" ]; then
  other="$([ "$CFG_PLATFORM" = android ] && echo android-rig-check.sh || echo rig-check.sh)"
  echo "this repo's config describes an $CFG_PLATFORM app (artifact '$ART_CFG'), and this check was asked for $PLATFORM - run $other" >&2
  exit 2
fi
[ -n "$PLATFORM" ] || PLATFORM="$CFG_PLATFORM"
[ -n "$PLATFORM" ] || { echo "no '- **artifact**: \`path\`' line (.app or .apk) in $CONFIG and no --platform - cannot tell iOS from Android" >&2; exit 2; }
[ -n "$APP_ID" ] || APP_ID="$(nv_app_id "$CONFIG" "$PLATFORM")"
[ -n "$APP_ID" ] || { echo "no app id in $CONFIG - add '- **bundle id**: \`com.example.app\`' or pass --bundle-id" >&2; exit 2; }
RECORD="$(nv_record_path "$REPO")" || { echo "$REPO is not a git checkout" >&2; exit 2; }

note "repo:    $REPO"
note "branch:  $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
[ "$CONFIG" = "$REPO/.simulator-verify/config.md" ] || note "config:  $CONFIG (main worktree's)"
note "app:     $APP_ID (native $PLATFORM - no Metro, no JS marker: proof by content)"
for i in "${IGNORED[@]+"${IGNORED[@]}"}"; do note "ignored: $i (a native app has no Metro)"; done

# --- 1. the record and the tree --------------------------------------------------------------
R_FP="$(nv_record_get "$RECORD" fingerprint)"
R_SHA="$(nv_record_get "$RECORD" artifact_sha)"
R_APP="$(nv_record_get "$RECORD" app_id)"
R_DEV="$(nv_record_get "$RECORD" device)"
R_BUILT="$(nv_record_get "$RECORD" built_at)"
R_INST="$(nv_record_get "$RECORD" installed_at)"
R_HEAD="$(nv_record_get "$RECORD" head)"
BUILD_HINT="$HERE/native-build.sh$([ "$REPO" != "$(pwd -P)" ] && echo " --repo $REPO")"

[ -n "$R_FP" ] || verdict DEAD "no native build is recorded for this checkout - nothing proves what the installed app was built from. Build and install with: $BUILD_HINT"
[ "$R_APP" = "$APP_ID" ] || verdict DEAD "the recorded build is of '$R_APP', the config's app is '$APP_ID' - build again: $BUILD_HINT"
note "build:   recorded $(nv_fmt_epoch "${R_BUILT:-0}") from $R_HEAD, tree ${R_FP:0:12}, artifact ${R_SHA:0:12}"
FP="$(nv_fingerprint "$REPO")"
if [ "$FP" != "$R_FP" ]; then
  note "tree:    now ${FP:0:12} @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null), $(git -C "$REPO" status --porcelain 2>/dev/null | grep -c .) changed/untracked paths"
  verdict DEAD "the tree changed since the recorded build (HEAD or files differ) - the installed app does not contain it. Rebuild and install: $BUILD_HINT"
fi
note "tree:    unchanged since that build (${FP:0:12})"
[ -n "$R_INST" ] || verdict DEAD "the recorded build was never installed (native-build.sh ran with --no-install) - install it: $BUILD_HINT --install-only"

# --- 2. the device and what is installed on it -------------------------------------------------
INSTALL_HINT="$BUILD_HINT --install-only (the artifact on disk, when it is still this build), else $BUILD_HINT"
if [ "$PLATFORM" = ios ]; then
  if ! BOOTED_TXT="$(xcrun simctl list devices booted 2>/dev/null)"; then
    verdict DEAD "xcrun simctl does not run (full Xcode selected? xcode-select -p says $(xcode-select -p 2>/dev/null))"
  fi
  BOOTED="$(printf '%s\n' "$BOOTED_TXT" | grep -oE '\([0-9A-Fa-f-]{36}\) \(Booted\)' | grep -oE '[0-9A-Fa-f-]{36}' || true)"
  N="$(printf '%s\n' "$BOOTED" | grep -c . || true)"
  if [ -z "$UDID" ]; then
    if [ "$N" -eq 0 ]; then
      verdict DEAD "no booted simulator - boot the config's simulator (xcrun simctl boot <udid>)"
    elif [ "$N" -eq 1 ]; then
      UDID="$BOOTED"
    elif [ -n "$R_DEV" ] && printf '%s\n' "$BOOTED" | grep -qx "$R_DEV"; then
      UDID="$R_DEV"
      note "sim:     resolved via the last native install (not 'the booted one' - $N are booted)"
    else
      echo >&2
      echo "CANNOT TELL WHICH SIMULATOR IS YOURS - $N booted, none is where this checkout's build was installed." >&2
      echo "This is NOT a dead rig; it is a question. Re-run with --udid (or export SIM_UDID). Booted:" >&2
      printf '%s\n' "$BOOTED_TXT" | grep Booted | sed 's/^ */  /' >&2
      exit 2
    fi
  elif ! printf '%s\n' "$BOOTED" | grep -qx "$UDID"; then
    verdict DEAD "simulator $UDID is not booted - xcrun simctl boot $UDID"
  fi
  note "sim:     $UDID"
  INST="$(xcrun simctl get_app_container "$UDID" "$APP_ID" app 2>/dev/null || true)"
  [ -n "$INST" ] && [ -d "$INST" ] || verdict DEAD "$APP_ID is not installed on $UDID - install it: $INSTALL_HINT"
  INST_SHA="$(nv_hash_local "$INST")"
else
  . "$HERE/android-lib.sh"
  [ -n "$ADB" ] || exit 1
  if [ -z "${ANDROID_SERIAL:-}" ] && [ -n "$R_DEV" ] \
     && [ "$(android_attached | grep -c .)" -gt 1 ] \
     && android_attached | awk -v s="$R_DEV" '$1 == s && $2 == "device" { f = 1 } END { exit !f }'; then
    export ANDROID_SERIAL="$R_DEV"
    note "device:  resolved via the last native install (several are attached)"
  fi
  SERIAL="$(android_serial)" || exit $?
  ( android_assert_ready "$SERIAL" ) 2>/dev/null || verdict DEAD "$SERIAL is not ready (offline, unauthorized or still booting - adb devices)"
  note "device:  $SERIAL ($(android_name "$SERIAL"))"
  sh_dev() { "$ADB" -s "$SERIAL" shell "$@" </dev/null 2>/dev/null | tr -d '\r'; }
  if [ "$(android_lock_state "$SERIAL" 2>/dev/null || true)" = true ]; then
    verdict DEAD "the screen of $SERIAL is locked (asleep or behind the keyguard) - the app cannot come to the front. Wake and unlock it (adb -s $SERIAL shell input keyevent KEYCODE_WAKEUP; a PIN needs a person)"
  fi
  P="$(sh_dev pm path "$APP_ID" | sed -n 's/^package://p')"
  [ -n "$P" ] || verdict DEAD "$APP_ID is not installed on $SERIAL - install it: $INSTALL_HINT"
  if [ "$(printf '%s\n' "$P" | grep -c .)" -gt 1 ]; then
    verdict DEAD "$APP_ID is installed as split APKs on $SERIAL - not the single recorded .apk; install it: $INSTALL_HINT"
  fi
  INST_SHA="$(sh_dev sha256sum "$P" | cut -d' ' -f1)"
fi
[ -n "$INST_SHA" ] || verdict DEAD "could not hash the installed app$([ "$PLATFORM" = android ] && echo " ($P - does this device's shell have sha256sum?)") - without its hash nothing ties it to a build"
if [ "$INST_SHA" != "$R_SHA" ]; then
  note "installed:${INST_SHA:0:12}, recorded build: ${R_SHA:0:12}"
  verdict DEAD "the app installed on the device is NOT this checkout's recorded build - another checkout, branch or build was installed over it. Install this tree's build: $INSTALL_HINT"
fi
note "install: the installed app hashes the same as the recorded build (${INST_SHA:0:12}), installed $(nv_fmt_epoch "$R_INST")"

# --- 3. the process -----------------------------------------------------------------------------
if [ "$PLATFORM" = ios ]; then
  CRASH_REF="$(mktemp -t nvrig-crashref)"
  trap 'rm -f "$CRASH_REF"' EXIT
  running_pid() {
    xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v b="UIKitApplication:${APP_ID}[" 'index($3, b) == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }'
  }
  # LC_ALL=C on both sides: under another locale `ps` prints a localized date that `date -j`
  # cannot parse, and an unknown start time must never read as "after the install".
  proc_start() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | LC_ALL=C xargs -I{} date -j -f '%a %b %d %T %Y' '{}' +%s 2>/dev/null; }
  PID=""
  if [ -z "$RELAUNCH" ]; then
    PID="$(running_pid)"
    if [ -n "$PID" ]; then
      ST="$(proc_start "$PID")"
      if [ -z "$ST" ] || [ "$ST" -lt "${R_INST:-0}" ]; then
        note "process: pid $PID started $([ -n "$ST" ] && echo "before the install" || echo "at an unreadable time") - restarting it"
        PID=""
      else
        note "process: kept the running pid $PID (--no-relaunch)"
      fi
    fi
  fi
  STARTED=""
  if [ -z "$PID" ]; then
    xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1 || true
    OUT="$(xcrun simctl launch "$UDID" "$APP_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"} 2>&1)"
    PID="$(printf '%s\n' "$OUT" | sed -nE "s/^$APP_ID: ([0-9]+).*/\1/p" | head -1)"
    [ -n "$PID" ] || verdict DEAD "simctl launch did not start $APP_ID: $(printf '%s' "$OUT" | head -1)"
    STARTED=1
    note "process: launched, pid $PID"
  fi
  alive() { kill -0 "$PID" 2>/dev/null; }
  # The newest crash report of THIS bundle written since the launch. A function, not inline
  # in $(...): bash 3.2 cannot parse a `case` pattern's `)` inside a command substitution.
  crash_report_since() {
    local f h
    while IFS= read -r f; do
      IFS= read -r h < "$f" 2>/dev/null || continue
      case "$h" in
        *"\"bundleID\":\"$APP_ID\""*) echo "$f"; return 0 ;;
      esac
    done < <(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name '*.ips' -newer "$CRASH_REF" 2>/dev/null | sort -r)
  }
else
  PID=""
  if [ -z "$RELAUNCH" ]; then
    PID="$(sh_dev pidof "$APP_ID" | awk '{print $1}')"
    if [ -n "$PID" ]; then
      ST="$(sh_dev stat -c %Y "/proc/$PID")"
      if ! [[ "$ST" =~ ^[0-9]+$ ]] || [ "$ST" -lt "${R_INST:-0}" ]; then
        note "process: pid $PID started $([[ "$ST" =~ ^[0-9]+$ ]] && echo "before the install" || echo "at an unreadable time") - restarting it"
        PID=""
      else
        note "process: kept the running pid $PID (--no-relaunch)"
      fi
    fi
  fi
  STARTED=""
  T0="$(sh_dev "date '+%m-%d %H:%M:%S.000'")"
  if [ -z "$PID" ]; then
    "$ADB" -s "$SERIAL" shell am force-stop "$APP_ID" </dev/null
    ACT="$(sh_dev cmd package resolve-activity --brief "$APP_ID" | tail -1)"
    case "$ACT" in */*) ;; *) verdict DEAD "$APP_ID has no launcher activity on $SERIAL (resolve-activity said '$ACT')" ;; esac
    OUT="$("$ADB" -s "$SERIAL" shell am start -W -n "$ACT" </dev/null 2>&1 | tr -d '\r')"
    if printf '%s\n' "$OUT" | grep -qE '^(Error|Exception)'; then
      verdict DEAD "am start failed: $(printf '%s\n' "$OUT" | grep -m1 -E '^(Error|Exception)')"
    fi
    PID="$(sh_dev pidof "$APP_ID" | awk '{print $1}')"
    STARTED=1
    note "process: started $ACT, pid ${PID:-none}"
  fi
  alive() { [ -n "$PID" ] && sh_dev pidof "$APP_ID" | tr ' ' '\n' | grep -qx "$PID"; }
fi

DIED=""
i=0
while [ "$i" -lt "$SETTLE" ]; do
  alive || { DIED=1; break; }
  sleep 1; i=$((i + 1))
done
alive || DIED=1

if [ -n "$DIED" ]; then
  if [ "$PLATFORM" = ios ]; then
    REPORT=""
    for _ in 1 2 3 4 5; do   # ReportCrash writes the .ips a second or two after the death
      REPORT="$(crash_report_since)"
      [ -n "$REPORT" ] && break
      sleep 1
    done
    if [ -n "$REPORT" ]; then
      R="$(tail -n +2 "$REPORT" | python3 -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(((d.get("termination") or {}).get("indicator") or "") + " (" + ((d.get("exception") or {}).get("signal") or "") + ")")' 2>/dev/null)"
      note "crash:   ${R:-report written, reason not parsed} - $REPORT"
    else
      note "crash:   no crash report for $APP_ID since the launch - something outside may have killed it"
    fi
  else
    C="$("$ADB" -s "$SERIAL" logcat -d -b crash -T "$T0" </dev/null 2>/dev/null | tr -d '\r' | grep -B1 -A2 -F "$APP_ID" | grep -m3 -E 'FATAL|Process:|signal|Exception' || true)"
    [ -n "$C" ] && while IFS= read -r l; do note "crash:   $l"; done <<< "$C"
  fi
  verdict DEAD "the app TERMINATED within ${SETTLE}s of its start (pid ${PID:-none}) - it is not running this build. A crash at start is a finding about the build; read the crash before anything else."
fi
note "process: pid $PID alive ${SETTLE}s after $([ -n "$STARTED" ] && echo "the start" || echo "the check")"

# Which app is in front is a note, not a verdict: a system dialog (the notification
# permission on first launch) legitimately covers a healthy app.
if [ "$PLATFORM" = android ]; then
  TOP="$(sh_dev dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity' | grep -oE '[A-Za-z0-9._]+/[A-Za-z0-9._$]+' | head -1)"
  FRONT_NOTE=""
  case "$TOP" in
    "$APP_ID"/*|"") ;;
    *) FRONT_NOTE=" - NOT the app (a system dialog over it?)" ;;
  esac
  note "front:   ${TOP:-unknown}$FRONT_NOTE"
fi

verdict OK
