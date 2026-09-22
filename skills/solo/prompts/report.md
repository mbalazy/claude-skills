# Closing the shift

## 1. Leave things in a known state

- Checkout: `git status` clean, on the base branch, `git worktree list` shows
  nothing you added. Every task branch exists locally (and on origin when
  `--push`).
- Runtime: stop nothing that was running when the shift began; stop what you
  started only if the config says it is throwaway. Either way the report
  names the state left behind.
- State file: `## Status: closed <ts>`, every task's `## Progress` line final.
- Tracker Log (or each task's, for an id list): `solo <shift-id>
  closed <ts>: <n> done, <m> parked, <k> untouched; report <path>`.
- **Every task gets its `task-end` line BEFORE the close.** `scripts/note.sh
  <state> task-end <id> <done|parked> <one line>` for each id that has a
  `task-start` - including the one the budget or the queue cut short.
  `shift-close.sh` refuses to close while any id is still open (it prints
  `open task: <id>` and keeps the marker); `--force` closes anyway and writes
  the missing lines itself as `parked shift-close --force`, which is the
  worse record of the two.
- The guard marker stays until the very end: `scripts/shift-close.sh <shift-id>` is the
  LAST command of the shift, after the report is written and printed. It
  appends the transcript's compaction count to `## Compactions noticed` on
  its way out, so that section is never empty - the retro reads it against
  the ones the shift itself noticed.

## 1b. Journal the shift's incidents

Walk the state file (`## Progress`, `## Decisions`, `## Compactions
noticed`) and write one `pm_journal_add` entry on the project's
`solo` journal per incident of these kinds - events, not metrics
(cost and time per task belong in report section 4, not here):

| kind | tag | example symptom |
|---|---|---|
| a step redone or skipped after a compaction, or a resume that landed in the wrong place | `compaction` | "after the summary the branch was created twice" |
| a task parked on the time budget | `budget` | "task X at 120 min still red on the gate" |
| a command that hung or timed out | `hang` | "sim-ui.sh source hung 120 s twice" |
| a reading first taken as evidence and later refuted | `false-pass` | "CONFIRMED on a screenshot before the negative control" |
| a decision that turned out wrong without a human to stop it | `bad-call` | "chose to skip the migration, the gate failed on it" |
| the shift ended early (window wall, crash, dirty tree) | `stall` | "session stalled at 02:10 on the usage limit" |

Fields: `symptom` (as it looked before the cause was known), `false_conclusion`
when there was one, `cause` (verified only), `cost_min` (rough), `tags` (reuse
the ones `pm_journal_list` returns), `session` = the shift id, `fix` EMPTY -
the fix is a later change to this skill, recorded by a later entry that
`resolves` this one. Rig incidents go to the rig journal (`sim-rig` /
`web-rig`) as `prompts/runtime.md` says, never here. No `solo` journal
declared for the project: one line in the report, nothing invented.

## 2. The report file

Write two files in `~/.claude/pm/<slug>/.shift/`:
`<YYYY-MM-DD>-<shift-id>-report.md` (sections 1-3 and the TL;DR) and
`<YYYY-MM-DD>-<shift-id>-details.md` (section 4). Print the report in the
chat, never the details. In Polish (the user's language). Fixed order; the
reader launched this hours ago and does not remember what the tasks were
about - they will read section 1 and the TL;DR, maybe section 2, and must be
able to act on those alone. A queue of six tasks produced a 2700-word report
nobody could read; **the report file stays under 600 words**, the details
file has no limit.

### 1. Co z taskami

Per task, in queue order, FOUR things and nothing else:

- **the heading** - the external ticket key (or the pm id when there is none)
  and the problem as the user experiences it, in plain words: which screen,
  what they do, what they see. From the Spec's `## Bug as the user sees it`
  when it exists; for a feature, what the user could not do before.
- `Stan:` **naprawione** / **częściowo** / **nie naprawione** (feature:
  **zrobione** / **częściowo** / **nie zrobione**), then one sentence of what
  now happens on that screen. "Częściowo" names what still misbehaves.
- `Sprawdzone:` ONE sentence: where and how, and whether it was the
  REPORTER'S OWN scenario (their device, data, steps) or a stand-in - and
  when a stand-in, what the human can do to close the gap. Runtime off or rig
  down: say so here in plain words ("na symulatorze nie sprawdzone, bo ...").
  No numbers, no paths, no quoted gate block - those are section 4's.
- `Przed PR-em:` what still stands between this branch and a PR, each with
  its reason, or "nic". Decisions for the human go here as the choice - and
  for a task that came in as a link, the criteria the shift derived itself
  ("kryteria wyprowadzone z ticketu, nie podane przez zgłaszającego: ...")
  so the user can strike one before the PR.

A task's paragraph stays under about 80 words. **Everything section 4 carries
is NOT repeated here**: shas, commits, gate numbers, the gate block, runtime
verdicts with their channel and evidence path, the reviewer's findings and
their fate, minutes. 24% of a shift's cost went on step 0 and the close - a
report that re-tells the details file is a second pass over the same material
for no reader.

A task the state file marks `REVIEW-MISSING` is never **naprawione** /
**zrobione** - **częściowo** at best, with the missing review named in
`Przed PR-em:`.

Banned in this section: sub, claim, channel/kanał, CONFIRMED, REFUTED,
UNVERIFIED, worker, agent, reviewer, gate, shift, session, compaction; enum
values or literals from the code; file paths and line numbers; test counts;
commit hashes. All of that lives in section 4. A line that needs the Spec to
be understood is a defect - rewrite it.

Untouched tasks (budget tripped, queue cut, a dependency that did not land)
get one line each: "nie ruszone, bo ...". For a stacked task `Przed PR-em:`
names the branch (or PR) it sits on and that it merges AFTER it - in plain
words ("scalić po X, PR jest na gałąź X, nie na development").

### 2. Decyzje podjęte za Ciebie

A table, one row per fork, one short sentence per cell, readable without the
session:

| Wybrane | Odrzucone | Dlaczego |
|---|---|---|

Parks (why a task was left at "częściowo") are rows too. Product and UX calls
the tasks left open belong here: the run takes them and the user reviews them
afterwards - they are not a reason to stop. "Brak" when none.

### 3. Sprzątanie i stan runtime

Every side effect on shared data or devices ("skasowane" / "zostawione,
skasuj jeśli zbędne"), then the runtime and checkout state left behind (which
sim/dev server, which port, which branch is checked out). Omit only when there
was nothing.

### 4. Szczegóły techniczne - osobny plik

In the details file, not the report; the report carries one line naming its
path. **This section is the ONLY place these fields appear** - section 1
names none of them. Per task: branch and head sha, commits (hash + one line),
gate numbers AND the verbatim gate block the state file holds (step 5 of
`prompts/task.md` pasted it there), runtime verdicts with the channel and
evidence path, the reviewer's findings and their fate, minutes spent, and for
a stacked task its parent branch.
Then the shift totals: tasks done / parked / untouched, wall clock,
compactions - the count `scripts/compactions.sh <shift-id>` prints from the
transcript, beside the ones the state file noticed (a shift noted 1 of 7) -,
the rig state per pass - and, when any task was
stacked, the merge order (parent first, one line: `A -> B -> C`), and the
`window:` and `budget:` lines of the state header as they were (the retro
reads the cost against them). This is the section the old acceptance report
consisted of; still wanted, in its own file.

**The details are a COPY, not new writing.** Every field above is already in
the state file (`## Progress` and the Log lines of that task) - assemble them
in ONE pass over it. Do not re-read the transcript, do not re-run anything, do
not reconstruct what happened from memory. The report stays under 600 words;
the details have no limit, because nothing in them is written twice.

### TL;DR

LAST, always, 2-4 full sentences that stand alone: what got done, what did
not and why, the single next action expected from the user (usually: open or
review these PRs, pick the ticket numbers).

## 3. Before sending

Read section 1 once as the returning user. Any line that needs the Spec, the
Log or the code to be understood goes back to be rewritten in the user's
words - not footnoted.
