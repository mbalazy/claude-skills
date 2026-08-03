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
#     --timeout N        seconds to wait for the marker (default 30)
#
# Exit: 0 = RIG OK, 1 = RIG DEAD, 2 = bad usage.
# The marker is always removed again, including on Ctrl-C or an error mid-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ_LOGS="$SCRIPT_DIR/read-rn-logs.sh"

REPO=""; BUNDLE_ID=""; ENTRY="index.js"; UDID="${SIM_UDID:-}"; PORT=""; PORT_EXPLICIT=""
TRIGGER="relaunch"; TIMEOUT=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      REPO="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --entry)     ENTRY="$2"; shift 2 ;;
    --udid)      UDID="$2"; shift 2 ;;
    --port)      PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --reload)    TRIGGER="reload"; shift ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
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
CONFIG="$REPO/.simulator-verify/config.md"
if [[ -z "$BUNDLE_ID" && -f "$CONFIG" ]]; then
  BUNDLE_ID="$(grep -m1 -i 'bundle id' "$CONFIG" | grep -oE '`[A-Za-z0-9._-]+`' | head -1 | tr -d '`')"
fi
[[ -z "$BUNDLE_ID" ]] && { echo "no bundle id (not in $CONFIG either) - pass --bundle-id" >&2; exit 2; }
note "bundle:  $BUNDLE_ID"

# --- Metro listeners -------------------------------------------------------------------
# Who listens where, and on which tree. A Metro serving a different worktree silently
# feeds the app someone else's code, which is exactly the failure this script catches.
# This runs BEFORE the simulator is resolved on purpose: when several sims are booted, the
# Metro serving this repo is the only thing that says which of them is ours.
METRO_FOR_REPO=""
SIM_PAIRS=""   # lines "<port> <udid>": simulator apps connected to that Metro
while read -r cmd pid port; do
  [[ -z "$pid" ]] && continue
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | cut -c2-)"
  if [[ "$cwd" == "$REPO" ]]; then
    METRO_FOR_REPO="$port"
    note "listen:  :$port $cmd pid $pid  <- serves this repo"
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
    verdict DEAD "no Metro is serving $REPO. Start one (or pass --port if you know the app talks to another tree's Metro on purpose)."
  fi
  PORT="$METRO_FOR_REPO"
elif [[ -n "$PORT_EXPLICIT" && -z "$METRO_FOR_REPO" ]]; then
  note "WARN:    no Metro serves this repo; using :$PORT as told - it may belong to another session"
fi

# --- marker --------------------------------------------------------------------------
MARKER="RIGCHECK_$(date +%s)_$$"
BACKUP="$(mktemp -t rigcheck)"
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

# --- trigger -------------------------------------------------------------------------
TS="$(date '+%Y-%m-%d %H:%M:%S')"
if [[ "$TRIGGER" == "reload" ]]; then
  curl -s -m 5 "localhost:$PORT/reload" >/dev/null 2>&1
  note "trigger: curl localhost:$PORT/reload"
else
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  note "trigger: terminate + launch (cold start)"
fi

# --- read the marker back ------------------------------------------------------------
FOUND=""
WAITED=0
while (( WAITED < TIMEOUT )); do
  sleep 2; WAITED=$((WAITED + 2))
  if SIMCTL_DEVICE="$UDID" "$READ_LOGS" --since "$TS" --grep "$MARKER" 2>/dev/null | grep -q "$MARKER"; then
    FOUND=1; break
  fi
done

restore
trap - EXIT INT TERM
# leave the app running marker-free code, best effort
curl -s -m 5 "localhost:$PORT/reload" >/dev/null 2>&1

if [[ -n "$FOUND" ]]; then
  note "marker:  $MARKER seen in the app log after ${WAITED}s"
  verdict OK ""
fi

note "marker:  $MARKER NEVER appeared (waited ${TIMEOUT}s)"
if [[ -n "$EMBEDDED" ]]; then
  verdict DEAD "the app never ran your code - it has an embedded main.jsbundle (Release build). Rebuild with a Debug configuration."
elif [[ -z "$METRO_FOR_REPO" ]]; then
  verdict DEAD "the app never ran your code - no Metro is serving $REPO. Start one on the port the app expects (:$PORT)."
else
  verdict DEAD "the app never ran your code, and neither the build nor Metro explains why. Check that the app is foregrounded and that :$PORT is the port baked into this build."
fi
