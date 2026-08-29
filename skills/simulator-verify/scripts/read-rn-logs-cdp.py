#!/usr/bin/env python3
"""Read React Native console.* output via Metro's CDP inspector proxy.

On RN >= 0.77 (New Architecture + Hermes / Fusebox) console logs go ONLY to
React Native DevTools over the Chrome DevTools Protocol - they no longer reach
os_log (`read-rn-logs.sh` finds nothing) or the Metro terminal. This script
taps the same channel programmatically: it lists Metro's inspector targets,
connects to the app's main JS runtime over a raw WebSocket (stdlib only, no
dependencies), enables the Runtime domain and streams Runtime.consoleAPICalled
events.

Usage:
  read-rn-logs-cdp.py [--port 8081] [--seconds 10] [--grep PATTERN]
                      [--device SUBSTRING] [--app BUNDLE_ID] [--page N]
                      [--all-runtimes] [--json]

  --port          Metro port (default: $METRO_PORT or 8081)
  --seconds       how long to listen; 0 = until Ctrl-C (default 10)
  --grep          only print lines whose message matches this regex
  --device        pick the target whose deviceName contains this substring
  --app           pick the target whose appId equals this bundle id
  --page          connect to an explicit page id (skips target selection)
  --all-runtimes  include worklet runtimes (Reanimated UI, etc.), not just
                  the main JS runtime
  --json          print raw consoleAPICalled params as JSON lines
  --no-follow     stop when the runtime goes away instead of waiting for it
                  to come back

Notes:
- Runtime.enable makes Hermes REPLAY its buffered console history, so logs
  emitted shortly before the tap connects still show up (they carry their
  original timestamps).
- Metro closes the socket every time the app restarts (relaunch, reload with
  a new runtime, crash) - that is normal, not a fault. By default the tap
  therefore WAITS for the same app on the same device to reappear in
  /json/list and reconnects; Runtime.enable on the new runtime replays what
  it logged while nobody was attached, so a relaunch loses nothing. Before
  2026-08-29 the script exited on the first close and a whole flow could run
  unlogged (journal sim-rig). --no-follow restores the old behaviour.
- One debugger per page: if React Native DevTools is already attached to the
  same runtime, the proxy may drop one of the clients. Disconnect DevTools
  first if the tap gets no events.
- With several simulators on one Metro this refuses to guess: pass --device.
"""

import argparse
import base64
import json
import os
import re
import secrets
import socket
import struct
import sys
import time
import urllib.request
from datetime import datetime


def fetch_targets(port):
    with urllib.request.urlopen(f"http://localhost:{port}/json/list", timeout=5) as r:
        return json.load(r)


def pick_target(targets, args, quiet=False):
    """Choose the runtime to tap. quiet=True returns None instead of exiting when
    nothing matches - the reconnect loop polls with it while the app restarts."""
    if args.page is not None:
        for t in targets:
            if t["webSocketDebuggerUrl"].endswith(f"page={args.page}"):
                return t
        if quiet:
            return None
        sys.exit(f"no target with page={args.page}; run with no --page to list candidates")

    candidates = [t for t in targets if t.get("type") == "node"]
    if args.app:
        candidates = [t for t in candidates if t.get("appId") == args.app]
    if args.device:
        candidates = [t for t in candidates if args.device.lower() in t.get("deviceName", "").lower()]

    if not args.all_runtimes:
        main = [
            t for t in candidates
            if t.get("reactNative", {}).get("capabilities", {}).get("prefersFuseboxFrontend")
        ]
        if main:
            candidates = main

    devices = {t.get("deviceName", "?") for t in candidates}
    if len(devices) > 1:
        if quiet:
            return None
        print("Multiple devices on this Metro - refusing to guess. Pass --device:", file=sys.stderr)
        for d in sorted(devices):
            print(f"  {d}", file=sys.stderr)
        sys.exit(2)

    if not candidates:
        if quiet:
            return None
        print(f"No matching inspector targets on port {args.port}. All targets:", file=sys.stderr)
        for t in targets:
            print(f"  {t.get('appId')} | {t.get('deviceName')} | {t.get('description')} | "
                  f"{t['webSocketDebuggerUrl']}", file=sys.stderr)
        sys.exit(1)

    return candidates[0]


