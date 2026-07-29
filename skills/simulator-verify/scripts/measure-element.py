#!/usr/bin/env python3
"""measure-element.py - hard pixel numbers for "pixel-perfect" UI bugs.

For small visual bugs (a label "not centered", a badge "off by a bit"), eyeballing
a screenshot is unreliable. This script measures the real geometry: it finds a
container blob (e.g. a pill/badge) inside a search region, then the inner content
(e.g. the text glyphs) inside that blob, and reports center deltas in device px and
logical pt. The verdict is a number, not "looks ok".

Requires Pillow (`python3 -c "import PIL"`). Take the screenshot first:
    xcrun simctl io booted screenshot shot.png

Usage:
    measure-element.py shot.png --region X,Y,W,H [--container dark|light]
                        [--inset N] [--scale 3] [--json]

  --region    search box in device px (X,Y top-left, W,H size). Crop generously
              around the element; the script locates the blob inside it.
  --container dark  = dark element on light page (default). light = inverse.
  --inset     shrink content search horizontally by N px each side, to skip
              rounded-corner background bleed (start ~20% of pill width).
  --scale     device px per logical pt (iPhone @3x = 3, default).

Reads: container W/H + center, content W/H + center, inner padding top/bottom,
and VERTICAL/HORIZONTAL delta of content-center vs container-center.
Negative vertical = content sits HIGH (above center); positive = LOW (below).
A well-centered label reads ~0pt; |delta| >= ~1pt is a real, fixable defect.
"""
import argparse, json, sys
from PIL import Image


def luminance(p):
    return 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]


def bbox_of(px, x0, y0, x1, y1, predicate):
    minx = miny = 10**9
    maxx = maxy = -1
    count = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            if predicate(px[x, y]):
                count += 1
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if count == 0:
        return None
    return {"x": minx, "y": miny, "w": maxx - minx + 1, "h": maxy - miny + 1,
            "cx": (minx + maxx) / 2, "cy": (miny + maxy) / 2, "px": count}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--region", required=True, help="X,Y,W,H search area in device px")
    ap.add_argument("--container", choices=["dark", "light"], default="dark",
                    help="container luminance vs page bg (dark pill on light bg = dark)")
    ap.add_argument("--dark-th", type=float, default=80.0)
    ap.add_argument("--light-th", type=float, default=180.0)
    ap.add_argument("--inset", type=int, default=0,
                    help="shrink content search box horizontally by N px each side "
                         "(avoids rounded-corner background bleed)")
    ap.add_argument("--scale", type=float, default=3.0, help="device px per logical pt")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    im = Image.open(args.image).convert("RGB")
    px = im.load()
    x, y, w, h = (int(v) for v in args.region.split(","))
    x1, y1 = x + w, y + h

    is_dark = lambda p: luminance(p) < args.dark_th
    is_light = lambda p: luminance(p) > args.light_th

    if args.container == "dark":
        container_pred, content_pred = is_dark, is_light
    else:
        container_pred, content_pred = is_light, is_dark

    container = bbox_of(px, x, y, x1, y1, container_pred)
    if not container:
        print("ERROR: no container blob found in region", file=sys.stderr)
        sys.exit(1)

    cx0 = container["x"] + args.inset
    cy0 = container["y"]
    cx1 = container["x"] + container["w"] - args.inset
    cy1 = container["y"] + container["h"]
    content = bbox_of(px, cx0, cy0, cx1, cy1, content_pred)

    s = args.scale
    out = {"container": container}
    if content:
        dy = content["cy"] - container["cy"]
        dx = content["cx"] - container["cx"]
        pad_top = content["y"] - container["y"]
        pad_bot = (container["y"] + container["h"]) - (content["y"] + content["h"])
        out["content"] = content
        out["delta_px"] = {"vertical": round(dy, 2), "horizontal": round(dx, 2)}
        out["delta_pt"] = {"vertical": round(dy / s, 2), "horizontal": round(dx / s, 2)}
        out["inner_pad_px"] = {"top": pad_top, "bottom": pad_bot}
        out["inner_pad_pt"] = {"top": round(pad_top / s, 2), "bottom": round(pad_bot / s, 2)}

    if args.json:
        print(json.dumps(out, indent=2))
        return

    c = container
    print(f"container: {c['w']}x{c['h']}px  center=({c['cx']:.1f},{c['cy']:.1f})  ({c['w']/s:.1f}x{c['h']/s:.1f}pt)")
    if content:
        ct = out["content"]
        print(f"content:   {ct['w']}x{ct['h']}px  center=({ct['cx']:.1f},{ct['cy']:.1f})  ({ct['w']/s:.1f}x{ct['h']/s:.1f}pt)")
        print(f"inner padding: top={out['inner_pad_pt']['top']}pt  bottom={out['inner_pad_pt']['bottom']}pt")
        print(f"VERTICAL delta (content - container center): {out['delta_px']['vertical']}px = {out['delta_pt']['vertical']}pt")
        print("  (negative = content sits HIGH/above center, positive = LOW/below center)")
        print(f"HORIZONTAL delta: {out['delta_px']['horizontal']}px = {out['delta_pt']['horizontal']}pt")
    else:
        print("content: none found inside container")


if __name__ == "__main__":
    main()
