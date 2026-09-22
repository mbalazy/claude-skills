#!/usr/bin/env python3
"""Triage pm tasks into cleanup categories and apply the user's picks.

    scan.py [--project SLUG ...] [--no-git] [--no-gh] [--plan FILE]
            [--done-days 14] [--todo-days 90] [--waiting-days 60] [--doing-days 30]
    scan.py apply --plan FILE --pick "A 3 7 D -40" [--as STATUS] [--dry-run]

scan  reads every task under $PM_DATA_DIR (default ~/.claude/pm), computes the
      evidence signals, assigns ONE category per task (first match wins), prints
      the numbered list (continuous numbering across categories) and writes the
      plan JSON the apply step maps numbers back through.
apply resolves the pick string (letters = whole category, numbers = items,
      "-N" / "bez N" = exclude, "N-M" = range) and runs `pm mv` for status
      moves. Deletes are NEVER executed here - they are printed as the exact ids
      for the MCP pm_delete_task tool, which is the only sanctioned delete path.

Stdlib only (no PyYAML on the homebrew python); the frontmatter parser handles
scalars, quoted scalars, block scalars (| |- > >-), lists and one-level maps.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

HOME = os.path.expanduser("~")
PM_ROOT = os.environ.get("PM_DATA_DIR") or os.path.join(HOME, ".claude", "pm")
NOW = dt.datetime.now()
TERMINAL = {"done", "archived", "rejected", "skipped", "cancelled", "canceled", "closed", "dropped"}
GH_URL = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/pull/\d+")

CATEGORIES = [
    # letter, label, action, target
    ("A", "ZROBIONE, DO SCHOWANIA", "mv", "archived"),
    ("B", "ZAMKNIETE W RZECZYWISTOSCI (jest dowod)", "mv", "archived"),
    ("C", "SMIECI (puste, duplikaty) - USUNIECIE, nieodwracalne", "delete", ""),
    ("D", "PRAWDOPODOBNIE MARTWE (niepewne - powod przy kazdym)", "mv", "archived"),
    ("E", "STARY STATUS (task zyje, status klamie) - przeniesienie", "mv", None),  # per-item target
    ("F", "NIE RUSZAC", "none", ""),
]


# ----------------------------------------------------------------------------- parsing
def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        inner = v[1:-1]
        return inner.replace("''", "'") if v[0] == "'" else inner.replace('\\"', '"')
    return v


def parse_frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n?", text, re.S)
    if not m:
        return None, text
    lines = m.group(1).split("\n")
    fm = {}
    i = 0
    top = re.compile(r"^([A-Za-z_][\w-]*):\s*(.*)$")
    while i < len(lines):
        mm = top.match(lines[i])
        if not mm:
            i += 1
            continue
        key, val = mm.group(1), mm.group(2)
        i += 1
        if val in ("|", "|-", ">", ">-", "|+", ">+"):
            block = []
            while i < len(lines) and (lines[i].startswith(" ") or lines[i] == ""):
                block.append(lines[i].strip())
                i += 1
            fm[key] = "\n".join(block).strip()
        elif val == "":
            items, mapping = [], {}
            while i < len(lines) and lines[i].startswith(" "):
                s = lines[i].strip()
                if s.startswith("- "):
                    items.append(unquote(s[2:]))
                elif ":" in s:
                    k, _, v = s.partition(":")
                    mapping[k.strip()] = unquote(v)
                i += 1
            fm[key] = items if items else mapping
        elif val.startswith("[") and val.endswith("]"):
            fm[key] = [unquote(x) for x in val[1:-1].split(",") if x.strip()]
        else:
            fm[key] = unquote(val)
    return fm, text[m.end():]


def parse_project(slug):
    path = os.path.join(PM_ROOT, slug, "project.yaml")
    try:
        fm, _ = parse_frontmatter("---\n" + open(path, errors="ignore").read() + "\n---\n")
    except OSError:
        return {}
    return fm or {}


def days_since(s):
    if not s:
        return None
    try:
        return (NOW - dt.datetime.strptime(str(s)[:10], "%Y-%m-%d")).days
    except ValueError:
        return None


# ----------------------------------------------------------------------------- evidence
class Evidence:
    def __init__(self, use_git, use_gh):
        self.use_git, self.use_gh = use_git, use_gh
        self.session_mtime = self._index_sessions()
        self.git_cache, self.gh_cache, self.base_cache = {}, {}, {}

    @staticmethod
    def _index_sessions():
        idx = {}
        roots = [os.path.join(HOME, ".claude", "projects")]
        roots += glob.glob(os.path.join(HOME, ".claude-*", "projects"))
        for root in roots:
            for d in glob.glob(os.path.join(root, "*")):
                try:
                    for e in os.scandir(d):
                        if e.name.endswith(".jsonl"):
                            uuid = e.name[:-6]
                            mt = e.stat().st_mtime
                            if mt > idx.get(uuid, 0):
                                idx[uuid] = mt
                except OSError:
                    pass
        return idx

    def last_session_age(self, sessions):
        ages = []
        for s in sessions or []:
            mt = self.session_mtime.get(s)
            if mt:
                ages.append((NOW - dt.datetime.fromtimestamp(mt)).days)
        return min(ages) if ages else None

    @staticmethod
    def _run(args, cwd, timeout=10):
        try:
            r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
            return r.returncode, r.stdout.strip()
        except (subprocess.TimeoutExpired, OSError):
            return 1, ""

    def base_branch(self, path):
        if path in self.base_cache:
            return self.base_cache[path]
        rc, out = self._run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], path)
        base = out.split("/", 1)[1] if rc == 0 and "/" in out else None
        if not base:
            for cand in ("main", "master", "develop"):
                if self._run(["git", "rev-parse", "--verify", "-q", cand], path)[0] == 0:
                    base = cand
                    break
        self.base_cache[path] = base
        return base

    def branch(self, path, branch):
        """-> dict(exists, merged, last_commit_age, base) or None when not checkable."""
        if not (self.use_git and path and branch and os.path.isdir(os.path.join(path, ".git"))):
            return None
        key = (path, branch)
        if key in self.git_cache:
            return self.git_cache[key]
        base = self.base_branch(path)
        res = {"exists": False, "merged": False, "last_commit_age": None, "base": base}
        if base and branch != base:
            ref = branch
            if self._run(["git", "rev-parse", "--verify", "-q", ref], path)[0] != 0:
                ref = "origin/" + branch
                if self._run(["git", "rev-parse", "--verify", "-q", ref], path)[0] != 0:
                    ref = None
            if ref:
                res["exists"] = True
                res["merged"] = self._run(["git", "merge-base", "--is-ancestor", ref, base], path)[0] == 0
                rc, out = self._run(["git", "log", "-1", "--format=%ct", ref], path)
                if rc == 0 and out.isdigit():
                    res["last_commit_age"] = (NOW - dt.datetime.fromtimestamp(int(out))).days
        self.git_cache[key] = res
        return res

    def epic_merged(self, path, tracker):
        """-> merge-commit subject when a merge of epic/<tracker> into the base is on the base's history."""
        if not (self.use_git and path and tracker and os.path.isdir(os.path.join(path, ".git"))):
            return None
        key = ("epic", path, tracker)
        if key in self.git_cache:
            return self.git_cache[key]
        base = self.base_branch(path)
        found = None
        if base:
            rc, out = self._run(["git", "log", "--merges", "--format=%s", base], path, timeout=20)
            if rc == 0:
                pat = re.compile(r"(from \S*|branch ')epic/" + re.escape(tracker) + r"'?$")
                for line in out.splitlines():
                    if pat.search(line.strip()):
                        found = line.strip()
                        break
        self.git_cache[key] = found
        return found

    def pr(self, path, url):
        """-> 'MERGED' | 'CLOSED' | 'OPEN' | None."""
        if not (self.use_gh and url and GH_URL.match(url)):
            return None
        if url in self.gh_cache:
            return self.gh_cache[url]
        cwd = path if path and os.path.isdir(path) else HOME
        args = ["gh", "pr", "view", url, "--json", "state", "-q", ".state"]
        # direnv-scoped GH_TOKEN (per-project auth) - honour it when an .envrc is in reach
        d = cwd
        while d and d != HOME and d != "/":
            if os.path.exists(os.path.join(d, ".envrc")):
                args = ["direnv", "exec", d] + args
                break
            d = os.path.dirname(d)
        rc, out = self._run(args, cwd, timeout=20)
        state = out.strip().upper() if rc == 0 and out.strip() else None
        self.gh_cache[url] = state
        return state


