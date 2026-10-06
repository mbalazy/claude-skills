#!/usr/bin/env python3
"""Fixture tests for wt.py: a throwaway origin + main checkout + pm root.

    python3 -I scripts/test_wt.py

Nothing outside a temp directory is touched: PM_ROOT points into it, ports
are high and unusual, and `launch` is exercised only as --dry-run.
"""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest


def slurp(path):
    with open(path) as f:
        return f.read()

HERE = os.path.dirname(os.path.abspath(__file__))


def sh(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


class WtTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="wt-test-")
        t = self.tmp
        origin, self.main = os.path.join(t, "origin.git"), os.path.join(t, "repo")
        sh(["git", "init", "-q", "--bare", "-b", "dev", origin], t)
        sh(["git", "clone", "-q", origin, self.main], t)
        sh(["git", "checkout", "-q", "-b", "dev"], self.main)
        os.makedirs(os.path.join(self.main, "app"))
        with open(os.path.join(self.main, "app", "config.mjs"), "w") as f:
            f.write("export default { port: 47098 };\n")
        with open(os.path.join(self.main, ".gitignore"), "w") as f:
            f.write("local/\nnode_modules/\n")
        sh(["git", "add", "."], self.main)
        sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], self.main)
        sh(["git", "push", "-q", "origin", "dev"], self.main)
        os.makedirs(os.path.join(self.main, "local"))
        with open(os.path.join(self.main, "local", "rig.md"), "w") as f:
            f.write(f"rig --repo {self.main} --port 47201\nnot a port: 147201\n")

        self.pm = os.path.join(t, "pm")
        proj = os.path.join(self.pm, "demo")
        os.makedirs(os.path.join(proj, ".worktrees", "templates", "app"))
        with open(os.path.join(proj, "project.yaml"), "w") as f:
            f.write(f"prefix: demo\npath: {self.main}\nexecutor:\n    base_branch: dev\n")
        for n in (1, 2):
            with open(os.path.join(proj, f"demo-{n}-task.md"), "w") as f:
                f.write(f"---\nid: demo-{n}\ntitle: 'Task {n}'\nstatus: todo\nbranch: feat/t{n}\n---\nbody\n")
        self.wt_root = os.path.join(t, ".wt")
        with open(os.path.join(proj, ".worktrees", "config.env"), "w") as f:
            f.write(f"WT_ROOT={self.wt_root}\nSEED=\"local/rig.md\"\n"
                    "PORTS=\"WEB_PORT=47201 E2E_PORT=47098\"\nLANE_STEP=10\n"
                    "OVERLAYS=\"app/config.mts\"\n")
        with open(os.path.join(proj, ".worktrees", "templates", "app", "config.mts"), "w") as f:
            f.write("// lane {{LANE}}\nexport default { port: {{E2E_PORT}} };\n")
        os.environ["PM_ROOT"] = self.pm
        sys.path.insert(0, HERE)
        import importlib
        import wt
        importlib.reload(wt)
        self.wt = wt

    def call(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = self.wt.main(list(argv))
        return rc, out.getvalue() + err.getvalue()

    def test_open_seeds_overlays_and_allocates_distinct_lanes(self):
        rc, out = self.call("open", "demo", "demo-1")
        self.assertEqual(rc, 0, out)
        wt1 = os.path.join(self.wt_root, "demo-1")
        self.assertEqual(subprocess.run(["git", "-C", wt1, "branch", "--show-current"], capture_output=True,
                                        text=True).stdout.strip(), "feat/t1")
        rig = slurp(os.path.join(wt1, "local", "rig.md"))
        self.assertIn(f"--repo {wt1} --port 47211", rig)
        self.assertIn("147201", rig, "a longer number containing the port must not be rewritten")
        self.assertNotIn(f"--repo {self.main} ", rig)
        self.assertIn("port: 47108", slurp(os.path.join(wt1, "app", "config.mts")))
        exclude = slurp(os.path.join(self.main, ".git", "info", "exclude"))
        self.assertIn("/app/config.mts", exclude)
        self.assertEqual(subprocess.run(["git", "-C", wt1, "status", "--porcelain"], capture_output=True,
                                        text=True).stdout, "")
        # the main checkout is untouched: same branch, no overlay
        self.assertEqual(subprocess.run(["git", "-C", self.main, "branch", "--show-current"], capture_output=True,
                                        text=True).stdout.strip(), "dev")
        self.assertFalse(os.path.exists(os.path.join(self.main, "app", "config.mts")))

        rc, out = self.call("open", "demo", "demo-2")
        self.assertEqual(rc, 0, out)
        e2 = self.wt.Project("demo").entry("demo-2")
        self.assertEqual(e2["LANE"], "2")
        self.assertEqual(e2["PORTS"], "WEB_PORT=47221 E2E_PORT=47118")

        rc, out = self.call("open", "demo", "demo-1")
        self.assertEqual(rc, 0)
        self.assertIn("already open", out)
        exclude2 = slurp(os.path.join(self.main, ".git", "info", "exclude"))
        self.assertEqual(exclude2.count("/app/config.mts"), 1, "exclude line written once")

    def test_close_refuses_dirty_and_unknown_ignored_then_removes(self):
        self.call("open", "demo", "demo-1")
        wt1 = os.path.join(self.wt_root, "demo-1")
        with open(os.path.join(wt1, "app", "new.txt"), "w") as f:
            f.write("x")
        rc, out = self.call("close", "demo", "demo-1")
        self.assertEqual(rc, 2)
        self.assertIn("uncommitted", out)
        os.rename(os.path.join(wt1, "app", "new.txt"), os.path.join(wt1, "local", "evidence.log"))
        rc, out = self.call("close", "demo", "demo-1")
        self.assertEqual(rc, 2)
        self.assertIn("local/evidence.log", out)
        os.makedirs(os.path.join(wt1, "node_modules", "x"))
        rc, out = self.call("close", "demo", "demo-1", "--discard-ignored")
        self.assertEqual(rc, 0, out)
        self.assertFalse(os.path.exists(wt1))
        self.assertEqual(self.wt.Project("demo").entry("demo-1")["STATUS"], "closed")
        branches = subprocess.run(["git", "-C", self.main, "branch", "--list", "feat/t1"], capture_output=True,
                                  text=True).stdout
        self.assertIn("feat/t1", branches, "close keeps the branch")
        # a closed lane frees its number
        rc, out = self.call("open", "demo", "demo-2")
        self.assertEqual(self.wt.Project("demo").entry("demo-2")["LANE"], "1")

    def test_close_delete_branch_only_when_contained_in_base(self):
        self.call("open", "demo", "demo-1")
        wt1 = os.path.join(self.wt_root, "demo-1")
        with open(os.path.join(wt1, "app", "f.txt"), "w") as f:
            f.write("x")
        sh(["git", "add", "app/f.txt"], wt1)
        sh(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "f"], wt1)
        rc, out = self.call("close", "demo", "demo-1", "--delete-branch")
        self.assertEqual(rc, 0, out)
        self.assertIn("KEPT", out)

    def test_open_refuses_a_branch_checked_out_elsewhere(self):
        sh(["git", "branch", "feat/t1"], self.main)
        other = os.path.join(self.tmp, "other")
        sh(["git", "worktree", "add", "-q", other, "feat/t1"], self.main)
        rc, out = self.call("open", "demo", "demo-1")
        self.assertEqual(rc, 2)
        self.assertIn("checked out in another worktree", out)

    def test_launch_dry_run_strips_parent_session_env(self):
        self.call("open", "demo", "demo-1")
        os.environ["CLAUDE_CODE_SESSION_ID"] = "parent-session"
        try:
            env = self.wt.clean_env()
        finally:
            del os.environ["CLAUDE_CODE_SESSION_ID"]
        self.assertNotIn("CLAUDE_CODE_SESSION_ID", env)
        argv = self.wt.build_argv("opus", "demo-1", '{"x":1}', ["--setting-sources", "user,local"], "/taking-over hi")
        self.assertEqual(argv[-3:], ["demo-1", "--bg", "/taking-over hi"])
        self.assertIn("--dangerously-skip-permissions", argv)
        self.assertIn("--setting-sources", argv)

    def test_check_settings_requires_the_deny_mirror(self):
        d = os.path.join(self.tmp, "s")
        os.makedirs(os.path.join(d, ".claude"))
        with open(os.path.join(d, ".claude", "settings.json"), "w") as f:
            json.dump({"permissions": {"ask": ["Bash(pnpm test:*)"], "deny": ["Bash(rm:*)"]}}, f)
        with self.assertRaises(self.wt.Refused):
            self.wt.check_settings(d)
        with open(os.path.join(d, ".claude", "settings.local.json"), "w") as f:
            json.dump({"permissions": {"deny": ["Bash(rm:*)"]}}, f)
        self.assertEqual(self.wt.check_settings(d), ["--setting-sources", "user,local"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
