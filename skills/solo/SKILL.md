---
name: solo
description: Works one or more tasks in ONE unattended Claude Code session - the user is away, day or night - instead of an executor batch plus an acceptance run. Input is a pm tracker, pm task ids, ticket keys, Linear / Jira / Slack / GitHub links or pasted text; anything that is not a pm task becomes one first, with criteria derived from the source when the reporter gave none. Per task, in order: cold start from pm, branch off the base, implement, gate, verify on the live runtime itself (simulator-verify / web-verify), one reviewer pass, brief + Log, next. Procedure and state live in files so auto-compaction loses nothing, a guard hook enforces the no-push/no-PR/no-done contract, and the shift ends with one report for a cold reader. Flags - --sim / --web / --no-runtime, --push, --pr, --max-tasks N, --max-hours H, resume. Use when the user says "/solo", "leć solo", "odpal solo", "solo z tymi taskami", "leć z listą", "dowieź to jak mnie nie będzie", "zrób to sam po kolei", or hands over work and leaves. With the user present use developing-features.
---

# Solo

One session, one worker, the tasks in order, nobody watching. This replaces
the chain `batch-prep -> pm run-epic -> pm finish / batch-finish-auto` with
the part of it that delivered: a session with its hands on the runtime.

Two facts shape everything below. **Auto-compaction WILL happen** during a
shift, and after it Claude Code re-injects skills capped at ~5k tokens each -
so this file stays small, the per-task procedure is re-read from disk at the
start of EVERY task, and the state of the shift lives in a file plus pm, never
in the conversation. **Nobody will unstick you** - a runtime that lies, a hung
command or a scope question must cost minutes, not the night.

