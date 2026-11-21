#!/usr/bin/env python3
"""Shared plumbing of the Android driver: which host port leads to which device's
UiAutomator2 server, who else holds UiAutomation on the device, and the one session
every command reuses.

  u2_client.py port    --serial S [--want P] [--allocate]   < `adb forward --list`
  u2_client.py foreign                                      < `adb shell ps -A -o PID,NAME,ARGS`
  u2_client.py session --port P [--new]
  u2_client.py health  --port P [--timeout S]

`port` prints the host port and exits 0; exit 2 with the reason on stderr when the port is
refused (forwarded to another device), exit 3 when (without --allocate) no forward exists.
`foreign` prints one line per other UiAutomation client (`<pid> <tool>: <args>`); exit 1
when there is one, 0 when the device is clear.
`session` prints `<session id> reused|new` after re-applying the two settings.
`health` prints `<bytes>` of a real /source; exit 1 with the cause when it does not come.

Why every part exists (measured on API 34/35/36 emulators, UiAutomator2 server 11.2.4):
  - The server's port on the device is always 6790; the host side is an `adb forward`
    line `<serial> tcp:<host port> tcp:6790`. That line is the only record of which
    device a host port drives - two emulators look identical over HTTP.
  - A second POST /session silently invalidates the first, and EVERY new session is back
    to waitForIdleTimeout=10000 and disableIdLocatorAutocompletion=false. At 10000 every
    call on a screen with an endless animation takes 10 s; with autocompletion on, an id
    lookup prefixes the package and finds no bare testID. So the session is reused from
    GET /sessions and both settings are re-applied on every command.
  - /status answers ready while UiAutomation is dead (after an adbd restart /source then
    waits 10 s and fails), so health is a real /source with a short timeout.
  - Only one UiAutomation client per device: the first one wins and the losers fail
    silently or after 10-19 s. Hence the process check before a start.
"""
import argparse
import json
import re
import socket
import sys
import urllib.error
import urllib.request

DEVICE_PORT = 6790
PORT_RANGE = range(8210, 8230)
SETTINGS = {"waitForIdleTimeout": 0, "disableIdLocatorAutocompletion": True}
OWN_PACKAGES = ("io.appium.uiautomator2.server", "io.appium.uiautomator2.server.test")


class PortRefused(Exception):
    """The requested host port cannot drive the requested device. `missing` = there is
    simply no forward yet (the server was never started), not a conflict."""

    def __init__(self, msg, missing=False):
        super().__init__(msg)
        self.missing = missing


class ServerError(Exception):
    """The server did not answer as a working UiAutomator2 server would."""


# --- adb forward --list -------------------------------------------------------------

def parse_forwards(text):
    """`adb forward --list` -> [(serial, host_port or None, remote)]. Only tcp host
    sides get a port; other local kinds (localabstract:...) keep None."""
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        serial, local, remote = parts
        port = None
        m = re.fullmatch(r"tcp:(\d+)", local)
        if m:
            port = int(m.group(1))
        out.append((serial, port, remote))
    return out


def pick_port(serial, forwards, want=None, allocate=False, is_free=None):
    """The host port for `serial`'s server, by the rule the driver documents:
    1. `want` (U2_PORT) when given - refused if that port is forwarded for another
       device, or for this device to something other than the server;
    2. else this device's existing forward to tcp:6790;
    3. else, with `allocate`, the first port in 8210-8229 that no forward uses and
       `is_free(port)` accepts.
    Raises PortRefused with the reason."""
    remote = "tcp:%d" % DEVICE_PORT
    if want is not None:
        for s, p, r in forwards:
            if p != want:
                continue
            if s != serial:
                raise PortRefused(
                    ":%d is forwarded to %s (%s), not %s - everything sent through it would "
                    "reach the other device" % (want, s, r, serial))
            if r != remote:
                raise PortRefused(
                    ":%d is forwarded on %s to %s, not to the UiAutomator2 server (%s)"
                    % (want, serial, r, remote))
        return want
    for s, p, r in forwards:
        if s == serial and r == remote and p is not None:
            return p
    if not allocate:
        raise PortRefused("no host port is forwarded to %s's UiAutomator2 server (%s)" % (serial, remote),
                          missing=True)
    used = {p for _, p, _ in forwards if p is not None}
    for p in PORT_RANGE:
        if p in used:
            continue
        if is_free is None or is_free(p):
            return p
    raise PortRefused("every port in %d-%d is taken" % (PORT_RANGE[0], PORT_RANGE[-1]))


def port_is_free(port):
    """Nothing listens on localhost:port (connect refused)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.3)
        return s.connect_ex(("127.0.0.1", port)) != 0


# --- other UiAutomation clients -----------------------------------------------------

# (pattern on the NAME column, pattern on ARGS, tool name). Measured: a running
# `uiautomator dump` is a process NAMEd `uiautomator`; a shell loop around it carries the
# command in its ARGS. mobilecli's server is an app_process with its class in ARGS. The
# Maestro and agent-device entries are their package names (process names not measured).
FOREIGN = (
    (r"^uiautomator$", None, "uiautomator"),
    (None, r"\buiautomator +(dump|runtest|events)\b", "uiautomator"),
    (None, r"com\.mobilenext\.mobilecli\.DeviceServer", "mobilecli"),
    (None, r"dev\.mobile\.maestro", "Maestro"),
    (None, r"com\.callstack\.agentdevice", "agent-device"),
)


def foreign_clients(ps_text):
    """`ps -A -o PID,NAME,ARGS` from the device -> [(pid, tool, args)] of every process
    that holds (or is about to hold) UiAutomation and is not this driver's own server."""
    out = []
    for line in ps_text.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        pid, name = parts[0], parts[1]
        args = parts[2] if len(parts) > 2 else ""
        if name in OWN_PACKAGES or OWN_PACKAGES[1] + "/" in args:
            continue
        tool = None
        for name_re, args_re, label in FOREIGN:
            if name_re and re.search(name_re, name):
                tool = label
            elif args_re and re.search(args_re, args):
                tool = label
            if tool:
                break
        if tool is None:
            m = re.search(r"\binstrument\b.*?(\S+/\S+)\s*$", args)
            if m and "com.android.commands.am.Am" in args:
                tool = "instrumentation " + m.group(1)
        if tool:
            out.append((int(pid), tool, args))
    return out


