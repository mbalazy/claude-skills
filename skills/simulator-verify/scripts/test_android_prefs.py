#!/usr/bin/env python3
"""Unit tests for android_prefs.py (the SharedPreferences merge of the Android rig check)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import android_prefs as P  # noqa: E402

APP = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="onboarding_done" value="true" />
    <string name="debug_http_host">10.0.2.2:8121</string>
    <int name="launches" value="3" />
    <string name="token_hint">a &amp; b</string>
</map>
"""


class Merge(unittest.TestCase):
    def test_set_replaces_only_the_one_key(self):
        out = P.put(APP, "debug_http_host", "10.0.2.2:8122")
        self.assertEqual(P.get(out, "debug_http_host"), "10.0.2.2:8122")
        self.assertEqual(out.count("debug_http_host"), 1)
        for line in ('<boolean name="onboarding_done" value="true" />', '<int name="launches" value="3" />',
                     '<string name="token_hint">a &amp; b</string>'):
            self.assertIn(line, out)

    def test_empty_or_missing_file_becomes_a_new_map(self):
        for empty in ("", "\n"):
            out = P.put(empty, "debug_http_host", "10.0.2.2:8121")
            self.assertTrue(out.startswith("<?xml"))
            self.assertEqual(P.get(out, "debug_http_host"), "10.0.2.2:8121")

    def test_self_closing_map(self):
        out = P.put("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map />\n", "k", "v")
        self.assertEqual(P.get(out, "k"), "v")
        self.assertNotIn("<map />", out)

    def test_unset_keeps_the_rest(self):
        out = P.without(APP, "debug_http_host")
        self.assertIsNone(P.get(out, "debug_http_host"))
        self.assertIn('<int name="launches" value="3" />', out)

    def test_get_unescapes_and_reads_an_empty_string(self):
        self.assertEqual(P.get(APP, "token_hint"), "a & b")
        self.assertEqual(P.get('<map><string name="e" /></map>', "e"), "")
        self.assertIsNone(P.get(APP, "nope"))

    def test_a_key_that_is_a_prefix_of_another_is_its_own(self):
        x = P.put(APP, "debug_http_host_extra", "x")
        out = P.put(x, "debug_http_host", "h")
        self.assertEqual(P.get(out, "debug_http_host_extra"), "x")
        self.assertEqual(P.get(out, "debug_http_host"), "h")

    def test_not_a_prefs_file_is_refused(self):
        with self.assertRaises(ValueError):
            P.put("<html></html>", "k", "v")


if __name__ == "__main__":
    unittest.main()
