#!/usr/bin/env python3
"""Print what a pm project and its repo already know, as dated plain-text facts.

Usage: gather.py [project-slug]
No slug: the project whose project.yaml `path` contains the cwd.
Reads PM_DATA_DIR (default ~/.claude/pm). Writes nothing.

Every dated line starts with YYYY-MM-DD and names its source, so a draft entry
can be traced to the line it came from.
"""

import os
import re
import subprocess
import sys
from collections import Counter
from datetime import date
from pathlib import Path

BRIEF_LINES = 12
BRIEF_CHARS = 700  # per task: a brief can be one 3000-character line
ARCHIVED_SHOWN = 20
MERGES_SHOWN = 40
TAGS_SHOWN = 20
RECENT_SHOWN = 30
BULK_MOVE = 10  # tasks sharing one status-change day = a clean-up, not landings (a batch run moves fewer)
DOC_HEADS = {"README.md": 40, "docs/INDEX.md": 60, "CHANGELOG.md": 80}
KNOWLEDGE_INDEX = Path.home() / "repos/knowledge/INDEX.md"


def data_dir() -> Path:
    return Path(os.environ.get("PM_DATA_DIR") or Path.home() / ".claude/pm")


YAML_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
                "e": "\x1b", " ": " ", "\"": "\"", "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0",
                "L": "\u2028", "P": "\u2029"}


def yaml_escape(m) -> str:
    s = m.group(1)
    if s[0] in "xuU":
        cp = int(s[1:], 16)
        return m.group(0) if 0xD800 <= cp <= 0xDFFF else chr(cp)
    return YAML_ESCAPES.get(s, m.group(0))


def unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == "'":
        return v[1:-1].replace("''", "'")
    if len(v) >= 2 and v[0] == v[-1] == '"':
        return re.sub(r"\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)", yaml_escape, v[1:-1])
    return v


def frontmatter(text: str) -> dict:
    """Top-level scalar keys of a YAML mapping: plain, quoted or block (| |- > >-).
    Lists and nested maps are skipped - nothing here needs them."""
    out, lines, i = {}, text.splitlines(), 0
    while i < len(lines):
        m = re.match(r"^([a-z_]+):\s?(.*)$", lines[i])
        i += 1
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if re.match(r"^[|>][-+]?\s*$", val):
            block = []
            while i < len(lines) and (lines[i].startswith(" ") or lines[i] == ""):
                block.append(lines[i])
                i += 1
            indent = min((len(b) - len(b.lstrip()) for b in block if b.strip()), default=0)
            body = [b[indent:] for b in block]
            joined = "\n".join(body) if val.startswith("|") else " ".join(x for x in body if x)
            out[key] = joined.strip("\n")
        elif val:
            out[key] = unquote(val)
    return out


def task_meta(path: Path) -> dict:
    text = path.read_text(errors="replace")
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    return frontmatter(text[3:end]) if end > 0 else {}


def day(stamp: str) -> str:
    return stamp[:10] if re.match(r"^\d{4}-\d{2}-\d{2}", stamp or "") else ""


def find_project(root: Path, slug: str) -> Path:
    if slug:
        p = root / slug
        if (p / "project.yaml").is_file():
            return p
        sys.exit(f"project not found: {slug} (no {p}/project.yaml)")
    cwd = os.path.realpath(os.getcwd())
    best, best_len = None, -1
    for y in root.glob("*/project.yaml"):
        path = frontmatter(y.read_text(errors="replace")).get("path", "")
        if not path:
            continue
        real = os.path.realpath(os.path.expanduser(path))
        if (cwd == real or cwd.startswith(real + os.sep)) and len(real) > best_len:
            best, best_len = y.parent, len(real)
    if best is None:
        sys.exit(f"no pm project has a path containing {cwd} - pass the slug")
    return best


def git(repo: str, *args: str) -> list:
    try:
        r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return r.stdout.splitlines() if r.returncode == 0 else []


