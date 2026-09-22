#!/usr/bin/env python3
"""PreToolUse hook: the solo guard.

Scoped to ONE session. A run's marker is ~/.claude/solo/<session-id>.active
(written by shift-open.sh with the run's session id, removed by
shift-close.sh). The hook reads the `session_id` Claude Code passes on stdin
and applies a marker ONLY when it belongs to that session - so a solo run
never blocks the user's other sessions, and several runs can coexist. No
marker for this session = every
call passes untouched. A marker older than MAX_HOURS + 2h is stale: the call
passes with a warning on stderr.

With a live marker it blocks (exit 2, reason on stderr) what the solo
contract forbids regardless of what the model has been told:
  Bash
  - git push            unless the run was opened with --push
  - any force push      always (-f, --force*, +ref), even with --push
  - git push --delete / :ref   always
  - gh pr create        unless --pr;  gh pr merge / close / comment   always
  - gh issue create/comment/close   always (external writes)
  - git merge / pull / rebase while ON the base branch (main, master,
    development, develop, or the marker's BASE); on a task branch they pass -
    bringing the base into the task branch before verification is required
  - git branch -D/-d, git reset --hard, git clean, git stash drop/clear   always
  - pm mv/move <id> done|archived, pm archive, pm add, pm delete  (CLI twins)
  pm MCP
  - pm_move_task / pm_update_task to done or archived   always
  - pm_add_task, pm_delete_task   always (findings are PROPOSED, never filed)
  other MCP servers (Jira, Slack, Linear, GitHub, Gmail, Figma, ...)
  - a tool whose name starts with a WRITE verb is blocked; a tool whose name
    starts with a READ verb passes; an unknown name PASSES (the contract's
    prose still forbids the write, but a read must never break the run).
    Servers that are local runtime / code tools are exempt by prefix.

`guard.py --explain <tool_name> [command]` prints the decision and the rule
without needing a marker - use it when a new MCP server arrives.

Deny rules in settings.json still apply on top of this (they run in every
permission mode); this guard exists for the rules that need a flag.
"""
import json
import os
import re
import shlex
import sys
import time

MARKER_DIR = os.path.expanduser("~/.claude/solo")
STALE_GRACE_H = 2

# MCP servers whose tools act on THIS machine or on a local runtime: never
# an "external system written". Matched as a prefix of the server segment.
LOCAL_SERVERS = ("playwright", "claude-in-chrome", "codegraph", "context7", "crawl4ai", "pm", "pm-vps")

READ_PREFIXES = (
    "get", "list", "search", "read", "fetch", "find", "query", "resolve", "show", "describe",
    "check", "download", "whoami", "lookup", "view", "count", "conversations_history",
    "conversations_replies", "conversations_search", "channels_list", "users_", "jira_get",
    "jira_search", "jira_download", "jira_batch_get", "confluence_get", "confluence_search",
    "confluence_download", "confluence_check", "confluence_list",
)
WRITE_PREFIXES = (
    "add", "create", "update", "delete", "remove", "transition", "assign", "post", "send",
    "upload", "edit", "move", "set", "reply", "resolve_", "link", "unlink", "batch_create",
    "batch_update", "publish", "archive", "close", "merge", "write", "put", "patch", "save",
    "submit", "apply", "invite", "notify", "comment", "react", "pin", "unpin", "schedule",
    "conversations_add", "jira_add", "jira_create", "jira_update", "jira_delete", "jira_remove",
    "jira_transition", "jira_assign", "jira_link", "jira_move", "jira_batch_create", "jira_edit",
    "jira_upload", "confluence_add", "confluence_create", "confluence_update", "confluence_delete",
    "confluence_move", "confluence_set", "confluence_upload", "confluence_reply", "confluence_copy",
)


def parse_marker(path):
    flags = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                flags[k.strip()] = v.strip()
    flags["_path"] = path
    return flags


def marker_for(session_id):
    """The marker that applies to THIS session, or None."""
    if not session_id:
        return None
    own = os.path.join(MARKER_DIR, f"{session_id}.active")
    if os.path.exists(own):
        return parse_marker(own)
    return None