# ----------------------------------------------------------------------------- scan
def load_tasks(projects):
    tasks = []
    for pdir in sorted(glob.glob(os.path.join(PM_ROOT, "*"))):
        slug = os.path.basename(pdir)
        if not os.path.isdir(pdir) or (projects and slug not in projects):
            continue
        proj = parse_project(slug)
        for f in sorted(glob.glob(os.path.join(pdir, "*.md"))):
            try:
                text = open(f, errors="ignore").read()
            except OSError:
                continue
            fm, body = parse_frontmatter(text)
            if fm is None:
                continue
            links = fm.get("links") if isinstance(fm.get("links"), dict) else {}
            tasks.append({
                "file": f, "project": slug, "proj": proj,
                "id": str(fm.get("id") or ""), "title": str(fm.get("title") or ""),
                "status": str(fm.get("status") or "").lower(),
                "age": days_since(fm.get("updated")), "age_created": days_since(fm.get("created")),
                "brief": str(fm.get("brief") or ""), "body_len": len(body.strip()),
                "links": links, "branch": str(fm.get("branch") or ""), "parent": str(fm.get("parent") or ""),
                "sessions": fm.get("sessions") if isinstance(fm.get("sessions"), list) else [],
            })
    return tasks


def norm_title(t):
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def categorize(tasks, ev, a):
    by_id = {t["id"]: t for t in tasks if t["id"]}
    children = defaultdict(list)
    for t in tasks:
        if t["parent"]:
            children[t["parent"]].append(t)

    # duplicate titles within a project: the richest/newest survives, the rest are losers
    groups = defaultdict(list)
    for t in tasks:
        if t["status"] != "archived" and t["title"]:
            groups[(t["project"], norm_title(t["title"]))].append(t)
    dup_loser = {}
    for g in groups.values():
        if len(g) < 2:
            continue
        # a finished task is a record, never a loser; an open twin of a finished one is junk
        finished = [t for t in g if t["status"] in TERMINAL]
        live = [t for t in g if t["status"] not in TERMINAL]
        if finished:
            for t in live:
                dup_loser[t["file"]] = finished[0]["id"]
        else:
            live.sort(key=lambda t: (t["body_len"] + len(t["brief"]), -(t["age"] or 9999)), reverse=True)
            for t in live[1:]:
                dup_loser[t["file"]] = live[0]["id"]

    out = []
    for t in tasks:
        st, age = t["status"], t["age"] if t["age"] is not None else 9999
        if st == "archived":
            continue
        statuses = [s.lower() for s in (t["proj"].get("statuses") or ["todo", "doing", "waiting", "done"])]
        path = os.path.expanduser(str(t["proj"].get("path") or ""))
        is_tracker = bool(children.get(t["id"]))
        open_children = [c for c in children.get(t["id"], []) if c["status"] not in TERMINAL]
        parent = by_id.get(t["parent"]) if t["parent"] else None
        parent_st = parent["status"] if parent else ("missing" if t["parent"] else "")
        sess_age = ev.last_session_age(t["sessions"])
        terminal = st in TERMINAL

        cat, reason, target = None, "", None

        # --- C: junk
        if not t["id"]:
            cat, reason = "C", "plik bez id"
        elif t["file"] in dup_loser:
            cat, reason = "C", f"duplikat tytulu, zostaje {dup_loser[t['file']]}"
        elif t["body_len"] < 40 and not t["brief"] and not t["links"] and not is_tracker and not terminal:
            cat, reason = "C", "pusty: brak body/brief/linkow"

        # --- A: finished, just hide
        if cat is None and terminal:
            if age >= a.done_days:
                cat, reason = "A", f"{st} od {age}d"
            else:
                cat, reason = "F", f"{st} swiezo ({age}d)"

        # --- trackers with live children are never proposed
        if cat is None and open_children:
            cat, reason = "F", f"tracker z {len(open_children)} otwartymi subami"

        # --- B: proof of closure on an open status
        if cat is None:
            epic = ev.epic_merged(path, t["parent"]) if t["parent"] and st in ("merged", "pushed", "doing") else None
            if st not in statuses:
                cat, reason = "B", f"status '{st}' nie istnieje w projekcie"
            elif parent_st in TERMINAL and parent_st:
                cat, reason = "B", f"rodzic {t['parent']} jest {parent_st}"
            elif is_tracker and not open_children:
                cat, reason = "B", f"tracker: wszystkie {len(children[t['id']])} suby zamkniete"
            elif epic:
                cat, reason = "B", f"epic rodzica wmergowany: {epic[:60]}"
            else:
                pr_state = ev.pr(path, t["links"].get("pr", "")) if t["links"].get("pr") else None
                if pr_state in ("MERGED", "CLOSED"):
                    cat, reason = "B", f"PR {pr_state.lower()} ({t['links']['pr'].rsplit('/', 1)[-1]})"
                else:
                    br = ev.branch(path, t["branch"])
                    if br and br["merged"] and not is_tracker:
                        cat, reason = "B", f"branch {t['branch']} wmergowany w {br['base']}"
                    elif br and br["merged"] and is_tracker:
                        cat, reason = "B", f"epic branch {t['branch']} wmergowany w {br['base']}, suby zamkniete"
                    t["_br"], t["_pr"] = br, pr_state

        # --- E: the status lies
        if cat is None and st == "doing" and age >= a.doing_days:
            br = t.get("_br")
            commit_age = br["last_commit_age"] if br else None
            quiet = (sess_age is None or sess_age >= a.doing_days) and (commit_age is None or commit_age >= a.doing_days)
            if quiet:
                target = "waiting" if re.search(r"\b(czek|wait|blocked|review)", t["brief"], re.I) else "todo"
                bits = [f"doing od {age}d"]
                bits.append(f"sesja {sess_age}d temu" if sess_age is not None else "brak sesji")
                bits.append(f"commit {commit_age}d temu" if commit_age is not None else "brak commitow")
                cat, reason = "E", "-> " + target + ": " + ", ".join(bits)
        if cat is None and st == "merged" and not t["parent"] and age >= a.waiting_days:
            cat, reason, target = "E", f"-> done: 'merged' bez rodzica od {age}d", "done"

        # --- D: probably dead
        if cat is None and not terminal:
            limit = {"todo": a.todo_days, "doing": None}.get(st, a.waiting_days)
            if limit is not None and age >= limit:
                bits = [f"{st} od {age}d"]
                if not t["brief"]:
                    bits.append("brak briefu")
                if not t["sessions"]:
                    bits.append("nigdy nie otwarty w sesji")
                elif sess_age is not None:
                    bits.append(f"sesja {sess_age}d temu")
                if t["parent"]:
                    bits.append(f"sub {t['parent']} ({parent_st})")
                if t.get("_pr") == "OPEN":
                    bits.append("PR otwarty")
                if is_tracker:
                    bits.append("tracker, suby zamkniete")
                cat, reason = "D", ", ".join(bits)

        if cat is None:
            cat, reason = "F", f"{st}, {age}d"
        out.append((cat, t, reason, target))
    return out