def landing_evidence(task: dict, base: str, merges: list, commits: list) -> list:
    """Git lines naming a landed task (inputs newest first): the oldest merge of
    its branch, else the first and the last commit whose subject names its id."""
    branch = task.get("branch", "")
    if branch and branch != base:
        pat = re.compile(rf"(?<![\w/.-]){re.escape(branch)}(?![\w/.-])")
        hits = [line for line in merges if pat.search(line)]
        if hits:
            return [hits[-1]]
    pat = re.compile(rf"(?<![\w-]){re.escape(task['id'])}(?!\w|-\w)")
    hits = [line for line in commits if pat.search(line)]
    return [hits[-1], hits[0]] if len(hits) > 1 else hits


def capped(lines: list, n: int) -> tuple:
    return lines[:n], len(lines)


def section(title: str):
    print(f"\n## {title}")


def main() -> None:
    slug = sys.argv[1] if len(sys.argv) > 1 else ""
    pdir = find_project(data_dir(), slug)
    slug = pdir.name
    proj = frontmatter((pdir / "project.yaml").read_text(errors="replace"))

    print(f"# facts for the timeline seed of {slug} (gathered {date.today().isoformat()})")
    print("A dated line starts with its date and names its source; an entry may only carry such a date.")

    section(f"pm project ({pdir / 'project.yaml'})")
    for k in ("name", "path", "repo", "group", "stack"):
        if proj.get(k):
            print(f"{k}: {proj[k]}")
    print("notes:" if proj.get("notes") else "notes: (none)")
    for line in proj.get("notes", "").splitlines():
        print(f"  {line}")

    # Git and docs come from the project's own path only - never from the cwd,
    # which may be another project's checkout.
    path = os.path.expanduser(proj.get("path", ""))
    repo, top, base, ref = "", [], "", ""
    if path and os.path.isdir(path):
        top = git(path, "rev-parse", "--show-toplevel")
        repo = top[0] if top else path
    if top:
        head = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        base = head[0].removeprefix("origin/") if head else ""
        if not base:
            base = next((b for b in ("main", "master", "development") if git(repo, "rev-parse", "--verify", "-q", b)), "")
        ref = f"origin/{base}" if base and git(repo, "rev-parse", "--verify", "-q", f"origin/{base}") else base
    fmt = ("--format=%ad git:%h %s", "--date=short")
    merges = git(repo, "log", ref, "--merges", "--first-parent", *fmt) if base else []
    commits = git(repo, "log", ref, *fmt) if base else []

    tasks = [m for m in (task_meta(p) for p in sorted(pdir.glob("*.md"))) if m.get("id")]
    by = lambda *st: [t for t in tasks if t.get("status") in st]
    stamp = lambda t: day(t.get("status_changed", "")) or day(t.get("updated", ""))
    bulk = Counter(day(t.get("status_changed", "")) for t in tasks)

    def which(t) -> str:
        d = day(t.get("status_changed", ""))
        if not d:
            return "last edit"
        if bulk[d] >= BULK_MOVE:
            return f"status change, bulk move: {bulk[d]} tasks changed status that day - not a landing date"
        return "status change"

    active = sorted(by("doing", "waiting"), key=stamp, reverse=True)
    section(f"tasks in progress ({len(active)}) - the brief says where each stands")
    for t in active:
        print(f"{stamp(t)} ({which(t)}) · task {t['id']} · {t['status']} · {t.get('title', '')}")
        if t.get("waiting_for"):
            print(f"  waiting for: {t['waiting_for']}")
        brief = [b for b in t.get("brief", "").splitlines() if b.strip()]
        budget = BRIEF_CHARS
        for n, b in enumerate(brief[:BRIEF_LINES]):
            if budget <= 0:
                break
            print(f"  | {b[:budget]}{'...' if len(b) > budget else ''}")
            budget -= len(b)
        if len(brief) > BRIEF_LINES or budget < 0:
            print("  | (brief cut - the whole brief is in the task)")

    landed = sorted(by("done", "merged", "pushed"), key=stamp)
    section(f"tasks landed ({len(landed)}), oldest first - milestone candidates")
    for t in landed:
        print(f"{stamp(t)} ({which(t)}) · task {t['id']} · {t['status']} · {t.get('title', '')}")
        for line in landing_evidence(t, base, merges, commits):
            print(f"  git: {line.split(' ', 1)[0]} · {line.split(' ', 1)[1]}")

    todo = sorted(by("todo"), key=lambda t: day(t.get("created", "")))
    section(f"tasks to do ({len(todo)})")
    for t in todo:
        print(f"created {day(t.get('created', ''))} · task {t['id']} · {t.get('title', '')}")

    archived = sorted(by("archived"), key=stamp, reverse=True)
    shown, total = capped(archived, ARCHIVED_SHOWN)
    section(f"tasks archived ({total}; newest {len(shown)} by last change)")
    for t in shown:
        print(f"{stamp(t)} ({which(t)}) · task {t['id']} · archived · {t.get('title', '')}")

    known = {"doing", "waiting", "done", "merged", "pushed", "todo", "archived"}
    other = sorted((t for t in tasks if t.get("status") not in known), key=stamp, reverse=True)
    if other:
        section(f"tasks in the project's other statuses ({len(other)})")
        for t in other:
            print(f"{stamp(t)} ({which(t)}) · task {t['id']} · {t.get('status', '(none)')} · {t.get('title', '')}")

    if not repo:
        section("git")
        print(f"project.yaml has no existing path ({proj.get('path') or 'none'}) - git and repo docs skipped")
    elif not top:
        section("git")
        print(f"not a git repository: {repo}")
    else:
        section(f"git ({repo}, base branch {base or 'none'})")
        if not base:
            print("no base branch (no origin/HEAD, main, master or development): merges and recent commits skipped - a checked-out feature branch would read as landed work")
        first = git(repo, "log", ref or "HEAD", "--reverse", "--format=%ad git:%h %s", "--date=short")
        if first:
            print(f"{first[0].split(' ', 1)[0]} · first commit · {first[0].split(' ', 1)[1]}")
        shown, total = capped(merges, MERGES_SHOWN)
        print(f"merges into {base} (newest {len(shown)} of {total}):")
        for line in shown:
            print(f"{line.split(' ', 1)[0]} · merge · {line.split(' ', 1)[1]}")
        tags = git(repo, "for-each-ref", "refs/tags", "--sort=-creatordate", "--format=%(creatordate:short) %(refname:short)")
        shown, total = capped(tags, TAGS_SHOWN)
        print(f"tags (newest {len(shown)} of {total}):")
        for line in shown:
            print(f"{line.split(' ', 1)[0]} · tag · {line.split(' ', 1)[1]}")
        shown, total = capped(git(repo, "log", ref, "--no-merges", "--since=30.days", "--format=%ad git:%h %s", "--date=short") if base else [], RECENT_SHOWN)
        print(f"commits on {base}, last 30 days (newest {len(shown)} of {total}):")
        for line in shown:
            print(f"{line.split(' ', 1)[0]} · commit · {line.split(' ', 1)[1]}")

    section("repo docs")
    if not repo:
        print("skipped - no project path")
    for name, n in (DOC_HEADS.items() if repo else ()):
        p = Path(repo) / name
        if not p.is_file():
            print(f"{name}: absent")
            continue
        lines = p.read_text(errors="replace").splitlines()
        print(f"{name} (first {min(n, len(lines))} of {len(lines)} lines):")
        for line in lines[:n]:
            print(f"  {line}")

    section(f"knowledge base ({KNOWLEDGE_INDEX})")
    names = {slug.lower(), proj.get("group", "").lower(), proj.get("name", "").lower()} - {""}
    found = False
    if KNOWLEDGE_INDEX.is_file():
        keep = False
        for line in KNOWLEDGE_INDEX.read_text(errors="replace").splitlines():
            if line.startswith("## "):
                head = line[3:].strip().lower()
                keep = head in names or any(n.startswith(head) for n in names)
                found = found or keep
            if keep:
                print(f"  {line}")
    if not found:
        print("no section for this project")


if __name__ == "__main__":
    main()
