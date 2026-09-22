#!/usr/bin/env python3
"""Numbers for a solo retro - from the artifacts a shift leaves behind.

usage: retro.py [<shift-id> | latest] [--project <slug>] [--state <file>]
                [--transcript <file>] [--json]

Finds the state file (~/.claude/pm/<slug>/.shift/<date>-<shift-id>.md), the
report next to it, the session transcript (<shift-id>.jsonl under
<config dir>/projects - CLAUDE_CONFIG_DIR, then every ~/.claude* dir) and the project's
solo journal, then prints:

  - per task: minutes (from note.sh task-start / task-end stamps), API calls,
    tokens, estimated cost, compactions that fell INSIDE the task
  - the shift: calls, tokens, cost, wall clock (from the state file's open and
    close stamps; the transcript only as a marked fallback - a resumed session
    makes it lie), compactions with their position relative to the tasks,
    guard blocks, over-budget ticks, journal entries
  - a "procedure trace": which steps left a mark (task-start/task-end lines,
    reviewer spawns, brief updates, journal writes, shift-close)

Cost uses the rates the CLI's own cost_usd matches (per 1M tokens): input 5,
cache write 6.25, cache read 0.5, output 25. Tokens are the metric that
matters on a subscription; dollars are the yardstick.
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

RATES = dict(inp=5.0, cw=6.25, cr=0.5, out=25.0)
HOME = os.path.expanduser("~")
PM_ROOT = os.path.join(HOME, ".claude", "pm")


# Files a shift writes NEXT TO its state file. None of them carries the Log,
# so picking one up costs every task: `<date>-<shift>-details.md` was newer
# than `<date>-<shift>.md` and matched `shift_id in basename`, so the whole
# shift landed under "(outside tasks)" with 0 tasks (pm-cli add0bd87).
SIDECARS = ("-report.md", "-details.md", "-retro.md")


def find_state(shift_id, project):
    pat = os.path.join(PM_ROOT, project or "*", ".shift", "*.md")
    files = [f for f in glob.glob(pat) if not f.endswith(SIDECARS)]
    if shift_id and shift_id != "latest":
        # the state file is `<date>-<shift-id>.md` - an exact tail match wins;
        # a loose substring match is the fallback for a shortened id only.
        exact = [f for f in files if f.endswith(f"-{shift_id}.md")]
        files = exact or [f for f in files if shift_id in os.path.basename(f)]
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def find_transcript(shift_id):
    roots = []
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        roots.append(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects"))
    # every Claude config dir next to ~/.claude: a second account, a worker dir
    roots += sorted(glob.glob(os.path.join(HOME, ".claude*", "projects")))
    for root in roots:
        hits = glob.glob(os.path.join(root, "*", f"{shift_id}*.jsonl"))
        if hits:
            return max(hits, key=os.path.getmtime)
    return None


def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


# A stamp as the state file writes it: ISO with or without an offset
# (2026-09-11T00:52+02:00, ...T09:46Z, ...T09:00+0200) or the Log's
# "2026-09-11 00:48". Bare local stamps are read in the machine's timezone,
# the same way read_state reads the task-end lines.
STAMP = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?")


def parse_stamp(text):
    m = STAMP.search(text or "")
    if not m:
        return None
    raw = m.group(0).replace(" ", "T").replace("Z", "+00:00")
    if re.search(r"[+-]\d{4}$", raw):  # +0200 -> +02:00
        raw = raw[:-2] + ":" + raw[-2:]
    try:
        return datetime.fromisoformat(raw).timestamp()
    except Exception:
        return None


TIME_ONLY = re.compile(r"\b(\d{2}:\d{2})\b")


def wall_from_state(state):
    """(minutes, source) from the state file itself, else (None, None).

    The transcript's first and last message are NOT the shift: a session
    resumed the next morning reported 700 minutes for a shift that ran
    21:45-00:52 (vega d2847400). The state file knows when the
    shift opened and when it closed; the transcript is only the fallback.

    opened  = the Log line "shift open(ed)", else the parenthetical on the
              Status line ("closed <ts> (opened <ts>)" / "(otwarta <ts>)"),
              whose stamp may be a bare time - then it takes the close date.
    closed  = the "## Status: closed <ts>" stamp, else the Log line
              "shift closed" / "shift close" / "shift-end".
    """
    status = state["status"] or ""
    open_ts = close_ts = None

    if status.lower().startswith("closed"):
        close_ts = parse_stamp(status)
    if close_ts is None:
        for stamp, rest in reversed(state["log"]):
            low = rest.lower()
            if low.startswith("shift clos") or low.startswith("shift-end"):
                close_ts = parse_stamp(stamp)
                break

    for stamp, rest in state["log"]:
        if rest.lower().startswith("shift open"):
            open_ts = parse_stamp(stamp)
            break
    if open_ts is None:
        m = re.search(r"\((?:otwarta|opened|open)\s+([^)]*)\)", status, re.I)
        if m:
            open_ts = parse_stamp(m.group(1))
            if open_ts is None and close_ts:  # "(opened 09:32 ...)" - no date
                hm = TIME_ONLY.search(m.group(1))
                day = datetime.fromtimestamp(close_ts).strftime("%Y-%m-%d")
                if hm:
                    open_ts = parse_stamp(f"{day} {hm.group(1)}")

    if open_ts and close_ts and close_ts > open_ts:
        return round((close_ts - open_ts) / 60), "state file"
    return None, None


def read_state(path):
    text = open(path).read()
    tasks = []  # ordered list of dicts: id, start, end, outcome
    log_lines = []
    for line in text.splitlines():
        m = re.match(r"^- (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) (.*)$", line)
        if not m:
            continue
        stamp, rest = m.groups()
        log_lines.append((stamp, rest))
        ms = re.match(r"task-start (\S+) epoch=(\d+)", rest)
        if ms:
            tasks.append({"id": ms.group(1), "start": int(ms.group(2)), "end": None, "outcome": None, "detail": ""})
            continue
        me = re.match(r"task-end (\S+)\s*(\S*)\s*(.*)", rest)
        if me:
            epoch = datetime.strptime(stamp, "%Y-%m-%d %H:%M").timestamp()
            for t in reversed(tasks):
                if t["id"] == me.group(1) and t["end"] is None:
                    t["end"], t["outcome"], t["detail"] = epoch, me.group(2), me.group(3)
                    break
    status = re.search(r"^## Status: (.*)$", text, re.M)
    header = {}
    for key in ("project", "runtime", "flags", "window", "budget", "rig", "base"):
        mm = re.search(rf"^{key}: (.*)$", text, re.M)
        if mm:
            header[key] = mm.group(1).strip()
    return {"tasks": tasks, "log": log_lines, "status": status.group(1) if status else "?", "header": header, "text": text}


def read_transcript(path, tasks):
    calls = []  # (ts, cr, cw, inp, out)
    compactions = []
    guard_blocks = 0
    reviewer_spawns = 0
    brief_updates = 0
    journal_writes = 0
    over_budget = 0
    shift_close = 0
    tools = {}
    first = last = None
    with open(path) as f:
        for line in f:
            if "solo guard" in line and "BLOCKED" in line:
                guard_blocks += 1
            if "OVER BUDGET" in line:
                over_budget += 1
            try:
                d = json.loads(line)
            except Exception:
                continue
            ts = parse_ts(d.get("timestamp", "") or "")
            t = d.get("type")
            if t == "system" and d.get("subtype") == "compact_boundary" and ts:
                compactions.append(ts)
            if t not in ("user", "assistant") or not ts:
                continue
            first = first or ts
            last = ts
            if t != "assistant":
                continue
            m = d.get("message") or {}
            u = m.get("usage") or {}
            if u:
                calls.append((ts, u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0),
                              u.get("input_tokens", 0), u.get("output_tokens", 0)))
            for b in m.get("content", []) if isinstance(m.get("content"), list) else []:
                if b.get("type") != "tool_use":
                    continue
                name = b.get("name", "")
                tools[name] = tools.get(name, 0) + 1
                inp = b.get("input") or {}
                if name == "Agent":
                    reviewer_spawns += 1
                if name.endswith("pm_update_task") and inp.get("brief"):
                    brief_updates += 1
                if name.endswith("pm_journal_add"):
                    journal_writes += 1
                if name == "Bash" and "shift-close.sh" in str(inp.get("command", "")):
                    shift_close += 1
    return {"calls": calls, "compactions": compactions, "guard_blocks": guard_blocks, "reviewer_spawns": reviewer_spawns,
            "brief_updates": brief_updates, "journal_writes": journal_writes, "over_budget": over_budget,
            "shift_close": shift_close, "tools": tools, "first": first, "last": last}


def cost_of(cr, cw, inp, out):
    return (inp * RATES["inp"] + cw * RATES["cw"] + cr * RATES["cr"] + out * RATES["out"]) / 1e6


def window_of(ts, tasks):
    for i, t in enumerate(tasks):
        end = t["end"] or (tasks[i + 1]["start"] if i + 1 < len(tasks) else float("inf"))
        if t["start"] <= ts < end:
            return t
    return None


def read_journal(project, shift_id, first, last):
    path = os.path.join(PM_ROOT, project, ".journal", "solo.jsonl")
    if not os.path.exists(path):
        return None
    rows = []
    for line in open(path):
        try:
            d = json.loads(line)
        except Exception:
            continue
        ts = parse_ts(d.get("ts", "") or "")
        if d.get("session") == shift_id or (ts and first and last and first - 3600 <= ts <= last + 6 * 3600):
            rows.append(d)
    return rows


def fmt_min(sec):
    return f"{int(sec // 60)} min" if sec is not None else "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("shift", nargs="?", default="latest")
    ap.add_argument("--project")
    ap.add_argument("--state")
    ap.add_argument("--transcript")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    state_path = a.state or find_state(a.shift, a.project)
    if not state_path:
        print("no state file found (looked under ~/.claude/pm/*/.shift/)", file=sys.stderr)
        return 1
    shift_id = a.shift if a.shift != "latest" else re.sub(r"^\d{4}-\d{2}-\d{2}-", "", os.path.basename(state_path)[:-3])
    project = a.project or os.path.basename(os.path.dirname(os.path.dirname(state_path)))
    state = read_state(state_path)
    tasks = state["tasks"]
    transcript = a.transcript or find_transcript(shift_id)
    tr = read_transcript(transcript, tasks) if transcript else None
    report = state_path[:-3] + "-report.md"

    out = {"shift": shift_id, "project": project, "state_file": state_path, "report": report if os.path.exists(report) else None,
           "transcript": transcript, "status": state["status"], "header": state["header"], "tasks": [], "shift_totals": {},
           "compactions": [], "procedure": {}, "journal": None}

    # per task
    per = {}
    if tr:
        for ts, cr, cw, inp, o in tr["calls"]:
            t = window_of(ts, tasks)
            key = t["id"] if t else "(outside tasks)"
            p = per.setdefault(key, [0, 0, 0, 0, 0])
            p[0] += 1; p[1] += cr; p[2] += cw; p[3] += inp; p[4] += o
    for t in tasks:
        p = per.get(t["id"], [0, 0, 0, 0, 0])
        dur = (t["end"] - t["start"]) if t["end"] else ((tr["last"] - t["start"]) if tr and tr["last"] else None)
        inside = [c for c in tr["compactions"] if window_of(c, tasks) is t] if tr else []
        out["tasks"].append({"id": t["id"], "minutes": round(dur / 60) if dur else None, "outcome": t["outcome"] or "(no task-end line)",
                             "detail": t["detail"], "calls": p[0], "cache_read": p[1], "cache_write": p[2], "output": p[4],
                             "cost_usd": round(cost_of(p[1], p[2], p[3], p[4]), 2),
                             "compactions_inside": [round((c - t["start"]) / 60) for c in inside]})
    if "(outside tasks)" in per:
        p = per["(outside tasks)"]
        out["tasks"].append({"id": "(outside tasks: step 0 / close)", "minutes": None, "outcome": "", "detail": "", "calls": p[0],
                             "cache_read": p[1], "cache_write": p[2], "output": p[4], "cost_usd": round(cost_of(p[1], p[2], p[3], p[4]), 2),
                             "compactions_inside": []})
    if tr:
        cr = sum(c[1] for c in tr["calls"]); cw = sum(c[2] for c in tr["calls"]); inp = sum(c[3] for c in tr["calls"]); o = sum(c[4] for c in tr["calls"])
        wall, wall_source = wall_from_state(state)
        if wall is None and tr["first"] and tr["last"]:
            wall, wall_source = round((tr["last"] - tr["first"]) / 60), "transcript (fallback: no open/close stamp in the state file)"
        out["shift_totals"] = {"calls": len(tr["calls"]), "cache_read": cr, "cache_write": cw, "output": o, "cost_usd": round(cost_of(cr, cw, inp, o), 2),
                               "wall_minutes": wall, "wall_source": wall_source,
                               "avg_context_k": round(sum(c[1] + c[2] + c[3] for c in tr["calls"]) / max(1, len(tr["calls"])) / 1000)}
        for c in tr["compactions"]:
            t = window_of(c, tasks)
            out["compactions"].append({"at": datetime.fromtimestamp(c).strftime("%H:%M"),
                                       "where": f"inside {t['id']} at +{round((c - t['start']) / 60)} min" if t else "between tasks / outside"})
        out["procedure"] = {"tasks_started": len(tasks), "tasks_with_end_line": sum(1 for t in tasks if t["end"]),
                            "reviewer_spawns": tr["reviewer_spawns"], "brief_updates": tr["brief_updates"], "journal_writes": tr["journal_writes"],
                            "guard_blocks": tr["guard_blocks"], "over_budget_ticks": tr["over_budget"], "shift_close_called": tr["shift_close"] > 0,
                            "state_status": state["status"], "top_tools": sorted(tr["tools"].items(), key=lambda x: -x[1])[:8]}
        out["journal"] = read_journal(project, shift_id, tr["first"], tr["last"])

    if a.json:
        print(json.dumps(out, indent=2, ensure_ascii=False, default=str))
        return 0

    print(f"# solo retro: {shift_id} ({project})")
    print(f"state: {state_path}\nreport: {out['report'] or 'MISSING'}\ntranscript: {transcript or 'NOT FOUND'}\nstatus: {state['status']}")
    for k, v in state["header"].items():
        print(f"{k}: {v}")
    print("\n## Per task")
    print("| task | min | outcome | calls | cache read | cache write | output | ~$ | compactions inside (min into task) |")
    print("|---|---|---|---|---|---|---|---|---|")
    for t in out["tasks"]:
        print(f"| {t['id']} | {t['minutes'] if t['minutes'] is not None else '?'} | {t['outcome']} {t['detail'][:40]} | {t['calls']} | "
              f"{t['cache_read'] / 1e6:.1f}M | {t['cache_write'] / 1e3:.0f}k | {t['output'] / 1e3:.0f}k | {t['cost_usd']} | "
              f"{', '.join(map(str, t['compactions_inside'])) or '-'} |")
    if out["shift_totals"]:
        s = out["shift_totals"]
        print(f"\n## Shift\ncalls {s['calls']} · wall {s['wall_minutes']} min ({s['wall_source']}) · avg context {s['avg_context_k']}k · "
              f"cache read {s['cache_read'] / 1e6:.1f}M · cache write {s['cache_write'] / 1e6:.2f}M · output {s['output'] / 1e3:.0f}k · ~${s['cost_usd']}")
        print("\n## Compactions")
        if out["compactions"]:
            for c in out["compactions"]:
                print(f"- {c['at']}: {c['where']}")
        else:
            print("- none")
        p = out["procedure"]
        print("\n## Procedure trace")
        print(f"- tasks started {p['tasks_started']}, with a task-end line {p['tasks_with_end_line']}")
        print(f"- reviewer spawns (Agent) {p['reviewer_spawns']} · brief updates {p['brief_updates']} · journal writes {p['journal_writes']}")
        print(f"- guard blocks {p['guard_blocks']} · over-budget ticks {p['over_budget_ticks']} · shift-close called: {p['shift_close_called']} · state status: {p['state_status']}")
        print(f"- top tools: {', '.join(f'{n} {c}' for n, c in p['top_tools'])}")
    print("\n## Journal (solo)")
    if out["journal"] is None:
        print("- no journal file (undeclared or never written)")
    elif not out["journal"]:
        print("- no entries for this shift")
    else:
        for e in out["journal"]:
            print(f"- {e.get('ts', '')[:16]} [{', '.join(e.get('tags') or [])}] {e.get('symptom', '')[:120]} · cost {e.get('cost_min', '?')} min · fix: {'OPEN' if not e.get('fix') else e.get('fix')[:60]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
