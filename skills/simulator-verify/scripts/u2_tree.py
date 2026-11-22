#!/usr/bin/env python3
"""Read (and optionally wait for) the UiAutomator2 element tree of an Android device,
printed in the same shape as wda_tree.py prints the iOS one, coordinates in dp.

  u2_tree.py --port P --scale S [--all] [--grep RE] [--names]          # one read
  u2_tree.py --port P --scale S --settled GAP [--all] [--grep RE] [--names]
  u2_tree.py --port P --scale S --match RE [--timeout S] [--all]       # waitfor
  u2_tree.py --xml FILE --scale S [...]                                # a saved /source

Element: {"type", "label", "name", "value", "checked", "hint", "rect"} - `name` is the
resource-id (a React Native testID arrives there bare, no package prefix), `type` the
last part of the class (TextView, Button, ViewGroup, EditText, Switch ...), `label` the
content-desc or else the text, `rect` [x, y, w, h] in dp (px / density-scale, rounded).
The rect is in SCREEN coordinates and clipped to the screen: in an edge-to-edge window
(API 35+, and the RN 0.8x template) it equals React Native's measureInWindow; in a window
without edge-to-edge it is lower by the status bar (24 dp measured on API 34), and an
element running past the bottom edge reports only its visible part.
An EditText's text is its `value`, except while `showing-hint` is true: then the text is
the placeholder, so `value` is empty and the placeholder is `hint`. A checkable node
(Switch, CheckBox) carries `checked` instead of a value.

Default filter (without --all): a visible node stays when it has a resource-id, a text
or a content-desc, or is a clickable Button / EditText / Switch / CheckBox. Visible =
displayed, a positive size, and some part inside the screen. --all keeps every visible
node.

What the tree is - read before relying on it (measured on API 34 and 36, RN 0.88):
  - Only the ACTIVE window. A permission dialog or a chooser replaces the app's nodes
    entirely; a NOTE on stderr says when the tree is a system window.
  - Off-screen rows of a list or a horizontal ScrollView do not exist at all (iOS
    lists them with displayed:false). A covered element still says displayed=true.
  - A nested <Text testID> and a View with opacity 0 have no node.
  - waitForIdleTimeout=0 (set by u2_client.py) means a read during a transition is a
    FRAME: a sliding Modal's button is displayed=true below the screen for ~0.3 s and a
    native-driver slide moves on every read. --settled (two reads 2 s apart) is the
    answer to "is this the state". It catches steady motion of any length (a 4 s slide
    included); a pause in the middle of an animation longer than the gap reads as
    settled. A react-navigation native-stack push never shows a middle frame: the new
    screen's nodes appear at their final rects within ~0.1 s of the tap.
"""
import argparse
import difflib
import json
import math
import os
import re
import sys
import time
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import u2_client  # noqa: E402

KEEP_CLICKABLE = ("Button", "EditText", "Switch", "CheckBox")
SYSTEM_PREFIXES = ("com.android.", "com.google.android.")
FIELDS = ("type", "label", "name", "value")


def dp(v, scale):
    return int(math.floor(v / scale + 0.5))


