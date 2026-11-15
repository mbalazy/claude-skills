#!/usr/bin/env python3
"""Address ONE element by its accessibility id (React Native `testID`) instead of
reading the whole tree.

  wda_el.py --port P --sid SID wait  ID [--timeout S] [--exists]
  wda_el.py --port P --sid SID tap   ID
  wda_el.py --port P --sid SID info  ID
  wda_el.py --port P --sid SID type  ID --text TEXT [--append] [--expect VALUE]

Why this exists (measured 2026-11-13/14, a large React Native app, iPhone 17 simulator): a full
`/source` read costs 1.7-4.2s per poll because WebDriverAgent asks the app for the
`visible` attribute of every node; a lookup by accessibility id answers in ~0.13s
and `displayed` on the element it returns in ~0.05s. `displayed` is the SAME
visibility function the tree uses (fb_isVisible), evaluated on a fresh snapshot of
that one element - it agreed with the tree on every identifier of three screens
(Home, Settings, Explore) apart from elements whose visibility flickers in both.

What the lookup really matches - read before relying on it:
  - WebDriverAgent's "accessibility id" is `identifier == X OR (identifier is empty
    AND label == X)`. So a plain TEXT matches elements that have no testID, and
    silently does NOT match the label of an element that has one. Every match is
    reported with `by: "id"` (its label differs from the query, so the testID matched)
    or `by: "id-or-label"` (the label equals the query: most likely a text match).
  - It returns EVERY match, visible or not, in no useful order.
  - Find, `displayed` and `rect` are three requests, not one snapshot: on a screen
    that is still loading the rect can move between them.
  - `<Screen>-screen-root` containers often report displayed=false while the screen
    is plainly up (Home and Settings do, Explore does not). Wait for a real control,
    or pass --exists.
  - Like the tree, the lookup stops at `snapshotMaxDepth` (50).

`tap` presses through `element/<id>/click`, never through the centre of the rect:
WebDriverAgent picks a hittable point, which is the only correct answer for an
element that is partly covered or runs off the screen edge (measured: a title whose
centre sat under the tab bar - the centre tap switched tabs, the click did not).
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request


class SessionLost(Exception):
    """The session this process used was replaced; element ids from it are void."""


class Wda:
    def __init__(self, port, sid):
        self.root = f"http://localhost:{port}"
        self.sid = sid
        self.own = None         # a session this process created and must delete

    @property
    def base(self):
        return f"{self.root}/session/{self.sid}"

    def raw(self, method, url, body=None, timeout=30):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
        try:
            return json.loads(raw)
        except Exception:
            return {"value": {"error": "unreadable response",
                              "message": raw[:200].decode("utf-8", "replace")}}

    def reattach(self):
        """WebDriverAgent holds ONE session: any other driver command creates its own and
        voids this one, and a waiting `waitid` then failed with "invalid session id" while
        the element was on screen (2026-11-14, 3 of 3). Join the session WDA has now
        (`/status` names it) rather than creating one, which would void the other
        command's session in turn; create one only when there is none."""
        cur = self.raw("GET", self.root + "/status", timeout=10).get("sessionId")
        if not cur:
            v = self.raw("POST", self.root + "/session",
                         {"capabilities": {"alwaysMatch": {"platformName": "iOS"}}}).get("value") or {}
            cur = v.get("sessionId")
            if not cur:
                raise RuntimeError(f"could not open a WebDriverAgent session: {v}")
            self.own = cur
        print(f"NOTE: another command replaced the WebDriverAgent session - re-attached to {cur}",
              file=sys.stderr)
        self.sid = cur

    def call(self, method, path, body=None, timeout=30):
        v = self.raw(method, self.base + path, body, timeout).get("value")
        if isinstance(v, dict) and v.get("error") == "invalid session id":
            self.reattach()
            raise SessionLost()
        return v

    def close(self):
        if self.own:
            self.raw("DELETE", f"{self.root}/session/{self.own}", timeout=10)

    def find(self, ident):
        v = self.call("POST", "/elements", {"using": "accessibility id", "value": ident})
        if isinstance(v, dict) and v.get("error"):
            raise RuntimeError(f"{v.get('error')}: {v.get('message', '')[:200]}")
        return [next(iter(e.values())) for e in (v or [])]

    def displayed(self, eid):
        return self.call("GET", f"/element/{eid}/displayed") is True

    def attr(self, eid, name):
        v = self.call("GET", f"/element/{eid}/attribute/{name}")
        return None if isinstance(v, dict) else v

    def describe(self, eid, ident, shown=None):
        r = self.call("GET", f"/element/{eid}/rect") or {}
        typ = (self.attr(eid, "type") or "").replace("XCUIElementType", "")
        name, label, value = self.attr(eid, "name"), self.attr(eid, "label"), self.attr(eid, "value")
        e = {"type": typ}
        if label:
            e["label"] = label
        if name and name != label:
            e["name"] = name
        if value:
            e["value"] = value
        try:
            e["rect"] = [round(r["x"]), round(r["y"]), round(r["width"]), round(r["height"])]
        except Exception:
            e["rect"] = None
        e["displayed"] = self.displayed(eid) if shown is None else shown
        # WDA does not expose the raw identifier of a single element: `name` is the
        # identifier when there is one and the label otherwise. So a match whose label
        # differs from the query was certainly found by its testID; one whose label
        # equals it was found by its text, or by a testID that happens to equal its text.
        e["by"] = "id" if label != ident else "id-or-label"
        return e


