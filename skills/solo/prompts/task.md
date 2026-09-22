# One task, start to finish

Read this file at the start of every task. Everything you need to know about
the task comes from pm and the repo now, not from what you remember of the
previous task or of the shift's beginning.

## 1. Cold start

1. `pm_get_task <id>`: brief, Spec (`## Description`, `## Context`,
   `## Acceptance Criteria`, and when batch-prep wrote them `## Bug as the
   user sees it`, `## Reporter's scenario`, `## Verification recipe`), Log,
   links. The live ticket (Linear/Jira link) beats every local copy - read it
   and its comments when a link exists. Criteria marked "derived by
   solo" are yours to deliver as written; the report says they were
   derived, the user strikes what they disagree with in the morning.
2. Decide the runtime need NOW, from the AC: a claim about what appears on
   screen or how a control reacts = runtime pass required; everything else =
   gate only. Write it in the state file line for this task.
3. `pm_move_task` -> `doing` (if not already), then `pm_update_task` with
   `sessions: ["<shift-id>"]` on THIS task too (the tracker got it at Step
   0; a sub the user opens from the board must lead to this session as
   well). Stamp the clock:
   `scripts/note.sh <state-file> task-start <id>` - the budget (120 min, or
   the marker's `BUDGET` for a queue of one) counts from here, and
   `scripts/tick.sh <state-file>` at the top of steps 4, 5, 6 and 7 tells
   you where you stand (exit 1 = over budget: go to 9, no exceptions and no
   re-reading of the budget - it was decided at Step 0).
4. Scope check. Something outside the repo that the task does not provide
   (credentials, a device, another team's API) parks it now (step 9, `Stan:
   nie naprawione`, the missing thing named). A PRODUCT decision the AC does
   not settle does NOT park: take the simplest reversible reading (the one
   the existing code makes cheapest to change), record it as `ASSUMPTION:
   default = X, EXCLUDED: Y because ...` in the Log and in `Przed PR-em:`,
   and continue - the same rule `prompts/intake.md` applies when it derives
   criteria. Ten minutes of certainty beat an hour of guessing; a night lost
   to a question nobody can answer is worse than either.

**Two rules about the tools, for the whole task:**

- **The state file is written ONLY by `scripts/state.py` (the sections) and
  `scripts/note.sh` (the Log).** No `sed -i`, no `python3 -c`, no Edit, no
  heredoc over it. A regex aimed at one line once overwrote the whole Queue
  section (journal 20260910-f33c); `state.py <file> sections` after an append
  shows where the line actually landed, and `state.py` exits 1 - writing
  nothing - when the section or the task id is not there.
- **This session's Bash tool is zsh, not your fish shell.** `set X`, `and`,
  `or`, `string ...` fail here. Write POSIX: `VAR=value`, `&&`, `||`, `$(...)`.

## 2. Branch

**The parent branch is decided by `depends_on`** (from `pm_get_task`), never
by what you worked on last:

- **Empty `depends_on`**: from the base, fresh - `git fetch origin`, then
  `git switch -c <branch> --no-track origin/<base>` (`--no-track`: without it
  the fork's upstream is the BASE and a bare `git push` would aim at it).
  Never `git switch <base> && git pull` - the guard blocks pull/merge/rebase ON the base branch (the local
  base is the user's; origin/<base> is the truth you fork from). Independent
  tasks never share a branch: a shared branch makes the morning PRs
  impossible to review separately.
- **`depends_on` names tasks**: every one of them must be satisfied, else
  this task is not started (below). Satisfied = ANY of:
  - its `## Progress` line in the state file says `done` with a green gate
    in THIS shift;
  - its status is `done`/`merged` and its branch is in the base (`git
    merge-base --is-ancestor origin/<dep-branch> origin/<base>`);
  - a dependency from an EARLIER shift: its branch (the task's `branch`
    field) exists - locally or on origin, either is a foundation - with
    commits beyond `origin/<base>`, and its last recorded outcome was
    green: the brief's `Stan:` reads `naprawione` / `zrobione`, or its
    Log's last `solo <shift-id>` block records a green gate. A push is NOT
    required: a shift without `--push` never pushes and never reaches
    `pushed`, so demanding it blocked every stack split across two shifts;
  - THIS task's Spec carries an override line, which wins over all of the
    above: `depends_on override: <dep-id> counts as satisfied (user,
    YYYY-MM-DD)`, optionally ` - <reason>`. The user's decision is the
    proof; fork from the dependency's branch wherever it lives.
  A dependency whose last outcome was parked or red (brief `Stan:
  częściowo` / `nie naprawione` / `nie zrobione`, or a `parked` task-end in
  its Log) is NOT satisfied without the override line.
  The parent is the dependency's branch (`pm_get_task` -> `branch`):
  `git switch <dep-branch>` (or `origin/<dep-branch>` when only there),
  then `git switch -c <branch>`; with several dependencies, fork from the
  first one in queue order and `git merge` the others' branches in. A
  dependency already in the base is satisfied and contributes nothing - the
  base carries it. Record `parent: <dep-branch>` in the task's Log and in
  the state file's `## Progress` line.
- **This task already has a branch from an earlier shift** (its `branch`
  field names a branch that exists with commits beyond its parent): continue
  on it - `git switch <branch>`, never fork again, never rebuild what its
  brief says is done; the dependency rule above still decides whether it
  starts at all. Record `parent: <dep-branch> (continued from <sha>)`.
- **A dependency parked, red, untouched or unresolvable** (a cycle, an id
  that is neither in the queue nor in the base nor on any branch, local or
  origin): do not move the task to `doing`, do not branch. State file `## Progress`: `<id> ·
  untouched: waits for <dep-id> (<parked|red|untouched|unknown>)`, and the
  report says "nie ruszone, bo czeka na X". Never work around it by forking
  from the base - the code would be built against a foundation that is not
  there.

Name: the task's `branch` field when set, else the repo's convention
(`fix/<slug>`, `feat/<ticket-key>-<slug>`). Record the branch on the task
(`pm_update_task branch`).

**Before the gate and the runtime pass, bring the base in**: `git fetch
origin && git merge origin/<base>` on the task branch (the guard allows
merge/pull/rebase on a task branch; it blocks them only ON the base branch).
Verifying code that does not carry the current base is verifying something
that will never ship. A conflict you can settle inside the task's files is
settled; anything wider parks the task with the conflict named. On a stacked
branch the base usually arrived through the parent (it merged the base
before its own gate); merge it again only when `git merge-base --is-ancestor
origin/<base> HEAD` says it is missing, and then say so in the Log - the
reviewer's diff (step 7) will carry those base commits too.

## 3. Plan, briefly

Read the code the task touches before writing any. Reuse before creating.
Write 2-6 checkpoint lines into the state file (what, which files, how it is
verified). A checkpoint is one commit. No spec document, no design doc - the
Spec in pm is the spec.

## 4. Build

Per checkpoint: implement against the repo's real patterns (its CLAUDE.md /
AGENTS.md / architecture doc, and the nearest existing example), add the test
the repo's convention requires, run the project's validation command, fix at
the source (never disable a rule, never `@ts-ignore`, never `--no-verify`),
then commit with an explicit pathspec after `git diff --cached --stat` shows
exactly this checkpoint's files.

Throwaway instrumentation (a log line, a hardcoded prop, an overlay) comes out
before the commit; `git status` clean is part of "done".

A red the validation reports in files you did not touch: confirm on the base
branch that it is pre-existing, say so in one line in the task Log, do not fix
it here and do not propose a ticket for it.

## 5. Gate

The project's full verification command (`executor.verify` from `pm executor
show`, else the repo's `make check` / `npm run validate` equivalent), on the
whole branch, once more after the last commit. Record the actual numbers
(tests, files, time) in the state file, and paste the gate command with the
last lines of its output VERBATIM under them - the report quotes that block,
never a sentence about it. Red gate = not done; fix or park.

**Gate proof - once per project per shift, before the first gate.** A green
gate proves nothing until it has been seen red. Break one file the change
covers on purpose: `expect(1).toBe(2)` in an existing test of a package this
task touches, or a type error in a file you edited. Run the FULL gate command.
Expect red. If it comes back GREEN the gate does not reach that package - a
turbo filter matching zero packages, a warm turbo cache, an empty `dist`, a
lint ratchet, or a build still running in the background and read as finished.
Fix the command or the filter, or write `GATE BLIND: <package>` in the Log,
BEFORE you call anything verified. Then undo the mutation (`git checkout --
<file>`) and confirm `git status` is clean. One line in the state file:
`gate-proof <exit code under the mutation> <command>`. Which packages the
gate must touch is the Spec's `## Verification recipe`; that list is what the
proof is run against.

**The fast gate never replaces the full one.** A single-package filter in
step 4 belongs to the build loop; step 5 runs the project's full command on
the whole branch before the reviewer. On vega-247 the lint error in
`packages/ui` showed up only on the full run.

## 6. Runtime pass (when step 1 said so)

Read `prompts/runtime.md` and do exactly that. Outcome per visual claim:
CONFIRMED / REFUTED / UNVERIFIED with the evidence path or the reason. A
REFUTED claim reopens step 4 for that point, within the budget.

## 7. One reviewer, no rounds

Spawn ONE subagent (general-purpose, no Bash needed) with: the task's AC, the
full `git diff <parent>...HEAD` (`<parent>` = the base, or the dependency's
branch for a stacked task - the dependency's own changes are its own
review's business), the list of tests added, and the instruction
"adversarial review: correctness defects and AC gaps only, each with
file:line and a failure scenario; no style, no refactoring proposals; an empty
list is a valid answer". Run it synchronously.

Then triage yourself: fix only findings that are real defects INSIDE the
task's scope (commit separately: one commit per finding, message names the
defect, not the review). Findings outside the task's scope are DROPPED - one
line in the task Log at most, never a proposed ticket and never a fix.
Findings you disagree with are recorded in the task Log with one line of why.
**No second review round** - the morning PR review is the second pair of
eyes, and a reviewer almost never returns an empty list, so a confirming
round buys nothing.

**The reviewer is a condition of done, exactly as the gate is.**

- **Synchronously, never in the background.** If the Agent tool answers
  "Async agent launched" (or anything else that is not the review), that is
  not a review: wait for the result - the TaskOutput / the completion
  notification - before the next step. Do not start step 8 meanwhile.
- **One retry, same prompt.** A report cut off (`[result truncated`) or an
  API failure (529 Overloaded, a timeout) buys ONE more attempt with the
  same prompt. Not two, not a reworded one.
- **After the second failure the task is NOT done.** `scripts/note.sh
  <state> task-end <id> parked REVIEW-MISSING <reason>`, the brief's
  `Przed PR-em:` carries `recenzja nie odbyła się (<reason>)`, and section 1
  of the report says it in plain words. A task nobody reviewed ships no more
  than a task whose gate was red.

## 8. Record

- **Brief** (overwrite): the four plain-words lines first, exactly as the
  report will carry them - `Bug:` / `Stan:` / `Sprawdzone:` / `Przed PR-em:`
  (format in `prompts/report.md`) - then at most two sentences of technical
  end state (branch, head sha, gate numbers).
- **Log** (`body_append`): a dated block `solo <shift-id>` with the
  checkpoints and their commits, the gate numbers, the runtime verdicts with
  evidence paths, the reviewer's findings and what was done with each,
  decisions and rejected alternatives.
- **Links**: `branch` already set; `pr` when `--pr` opened one.
- **State file**: `scripts/state.py <file> append <Section> <text>` for the
  sections, `scripts/note.sh <file> <text>` for the Log - nothing else writes
  to that file (step 1), and `task-start` / `task-end` are separate arguments,
  never one quoted string.

## 9. Status and delivery

- Done and green: `--push` -> `git push -u origin <branch>`; `--pr` -> a
  draft PR with the repo's template, title in the repo's convention, body
  from the brief's four lines rewritten in the repo's language, no shift
  wording. A stacked task's PR targets its parent branch (`gh pr create
  --base <dep-branch>`; the dependency's PR exists because it was pushed
  and opened in its own step 9) and its body's first line names the PR it
  is stacked on - a PR against the base would show the dependency's diff
  as this task's. Then `pm_move_task` -> `pushed` when the project's statuses have
  it and the branch is on origin; otherwise the task stays `doing`. Without
  the flags the guard hook blocks push and PR - that is the contract, not an
  obstacle: record "branch ready locally" and move on.
- Parked (budget, scope, red gate, rig down with a visual AC): commit what is
  green, brief says `Stan: częściowo`/`nie naprawione` with the reason and
  the exact next step; status stays `doing`; nothing pushed unless `--push`
  and the branch is at least green.
- Never `done`, never `waiting` (the user decides who is waited on).

## 10. Leave the checkout ready for the next task

`git status` clean, no stray worktrees, no leftover test data you created
outside the repo unless the state file lists it under `## Cleanup`. Update the
state file: the task's `## Progress` line (`<id> · <status> · <branch>@<sha>
· from <base|dep-branch> · <minutes> · runtime <verdict>`), decisions,
cleanup, and
`scripts/note.sh <state-file> task-end <id> <done|parked> <one line>`.
Then the next id.
