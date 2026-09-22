---
name: batch-finish
description: Finishes ONE task after an executor batch run (pm run-epic in independent mode) - the acceptance phase. Given no id it DISCOVERS the run itself, local runs and the remote VPS runner alike, so no parent/sub id has to be remembered. Empirically verifies every ASSUMPTION the worker recorded (runtime logs, network dump, dev API call, backend/contract source - evidence, never reasoning), fixes refuted ones FIRST, then works the TODO handoff, verifies on the project's runtime, and preps the per-task PR. Use when the user returns to a task the executor ran, says "/batch-finish <task-id>", "domknij taska", "dopnij po robocie", "odbiór taska", "zweryfikuj założenia robota", "odbierz taska z VPS-a", or "odbiór tasków z serwera".
---

# Batch Finish

Closes out one task after a batch executor run. The worker delivered 70-100%
best-effort and left a handoff: `ASSUMPTION:` lines (guesses it made, each with
a `verify:` recipe), `TODO:` lines (work it couldn't do headless) and - on a sub
that ran the executor's `runtime` phase (`runtime: on`, pm-cli-122) -
`OBSERVED:` lines (what the worker SAW on the slot's simulator, each with a
positive and a negative control and an evidence path). This skill is the
inspection-and-completion pass: **assumptions get verified with evidence before
anything else**, because a wrong assumption buried inside working-looking code
is exactly the kind of bug that slips through review - and **an OBSERVED line is
a hypothesis, never a result**: the sim-rig journal holds 16 confident false
readings, and a headless worker had nobody to catch one.

## Core rule: evidence, not reasoning

An assumption is CONFIRMED or REFUTED **only by observing the running system
or the authoritative source** - never by re-reading the code and concluding
"it makes sense". The worker already reasoned its way into the assumption;
re-reasoning repeats the same blind spot. Evidence categories (the project
playbook maps each to concrete tools):

- **Runtime logs** - the app/service's own log output at the exact spot,
  via the project's log-reading tool or a temporary log statement (thrown
  away after - `git status` must come back clean).
- **Network traffic / live API** - the project's traffic-capture tool, or a
  direct request to the dev/staging API to see the real response shape.
- **Authoritative source** - the actual code in the backend / contract /
  consumer repo the assumption is about (local checkout, read-only).
- **A test that encodes the assumption** and runs against real behavior.

If evidence genuinely cannot be obtained, the assumption stays **UNVERIFIED**
- that's an open risk to surface to the user, not a silent pass.

### Two kinds of claim that need more than a look

These hold whether the acceptance runs unattended or with the user sitting next to
you. **A human being present is not one of the evidence categories** - it is the
condition under which both of the failures below actually shipped.

**1. A claim about what appears on screen must name the CHANNEL that settles
it.** Not "check it looks right" - the specific observation that makes the claim
true or false: a delta measured in points, a number read out of the layout log,
an anchor-versus-rendered-frame probe, or a plain screenshot when the claim
really is binary presence. The playbook's diagnostic section maps these to
real scripts; pick the channel BEFORE observing, not after a round of squinting
failed to settle it.

