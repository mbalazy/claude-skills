#!/usr/bin/env python3
"""worktree-task: one pm task = one git worktree = one Claude Code session.

    wt.py open   <project> <task-id> [--name N] [--branch B] [--base B] [--no-prepare]
    wt.py launch <project> <name> [--model M] [--max-hours H] [--dry-run]
    wt.py arm    <project> <name>          # guard marker for THIS session (run inside it)
    wt.py status [<project>]
    wt.py env    <project> <name>          # the lane's KEY=VALUE lines
    wt.py close  <project> <name> [--delete-branch] [--discard-ignored]

Per-project state lives in pm's project directory, never in the repo:

    <pm-root>/<project>/.worktrees/config.env        what a worktree of this repo needs
    <pm-root>/<project>/.worktrees/templates/<path>   overlay files rendered into it
    <pm-root>/<project>/.worktrees/notes.md           appended to every kickoff (optional)
    <pm-root>/<project>/.worktrees/lanes/<name>/      entry.env, prepare.log, kickoff.md,
                                                      state.md, evidence/

config.env keys (KEY=VALUE, `#` comments):
    WT_ROOT     where worktrees go (default: <main checkout>/../.wt)
    BASE        branch a new task branch forks from (default: executor base_branch)
    SEED        untracked files copied from the main checkout, with the main
                checkout's path and ports rewritten to this worktree's
    PORTS       ports the MAIN checkout uses, as NAME=PORT; lane n gets PORT + n*LANE_STEP
    LANE_STEP   default 10
    OVERLAYS    untracked files rendered from templates/ ({{NAME}} placeholders);
                each is added to the repo's shared info/exclude so it never shows
                up in `git status`
    PREPARE     shell command run once in a fresh worktree (install, build)
    LANE_ENV    extra environment for PREPARE and the session, NAME=VALUE with
                {{WT}} / {{LANE}} / port placeholders (e.g. a per-worktree cache dir)
    DISPOSABLE  ignored paths `close` may delete with the worktree (glob per path
                component); any other ignored file blocks close without
                --discard-ignored

The main checkout is only ever read (untracked files to seed) and used as the
git directory (`git worktree add/remove`, `fetch`); nothing in it is edited,
switched or built.
"""
import argparse
import fnmatch
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime

PM_ROOT = os.path.expanduser(os.environ.get("PM_ROOT", "~/.claude/pm"))
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOLO_SCRIPTS = os.path.expanduser(os.environ.get("WT_SOLO_SCRIPTS", "~/.claude/skills/solo/scripts"))
CLAUDE = os.environ.get("WT_CLAUDE", "claude")
CONFIG_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
DEFAULT_DISPOSABLE = "node_modules .next .turbo dist build out coverage *.tsbuildinfo next-env.d.ts"
EXCLUDE_HEADER = "# worktree-task overlays: untracked per-worktree files (see the worktree-task skill)"
# Environment a launched session must NOT inherit from the session that launches
# it: CLAUDE_CODE_SESSION_ID is what `pm session-id` reads first, so the child
# would report (and arm the guard for) the parent's id.
ENV_STRIP_PREFIXES = ("CLAUDE_CODE_",)
ENV_STRIP = {"CLAUDECODE", "CLAUDE_PID", "CLAUDE_JOB_DIR", "ANTHROPIC_API_KEY",
             "ANTHROPIC_AUTH_TOKEN", "PM_HEADLESS"}


class Refused(Exception):
    pass


# ---------------------------------------------------------------- small helpers

def now():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def run(cmd, cwd=None, check=True, env=None, timeout=None):
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise Refused(f"{' '.join(cmd)} failed ({p.returncode}): {(p.stderr or p.stdout).strip()}")
    return p


def git(repo, *args, check=True):
    return run(["git", "-C", repo, *args], check=check)


def slurp(path):
    with open(path) as f:
        return f.read()


def read_kv(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k.strip()] = v
    return out


