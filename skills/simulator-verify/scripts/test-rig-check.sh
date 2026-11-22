#!/usr/bin/env bash
# test-rig-check.sh - regression test of the two rig checks' setup paths, with no
# simulator, emulator, Metro or app: xcrun, xcode-select, lsof, curl and adb are stubs.
#
# What it covers is everything a rig check decides BEFORE it touches a device, plus one
# stubbed happy path through rig-check.sh: config found or not, the bundle id / package
# line, the entry file, a Mac without full Xcode, several simulators, an app that is not
# installed, no Metro, no adb. What a stub cannot answer (a real marker in a real log, a
# real install) is regress.sh's and android-regress.sh's job on a live device.
#
# Usage: test-rig-check.sh [-v]     -v prints each case's output
# Exit:  0 all cases pass, 1 a case failed.
#
# Runs in a temp dir; touches nothing outside it (HOME is the temp dir too).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
VERBOSE=""; [[ "${1:-}" == "-v" ]] && VERBOSE=1

T="$(mktemp -d -t test-rig-check)"
APP_PID=""
cleanup() { [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# --- a copy of the skill whose log reader is a stub -------------------------------------
mkdir -p "$T/skill/scripts" "$T/bin" "$T/home"
cp "$HERE/rig-check.sh" "$HERE/android-rig-check.sh" "$HERE/android-lib.sh" "$HERE/android_prefs.py" "$T/skill/scripts/"
[[ -d "$SKILL/lib" ]] && cp -R "$SKILL/lib" "$T/skill/lib"
[[ -d "$SKILL/references" ]] && cp -R "$SKILL/references" "$T/skill/references"
cat > "$T/skill/scripts/read-rn-logs.sh" <<'EOF'
#!/bin/bash
# stub: the app "logs" the marker that rig-check.sh wrote into the entry file
[[ -n "${STUB_LOGS_MARKER:-}" && -f "${STUB_ENTRY_FILE:-}" ]] && grep -o 'RIGCHECK_[0-9_]*' "$STUB_ENTRY_FILE"
exit 0
EOF
chmod +x "$T/skill/scripts/"*.sh

# --- stubs ------------------------------------------------------------------------------
cat > "$T/bin/xcrun" <<'EOF'
#!/bin/bash
[[ "$1" == simctl ]] || { echo "xcrun stub: $*" >&2; exit 1; }
if [[ -n "${STUB_NO_SIMCTL:-}" ]]; then
  echo 'xcrun: error: unable to find utility "simctl", not a developer tool or in PATH' >&2; exit 72
fi
shift
case "$1" in
  list) printf '== Devices ==\n'; [[ -n "${STUB_BOOTED:-}" ]] && printf '%s\n' "$STUB_BOOTED" ;;
  get_app_container) [[ -n "${STUB_APP:-}" ]] && echo "$STUB_APP" || exit 2 ;;
  terminate) ;;
  launch) echo "$3: ${STUB_PID:-}" ;;
  spawn) ;;
esac
exit 0
EOF
cat > "$T/bin/xcode-select" <<'EOF'
#!/bin/bash
echo "${STUB_DEVDIR:-/Applications/Xcode.app/Contents/Developer}"
EOF
cat > "$T/bin/lsof" <<'EOF'
#!/bin/bash
case "$*" in
  *"-sTCP:LISTEN"*)
    echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
    [[ -n "${STUB_METRO_PORT:-}" ]] && echo "node 4321 u 20u IPv6 0x0 0t0 TCP *:${STUB_METRO_PORT} (LISTEN)" ;;
  *"-d cwd"*) printf 'p4321\nfcwd\nn%s\n' "${STUB_METRO_CWD:-/nowhere}" ;;
esac
exit 0
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
case "$*" in *"/status"*) echo "${STUB_STATUS:-packager-status:running}" ;; esac
exit 0
EOF
cat > "$T/bin/adb" <<'EOF'
#!/bin/bash
# no device attached
case "$*" in *devices*) echo "List of devices attached" ;; esac
exit 0
EOF
chmod +x "$T/bin/"*
# python3 and git only, through their own directory - never the rest of PATH (an adb there
# would defeat the "no adb" case).
mkdir -p "$T/tools"
ln -s "$(command -v python3)" "$T/tools/python3"
ln -s "$(command -v git)" "$T/tools/git"
BASE_PATH="$T/bin:$T/tools:/usr/bin:/bin:/usr/sbin:/sbin"
NOADB_PATH="$T/nobin:$T/tools:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$T/nobin"
for s in xcrun xcode-select lsof curl; do ln -s "$T/bin/$s" "$T/nobin/$s"; done

