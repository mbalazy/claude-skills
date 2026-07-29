#!/usr/bin/env bash
# compare.sh — side-by-side montage of Figma reference vs simulator render
#
# Build this at the END / on request (not every iteration) and send to the user for sign-off.
#
# Usage:
#   compare.sh <figma.png> <sim.png> <out.png> [crop-geometry] [target-width]
#
#   crop-geometry  optional ImageMagick crop applied to the SIM shot to isolate the
#                  component, e.g. '402x300+0+120' (WxH+X+Y in logical px). Omit for full screen.
#   target-width   each panel resized to this width before appending (default 360).
#
# Examples:
#   compare.sh figma.png sim.png cmp.png                 # full-screen side-by-side
#   compare.sh figma.png sim.png cmp.png '402x300+0+120' # crop sim to a band first

set -euo pipefail

FIGMA="${1:?figma png required}"
SIM="${2:?sim png required}"
OUT="${3:?output png required}"
CROP="${4:-}"
W="${5:-360}"

command -v magick >/dev/null || { echo "magick (ImageMagick) not found"; exit 1; }

SIMSRC="$SIM"
if [[ -n "$CROP" ]]; then
  TMP="$(mktemp -t cmppp).png"
  trap 'rm -f "$TMP"' EXIT
  magick "$SIM" -crop "$CROP" +repage "$TMP"
  SIMSRC="$TMP"
fi

# label each panel, resize to common width, append horizontally
magick \
  \( "$FIGMA" -resize "${W}x" -gravity North -background '#222' -splice 0x22 \
     -annotate +0+4 'FIGMA' \) \
  \( "$SIMSRC" -resize "${W}x" -gravity North -background '#222' -splice 0x22 \
     -annotate +0+4 'RENDER' \) \
  +append "$OUT"

echo "wrote $OUT — send to user for sign-off"
