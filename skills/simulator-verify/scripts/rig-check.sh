#!/usr/bin/env bash
# rig-check.sh - prove the simulator is running YOUR code before you trust any reading.
#
# The failure it exists for: the app on the simulator quietly runs *different code or
# state* than the tree under test (a Release build with an embedded main.jsbundle, a
# Metro serving another worktree, a stale binary, a persisted store). Every one of those
# produces a normal-looking, entirely false result - most often SILENCE from
# instrumentation, which reads as "the feature never runs".
#
# So this does not check causes, it checks the EFFECT: it injects a unique marker as the
# first line of the entry file, makes the app pick up JS again, and reads the marker back
# out of the simulator's log. Marker seen = your tree reaches the app. No marker = the rig
# is dead and NO observation from this session is valid, including "the screen looks right".
#
# Usage:
#   rig-check.sh [options]
#     --repo PATH        tree that must reach the app (default: git root of cwd)
#     --bundle-id ID     app under test (default: parsed from <repo>/.simulator-verify/config.md)
#     --entry FILE       entry file to mark, relative to repo (default: index.js)
#     --udid UDID        simulator (default: $SIM_UDID; else the only booted one, or - with
#                        several booted - the one connected to this repo's Metro. Never a guess.)
#     --port N           Metro port (default: the Metro whose cwd is <repo>, else 8081)
#     --reload           trigger with `curl /reload` instead of terminate+launch (faster,
#                        keeps navigation state, but only works if --port is right)
#     --launch-arg ARG   extra argument passed to `simctl launch` (repeatable). Anything a
#                        launch of the app under test normally needs - the app never sees it
#                        otherwise, because this script starts the app itself.
#     --no-jslocation    do not add -RCT_jsLocation automatically (see below)
#     --timeout N        seconds to wait for the marker (default 30)
#
# On the relaunch trigger this script starts the app with
# `-RCT_jsLocation localhost:<port>`, so the app comes back on the Metro that serves --repo
# rather than on the port baked into the binary at build time. That redirect lives for one
# launch only (it is an NSUserDefaults argument-domain value, never persisted), which is why
# a plain `simctl launch` afterwards drops it and sends the app back to its baked port.
# Simulator builds accept it; a physical-device build does not, because its bundle carries an
# `ip.txt` that AppDelegate reads first. Suppress with --no-jslocation.
#
# Exit: 0 = RIG OK, 1 = RIG DEAD, 2 = bad usage.
# The marker is always removed again, including on Ctrl-C or an error mid-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ_LOGS="$SCRIPT_DIR/read-rn-logs.sh"

REPO=""; BUNDLE_ID=""; ENTRY="index.js"; UDID="${SIM_UDID:-}"; PORT=""; PORT_EXPLICIT=""
TRIGGER="relaunch"; TIMEOUT=30; AUTO_JSLOCATION=1
LAUNCH_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --bundle-id)     BUNDLE_ID="$2"; shift 2 ;;
    --entry)         ENTRY="$2"; shift 2 ;;
    --udid)          UDID="$2"; shift 2 ;;
    --port)          PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --reload)        TRIGGER="reload"; shift ;;
    --launch-arg)    LAUNCH_ARGS+=("$2"); shift 2 ;;
    --no-jslocation) AUTO_JSLOCATION=""; shift ;;
    --timeout)       TIMEOUT="$2"; shift 2 ;;
    -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- findings collected along the way, printed in the verdict block -------------------
NOTES=()
note() { NOTES+=("$1"); }