# --- repos ------------------------------------------------------------------------------
# mkrepo <files...> - a fresh git repo with an initial commit; prints its path.
# A file spec "path=content" writes content; a bare path writes a line of JS.
# (mktemp, not a counter: it runs in a $(...) subshell, where a counter never advances.)
mkrepo() {
  local r f
  r="$(mktemp -d "$T/repo.XXXXXX")" && git -C "$r" init -q
  for f in "$@"; do
    mkdir -p "$(dirname "$r/${f%%=*}")"
    if [[ "$f" == *=* ]]; then printf '%s\n' "${f#*=}" > "$r/${f%%=*}"; else echo "console.log('app');" > "$r/$f"; fi
  done
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" -c user.name=t -c user.email=t@example.com commit -qm init --allow-empty
  (cd "$r" && pwd -P)
}
template() { mkdir -p "$1/.simulator-verify"; cp "$SKILL/references/config-template.md" "$1/.simulator-verify/config.md"; }
config() { mkdir -p "$1/.simulator-verify"; printf '%s\n' "${@:2}" > "$1/.simulator-verify/config.md"; }

SIM_A="11111111-2222-3333-4444-555555555555"
SIM_B="22222222-2222-2222-2222-222222222222"
mkdir -p "$T/app/Demo.app"

# --- runner -----------------------------------------------------------------------------
PASS=0; FAIL=0
# check <name> <expected exit> <regex the output must match> <script> [args...]
# The environment for the case comes from the STUB_* / PATH variables set before the call;
# CASE_NOT, when set, is a regex the output must NOT match.
check() {
  local name="$1" want="$2" re="$3" script="$4"; shift 4
  local out rc
  out="$(cd "$T" && env -i HOME="$T/home" PATH="${CASE_PATH:-$BASE_PATH}" TMPDIR="$T" \
          ${CASE_ENV[@]+"${CASE_ENV[@]}"} bash "$T/skill/scripts/$script" "$@" 2>&1)"
  rc=$?
  if [[ "$rc" == "$want" ]] && grep -qE -- "$re" <<< "$out" \
     && { [[ -z "${CASE_NOT:-}" ]] || ! grep -qE -- "$CASE_NOT" <<< "$out"; }; then
    PASS=$((PASS + 1)); echo "PASS  $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL  $name (exit $rc, want $want; want output matching: $re${CASE_NOT:+, and not: $CASE_NOT})"
    printf '%s\n' "$out" | sed 's/^/      | /'
    return
  fi
  [[ -n "$VERBOSE" ]] && printf '%s\n' "$out" | sed 's/^/      | /'
  return 0
}
CASE_ENV=()

# ======================================================================== rig-check.sh
CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)")
OK_ID='- **bundle id**: `com.example.app`'

R="$(mkrepo index.js)"
check "ios: no config at all" 2 \
  "no config: .*/\.simulator-verify/config\.md does not exist .*config-template\.md" rig-check.sh --repo "$R"

R="$(mkrepo index.js)"; template "$R"
check "ios: config is the unfilled template" 2 \
  "the 'bundle id' line in .* is still the template's placeholder" rig-check.sh --repo "$R"

R="$(mkrepo index.js)"; config "$R" "- **bundle id**: com.example.app"
check "ios: bundle id without backticks" 2 \
  "the 'bundle id' line in .* has no id in backticks" rig-check.sh --repo "$R"

R="$(mkrepo index.js)"; config "$R" "- **scheme**: \`MyApp\`"
check "ios: config without a bundle id line" 2 \
  "no 'bundle id' line in .*config\.md" rig-check.sh --repo "$R"

R="$(mkrepo)"; config "$R" "$OK_ID"
check "ios: no index.js, no package.json" 2 \
  "entry file not found: .*/index\.js \(pass --entry" rig-check.sh --repo "$R"

R="$(mkrepo 'package.json={"main": "expo-router/entry"}' app/_layout.tsx)"; config "$R" "$OK_ID"
check "ios: Expo Router app names its root layout" 2 \
  "an Expo Router app\. Mark its root layout instead: pass --entry app/_layout\.tsx" rig-check.sh --repo "$R"

R="$(mkrepo 'package.json={"main": "src/start.js"}')"; config "$R" "$OK_ID"
check "ios: package.json main names a missing file" 2 \
  "package\.json main \('src/start\.js'\) is not a file" rig-check.sh --repo "$R"

R="$(mkrepo index.js)"; config "$R" "$OK_ID"
CASE_ENV=("STUB_NO_SIMCTL=1" "STUB_DEVDIR=/Library/Developer/CommandLineTools")
check "ios: command line tools only, no Xcode" 1 \
  "RIG DEAD: xcrun simctl does not run: the developer directory is the command line tools" rig-check.sh --repo "$R" --timeout 2
CASE_ENV=("STUB_NO_SIMCTL=1")
check "ios: simctl fails with Xcode selected" 1 \
  "RIG DEAD: xcrun simctl list failed" rig-check.sh --repo "$R" --timeout 2

CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)
    Other Sim ($SIM_B) (Booted)")
check "ios: two simulators, none tied to this repo" 2 \
  "CANNOT TELL WHICH SIMULATOR IS YOURS" rig-check.sh --repo "$R" --timeout 2

CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)")
check "ios: app not installed" 1 \
  "RIG DEAD: com\.example\.app is not installed on $SIM_A" rig-check.sh --repo "$R" --timeout 2

CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)")
check "ios: --bundle-id wins over the config line" 1 \
  "RIG DEAD: com\.example\.other is not installed" rig-check.sh --repo "$R" --bundle-id com.example.other --timeout 2

CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)" "STUB_APP=$T/app/Demo.app")
check "ios: no Metro serves the repo" 1 \
  "RIG DEAD: no Metro is serving" rig-check.sh --repo "$R" --timeout 2

sleep 120 & APP_PID=$!
# happy <name> <repo> <entry file the stub app logs from> [args...]
happy() {
  local name="$1" repo="$2" entry="$3"; shift 3
  CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)" "STUB_APP=$T/app/Demo.app" "STUB_METRO_PORT=8081"
            "STUB_METRO_CWD=$repo" "STUB_PID=$APP_PID" "STUB_LOGS_MARKER=1" "STUB_ENTRY_FILE=$repo/$entry")
  check "$name" 0 "RIG OK - the app is running code from $repo" rig-check.sh --repo "$repo" --timeout 6 "$@"
  if grep -q RIGCHECK_ "$repo/$entry"; then
    FAIL=$((FAIL + 1)); echo "FAIL  $name: the marker stayed in $entry"
  else
    PASS=$((PASS + 1)); echo "PASS  $name: $entry restored"
  fi
}
happy "ios: happy path" "$R" index.js

# index.js wins over package.json main: an RN CLI app's bundle starts there.
R2="$(mkrepo index.js 'src/other.js' 'package.json={"main": "src/other.js"}')"; config "$R2" "$OK_ID"
happy "ios: index.js wins over package.json main" "$R2" index.js

R2="$(mkrepo index.ts 'package.json={"main": "index.ts"}')"; config "$R2" "$OK_ID"
happy "ios: Expo app with index.ts" "$R2" index.ts

R2="$(mkrepo 'package.json={"main": "expo-router/entry"}' app/_layout.tsx)"
config "$R2" "$OK_ID" '- **entry**: `app/_layout.tsx` - the root layout (an Expo Router app has no entry file)'
happy "ios: entry line in the config" "$R2" app/_layout.tsx

R2="$(mkrepo index.js app/_layout.tsx)"; config "$R2" "$OK_ID" '- **entry**: `index.js`'
happy "ios: --entry wins over the config line" "$R2" app/_layout.tsx --entry app/_layout.tsx

# A linked worktree has no .simulator-verify/ of its own: the bundle id comes from the main one.
git -C "$R" worktree add -q "$T/wt" >/dev/null 2>&1
WT="$(cd "$T/wt" && pwd -P)"
CASE_ENV=("STUB_BOOTED=    Demo Sim ($SIM_A) (Booted)" "STUB_APP=$T/app/Demo.app" "STUB_METRO_PORT=8081"
          "STUB_METRO_CWD=$WT" "STUB_PID=$APP_PID" "STUB_LOGS_MARKER=1" "STUB_ENTRY_FILE=$WT/index.js")
check "ios: worktree reads the main worktree's config" 0 \
  "read from main worktree" rig-check.sh --repo "$WT" --timeout 6
kill "$APP_PID" 2>/dev/null; APP_PID=""

# ================================================================ android-rig-check.sh
CASE_ENV=("ADB=$T/bin/adb")
OK_PKG='- **android package**: `com.example.app`'

R="$(mkrepo index.js)"; template "$R"
check "android: config is the unfilled template" 2 \
  "the 'android package' line in .* is still the template's placeholder.*or delete that line" android-rig-check.sh --repo "$R"

R="$(mkrepo index.js)"
check "android: no config at all" 2 \
  "no config: .*config\.md does not exist" android-rig-check.sh --repo "$R"

R="$(mkrepo index.js)"; config "$R" "$OK_ID"
check "android: bundle id line serves when there is no android package line" 1 \
  "no Android device attached" android-rig-check.sh --repo "$R"

R="$(mkrepo)"; config "$R" "$OK_PKG"
check "android: no index.js, no package.json" 2 \
  "entry file not found: .*/index\.js \(pass --entry" android-rig-check.sh --repo "$R"

R="$(mkrepo 'package.json={"main": "expo-router/entry"}' src/app/_layout.tsx)"; config "$R" "$OK_PKG"
check "android: Expo Router app names its root layout" 2 \
  "Expo Router app\. Mark its root layout instead: pass --entry src/app/_layout\.tsx" android-rig-check.sh --repo "$R"

R="$(mkrepo 'package.json={"main": "expo-router/entry"}' app/_layout.tsx)"
config "$R" "$OK_PKG" '- **entry**: `app/_layout.tsx`'
check "android: entry line in the config gets past the entry check" 1 \
  "no Android device attached" android-rig-check.sh --repo "$R"

R="$(mkrepo index.ts 'package.json={"main": "index.ts"}')"; config "$R" "$OK_PKG"
check "android: Expo index.ts gets past the entry check" 1 \
  "no Android device attached" android-rig-check.sh --repo "$R"

CASE_ENV=(); CASE_PATH="$NOADB_PATH"; CASE_NOT="no Android device"
check "android: no adb anywhere - one error, the right one" 1 \
  "adb not found" android-rig-check.sh --repo "$R" --package com.example.app
CASE_PATH=""; CASE_NOT=""

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