# --- HTTP to the server -------------------------------------------------------------

class U2:
    def __init__(self, port, timeout=10):
        self.root = "http://127.0.0.1:%d" % port
        self.timeout = timeout
        self.sid = None

    def call(self, method, path, body=None, timeout=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.root + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            # The server sends its errors as JSON bodies with 4xx/5xx codes.
            with e:
                raw = e.read()
        except (urllib.error.URLError, OSError) as e:
            raise ServerError("no answer from the UiAutomator2 server on %s%s (%s)"
                              % (self.root, path, getattr(e, "reason", e)))
        try:
            # The page source is XML inside a JSON string and carries control characters.
            return json.loads(raw.decode("utf-8", "replace"), strict=False)
        except ValueError:
            raise ServerError("not a JSON answer from %s%s: %r" % (self.root, path, raw[:200]))

    @staticmethod
    def error_of(resp):
        v = resp.get("value") if isinstance(resp, dict) else None
        if isinstance(v, dict) and v.get("error"):
            lines = str(v.get("message") or "").splitlines()
            return "%s: %s" % (v.get("error"), lines[0][:300] if lines else "(no message)")
        return None

    def existing_session(self):
        resp = self.call("GET", "/sessions", timeout=5)
        return session_from_list(resp)

    def session(self, new=False):
        """Reuse the server's session (or create one), then re-apply SETTINGS.
        Returns (sid, "reused"|"new")."""
        how = "reused"
        sid = None if new else self.existing_session()
        if not sid:
            resp = self.call("POST", "/session",
                             {"capabilities": {"alwaysMatch": {"platformName": "Android"}}}, timeout=20)
            err = self.error_of(resp)
            if err:
                raise ServerError("the server refused to open a session - " + err)
            sid = (resp.get("value") or {}).get("sessionId") or resp.get("sessionId")
            if not sid:
                raise ServerError("POST /session returned no session id: %r" % str(resp)[:200])
            how = "new"
        resp = self.call("POST", "/session/%s/appium/settings" % sid, {"settings": SETTINGS}, timeout=5)
        err = self.error_of(resp)
        if err:
            raise ServerError("the server refused the settings - " + err)
        self.sid = sid
        return sid, how

    def settings(self):
        resp = self.call("GET", "/session/%s/appium/settings" % self.sid, timeout=5)
        return resp.get("value") or {}

    def source(self, timeout=3):
        resp = self.call("GET", "/session/%s/source" % self.sid, timeout=timeout)
        err = self.error_of(resp)
        if err:
            raise ServerError("/source failed - " + err)
        v = resp.get("value")
        if not isinstance(v, str) or "<hierarchy" not in v:
            raise ServerError("/source returned no element tree: %r" % str(v)[:200])
        return v


def session_from_list(resp):
    """GET /sessions -> the first session id, or None. The server answers
    {"value": [{"id": ..., "capabilities": ...}]}."""
    v = resp.get("value") if isinstance(resp, dict) else None
    if isinstance(v, list):
        for s in v:
            if isinstance(s, dict) and s.get("id"):
                return s["id"]
    return None


# --- command line -------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("port")
    p.add_argument("--serial", required=True)
    p.add_argument("--want", type=int)
    p.add_argument("--allocate", action="store_true")
    sub.add_parser("foreign")
    s = sub.add_parser("session")
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--new", action="store_true")
    h = sub.add_parser("health")
    h.add_argument("--port", type=int, required=True)
    h.add_argument("--timeout", type=float, default=3)
    a = ap.parse_args(argv)

    if a.cmd == "port":
        try:
            print(pick_port(a.serial, parse_forwards(sys.stdin.read()), a.want, a.allocate, port_is_free))
        except PortRefused as e:
            print(str(e), file=sys.stderr)
            return 3 if e.missing else 2
        return 0
    if a.cmd == "foreign":
        found = foreign_clients(sys.stdin.read())
        for pid, tool, args in found:
            print("%d %s: %s" % (pid, tool, args[:200]))
        return 1 if found else 0
    u = U2(a.port)
    try:
        if a.cmd == "session":
            sid, how = u.session(new=a.new)
            got = u.settings()
            print("%s %s waitForIdleTimeout=%s disableIdLocatorAutocompletion=%s" % (
                sid, how, got.get("waitForIdleTimeout"),
                str(got.get("disableIdLocatorAutocompletion")).lower()))
            return 0
        if a.cmd == "health":
            u.session()
            print(len(u.source(timeout=a.timeout).encode()))
            return 0
    except ServerError as e:
        print(str(e), file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