The rules that matter are not left to memory. **Mechanics** (all in
`scripts/`, relative to this skill's directory):

| script | what it enforces |
|---|---|
| `shift-open.sh` / `shift-close.sh` | writes / removes `~/.claude/solo/<shift-id>.active`; while it exists the PreToolUse hook `guard.py` (matcher `Bash\|mcp__.*` in settings.json) BLOCKS `git push` without `--push`, any force/delete push, `gh pr create` without `--pr`, `gh pr/issue` writes, `git merge`/`pull`/`rebase` ON the base branch (on a task branch they pass), `branch -D`, `reset --hard`, `clean`, `stash drop`, pm status `done`/`archived` (MCP and `pm mv`), `pm_add_task`/`pm_delete_task`, and every MCP tool of an external system whose name starts with a write verb (Jira/Slack/Linear/GitHub/Gmail/Figma: add_, create_, update_, transition_, send_, post..., `conversations_add_message`); reads pass, local servers (playwright, chrome, codegraph, context7, crawl4ai) pass, an unknown name passes - in bypass mode too. Markers are PER SESSION (`~/.claude/solo/<session-id>.active`, matched against the `session_id` Claude Code hands the hook), so a run never blocks the user's other sessions. A marker older than `MAX_HOURS + 2h` is stale: calls pass with a warning. `guard.py --explain <tool> [command]` shows the decision |
| `note.sh <state> <text>` | appends one timestamped line to the state file's `## Log`; `note.sh <state> task-start <id>` stamps the clock |
| `tick.sh <state> [budget]` | prints minutes on the current task and on the shift, exit 1 when over budget - you have no clock, this is it. The budget comes from the marker (`shift-open.sh --budget`), default 120 |
| `launch-check.sh [repo]` | preflight, exit 1 = relaunch: the auto-compact window this session really runs with (`window.sh`: the `--autocompact` flag on the claude process, else the config dir's `autoCompactWindow`), bypass mode on the process, and the repo's shared `.claude/settings.json` `ask` rules - **an `ask` rule prompts in every mode, bypass included**, so such a repo needs `--setting-sources user,local` (project settings skipped) with the shared DENY list mirrored in `.claude/settings.local.json` (the script checks the mirror). The model cannot see its own launch flags; this can |

A blocked call is a fact to record (brief, state file), never something to
work around with another command.

## Consent and hard limits

Invoking this skill is the `taking-over` contract: act without asking, decide
within the task's scope and AC, keep everything local. Explicitly:

- No `git push`, no PR, no merge, no status `done` - unless `--push` / `--pr`
  say otherwise (below). `main`/`development` are never touched.
- No messages to people, no external systems written (Linear/Jira comments
  included). Reading them is fine.
- No `pm_add_task` for a finding, and no proposed-ticket list either: a
  finding outside the task's scope is DROPPED - not fixed, not filed, not
  suggested. The user has never acted on such a list, so producing one only
  costs them reading. The single exception is a finding that would lose data
  or take the shipped product down; that one gets ONE line in the report,
  named as such. The queue itself is different: intake creates the tasks the
  user handed over as links, before the guard is on.
- Nothing destructive: no branch deletes, no resets discarding work, no edits
  to pm data beyond the tasks being worked (brief, body, links, status, branch).
- No scope creep: nothing beyond the task's AC. A product decision the AC
  does not settle is taken, not parked: the simplest reversible reading,
  recorded as an ASSUMPTION with the excluded alternative and listed in
  `Przed PR-em:` for the user to overturn. Only a hard external blocker
  (credentials, a device, someone else's API) parks a task.
- Decisions: reversible over irreversible, simpler over cleverer. Record each
  decision the moment it is made (state file), never reconstruct at the end.
- Commit messages, branch names and any pushed text read as ordinary human
  work in the repo's language: no shift/session/agent/night wording, no pm ids
  unless the repo's convention carries ticket keys.

## Invocation

```
/solo <tracker-id | task-id | ticket-key | url ...> [--sim|--web|--no-runtime]
             [--push] [--pr] [--max-tasks N] [--max-hours H] [--base <branch>]
/solo resume            # continue the newest unfinished shift of this project
```

- **Queue**: a tracker id = its subs in `order` (todo first, then waiting
  tasks whose `waiting_for` is empty); explicit ids = that order; one id is
  a queue of one. Skip anything not `todo`/`doing` and say so in the report.
  **`depends_on` makes a stack**: a sub is placed after every id it names
  (ties by `order`), and it forks from the head of its dependency's branch
  instead of the base - the rule is in `prompts/task.md` step 2. A
  dependency that ends parked, red or untouched leaves its dependents
  untouched ("nie ruszone, bo czeka na X"); one already in the base counts
  as satisfied, and so does one from an earlier shift whose branch exists
  (local or origin - no push needed) with a green outcome in its brief; a
  `depends_on override: <id> counts as satisfied (user, <date>)` line in
  the sub's Spec counts regardless; a cycle or an id outside the queue that
  is on no branch and not in the base is reported and the sub skipped. A
  sub that already has its own branch from an earlier shift continues on
  it. No `depends_on` = independent tasks, every one from the base, as
  before.
  **An argument may also be a ticket key, a Linear / Jira / Slack / GitHub
  link, or pasted text** - `prompts/intake.md` turns each into a pm task
  first (criteria derived from the source when the reporter gave none,
  marked as derived, never a park), before the guard is armed.
- **Runtime**: default ON when `pm executor show <project>` declares a runtime
  skill; `--sim`/`--web` force the kind, `--no-runtime` skips the pass and
  every visual claim is reported UNVERIFIED with the reason.
- `--push`: push each task's branch after its review. `--pr` implies `--push`
  and opens a draft PR per task with the repo's PR template - for a stacked
  task the PR's base is the dependency's branch, so the PRs form a stack
  merged parent first (the report names the order). Without them the work
  stays local and the report says which branch holds what.
- `--max-tasks` (default: the whole queue), `--max-hours` (default 4): when
  either trips, finish the current task's step, write state, report. The
  real ceiling is the account's usage window, not the clock: a shift that
  exhausts it stalls silently until the window resets, and only a human can
  `resume` it - a smaller context (below) pushes that ceiling out.
- `--base`: the branch every task forks from (default: `executor.base_branch`
  from `pm executor show`, else the repo's default branch).

**Launch** (the user's launcher for unattended runs - usually a shell
abbreviation named in their CLAUDE.md):
`claude --dangerously-skip-permissions --autocompact 400k`, plus
`--setting-sources user,local` in a repo whose shared `.claude/settings.json`
has `ask` rules (`scripts/launch-check.sh` says which). Bypass, not
`auto`: the auto classifier falls back to prompts after three blocks in a
row, and at 02:00 nobody answers - the guard hook and the settings deny
rules are what hold the line instead. The smaller compaction window is per
launch (the interactive window stays as configured) and keeps every call
cheaper. **First shift on a project: `--no-runtime`, two tasks** - prove the
loop, the state file and the report hold before adding the runtime.

## Step 0: Open the shift (once)

0. `scripts/shift-close.sh --stale`: removes markers of dead runs under
   `~/.claude/solo/` (older than their `MAX_HOURS + 2h`). Markers are per
   session, so another session's live run is never touched and never
   touches this one.
1. `pm session-id` -> the shift id. `pm_context` with cwd -> the project.
   `scripts/launch-check.sh <repo>` -> its `window:` line goes into the
   state header. A window above the intended one (400k via the launcher) is a fact
   for the report, not a reason to stop. **Exit 1 IS a reason to stop**:
   print the script's relaunch line and end the turn - no shift is opened.
   A repo whose shared settings carry `ask` rules would prompt at the first
   `pnpm test` and stall until morning; ten seconds now beat that.
2. `pm executor show <project>`: base branch, runtime skill + scripts, rig
   skill, playbook, slot ids/ports. These identifiers come from pm, never from
   prose. `pm executor doctor` failing on the handoff block = runtime OFF for
   the shift, said in the report.
3. Preconditions in the MAIN checkout (no worktree slots in this mode): `git
   status --porcelain` empty (a dirty tree is not yours to stash: STOP and
   report), `git fetch origin`, base branch up to date. Note the HEAD sha.
4. Resolve the queue: pm ids via `pm_get_task` (a missing id is reported,
   never waited on); anything else via `prompts/intake.md`, which creates
   the tasks NOW - this is the one moment `pm_add_task` is legal. Write the
   state file from `templates/state.md` to
   `~/.claude/pm/<slug>/.shift/<YYYY-MM-DD>-<shift-id>.md`. Only then arm
   the guard: `scripts/shift-open.sh --project <slug> --shift <shift-id>
   --state <state-file> [--push] [--pr] [--max-hours H] --base <base>
   [--budget MIN]` (the guard uses `--base` to tell the base branch from a
   task branch). **Queue of one: `--budget $((H * 60 - 30))`** (210 with the
   default 4 hours) - the whole shift minus the close is that task's budget,
   decided HERE, once, and written into the state header as `budget:`. For
   any longer queue the default 120 stands.
5. Read the project's runtime skill IN FULL once now (its SKILL.md, plus the
   playbook `pm executor show` names) - this is the read that compaction
   later truncates, so `prompts/runtime.md` tells you when to re-read it.
6. `pm_journal_list <project>`: note whether a `solo` journal is
   declared (and the rig journal's name). Undeclared = the closing step
   cannot record incidents; say so in the report instead of inventing a name.
7. **Attach this session** to the tracker (or to each task, for an id
   list): `pm_update_task` with `sessions: ["<shift-id>"]` (append-only;
   it is what `pm board`'s resume and the cockpit read - a run nobody can
   find from the task is a run that did not happen) and, in the same call,
   `body_append` one Log line:
   `solo <shift-id> started <ts>, queue: <ids>, runtime: <sim|web|off>`.

## The loop

For each task in the queue:

1. **Read `prompts/task.md` again, in full.** Not from memory, not from the
   previous task - from disk. This is the cold-start rule that makes
   compaction harmless, and it costs one Read.
2. Follow it: cold start from pm -> branch -> plan -> build -> gate -> runtime
   (`prompts/runtime.md`) -> one reviewer -> record -> status -> push/PR when
   flagged -> state file.
3. **Per-task budget: 120 minutes** (or the marker's `BUDGET`, set at
   Step 0 for a queue of one) from `note.sh <state> task-start <id>`;
   `tick.sh <state>` at the top of every step says where you are. Over
   budget: commit what is green, write the brief honestly (`Stan:
   częściowo` / `nie naprawione`, why, next step), park the task, move on.
   A parked task is a result, a task that ate the night is not. **The
   budget is never extended from inside the loop** - not for a queue of
   one, not for "almost there": a run that reasons its way past a tick is
   the failure the tick exists to catch. The one place a budget is decided
   is `shift-open.sh --budget` at Step 0.
4. Update the state file (`## Progress` line for the task, `## Decisions`,
   `## Cleanup`), then continue with the next id.

**After a compaction** (you notice a summary instead of the conversation):
the first two actions are `cat` the state file and Read `prompts/task.md`.
Resume at the step the state file names. Never re-do a step it marks done;
verify it from artifacts instead (`git log`, the task's Log) if in doubt.

**Waiting is not work.** No Monitor, no sleeping watchers, no polling: every
task is fully in your hands, and a command that can hang (runtime, dev
server, package install) runs under `timeout` (`prompts/runtime.md`). A
continuous session also keeps the prompt cache warm, which is most of what
makes this mode cheaper than a batch.

## Step Z: Close the shift

Read `prompts/report.md` and follow it: leave the runtime and the checkout in
a known state, journal every incident of the shift (`solo` journal:
what went wrong without a human, with its cost), write the report file next
to the state file, append the closing lines to the tracker's Log, print the
same report in the chat, and LAST run `scripts/shift-close.sh <shift-id>` (the guard
stays armed until then, so a forgotten close blocks the user's own next
push - the report must say the shift is closed). The
report is written for someone who launched this hours ago and remembers
nothing - section 1 in plain words, TL;DR last.

## Resume

`/solo resume`: newest `.shift/*.md` of the project whose `## Status`
is not `closed` -> continue its loop from `## Progress`. The account window
wall (a session that stalls until the limit resets) is the expected reason to
resume; treat the state file as authoritative and the conversation as gone.
A resume runs under a NEW session id: run `scripts/launch-check.sh` again,
open a marker for THIS id (`shift-open.sh` with the same flags and
`--state` the existing file - `tick.sh` finds the marker by that path),
attach this id too (`pm_update_task sessions` on the tracker and the
current task), and `note.sh <state> resume: <new id> picked up the shift`.
The old session's marker is closed by `shift-close.sh <old-id>` at once if
that session is dead, else left for `--stale`.

## The morning after

`/solo-retro` (its own skill) reads the state file, the report, the
transcript and the journal and answers cost, time, where the compactions
fell and whether the procedure left its marks - that is where the
`--autocompact` window and this skill's prompts get tuned from.

## Files

| When | File |
|---|---|
| Step 0, an argument that is not a pm id | `prompts/intake.md` |
| start of EVERY task | `prompts/task.md` |
| the runtime pass of a task | `prompts/runtime.md` |
| closing the shift | `prompts/report.md` |
| Step 0 | `templates/state.md` |
| the whole shift | `scripts/` (guard, open/close, note, state, tick) |

## Out of scope

Launching batches, merging, closing tasks (`done` is the user's, on a merged
PR), creating tickets, touching the executor's run-state files, anything on
the VPS runner.

## Changelog

- 2026-09-21, a stack split across two shifts: a dependency from an earlier
  shift counted only as `pushed` + on origin - a state a shift without
  `--push` can never produce - so the second shift always reported "nie
  ruszone, bo czeka na X". Now a green outcome on an existing branch (local
  or origin) satisfies it, a `depends_on override:` line in the sub's Spec
  is the user's veto over the rule, and a task that already has its own
  branch continues on it instead of forking again (`prompts/task.md` step
  2; `solo-prep/scripts/check-queue.py` warns accordingly).
- 2026-09-21, after the retro of the executor-vs-solo runs (24 shifts, 62
  tasks, 70 journal entries): WP1 gate proof before the first gate + full gate
  never replaced by a filtered one; WP2 a missing review parks the task as
  REVIEW-MISSING; WP3 intake splits QA rounds and parks tasks that demand a
  merge/push/PR; WP4 `scripts/state.py` owns the state file's sections and
  `note.sh` refuses a quoted `task-start <id>`; WP5 solo-retro reads the state
  file (not the `-details.md` sidecar) and takes the wall clock from it;
  WP6 `shift-close.sh` refuses to close with an open task and records the
  compaction count; WP7 web-verify `--api-path` / `api_probe:` so a live page
  over a dead API is RIG DEAD, rig check before every observation round;
  WP8 report section 1 and the details file stop duplicating each other.