def write_kv(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("# worktree-task lane entry - written by wt.py, do not edit by hand\n")
        for k, v in data.items():
            f.write(f"{k}={json.dumps(str(v))}\n" if re.search(r"\s|[\"'#]", str(v)) else f"{k}={v}\n")
    os.replace(tmp, path)


def frontmatter(path):
    """Top-level scalar keys of a pm task file's YAML frontmatter."""
    out = {}
    with open(path) as f:
        lines = f.read().split("\n")
    if not lines or lines[0].strip() != "---":
        return out
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z_]+):\s*(.*)$", line)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1].replace("''", "'")
            out[m.group(1)] = v
    return out


def safe_name(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name or ""):
        raise Refused(f"unsafe name {name!r}: letters, digits, '.', '_', '-' only")
    return name


def listening_pids(port):
    p = run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], check=False)
    return [int(x) for x in p.stdout.split() if x.strip().isdigit()]


def pid_cwd(pid):
    p = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], check=False)
    for line in p.stdout.splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


def inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def clean_env(extra=None):
    env = {k: v for k, v in os.environ.items()
           if k not in ENV_STRIP and not k.startswith(ENV_STRIP_PREFIXES)}
    env.update(extra or {})
    return env


def memory_index(main):
    key = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(main))
    return os.path.join(CONFIG_DIR, "projects", key, "memory", "MEMORY.md")


# ---------------------------------------------------------------- project model

class Project:
    def __init__(self, slug):
        self.slug = safe_name(slug)
        self.dir = os.path.join(PM_ROOT, slug)
        yaml = os.path.join(self.dir, "project.yaml")
        if not os.path.exists(yaml):
            raise Refused(f"no pm project {slug!r} ({yaml} missing)")
        text = slurp(yaml)
        m = re.search(r"^path:\s*(\S+)\s*$", text, re.M)
        if not m:
            raise Refused(f"{yaml} has no path:")
        self.main = os.path.expanduser(m.group(1).strip("\"'"))
        m = re.search(r"^\s+base_branch:\s*(\S+)\s*$", text, re.M)
        self.executor_base = m.group(1).strip("\"'") if m else ""
        self.wtdir = os.path.join(self.dir, ".worktrees")
        self.lanes = os.path.join(self.wtdir, "lanes")
        cfg_path = os.path.join(self.wtdir, "config.env")
        if not os.path.exists(cfg_path):
            raise Refused(f"no {cfg_path} - write the project's worktree config first (SKILL.md, 'New project')")
        self.cfg = read_kv(cfg_path)
        self.wt_root = os.path.expanduser(self.cfg.get("WT_ROOT") or os.path.join(os.path.dirname(self.main), ".wt"))
        self.base = self.cfg.get("BASE") or self.executor_base or "main"
        self.seed = self.cfg.get("SEED", "").split()
        self.overlays = self.cfg.get("OVERLAYS", "").split()
        self.step = int(self.cfg.get("LANE_STEP", "10"))
        self.main_ports = {}
        for item in self.cfg.get("PORTS", "").split():
            k, _, v = item.partition("=")
            if not v.isdigit():
                raise Refused(f"PORTS item {item!r} is not NAME=PORT")
            self.main_ports[k] = int(v)
        self.prepare = self.cfg.get("PREPARE", "")
        self.disposable = (self.cfg.get("DISPOSABLE") or DEFAULT_DISPOSABLE).split()
        self.lane_env_spec = self.cfg.get("LANE_ENV", "").split()

    def task_file(self, task_id):
        for fn in sorted(os.listdir(self.dir)):
            if fn.startswith(task_id + "-") and fn.endswith(".md"):
                path = os.path.join(self.dir, fn)
                if frontmatter(path).get("id") == task_id:
                    return path
        raise Refused(f"no task {task_id!r} in project {self.slug}")

    def lane_dir(self, name):
        return os.path.join(self.lanes, safe_name(name))

    def entry(self, name):
        return read_kv(os.path.join(self.lane_dir(name), "entry.env"))

    def save(self, name, data):
        os.makedirs(self.lane_dir(name), exist_ok=True)
        write_kv(os.path.join(self.lane_dir(name), "entry.env"), data)

    def entries(self):
        if not os.path.isdir(self.lanes):
            return []
        out = []
        for n in sorted(os.listdir(self.lanes)):
            e = read_kv(os.path.join(self.lanes, n, "entry.env"))
            if e:
                out.append(e)
        return out

    def lane_ports(self, lane):
        return {k: v + self.step * lane for k, v in self.main_ports.items()}

    def lane_env(self, entry):
        """Ports plus LANE_ENV, rendered for one lane - what PREPARE, the session
        and `wt.py env` all get."""
        ports = parse_ports(entry["PORTS"])
        env = {k: str(v) for k, v in ports.items()}
        values = dict(entry, **ports)
        for item in self.lane_env_spec:
            k, _, v = item.partition("=")
            env[k] = render(v, values)
        return env