def out(obj):
    print(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))


def cmd_wait(w, a):
    started = time.time()
    deadline = started + a.timeout
    polls = 0
    eids, shown = [], []
    err = None
    while True:
        polls += 1
        try:
            eids = w.find(a.id)
            shown = [e for e in eids if w.displayed(e)] if eids and not a.exists else []
            hits = eids if a.exists else shown
            if hits:
                desc = [w.describe(e, a.id, None if a.exists else True) for e in hits]
            err = None
        except SessionLost:         # re-attached; the element ids of this poll are void
            # No `continue`: the deadline below still applies, or a session that keeps
            # being replaced would keep this wait alive forever.
            eids, shown, hits, err = [], [], [], "the session kept being replaced by other commands"
        except Exception as e:      # WDA busy / app restarting: keep polling, report at the end
            eids, shown, hits, err = [], [], [], str(e)
        if hits:
            out(desc)
            mode = "exists" if a.exists else "displayed"
            print(f"matched id '{a.id}' ({mode}) after {polls} poll(s), {time.time() - started:.1f}s",
                  file=sys.stderr)
            return 0
        if time.time() >= deadline:
            print(f"waitid: nothing {'present' if a.exists else 'displayed'} with id '{a.id}' "
                  f"within {a.timeout:g}s ({polls} polls)", file=sys.stderr)
            if eids:
                print(f"  {len(eids)} element(s) with that id EXIST but none is displayed. Screen-root "
                      f"containers often report displayed=false while the screen is up: wait for a real "
                      f"control, or pass --exists.", file=sys.stderr)
                out([w.describe(e, a.id) for e in eids[:5]])
            elif err:
                print(f"  last lookup failed: {err}", file=sys.stderr)
            else:
                print("  no element carries that id (or that exact label with no id) on this screen. "
                      "An id is matched exactly and case-sensitively; `elements --all --grep` lists "
                      "what is there.", file=sys.stderr)
            return 1
        time.sleep(a.interval)


def cmd_info(w, a):
    eids = w.find(a.id)
    if not eids:
        print(f"no element with id '{a.id}' on this screen", file=sys.stderr)
        return 1
    out([w.describe(e, a.id) for e in eids])
    return 0


def pick_displayed(w, ident, verb, done, hint):
    """The ONE displayed element carrying `ident`, as (element id, description), or None
    after explaining on stderr why nothing was done. `verb`/`done` name the command and
    what it did not do ("tapid", "tapped"); `hint` ends the ambiguity message."""
    eids = w.find(ident)
    if not eids:
        print(f"{verb}: no element with id '{ident}' on this screen - nothing was {done}", file=sys.stderr)
        return None
    # Only `displayed` and the frame decide the target; the full description (four
    # more requests per element) is fetched for the one target, or for an error report.
    shown = [e for e in eids if w.displayed(e)]
    if not shown:
        print(f"{verb}: {len(eids)} element(s) with id '{ident}' exist but none is displayed - "
              f"nothing was {done}", file=sys.stderr)
        out([w.describe(e, ident, False) for e in eids[:5]])
        return None
    # React Native often exposes one view twice (the view and its accessibility
    # element) with the identical frame: those are one target. Anything else is a
    # real ambiguity and guessing would act on the wrong thing confidently.
    frames = {json.dumps(w.call("GET", f"/element/{e}/rect"), sort_keys=True) for e in shown} \
        if len(shown) > 1 else {"one"}
    if len(frames) > 1:
        print(f"{verb}: {len(shown)} DISPLAYED elements with id '{ident}' at different places - refusing "
              f"to pick one, nothing was {done}. {hint}", file=sys.stderr)
        out([w.describe(e, ident, True) for e in shown[:8]])
        return None
    return shown[0], w.describe(shown[0], ident, True)


