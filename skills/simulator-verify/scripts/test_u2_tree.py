#!/usr/bin/env python3
"""Unit tests of u2_tree.py and u2_el.py on a synthetic /source (no device)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import u2_el  # noqa: E402
import u2_tree  # noqa: E402

PKG = "com.example.app"


def node(cls, bounds, rid="", text="", desc="", clickable="false", displayed="true", pkg=PKG, **extra):
    attrs = {"class": cls, "package": pkg, "resource-id": rid, "text": text, "content-desc": desc,
             "clickable": clickable, "displayed": displayed, "bounds": bounds,
             "checkable": "false", "checked": "false", "showing-hint": "false"}
    attrs.update(extra)
    a = " ".join('%s="%s"' % (k, v) for k, v in attrs.items())
    return "<%s %s/>" % (cls, a)


def source(*nodes, w=1080, h=2424):
    return ('<?xml version="1.0"?><hierarchy index="0" class="hierarchy" rotation="0" width="%d" height="%d">'
            '<android.widget.FrameLayout class="android.widget.FrameLayout" package="%s" bounds="[0,0][%d,%d]" '
            'displayed="true" resource-id="" text="" content-desc="">%s</android.widget.FrameLayout></hierarchy>'
            % (w, h, nodes[0].split('package="')[1].split('"')[0] if nodes else PKG, w, h, "".join(nodes)))


SCREEN = source(
    node("android.widget.TextView", "[52,583][1027,644]", rid="Comp-text", text="Plain text"),
    node("android.view.View", "[194,179][618,279]", text="Components"),          # a header, no id
    node("android.view.ViewGroup", "[53,926][158,1031]", clickable="true"),      # unlabelled Pressable
    node("android.widget.Button", "[53,1715][1028,1808]", clickable="true"),     # unlabelled Button
    node("android.view.ViewGroup", "[53,1442][158,1547]", rid="Comp-busy", desc="Loading data, busy"),
    node("android.widget.Switch", "[52,1339][1027,1410]", rid="Comp-switch", clickable="true",
         checkable="true", checked="true"),
    node("android.widget.EditText", "[52,300][1027,400]", rid="Input-empty", text="Placeholder",
         clickable="true", **{"showing-hint": "true"}),
    node("android.widget.EditText", "[52,420][1027,520]", rid="Input-full", text="hello", clickable="true"),
    node("android.widget.Button", "[100,2526][400,2569]", rid="Modal-close", text="Close"),   # below the screen
    node("android.widget.TextView", "[0,10][100,40]", rid="Hidden", text="x", displayed="false"),
    node("android.view.ViewGroup", "[10,10][10,50]", rid="Zero-width"),
)


def windows(focus, pkg):
    """A `dumpsys window` dump: the focus line and, further down, every window's block
    with its own package; the focused window (`focus`) belongs to `pkg`."""
    h = focus.split("{")[1].split(" ")[0]
    return ("  mCurrentFocus=%s\nWINDOW MANAGER WINDOWS (dumpsys window windows)\n"
            "  Window #3 Window{ffff u0 com.android.systemui}:\n"
            "    mOwnerUid=10100 showForAllUsers=true package=com.android.systemui appop=NONE\n"
            "  Window #4 %s:\n"
            "    mOwnerUid=10215 showForAllUsers=false package=%s appop=NONE\n"
            "  Window #5 Window{%s0 u0 other}:\n"
            "    mOwnerUid=10300 showForAllUsers=false package=com.example.other appop=NONE\n" % (focus, focus, pkg, h))


class Elements(unittest.TestCase):
    def by_name(self, els):
        return {e.get("name") or e.get("label"): e for e in els}

    def test_filter_keeps_content_and_clickable_controls(self):
        got = self.by_name(u2_tree.elements(SCREEN, 2.625))
        self.assertIn("Comp-text", got)
        self.assertIn("Components", got)            # header kept by its text
        self.assertIn("Comp-busy", got)
        self.assertIn("Comp-switch", got)
        self.assertIn("Input-empty", got)
        self.assertTrue(any(e["type"] == "Button" and "name" not in e and "label" not in e
                            for e in u2_tree.elements(SCREEN, 2.625)))
        self.assertFalse(any(e["type"] == "ViewGroup" and "name" not in e
                             for e in u2_tree.elements(SCREEN, 2.625)))

    def test_all_keeps_the_unlabelled_pressable(self):
        self.assertTrue(any(e["type"] == "ViewGroup" and "name" not in e
                            for e in u2_tree.elements(SCREEN, 2.625, show_all=True)))

    def test_invisible_offscreen_and_empty_nodes_are_dropped(self):
        names = {e.get("name") for e in u2_tree.elements(SCREEN, 2.625, show_all=True)}
        self.assertNotIn("Modal-close", names)
        self.assertNotIn("Hidden", names)
        self.assertNotIn("Zero-width", names)

    def test_rect_is_in_dp(self):
        e = self.by_name(u2_tree.elements(SCREEN, 2.625))["Comp-text"]
        self.assertEqual(e["rect"], [20, 222, 371, 23])
        e = self.by_name(u2_tree.elements(SCREEN, 3.0))["Comp-text"]
        self.assertEqual(e["rect"], [17, 194, 325, 20])

    def test_placeholder_is_not_a_value(self):
        got = self.by_name(u2_tree.elements(SCREEN, 2.625))
        self.assertEqual(got["Input-empty"]["value"], "")
        self.assertEqual(got["Input-empty"]["hint"], "Placeholder")
        self.assertEqual(got["Input-full"]["value"], "hello")
        self.assertNotIn("hint", got["Input-full"])

    def test_switch_reports_checked(self):
        self.assertIs(self.by_name(u2_tree.elements(SCREEN, 2.625))["Comp-switch"]["checked"], True)

    def test_grep_matches_one_field(self):
        got = u2_tree.narrow(u2_tree.elements(SCREEN, 2.625), "busy")
        self.assertEqual([e["name"] for e in got], ["Comp-busy"])

    def test_names_lines(self):
        lines = u2_tree.name_lines(u2_tree.narrow(u2_tree.elements(SCREEN, 2.625), "^Comp-switch$"))
        self.assertEqual(lines, ["Comp-switch\tSwitch\t[20,510,371,27]\t''  checked=true"])

    def test_system_window_is_named(self):
        dialog = source(node("android.widget.Button", "[100,1000][900,1100]", pkg="com.android.permissioncontroller",
                             rid="com.android.permissioncontroller:id/permission_deny_button", text="Don't allow"))
        self.assertIn("com.android.permissioncontroller", u2_tree.window_note(dialog))
        self.assertIsNone(u2_tree.window_note(SCREEN))


class Element(unittest.TestCase):
    def test_matches_carry_the_hit_conditions(self):
        got = {e["name"]: e for e in u2_el.matches(SCREEN, "Modal-close", 2.625)}
        self.assertFalse(got["Modal-close"]["on_screen"])
        self.assertTrue(got["Modal-close"]["displayed"])
        self.assertEqual(u2_el.matches(SCREEN, "nope", 2.625), [])

    def test_focus_matches_the_package_of_the_focused_window(self):
        f = u2_el.focused_window(windows("Window{ccaae10 u0 com.example.app/com.example.app.MainActivity}", PKG))
        self.assertEqual(f, ("Window{ccaae10 u0 com.example.app/com.example.app.MainActivity}", PKG))
        self.assertTrue(u2_el.in_focus(PKG, f))
        self.assertFalse(u2_el.in_focus("com.example.app.other", f))
        self.assertFalse(u2_el.in_focus(PKG, ("", None)))

    def test_a_titled_dialog_of_the_app_is_the_app(self):
        f = u2_el.focused_window(windows("Window{ab12 u0 Delete item?}", PKG))
        self.assertTrue(u2_el.in_focus(PKG, f))

    def test_an_anr_dialog_naming_the_app_is_not_the_app(self):
        f = u2_el.focused_window(windows("Window{ab12 u0 Application Not Responding: %s}" % PKG, "android"))
        self.assertEqual(f[1], "android")
        self.assertFalse(u2_el.in_focus(PKG, f))

    def test_focus_without_a_package_line_falls_back_to_the_title(self):
        self.assertTrue(u2_el.in_focus(PKG, ("Window{1 u0 Splash Screen com.example.app}", None)))
        self.assertTrue(u2_el.in_focus(PKG, ("Window{1 u0 com.example.app/x.Main}", None)))
        self.assertFalse(u2_el.in_focus(PKG, ("Window{1 u0 com.example.app.other/x.Main}", None)))
        self.assertEqual(u2_el.focused_window("  mCurrentFocus=null\n"), ("", None))

    def test_why_not_names_the_failed_condition(self):
        app = ("Window{1 u0 %s/x}" % PKG, PKG)
        e = u2_el.matches(SCREEN, "Modal-close", 2.625)[0]
        self.assertIn("outside the screen", u2_el.why_not(e, app))
        e = u2_el.matches(SCREEN, "Comp-text", 2.625)[0]
        self.assertIsNone(u2_el.why_not(e, app))
        self.assertIn("focused window", u2_el.why_not(e, ("Window{1 u0 com.android.launcher3/x}", "com.android.launcher3")))


ACTIVITIES = """  * Task{1bac009 #111 type=standard A=10215:%(app)s U=0 visible=true sz=2}
    topResumedActivity=ActivityRecord{183426601 u0 com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity t111}
    * Hist  #1: ActivityRecord{183426601 u0 com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity t111}
    * Hist  #0: ActivityRecord{233745680 u0 %(app)s/.MainActivity t111}
      * Hist  #1: ActivityRecord{183207967 u0 com.android.launcher3/.Launcher t6}
""" % {"app": PKG}


class Foreground(unittest.TestCase):
    def test_a_permission_dialog_on_the_app_task_names_the_app_as_root(self):
        top, root = u2_el.front(ACTIVITIES)
        self.assertEqual(top[0], "com.google.android.permissioncontroller")
        self.assertEqual(root, (PKG, ".MainActivity"))

    def test_the_app_alone(self):
        acts = "    topResumedActivity=ActivityRecord{9 u0 %s/.MainActivity t5}\n    * Hist  #0: ActivityRecord{9 u0 %s/.MainActivity t5}\n" % (PKG, PKG)
        self.assertEqual(u2_el.front(acts), ((PKG, ".MainActivity"), (PKG, ".MainActivity")))
        self.assertEqual(u2_el.front("nothing resumed"), (None, None))


if __name__ == "__main__":
    unittest.main()