class Lock:
    def __init__(self, project):
        self.path = os.path.join(project.lanes, ".lock")

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        for _ in range(100):
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                if time.time() - os.path.getmtime(self.path) > 300:
                    os.rmdir(self.path)  # a lock left by a killed wt.py
                    continue
                time.sleep(0.1)
        raise Refused(f"lock {self.path} held for 10s")

    def __exit__(self, *a):
        try:
            os.rmdir(self.path)
        except FileNotFoundError:
            pass


def port_line(ports):
    return " ".join(f"{k}={v}" for k, v in ports.items())


def parse_ports(text):
    out = {}
    for item in (text or "").split():
        k, _, v = item.partition("=")
        if v.isdigit():
            out[k] = int(v)
    return out


# ---------------------------------------------------------------- open

def allocate_lane(project, taken_by_name=None):
    used = {int(e["LANE"]) for e in project.entries()
            if e.get("STATUS") != "closed" and e.get("LANE", "").isdigit() and e.get("NAME") != taken_by_name}
    for lane in range(1, 50):
        if lane in used:
            continue
        ports = project.lane_ports(lane)
        busy = [p for p in ports.values() if listening_pids(p)]
        if busy:
            continue
        return lane, ports
    raise Refused("no free lane (1-49)")


def rewrite(text, main, wt, main_ports, lane_ports):
    text = text.replace(os.path.realpath(main), wt).replace(main, wt)
    for k, port in main_ports.items():
        text = re.sub(rf"(?<!\d){port}(?!\d)", str(lane_ports[k]), text)
    return text


def seed(project, wt, lane, lane_ports):
    done = []
    for rel in project.seed:
        src, dst = os.path.join(project.main, rel), os.path.join(wt, rel)
        if not os.path.isfile(src):
            done.append(f"{rel}: absent in the main checkout, skipped")
            continue
        if os.path.exists(dst):
            done.append(f"{rel}: already there, kept")
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        text = rewrite(slurp(src), project.main, wt, project.main_ports, lane_ports)
        if rel.endswith(".md"):
            text = (f"<!-- worktree-task: copied from {project.main} on {now()[:10]}; path and ports "
                    f"rewritten for this worktree (lane {lane}). -->\n") + text
        with open(dst, "w") as f:
            f.write(text)
        shutil.copymode(src, dst)
        done.append(f"{rel}: seeded")
    return done


def render(template, values):
    def sub(m):
        k = m.group(1)
        if k not in values:
            raise Refused(f"template placeholder {{{{{k}}}}} has no value")
        return str(values[k])
    return re.sub(r"\{\{([A-Z][A-Z0-9_]*)\}\}", sub, template)