# Element types that take text. Anything else is refused BEFORE any request that could
# touch it: XCTest focuses an element by tapping it, so `typeid` on a button pressed the
# button (2026-11-15: the Filters button opened its screen) and then reported only a
# value mismatch.
TEXT_TYPES = ("TextField", "SecureTextField", "SearchField", "TextView")


def wda_error(v):
    return isinstance(v, dict) and v.get("error")


def cmd_type(w, a):
    # The text is split into what goes INTO the field and a trailing Return. The Return is
    # sent only after the field was read back and holds the right text, so a search never
    # runs for a cut word, and the read-back never expects a "\n" the field cannot hold.
    body = a.text.rstrip("\n")
    submit = a.text[len(body):]
    st = a.state                    # survives a re-run after the session was replaced
    if "expected" not in st:
        got = pick_displayed(w, a.id, "typeid", "typed",
                             "Tap the one you mean by its rect, then `type` into it:")
        if not got:
            return 1
        eid, d = got
        if d["type"] not in TEXT_TYPES:
            print(f"typeid: '{a.id}' is a {d['type'] or 'element of unknown type'}, not a text field - "
                  f"nothing was done (typing would tap it to focus it). Tap it with `tapid`, then "
                  f"address the field that appears.", file=sys.stderr)
            return 1
        st["type"] = d["type"]
        st["placeholder"] = w.attr(eid, "placeholderValue")
        before = ""
        if a.append:
            v = w.attr(eid, "value")
            before = "" if v is None or v == st["placeholder"] else v
        if not a.append:
            v = w.call("POST", f"/element/{eid}/clear", {})
            if wda_error(v):
                print(f"typeid: WebDriverAgent refused to clear '{a.id}': {v.get('error')}: "
                      f"{str(v.get('message', ''))[:300]} - nothing was typed, but the element may have "
                      f"been tapped to focus it: check the screen.", file=sys.stderr)
                return 1
        t0 = time.time()
        v = w.call("POST", f"/element/{eid}/value", {"text": body, "value": list(body)})
        took = time.time() - t0
        if wda_error(v):
            print(f"typeid: WebDriverAgent refused to type into '{a.id}': {v.get('error')}: "
                  f"{str(v.get('message', ''))[:300]} - the element may have been tapped to focus it: "
                  f"check the screen.", file=sys.stderr)
            return 1
        # From here on the text IS in the field. If the session is replaced during the
        # read-back, the re-run must only read again: running the typing again doubled an
        # --append text ('yoga flow flow' with exit 0, 12 of 16 runs, 2026-11-15).
        st["expected"] = a.expect if a.expect is not None else before + body
        st["took"] = took
    if st["type"] == "SecureTextField":
        print(f"NOTE: '{a.id}' is a secure field - its value reads as bullets, so what arrived "
              f"cannot be checked here.", file=sys.stderr)
        value = None
    else:
        # Looked up again by testID: typing can re-render the field, and after a re-run the
        # old element id belongs to a void session. An empty React Native TextInput reports
        # its PLACEHOLDER as its value; that is "".
        found = w.find(a.id)
        raw = w.attr(found[0], "value") if found else None
        value = "" if raw is None or raw == st["placeholder"] else raw
        if st["expected"] not in (raw, value):
            print(f"typeid: the field '{a.id}' holds {value!r}, expected {st['expected']!r}"
                  f"{' - Return was NOT sent' if submit else ''}. If the field formats its input "
                  f"(a mask), pass the formatted value with --expect.", file=sys.stderr)
            return 1
    if submit and not st.get("submitted"):
        found = w.find(a.id)
        if not found:
            print(f"typeid: the field '{a.id}' is gone before Return could be sent - the text was "
                  f"typed, Return was not.", file=sys.stderr)
            return 1
        v = w.call("POST", f"/element/{found[0]}/value", {"text": submit, "value": list(submit)})
        # Only after the call: a request answered "invalid session id" raised SessionLost
        # above and was not executed, so the re-run must still send it - once.
        st["submitted"] = True
        if wda_error(v):
            print(f"typeid: the text was typed and read back, but WebDriverAgent refused the Return: "
                  f"{v.get('error')}: {str(v.get('message', ''))[:300]}", file=sys.stderr)
            return 1
    if st["took"] > 5:
        print(f"NOTE: typing took {st['took']:.1f}s - WebDriverAgent waited for the app to go idle.",
              file=sys.stderr)
    shown = "secure field, not read back" if value is None else f"{value!r} (read back)"
    print(f"typed into id {a.id}: {shown}{', then Return' if submit else ''}")
    return 0


