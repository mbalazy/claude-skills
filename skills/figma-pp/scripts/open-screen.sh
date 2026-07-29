#!/usr/bin/env bash
# open-screen.sh — deterministically reach an app screen via deep link on the iOS simulator
#
# mobile MCP blocks custom URL schemes directly, so we go through `xcrun simctl openurl`.
# This is the single biggest time-saver vs clicking through navigation.
#
# Usage:
#   open-screen.sh <scheme> <route> [udid]
#
# Examples:
#   open-screen.sh myapp paywall
#   open-screen.sh myapp 'item/123?page=4' ABCD-1234-UDID
#
# If no udid is given, targets the currently booted simulator.
# Falls back with a clear message if no simulator is booted (then use manual nav via
# mobile_list_elements_on_screen — tap testIDs, never inline-screenshot coords).

set -euo pipefail

SCHEME="${1:?scheme required (e.g. myapp)}"
ROUTE="${2:?route required (e.g. paywall)}"
UDID="${3:-booted}"

command -v xcrun >/dev/null || { echo "xcrun not found (Xcode command line tools)"; exit 1; }

if [[ "$UDID" == "booted" ]]; then
  if ! xcrun simctl list devices booted | grep -q '(Booted)'; then
    echo "No booted simulator. Boot one, or pass a udid, or fall back to manual nav." >&2
    exit 1
  fi
fi

URL="${SCHEME}:///${ROUTE}"
echo "opening $URL on $UDID"
xcrun simctl openurl "$UDID" "$URL"
echo "ok — now mobile_save_screenshot and verify"
