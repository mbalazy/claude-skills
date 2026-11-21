#!/usr/bin/env python3
"""inventory.py - list everything a Claude Code session produced, for a digest.

    inventory.py --session <name|uuid|path.jsonl> --out <dir>
    inventory.py --out <dir>                 # newest transcript of the cwd's project

Reads the session transcript (JSONL) once, streaming, and writes three files:

    <out>/inventory.md       header, asks, sessions/agents driven, files, commits, pm ids
    <out>/asks.md            every message the user typed, full text, with local times
    <out>/shown-messages.md  every longer text the session showed the user, full text

It never interprets content: it only collects. Python 3 stdlib only.
Exit: 0 ok, 2 usage / session not found.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys

CFG = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# A markdown path: ~/..., /Users/<u>/..., /home/<u>/..., /tmp/... ending in .md.
MD_RE = re.compile(r"(?:~|/Users/[^/\s\"'\\]+|/home/[^/\s\"'\\]+|/tmp|/private/tmp)/[^\s\"'`<>|,;()\[\]\\]+?\.md\b")
HASH_RE = re.compile(r"\b[0-9a-f]{9,40}\b")
SHOWN_MIN_WORDS = 60


def local(ts):
    if not ts:
        return "?"
    try:
        t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
        return t.strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ts


def project_dirs():
    return [d for d in glob.glob(os.path.join(CFG, "projects", "*")) if os.path.isdir(d)]


def cwd_project_dir():
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())
    p = os.path.join(CFG, "projects", slug)
    return p if os.path.isdir(p) else None


def resolve(session):
    if session and session.endswith(".jsonl") and os.path.exists(session):
        return session
    if session and UUID_RE.match(session):
        hits = glob.glob(os.path.join(CFG, "projects", "*", session + ".jsonl"))
        return hits[0] if hits else None
    if session:
        # A name: /rename title or agent name. Prefer the cwd's project, then any.
        needles = ['"customTitle":"%s"' % session, '"agentName":"%s"' % session]
        dirs = [d for d in [cwd_project_dir()] if d] + project_dirs()
        best = None
        for d in dirs:
            for f in glob.glob(os.path.join(d, "*.jsonl")):
                n = 0
                with open(f, errors="replace") as fh:
                    for line in fh:
                        if any(x in line for x in needles):
                            n += 1
                if n:
                    cand = (n, os.path.getmtime(f), f)
                    best = max(best, cand) if best else cand
            if best:
                return best[2]
        return None
    d = cwd_project_dir()
    if not d:
        return None
    files = glob.glob(os.path.join(d, "*.jsonl"))
    return max(files, key=os.path.getmtime) if files else None


def text_parts(content):
    if isinstance(content, str):
        return [content]
    return [p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text"]


def words(path):
    try:
        with open(path, errors="replace") as fh:
            return len(fh.read().split())
    except OSError:
        return 0


def git(args, cwd):
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", help="session name (/rename or agent name), uuid or transcript path")
    ap.add_argument("--out", required=True, help="directory for inventory.md, asks.md, shown-messages.md")
    a = ap.parse_args()

    path = resolve(a.session)
    if not path:
        print("inventory: session not found: %s" % (a.session or "(newest in cwd project)"), file=sys.stderr)
        return 2
    sid = os.path.basename(path)[:-6]

    titles, cwds = set(), set()
    first = last = None
    compactions = 0
    asks, shown = [], []
    written, mentioned = set(), set()
    targets, agents, pm_ids, skills = {}, [], set(), []
    hashes = set()

    with open(path, errors="replace") as fh:
        for line in fh:
            for m in MD_RE.finditer(line):
                mentioned.add(m.group(0))
            for m in HASH_RE.finditer(line):
                hashes.add(m.group(0))
            try:
                d = json.loads(line)
            except ValueError:
                continue
            ts = d.get("timestamp")
            if ts:
                first = first or ts
                last = ts
            if d.get("customTitle"):
                titles.add(d["customTitle"])
            if d.get("agentName"):
                titles.add(d["agentName"])
            if d.get("cwd"):
                cwds.add(d["cwd"])
            if d.get("isCompactSummary"):
                compactions += 1
                continue
            t = d.get("type")
            msg = d.get("message") or {}
            if t == "user" and not d.get("isMeta"):
                for txt in text_parts(msg.get("content", [])):
                    s = txt.strip()
                    if not s or s.startswith("<task-notification>") or s.startswith("<local-command") \
                            or s.startswith("<command-name>") or s.startswith("[Request interrupted") \
                            or s.startswith("This session is being continued"):
                        continue
                    asks.append((ts, s))
            elif t == "assistant":
                for p in msg.get("content", []):
                    if not isinstance(p, dict):
                        continue
                    if p.get("type") == "text" and len(p.get("text", "").split()) >= SHOWN_MIN_WORDS:
                        shown.append((ts, p["text"]))
                    if p.get("type") != "tool_use":
                        continue
                    name, inp = p.get("name", ""), p.get("input") or {}
                    if name in ("Write", "Edit", "NotebookEdit") and inp.get("file_path"):
                        written.add(inp["file_path"])
                    elif name == "SendMessage" and inp.get("to"):
                        targets[inp["to"]] = targets.get(inp["to"], 0) + 1
                    elif name in ("Agent", "Task"):
                        agents.append((ts, inp.get("description", ""), inp.get("subagent_type", "")))
                    elif name == "Skill":
                        skills.append((ts, inp.get("skill", "")))
                    elif name.startswith("mcp__pm__"):
                        for k in ("task_id", "parent", "id"):
                            if inp.get(k):
                                pm_ids.add(inp[k])

    # Files: everything mentioned that exists, plus every md in an evidence dir that was touched.
    files = {}
    for p in mentioned | {w for w in written if w.endswith(".md")}:
        full = os.path.expanduser(p)
        if os.path.isfile(full):
            files[os.path.realpath(full)] = None
    ev_dirs = set()
    for f in list(files):
        m = re.match(r"(.*/\.shift/evidence/[^/]+)/", f)
        if m:
            ev_dirs.add(m.group(1))
    for d in ev_dirs:
        for f in glob.glob(os.path.join(d, "**", "*.md"), recursive=True):
            files[os.path.realpath(f)] = None
    written_real = {os.path.realpath(os.path.expanduser(w)) for w in written}

    roots = {re.match(r"(.*/\.shift/evidence)/", f).group(1) for f in files if "/.shift/evidence/" in f}
    if roots:
        out_root = sorted(roots)[0]
    else:
        out_root = os.path.join(CFG, "digests")
    name = sorted(titles)[0] if titles else sid[:8]
    day = local(last)[:10]
    suggested = os.path.join(out_root, "digest-%s-%s" % (day, re.sub(r"[^A-Za-z0-9._-]", "-", name)))

    # Commits: hashes that exist in the session's repo.
    repo = next((c for c in sorted(cwds) if git(["rev-parse", "--git-dir"], c)), None)
    commits = []
    if repo:
        for h in sorted(hashes):
            if git(["cat-file", "-e", h + "^{commit}"], repo) is None:
                continue
            subj = git(["log", "-1", "--format=%h %ad %s", "--date=format:%m-%d %H:%M", h], repo) or h
            when = git(["log", "-1", "--format=%cI", h], repo) or ""
            br = git(["branch", "--contains", h, "--format=%(refname:short)"], repo) or ""
            inside = bool(when and first and last and first <= dt.datetime.fromisoformat(when).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") <= last)
            commits.append((inside, subj, ", ".join(br.split()[:4])))
    commits.sort(key=lambda c: not c[0])

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "asks.md"), "w") as fh:
        fh.write("# What the user typed (%d messages)\n\n" % len(asks))
        for ts, s in asks:
            fh.write("## %s\n\n%s\n\n" % (local(ts), s))
    with open(os.path.join(a.out, "shown-messages.md"), "w") as fh:
        fh.write("# What the session showed the user (texts of %d+ words, %d)\n\n" % (SHOWN_MIN_WORDS, len(shown)))
        for i, (ts, s) in enumerate(shown, 1):
            fh.write("## S%d %s (%d words)\n\n%s\n\n" % (i, local(ts), len(s.split()), s))

    start = dt.datetime.fromisoformat(first.replace("Z", "+00:00")) if first else None
    total_words = 0
    rows = []
    for f in sorted(files):
        w = words(f)
        total_words += w
        tag = []
        if f in written_real:
            tag.append("written here")
        if re.search(r"-v\d+\.md$|/old/|superseded", f):
            tag.append("superseded?")
        mtime = dt.datetime.fromtimestamp(os.path.getmtime(f)).astimezone()
        if start and mtime < start:
            tag.append("older than the session")
        mt = mtime.strftime("%m-%d %H:%M")
        rows.append("| `%s` | %d | %s | %s |" % (f.replace(os.path.expanduser("~"), "~"), w, mt, ", ".join(tag)))

    with open(os.path.join(a.out, "inventory.md"), "w") as fh:
        fh.write("# Inventory: %s\n\n" % name)
        fh.write("- Transcript: `%s`\n" % path.replace(os.path.expanduser("~"), "~"))
        fh.write("- Names: %s\n" % (", ".join(sorted(titles)) or "-"))
        fh.write("- Repo/cwd: %s\n" % (", ".join(sorted(cwds)) or "-"))
        fh.write("- Span: %s -> %s (local)\n" % (local(first), local(last)))
        fh.write("- Compactions: %d\n" % compactions)
        fh.write("- Asks: %d (asks.md); shown texts: %d (shown-messages.md)\n" % (len(asks), len(shown)))
        fh.write("- Files: %d md, %d words\n" % (len(files), total_words))
        fh.write("- Suggested output dir: `%s`\n\n" % suggested.replace(os.path.expanduser("~"), "~"))
        fh.write("## Asks (first 300 chars; full text in asks.md)\n\n")
        for ts, s in asks:
            fh.write("- %s: %s\n" % (local(ts), " ".join(s.split())[:300]))
        fh.write("\n## Sessions messaged\n\n")
        for k, v in sorted(targets.items()):
            fh.write("- %s (%d messages)\n" % (k, v))
        fh.write("\n## Agents spawned (%d)\n\n" % len(agents))
        for ts, desc, typ in agents:
            fh.write("- %s: %s (%s)\n" % (local(ts), desc, typ or "default"))
        fh.write("\n## Skills invoked\n\n")
        for ts, s in skills:
            fh.write("- %s: %s\n" % (local(ts), s))
        fh.write("\n## pm task ids passed to pm tools\n\n%s\n" % (", ".join(sorted(pm_ids)) or "-"))
        fh.write("\n## Files (md, existing; mtime local)\n\n| File | Words | Modified | Note |\n|---|---|---|---|\n")
        fh.write("\n".join(rows) + "\n")
        fh.write("\n## Commits mentioned that exist in %s\n\n" % (repo or "(no repo)"))
        for inside, subj, br in commits:
            fh.write("- %s%s [%s]\n" % ("" if inside else "(before the session) ", subj, br or "no local branch"))
    print(os.path.join(a.out, "inventory.md"))
    print("suggested output dir: %s" % suggested)
    return 0


if __name__ == "__main__":
    sys.exit(main())