Why this is a rule and not advice: the accessibility tree reports a view's
frame, not where the rendered text sits inside it, so "looks centered" cannot
resolve a sub-point offset, and a screenshot cannot tell a wrong anchor from
wrong offset math at all. Both of those shipped to review with someone looking
at the screen (a shared component verified on one render site while the bug sat
in another; a picker sitting 358pt off its row and reading as "roughly next to
it").

**One round of looking that does not settle a claim escalates to
instrumentation, never to a second round of looking.**

**2. A claim about a guard needs the guard broken.** "This test fails if you
remove the lock / the check / the early return" is a claim, not evidence: remove
the thing, re-run, and count. Run it enough times to expose a guard that only
sometimes fires - a statistical race needs tens of runs, not three. A guard that
fires intermittently reads as protection and lets the defect back in on the next
change, which is the most expensive way for this to fail: the test is green when
the bug returns, so nobody looks there.

## Evidence playbook (per project)

This skill is project-agnostic; the concrete tools are not. BEFORE Step 2, run
**`pm executor show <project>`**. It prints the project's declared handoff
contract - the playbook path, the runtime-driving skill (plus that skill's
diagnostic scripts) and, when declared, the **rig skill** that stands the
runtime up when it is down - alongside the worktree slots with their resolved
**runtime identifiers (simulator/device ids, Metro ports)** and the read-only
context repos. Then:

1. **Read the playbook** it names. It maps the evidence categories above to
   real commands/paths here, and says what each diagnostic script is FOR.
2. **Read the runtime skill in full** (its SKILL.md, not its one-line
   description). Its numbered sections carry the measurement and
   instrumentation techniques; the scripts alone are unusable without them.
3. **Take ports and device ids from `pm executor show`, never from prose.**
   pm resolves them from config; any copy in a doc drifts.
4. **Runtime down? The rig skill is the cold-start procedure** - read it whole
   and follow it; status check first, never restart a component that reports
   healthy. No rig skill declared: use the playbook's runtime section, and if
   that is silent too, say so instead of improvising a backend from memory.

If the project declares no handoff block (`pm executor doctor <project>` says
so), or the playbook does not exist: derive the tools from the repo's own
CLAUDE.md and skills, tell the user which tools you settled on, and OFFER to
scaffold the playbook plus the `executor.handoff` block so the next acceptance
starts warm. Never silently guess a tool that mutates anything.

## Process

### Step 0: Locate the run - and the machine it ran on

Invoked with no id, or with one that does not resolve: **discover the run, do
not ask.** Where a batch ran is a fact to look up, not a question for the user -
and asking is how an acceptance ends up pointed at the wrong pm server. Both places,
newest first:

```sh
# local runs, every project
ls -t ~/.claude/pm/*/.executor/*.json 2>/dev/null | while read f; do
  jq -r --arg w local --arg p "$(basename "$(dirname "$(dirname "$f")")")" \
    '[$w,$p,.task_id,.kind,.status,.started,((.subs//[])|length|tostring)]|@tsv' "$f"; done

# the remote runners: `pm config show` lists them under remotes: (name, ssh, root).
# One command per runner - RUNNER = its ssh alias, ROOT = its pm root, PROJECT = the
# project slug on that runner (`pm runs --json` names the projects that have runs there).
ssh -o ConnectTimeout=5 RUNNER 'cd ROOT/PROJECT/.executor && ls -t *.json | \
  while read f; do jq -r "[\"vps\",\"PROJECT\",.task_id,.kind,.status,.started,((.subs//[])|length|tostring)]|@tsv" "$f"; done'
```

`kind: run-epic` = a batch, `kind: work` = a single task run; both are
acceptance-ready. Resolve each candidate to its title through the right pm server and
present ONE numbered table (where, project, parent, date, status, subs).

- **Exactly one live/recent run** -> take it, name it in one line, continue.
- **More than one** -> ask which. Never silently take the newest.
- **An id was given** -> skip the listing, but still read the task back and
  print `server=<pm|pm-vps> · project · id · title` before any write.
- **The remote is unreachable** -> one line saying remote runs were not checked
  and why, then continue with the local ones. Never stop on this.
- **Nothing found at all** -> do NOT report "no run" and stop. Go to Step 0a.

### Step 0a: Nothing there yet? Arm a 20-minute re-check, don't give up

A batch is often scheduled to start LATER - a `sleep N` plus a detached
`pm run-epic`, which on the runner looks like
`.executor/<parent>-delayed.sh`. So "no run" at this instant routinely means
"not yet", not "nothing is coming", and reporting the former hands the user back
the wait this skill exists to absorb.

1. **Check whether a launch is already queued** - cheap, and it answers "is one
   coming, and roughly when":

```sh
ssh -o ConnectTimeout=5 RUNNER 'ls -la ROOT/*/.executor/*-delayed.sh 2>/dev/null; \
  ps -eo pid,etime,args | grep -E "sleep [0-9]{3,}|run-epic" | grep -v grep'
ls -la ~/.claude/pm/*/.executor/*-delayed.sh 2>/dev/null; pgrep -fl "run-epic|sleep [0-9]{3,}"
```

A pending launcher names its own ETA: launchers written by batch-prep-run
carry a `# armed: ... · fires_at: ... (epoch ...) · sleep N` header - read
`fires_at` and report it (`head -3` of the script). No header (an older
hand-rolled launcher)? Fall back to the live `sleep`'s `etime` against the
`sleep N` in the script. A launcher file with NO matching live process is
stale - it already fired (pre-header launchers do not self-delete) or its
sleep was killed; check RunState before calling it pending.
Report what will launch and when. Nothing queued?
Arm the watch anyway - prep may still be ahead of the run.

2. **Arm a poll that fires once, when something appears.** Any new state file, a
   status change, or a newly scheduled launcher counts:

```sh
snap() {
  ls ~/.claude/pm/*/.executor/*.json 2>/dev/null | while read f; do
    echo "local $(basename "$f") $(jq -r '.status' "$f")"; done
  ssh -o ConnectTimeout=5 RUNNER 'cd ROOT/PROJECT/.executor 2>/dev/null && \
    for f in *.json; do echo "vps $f $(jq -r .status "$f")"; done' 2>/dev/null
  ssh -o ConnectTimeout=5 RUNNER 'ls ROOT/*/.executor/*-delayed.sh 2>/dev/null | \
    while read s; do echo "vps-scheduled $(basename "$s")"; done' 2>/dev/null
}
base=$(snap | sort)
while true; do
  sleep 1200
  cur=$(snap | sort)
  if [ "$cur" != "$base" ]; then comm -13 <(echo "$base") <(echo "$cur"); break; fi
done
```

Run it through **Monitor with `persistent: true`** - the wait routinely outlives
a single Bash call, and one line of output is exactly the one notification
wanted. **Sorting both snapshots is load-bearing**: an mtime-ordered listing
reshuffles itself and would fire on nothing. Silence means no batch yet - here
that is the correct reading, not a blind spot.

3. When it fires, restart Step 0 from the top (rediscover, since the new run may
   be remote) and continue into Step 1. Meanwhile say in ONE line what is armed:
   cadence, what it watches, and that the user can walk away - then stop working.
   Never busy-loop in the foreground, and never re-run discovery yourself every
   few seconds. `TaskStop` cancels it if the user changes plans.

### Step 0b: If the run was remote, four things change

Everything else in this skill is unchanged - but these four are load-bearing,
and each one has already cost a session:

| | local run | remote run |
|---|---|---|
| task reads/writes | `mcp__pm__*` | **the runner's pm MCP** (e.g. `mcp__pm-<runner>__*`), project as named on the runner |
| run-state | `~/.claude/pm/<slug>/.executor/<parent>.json` | **`ssh RUNNER 'cat ROOT/PROJECT/.executor/<parent>.json'`** |
| branch | already local | **origin only** - `git fetch origin <branch>`, worktree off `origin/<branch>` |
| visual pass | often already done | **always outstanding** - the runner is Linux, nothing visual was ever seen |

**The same id exists on both pm servers and means different tasks.**
`orbit-1` locally is a project-setup task; `orbit-1` on the VPS is
a batch tracker. Nothing errors: a fuzzy lookup on the wrong server returns a
real, unrelated task, and writing an acceptance block there corrupts work nobody was
doing. So: ids from a remote run go ONLY to `mcp__pm-vps__*`, and identity is
confirmed by TITLE, never by "the id resolved". Both the runner's own prefix
(e.g. `orbit-vps-*`) and `orbit-1*` are legitimate id
families on that server.

### Step 1: Load the task and the handoff

`pm_get_task` (on the server Step 0 resolved) -> read the brief and the worker's
Log entry. Extract:

- the branch (frontmatter `branch`) - `git fetch origin` and check it out in
  the MAIN checkout (the worker pushed from the isolated worktree),
- every `ASSUMPTION:` line (with its `verify:` recipe),
- every `TODO:` line (a `TODO: runtime verification not run - rig DEAD: <why>`
  means the runtime phase was skipped for a rig reason - the visual pass is
  wholly yours, and the `<why>` is a rig fault to fix or journal, not a task
  fault),
- every `OBSERVED:` line (the worker's runtime readings - see Step 2b),
- the worker's summary and commits.

**Three checks before trusting the branch** - each one has silently wasted a
whole acceptance:

1. **The status describes the WORKER, not origin.** `git ls-remote --heads
   origin <branch>`. A sub can sit on `pushed` with zero commits and no ref on
   origin at all. No ref + a handoff that claims no code (an investigation sub)
   is a legitimate outcome - say so and go to the report. No ref + a handoff
   claiming commits = report the contradiction, do not reconstruct the work.
2. **Check the base before reading the diff.** `git merge-base <base> <branch>`
   against the base's current tip: a branch prepped days earlier shows a phantom
   diff of everything that landed meanwhile. Diff two-arg against the merge-base,
   and say if the base is stale.
3. **Check nobody already shipped it.** `gh pr list --state all --search
   '<ticket>'` plus `git log --all -S'<ticket>'`. A batch runs detached for
   hours while work continues elsewhere - including other sessions of your own.
   Found a duplicate? Compare both, recommend which ships, and stop; do not
   acceptance a branch that is going to be thrown away.

A worker handoff can also be **missing entirely**: a sub that died on a
harness-level error (`worker returned no structured result`) has no ASSUMPTION
list, no TODO list, no self-report, and its whole diff went unreviewed. Then
derive the claims from the diff plus the spec's baked-in decisions, hold them to
the same evidence bar as Step 2, and state in the report that the diff was
unreviewed - that is invisible from the status alone and the user needs it before
merging.

If the app/runtime isn't up, cold-start it with the handoff's rig skill (`pm
executor show <project>` names it) - status check first, restart only what is
down. Fall back to the playbook's runtime section when no rig skill is
declared.

### Step 2: Verify every assumption (before touching anything else)

For each `ASSUMPTION:`, run its `verify:` recipe (or design an equivalent
evidence-based check if the recipe is missing/stale). **Spec-baked decisions
count too:** a `DECYZJA`/pre-made ASSUMPTION written into the spec at prep
time gets the same evidence bar as worker assumptions - prep can be wrong
(ACME-1305: the spec mandated dropping 72h on a false FE-only premise; the BE
enum refuted it at acceptance). Verdict per assumption:

- **CONFIRMED** - evidence matches; note what was observed.
- **REFUTED** - evidence contradicts it. **Stop and fix the code NOW**, before
  processing further assumptions or TODOs - later work may be built on the
  broken premise. Commit the fix separately (`fix: ...`).
- **UNVERIFIED** - evidence unobtainable; flag to the user and decide together.

### Step 2b: Re-observe every OBSERVED line (same controls, your own eyes)

An `OBSERVED:` line has the shape `OBSERVED: <screen> shows <seen> - expected:
<AC> - positive control: <...> - negative control: <...> - evidence: <path>`.
It is the worker's claim about the runtime, taken on the executor's slot
runtime (the slot's simulator, or the slot's dev server in a browser for a web
project) under `executor.rig`'s verdict. Treat it exactly like an ASSUMPTION
whose `verify:` recipe is "look again": on the project's runtime (Step 5's rig,
or the slot's runtime when it is still up - `pm executor show <project>` names
the driving skill: `simulator-verify` or `web-verify`, and the slot's ports),
reach the same screen or route and re-take the reading WITH THE SAME TWO
CONTROLS - the positive control must be visible, the negative one absent, or
the reading proves nothing about the rig, whatever the screen shows. Then:

- **CONFIRMED** - you saw the same thing, both controls held. Record it; the
  worker's screenshot is evidence only once yours agrees with it.
- **REFUTED** - you saw something else, or a control failed for the worker
  (its own line shows a missing control, or its screenshot contradicts its
  text). The AC is NOT met on that point: fix the code if it is a code fault
  (`fix:` commit, like a refuted assumption), and ALWAYS add a journal entry
  for the project's rig (`pm_journal_add`, tag `false-reading` - `sim-rig` on
  a React Native project; a web project declares its own, e.g. `web-rig`, in
  `project.yaml` `journals:`; none declared = say so in the report instead)
  naming what the worker read, what was true, and why the rig lied - that
  entry is the only thing that improves the next batch.
- **UNVERIFIED** - the screen is unreachable for you (data the account cannot
  produce, a device-only path); the claim stays open in the report, marked
  "worker-observed, unconfirmed", never folded into "Sprawdzone:".

An OBSERVED line missing either control is REFUTED by form: do not re-take it
on the worker's terms, re-take it on the playbook's, and record the omission.
`Sprawdzone:` in the ticket paragraph (Step 7) may cite only what YOU
confirmed; "the worker saw it on the simulator" never appears there.

### Step 3: Record the verdicts

Append to the task Log (`pm_update_task` with `body_append`) a dated
verification block:

```
**Acceptance (<date>)** - assumption verification:
- CONFIRMED: <assumption> - evidence: <what was observed>
- REFUTED:   <assumption> - evidence: <...> -> fixed in <commit>
- UNVERIFIED: <assumption> - why + agreed risk
- OBSERVED CONFIRMED: <worker reading> - re-observed: <what you saw> - controls: <pos>/<neg>
- OBSERVED REFUTED:   <worker reading> - actual: <...> -> fixed in <commit> / journal sim-rig <id>
```

This is the audit trail: next time the executor's assumptions drift in some
area, `/executor-retro` can see which kinds go wrong.

### Step 4: Work the TODO list

Now do the deferred items - typically the visual/manual pieces. Small commits
as you go. Update the checklist in the task as items complete.

### Step 4b: Findings outside the task's scope are DROPPED - not fixed, not filed, not proposed

Anything real you turn up that is outside this task's AC - a sibling call site
with the same bug, an architectural limit the fix made worse in kind, a
pre-existing red - does **not** get fixed here, does **not** get filed, and
does **not** come back as a suggestion the user has to read and dismiss.

**Never call `pm_add_task` for a finding.** This holds for BOTH pm servers -
the local `pm` and the VPS runner's `pm-vps` - and regardless of how obviously
real the finding is.

What to do instead:

1. Append the evidence (file:line, the measured numbers) to THIS task's Log via
   `body_append`, in at most one line per finding. The Log is where it stays;
   whoever hits the same thing later will find it there.
2. Say nothing about it in the report. No "proposed tickets" section, no
   numbered list of ideas, no "worth a ticket?" question.

The only exception: a finding that would lose user data or take the shipped
product down gets ONE line in the report, named as that. Everything else is
Log-only.

Why the change: a proposed-ticket list reads as work the user must triage, and
in practice none of them were ever acted on - so the list cost reading time and
bought nothing. Fixing it inflates the diff and buries the reviewable change;
filing it buries the backlog. The Log entry is the durable output.

### Step 5: Verify and gate

- Runtime verification of the affected screens/flows, per the playbook (e.g.
  a simulator-verify skill, an e2e run, a manual staging pass). Visual claims
  settle through a named channel (see "Two kinds of claim" above), never
  "looks fine".
- **The playbook's pre-PR gate must pass - not just its verification command.**
  Those are usually two different things: the verification command is what gates
  a single commit (types, lint, formatting), while the pre-PR gate is the local
  stand-in for CI - test and performance suites, review passes, whatever else
  the project runs before review. Use the SAME gate the project's interactive
  feature flow uses; a task finished here enters review at the same bar as one
  built by hand, and if this path is thinner, the difference shows up as red CI
  on an already-open PR, which is exactly where it costs the most.
- If the playbook declares only a verification command and no gate: run it,
  then say plainly which CI checks nobody ran locally. Do not describe the
  branch as clean on the strength of a partial gate.
- No suppression to get a gate green - never a disabled rule, never
  `@ts-ignore` / `@ts-expect-error`, never `--no-verify`.
- Any throwaway instrumentation from Step 2 removed - `git status` clean
  except intended changes.

### Step 6: PR and status

- Update the task: brief = the ticket paragraph (below) followed by at most two
  sentences of technical end-state (branch, head, acceptance commit); links
  (commits).
- **Propose** the PR per the playbook's PR conventions (base branch, title
  format, body style) - but do NOT open it without the user's confirmation;
  they may want a manual pass first.
