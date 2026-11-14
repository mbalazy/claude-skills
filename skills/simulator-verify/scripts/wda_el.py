#!/usr/bin/env python3
"""Address ONE element by its accessibility id (React Native `testID`) instead of
reading the whole tree.

  wda_el.py --port P --sid SID wait  ID [--timeout S] [--exists]
  wda_el.py --port P --sid SID tap   ID
  wda_el.py --port P --sid SID info  ID

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


class Wda:
    def __init__(self, port, sid):
        self.base = f"http://localhost:{port}/session/{sid}"

    def call(self, method, path, body=None, timeout=30):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
        try:
            return json.loads(raw).get("value")
        except Exception:
            return {"error": "unreadable response", "message": raw[:200].decode("utf-8", "replace")}

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
            err = None
        except Exception as e:      # WDA busy / app restarting: keep polling, report at the end
            eids, err = [], str(e)
        shown = [e for e in eids if w.displayed(e)] if eids and not a.exists else []
        hits = eids if a.exists else shown
        if hits:
            out([w.describe(e, a.id, None if a.exists else True) for e in hits])
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


def cmd_tap(w, a):
    eids = w.find(a.id)
    if not eids:
        print(f"tapid: no element with id '{a.id}' on this screen - nothing was tapped", file=sys.stderr)
        return 1
    # Only `displayed` and the frame decide what gets tapped; the full description (four
    # more requests per element) is fetched for the one target, or for an error report.
    shown = [e for e in eids if w.displayed(e)]
    if not shown:
        print(f"tapid: {len(eids)} element(s) with id '{a.id}' exist but none is displayed - "
              f"nothing was tapped", file=sys.stderr)
        out([w.describe(e, a.id, False) for e in eids[:5]])
        return 1
    # React Native often exposes one view twice (the view and its accessibility
    # element) with the identical frame: those are one target. Anything else is a
    # real ambiguity and guessing would tap the wrong thing confidently.
    frames = {json.dumps(w.call("GET", f"/element/{e}/rect"), sort_keys=True) for e in shown} \
        if len(shown) > 1 else {"one"}
    if len(frames) > 1:
        print(f"tapid: {len(shown)} DISPLAYED elements with id '{a.id}' at different places - refusing "
              f"to pick one, nothing was tapped. Tap the one you mean by its rect:", file=sys.stderr)
        out([w.describe(e, a.id, True) for e in shown[:8]])
        return 1
    eid = shown[0]
    d = w.describe(eid, a.id, True)
    v = w.call("POST", f"/element/{eid}/click", {})
    if isinstance(v, dict) and v.get("error"):
        print(f"tapid: WebDriverAgent refused the click on '{a.id}': {v.get('error')}: "
              f"{str(v.get('message', ''))[:300]}", file=sys.stderr)
        return 1
    if d["by"] != "id":
        print(f"NOTE: '{a.id}' equals the element's LABEL - it was most likely matched by its text, "
              f"not by a testID.", file=sys.stderr)
    print(f"tapped id {a.id} ({d['type']} {d['rect']})")
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--port", required=True)
    ap.add_argument("--sid", required=True)
    ap.add_argument("cmd", choices=["wait", "tap", "info"])
    ap.add_argument("id")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--interval", type=float, default=0.15)
    ap.add_argument("--exists", action="store_true")
    a = ap.parse_args()
    w = Wda(a.port, a.sid)
    try:
        return {"wait": cmd_wait, "tap": cmd_tap, "info": cmd_info}[a.cmd](w, a)
    except Exception as e:
        print(f"{a.cmd}id: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
