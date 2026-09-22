#!/usr/bin/env python3
"""check-queue.py - mechanical readiness check of a solo queue (pm parent + subs).

Usage:
  check-queue.py <tracker-id> [--pm-root DIR] [--no-git] [-v]

Read-only: never writes pm files, never fetches, never switches branches.
Frontmatter is parsed with the system ruby's YAML (no Python dependency).
Exit: 0 = no errors (warnings allowed), 1 = errors, 2 = usage / not found.
"""
import argparse
import difflib
import glob
import json
import os
import re
import subprocess
import sys

SUB_REQUIRED = ["Description", "Bug as the user sees it", "Reporter's scenario", "Context",
                "Decided approach", "Acceptance Criteria", "Verification recipe"]
SUB_EXPECTED = ["Open Questions", "Next Steps"]
PARENT_REQUIRED = ["Description", "Context", "Queue and delivery", "Shared constraints",
                   "Acceptance Criteria", "Verification and launch"]
PARENT_EXPECTED = ["Pinned sources", "Open Questions", "Next Steps"]
SHARED_START = "<!-- solo-prep:shared:start -->"
SHARED_END = "<!-- solo-prep:shared:end -->"
SPEC_START = "<!-- spec:start -->"
SPEC_END = "<!-- spec:end -->"
AC_SPLIT = 10
LANDED = {"done", "merged", "pushed", "archived"}

PATH_RE = re.compile(r"(?<![\w/.~-])((?:~|/Users|/home|/private|/opt|/tmp|/var)/[^\s`'\"<>()\[\]{}|,;*$]+)")
DATED_RE = re.compile(r"^(?P<stem>.+?)[-_](?P<date>\d{4}-\d{2}-\d{2})(?P<ext>\.[A-Za-z0-9.]+)?$")


class Report:
    def __init__(self, verbose):
        self.rows = []
        self.verbose = verbose

    def add(self, level, where, msg):
        self.rows.append((level, where, msg))

    def err(self, where, msg):
        self.add("ERROR", where, msg)

    def warn(self, where, msg):
        self.add("WARN", where, msg)

    def ok(self, where, msg):
        self.add("ok", where, msg)

    def print(self):
        for level, where, msg in self.rows:
            if level == "ok" and not self.verbose:
                continue
            print(f"{level:<5}  {where}: {msg}")
        errors = sum(1 for r in self.rows if r[0] == "ERROR")
        warns = sum(1 for r in self.rows if r[0] == "WARN")
        verdict = "READY" if errors == 0 else "NOT READY"
        print(f"\n{verdict}: {errors} error(s), {warns} warning(s)")
        return errors


def run(cmd, cwd=None, stdin=None, timeout=60):
    try:
        p = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def yaml_load(raw):
    code, out, err = run(["ruby", "-rdate", "-ryaml", "-rjson", "-e",
                          "puts JSON.generate(YAML.load(STDIN.read) || {})"], stdin=raw)
    if code != 0:
        raise ValueError(f"ruby YAML parse failed: {err.strip().splitlines()[-1] if err.strip() else code}")
    return json.loads(out)