def overlay(project, wt, values):
    done = []
    for rel in project.overlays:
        tpl = os.path.join(project.wtdir, "templates", rel)
        if not os.path.isfile(tpl):
            raise Refused(f"overlay {rel}: no template {tpl}")
        dst = os.path.join(wt, rel)
        if git(wt, "ls-files", "--error-unmatch", rel, check=False).returncode == 0:
            raise Refused(f"overlay {rel} is a TRACKED file in this branch - refusing to shadow it")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as f:
            f.write(render(slurp(tpl), values))
        done.append(f"{rel}: rendered")
    ensure_excluded(wt, project.overlays)
    return done


def ensure_excluded(wt, rels):
    if not rels:
        return
    common = git(wt, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    path = os.path.join(common, "info", "exclude")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    have = slurp(path).splitlines() if os.path.exists(path) else []
    add = [f"/{r}" for r in rels if f"/{r}" not in have]
    if not add:
        return
    with open(path, "a") as f:
        if EXCLUDE_HEADER not in have:
            f.write(("\n" if have and have[-1].strip() else "") + EXCLUDE_HEADER + "\n")
        for line in add:
            f.write(line + "\n")


def cmd_open(a):
    project = Project(a.project)
    tfile = project.task_file(a.task)
    fm = frontmatter(tfile)
    name = safe_name(a.name or a.task)
    branch = a.branch or fm.get("branch", "")
    if not branch:
        raise Refused(f"task {a.task} has no branch - pass --branch")
    base = a.base or project.base
    wt = os.path.join(project.wt_root, name)

    with Lock(project):
        old = project.entry(name)
        if old.get("STATUS") == "open":
            if old.get("TASK") != a.task:
                raise Refused(f"lane {name} is open for task {old.get('TASK')}, not {a.task}")
            print(f"already open: {name} -> {old['WT']} (lane {old['LANE']}: {old['PORTS']})")
            return 0
        if os.path.exists(wt):
            raise Refused(f"{wt} exists and is not an open lane of this project - pick another --name")
        holders = [l for l in git(project.main, "worktree", "list", "--porcelain").stdout.splitlines()
                   if l == f"branch refs/heads/{branch}"]
        if holders:
            raise Refused(f"branch {branch} is checked out in another worktree (git worktree list)")
        lane, lane_ports = allocate_lane(project, taken_by_name=name)
        entry = {"NAME": name, "TASK": a.task, "PROJECT": project.slug, "MAIN": project.main,
                 "WT": wt, "BRANCH": branch, "BASE": base, "LANE": lane,
                 "PORTS": port_line(lane_ports), "MAIN_PORTS": port_line(project.main_ports),
                 "STATUS": "opening", "OPENED": now()}
        project.save(name, entry)

    if git(project.main, "fetch", "origin", "--quiet", check=False).returncode != 0:
        time.sleep(2)  # another session's fetch holding a ref lock
        git(project.main, "fetch", "origin", "--quiet")
    exists = git(project.main, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}", check=False).returncode == 0
    os.makedirs(project.wt_root, exist_ok=True)
    if exists:
        git(project.main, "worktree", "add", wt, branch)
        how = f"existing branch {branch}"
    else:
        git(project.main, "worktree", "add", "--no-track", "-b", branch, wt, f"origin/{base}")
        how = f"new branch {branch} from origin/{base}"

    lines = [f"worktree {wt} ({how})"]
    lines += seed(project, wt, lane, lane_ports)
    values = dict(entry, **{k: v for k, v in lane_ports.items()}, LANE=lane)
    lines += overlay(project, wt, values)
    entry["STATUS"] = "open"
    entry["HEAD_AT_OPEN"] = git(wt, "rev-parse", "--short", "HEAD").stdout.strip()
    project.save(name, entry)

    if project.prepare and not a.no_prepare:
        log = os.path.join(project.lane_dir(name), "prepare.log")
        t0 = time.time()
        with open(log, "w") as f:
            p = subprocess.run(project.prepare, shell=True, cwd=wt, stdout=f, stderr=subprocess.STDOUT,
                               env=clean_env(project.lane_env(entry)))
        entry["PREPARE_RC"] = p.returncode
        project.save(name, entry)
        lines.append(f"prepare: exit {p.returncode} in {int(time.time() - t0)}s, log {log}")
    else:
        lines.append("prepare: skipped")

    dirty = git(wt, "status", "--porcelain").stdout.strip()
    lines.append("git status: clean" if not dirty else f"git status NOT clean:\n{dirty}")
    print(f"open: {name} task={a.task} lane={lane} {port_line(lane_ports)}")
    for l in lines:
        print(f"  {l}")
    print(f"next: {sys.argv[0]} launch {project.slug} {name}")
    return 0 if entry.get("PREPARE_RC", 0) in (0, "0") and not dirty else 1


# ---------------------------------------------------------------- launch / arm

def agents():
    p = run([CLAUDE, "agents", "--json", "--all"], check=False, env=clean_env(), timeout=30)
    try:
        return json.loads(p.stdout)
    except ValueError:
        return []


def session_state(entry):
    sid = entry.get("SESSION", "")
    if not sid:
        return "-"
    for s in agents():
        if s.get("sessionId") == sid:
            return s.get("status") or s.get("state") or "listed"
    return "not running"


def check_settings(wt):
    """--setting-sources user,local when the repo's shared settings carry `ask`
    rules (they prompt in bypass too); then the shared deny list must be
    mirrored in the worktree's settings.local.json or it is not in force."""
    shared = os.path.join(wt, ".claude", "settings.json")
    try:
        sp = json.loads(slurp(shared)).get("permissions", {})
    except (OSError, ValueError):
        return []
    if not sp.get("ask"):
        return []
    local = os.path.join(wt, ".claude", "settings.local.json")
    try:
        ld = json.loads(slurp(local)).get("permissions", {}).get("deny", [])
    except (OSError, ValueError):
        raise Refused(f"{shared} has ask rules but {local} is missing - seed it (SEED in config.env)")
    missing = [d for d in sp.get("deny", []) if d not in ld]
    if missing:
        raise Refused(f"{local} lacks {len(missing)} shared deny rule(s): {missing[:3]}")
    return ["--setting-sources", "user,local"]


def kickoff(project, entry):
    lane_ports = parse_ports(entry["PORTS"])
    main_ports = parse_ports(entry["MAIN_PORTS"])
    evidence = os.path.join(project.lane_dir(entry["NAME"]), "evidence")
    os.makedirs(evidence, exist_ok=True)
    notes_path = os.path.join(project.wtdir, "notes.md")
    notes = render(slurp(notes_path), dict(entry, **lane_ports)) if os.path.exists(notes_path) else "(none)"
    values = dict(entry,
                  WT_ROOT=project.wt_root,
                  PORT_LINES=", ".join(f"{k}={v}" for k, v in lane_ports.items()) or "(none)",
                  ENV_LINES=", ".join(f"{k}={v}" for k, v in project.lane_env(entry).items()
                                      if k not in lane_ports) or "(none)",
                  MAIN_PORT_LINES=", ".join(f"{k}={v}" for k, v in main_ports.items()) or "(none)",
                  SEEDED=", ".join(project.seed) or "(none)",
                  OVERLAY_LIST=", ".join(project.overlays) or "(none)",
                  MEMORY=memory_index(project.main),
                  EVIDENCE=evidence,
                  WT_PY=os.path.abspath(__file__),
                  PROJECT_NOTES=notes.strip())
    return render(slurp(os.path.join(SKILL_DIR, "templates", "kickoff.md")), values)


def build_argv(model, name, settings_json, sources, prompt):
    argv = [CLAUDE, "--dangerously-skip-permissions", "--autocompact", "400k", "--settings", settings_json]
    argv += sources
    if model:
        argv += ["--model", model]
    return argv + ["--name", name, "--bg", prompt]


def arm_guard(project, entry, sid, max_hours):
    marker = os.path.expanduser(f"~/.claude/solo/{sid}.active")
    if os.path.exists(marker):
        return f"guard: armed ({marker})"
    state = os.path.join(project.lane_dir(entry["NAME"]), "state.md")
    if not os.path.exists(state):
        with open(state, "w") as f:
            f.write(f"# worktree-task {entry['NAME']} ({entry['TASK']})\n\n## Log\n")
    p = run([os.path.join(SOLO_SCRIPTS, "shift-open.sh"), "--project", project.slug, "--shift", sid,
             "--state", state, "--base", entry["BASE"], "--max-hours", str(max_hours),
             "--budget", str(int(max_hours) * 60 - 30)], check=False)
    if p.returncode != 0:
        raise Refused(f"guard not armed: {p.stderr.strip() or p.stdout.strip()}")
    return f"guard: armed now ({marker})"


def cmd_launch(a):
    project = Project(a.project)
    entry = project.entry(a.name)
    if entry.get("STATUS") != "open":
        raise Refused(f"lane {a.name} is not open (wt.py open first)")
    state = session_state(entry)
    if entry.get("SESSION") and state not in ("not running", "-"):
        raise Refused(f"lane {a.name} already has session {entry['SHORT']} ({state}): claude attach {entry['SHORT']}")
    wt = entry["WT"]
    sources = check_settings(wt)
    env_block = project.lane_env(entry)
    env_block.update(WT_LANE=str(entry["LANE"]), WT_TASK=entry["TASK"], WT_NAME=entry["NAME"])
    settings = json.dumps({"worktree": {"bgIsolation": "none"}, "env": env_block}, separators=(",", ":"))
    text = kickoff(project, entry)
    with open(os.path.join(project.lane_dir(a.name), "kickoff.md"), "w") as f:
        f.write(text)
    argv = build_argv(a.model, a.name, settings, sources, "/taking-over " + text)
    if a.dry_run:
        print(json.dumps(argv[:-1] + ["<kickoff.md>"], indent=1))
        print(f"kickoff: {os.path.join(project.lane_dir(a.name), 'kickoff.md')}")
        return 0
    p = subprocess.run(argv, cwd=wt, env=clean_env(), capture_output=True, text=True, timeout=120,
                       start_new_session=True, stdin=subprocess.DEVNULL)
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"backgrounded\s+·\s+([A-Za-z0-9._-]+)", out)
    if not m:
        raise Refused(f"claude --bg printed no session id (exit {p.returncode}): {out.strip()[:400]}")
    short = m.group(1)
    sid = ""
    for _ in range(30):
        for s in agents():
            if s.get("sessionId", "").startswith(short):
                sid = s["sessionId"]
        if sid:
            break
        time.sleep(1)
    if not sid:
        raise Refused(f"session {short} started but not listed by `claude agents --json --all` - arm it from inside: wt.py arm")
    with Lock(project):
        entry = project.entry(a.name)
        entry.update(SESSION=sid, SHORT=short, LAUNCHED=now(), MAX_HOURS=a.max_hours, MODEL=a.model or "")
        project.save(a.name, entry)
    print(f"launched: {a.name} session {sid} (short {short}) in {wt}")
    print(f"  {arm_guard(project, entry, sid, a.max_hours)}")
    print(f"  watch: claude attach {short}   |   claude logs {short}   |   stop: claude stop {short}")
    return 0