def session_of(data):
    sid = data.get("session_id")
    if sid:
        return sid
    tp = data.get("transcript_path") or ""
    base = os.path.basename(tp)
    return base[:-6] if base.endswith(".jsonl") else None


def marker_stale(flags):
    try:
        started = int(flags.get("STARTED", "0"))
        max_h = float(flags.get("MAX_HOURS", "4"))
    except ValueError:
        return False
    return started and (time.time() - started) > (max_h + STALE_GRACE_H) * 3600


def segments(command):
    """Split a shell command on ; && || | and newlines, keep each piece."""
    return [s.strip() for s in re.split(r"\|\||&&|;|\||\n", command) if s.strip()]


WRAPPERS = {"timeout", "time", "nice", "nohup", "env", "command", "builtin", "sudo"}


def tokens_of(segment):
    try:
        toks = shlex.split(segment)
    except ValueError:
        toks = segment.split()
    while toks and (toks[0] in WRAPPERS or "=" in toks[0] and not toks[0].startswith("-")):
        head = toks.pop(0)
        if head in ("timeout", "nice"):
            while toks and (toks[0].startswith("-") or re.match(r"^[0-9]+[smhd]?$", toks[0])):
                toks.pop(0)
        elif head == "env":
            while toks and (toks[0].startswith("-") or "=" in toks[0]):
                if toks[0] in ("-u", "-C"):
                    toks.pop(0)
                toks.pop(0)
    return toks


BASE_BRANCHES = {"main", "master", "development", "develop", "dev", "trunk"}


def git_subcommand(toks):
    """Return (subcommand, args, dir) for a git invocation; dir is the `-C` path or None."""
    if not toks or os.path.basename(toks[0]) != "git":
        return None, [], None
    i = 1
    gdir = None
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] == "-C" and i + 1 < len(toks):
            gdir = toks[i + 1]
            i += 2
        elif toks[i] in ("-c", "--git-dir", "--work-tree"):
            i += 2
        else:
            i += 1
    if i >= len(toks):
        return None, [], None
    return toks[i], toks[i + 1:], gdir


