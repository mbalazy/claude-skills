#!/usr/bin/env python3
"""Unit tests of u2_client.py that need no device: port selection, `adb forward --list`
and `ps` parsing, and the session handling against a fake UiAutomator2 server.

  python3 -m unittest discover -s skills/simulator-verify/scripts -p 'test_*.py'
"""
import http.server
import json
import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import u2_client as u2  # noqa: E402

FORWARDS = """\
emulator-5560 tcp:8210 tcp:6790
emulator-5562 tcp:8211 tcp:6790
emulator-5562 tcp:8121 tcp:8121
emulator-5560 localabstract:foo tcp:7000
"""


class ParseForwards(unittest.TestCase):
    def test_lines(self):
        got = u2.parse_forwards(FORWARDS + "\ngarbage line\n")
        self.assertEqual(got, [
            ("emulator-5560", 8210, "tcp:6790"),
            ("emulator-5562", 8211, "tcp:6790"),
            ("emulator-5562", 8121, "tcp:8121"),
            ("emulator-5560", None, "tcp:7000"),
        ])

    def test_empty(self):
        self.assertEqual(u2.parse_forwards(""), [])


class PickPort(unittest.TestCase):
    fw = u2.parse_forwards(FORWARDS)

    def test_existing_forward_of_this_serial(self):
        self.assertEqual(u2.pick_port("emulator-5562", self.fw), 8211)

    def test_wanted_port_of_this_serial(self):
        self.assertEqual(u2.pick_port("emulator-5560", self.fw, want=8210), 8210)

    def test_wanted_port_unused_is_taken_as_given(self):
        self.assertEqual(u2.pick_port("emulator-5560", self.fw, want=8225), 8225)

    def test_wanted_port_of_another_serial_is_refused_naming_the_owner(self):
        with self.assertRaises(u2.PortRefused) as c:
            u2.pick_port("emulator-5560", self.fw, want=8211)
        self.assertIn("emulator-5562", str(c.exception))

    def test_wanted_port_forwarded_elsewhere_on_this_serial_is_refused(self):
        with self.assertRaises(u2.PortRefused) as c:
            u2.pick_port("emulator-5562", self.fw, want=8121)
        self.assertIn("tcp:8121", str(c.exception))

    def test_no_forward_without_allocate_is_refused_as_missing(self):
        with self.assertRaises(u2.PortRefused) as c:
            u2.pick_port("emulator-5570", self.fw)
        self.assertTrue(c.exception.missing)

    def test_a_conflict_is_not_missing(self):
        with self.assertRaises(u2.PortRefused) as c:
            u2.pick_port("emulator-5560", self.fw, want=8211)
        self.assertFalse(c.exception.missing)

    def test_allocate_skips_forwarded_and_busy_ports(self):
        busy = {8212}
        got = u2.pick_port("emulator-5570", self.fw, allocate=True, is_free=lambda p: p not in busy)
        self.assertEqual(got, 8213)

    def test_allocate_reuses_the_existing_forward_first(self):
        self.assertEqual(u2.pick_port("emulator-5560", self.fw, allocate=True, is_free=lambda p: True), 8210)

    def test_allocate_with_every_port_taken(self):
        with self.assertRaises(u2.PortRefused):
            u2.pick_port("emulator-5570", [], allocate=True, is_free=lambda p: False)


PS = """\
  PID NAME                        ARGS
    1 init                        /system/bin/init second_stage
 4101 app_process                 app_process /system/bin com.android.commands.am.Am instrument -w -e disableAnalytics true io.appium.uiautomator2.server.test/androidx.test.runner.AndroidJUnitRunner
 4120 io.appium.uiautomator2.server io.appium.uiautomator2.server
 5145 sh                          sh -c while true; do uiautomator dump /dev/null >/dev/null 2>&1; done
 5147 uiautomator                 uiautomator
 6001 app_process                 app_process /data/local/tmp com.mobilenext.mobilecli.DeviceServer --idle-timeout-ms=1800000
 6100 app_process                 app_process /system/bin com.android.commands.am.Am instrument -w com.example.other.test/androidx.test.runner.AndroidJUnitRunner
 7000 com.example.svcli           com.example.svcli
"""