def cmd_arm(a):
    project = Project(a.project)
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID") or run(["pm", "session-id"]).stdout.strip()
    with Lock(project):
        entry = project.entry(a.name)
        if entry.get("STATUS") != "open":
            raise Refused(f"lane {a.name} is not open")
        if entry.get("SESSION") and entry["SESSION"] != sid:
            raise Refused(f"lane {a.name} belongs to session {entry['SESSION']}, this is {sid}")
        if not entry.get("SESSION"):
            entry.update(SESSION=sid, SHORT=sid[:8], LAUNCHED=entry.get("LAUNCHED") or now())
            project.save(a.name, entry)
    print(arm_guard(project, entry, sid, entry.get("MAX_HOURS") or 6))
    return 0


# ---------------------------------------------------------------- status / env

def lane_report(project, e):
    wt = e.get("WT", "")
    if e.get("STATUS") == "closed":
        return f"{e['NAME']:<22} {e.get('TASK',''):<10} closed {e.get('CLOSED','')}"
    parts = [f"{e['NAME']:<22} {e.get('TASK',''):<10} lane {e.get('LANE')} [{e.get('PORTS')}]"]
    if os.path.isdir(wt):
        head = git(wt, "rev-parse", "--short", "HEAD", check=False).stdout.strip()
        dirty = len([l for l in git(wt, "status", "--porcelain", check=False).stdout.splitlines() if l])
        ahead = git(wt, "rev-list", "--count", f"origin/{e['BASE']}..HEAD", check=False).stdout.strip() or "?"
        parts.append(f"  {e['BRANCH']}@{head}, {ahead} commit(s) over origin/{e['BASE']}, {dirty} dirty path(s)")
    else:
        parts.append(f"  WORKTREE MISSING: {wt}")
    listening = [f"{k}={v}" for k, v in parse_ports(e.get("PORTS")).items() if listening_pids(v)]
    parts.append(f"  listening: {', '.join(listening) or 'none'}")
    sid = e.get("SESSION", "")
    marker = os.path.expanduser(f"~/.claude/solo/{sid}.active") if sid else ""
    parts.append(f"  session: {e.get('SHORT') or '-'} ({session_state(e)}), guard "
                 f"{'armed' if marker and os.path.exists(marker) else 'off'}")
    return "\n".join(parts)


