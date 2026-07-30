#!/usr/bin/env python3
"""measure-boxes.py - measure the colored debug boxes from skill section 3e.

Finds the red (anchor) and lime (rendered frame) overlay rects in a full-res
screenshot and reports their top/bottom/height in pt plus the gap between them.
Needs Pillow, and takes care of that itself (see `_pillow.py`). Run it with plain
`python3` - or just execute it, the shebang is enough.

    xcrun simctl io <udid> screenshot --type=png shot.png
    ./measure-boxes.py shot.png 3
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import _pillow  # noqa: F401  - guarantees Pillow; may re-exec into a venv

from PIL import Image

if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
    sys.exit(f"usage: {os.path.basename(sys.argv[0])} SCREENSHOT.png [SCALE=3]")

img = Image.open(sys.argv[1]).convert('RGB')
W, H = img.size
scale = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
px = img.load()

def rows_with(pred, min_count=40):
    out = []
    for y in range(H):
        c = 0
        for x in range(0, W, 2):
            if pred(px[x, y]):
                c += 1
                if c >= min_count:
                    out.append(y)
                    break
    return out

is_lime = lambda p: p[1] > 200 and p[0] < 120 and p[2] < 120
is_red  = lambda p: p[0] > 180 and p[1] < 110 and p[2] < 110

lime = rows_with(is_lime)
red  = rows_with(is_red)
print(f"image {W}x{H} px, scale {scale} -> {W/scale:.0f}x{H/scale:.0f} pt")
if lime:
    print(f"LIME (modal frame): top={lime[0]}px={lime[0]/scale:.2f}pt  bottom={lime[-1]}px={lime[-1]/scale:.2f}pt  height={(lime[-1]-lime[0]+1)/scale:.2f}pt")
if red:
    print(f"RED  (anchor rect): top={red[0]}px={red[0]/scale:.2f}pt  bottom={red[-1]}px={red[-1]/scale:.2f}pt  height={(red[-1]-red[0]+1)/scale:.2f}pt")
if lime and red:
    if red[0] > lime[-1]:
        print(f"GAP modal-bottom -> anchor-top = {(red[0]-lime[-1])/scale:.2f}pt  (flipped above)")
    elif lime[0] > red[-1]:
        print(f"GAP anchor-bottom -> modal-top = {(lime[0]-red[-1])/scale:.2f}pt  (below anchor)")
    else:
        print("boxes overlap vertically")