class WsClient:
    """Minimal RFC 6455 client for localhost text-frame traffic."""

    def __init__(self, url, timeout):
        m = re.match(r"ws://([^:/]+):(\d+)(/.*)", url)
        if not m:
            sys.exit(f"unsupported ws url: {url}")
        host, port, path = m.group(1), int(m.group(2)), m.group(3)
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(timeout)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(handshake.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                sys.exit("websocket handshake: connection closed")
            response += chunk
        status = response.split(b"\r\n", 1)[0]
        if b"101" not in status:
            sys.exit(f"websocket handshake failed: {status.decode(errors='replace')}")
        self.buffer = response.split(b"\r\n\r\n", 1)[1]
        self.fragments = []

    def send_text(self, text):
        payload = text.encode()
        mask = secrets.token_bytes(4)
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _read_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def recv_message(self):
        """Return the next complete text message, or None on close."""
        while True:
            b1, b2 = self._read_exact(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            masked, length = b2 & 0x80, b2 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 8:
                return None
            if opcode == 9:
                pong_mask = secrets.token_bytes(4)
                frame = bytearray([0x8A, 0x80 | len(payload)]) + pong_mask
                frame += bytes(b ^ pong_mask[i % 4] for i, b in enumerate(payload))
                self.sock.sendall(bytes(frame))
                continue
            if opcode == 10:
                continue
            self.fragments.append(payload)
            if fin:
                message = b"".join(self.fragments)
                self.fragments = []
                return message.decode(errors="replace")

    def close(self):
        try:
            self.sock.sendall(bytes([0x88, 0x80]) + secrets.token_bytes(4))
        except OSError:
            pass
        self.sock.close()


def format_arg(arg):
    if "value" in arg:
        v = arg["value"]
        return v if isinstance(v, str) else json.dumps(v)
    if "unserializableValue" in arg:
        return arg["unserializableValue"]
    preview = arg.get("preview")
    if preview and preview.get("properties") is not None:
        inner = ", ".join(f"{p.get('name')}: {p.get('value')}" for p in preview["properties"])
        return f"{{{inner}}}"
    return arg.get("description", arg.get("type", "?"))


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--port", type=int, default=int(os.environ.get("METRO_PORT", "8081")))
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--grep")
    parser.add_argument("--device")
    parser.add_argument("--app")
    parser.add_argument("--page", type=int)
    parser.add_argument("--all-runtimes", action="store_true")
    parser.add_argument("--json", action="store_true", dest="raw_json")
    parser.add_argument("--no-follow", action="store_true")
    args = parser.parse_args()

    try:
        targets = fetch_targets(args.port)
    except OSError as e:
        sys.exit(f"cannot reach Metro inspector on port {args.port}: {e}")
    if not targets:
        sys.exit(f"Metro on port {args.port} reports no inspector targets - is the app running?")

    target = pick_target(targets, args)
    print(f"# tapping {target.get('appId')} on {target.get('deviceName')} "
          f"[{target.get('description')}] via port {args.port}", file=sys.stderr)

    # After a restart the app comes back as a NEW page id; what identifies "the
    # same app" across restarts is bundle id + device, so pin both for the
    # reconnect search even when the first pick was made by elimination.
    args.app = args.app or target.get("appId")
    args.device = args.device or target.get("deviceName")
    args.page = None

    pattern = re.compile(args.grep) if args.grep else None
    deadline = time.monotonic() + args.seconds if args.seconds > 0 else None
    matched = 0

    def expired():
        return deadline is not None and time.monotonic() > deadline

    def wait_for_target():
        """Poll /json/list until the pinned app is back (or the deadline hits)."""
        while not expired():
            time.sleep(0.5)
            try:
                found = pick_target(fetch_targets(args.port), args, quiet=True)
            except OSError:
                found = None
            if found is not None:
                return found
        return None

    try:
        while True:
            ws = WsClient(target["webSocketDebuggerUrl"], timeout=1.0)
            ws.send_text(json.dumps({"id": 1, "method": "Runtime.enable"}))
            closed = False
            try:
                while not expired():
                    try:
                        message = ws.recv_message()
                    except socket.timeout:
                        continue
                    except ConnectionError:
                        message = None
                    if message is None:
                        closed = True
                        break
                    try:
                        event = json.loads(message)
                    except ValueError:
                        continue
                    if event.get("method") != "Runtime.consoleAPICalled":
                        continue
                    params = event["params"]
                    text = " ".join(format_arg(a) for a in params.get("args", []))
                    if pattern and not pattern.search(text):
                        continue
                    matched += 1
                    if args.raw_json:
                        print(json.dumps(params))
                    else:
                        ts = datetime.fromtimestamp(params.get("timestamp", 0) / 1000).strftime("%H:%M:%S.%f")[:-3]
                        print(f"[{ts}] {params.get('type', 'log').upper()} {text}")
                    sys.stdout.flush()
            finally:
                ws.close()
            if not closed or args.no_follow or expired():
                if closed:
                    print("# websocket closed by Metro (app restarted, or another debugger attached) - not following",
                          file=sys.stderr)
                break
            print("# websocket closed by Metro (app restarted?) - waiting for "
                  f"{args.app} on {args.device} to come back", file=sys.stderr)
            target = wait_for_target()
            if target is None:
                print("# runtime did not come back before the deadline", file=sys.stderr)
                break
            print(f"# reconnected to {target.get('appId')} on {target.get('deviceName')} "
                  f"[{target.get('description')}] - buffered logs replay below", file=sys.stderr)
    except KeyboardInterrupt:
        pass

    if matched == 0:
        print("# no console events matched. If DevTools is open on this app, close it and retry.",
              file=sys.stderr)


if __name__ == "__main__":
    main()