def parse_bounds(s):
    m = re.fullmatch(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", s or "")
    if not m:
        return None
    x1, y1, x2, y2 = (int(g) for g in m.groups())
    return x1, y1, x2, y2


def parse(xml_text):
    """The /source XML -> (root element, screen (w, h) in px)."""
    root = ET.fromstring(xml_text.encode("utf-8") if isinstance(xml_text, str) else xml_text)
    try:
        screen = (int(root.get("width")), int(root.get("height")))
    except (TypeError, ValueError):
        screen = None
    return root, screen


def on_screen(b, screen):
    x1, y1, x2, y2 = b
    if x2 <= x1 or y2 <= y1:
        return False
    if screen is None:
        return True
    w, h = screen
    return x1 < w and y1 < h and x2 > 0 and y2 > 0


def short_class(cls):
    return (cls or "").rsplit(".", 1)[-1]


def describe(a, scale):
    """One node's attributes -> the element dict (no visibility decision here)."""
    typ = short_class(a.get("class"))
    text, desc = a.get("text") or "", a.get("content-desc") or ""
    e = {"type": typ}
    if typ == "EditText":
        if desc:
            e["label"] = desc
        if a.get("resource-id"):
            e["name"] = a["resource-id"]
        if a.get("showing-hint") == "true":
            e["value"] = ""
            if text:
                e["hint"] = text
        elif text:
            e["value"] = text
    else:
        label = desc or text
        if label:
            e["label"] = label
        if a.get("resource-id"):
            e["name"] = a["resource-id"]
        if desc and text and desc != text:
            e["value"] = text
    if a.get("checkable") == "true":
        e["checked"] = a.get("checked") == "true"
    b = parse_bounds(a.get("bounds"))
    e["rect"] = [dp(b[0], scale), dp(b[1], scale), dp(b[2] - b[0], scale), dp(b[3] - b[1], scale)] if b else None
    return e


def kept(a, show_all):
    if show_all:
        return True
    if a.get("resource-id") or a.get("text") or a.get("content-desc"):
        return True
    return a.get("clickable") == "true" and short_class(a.get("class")) in KEEP_CLICKABLE


def visible(a, screen):
    b = parse_bounds(a.get("bounds"))
    return a.get("displayed", "true") == "true" and b is not None and on_screen(b, screen)


def elements(xml_text, scale, show_all=False):
    root, screen = parse(xml_text)
    out, seen = [], set()
    for n in root.iter():
        a = n.attrib
        if "class" not in a or a.get("class") == "hierarchy":
            continue
        if not (visible(a, screen) and kept(a, show_all)):
            continue
        e = describe(a, scale)
        key = json.dumps(e, sort_keys=True)
        if key not in seen:
            seen.add(key)
            out.append(e)
    return out


def window_package(xml_text):
    """The package of the window the tree belongs to (its first node's), or None."""
    root, _ = parse(xml_text)
    for n in root.iter():
        if n.get("package"):
            return n.get("package")
    return None


def is_system_package(pkg):
    return bool(pkg) and (pkg == "android" or pkg.startswith(SYSTEM_PREFIXES))


def window_note(xml_text):
    pkg = window_package(xml_text)
    if is_system_package(pkg):
        return ("NOTE: the tree is a SYSTEM window (%s) - it covers the app, whose elements are "
                "not in this read (only the active window is)." % pkg)
    return None


def regex(flag, pattern):
    try:
        return re.compile(pattern, re.I)
    except re.error as e:
        print("ERROR: %s '%s' is not a valid regular expression: %s" % (flag, pattern, e), file=sys.stderr)
        sys.exit(2)


def narrow(els, pattern):
    """Keep elements where ONE field matches (as wda_tree.py: a joined string lets a
    pattern span two fields and hit something unrelated)."""
    pat = regex("--grep", pattern)
    return [e for e in els if any(pat.search(str(e.get(k, ""))) for k in FIELDS)]


def name_lines(els):
    lines = []
    for e in els:
        ident = repr(e["name"])[1:-1] if e.get("name") else "-"
        text = e.get("label") or e.get("value") or ""
        extra = ""
        if e.get("value") and e.get("value") != e.get("label"):
            extra += "  value=%r" % e["value"]
        if "hint" in e:
            extra += "  hint=%r" % e["hint"]
        if "checked" in e:
            extra += "  checked=%s" % str(e["checked"]).lower()
        lines.append("%s\t%s\t%s\t%r%s" % (ident, e.get("type"),
                                           json.dumps(e["rect"], separators=(",", ":")), text, extra))
    return lines


def emit(els, names):
    if names:
        for line in name_lines(els):
            print(line)
    else:
        print(json.dumps(els, separators=(",", ":"), ensure_ascii=False))


class Reader:
    def __init__(self, port):
        self.u = u2_client.U2(port)
        self.u.session()

    def read(self):
        return self.u.source(timeout=10)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--port", type=int)
    ap.add_argument("--xml")
    ap.add_argument("--scale", type=float, required=True)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--grep")
    ap.add_argument("--names", action="store_true")
    ap.add_argument("--settled", type=float)
    ap.add_argument("--match")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--interval", type=float, default=0.2)
    ap.add_argument("--adb")       # with --serial: waitfor stops at once on a locked screen
    ap.add_argument("--serial")
    a = ap.parse_args(argv)
    if a.grep is not None:
        regex("--grep", a.grep)
    if a.scale <= 0:
        print("ERROR: --scale must be positive", file=sys.stderr)
        return 2

    if a.xml:
        with open(a.xml, encoding="utf-8") as f:
            src = f.read()
        read = lambda: src  # noqa: E731
    else:
        try:
            read = Reader(a.port).read
        except u2_client.ServerError as e:
            print("ERROR: %s" % e, file=sys.stderr)
            return 1

    def safe_read():
        try:
            return read()
        except u2_client.ServerError as e:
            print("ERROR: %s" % e, file=sys.stderr)
            sys.exit(1)

    if a.match is None and a.settled is None:
        src = safe_read()
        note = window_note(src)
        if note:
            print(note, file=sys.stderr)
        els = elements(src, a.scale, a.all)
        emit(narrow(els, a.grep) if a.grep else els, a.names)
        return 0

    if a.settled is not None:
        first = elements(safe_read(), a.scale, a.all)
        time.sleep(a.settled)
        src = safe_read()
        second = elements(src, a.scale, a.all)
        if first != second:
            print("ERROR: the element tree changed between two reads %gs apart - the screen is still "
                  "moving (keyboard, sheet, transition), so neither read is its state. Wait and read "
                  "again; what changed:" % a.settled, file=sys.stderr)
            diff = difflib.unified_diff(name_lines(first), name_lines(second), "first", "second", lineterm="", n=0)
            for i, line in enumerate(diff):
                if i >= 22:
                    break
                print(line, file=sys.stderr)
            return 3
        note = window_note(src)
        if note:
            print(note, file=sys.stderr)
        emit(narrow(second, a.grep) if a.grep else second, a.names)
        return 0

    pat = regex("waitfor", a.match)
    started = time.time()
    deadline = started + a.timeout
    polls, last = 0, []
    while True:
        polls += 1
        def hits_of(els):
            return [e for e in els if pat.search(" ".join(str(e.get(k, "")) for k in FIELDS))]
        try:
            if polls == 1 and a.adb and a.serial:
                # A locked screen will not show the match however long this waits.
                last = u2_client.unless_locked(lambda: elements(read(), a.scale, a.all), hits_of,
                                               lambda: u2_client.device_locked(a.adb, a.serial))
            else:
                last = elements(read(), a.scale, a.all)
        except u2_client.ScreenLocked:
            print("waitfor: %s" % u2_client.locked_hint(a.serial), file=sys.stderr)
            return 1
        except u2_client.ServerError:
            last = []
        hits = hits_of(last)
        if hits:
            print(json.dumps(hits, separators=(",", ":"), ensure_ascii=False))
            print("matched /%s/ after %d poll(s), %.1fs" % (a.match, polls, time.time() - started), file=sys.stderr)
            return 0
        if time.time() >= deadline:
            print("waitfor: nothing matching /%s/ within %gs (%d polls, %d elements on the last one)"
                  % (a.match, a.timeout, polls, len(last)), file=sys.stderr)
            lines = name_lines(last)
            if lines:
                print("  on screen now:", file=sys.stderr)
                for line in lines[:25]:
                    print("  " + line, file=sys.stderr)
                if len(lines) > 25:
                    print("  ... and %d more" % (len(lines) - 25), file=sys.stderr)
            return 1
        time.sleep(a.interval)


if __name__ == "__main__":
    sys.exit(main())