def current_branch(cwd, gdir):
    """The checked-out branch in the directory the git call targets, or None."""
    import subprocess
    d = gdir if gdir and os.path.isabs(gdir) else os.path.join(cwd or os.getcwd(), gdir or "")
    try:
        out = subprocess.run(["git", "-C", d, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True, timeout=3)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def on_base_branch(flags, cwd, gdir):
    branch = current_branch(cwd, gdir)
    bases = set(BASE_BRANCHES)
    if flags.get("BASE"):
        bases.add(flags["BASE"])
    return branch in bases, branch


def check_bash(command, flags, cwd=None):
    push_ok = flags.get("PUSH") == "1"
    pr_ok = flags.get("PR") == "1"
    for seg in segments(command):
        toks = tokens_of(seg)
        if not toks:
            continue
        head = os.path.basename(toks[0])
        sub, args, gdir = git_subcommand(toks)
        if sub == "push":
            for a in args:
                if a in ("-f",) or a.startswith("--force") or a.startswith("+") or a in ("-d", "--delete") or re.match(r"^:\S+$", a):
                    return f"force/delete push is never allowed on a solo run: `{seg}`"
            if not push_ok:
                return f"git push is off for this run (open it with --push to allow): `{seg}`"
        elif sub in ("merge", "pull", "rebase") and "--abort" not in args and "--continue" not in args:
            # Bringing the base INTO the task branch is required (verify on the code that
            # will land); merging/pulling/rebasing ON the base branch is what the user does.
            on_base, branch = on_base_branch(flags, cwd, gdir)
            if on_base:
                return f"git {sub} on the base branch ({branch}) is the user's job - branches stay separate: `{seg}`"
        elif sub == "branch" and any(a in ("-D", "--delete", "-d") for a in args):
            return f"branch deletion is never allowed on a solo run: `{seg}`"
        elif sub == "reset" and "--hard" in args:
            return f"git reset --hard discards work; park the task instead: `{seg}`"
        elif sub == "clean":
            return f"git clean discards untracked work; list and delete files by name instead: `{seg}`"
        elif sub == "stash" and any(a in ("drop", "clear") for a in args):
            return f"git stash drop/clear discards work: `{seg}`"
        if head == "gh" and len(toks) >= 3:
            kind, verb = toks[1], toks[2]
            if kind == "pr" and verb == "create" and not pr_ok:
                return f"gh pr create is off for this run (open it with --pr to allow): `{seg}`"
            if kind == "pr" and verb in ("merge", "close", "comment", "review", "edit", "ready"):
                return f"gh pr {verb} is the user's call, never the run's: `{seg}`"
            if kind == "issue" and verb in ("create", "comment", "close", "edit", "delete"):
                return f"gh issue {verb} writes an external system: `{seg}`"
        if head == "pm" and len(toks) >= 2:
            verb = toks[1]
            if verb in ("mv", "move") and any(a.lower() in ("done", "archived") for a in toks[2:]):
                return f"pm {verb} to done/archived is the user's decision (a merged PR closes a task): `{seg}`"
            if verb in ("archive", "add", "delete", "rm"):
                return f"pm {verb} is never called on a solo run (findings are PROPOSED, statuses are the user's): `{seg}`"
    return None


def check_pm(tool, inp):
    if tool.endswith("__pm_add_task"):
        return "pm_add_task is never called on a solo run - findings go to the PROPOSED TICKETS list"
    if tool.endswith("__pm_delete_task"):
        return "pm_delete_task is never called on a solo run"
    status = str(inp.get("status") or "").lower()
    if status in ("done", "archived"):
        return f"status {status} is the user's decision (a merged PR closes a task); leave it on doing/pushed"
    return None


def split_mcp(tool):
    m = re.match(r"^mcp__(.+?)__(.+)$", tool)
    return (m.group(1), m.group(2)) if m else (None, tool)


def classify_mcp(tool):
    server, name = split_mcp(tool)
    if server is None:
        return "allow", "not an MCP tool"
    if any(server == s or server.startswith(s + "-") for s in LOCAL_SERVERS):
        return "allow", f"server {server} is local (runtime / code tool)"
    low = name.lower()
    for p in READ_PREFIXES:
        if low.startswith(p):
            return "allow", f"name starts with read verb '{p}'"
    for p in WRITE_PREFIXES:
        if low.startswith(p):
            return "block", f"name starts with write verb '{p}' (external system written)"
    return "allow", "unknown verb - passes by default; the contract's prose still applies"


def decide(tool, inp, flags, cwd=None):
    if tool == "Bash":
        return check_bash(str(inp.get("command", "")), flags, cwd)
    server, name = split_mcp(tool)
    if server in ("pm", "pm-vps") or (server and server.startswith("pm-")):
        return check_pm(tool, inp)
    if server:
        decision, rule = classify_mcp(tool)
        if decision == "block":
            return f"{tool}: {rule}"
    return None


def explain(argv):
    tool = argv[0]
    inp = {"command": " ".join(argv[1:])} if len(argv) > 1 else {}
    flags = {"PUSH": "0", "PR": "0", "SHIFT_ID": "explain"}
    reason = decide(tool, inp, flags)
    server, _ = split_mcp(tool)
    if reason:
        print(f"BLOCK  {tool}  -> {reason}")
    elif server and server != "pm":
        d, rule = classify_mcp(tool)
        print(f"ALLOW  {tool}  -> {rule}")
    else:
        print(f"ALLOW  {tool}")
    return 0


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--explain":
        return explain(sys.argv[2:])
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    flags = marker_for(session_of(data))
    if flags is None:
        return 0
    tool = data.get("tool_name", "")
    inp = data.get("tool_input") or {}
    reason = decide(tool, inp, flags, data.get("cwd"))
    if not reason:
        return 0
    if marker_stale(flags):
        sys.stderr.write(
            f"solo guard: marker {flags['_path']} is STALE (run {flags.get('SHIFT_ID', '?')} started "
            f"{(time.time() - int(flags.get('STARTED', '0'))) / 3600:.1f} h ago, max {flags.get('MAX_HOURS', '?')} h) - "
            "passing the call; run scripts/shift-close.sh to remove it.\n"
        )
        return 0
    sys.stderr.write(
        f"solo guard (run {flags.get('SHIFT_ID', '?')}): BLOCKED - {reason}. "
        "Record what you wanted to do in the task's brief / the state file and continue.\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
