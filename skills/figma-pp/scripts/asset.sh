#!/usr/bin/env bash
# asset.sh — Figma asset → transparent, trimmed WebP
#
# Pipeline: (already-downloaded PNG) → floodfill parent bg to alpha → trim → cwebp
# Figma exports bake in the parent background (no alpha), so we floodfill the edges out.
#
# Usage:
#   asset.sh <input.png> <output.webp> [parent-bg-hex] [fuzz%] [quality]
#
# Example:
#   asset.sh /tmp/hero.png apps/expo/assets/hero.webp '#123456' 14 85
#
# Note: download the PNG first (mcp__<figma-server>__download_assets at scale 3 → curl the URL).
# This script handles the cleanup half so it's identical every time.

set -euo pipefail

IN="${1:?input png required}"
OUT="${2:?output webp path required}"
BG="${3:-}"            # parent bg hex, e.g. #123456 — empty = skip floodfill (already transparent)
FUZZ="${4:-14}"        # floodfill tolerance %
Q="${5:-85}"          # cwebp quality

command -v magick >/dev/null || { echo "magick (ImageMagick) not found"; exit 1; }
command -v cwebp  >/dev/null || { echo "cwebp not found (brew install webp)"; exit 1; }

TMP="$(mktemp -t assetpp).png"
trap 'rm -f "$TMP"' EXIT

if [[ -n "$BG" ]]; then
  # flood from each corner so the parent fill becomes transparent, then trim the border
  magick "$IN" -alpha set -bordercolor "$BG" -border 1 -fuzz "${FUZZ}%" \
    -fill none \
    -draw 'alpha 0,0 floodfill' \
    -shave 1x1 "$TMP"
else
  cp "$IN" "$TMP"
fi

# trim transparent margins
magick "$TMP" -trim +repage "$TMP"

cwebp -quiet -q "$Q" "$TMP" -o "$OUT"
echo "wrote $OUT ($(magick identify -format '%wx%h' "$OUT"))"
