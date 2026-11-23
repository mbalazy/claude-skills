#!/usr/bin/env bash
# native-build.sh - build a NATIVE app (Swift / Kotlin, no Metro) from the tree under test,
# install it, and record which tree content the installed artifact came from, so that
# native-rig-check.sh (and rig-check.sh / android-rig-check.sh, which hand a native config
# to it) can prove it later by content instead of by a date. Mechanism: lib/native.sh.
#
# Usage:
#   native-build.sh [options]
#     --repo PATH       checkout to build (default: git root of cwd)
#     --udid UDID       iOS simulator to install on (default: $SIM_UDID, else the only
#                       booted one; several booted and none named = exit 2 with the list)
#     --serial SERIAL   Android emulator or phone (default: $ANDROID_SERIAL, else the only
#                       attached device; several and none named = exit 2)
#     --no-install      build and record only
#     --install-only    no build: install the artifact already on disk - only when it is
#                       still the recorded build of this exact tree content (refused otherwise)
#
# Reads from <repo>/.simulator-verify/config.md (a worktree without one reads the main
# worktree's): `app type` (must be `native`), `build` (the command, run from the repo
# root), `artifact` (the built .app or .apk), `bundle id` / `android package`.
#
# Run it under a timeout that fits a cold build (a native iOS build can take 10+ minutes).
#
# Exit: 0 = built (and installed, unless --no-install), the record written.
#       1 = the build failed, the tree changed during the build, the artifact is missing
#           or is another app, the install failed or did not land byte for byte.
#       2 = could not start: a bad flag, a config gap it names, an ambiguous device.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/native.sh"