def cmd_tap(w, a):
    got = pick_displayed(w, a.id, "tapid", "tapped", "Tap the one you mean by its rect:")
    if not got:
        return 1
    eid, d = got
    t0 = time.time()
    v = w.call("POST", f"/element/{eid}/click", {})
    took = time.time() - t0
    if isinstance(v, dict) and v.get("error"):
        print(f"tapid: WebDriverAgent refused the click on '{a.id}': {v.get('error')}: "
              f"{str(v.get('message', ''))[:300]}", file=sys.stderr)
        return 1
    if d["by"] != "id":
        print(f"NOTE: '{a.id}' equals the element's LABEL - it was most likely matched by its text, "
              f"not by a testID.", file=sys.stderr)
    if took > 5:
        # Measured 2026-11-14: element/click waits for the app to go idle before AND after
        # the tap, up to waitForIdleTimeout (10s) each. An app that never idles (a focused
        # text field with its caret, a looping animation) turns a 1s tap into ~20.5s.
        print(f"NOTE: the click took {took:.1f}s - WebDriverAgent waited for the app to go idle "
              f"(up to 2 x waitForIdleTimeout). The tap itself landed.", file=sys.stderr)
    print(f"tapped id {a.id} ({d['type']} {d['rect']})")
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--port", required=True)
    ap.add_argument("--sid", required=True)
    ap.add_argument("cmd", choices=["wait", "tap", "info", "type"])
    ap.add_argument("id")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--interval", type=float, default=0.15)
    ap.add_argument("--exists", action="store_true")
    ap.add_argument("--text")
    ap.add_argument("--append", action="store_true")
    ap.add_argument("--expect")
    a = ap.parse_args()
    if a.cmd == "type" and a.text is None:
        print("typeid: --text is required", file=sys.stderr)
        return 2
    a.state = {}                    # what a command already did, kept across re-runs
    w = Wda(a.port, a.sid)
    fn = {"wait": cmd_wait, "tap": cmd_tap, "info": cmd_info, "type": cmd_type}[a.cmd]
    try:
        # A one-shot command whose session was replaced half way runs again from the lookup:
        # its element ids belonged to the old session. One other driver command replaces it
        # TWICE (it opens its own session, then deletes it on exit), so a single retry was
        # not enough (2026-11-14: `el` beside one concurrent `el` failed 3 of 3). Retrying is
        # safe for `tap` too: a request answered "invalid session id" was not executed, so a
        # retry cannot click twice. NOT safe for a request that already succeeded before a
        # LATER one lost the session: `type` records in `a.state` what it did, and a re-run
        # only reads back. Bounded, so a driver that never stops cannot pin it.
        for attempt in range(6):
            try:
                return fn(w, a)
            except SessionLost:
                time.sleep(0.2)
        raise SessionLost()
    except SessionLost:
        print(f"{a.cmd}id: the WebDriverAgent session was replaced 6 times by other commands - "
              f"nothing was done; run it again when the other driver command has finished", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"{a.cmd}id: {e}", file=sys.stderr)
        return 1
    finally:
        w.close()


if __name__ == "__main__":
    sys.exit(main())