def load_task(path):
    text = open(path, encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---[ \t]*\n?(.*)\Z", text, re.S)
    if not m:
        return None
    fm = yaml_load(m.group(1))
    body = m.group(2)
    s, e = body.find(SPEC_START), body.find(SPEC_END)
    spec = body[s + len(SPEC_START):e].strip() if s != -1 and e > s else ""
    return {"path": path, "fm": fm, "body": body, "spec": spec, "id": str(fm.get("id", ""))}


def raw_field(path, key):
    try:
        with open(path, encoding="utf-8") as fh:
            head = fh.read(4000)
    except OSError:
        return None
    m = re.search(rf"^{re.escape(key)}:\s*['\"]?([^'\"\n]+?)['\"]?\s*$", head, re.M)
    return m.group(1) if m else None


def sections(md):
    """[(heading, text)] for level-two headings outside code fences."""
    out, cur, fence = [], None, False
    for line in md.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        if not fence and line.startswith("## "):
            cur = [line[3:].strip(), []]
            out.append(cur)
            continue
        if cur is not None:
            cur[1].append(line)
    return [(h, "\n".join(b).strip()) for h, b in out]


def deep_headings(md):
    found, fence = [], False
    for line in md.split("\n"):
        if line.lstrip().startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^#{3,6}\s+(.*?)\s*$", line)
        if m:
            found.append(m.group(1))
    return found


def section_text(secs, name):
    for h, t in secs:
        if h.lower() == name.lower():
            return t
    return None


def check_headings(rep, where, spec, required, expected):
    secs = sections(spec)
    names = [h.lower() for h, _ in secs]
    deep = [d.lower() for d in deep_headings(spec)]
    for name, level in [(n, "ERROR") for n in required] + [(n, "WARN") for n in expected]:
        if name.lower() in names:
            continue
        near = [h for h, _ in secs if h.lower().startswith(name.lower().split()[0])]
        hint = ""
        if near:
            hint = f" (found '## {near[0]}' - use the exact name)"
        elif name.lower() in deep:
            hint = " (found at a deeper level - use '## ')"
        rep.add(level, where, f"'## {name}' missing{hint}")
    return secs


def shared_block(text):
    s, e = text.find(SHARED_START), text.find(SHARED_END)
    if s == -1 or e <= s:
        return None
    lines = [ln.rstrip() for ln in text[s + len(SHARED_START):e].strip("\n").split("\n")]
    out = []
    for ln in lines:
        if ln == "" and out and out[-1] == "":
            continue
        out.append(ln)
    return "\n".join(out).strip()


def block_in_section(spec, section):
    pos = spec.find(SHARED_START)
    if pos == -1:
        return False
    current = None
    for m in re.finditer(r"^## (.*)$", spec, re.M):
        if m.start() > pos:
            break
        current = m.group(1).strip()
    return current is not None and current.lower() == section.lower()


def find_cycle(graph):
    state, stack = {}, []

    def dfs(node):
        state[node] = 1
        stack.append(node)
        for dep in graph.get(node, []):
            if dep not in graph:
                continue
            if state.get(dep) == 1:
                return stack[stack.index(dep):] + [dep]
            if dep not in state:
                cyc = dfs(dep)
                if cyc:
                    return cyc
        state[node] = 2
        stack.pop()
        return None

    for node in graph:
        if node not in state:
            cyc = dfs(node)
            if cyc:
                return cyc
    return None


def locate_task(pm_root, task_id):
    for path in glob.glob(os.path.join(pm_root, "*", "*.md")):
        base = os.path.basename(path)
        if not (base.startswith(task_id + "-") or base == task_id + ".md"):
            continue
        if raw_field(path, "id") == task_id:
            return path
    for path in glob.glob(os.path.join(pm_root, "*", "*.md")):
        if raw_field(path, "id") == task_id:
            return path
    return None


def git(repo, *args):
    return run(["git", "-C", repo, *args], timeout=120)


def ref_exists(repo, ref):
    return git(repo, "rev-parse", "--verify", "--quiet", ref)[0] == 0


def main():
    ap = argparse.ArgumentParser(description="Mechanical readiness check of a solo queue.")
    ap.add_argument("tracker")
    ap.add_argument("--pm-root", default=os.path.expanduser("~/.claude/pm"))
    ap.add_argument("--no-git", action="store_true", help="skip checks that read the code repo's git")
    ap.add_argument("-v", "--verbose", action="store_true", help="also print passing facts")
    args = ap.parse_args()
    rep = Report(args.verbose)

    tracker_path = locate_task(args.pm_root, args.tracker)
    if not tracker_path:
        print(f"tracker {args.tracker} not found under {args.pm_root}", file=sys.stderr)
        return 2
    project_dir = os.path.dirname(tracker_path)
    slug = os.path.basename(project_dir)
    try:
        parent = load_task(tracker_path)
        project = yaml_load(open(os.path.join(project_dir, "project.yaml"), encoding="utf-8").read())
    except (OSError, ValueError) as exc:
        print(f"cannot read tracker or project.yaml: {exc}", file=sys.stderr)
        return 2
    repo = os.path.expanduser(str(project.get("path", "")))
    prefix = str(project.get("prefix", ""))
    print(f"# check-queue {args.tracker} (project {slug}, repo {repo})\n")

    subs = []
    for path in sorted(glob.glob(os.path.join(project_dir, "*.md"))):
        if path == tracker_path or raw_field(path, "parent") != args.tracker:
            continue
        task = load_task(path)
        if task and str(task["fm"].get("status", "")) != "archived":
            subs.append(task)
    if not subs:
        rep.err(args.tracker, "no subtasks with this parent")
    subs.sort(key=lambda t: (int(t["fm"].get("order") or 10**9), t["id"]))
    rep.ok(args.tracker, f"{len(subs)} sub(s): " + ", ".join(t["id"] for t in subs))
    by_id = {t["id"]: t for t in subs}

    # ---- parent -------------------------------------------------------------
    P = args.tracker
    if not parent["spec"]:
        rep.err(P, "no Spec block")
    psecs = check_headings(rep, P, parent["spec"], PARENT_REQUIRED, PARENT_EXPECTED)
    if not str(parent["fm"].get("brief") or "").strip():
        rep.err(P, "brief empty")
    canonical = shared_block(parent["spec"])
    if canonical is None:
        rep.err(P, "no shared block (<!-- solo-prep:shared:start/end -->) in '## Shared constraints'")
    else:
        if not block_in_section(parent["spec"], "Shared constraints"):
            rep.warn(P, "shared block is not inside '## Shared constraints'")
        low = canonical.lower()
        if not ((prefix and f"{prefix}-" in low) or "pm id" in low):
            rep.warn(P, f"shared block does not state the internal-id rule (no '{prefix}-' example, no 'pm id')")
    pinned = section_text(psecs, "Pinned sources")
    if pinned is not None and not PATH_RE.search(pinned):
        rep.warn(P, "'## Pinned sources' names no local copy path")
    context = section_text(psecs, "Context") or ""

    # ---- launch line ----------------------------------------------------------
    launch, flags = None, []
    for line in parent["spec"].split("\n"):
        m = re.search(r"/solo\s+(\S+)(.*)$", line)
        if m and m.group(1).strip("`") == args.tracker:
            launch, flags = line.strip(), m.group(2).replace("`", " ").split()
            break
    if not launch:
        rep.err(P, f"no launch line '/solo {args.tracker} ...' in the Spec")
    # The launcher line: the last non-empty line BEFORE the /solo line. Its
    # name is the user's (a shell abbreviation, or `claude` itself with the
    # flags spelled out), so the check is positional, never by name.
    spec_lines = parent["spec"].split("\n")
    launcher = None
    if launch:
        idx = next((i for i, ln in enumerate(spec_lines) if ln.strip() == launch), None)
        if idx is not None:
            for ln in reversed(spec_lines[:idx]):
                s = ln.strip()
                if s and not s.startswith("```"):
                    launcher = s
                    break
    if not launcher or launcher.startswith("cd ") or launcher.startswith("#"):
        rep.err(P, "launch block has no launcher line before /solo (the line that starts Claude Code)")
    else:
        model = str(parent["fm"].get("model") or "")
        mm = re.search(r"--model\s+(\S+)", launcher)
        if model and not mm:
            rep.warn(P, f"launcher line has no --model although the parent says model: {model}")
        elif model and mm and mm.group(1).strip("`,.;:)'\"") != model:
            rep.warn(P, f"launcher --model {mm.group(1).strip(chr(96))} differs from parent model: {model}")
    for bad in ("--push", "--pr"):
        if bad in flags:
            rep.warn(P, f"launch line has {bad} - only with the user's explicit authorization")
    runtime_flag = next((f for f in flags if f in ("--web", "--sim", "--no-runtime")), None)
    base = None
    if "--base" in flags and flags.index("--base") + 1 < len(flags):
        base = flags[flags.index("--base") + 1]

    # ---- profile / runtime --------------------------------------------------------
    code, show, _ = run(["pm", "executor", "show", slug], timeout=60)
    skill = None
    if code != 0:
        rep.warn(P, "could not read 'pm executor show' - runtime and base not verified")
    else:
        m = re.search(r"^\s*runtime\s+skill:\s*(\S+)", show, re.M)
        skill = m.group(1) if m else None
        if base is None:
            mb = re.search(r"^\s*base_branch:\s*(\S+)", show, re.M)
            base = mb.group(1) if mb else None
    configs = {"web-verify": ".web-verify/config.md", "simulator-verify": ".simulator-verify/config.md"}
    wanted = {"--web": "web-verify", "--sim": "simulator-verify"}.get(runtime_flag)
    if code == 0:
        if wanted:
            if skill != wanted:
                rep.err(P, f"launch uses {runtime_flag} but the profile's runtime skill is {skill or 'none'} - run /onboarding-projects first")
            elif not os.path.isfile(os.path.join(repo, configs[wanted])):
                rep.err(P, f"launch uses {runtime_flag} but {configs[wanted]} is missing in the repo")
            else:
                rep.ok(P, f"runtime {runtime_flag} via {skill}")
        elif runtime_flag == "--no-runtime" and skill:
            rep.warn(P, f"profile offers runtime ({skill}) but the launch disables it - the user's choice must be recorded")
        elif runtime_flag is None and skill:
            if not os.path.isfile(os.path.join(repo, configs.get(skill, "__none__"))):
                rep.err(P, f"no runtime flag: the run defaults to {skill}, whose repo config is missing")
    if (runtime_flag or skill) and not re.search(r"DECIDED:.*runtime", context, re.I):
        rep.warn(P, "parent '## Context' has no 'DECIDED: runtime ...' line")

    # ---- permissions mirror -----------------------------------------------------
    shared_settings = os.path.join(repo, ".claude", "settings.json")
    if os.path.isfile(shared_settings):
        try:
            perms = json.load(open(shared_settings)).get("permissions", {})
        except (OSError, ValueError):
            perms = {}
        if perms.get("ask"):
            local_path = os.path.join(repo, ".claude", "settings.local.json")
            if not os.path.isfile(local_path):
                rep.err(P, f"repo has {len(perms['ask'])} ask rule(s) but no .claude/settings.local.json deny mirror")
            else:
                try:
                    local_deny = set(json.load(open(local_path)).get("permissions", {}).get("deny", []))
                except (OSError, ValueError):
                    local_deny = set()
                missing = [d for d in perms.get("deny", []) if d not in local_deny]
                if missing:
                    rep.err(P, f"{len(missing)} shared deny rule(s) missing from settings.local.json, e.g. {missing[:3]}")

    # ---- subs -----------------------------------------------------------------------
    branches, orders, graph = {}, {}, {}
    path_refs = []  # (task id, path)
    for t in [parent] + subs:
        for v in (t["fm"].get("links") or {}).values():
            if isinstance(v, str) and PATH_RE.fullmatch(v):
                path_refs.append((t["id"], v))
        for text in (t["spec"], str(t["fm"].get("brief") or "")):
            for m in PATH_RE.finditer(text):
                path_refs.append((t["id"], m.group(1)))

    for t in subs:
        W, fm = t["id"], t["fm"]
        status = str(fm.get("status") or "")
        if not t["spec"]:
            rep.err(W, "no Spec block")
        secs = check_headings(rep, W, t["spec"], SUB_REQUIRED, SUB_EXPECTED)
        for field in ("brief", "ac", "branch"):
            if not str(fm.get(field) or "").strip():
                rep.err(W, f"{field} empty")
        if fm.get("order") in (None, ""):
            rep.err(W, "order missing")
        else:
            orders.setdefault(int(fm["order"]), []).append(W)
        br = str(fm.get("branch") or "")
        if br:
            branches.setdefault(br, []).append(W)
            if base and br == base:
                rep.err(W, f"branch is the base branch {base}")
        if status == "waiting" and not str(fm.get("waiting_for") or "").strip():
            rep.err(W, "status waiting without waiting_for")
        pmodel, smodel = str(parent["fm"].get("model") or ""), str(fm.get("model") or "")
        if pmodel and smodel and pmodel != smodel:
            rep.warn(W, f"model {smodel} differs from the parent's {pmodel}")
        ac = section_text(secs, "Acceptance Criteria")
        if ac is not None:
            boxes = len(re.findall(r"^\s*[-*]\s+\[[ xX]\]", ac, re.M))
            if boxes == 0:
                rep.err(W, "'## Acceptance Criteria' has no checkboxes")
            elif boxes > AC_SPLIT:
                rep.warn(W, f"{boxes} acceptance checkboxes (> {AC_SPLIT}) - split, or justify in the parent")
        recipe = section_text(secs, "Verification recipe")
        if recipe is not None:
            if not recipe.strip():
                rep.err(W, "'## Verification recipe' is empty")
            elif (runtime_flag in ("--web", "--sim") or (runtime_flag is None and skill)) \
                    and not re.search(r"negat(?:ive|yw)|\bvs\.?\s|\bversus\b", recipe, re.I):
                rep.warn(W, "recipe names no negative control")
        block = shared_block(t["spec"])
        if canonical is not None:
            if block is None:
                rep.err(W, "shared block missing")
            elif block != canonical:
                diff = [d for d in difflib.unified_diff(canonical.split("\n"), block.split("\n"), lineterm="", n=0)
                        if d[:1] in "+-" and not d.startswith(("+++", "---"))]
                rep.err(W, f"shared block differs from the parent's: {diff[0][:140] if diff else '(whitespace)'}")
            elif not block_in_section(t["spec"], "Context"):
                rep.warn(W, "shared block is not inside '## Context'")
        graph[W] = [str(d) for d in (fm.get("depends_on") or [])]

    for br, ids in branches.items():
        if len(ids) > 1:
            rep.err(",".join(ids), f"share branch {br}")
    for order, ids in orders.items():
        if len(ids) > 1:
            rep.err(",".join(ids), f"share order {order}")

    for W, deps in graph.items():
        for dep in deps:
            if dep in by_id:
                o1, o2 = by_id[W]["fm"].get("order"), by_id[dep]["fm"].get("order")
                if o1 is not None and o2 is not None and int(o2) >= int(o1):
                    rep.warn(W, f"depends on {dep} whose order ({o2}) is not lower")
                continue
            path = locate_task(args.pm_root, dep)
            if not path:
                rep.err(W, f"depends_on {dep}: no such task")
                continue
            dstatus = raw_field(path, "status") or "?"
            overridden = re.search(rf"^depends_on override:\s*{re.escape(dep)}\b", by_id[W]["spec"] or "", re.M)
            if dstatus not in LANDED and not overridden and str(by_id[W]["fm"].get("status")) != "waiting":
                dbranch = raw_field(path, "branch")
                hint = (f"the run starts this sub only if branch {dbranch} exists with a green brief"
                        if dbranch else "that task names no branch, so the run leaves this sub untouched")
                rep.warn(W, f"depends on {dep} outside the queue with status {dstatus}: {hint}"
                            " (a `depends_on override: <id> counts as satisfied (user, <date>)` line in this sub's Spec overrides)")
    cyc = find_cycle(graph)
    if cyc:
        rep.err(args.tracker, "dependency cycle: " + " -> ".join(cyc))

    # ---- paths and pins -----------------------------------------------------------------
    seen, dated = set(), {}
    for tid, raw in path_refs:
        p = raw.rstrip(".:")
        if "<" in p:
            continue
        full = os.path.expanduser(p)
        if (tid, full) not in seen:
            seen.add((tid, full))
            if not os.path.exists(full):
                rep.err(tid, f"path does not exist: {p}")
        m = DATED_RE.match(os.path.basename(full))
        if m:
            key = (os.path.dirname(full), m.group("stem"), m.group("ext") or "")
            dated.setdefault(key, {}).setdefault(m.group("date"), set()).add(tid)
    for (d, stem, ext), versions in dated.items():
        if len(versions) > 1:
            detail = "; ".join(f"{date} in {', '.join(sorted(ids))}" for date, ids in sorted(versions.items()))
            rep.err(args.tracker, f"source {stem}{ext} pinned at several dates: {detail}")

    # ---- git ------------------------------------------------------------------------------
    if not args.no_git and os.path.isdir(os.path.join(repo, ".git")):
        base_ref = None
        if base:
            if ref_exists(repo, f"refs/remotes/origin/{base}"):
                base_ref = f"origin/{base}"
            elif ref_exists(repo, f"refs/heads/{base}"):
                base_ref = base
                rep.warn(P, f"base {base} exists only locally (no origin/{base})")
            else:
                rep.err(P, f"base branch {base} not found in {repo}")
        else:
            rep.warn(P, "base branch unknown (no --base in the launch line, no profile)")
        if base_ref and prefix:
            pat = re.compile(rf"(?<![\w-]){re.escape(prefix)}-\d+(?:-\d+)?(?![\w-])", re.I)
            reported, scanned = set(), 0
            for t in subs:
                br = str(t["fm"].get("branch") or "")
                if not br or not ref_exists(repo, f"refs/heads/{br}"):
                    continue
                scanned += 1
                hits = []
                _, log, _ = git(repo, "log", "--format=%h %B%x1e", f"{base_ref}..{br}")
                for entry in log.split("\x1e"):
                    entry = entry.strip()
                    if entry and pat.search(entry) and ("commit", entry[:7]) not in reported:
                        reported.add(("commit", entry[:7]))
                        hits.append(f"commit {entry[:7]}: {pat.search(entry).group(0)}")
                _, diff, _ = git(repo, "diff", "--unified=0", "--no-color", f"{base_ref}...{br}")
                current = "?"
                for line in diff.split("\n"):
                    if line.startswith("+++ "):
                        current = line[6:] if line.startswith("+++ b/") else line[4:]
                    elif line.startswith("+") and pat.search(line):
                        key = (current, line)
                        if key not in reported:
                            reported.add(key)
                            hits.append(f"{current}: {line[1:].strip()[:90]}")
                if hits:
                    more = f" (+{len(hits) - 5} more)" if len(hits) > 5 else ""
                    rep.err(t["id"], f"pm ids on branch {br}: " + " | ".join(hits[:5]) + more)
            rep.ok(P, f"scanned {scanned} existing queue branch(es) against {base_ref} for {prefix}-<n> ids")
    return 1 if rep.print() else 0


if __name__ == "__main__":
    sys.exit(main())