REPO=""; UDID="${SIM_UDID:-}"; INSTALL=1; BUILD=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--udid|--serial) [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --repo)         REPO="$2"; shift 2 ;;
    --udid)         UDID="$2"; shift 2 ;;
    --serial)       export ANDROID_SERIAL="$2"; shift 2 ;;
    --no-install)   INSTALL=""; shift ;;
    --install-only) BUILD=""; shift ;;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BUILD" ] || [ -n "$INSTALL" ] || { echo "--install-only and --no-install together do nothing" >&2; exit 2; }

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || { echo "not in a git repo and no --repo given" >&2; exit 2; }
fi
[ -d "$REPO" ] || { echo "--repo is not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd -P)"

# --- config ------------------------------------------------------------------------------
CONFIG="$(nv_config_for "$REPO")"
[ -f "$CONFIG" ] || { echo "no config: $CONFIG does not exist - copy $HERE/../references/config-template.md there and fill its native lines" >&2; exit 2; }
TYPE="$(nv_app_type "$CONFIG")"
[ "$TYPE" = native ] || { echo "$CONFIG has no '- **app type**: \`native\`' line${TYPE:+ (it says '$TYPE')} - this script is for native apps only; an RN / Expo app runs from Metro (rig-check.sh)" >&2; exit 2; }
BUILD_CMD="$(nv_config_line "$CONFIG" build)"
ART_CFG="$(nv_config_line "$CONFIG" artifact)"
[ -n "$ART_CFG" ] || { echo "no '- **artifact**: \`path\`' line in $CONFIG - name the built .app or .apk (repo-relative or absolute)" >&2; exit 2; }
ARTIFACT="$(nv_abs "$REPO" "$ART_CFG")"
ARTIFACT="${ARTIFACT%/}"
PLATFORM="$(nv_platform_of "$ARTIFACT")"
[ -n "$PLATFORM" ] || { echo "the artifact line in $CONFIG names '$ART_CFG' - expected a .app (iOS simulator) or an .apk (Android)" >&2; exit 2; }
APP_ID="$(nv_app_id "$CONFIG" "$PLATFORM")"
[ -n "$APP_ID" ] || { echo "no app id in $CONFIG - add '- **bundle id**: \`com.example.app\`'$([ "$PLATFORM" = android ] && echo " (or an 'android package' line)")" >&2; exit 2; }
[ -n "$BUILD" ] && [ -z "$BUILD_CMD" ] && { echo "no '- **build**: \`command\`' line in $CONFIG - the command that produces $ART_CFG, run from the repo root" >&2; exit 2; }
RECORD="$(nv_record_path "$REPO")" || { echo "$REPO is not a git checkout - the build record lives in its git dir" >&2; exit 2; }

echo "repo:     $REPO @ $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '(no commit)')"
echo "app:      $APP_ID ($PLATFORM)"
echo "artifact: $ARTIFACT"

# --- device (before the build: a question about it should not cost a build) ----------------
SERIAL=""
if [ -n "$INSTALL" ]; then
  if [ "$PLATFORM" = ios ]; then
    if [ -z "$UDID" ]; then
      BOOTED="$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([0-9A-Fa-f-]{36}\) \(Booted\)' | grep -oE '[0-9A-Fa-f-]{36}' || true)"
      N="$(printf '%s\n' "$BOOTED" | grep -c . || true)"
      if [ "$N" -eq 0 ]; then
        echo "no booted simulator - boot the config's simulator (xcrun simctl boot <udid>) or pass --udid" >&2; exit 1
      elif [ "$N" -gt 1 ]; then
        echo "$N simulators are booted and neither --udid nor SIM_UDID names one - refusing to guess. Booted:" >&2
        xcrun simctl list devices booted 2>/dev/null | grep Booted | sed 's/^ */  /' >&2
        exit 2
      fi
      UDID="$BOOTED"
    fi
    echo "device:   simulator $UDID"
  else
    . "$HERE/android-lib.sh"
    [ -n "$ADB" ] || exit 1
    SERIAL="$(android_serial)" || exit $?
    android_assert_ready "$SERIAL"
    echo "device:   $SERIAL ($(android_name "$SERIAL"))"
  fi
fi

# --- build -------------------------------------------------------------------------------
if [ -n "$BUILD" ]; then
  FP="$(nv_fingerprint "$REPO")"
  echo "tree:     fingerprint ${FP:0:12}"
  echo "build:    $BUILD_CMD"
  echo
  T0="$(date +%s)"
  (cd "$REPO" && bash -c "$BUILD_CMD")
  RC=$?
  T1="$(date +%s)"
  echo
  [ "$RC" -eq 0 ] || { echo "BUILD FAILED (exit $RC after $((T1 - T0)) s) - nothing installed, the record is unchanged"; exit 1; }
  FP_AFTER="$(nv_fingerprint "$REPO")"
  if [ "$FP_AFTER" != "$FP" ]; then
    echo "BUILD NOT RECORDED: the tree changed while it built (fingerprint ${FP:0:12} -> ${FP_AFTER:0:12}) -"
    echo "  the artifact cannot be tied to one tree. Build again once nothing edits the checkout."
    exit 1
  fi
  [ -e "$ARTIFACT" ] || { echo "BUILD PRODUCED NO ARTIFACT at $ARTIFACT - fix the 'artifact' line in $CONFIG"; exit 1; }
  if [ "$PLATFORM" = ios ]; then
    BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ARTIFACT/Info.plist" 2>/dev/null || true)"
    [ "$BID" = "$APP_ID" ] || { echo "WRONG ARTIFACT: $ARTIFACT is '$BID', the config's app is '$APP_ID'"; exit 1; }
  fi
  ART_SHA="$(nv_hash_local "$ARTIFACT")"
  nv_record_write "$RECORD" "platform=$PLATFORM" "app_id=$APP_ID" "artifact=$ARTIFACT" \
    "fingerprint=$FP" "artifact_sha=$ART_SHA" "head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)" \
    "built_at=$T1" "build_seconds=$((T1 - T0))" "device=" "installed_at=" \
    || { echo "could not write the build record $RECORD" >&2; exit 1; }
  echo "BUILT in $((T1 - T0)) s - artifact ${ART_SHA:0:12}, tree ${FP:0:12}"
else
  # --install-only: the artifact on disk must still be the recorded build of THIS content.
  # A DerivedData or build/ directory shared with another checkout gets overwritten by
  # that checkout's builds, and installing it here would be the exact lie this prevents.
  FP="$(nv_fingerprint "$REPO")"
  R_FP="$(nv_record_get "$RECORD" fingerprint)"
  R_SHA="$(nv_record_get "$RECORD" artifact_sha)"
  [ -n "$R_FP" ] || { echo "INSTALL REFUSED: no build recorded for this checkout - run without --install-only"; exit 1; }
  [ "$R_FP" = "$FP" ] || { echo "INSTALL REFUSED: the tree changed since the recorded build (${R_FP:0:12} -> ${FP:0:12}) - run without --install-only"; exit 1; }
  ART_SHA="$(nv_hash_local "$ARTIFACT")"
  [ "$ART_SHA" = "$R_SHA" ] || { echo "INSTALL REFUSED: $ARTIFACT is no longer the recorded build (${R_SHA:0:12}, on disk ${ART_SHA:0:12}) - another build overwrote it; run without --install-only"; exit 1; }
  echo "artifact: still the recorded build of this tree (${ART_SHA:0:12})"
fi

[ -n "$INSTALL" ] || { echo "not installed (--no-install). Record: $RECORD"; exit 0; }

# --- install + proof that it landed byte for byte -------------------------------------------
if [ "$PLATFORM" = ios ]; then
  xcrun simctl install "$UDID" "$ARTIFACT" || { echo "INSTALL FAILED on $UDID"; exit 1; }
  INST="$(xcrun simctl get_app_container "$UDID" "$APP_ID" app 2>/dev/null || true)"
  INST_SHA="$([ -n "$INST" ] && nv_hash_local "$INST")"
  DEVICE="$UDID"
else
  OUT="$("$ADB" -s "$SERIAL" install -r "$ARTIFACT" 2>&1 </dev/null | tr -d '\r')"
  if ! printf '%s\n' "$OUT" | grep -q '^Success'; then
    echo "INSTALL FAILED on $SERIAL:"
    printf '%s\n' "$OUT" | tail -3 | sed 's/^/  /'
    if printf '%s\n' "$OUT" | grep -q 'UPDATE_INCOMPATIBLE'; then
      echo "  the installed app is signed with another key. Uninstalling it deletes its data (a logged-in"
      echo "  session, test fixtures) - a person decides that: adb -s $SERIAL uninstall $APP_ID"
    fi
    exit 1
  fi
  P="$("$ADB" -s "$SERIAL" shell pm path "$APP_ID" </dev/null 2>/dev/null | tr -d '\r' | sed -n 's/^package://p')"
  INST_SHA=""
  if [ "$(printf '%s\n' "$P" | grep -c .)" -eq 1 ]; then
    INST_SHA="$("$ADB" -s "$SERIAL" shell sha256sum "$P" </dev/null 2>/dev/null | tr -d '\r' | cut -d' ' -f1)"
  fi
  DEVICE="$SERIAL"
fi
if [ "$INST_SHA" != "$ART_SHA" ]; then
  echo "INSTALL DID NOT LAND: $APP_ID on $DEVICE hashes ${INST_SHA:-(nothing)}, the artifact ${ART_SHA:0:12} -"
  echo "  is the artifact another app? (the config's app id is $APP_ID)"
  exit 1
fi
NOW="$(date +%s)"
nv_record_write "$RECORD" \
  "platform=$PLATFORM" "app_id=$APP_ID" "artifact=$ARTIFACT" "fingerprint=$FP" "artifact_sha=$ART_SHA" \
  "head=$(nv_record_get "$RECORD" head)" "built_at=$(nv_record_get "$RECORD" built_at)" \
  "build_seconds=$(nv_record_get "$RECORD" build_seconds)" "device=$DEVICE" "installed_at=$NOW" \
  || { echo "could not write the build record $RECORD" >&2; exit 1; }
echo "INSTALLED on $DEVICE - byte for byte the build of this tree (${ART_SHA:0:12}). Next: $([ "$PLATFORM" = android ] && echo android-rig-check.sh || echo rig-check.sh)"
exit 0