- After the PR is opened and linked: the sub may move `merged -> done` (batch
  subs follow the loosened subtask flow - merged AND verified = done).

### Step 7: Report - written for a cold reader

The reader launched the batch, walked away for hours, and does not remember
what the ticket was about or how it was specced. They have not read the spec,
the worker's handoff or the Log, and they will not. Every line of the report
must make sense to that person. Write it in the user's conversation language
(Polish for this user). Fixed order:

**1. Co z ticketem** - the ticket paragraph. It is about the TICKET, never
about the acceptance process. Four labelled lines, always all four:

- `Bug:` the reported problem retold in one sentence as the user experiences
  it - which screen, what they do, what they see. Copy it from the spec's
  `## Bug as the user sees it` when batch-prep wrote one; otherwise write it
  now from the `## Ticket` section.
- `Stan:` **naprawione** / **częściowo** / **nie naprawione**, then one
  sentence of what now happens on that screen. "Częściowo" names what still
  misbehaves, in the same user-facing words.
- `Sprawdzone:` where and how - and, explicitly, whether it was checked in the
  REPORTER'S OWN scenario (their device, their kind of data, their steps, from
  the spec's `## Reporter's scenario`). When it was not, say in plain words
  what that scenario is, why it was not reproduced, what stood in for it, and
  what the human can do to close the gap ("wgraj zdjęcie dowolnemu klientowi
  na koncie dev i otwórz ten ekran"). A mechanism proven on stand-in data is
  NOT the reporter's scenario - say so.
- `Przed PR-em:` the actions still standing between this branch and a PR, each
  with its reason, or "nic". Decisions the human must make go here too, phrased
  as the choice ("dopisać do tego PR-a czy zostawić").

Banned in this section: the words sub, claim, kanał/channel, REFUTED,
CONFIRMED, UNVERIFIED, worker, agent, envelope, gate; enum values or literals
from the code (`new_lead`, `in_progress`); file paths and line numbers; test
counts; commit hashes. All of that has a home in section 4. A line the user
would have to open the spec to understand is a defect in the report - rewrite
it, do not footnote it.

**2. Co zrobiła sesja odbioru poza sprawdzaniem** - which fixes the acceptance
itself pushed to the branch (what each changes for the user, plus the commit
hash - the one place a hash belongs above section 4), which tests it added, or
"nic nie zmieniała". Then one line: nothing merged, no PR opened, status
untouched (or the exception, named).

**3. Sprzątanie po testach** - every side effect on shared data or devices
(records created on the dev account, fixtures left on a simulator, contacts
added), each marked "zostawione, skasuj jeśli zbędne" or "skasowane". Omit the
section only when there was none.

**4. Szczegóły techniczne** - the acceptance's own record: verdict per
assumption (CONFIRMED / REFUTED / UNVERIFIED with evidence), visual claims and
the channel that settled each, gates with their numbers, unreviewed commits,
turns and cost. This is the section the old report consisted of; it is still
wanted, last.

Before sending: read section 1 once as the returning user. If any line needs
the spec to be understood, it goes back to the drawing board.

## Out of scope

- Running the batch itself (`pm run-epic`) or re-running failed subs.
- Merging PRs - always the user.
- Cross-task work: one invocation = one task. For the next task, run the
  skill again.