# UDIDs of simulator apps holding a connection to a given Metro port. A simulator app runs
# as a host process whose executable path contains its device UDID, so this ties sim to
# packager without touching either of them - and without believing "the booted one".
sims_on_port() {
  local pid comm
  for pid in $(lsof -nP -iTCP:"$1" -sTCP:ESTABLISHED -t 2>/dev/null | sort -u); do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "$comm" in */CoreSimulator/Devices/*) ;; *) continue ;; esac
    printf '%s\n' "$comm" | grep -oE 'Devices/[0-9A-Fa-f-]{36}' | cut -c9-
  done | sort -u
}

verdict() { # verdict OK|DEAD "reason"
  echo
  echo "----------------------------------------------------------------"
  if [[ "$1" == "OK" ]]; then
    echo "RIG OK - the app is running code from $REPO"
    # JS is live from Metro, the native layer is frozen at build time. Say when
    # that was on EVERY green verdict, not only on a detected skew: a native fix
    # merged after this date (2026-08-29: custom-scheme deep links, merged
    # 2026-08-28 into a binary built 2026-08-27) is simply absent, silently.
    if [[ -n "${APP:-}" ]]; then
      local built; built="$(app_built_epoch "$APP")"
      [[ -n "$built" ]] && echo "  native binary built $(fmt_epoch "$built") - native changes merged after that are NOT in this app"
    fi
  else
    echo "RIG DEAD: $2"
    echo "  => no observation from this session is valid, including screenshots."
  fi
  echo "----------------------------------------------------------------"
  printf '  %s\n' "${NOTES[@]}"
  [[ "$1" == "OK" ]] && exit 0
  exit 1
}

# --- repo ----------------------------------------------------------------------------
if [[ -z "$REPO" ]]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$REPO" ]] && { echo "not in a git repo and no --repo given" >&2; exit 2; }
fi
REPO="$(cd "$REPO" && pwd -P)"   # physical path - lsof reports cwd resolved, they must compare equal
ENTRY_PATH="$REPO/$ENTRY"
[[ -f "$ENTRY_PATH" ]] || { echo "entry file not found: $ENTRY_PATH (pass --entry)" >&2; exit 2; }

note "repo:    $REPO"
note "branch:  $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null) @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
note "entry:   $ENTRY"

# --- bundle id -----------------------------------------------------------------------
# `.simulator-verify/` is per-project config, and it is normally gitignored - so a fresh
# `git worktree` of the same repo does not have it and never will. Falling back to the main
# worktree's copy is not a guess: --repo already says the two are checkouts of ONE repo, and
# the bundle id is a property of the project, not of the branch. Without this, every
# throwaway worktree forces a --bundle-id nobody remembers.
CONFIG="$REPO/.simulator-verify/config.md"
CONFIG_SOURCE="$CONFIG"
if [[ ! -f "$CONFIG" ]]; then
  COMMON_DIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ -n "$COMMON_DIR" ]]; then
    MAIN_WORKTREE="$(dirname "$COMMON_DIR")"
    if [[ "$MAIN_WORKTREE" != "$REPO" && -f "$MAIN_WORKTREE/.simulator-verify/config.md" ]]; then
      CONFIG_SOURCE="$MAIN_WORKTREE/.simulator-verify/config.md"
      note "config:  $REPO has no .simulator-verify/ - read from main worktree $MAIN_WORKTREE"
    fi
  fi
fi
if [[ -z "$BUNDLE_ID" && -f "$CONFIG_SOURCE" ]]; then
  BUNDLE_ID="$(grep -m1 -i 'bundle id' "$CONFIG_SOURCE" | grep -oE '`[A-Za-z0-9._-]+`' | head -1 | tr -d '`')"
fi
[[ -z "$BUNDLE_ID" ]] && { echo "no bundle id (not in $CONFIG_SOURCE either) - pass --bundle-id" >&2; exit 2; }
note "bundle:  $BUNDLE_ID"

# --- Metro listeners -------------------------------------------------------------------
# Who listens where, and on which tree. A Metro serving a different worktree silently
# feeds the app someone else's code, which is exactly the failure this script catches.
# This runs BEFORE the simulator is resolved on purpose: when several sims are booted, the
# Metro serving this repo is the only thing that says which of them is ours.
METRO_FOR_REPO=""
WEDGED_METRO=""   # node from this repo that listens but does not answer as a packager
SIM_PAIRS=""   # lines "<port> <udid>": simulator apps connected to that Metro
while read -r cmd pid port; do
  [[ -z "$pid" ]] && continue
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)"
  if [[ "$cwd" == "$REPO" ]]; then
    # Matching cwd is not enough: any process started from this directory lands in the port
    # range (a debug collector on :8099 was once taken for Metro, and the app was then
    # pointed at a port that serves no JS at all). Ask the port whether it is a packager.
    if [[ "$(curl -s -m 2 "http://localhost:$port/status" 2>/dev/null)" == *packager-status:running* ]]; then
      METRO_FOR_REPO="$port"
      note "listen:  :$port $cmd pid $pid  <- serves this repo"
    elif [[ "$cmd" == node ]]; then
      # A node process serving this repo that will not say packager-status:running is a
      # Metro that WEDGED, not a stranger on the port - it keeps the socket open while the
      # app finds no packager and comes up on a redbox (journal sim-rig 20260730-fd2d).
      WEDGED_METRO="$port"
      note "listen:  :$port $cmd pid $pid  <- node serving this repo, but /status is silent: WEDGED Metro"
    else
      note "listen:  :$port $cmd pid $pid  (this repo's cwd, but not a packager - ignored)"
    fi
  else
    note "listen:  :$port $cmd pid $pid cwd ${cwd:-?}  (not this repo)"
  fi
  # Metro is node; asking the other listeners in the range (WDA and friends) which sims
  # are connected to them says nothing about which tree the app is running.
  if [[ "$cmd" == node ]]; then
    for u in $(sims_on_port "$port"); do
      SIM_PAIRS="$SIM_PAIRS$port $u"$'\n'
      note "         :$port <- sim $u"
    done
  fi
done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
          | awk 'NR>1 {n=split($9,a,":"); p=a[n]+0; if (p>=8080 && p<=8110) print $1, $2, p}' \
          | sort -u -k3,3n)

# --- simulator -----------------------------------------------------------------------
BOOTED=(); BOOTED_NAMES=()
while IFS= read -r line; do
  u="$(printf '%s' "$line" | grep -oE '[0-9A-Fa-f-]{36}' | head -1)"
  [[ -z "$u" ]] && continue
  BOOTED+=("$u")
  BOOTED_NAMES+=("$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(.*) \([0-9A-Fa-f-]{36}\).*$/\1/')")
done < <(xcrun simctl list devices booted 2>/dev/null)

if [[ -z "$UDID" ]]; then
  if (( ${#BOOTED[@]} == 0 )); then
    note "sim:     NONE BOOTED"
    verdict DEAD "no booted simulator"
  elif (( ${#BOOTED[@]} == 1 )); then
    UDID="${BOOTED[0]}"
  else
    # Several booted. Taking the first is how this script once printed RIG DEAD for a
    # perfectly live rig it had never been pointed at (2026-08-03). Derive it instead:
    # ours is the sim connected to the Metro that serves this repo. If that does not
    # single one out, refuse - a wrong sim produces a confident, false verdict.
    if [[ -n "$METRO_FOR_REPO" ]]; then
      matched="$(printf '%s' "$SIM_PAIRS" | awk -v p="$METRO_FOR_REPO" '$1==p {print $2}' | sort -u)"
      if [[ "$(printf '%s\n' "$matched" | grep -c .)" -eq 1 ]]; then
        UDID="$matched"
        note "sim:     resolved via Metro :$METRO_FOR_REPO (not 'the booted one' - ${#BOOTED[@]} are booted)"
      fi
    fi
    if [[ -z "$UDID" ]]; then
      echo >&2
      echo "CANNOT TELL WHICH SIMULATOR IS YOURS - ${#BOOTED[@]} booted, none tied to this repo's Metro." >&2
      echo "This is NOT a dead rig; it is a question. Re-run with --udid (or export SIM_UDID). Booted:" >&2
      for i in "${!BOOTED[@]}"; do
        p="$(printf '%s' "$SIM_PAIRS" | awk -v u="${BOOTED[$i]}" '$2==u {printf ":%s ", $1}')"
        echo "  ${BOOTED[$i]}  ${BOOTED_NAMES[$i]}  metro ${p:-none}" >&2
      done
      printf '  %s\n' "${NOTES[@]+"${NOTES[@]}"}" >&2
      exit 2
    fi
  fi
fi
note "sim:     $UDID"

APP="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  verdict DEAD "$BUNDLE_ID is not installed on $UDID"
fi
note "app:     $APP"

# Embedded bundle = a Release build that reads JS from inside the .app and ignores Metro
# entirely. Not proof on its own (a Debug build still prefers Metro), so it is recorded
# as a suspect and only named as the cause if the marker never arrives.
EMBEDDED=""
if [[ -f "$APP/main.jsbundle" ]]; then
  EMBEDDED=1
  note "SUSPECT: $APP/main.jsbundle exists -> looks like a Release build (JS frozen at build time)"
else
  note "jsbundle: absent (Debug build - pulls JS from Metro)"
fi

# --- Metro port ------------------------------------------------------------------------
# Firing a reload at a guessed port would poke a Metro that belongs to somebody else -
# another session, another worktree. Refuse instead of guessing.
if [[ -z "$PORT" ]]; then
  if [[ -z "$METRO_FOR_REPO" ]]; then
    if [[ -n "$WEDGED_METRO" ]]; then
      verdict DEAD "Metro on :$WEDGED_METRO is WEDGED - it still holds the port for $REPO but does not answer packager-status:running, so the app finds no packager. Restart that Metro; do not go looking for a broken build."
    fi
    verdict DEAD "no Metro is serving $REPO. Start one (or pass --port if you know the app talks to another tree's Metro on purpose)."
  fi
  PORT="$METRO_FOR_REPO"
elif [[ -n "$PORT_EXPLICIT" && -z "$METRO_FOR_REPO" ]]; then
  note "WARN:    no Metro serves this repo; using :$PORT as told - it may belong to another session"
fi

# --- marker --------------------------------------------------------------------------
MARKER="RIGCHECK_$(date +%s)_$$"
BACKUP="$(mktemp -t rigcheck)"
# Timestamp reference for "did a crash report appear during THIS run": created here, a
# moment before the app is launched, so the comparison needs no clock arithmetic.
CRASH_REF="$(mktemp -t rigcheck-crashref)"
cp "$ENTRY_PATH" "$BACKUP"

restore() {
  if [[ -f "$BACKUP" ]]; then
    cp "$BACKUP" "$ENTRY_PATH" && rm -f "$BACKUP"
    if grep -q 'RIGCHECK_' "$ENTRY_PATH" 2>/dev/null; then
      echo "!! FAILED TO RESTORE $ENTRY_PATH - remove the RIGCHECK_ line by hand" >&2
    fi
  fi
}
trap restore EXIT INT TERM

# a previous run killed mid-flight would have left its own line behind
if grep -q 'RIGCHECK_' "$BACKUP"; then
  note "WARN:    stale RIGCHECK_ line in $ENTRY - stripping it"
  grep -v 'RIGCHECK_' "$BACKUP" > "$BACKUP.clean" && mv "$BACKUP.clean" "$BACKUP"
fi

{ echo "console.log('$MARKER');"; cat "$BACKUP"; } > "$ENTRY_PATH"

# --- is the app even running? --------------------------------------------------------
# "No marker" has two very different causes: the app ran and did not execute your code, or
# the app is not there at all because it died. Without telling them apart, an app that
# aborts at launch (a JS/native version skew after an RN bump is the usual reason - pure
# JS/TS changes cannot abort natively) reads as a mysteriously dead rig; journal sim-rig
# 20260721-f19d cost a session to "the PR's code crashes the app".
APP_PID=""

app_alive() {
  if [[ -n "$APP_PID" ]]; then
    kill -0 "$APP_PID" 2>/dev/null
    return
  fi
  # No PID (the reload trigger never launches anything): ask the simulator's launchd.
  # The trailing bracket keeps com.example.app from matching com.example.app.dev.
  xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
    | grep -qF "UIKitApplication:$BUNDLE_ID["
}

# Path of the newest crash report for THIS bundle newer than the reference file $1, if any.
# `-newer <file>` is POSIX; `-newermt @<epoch>` is a GNU extension that the /usr/bin/find
# every Mac ships rejects outright ("Can't parse date/time: @1786741447").
crash_report_since() {
  local dir="$HOME/Library/Logs/DiagnosticReports" f header
  [[ -d "$dir" && -f "$1" ]] || return 0
  while IFS= read -r f; do
    # Read the header line directly instead of `head -1 | grep`: grep -q exits on the
    # first match, head takes SIGPIPE, and with `set -o pipefail` the pipeline then
    # reports failure - so the pipe version rejects exactly the files that DO match.
    IFS= read -r header < "$f" 2>/dev/null || continue
    case "$header" in
      *"\"bundleID\":\"$BUNDLE_ID\""*) echo "$f"; return 0 ;;
    esac
  done < <(find "$dir" -maxdepth 1 -name '*.ips' -newer "$1" 2>/dev/null | sort -r)
}

# "<indicator> (<signal>)" from a crash report, e.g. "Abort trap: 6 (SIGABRT)".
crash_reason() {
  tail -n +2 "$1" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ind = (d.get("termination") or {}).get("indicator") or ""
sig = (d.get("exception") or {}).get("signal") or ""
print(f"{ind} ({sig})".strip() if ind or sig else "", end="")
' 2>/dev/null
}

# --- did the JS throw while loading? -------------------------------------------------
# An app that is alive, talks to the right Metro and still never logs the marker may have
# thrown while EVALUATING the bundle: imports are hoisted above the marker line, so a module
# that cannot load takes the marker down with it. The usual reason is a native module the
# JS requires that the installed binary does not carry (JS/native skew after a native
# dependency landed in the tree). The redbox text lands in the same log subsystem as
# console.log, so it is readable right here - journal sim-rig 20260820-baf2 is what it
# costs not to: "neither the build nor Metro explains why", read as "not installed", read as
# a 40-minute rebuild, when a newer build already sat in DerivedData.
js_startup_error() {
  local lines pick
  lines="$(SIMCTL_DEVICE="$UDID" "$READ_LOGS" --since "$TS" 2>/dev/null \
    | grep -E 'Invariant Violation|Unhandled JS Exception|\[runtime not ready\]')"
  [[ -n "$lines" ]] || return 0
  # Prefer the line that names the cause. Terminating the previous instance logs its own
  # "[runtime not ready]: ... stopSurface failed" noise BEFORE the new one throws, and
  # the invariant that took the bundle down comes before the "has not been registered"
  # it causes - so: first Invariant/Unhandled, else the first runtime-not-ready line.
  pick="$(printf '%s\n' "$lines" | grep -E 'Invariant Violation|Unhandled JS Exception' | head -1)"
  [[ -n "$pick" ]] || pick="$(printf '%s\n' "$lines" | head -1)"
  printf '%s\n' "$pick" | sed -E 's/.*\[com\.facebook\.react\.log:[^]]*\] //; s/^\[runtime not ready\]: //'
}

# mtime (epoch) of the app bundle's executable = when the installed binary was BUILT.
# `simctl install` copies the product with its timestamps, so this survives the install
# (checked: installed exec and DerivedData product carry the same second).
app_built_epoch() {
  local exe
  exe="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$1/Info.plist" 2>/dev/null)"
  [[ -n "$exe" && -f "$1/$exe" ]] || return 0
  stat -f %m "$1/$exe" 2>/dev/null
}

fmt_epoch() { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null; }

# Simulator products in DerivedData with THIS bundle id, built after the installed binary,
# newest first - each line "<epoch> <path>". A build that already exists is a seconds-long
# `simctl install` (same bundle id = upgrade in place, the data container and the logged-in
# session survive), not a rebuild.
newer_products() {
  local installed="$1" app bid e
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/*-iphonesimulator/*.app; do
    [[ -d "$app" ]] || continue
    bid="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist" 2>/dev/null)"
    [[ "$bid" == "$BUNDLE_ID" ]] || continue
    e="$(app_built_epoch "$app")"
    [[ -n "$e" && "$e" -gt "$installed" ]] || continue
    printf '%s %s\n' "$e" "$app"
  done | sort -rn
}

# --- trigger -------------------------------------------------------------------------
TS="$(date '+%Y-%m-%d %H:%M:%S')"
if [[ "$TRIGGER" == "reload" ]]; then
  curl -s -m 5 "localhost:$PORT/reload" >/dev/null 2>&1
  note "trigger: curl localhost:$PORT/reload"
else
  ARGS=("${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}")
  # A launch of our own replaces whatever the app was started with, so an app that had been
  # pointed at another Metro by hand would silently fall back to its baked-in port here and
  # report a dead rig for a live one. Re-assert the redirect instead.
  if [[ -n "$AUTO_JSLOCATION" ]] && ! printf '%s\n' "${ARGS[@]+"${ARGS[@]}"}" | grep -qx -- '-RCT_jsLocation'; then
    ARGS+=(-RCT_jsLocation "localhost:$PORT")
  fi
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  # `simctl launch` answers "<bundle-id>: <pid>"; that pid is a real host process (the
  # simulator runs apps on the host), so `kill -0` is all it takes to ask if it is alive.
  LAUNCH_OUT="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} 2>&1)" || true
  case "${LAUNCH_OUT##*: }" in
    ''|*[!0-9]*) : ;;
    *) APP_PID="${LAUNCH_OUT##*: }" ;;
  esac
  if (( ${#ARGS[@]} )); then
    note "trigger: terminate + launch (cold start) with ${ARGS[*]}"
    note "         those launch arguments live for THIS launch only - a plain simctl launch drops them"
  else
    note "trigger: terminate + launch (cold start)"
  fi
fi

# --- read the marker back ------------------------------------------------------------
FOUND=""
APP_DIED=""
WAITED=0
# Only a process seen alive can be seen to die - otherwise "not running" is the ordinary
# case of an app that was never started, which the verdicts below already cover.
ALIVE_AT_START=""
app_alive && ALIVE_AT_START=1
while (( WAITED < TIMEOUT )); do
  sleep 2; WAITED=$((WAITED + 2))
  if SIMCTL_DEVICE="$UDID" "$READ_LOGS" --since "$TS" --grep "$MARKER" 2>/dev/null | grep -q "$MARKER"; then
    FOUND=1; break
  fi
  if [[ -n "$ALIVE_AT_START" ]] && ! app_alive; then
    APP_DIED=1; break
  fi
done

restore
trap - EXIT INT TERM
# The reference file outlives restore() - the crash lookup below still needs it - so it
# gets its own cleanup covering every exit path, verdicts included.
trap 'rm -f "$CRASH_REF"' EXIT INT TERM
# leave the app running marker-free code, best effort
curl -s -m 5 "localhost:$PORT/reload" >/dev/null 2>&1

if [[ -n "$FOUND" ]]; then
  note "marker:  $MARKER seen in the app log after ${WAITED}s"
  verdict OK ""
fi

if [[ -n "$APP_DIED" ]]; then
  note "marker:  $MARKER never appeared - the app process is gone (checked after ${WAITED}s)"
  # ReportCrash writes the .ips a second or two AFTER the process is gone, so looking once
  # at the moment of death finds nothing and makes a real crash look like an outside kill.
  # A few seconds of slack on the cutoff: -newermt wants the file STRICTLY newer, and the
  # report lands in the same second the run started, so an exact cutoff misses it every time.
  REPORT=""
  for _ in $(seq 1 8); do
    REPORT="$(crash_report_since "$CRASH_REF")"
    [[ -n "$REPORT" ]] && break
    sleep 1
  done
  if [[ -n "$REPORT" ]]; then
    REASON="$(crash_reason "$REPORT")"
    note "crash:   ${REASON:-crash report written, reason not parsed}"
    note "         $REPORT"
  else
    note "crash:   no crash report for $BUNDLE_ID since the launch - it may have been"
    note "         terminated from outside (another session, Simulator.app, simctl)."
  fi
  verdict DEAD "the app TERMINATED instead of running your code - this is not a rig problem to debug through the log. If it aborts natively, suspect a JS/native version skew first: pure JS/TS changes cannot abort natively, so reinstall node_modules and rebuild the app before blaming the branch."
fi

note "marker:  $MARKER NEVER appeared (waited ${TIMEOUT}s)"
if [[ -n "$EMBEDDED" ]]; then
  verdict DEAD "the app never ran your code - it has an embedded main.jsbundle (Release build). Rebuild with a Debug configuration."
elif [[ -n "$WEDGED_METRO" && -z "$METRO_FOR_REPO" ]]; then
  verdict DEAD "the app never ran your code - Metro on :$WEDGED_METRO is WEDGED (holds the port, does not answer packager-status:running). Restart that Metro."
elif [[ -z "$METRO_FOR_REPO" ]]; then
  verdict DEAD "the app never ran your code - no Metro is serving $REPO. Start one on the port the app expects (:$PORT)."
else
  JS_ERR="$(js_startup_error)"
  if [[ -n "$JS_ERR" ]]; then
    note "js-error: $JS_ERR"
    case "$JS_ERR" in
      *"could not be found"*|*TurboModule*)
        # A module the JS asks for is not in the native binary. Say how old the binary is
        # against this tree's native dependencies, and whether a usable build already exists.
        BUILT="$(app_built_epoch "$APP")"
        [[ -n "$BUILT" ]] && note "binary:  built $(fmt_epoch "$BUILT") ($APP)"
        DEP_COMMIT="$(git -C "$REPO" log -1 --format='%ct %h %cs' -- ios/Podfile.lock package.json 2>/dev/null)"
        if [[ -n "$DEP_COMMIT" ]]; then
          DEP_EPOCH="${DEP_COMMIT%% *}"
          note "native deps of this tree last changed: ${DEP_COMMIT#* } (ios/Podfile.lock, package.json)"
          if [[ -n "$BUILT" && "$DEP_EPOCH" -gt "$BUILT" ]]; then
            note "         => the installed binary PREDATES that change in this tree's history - it was built"
            note "            without the module unless it came off a branch that already carried it"
          fi
        fi
        NEWER="$(newer_products "${BUILT:-0}")"
        if [[ -n "$NEWER" ]]; then
          note "newer builds of $BUNDLE_ID already in DerivedData (newest first):"
          while read -r e p; do
            note "         $(fmt_epoch "$e")  $p"
          done <<< "$NEWER"
          FIRST="${NEWER%%$'\n'*}"; FIRST="${FIRST#* }"
          note "         install one in seconds, keeping the data container (login survives):"
          note "         xcrun simctl install $UDID \"$FIRST\""
          note "         (a build from before the native-dep change most likely lacks the module too -"
          note "          prefer one built after it, or from the branch that introduced it)"
        else
          note "         no newer build of $BUNDLE_ID in DerivedData - pod install + one build is the move"
        fi
        verdict DEAD "the app is ALIVE but its JS threw while loading the bundle, before your code could run - a module it requires is missing from the NATIVE binary (JS/native skew: the JS is from this tree, the binary is older). This is not 'not installed' and not a Metro problem: install a newer build (see notes), or rebuild once; do not debug the branch."
        ;;
    esac
    verdict DEAD "the app is ALIVE but its JS threw while loading the bundle, before your code could run (see js-error above). Fix that error first - the rig cannot be judged through it."
  fi
  if [[ "$TRIGGER" == "relaunch" && -z "$AUTO_JSLOCATION" ]]; then
    note "HINT:    --no-jslocation was given, so this launch could not repoint the app. If the"
    note "         app had been started by hand with -RCT_jsLocation, this run just undid it."
  fi
  note "HINT:    if the app needs launch arguments to reach this Metro, pass them with --launch-arg"
  note "         (a launch here replaces the one that started the app, arguments included)."
  verdict DEAD "the app never ran your code, and neither the build nor Metro explains why. Check that the app is foregrounded and that it is talking to :$PORT."
fi
