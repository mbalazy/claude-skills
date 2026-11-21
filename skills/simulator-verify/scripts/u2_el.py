#!/usr/bin/env python3
"""Address ONE element by its resource-id (React Native `testID`) on an Android device -
the counterpart of wda_el.py.

  u2_el.py --port P --scale S --adb ADB --serial SER wait ID [--timeout S] [--exists]
  u2_el.py --port P --scale S --adb ADB --serial SER info ID
  u2_el.py --adb ADB --serial SER foreground

Every poll is ONE /source snapshot (5-20 ms over HTTP; ~100 ms on a 250-node screen),
matched on resource-id == ID exactly. One snapshot means displayed, rect and package
come from the same moment - three separate requests per element would not.

A HIT (what `wait` waits for and what `tapid` will act on) is all of:
  - displayed=true and a positive size,
  - some part of the rect inside the screen: with waitForIdleTimeout=0 a sliding Modal's
    button is displayed=true BELOW the screen for ~0.3 s (measured: y 2526-2569 px on a
    2424 px screen),
  - the node's package is the package of the focused window (`dumpsys window`: the
    mCurrentFocus window's own `package=` line - its title is not a package for a
    titled dialog, and an ANR dialog's title carries the app's name): after `am start` of another app the tree keeps showing the window
    that was underneath for ~0.4 s (measured: focus empty until 0.31 s, the new app's
    from 0.36 s, its tree from 0.39 s), so an id that also exists there would hit too
    early. While nothing has focus nothing is a hit.
--exists drops all three: the id is anywhere in the tree. It cannot tell "scrolled away"
from "absent" on Android - rows outside a list's viewport have no node at all.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import u2_client  # noqa: E402
import u2_tree  # noqa: E402


def out(obj):
    print(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))


def matches(xml_text, ident, scale):
    """[(element dict + displayed/package/on_screen, attrib)] for every node with that id."""
    root, screen = u2_tree.parse(xml_text)
    found = []
    for n in root.iter():
        a = n.attrib
        if a.get("resource-id") != ident:
            continue
        e = u2_tree.describe(a, scale)
        b = u2_tree.parse_bounds(a.get("bounds"))
        e["displayed"] = a.get("displayed", "true") == "true"
        e["on_screen"] = bool(b) and u2_tree.on_screen(b, screen)
        e["package"] = a.get("package")
        found.append(e)
    return found


def adb_shell(adb, serial, *args):
    try:
        r = subprocess.run([adb, "-s", serial, "shell"] + list(args), capture_output=True,
                           text=True, timeout=10, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.replace("\r", "")


def focused_window(dump):
    """`dumpsys window` text -> (focus line, package of that window or None). The line is
    e.g. 'Window{c3 u0 com.example.app/...MainActivity}', '' when nothing has focus."""
    m = re.search(r"mCurrentFocus=(\S.*)", dump)
    line = m.group(1).strip() if m else ""
    if line in ("", "null"):
        return "", None
    h = re.match(r"Window\{([0-9a-f]+) ", line)
    if not h:
        return line, None
    block = re.search(r"Window #\d+ Window\{%s [^\n]*\n(.*?)(?=\n *Window #\d+ |\Z)" % h.group(1), dump, re.S)
    pkg = re.search(r"\bpackage=(\S+)", block.group(1)) if block else None
    return line, (pkg.group(1) if pkg else None)


def focus_of(adb, serial):
    return focused_window(adb_shell(adb, serial, "dumpsys", "window"))


def in_focus(pkg, focus):
    """Does the focused window (a (line, package) pair) belong to `pkg`? Its own package
    decides; without one (an older dump format) the line is matched, where a window is
    named `pkg/activity` or, for a starting window, by its last word."""
    line, fpkg = focus
    if not pkg or not line:
        return False
    if fpkg:
        return pkg == fpkg
    return re.search(r"(^|[\s{])%s([/}]|$)" % re.escape(pkg), line) is not None


def why_not(e, focus):
    if not e["displayed"]:
        return "displayed=false"
    if not e["on_screen"]:
        return "outside the screen (rect %s dp) - mid-transition or scrolled" % (e["rect"],)
    if not in_focus(e["package"], focus):
        line, fpkg = focus
        return "in the window of %s, but the focused window is %s" % (
            e["package"], ("%s (%s)" % (line, fpkg)) if line else "none (screen off?)")
    return None


class Device:
    def __init__(self, a):
        self.a = a
        self.u = u2_client.U2(a.port)
        self.u.session()

    def source(self):
        return self.u.source(timeout=10)

    def focus(self):
        return focus_of(self.a.adb, self.a.serial)


def hits_now(dev, ident, scale, exists):
    """(hits, all matches, focus line or None, the source) from one snapshot."""
    src = dev.source()
    found = matches(src, ident, scale)
    if exists:
        return found, found, None, src
    cand = [e for e in found if e["displayed"] and e["on_screen"]]
    if not cand:
        return [], found, None, src
    focus = dev.focus()
    return [e for e in cand if in_focus(e["package"], focus)], found, focus, src


def cmd_wait(dev, a):
    started = time.time()
    deadline = started + a.timeout
    polls, found, focus, err, src = 0, [], None, None, None
    while True:
        polls += 1
        try:
            hits, found, focus, src = hits_now(dev, a.id, a.scale, a.exists)
            err = None
        except u2_client.ServerError as e:
            hits, found, err = [], [], str(e)
        if hits:
            out(hits)
            print("matched id '%s' (%s) after %d poll(s), %.1fs" % (
                a.id, "exists" if a.exists else "displayed", polls, time.time() - started), file=sys.stderr)
            return 0
        if time.time() >= deadline:
            print("waitid: nothing %s with id '%s' within %gs (%d polls)" % (
                "present" if a.exists else "displayed on screen in the app's window", a.id, a.timeout, polls),
                file=sys.stderr)
            if found:
                if focus is None:
                    focus = dev.focus()
                print("  %d element(s) with that id EXIST but none is a hit:" % len(found), file=sys.stderr)
                for e in found[:5]:
                    print("    %s" % why_not(e, focus), file=sys.stderr)
                out(found[:5])
            elif err:
                print("  last read failed: %s" % err, file=sys.stderr)
            else:
                note = u2_tree.window_note(src) if src else None
                print("  %s" % (note or "no element carries that resource-id in this tree (only the active "
                      "window is read, and off-screen list rows do not exist). `elements --all --grep` "
                      "lists what is there."), file=sys.stderr)
            return 1
        time.sleep(a.interval)


def cmd_info(dev, a):
    src = dev.source()
    found = matches(src, a.id, a.scale)
    if not found:
        note = u2_tree.window_note(src)
        print("no element with id '%s' on this screen%s" % (a.id, (" - " + note) if note else ""), file=sys.stderr)
        return 1
    out(found)
    return 0


SYSTEM_PREFIXES = ("com.android.", "com.google.android.")


def is_system(pkg):
    return pkg == "android" or pkg.startswith(SYSTEM_PREFIXES)


def front(activities):
    """`dumpsys activity activities` text -> (top resumed (pkg, activity), the root
    (pkg, activity) of its task) or (None, None). A permission dialog is an activity of
    the permission controller pushed onto the APP's task, so the task root names the app
    under it; a chooser started on its own has itself as root."""
    m = re.search(r"topResumedActivity=ActivityRecord\{\S+ \S+ ([^/\s]+)/(\S+) t(\d+)", activities)
    if not m:
        return None, None
    top, task = (m.group(1), m.group(2)), m.group(3)
    roots = re.findall(r"\* Hist +#0: ActivityRecord\{\S+ \S+ ([^/\s]+)/(\S+) t%s\}" % task, activities)
    return top, (roots[0] if roots else top)


def cmd_foreground(a):
    acts = adb_shell(a.adb, a.serial, "dumpsys", "activity", "activities")
    top, root = front(acts)
    line, fpkg = focus_of(a.adb, a.serial)
    if top is None:
        print("ERROR: no resumed activity on %s (screen off or locked?) - focused window: %s"
              % (a.serial, line or "none"), file=sys.stderr)
        return 1
    app = root if (is_system(top[0]) and not is_system(root[0])) else top
    pid = adb_shell(a.adb, a.serial, "pidof", app[0]).strip()
    print("%s pid %s (%s/%s)" % (app[0], pid or "?", app[0], app[1]))
    if not line:
        print("focus: none (screen off?)")
    elif not in_focus(app[0], (line, fpkg)):
        print("focus: %s%s - this window, not %s, is what element reads see"
              % (line, (" (package %s)" % fpkg) if fpkg else "", app[0]))
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "foreground" in argv and "--port" not in argv:
        fp = argparse.ArgumentParser(add_help=False)
        fp.add_argument("--adb", required=True)
        fp.add_argument("--serial", required=True)
        fp.add_argument("cmd", choices=("foreground",))
        return cmd_foreground(fp.parse_args(argv))
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--scale", type=float, required=True)
    ap.add_argument("--adb", required=True)
    ap.add_argument("--serial", required=True)
    ap.add_argument("cmd", choices=("wait", "info"))
    ap.add_argument("id")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--exists", action="store_true")
    ap.add_argument("--interval", type=float, default=0.1)
    a = ap.parse_args(argv)
    try:
        dev = Device(a)
        return cmd_wait(dev, a) if a.cmd == "wait" else cmd_info(dev, a)
    except u2_client.ServerError as e:
        print("%sid: %s" % ("wait" if a.cmd == "wait" else "el ", e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