def build_plan(rows):
    order = {c[0]: i for i, c in enumerate(CATEGORIES)}
    rows.sort(key=lambda r: (order[r[0]], r[1]["project"], -(r[1]["age"] or 0)))
    plan, n = [], 0
    for cat, t, reason, target in rows:
        letter, label, action, ctarget = next(c for c in CATEGORIES if c[0] == cat)
        if action == "none":
            plan.append({"n": None, "cat": cat, "id": t["id"], "project": t["project"], "status": t["status"],
                         "age": t["age"], "title": t["title"], "reason": reason, "action": "none", "target": ""})
            continue
        n += 1
        plan.append({"n": n, "cat": cat, "id": t["id"], "project": t["project"], "status": t["status"],
                     "age": t["age"], "title": t["title"], "reason": reason,
                     "action": action, "target": target or ctarget, "brief": t["brief"][:160]})
    return plan


def render(plan, show_f, show_a):
    lines = []
    for letter, label, action, ctarget in CATEGORIES:
        items = [p for p in plan if p["cat"] == letter]
        if not items:
            continue
        act = {"mv": f"-> {ctarget or 'status podany przy pozycji'}", "delete": "-> pm_delete_task", "none": "tylko licznik"}[action]
        lines.append(f"\n{letter}. {label}  [{len(items)}]  {act}")
        if action == "none" and not show_f:
            by = defaultdict(int)
            for p in items:
                by[p["project"]] += 1
            lines.append("   " + ", ".join(f"{k} {v}" for k, v in sorted(by.items())))
            continue
        if letter == "A" and not show_a:
            # done tasks are uniform - one range per project is all the picker needs
            by = defaultdict(list)
            for p in items:
                by[p["project"]].append(p["n"])
            for proj, ns in sorted(by.items()):
                lines.append(f"   {min(ns):>4}-{max(ns):<4} {proj} ({len(ns)})")
            continue
        cur = None
        for p in items:
            if p["project"] != cur:
                cur = p["project"]
                lines.append(f"   [{cur}]")
            num = f"{p['n']:>4}." if p["n"] else "     "
            age = f"{p['age']}d" if p["age"] is not None else "?"
            lines.append(f"  {num} {p['id']:<26} {p['status']:<9} {age:>5}  {p['title'][:58]}")
            if letter != "A":
                lines.append(f"        {p['reason']}")
    return "\n".join(lines)


