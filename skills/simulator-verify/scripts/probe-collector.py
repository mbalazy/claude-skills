#!/usr/bin/env python3
"""probe-collector.py - read instrumentation out of the app over HTTP instead of the log.

console.log is only worth adding if you can read it back, and there are two situations where
you cannot. On a physical device with the New Architecture + Hermes, JS logs go to the
DevTools inspector and never reach anything idevicesyslog relays. On any target, a large
payload (an element tree, a serialized object) gets truncated and line-wrapped in the system
log into something unparseable.

So let the app hand the data over directly: it POSTs (or GETs) to this collector on the Mac,
and every request lands in a file, whole, one JSON object per line.

    scripts/probe-collector.py                    # :8099 -> /tmp/probe.log
    scripts/probe-collector.py --port 9100 --out /tmp/layout.log
    scripts/probe-collector.py --stdout           # also echo each line as it arrives

In the app (throwaway instrumentation - remove it before committing):

    fetch('http://localhost:8099', {              // simulator
      method: 'POST',
      body: JSON.stringify({ tag: 'SEARCH_INPUT', ...e.nativeEvent.layout }),
    });

A physical device needs the Mac's LAN address instead of localhost; this script prints the
usable addresses on startup. A GET works too, so the shortest possible probe is
`fetch('http://localhost:8099/?tag=mounted')` with no body at all.
"""

import argparse
import json
import socket
import subprocess
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs


def lan_addresses():
    addrs = []
    for iface in ("en0", "en1", "en10"):
        try:
            ip = subprocess.run(
                ["ipconfig", "getifaddr", iface], capture_output=True, text=True, timeout=2
            ).stdout.strip()
        except Exception:
            continue
        if ip:
            addrs.append((iface, ip))
    return addrs


def make_handler(out_path, echo):
    class Handler(BaseHTTPRequestHandler):
        def _record(self, payload):
            line = json.dumps(
                {"at": datetime.now().strftime("%H:%M:%S.%f")[:-3], "data": payload},
                ensure_ascii=False,
            )
            with open(out_path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            if echo:
                print(line, flush=True)

        def _ok(self):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            # the app may probe from a webview or a dev-menu fetch; keep CORS out of the way
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = raw
            self._record(payload)
            self._ok()

        def do_GET(self):
            query = parse_qs(urlparse(self.path).query)
            self._record({k: v[0] if len(v) == 1 else v for k, v in query.items()})
            self._ok()

        def do_OPTIONS(self):
            self.send_response(200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass  # the payload file is the output; request lines are noise

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--out", default="/tmp/probe.log")
    ap.add_argument("--stdout", action="store_true", help="echo each received line")
    args = ap.parse_args()

    try:
        server = HTTPServer(("0.0.0.0", args.port), make_handler(args.out, args.stdout))
    except OSError as exc:
        # a busy port is almost always another collector or a Metro - say so instead of
        # dying with a bare traceback
        print(f"cannot listen on :{args.port} - {exc}", file=sys.stderr)
        print("something else owns it: lsof -ti tcp:%d -sTCP:LISTEN" % args.port, file=sys.stderr)
        return 2

    print(f"probe collector on :{args.port} -> {args.out}")
    print(f"  simulator: http://localhost:{args.port}")
    for iface, ip in lan_addresses():
        print(f"  device ({iface}): http://{ip}:{args.port}")
    print("  read it with: tail -f %s" % args.out)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
