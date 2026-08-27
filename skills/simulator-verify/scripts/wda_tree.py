#!/usr/bin/env python3
"""Read (and optionally wait for) the WebDriverAgent accessibility tree.

Split out of sim-ui.sh so that `elements` and `waitfor` share ONE definition of
"what counts as an element". Without --match it prints the tree, exactly as the
inline version in sim-ui.sh used to. With --match it polls until an element
matches, which is what replaces a fixed `sleep` after a tap or a relaunch: the
wait then costs what the app actually needs instead of a guessed constant.

  curl -s "$WDA/source?format=json" | wda_tree.py            # filtered tree, from stdin
  curl -s "$WDA/source?format=json" | wda_tree.py --all      # every visible node
  wda_tree.py --port 8101 --match 'Schedule' --timeout 10    # poll until it matches

Reading the one-shot tree from stdin keeps curl's download overlapping the parse the
way the original inline version did; fetching it here instead cost ~0.1s per call.
"""
import argparse
import json
import re
import sys
import time

ACCEPTED = {"TextField", "Button", "Switch", "Icon", "SearchField", "StaticText", "Image"}


def fetch(port, timeout=20):
    import urllib.request
    url = f"http://localhost:{port}/source?format=json"
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)["value"]


def elements(src, show_all):
    out, seen = [], set()

    def walk(n):
        r = n.get("rect", {})
        visible = n.get("isVisible") == "1" and r.get("width", 0) > 0 and r.get("height", 0) > 0
        labeled = n.get("label") or n.get("name") or n.get("rawIdentifier")
        if n.get("type") in ("TextField", "SearchField"):
            labeled = labeled or n.get("value")
        if visible and (show_all or (n.get("type") in ACCEPTED and labeled)):
            e = {"type": n.get("type")}
            if n.get("label"):
                e["label"] = n["label"]
            if n.get("name") and n.get("name") != n.get("label"):
                e["name"] = n["name"]
            if n.get("value"):
                e["value"] = n["value"]
            e["rect"] = [round(r["x"]), round(r["y"]), round(r["width"]), round(r["height"])]
            key = json.dumps(e)
            if key not in seen:
                seen.add(key)
                out.append(e)
        for c in n.get("children") or []:
            walk(c)

    walk(src)
    return out


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--port", default="8100")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--match")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--interval", type=float, default=0.35)
    a = ap.parse_args()

    if not a.match:
        src = json.load(sys.stdin)["value"] if not sys.stdin.isatty() else fetch(a.port)
        print(json.dumps(elements(src, a.all), separators=(",", ":")))
        return 0

    pat = re.compile(a.match, re.I)
    deadline = time.time() + a.timeout
    polls = 0
    while True:
        polls += 1
        try:
            els = elements(fetch(a.port), a.all)
        except Exception as exc:
            els = []
            last_err = exc
        hits = [e for e in els
                if pat.search(" ".join(str(e.get(k, "")) for k in ("type", "label", "name", "value")))]
        if hits:
            print(json.dumps(hits, separators=(",", ":")))
            print(f"matched /{a.match}/ after {polls} poll(s), "
                  f"{time.time() - (deadline - a.timeout):.1f}s", file=sys.stderr)
            return 0
        if time.time() >= deadline:
            print(f"waitfor: nothing matching /{a.match}/ within {a.timeout:g}s "
                  f"({polls} polls, {len(els)} elements on the last one)", file=sys.stderr)
            return 1
        time.sleep(a.interval)


if __name__ == "__main__":
    sys.exit(main())