def cmd_status(a):
    slugs = [a.project] if a.project else sorted(
        d for d in os.listdir(PM_ROOT) if os.path.isdir(os.path.join(PM_ROOT, d, ".worktrees", "lanes")))
    for slug in slugs:
        project = Project(slug)
        entries = project.entries()
        print(f"# {slug}  (main checkout {project.main}, ports {port_line(project.main_ports) or '-'})")
        if not entries:
            print("  no lanes")
        for e in entries:
            print(lane_report(project, e))
    return 0


def cmd_env(a):
    project = Project(a.project)
    e = project.entry(a.name)
    if not e:
        raise Refused(f"no lane {a.name}")
    for k, v in project.lane_env(e).items():
        print(f"{k}={v}")
    print(f"WT_LANE={e['LANE']}")
    return 0


# ---------------------------------------------------------------- close

def ignored_leftovers(project, wt):
    """Ignored files `git worktree remove` would delete silently that are
    neither build output (DISPOSABLE) nor what open() put there itself."""
    keep = set(project.seed) | set(project.overlays)

    def disposable(rel):
        return any(fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(c, pat)
                   for pat in project.disposable for c in rel.split("/"))

    out = git(wt, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory").stdout
    left = []
    for rel in (r.rstrip("/") for r in out.splitlines() if r.strip()):
        if rel in keep or disposable(rel):
            continue
        full = os.path.join(wt, rel)
        if not os.path.isdir(full):
            left.append(rel)
            continue
        for root, dirs, files in os.walk(full):
            dirs[:] = [d for d in dirs if not disposable(os.path.relpath(os.path.join(root, d), wt))]
            for fn in files:
                r = os.path.relpath(os.path.join(root, fn), wt)
                if r not in keep and not disposable(r):
                    left.append(r)
    return left


def cmd_close(a):
    project = Project(a.project)
    e = project.entry(a.name)
    if e.get("STATUS") != "open":
        raise Refused(f"lane {a.name} is not open")
    wt = e["WT"]
    state = session_state(e)
    if state == "busy":
        raise Refused(f"session {e['SHORT']} is busy - let it finish or `claude stop {e['SHORT']}` yourself")
    notes = []
    if e.get("SESSION") and state not in ("not running", "-"):
        run([CLAUDE, "stop", e["SHORT"]], check=False, env=clean_env())
        notes.append(f"session {e['SHORT']} stopped (conversation kept: claude --resume {e['SESSION']})")
    if os.path.isdir(wt):
        dirty = git(wt, "status", "--porcelain").stdout.strip()
        if dirty:
            raise Refused(f"{wt} has uncommitted changes - commit or discard them first:\n{dirty}")
        left = ignored_leftovers(project, wt)
        if left and not a.discard_ignored:
            raise Refused("ignored files that are not build output would be deleted with the worktree "
                          f"(move what you need, or pass --discard-ignored): {left[:10]}")
        for port in parse_ports(e["PORTS"]).values():
            for pid in listening_pids(port):
                if inside(pid_cwd(pid), wt):
                    os.kill(pid, signal.SIGTERM)
                    notes.append(f"stopped pid {pid} on port {port} (cwd in the worktree)")
                else:
                    notes.append(f"port {port} held by pid {pid} OUTSIDE this worktree - left alone")
        git(project.main, "worktree", "remove", wt)
        notes.append(f"worktree removed: {wt} (branch {e['BRANCH']} kept)")
    else:
        git(project.main, "worktree", "prune")
        notes.append(f"worktree already gone; pruned")
    if a.delete_branch:
        git(project.main, "fetch", "origin", "--quiet", check=False)
        merged = git(project.main, "merge-base", "--is-ancestor", e["BRANCH"], f"origin/{e['BASE']}",
                     check=False).returncode == 0
        if merged:
            git(project.main, "branch", "-D", e["BRANCH"])
            notes.append(f"branch {e['BRANCH']} deleted (contained in origin/{e['BASE']})")
        else:
            notes.append(f"branch {e['BRANCH']} KEPT: not contained in origin/{e['BASE']} "
                         "(unmerged, or merged as a squash - check the MR, then delete by hand)")
    sid = e.get("SESSION", "")
    if sid and os.path.exists(os.path.expanduser(f"~/.claude/solo/{sid}.active")):
        p = run([os.path.join(SOLO_SCRIPTS, "shift-close.sh"), sid], check=False)
        notes.append("guard marker closed" if p.returncode == 0 else f"guard marker NOT closed: {p.stderr.strip()}")
    with Lock(project):
        e = project.entry(a.name)
        e.update(STATUS="closed", CLOSED=now())
        project.save(a.name, e)
    print(f"closed: {a.name}")
    for n in notes:
        print(f"  {n}")
    return 0


# ---------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(prog="wt.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("open"); o.add_argument("project"); o.add_argument("task")
    o.add_argument("--name"); o.add_argument("--branch"); o.add_argument("--base")
    o.add_argument("--no-prepare", action="store_true")
    l = sub.add_parser("launch"); l.add_argument("project"); l.add_argument("name")
    l.add_argument("--model", default=""); l.add_argument("--max-hours", type=int, default=6)
    l.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("arm"); r.add_argument("project"); r.add_argument("name")
    s = sub.add_parser("status"); s.add_argument("project", nargs="?")
    e = sub.add_parser("env"); e.add_argument("project"); e.add_argument("name")
    c = sub.add_parser("close"); c.add_argument("project"); c.add_argument("name")
    c.add_argument("--delete-branch", action="store_true")
    c.add_argument("--discard-ignored", action="store_true")
    a = ap.parse_args(argv)
    fn = {"open": cmd_open, "launch": cmd_launch, "arm": cmd_arm, "status": cmd_status,
          "env": cmd_env, "close": cmd_close}[a.cmd]
    try:
        return fn(a)
    except Refused as err:
        print(f"wt.py {a.cmd}: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