class ForeignClients(unittest.TestCase):
    def test_own_server_is_not_foreign(self):
        own = [l for l in PS.splitlines() if "uiautomator2" in l]
        self.assertEqual(u2.foreign_clients("\n".join(own)), [])

    def test_every_other_holder_is_named(self):
        got = {(pid, tool) for pid, tool, _ in u2.foreign_clients(PS)}
        self.assertEqual(got, {
            (5145, "uiautomator"),
            (5147, "uiautomator"),
            (6001, "mobilecli"),
            (6100, "instrumentation com.example.other.test/androidx.test.runner.AndroidJUnitRunner"),
        })

    def test_header_and_apps_are_ignored(self):
        self.assertEqual(u2.foreign_clients(PS.splitlines()[0] + "\n 7000 com.example.svcli com.example.svcli"), [])


class FakeServer(http.server.BaseHTTPRequestHandler):
    """A UiAutomator2 server as far as the session logic sees it."""
    state = {}

    def log_message(self, *a):
        pass

    def reply(self, obj, code=200):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        st = self.state
        st["calls"].append(("GET", self.path))
        if self.path == "/sessions":
            return self.reply({"value": [{"id": s} for s in st["sessions"]]})
        if self.path.endswith("/appium/settings"):
            return self.reply({"value": st["settings"]})
        if self.path.endswith("/source"):
            if st.get("source_error"):
                return self.reply({"value": {"error": "unknown error", "message": st["source_error"]}}, 500)
            return self.reply({"value": '<?xml version="1.0"?><hierarchy rotation="0">&#10;</hierarchy>'})
        self.reply({"value": {"error": "unknown command", "message": self.path}}, 404)

    def do_POST(self):
        st = self.state
        b = self.body()
        st["calls"].append(("POST", self.path))
        if self.path == "/session":
            if st.get("session_error"):
                return self.reply({"value": {"error": "session not created", "message": st["session_error"]}}, 500)
            sid = "sid-%d" % (len(st["created"]) + 1)
            st["created"].append(sid)
            st["sessions"] = [sid]            # a new session replaces the old one
            st["settings"] = {"waitForIdleTimeout": 10000, "disableIdLocatorAutocompletion": False}
            return self.reply({"value": {"sessionId": sid, "capabilities": {}}})
        if self.path.endswith("/appium/settings"):
            st["settings"].update(b["settings"])
            return self.reply({"value": None})
        self.reply({"value": {"error": "unknown command", "message": self.path}}, 404)


