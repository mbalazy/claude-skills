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


def matches(xml_text, ident, scale, raw=False, pick=None):
    """The element dict + displayed/package/on_screen of every node with that id (or, with
    `pick`, every node the predicate accepts). raw=True adds the node's attributes under
    "_a" for the caller's own use; `public()` strips it before printing."""
    root, screen = u2_tree.parse(xml_text)
    found = []
    for n in root.iter():
        a = n.attrib
        if not (pick(a) if pick else a.get("resource-id") == ident):
            continue
        e = u2_tree.describe(a, scale)
        b = u2_tree.parse_bounds(a.get("bounds"))
        e["displayed"] = a.get("displayed", "true") == "true"
        e["on_screen"] = bool(b) and u2_tree.on_screen(b, screen)
        e["package"] = a.get("package")
        if raw:
            e["_a"] = dict(a)
        found.append(e)
    return found


def public(els):
    return [{k: v for k, v in e.items() if k != "_a"} for e in els]


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


def pick_hit(dev, ident, scale, verb, done, hint):
    """The ONE element with that id that is a hit now (the waitid rule), from one
    snapshot, or None after saying on stderr why nothing was done. Several nodes at the
    same bounds are one target (React Native can expose a view twice); several at
    different places are refused - guessing would act on the wrong one confidently."""
    src = dev.source()
    found = matches(src, ident, scale, raw=True)
    if not found:
        note = u2_tree.window_note(src)
        print("%s: no element with id '%s' on this screen - nothing was %s%s"
              % (verb, ident, done, (". " + note) if note else ""), file=sys.stderr)
        return None
    cand = [e for e in found if e["displayed"] and e["on_screen"]]
    focus = dev.focus()
    hits = [e for e in cand if in_focus(e["package"], focus)]
    if not hits:
        print("%s: %d element(s) with id '%s' exist but none is displayed on screen in the app's "
              "window - nothing was %s:" % (verb, len(found), ident, done), file=sys.stderr)
        for e in found[:5]:
            print("    %s" % why_not(e, focus), file=sys.stderr)
        out(public(found[:5]))
        return None
    places = {e["_a"].get("bounds") for e in hits}
    if len(places) > 1:
        print("%s: %d DISPLAYED elements with id '%s' at different places - refusing to pick one, "
              "nothing was %s. %s" % (verb, len(hits), ident, done, hint), file=sys.stderr)
        out(public(hits[:8]))
        return None
    return hits[0]


def server_element(dev, ident, bounds):
    """The server's element id for the node with that resource-id at those bounds."""
    u = dev.u
    resp = u.call("POST", "/session/%s/elements" % u.sid, {"strategy": "id", "selector": ident})
    err = u.error_of(resp)
    if err:
        raise u2_client.ServerError("the server could not look up id '%s': %s" % (ident, err))
    eids = [v.get("ELEMENT") for v in resp.get("value") or [] if isinstance(v, dict)]
    if len(eids) == 1:
        return eids[0]
    for eid in eids:
        b = u.call("GET", "/session/%s/element/%s/attribute/bounds" % (u.sid, eid)).get("value")
        if b == bounds:
            return eid
    raise u2_client.ServerError("id '%s' changed between the tree read and the lookup (%d match(es), "
                                "none at %s) - the screen is moving; try again" % (ident, len(eids), bounds))


def element_call(dev, method, eid, what, body=None):
    u = dev.u
    resp = u.call(method, "/session/%s/element/%s/%s" % (u.sid, eid, what), body)
    return u.error_of(resp)


def press_enter(dev):
    u = dev.u
    return u.error_of(u.call("POST", "/session/%s/appium/device/press_keycode" % u.sid, {"keycode": 66}))


def cmd_tap(dev, a):
    hit = pick_hit(dev, a.id, a.scale, "tapid", "tapped", "Tap the one you mean by its rect:")
    if not hit:
        return 1
    eid = server_element(dev, a.id, hit["_a"].get("bounds"))
    err = element_call(dev, "POST", eid, "click", {})
    if err:
        print("tapid: the server refused the click on '%s': %s" % (a.id, err), file=sys.stderr)
        return 1
    print("tapped id %s (%s %s)" % (a.id, hit["type"], json.dumps(hit["rect"], separators=(",", ":"))))
    return 0