# ----------------------------------------------------------------------------- apply
def resolve_picks(plan, pick):
    numbered = {p["n"]: p for p in plan if p["n"]}
    chosen, excluded = set(), set()
    tokens = re.split(r"[\s,;]+", pick.strip())
    exclude_next = False
    for tok in tokens:
        if not tok:
            continue
        low = tok.lower()
        if low in ("bez", "oprocz", "oprócz", "minus", "except"):
            exclude_next = True
            continue
        neg = tok.startswith("-") or exclude_next
        tok = tok.lstrip("-")
        exclude_next = False
        target = excluded if neg else chosen
        if re.fullmatch(r"[A-Za-z]", tok):
            target.update(p["n"] for p in numbered.values() if p["cat"] == tok.upper())
        elif re.fullmatch(r"\d+-\d+", tok):
            lo, hi = map(int, tok.split("-"))
            target.update(range(lo, hi + 1))
        elif tok.isdigit():
            target.add(int(tok))
        else:
            sys.exit(f"nie rozumiem tokenu: {tok!r}")
    return [numbered[n] for n in sorted(chosen - excluded) if n in numbered]


def apply(args):
    plan = json.load(open(args.plan))
    picked = resolve_picks(plan, args.pick)
    if not picked:
        sys.exit("nic nie wybrano")
    deletes, moved, failed = [], 0, []
    for p in picked:
        action, target = p["action"], p["target"]
        if args.as_status:
            action, target = "mv", args.as_status
        if action == "delete":
            deletes.append(p)
            continue
        cmd = ["pm", "mv", p["project"], p["id"], target]
        print(("DRY  " if args.dry_run else "") + " ".join(cmd))
        if args.dry_run:
            continue
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 0:
            moved += 1
        else:
            failed.append((p["id"], (r.stderr or r.stdout).strip()))
    print(f"\nprzeniesione: {moved}, bledy: {len(failed)}")
    for tid, err in failed:
        print(f"  {tid}: {err}")
    if deletes:
        print("\nDO USUNIECIA przez MCP pm_delete_task (dokladne id, po jednym):")
        for p in deletes:
            print(f"  {p['id']}   [{p['project']}] {p['title'][:60]}")


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("scan")
    s.add_argument("--project", action="append", default=[])
    s.add_argument("--no-git", action="store_true")
    s.add_argument("--no-gh", action="store_true")
    s.add_argument("--show-f", action="store_true", help="list category F items instead of counts")
    s.add_argument("--show-a", action="store_true", help="list every category A item instead of per-project ranges")
    s.add_argument("--plan", default="plan.json")
    s.add_argument("--done-days", type=int, default=14)
    s.add_argument("--todo-days", type=int, default=90)
    s.add_argument("--waiting-days", type=int, default=60)
    s.add_argument("--doing-days", type=int, default=30)
    a = sub.add_parser("apply")
    a.add_argument("--plan", default="plan.json")
    a.add_argument("--pick", required=True)
    a.add_argument("--as", dest="as_status", default="", help="override the target status for every picked item")
    a.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(sys.argv[1:] if len(sys.argv) > 1 and sys.argv[1] in ("scan", "apply") else ["scan"] + sys.argv[1:])

    if args.cmd == "apply":
        return apply(args)
    tasks = load_tasks(set(args.project))
    ev = Evidence(use_git=not args.no_git, use_gh=not args.no_gh)
    rows = categorize(tasks, ev, args)
    plan = build_plan(rows)
    json.dump(plan, open(args.plan, "w"), ensure_ascii=False, indent=1)
    total = len(tasks)
    counts = {c[0]: sum(1 for p in plan if p["cat"] == c[0]) for c in CATEGORIES}
    print(f"tasks: {total} (bez archived: {len(plan)})   " + "  ".join(f"{k}={v}" for k, v in counts.items()))
    print(render(plan, args.show_f, args.show_a))
    print(f"\nplan: {args.plan}")


if __name__ == "__main__":
    main()
