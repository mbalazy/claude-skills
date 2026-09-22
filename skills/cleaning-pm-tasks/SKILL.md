---
name: cleaning-pm-tasks
description: Triages the pm task tracker for cleanup - scans every project (or one), gathers evidence per task (age, last session activity, whether the branch is merged, whether the PR is merged, the parent's status), and presents lettered categories with continuously numbered items - A = finished tasks to archive, B = provably closed in reality but still on an open status, C = junk to delete, D = probably dead with the reason for the doubt, E = tasks whose status lies (doing for a month with no activity) with the status to move them to, F = leave alone. The user picks whole letters or single numbers; only the picks are applied (archive/move via pm mv, delete only through the MCP delete tool). Use when the user says "/cleaning-pm-tasks", "posprzątaj taski", "wyczyść pm", "clean-up tasków", "co zarchiwizować", "śmieci w pm", "stare taski", "triage tasków", "zrób porządek na boardzie", or complains the board is full of stale tasks.
---

# Cleaning pm tasks

Scan, propose by category, apply only what the user picks. The judgment lives in the scanner's evidence; the user owns the decision.

## Core rules

- **The scanner decides categories, you decide nothing silently.** `scripts/scan.py` computes the evidence and the category per task. Your job is to run it, sanity-check the surprising lines, print the list, and apply the picks. Never archive, move or delete a task the user did not pick - per-task data edits need explicit confirmation, and the pick IS that confirmation.
- **Numbers are continuous across categories** (1..N, never restarting per letter). The user answers with letters (whole category), numbers, ranges (`600-612`), and exclusions (`bez 5`, `-5`). "A" = archive every finished task; "236-346" = the pm-cli slice of A.
- **Delete is never run by the script.** Category C items come back as exact ids; delete each one through the MCP `pm_delete_task` tool (exact full id, one per call). Everything else is `pm mv <project> <id> <status>`.
- **Archive, not done.** Categories A/B/D land on `archived` (system-level, preserves brief, hidden from the board). If the user wants a B item on `done` instead, apply with `--as done`.

## Workflow

### 1. Scan

Work in the scratchpad dir. Scope to one project when the user names one; otherwise all.

```bash
S=~/.claude/skills/cleaning-pm-tasks/scripts/scan.py
python3 $S --plan plan.json                        # all projects, ~30s (gh + git evidence)
python3 $S --project pm-cli --plan plan.json       # one project
python3 $S --no-gh --plan plan.json                # offline / gh flaky
```

Thresholds (days, all overridable): `--done-days 14` (A), `--todo-days 90`, `--waiting-days 60` (D - also every custom non-terminal status such as `applied`, `pushed`, `parking`), `--doing-days 30` (E). `--show-a` expands category A from per-project ranges to one line per task; `--show-f` lists what is being left alone.

Evidence the scanner gathers per task: days since `updated`, last activity of any attached session (jsonl mtime under every `~/.claude*/projects`), whether `branch` is an ancestor of the repo's base branch and when its last commit was, the PR state from `links.pr` via `gh` (through `direnv exec` when the repo has an `.envrc`), the parent's status, per-project status list (an unknown status is a proven error), duplicate titles within a project.

### 2. Sanity-check before printing

Read the D and E lines. The scanner is age-based there, so override with judgment where the title or brief says otherwise - a "someday backlog" todo is not dead, a `waiting` on a client answer may be real. Do NOT renumber: keep the script's list and add a short note on the line (`<- raczej zostaw, to backlog`). Anything with a live executor run (`pm runs`) is off the table even if listed.

### 3. Present

Paste the scanner output as-is (plain text, no AskUserQuestion - the user answers in prose). Then one line: how to answer.

```
Odpowiedz literami (cała kategoria), numerami, zakresami (600-612) i wykluczeniami (bez 5).
Np. "A B 552-560 bez 555" albo "C usuń, E przenieś".
```

Categories, fixed order, empty ones skipped:

| | Meaning | Action |
|---|---|---|
| **A** | terminal status (done/rejected/skipped) older than `--done-days` - clutter, no judgment needed | archive |
| **B** | open status but PROOF of closure: PR merged/closed, branch merged into base, parent finished, status not in the project's set | archive |
| **C** | junk: no id, empty (no body/brief/links), open twin of a finished task, exact duplicate | delete (MCP) |
| **D** | probably dead: open past the threshold, each line says why the doubt (never opened in a session, no brief, sub of a closed parent, PR still open) | archive |
| **E** | status lies: `doing` past `--doing-days` with no session and no commit in that window, or a standalone `merged` | move to the status on the line (todo/waiting/done) |
| **F** | recent, or a tracker with open children - counts only | none |

### 4. Apply the picks

```bash
python3 $S apply --plan plan.json --pick "A B 552-560 bez 555" --dry-run   # show the pm mv lines first
python3 $S apply --plan plan.json --pick "A B 552-560 bez 555"             # run them
python3 $S apply --plan plan.json --pick "466 467" --as done               # override target
```

The apply step prints `przeniesione: N, bledy: M` plus the C ids for MCP deletion. Delete those with `pm_delete_task` one by one, then re-run the scan once so the user sees the board after. If the user picks nothing, stop - a scan with no picks is a valid outcome.

### 5. Report

Counts per action (archived / moved / deleted), the failures verbatim, and the F count as what stays. Suggest `pm board` for a look, nothing else.

## Gotchas

- `pm mv` takes the PROJECT slug first (`pm mv <project> <id> <status>`); the plan carries it. `archived` is always legal, the E targets must exist in that project's `statuses:`.
- A task whose branch equals the base branch (`main`) is never "merged evidence" - the scanner skips it on purpose.
- The scanner is read-only against `~/.claude/pm`; it only ever calls `pm mv` in apply. `PM_DATA_DIR` is honoured for a sandboxed run.
- The remote VPS pm (`pm-vps`) is not scanned - its tasks live on the server. Run the skill there by hand if needed.