def field_value(dev, ident, scale):
    """(value, is_password) of the first node with that id now, or (None, False)."""
    found = matches(dev.source(), ident, scale, raw=True)
    if not found:
        return None, False
    e = found[0]
    return e.get("value", ""), e["_a"].get("password") == "true"


def read_back(dev, ident, scale, settle, gap=0.25):
    """The field's value once it holds still. The text set by the server is in the field
    at once, and a controlled field re-renders with what its onChangeText made of it a
    frame later: a phone mask read '5125550199' first and '(512) 555-0199' after. So the
    value counts when two reads `gap` apart agree; `settle` caps the wait."""
    deadline = time.time() + settle
    time.sleep(gap)
    value, _ = field_value(dev, ident, scale)
    while time.time() < deadline:
        time.sleep(gap)
        again, _ = field_value(dev, ident, scale)
        if again == value:
            break
        value = again
    return value


def cmd_type(dev, a):
    # A trailing newline is Return, pressed only after the read-back matched - a search
    # never runs for a cut word, and the field is never expected to hold the "\n".
    body = a.text.rstrip("\n")
    submit = a.text[len(body):]
    hit = pick_hit(dev, a.id, a.scale, "typeid", "typed",
                   "Tap the one you mean by its rect, then `type` into it:")
    if not hit:
        return 1
    if hit["type"] != "EditText":
        print("typeid: '%s' is a %s, not a text field (EditText) - nothing was done. Tap it with "
              "`tapid`, then address the field that appears." % (a.id, hit["type"] or "node of unknown class"),
              file=sys.stderr)
        return 1
    password = hit["_a"].get("password") == "true"
    before = hit.get("value", "") if a.append and not password else ""
    if a.append and password:
        print("NOTE: '%s' is a password field - its text cannot be read, so --append replaced it."
              % a.id, file=sys.stderr)
    eid = server_element(dev, a.id, hit["_a"].get("bounds"))
    # The server sets the whole text at once (one onChangeText): Unicode arrives intact,
    # where `input text` cannot type a non-ASCII character at all.
    err = element_call(dev, "POST", eid, "value", {"text": before + body})
    if err:
        print("typeid: the server refused to type into '%s': %s" % (a.id, err), file=sys.stderr)
        return 1
    expected = a.expect if a.expect is not None else before + body
    if password:
        print("NOTE: '%s' is a password field - its text reads as dots, so what arrived cannot be "
              "checked here." % a.id, file=sys.stderr)
        shown = "password field, not read back"
    else:
        value = read_back(dev, a.id, a.scale, a.settle)
        if value != expected:
            print("typeid: the field '%s' holds %r, expected %r%s. If the field formats its input "
                  "(a mask), pass the formatted value with --expect."
                  % (a.id, value, expected, " - Return was NOT sent" if submit else ""), file=sys.stderr)
            return 1
        shown = "%r (read back)" % value
    if submit:
        # Setting the text does not focus the field, and a Return with nothing focused
        # goes nowhere (onSubmitEditing did not fire): the field is clicked first.
        err = element_call(dev, "POST", server_element(dev, a.id, hit["_a"].get("bounds")), "click", {}) \
            or press_enter(dev)
        if err:
            print("typeid: the text was typed and read back, but the server refused the Return: %s"
                  % err, file=sys.stderr)
            return 1
    print("typed into id %s: %s%s" % (a.id, shown, ", then Return" if submit else ""))
    return 0


def is_focused_field(attrs):
    return attrs.get("focused") == "true" and u2_tree.short_class(attrs.get("class")) == "EditText"