class Session(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = http.server.HTTPServer(("127.0.0.1", 0), FakeServer)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def setUp(self):
        FakeServer.state = {"calls": [], "sessions": [], "created": [],
                            "settings": {"waitForIdleTimeout": 10000, "disableIdLocatorAutocompletion": False}}

    def test_session_list_parsing(self):
        self.assertEqual(u2.session_from_list({"value": [{"id": "a"}, {"id": "b"}]}), "a")
        self.assertIsNone(u2.session_from_list({"value": []}))
        self.assertIsNone(u2.session_from_list({"value": {"error": "x"}}))

    def test_creates_a_session_when_none_and_applies_the_settings(self):
        c = u2.U2(self.port)
        self.assertEqual(c.session(), ("sid-1", "new"))
        self.assertEqual(c.settings(), {"waitForIdleTimeout": 0, "disableIdLocatorAutocompletion": True})

    def test_two_commands_reuse_one_session(self):
        first = u2.U2(self.port).session()
        second = u2.U2(self.port).session()
        self.assertEqual(first[0], second[0])
        self.assertEqual(second[1], "reused")
        self.assertEqual(FakeServer.state["created"], ["sid-1"])

    def test_settings_are_reapplied_after_someone_opens_a_new_session(self):
        u2.U2(self.port).session()
        u2.U2(self.port).session(new=True)     # what another client would do
        FakeServer.state["settings"] = {"waitForIdleTimeout": 10000, "disableIdLocatorAutocompletion": False}
        c = u2.U2(self.port)
        sid, how = c.session()
        self.assertEqual((sid, how), ("sid-2", "reused"))
        self.assertEqual(c.settings(), {"waitForIdleTimeout": 0, "disableIdLocatorAutocompletion": True})

    def test_a_refused_session_names_the_servers_reason(self):
        FakeServer.state["session_error"] = "UiAutomation not connected!"
        with self.assertRaises(u2.ServerError) as c:
            u2.U2(self.port).session()
        self.assertIn("UiAutomation not connected", str(c.exception))

    def test_health_reads_a_real_source(self):
        c = u2.U2(self.port)
        c.session()
        self.assertIn("<hierarchy", c.source())

    def test_health_fails_on_a_source_error(self):
        FakeServer.state["source_error"] = "Timed out waiting for the root AccessibilityNodeInfo"
        c = u2.U2(self.port)
        c.session()
        with self.assertRaises(u2.ServerError) as e:
            c.source()
        self.assertIn("root AccessibilityNodeInfo", str(e.exception))

    def test_an_error_without_a_message_is_still_named(self):
        self.assertEqual(u2.U2.error_of({"value": {"error": "unknown error", "message": ""}}),
                         "unknown error: (no message)")

    def test_no_server_is_a_server_error(self):
        dead = u2.U2(1)
        with self.assertRaises(u2.ServerError):
            dead.session()



class LockState(unittest.TestCase):
    AWAKE = "Power Manager State:\n  mWakefulness=Awake\n  mWakefulnessChanging=false\n"
    ASLEEP = "Power Manager State:\n  mWakefulness=Asleep\n"
    DOZING = "  mWakefulness=Dozing\n"

    def test_awake_without_keyguard_is_unlocked(self):
        self.assertFalse(u2.lock_state(self.AWAKE + "    isKeyguardShowing=false\n"))

    def test_the_keyguard_up_on_an_awake_screen_is_locked(self):
        self.assertTrue(u2.lock_state(self.AWAKE + "    isKeyguardShowing=true\n"))

    def test_an_asleep_or_dozing_screen_is_locked_whatever_the_keyguard_says(self):
        self.assertTrue(u2.lock_state(self.ASLEEP + "    isKeyguardShowing=false\n"))
        self.assertTrue(u2.lock_state(self.DOZING + "    isKeyguardShowing=false\n"))

    def test_the_line_mid_text_or_a_longer_name_does_not_count(self):
        # mWakefulnessChanging=... and a wakefulness quoted inside another line are not it.
        self.assertIsNone(u2.lock_state("  mWakefulnessChanging=false\n    isKeyguardShowing=false\n"))
        self.assertIsNone(u2.lock_state("  last: mWakefulness=Awake\n    isKeyguardShowing=false\n"))

    def test_dumps_without_either_line_say_nothing(self):
        self.assertIsNone(u2.lock_state(self.AWAKE))
        self.assertIsNone(u2.lock_state("    isKeyguardShowing=true\n"))
        self.assertIsNone(u2.lock_state(""))

    def test_cli_prints_true_false_and_exits_1_when_unknown(self):
        import io
        from unittest import mock
        for text, want, rc in ((self.AWAKE + "isKeyguardShowing=true", "true", 0),
                               (self.AWAKE + "isKeyguardShowing=false", "false", 0), ("", "", 1)):
            with mock.patch("sys.stdin", io.StringIO(text)), mock.patch("sys.stdout", new=io.StringIO()) as o, \
                    mock.patch("sys.stderr", new=io.StringIO()):
                self.assertEqual(u2.main(["locked"]), rc)
            self.assertEqual(o.getvalue().strip(), want)

    def test_device_locked_is_none_when_adb_cannot_run(self):
        self.assertIsNone(u2.device_locked("/nonexistent/adb", "emulator-5554"))


class UnlessLocked(unittest.TestCase):
    def test_a_hit_returns_without_waiting_for_the_lock_check(self):
        import threading as th
        gate = th.Event()
        t = __import__("time").time()
        self.assertEqual(u2.unless_locked(lambda: "hit", lambda v: True, lambda: gate.wait(5)), "hit")
        self.assertLess(__import__("time").time() - t, 1)
        gate.set()

    def test_a_locked_screen_wins_over_a_read_that_hangs(self):
        import threading as th
        hang = th.Event()
        t = __import__("time").time()
        with self.assertRaises(u2.ScreenLocked):
            u2.unless_locked(lambda: hang.wait(5), lambda v: False, lambda: True)
        self.assertLess(__import__("time").time() - t, 1)
        hang.set()

    def test_a_miss_on_an_unlocked_screen_returns_the_read(self):
        self.assertEqual(u2.unless_locked(lambda: [], lambda v: bool(v), lambda: False), [])
        self.assertEqual(u2.unless_locked(lambda: [], lambda v: bool(v), lambda: None), [])

    def test_a_locked_screen_wins_over_a_miss(self):
        with self.assertRaises(u2.ScreenLocked):
            u2.unless_locked(lambda: [], lambda v: bool(v), lambda: True)

    def test_a_read_error_on_an_unlocked_screen_is_raised(self):
        def boom():
            raise u2.ServerError("down")
        with self.assertRaises(u2.ServerError):
            u2.unless_locked(boom, lambda v: True, lambda: False)

if __name__ == "__main__":
    unittest.main()