def cmd_type_focused(dev, a):
    """Typing at the keyboard focus. The server can only SET a field's text, so the text is
    appended to what the field holds (placeholder excluded) - at its end, not at the cursor."""
    body = a.text.rstrip("\n")
    submit = a.text[len(body):]
    fields = matches(dev.source(), None, a.scale, raw=True, pick=is_focused_field)
    if not fields:
        print("type: no text field has keyboard focus - nothing was typed. Tap the field first "
              "(tapid), or address it with typeid.", file=sys.stderr)
        return 1
    f = fields[0]
    u = dev.u
    resp = u.call("POST", "/session/%s/element" % u.sid,
                  {"strategy": "-android uiautomator", "selector": "new UiSelector().focused(true)"})
    eid = (resp.get("value") or {}).get("ELEMENT") if isinstance(resp.get("value"), dict) else None
    if not eid:
        print("type: the focused field went away before typing (%s) - nothing was typed."
              % (u.error_of(resp) or "no element"), file=sys.stderr)
        return 1
    if body:
        before = "" if f["_a"].get("password") == "true" else f.get("value", "")
        err = element_call(dev, "POST", eid, "value", {"text": before + body})
        if err:
            print("type: the server refused to type into the focused field: %s" % err, file=sys.stderr)
            return 1
    if submit:
        err = press_enter(dev)
        if err:
            print("type: the server refused the Return: %s" % err, file=sys.stderr)
            return 1
    where = f.get("name") or "%s %s" % (f["type"], f["rect"])
    print("typed: %s (into the focused field %s, appended at its end)" % (a.text, where))
    return 0


def pointer(actions):
    return {"actions": [{"type": "pointer", "id": "finger", "parameters": {"pointerType": "touch"},
                         "actions": actions}]}


def gesture_body(kind, px, hold_ms=500):
    """W3C pointer actions in px. The timing runs on the device: two `input tap` calls
    depend on how fast the shell starts the second one."""
    x, y = px[0], px[1]
    start = [{"type": "pointerMove", "duration": 0, "x": x, "y": y}]
    if kind == "doubletap":
        return pointer(start + [
            {"type": "pointerDown", "button": 0}, {"type": "pause", "duration": 50},
            {"type": "pointerUp", "button": 0}, {"type": "pause", "duration": 100},
            {"type": "pointerDown", "button": 0}, {"type": "pause", "duration": 50},
            {"type": "pointerUp", "button": 0}])
    if kind == "drag":
        return pointer(start + [
            {"type": "pointerDown", "button": 0}, {"type": "pause", "duration": hold_ms},
            {"type": "pointerMove", "duration": 300, "x": px[2], "y": px[3]},
            {"type": "pointerUp", "button": 0}])
    raise ValueError(kind)


def cmd_gesture(dev, a):
    u = dev.u
    err = u.error_of(u.call("POST", "/session/%s/actions" % u.sid,
                            gesture_body(a.kind, a.px, int(round(a.hold * 1000)))))
    if err:
        print("%s: the server refused the gesture: %s" % (a.kind, err), file=sys.stderr)
        return 1
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
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("wait", "info", "tap"):
        p = sub.add_parser(name, add_help=False)
        p.add_argument("id")
        if name == "wait":
            p.add_argument("--timeout", type=float, default=10.0)
            p.add_argument("--exists", action="store_true")
            p.add_argument("--interval", type=float, default=0.1)
    p = sub.add_parser("type", add_help=False)
    p.add_argument("id")
    p.add_argument("--text", required=True)
    p.add_argument("--append", action="store_true")
    p.add_argument("--expect")
    p.add_argument("--settle", type=float, default=1.5)
    p = sub.add_parser("typefocused", add_help=False)
    p.add_argument("--text", required=True)
    p = sub.add_parser("gesture", add_help=False)
    p.add_argument("kind", choices=("doubletap", "drag"))
    p.add_argument("px", type=int, nargs="+")
    p.add_argument("--hold", type=float, default=0.5)
    a = ap.parse_args(argv)
    run = {"wait": cmd_wait, "info": cmd_info, "tap": cmd_tap, "type": cmd_type,
           "typefocused": cmd_type_focused, "gesture": cmd_gesture}[a.cmd]
    label = {"wait": "waitid", "info": "el", "tap": "tapid", "type": "typeid",
             "typefocused": "type", "gesture": getattr(a, "kind", "")}[a.cmd]
    try:
        dev = Device(a)
        return run(dev, a)
    except u2_client.ServerError as e:
        print("%s: %s" % (label, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
