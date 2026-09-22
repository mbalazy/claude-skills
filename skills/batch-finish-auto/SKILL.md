---
name: batch-finish-auto
description: Drives the acceptance of a WHOLE executor batch autonomously - discovers which run to take (local runs and the remote VPS runner alike, so no parent id has to be remembered), watches the pm run-epic run, and as each sub reaches a terminal status spawns a subagent that runs the batch-finish procedure for it in an isolated worktree, verifying the worker's ASSUMPTIONs with evidence. Mechanizes the "manual" handoff items it can, owns the visual pass on the project's runtime itself (agents never touch the shared simulator), and leaves only design judgment, product calls and device-only checks for the human. Flags: --sim / --no-sim. Coexists with pm's own auto-chain (finish_mode: auto): a batch whose acceptance already ran headless is DRAINED (visual queue + report review only), never redone, and an armed chain is yielded to, not raced. Use when the user says "/batch-finish-auto", "odbierz caly batch", "dowiez odbiory sam", "zrob odbior wszystkich subow", "odbierz batcha z VPS-a", "domknij to co poszlo na serwerze", "dociagnij wizualia po auto-odbiorze", or leaves a run unattended and wants the acceptances delivered on their return. Can start BEFORE the run exists - it waits out prep rather than failing. For ONE task, use batch-finish.
---

# Batch Finish Auto

Unattended acceptance of an entire batch. The user is not watching: everything
verifiable headless gets verified and recorded; everything that genuinely
needs a human is collected into one handoff list. Nothing is closed, merged,
or PR'd - those stay the user's calls.

Invoking this skill is consent to run the acceptance passes and to push
evidence-driven fixes onto the SUBS' OWN BRANCHES. It is not consent to
merge, to open PRs, to move statuses, or to touch `main`.

## Flags

| flag | effect |
|---|---|
| `--sim` | force the visual pass (Step 6) on |
| `--no-sim` | skip the visual pass; every visual claim is reported UNVERIFIED **with the reason**, never silently dropped |

Default: the visual pass runs whenever the project playbook names a
runtime-verify skill. Turn it off when the runtime is genuinely unavailable
(device-only feature, the still-running manager owns the runtime, no build).

**On a remote run the pass is never "already done"** - that runner is Linux, so
every visual claim in the batch was deferred here by construction. `--no-sim` on
a remote batch means nothing about appearance was verified anywhere, by anyone;
allowed only with the reason recorded against each claim.

## Step 0: Which run? Discover it, including remote ones

No parent id given, or one that does not resolve: run **batch-finish's Step 0**
(discovery over the local run-state dirs AND the remote runner, newest first,
one numbered table, one candidate = take it, several = ask, remote unreachable =
report and continue). If the run turns out to be remote, **batch-finish's Step 0b
governs the whole session**: `mcp__pm-vps__*` for every task read/write, the
run-state read over ssh instead of the local path in Step 1, branches fetched
from origin, and the same-id-on-both-servers trap. Do not re-derive any of that
here; if this file and batch-finish ever disagree, batch-finish wins.

**Found nothing anywhere? batch-finish's Step 0a applies** - look for a queued
launcher (a delayed `sleep N` + `pm run-epic`), then arm the 20-minute
persistent poll and stop working, rather than reporting "no run". Do not confuse
that with the one genuine failure in Step 1 below: a parent id that was GIVEN and
does not exist (mistyped, or prep aborted and deleted it) is reported at once and
never waited on. Nothing found *without* an id = wait; a named parent missing =
report.

The watcher in Step 2 works identically on a remote run - same poll, same
snapshot, `ssh <runner> 'cat ...'` instead of `cat`.

## Step 0.5: Claim the run - or yield to the auto-chain

pm has its own acceptance path since 0.41: a tracker with `finish_mode: auto`
(or a run launched with `--then-finish`) spawns a detached `pm finish
<tracker>` the moment the run ends - the same acceptance procedure, headless
and `--no-sim`. Two acceptances pushing to the same branches is the one
collision this step exists to prevent, so before any watcher or agent, read
`<data dir>/.executor/<tracker>.finish.json` (over ssh for a remote run), run
`pm finish status <tracker>`, and check the parent's `finish_mode` via
`pm_get_task`. Then exactly one of:

1. **finish.json terminal (done/failed)** - the acceptance already ran.
   Switch to DRAIN MODE (below); do not redo it.
2. **finish.json running, or the claim is held** - an acceptance is in
   flight. Do not compete: say who holds it (`pm finish status` names host
   and pid), watch for its end, then drain.
3. **`finish_mode: auto` and the run is still ahead or in flight** - the
   chain WILL fire at run end. Do not run a parallel acceptance: announce
   that the auto path is armed, keep Step 2's watcher for progress only, and
   when the chained acceptance finishes, drain. Taking the run over instead
   is the user's explicit call, and it only works BEFORE launch
   (`--then-finish=false`) - the chain decision is resolved at run start, so
   clearing `finish_mode` mid-run changes nothing.
4. **No auto path anywhere** - `pm finish claim <tracker> --session
   <session-id>`, then proceed with the full procedure. The claim makes a
   board- or hand-launched `pm finish` refuse while it is live - but only
   while somebody refreshes it: the TTL is 10 minutes, and the whole
   acceptance is longer than that. Re-running the SAME command with the SAME
   `--session` refreshes the claim in place (pm >= 0.49.0 answers `refreshed
   the claim ...`; `started` holds still, so the board keeps showing the
   acceptance's true age). Keep it alive with a **background refresher
   loop**, started as a background Bash task right after the claim - the
   watcher rounds alone are NOT enough, because the agent-spawning and
   visual-pass phases never pass through the watcher (that is exactly how
   orbit-117's claim lapsed 13 minutes into a 23-minute acceptance):

   ```sh
   for i in $(seq 1 240); do   # hard cap ~4h: a dead session must not wall the run off forever
     sleep 60
     pm finish status <tracker> | grep -q "session   <session-id>" || exit 0
     pm finish claim <tracker> --session <session-id> >/dev/null 2>&1 || exit 0
   done
   ```

   The `status` check comes FIRST and exits on anything that is not our own
   live claim, so a claim released in the final report is never resurrected
   by a still-ticking loop, and an expired-and-taken-over claim is never
   fought for. Belt and braces: also re-claim at each watcher round and
   after each agent spawn / visual-queue item - the loop covers the long
   silent stretches, the checkpoints cover a loop that died. (A `busy`
   answer naming this host on a live claim means the pm binary predates the
   refresh, pre-0.49 - then the claim genuinely cannot be kept alive; say so
   in the report and re-claim right after each lapse instead.) In the final
   report: `pm finish release` with the printed `--started` stamp (or the
   `--session`), then kill the refresher loop - a forgotten kill is a 60s
   cleanup, not a leak, because the release already makes the loop's next
   tick exit.

### Drain mode - the acceptance already ran headless

The chained acceptance did everything mechanizable and, being `--no-sim`,
deferred every visual claim. Drain = the second half only:

1. Read the report (`<tracker>.finish.md`, over ssh for a remote run), the
   `.finish.json`, and each sub's Log acceptance block.
2. Verify the UNVERIFIED visual claims via Step 6 - the orchestrator owns
   the runtime, same rules (named channel, one look then instrumentation).
3. Re-open a sub's acceptance ONLY on contradiction: a recorded verdict the
   artifacts do not support (Log says fixed, branch has no such commit) gets
   one agent re-run for THAT sub - never a batch-wide redo.
4. Report per Step 9, marking which verdicts came from the chained
   acceptance and which from the drain. PRs, merges and statuses: still the user's - drain never opens
   a PR.

## Step 1: Locate the run and its subs

Read the run-state (`~/.claude/pm/<slug>/.executor/<parent-id>.json` locally, or
the remote path over ssh): sub ids, their statuses, per-sub `note` (the worker's
handoff), turns and cost. The parent task's Spec lists branches and the
file-overlap seams.

Terminal sub statuses (`merged`, `failed`, `blocked`) are ready for acceptance;
`running`/`pending` are not. A run may still be in flight - that is normal,
see Step 2.

### Started before the run? That is the intended usage

`batch-prep` creates the parent tracker BEFORE it gathers tickets, precisely so
this session can be opened while the prep still runs. Three entry states are
therefore normal, and none of them is an error:

| what you find | what it means |
|---|---|
| parent exists, no run-state file | `pm run-epic` has not launched yet - prep still in flight |
| parent exists, zero subs | prep has not written the subs yet |
| run-state exists, every sub `pending`/`running` | run started, nothing has landed |
| run done, `<tracker>.finish.json` terminal | the chained acceptance already happened - drain mode (Step 0.5) |

In all three: confirm the parent with `pm_get_task` and that it carries
`epic_mode: independent`, state in one line what you are waiting for, then go
into Step 2's watcher. **Do NOT report "no run found" and stop** - that hands
the user back the very wait this ordering exists to remove.

The one genuine failure here is a parent that does not exist (mistyped id, or
prep aborted and deleted it - batch-prep deletes the parent when it aborts).
`pm_get_task` returning nothing = report it immediately and do not wait; a
missing run-state alone never justifies that conclusion.

## Step 2: Acceptance as subs land, not after the run

Do NOT wait for the whole run. Poll the run-state in a background Bash
watcher that exits on change or after ~10 minutes, and the moment a sub
reaches a terminal status, spawn its acceptance agent. Acceptance of sub N overlaps
the worker of sub N+1 - that is the point, and it is safe: agents work in
their own worktrees.

Watcher shape (snapshot = status + current sub + finished subs; exit early on
any change):

```sh
for i in $(seq 1 14); do sleep 45; [ "$(snap)" != "$base" ] && break; done
```

Never poll in the foreground, and never re-check faster than ~45s - the
manager only writes the run-state at sub boundaries and heartbeat ticks.

**The pre-run wait is much longer than the between-subs wait.** Prep plus the
first worker is routinely 20-40 minutes, so when you entered before the run
(Step 1) two things change:

- The snapshot must also cover **whether the run-state file exists** and **how
  many subs the parent has** - otherwise nothing changes in it during prep and
  the watcher just times out on a still-healthy batch.
- Re-arm the watcher across rounds instead of concluding anything after one
  ~10-minute window. Each round, print one line of progress (`prep running, N
  subs so far` / `run started, sub X running`) so an unattended session leaves
  a trail of what it was waiting on.

## Step 3: Spawn one subagent per sub

One agent per sub, in parallel where subs are ready together. Model: the
default cheap tier for routine subs; the strong tier for subs that carry
concurrency, an unreviewed commit, a hit review cap, or an unusually high
cost - those are where a shallow acceptance costs the most.

The agent prompt MUST carry:

1. **The procedure by reference, not by copy**: "follow the batch-finish
   skill (`~/.claude/skills/batch-finish/SKILL.md`)"; if the two ever
   disagree, batch-finish wins.
2. **Isolation**: `git -C <repo> worktree add <scratch>/accept-<sub> <branch>`,
   ALL work there. The main checkout may be occupied by the still-running
   manager and is left on whatever branch the run ended on - read-only git
   against it, never a checkout/commit there. Worktree removed at the end.
3. **The worker's handoff verbatim** - its ASSUMPTION/TODO/OBSERVED lines, so
   the agent verifies the real claims rather than rediscovering them. An
   `OBSERVED:` line (a sub that ran the executor's `runtime` phase, `runtime:
   on`) is the worker's own simulator reading, controls included - a
   HYPOTHESIS for the visual pass, never a settled claim (batch-finish Step 2b).
4. **The suspicion signal for THIS sub**, when there is one: suspiciously few
   turns for the price, a review cap reached, a commit that no fresh reviewer
   saw, a claim about test strength. Name it and demand it be checked.
5. **The spec-baked product decisions** the implementation must honor,
   including the EXCLUDED alternatives - verify they did not creep back in.
6. **Hard rules** (see below).
7. **What to return**: verdict per assumption with a one-line evidence each,
   probe outcomes with actual numbers, gate result, commits pushed, what
   remains for the human - AND a draft of the ticket paragraph (batch-finish
   Step 7, section 1): the four `Bug / Stan / Sprawdzone / Przed PR-em` lines
   in plain words, with `Sprawdzone:` marked "wizualnie: czeka na orkiestratora"
   where a visual claim is still open. The orchestrator completes that line
   after the visual pass; the agent never invents the visual result.

## Step 4: Non-negotiables in every agent prompt

- Never `make install` (it would swap the binary a live run is using), never
  touch the version file or the project CLAUDE.md version line, never merge
  to main, never open a PR, never change task status.
- Never point a built binary or a test at the real pm data dir - throwaway
  stores only. The task Log write via `pm_update_task` is the ONE sanctioned
  data write.
- **Never `pm_add_task`** - not on `pm`, not on `pm-vps`, no matter how real the
  finding. Out-of-scope findings are dropped: one line in the sub's Log, nothing
  in what the agent returns (Step 7).
- Commits only on that sub's own branch, inside the agent's worktree; push
  that branch only. Throwaway probes deleted, `git status` clean at the end.
- **Never touch the shared runtime** (simulator/emulator/device/dev server).
  It is a single resource and several agents run at once; the orchestrator
  owns it (Step 6). An agent that needs a visual check writes the claim into
  its report instead of trying to observe it.
- **Nothing about this setup leaks off the machine.** Commit messages, branch
  names, PR titles/bodies and issue-tracker comments are in the repo's own
  language (English unless the repo says otherwise) and read as ordinary human
  work: no batch/sub/executor/worker/agent/acceptance wording, no orchestrator task
  ids, no "fixed after the agent run" markers. Commit messages follow the
  repo's normal convention, with no extra prefix distinguishing an acceptance
  commit. Traceability lives in LOCAL artifacts instead: keep the acceptance commit
  separate from the worker's (never amend or squash into it) and list its hash
  in the task Log and the final report.
- Record verdicts in the task: `body_append` a dated acceptance block
  (CONFIRMED / REFUTED / UNVERIFIED + evidence per line) and overwrite the
  brief with the ticket paragraph (batch-finish Step 6/7: the four plain-words
  lines first, then at most two sentences of technical end-state - branch,
  head, acceptance commit). A brief that opens with evidence and enum values
  is the wrong brief: it is read cold, on the board, by the same person the
  report is for.

## Step 5: What the agent must do itself vs leave to the human

**Do it headless** - most "manual" TODOs a headless worker writes are
mechanizable, because the worker was blocked by a sandbox rule, not by
physics:

- "create data X and run the command" -> build the binary in the worktree,
  drive a throwaway store, read the real output.
- "check whether stats lose/double-count this" -> synthesize the fixture and
  call the aggregation directly; record the ACTUAL numbers.
- "the UI shows Y" -> the model-level half (which state is set, which index
  is picked) is unit-testable; only the pixels are not.

**Mutation-test every claim about a guard** - break the thing, re-run, count,
enough times to expose a guard that only sometimes fires. The rule and its
reasoning live in batch-finish ("Two kinds of claim that need more than a
look"); the agent prompt carries it by reference like the rest of the
procedure. It is worth naming explicitly in the prompt anyway: unattended, it
is the highest-value check there is.

**Hand to the orchestrator's visual pass** (Step 6): anything whose truth is
what appears on screen - layout, spacing, a label, whether a control still
reacts to touch. The agent states the claim and how to reach the screen; it
does not observe it itself. **A worker's `OBSERVED:` line is handed over
verbatim, tagged "worker-observed"** - it already names the screen, the
expected state, both controls and an evidence path, so the agent adds nothing
and, above all, does not mark it settled: the orchestrator re-takes the reading
with the SAME positive and negative controls. A line missing a control is
handed over as "refuted by form" (re-observe on the playbook's terms).

**Every handed-over visual claim must name the CHANNEL that settles it** - the
rule itself is batch-finish's ("Two kinds of claim that need more than a look"),
and the channels come from the project's runtime skill (`pm executor show
<project>` for the scripts, the playbook for what each is for). What is specific
to this hand-off: the agent picks the channel even though someone else does the
observing, because a claim arriving without one makes the visual pass improvise
the measurement from scratch - and improvised measurement is how a sub-point
offset gets waved through.

**Leave to the human**: design judgment, product decisions, and anything
needing credentials or a physical device.

## Step 6: Visual pass - the orchestrator owns the runtime

Run `pm executor show <project>` for the runtime slots (device ids, dev-server
ports) and the handoff contract, read the playbook and the runtime skill it
names IN FULL, then drive the runtime YOURSELF, in this session. A runtime
that is DOWN is stood up with the handoff's **rig skill** when one is declared
(read it whole; status check first, restart only what reports down), the
playbook's runtime section otherwise - never improvised from memory. The skill's
numbered sections are where the measurement and instrumentation techniques
live; its scripts are unusable without them, and the identifiers belong to pm,
never to prose that can drift. Do not delegate the runtime: it is one shared
resource,
and a single owner serialises access with no lock protocol to get wrong, no
agent stranded waiting, and one app rebuild instead of one per agent.

Work a queue: as each agent reports, take its visual claims and check them
before or alongside the next agent's - no need to wait for the whole batch.
Reach the screen, observe, and record the outcome the way the runtime-verify
skill prescribes (element tree / measured numbers / screenshot), never "looks
fine". A claim you could not reach stays UNVERIFIED with the reason. A
"worker-observed" claim (an `OBSERVED:` line) gets the same look, with its own
two controls re-run: agreement = CONFIRMED and the worker's screenshot becomes
evidence; disagreement = REFUTED, the AC is open on that point AND a `sim-rig`
journal entry (`pm_journal_add`, tag `false-reading`) records what the worker
read, what was true and why the rig lied - the only feedback the next batch's
runtime phase ever gets. The worker's reading never shortens the queue.

**One round of looking that does not settle a claim escalates to
instrumentation - never to a second round of looking.** Use the channel the
agent named (Step 5); if it named none, pick one from the playbook's
diagnostic section before observing, not after. Instrument in a worktree slot
with its own dev-server port, never the main checkout, and strip every
overlay, log line and hardcoded prop afterwards - `git status` clean is part
of the verdict.

If the batch's own manager still occupies the runtime (same checkout, same
dev server, same device), either point the pass at the project's secondary
runtime if the playbook defines one, or hold the visual queue until the run
ends and drain it then. Say which of the two you did.

## Step 7: Pre-existing findings are DROPPED - not fixed, not filed, not proposed

batch-finish Step 4b owns this rule; it applies unchanged to every agent here,
and unattended is exactly where it gets violated - nobody is watching the
temptation to "just fix it while I'm in there", to file it, or to hand the user
a list of things they never asked about.

**No agent in this run calls `pm_add_task` for a finding. Not once, on either pm
server (`pm` or `pm-vps`).**

Each agent puts at most ONE line per finding in its sub's Log (file:line, the
measured number) and returns nothing about it. The orchestrator builds no
proposal list and the final report carries no "new tickets" section. The only
exception: a finding that would lose user data or take the shipped product down
gets one line in the report, named as that.

The Log entry is the durable output of an unattended night. A proposal list is
not: in practice none of them were ever acted on, so it cost the user reading
time on their return and bought nothing.

## Step 8: Agent went idle without reporting?

Do not assume success and do not re-run it blindly. Verify from artifacts:
the task's Log for the acceptance block, `git log` on the branch, `git worktree
list` for a leftover worktree. Report what the artifacts actually show. If
the pass is genuinely incomplete, finish it yourself - the user is asleep,
"the agent didn't answer" is not a delivery.

## Step 9: Record the acceptance, then the final report

**Before releasing the claim, RECORD the acceptance** (pm >= 0.51.0) - a
hand-driven acceptance leaves no `.finish.json` by itself, so without this
the ACCEPTANCE column (`pm runs`, board `R`) reads `-` the moment the claim
lapses, as if the batch was never accepted:

```
pm finish record <tracker> --result done|partial|blocked \
  --claims-open <N-unsettled-visual-claims> \
  --note "<one line: what the acceptance concluded>" \
  --report <path-to-the-final-report-md> \
  --session <session-id>
```

- `--result`: `done` = everything accepted; `partial` = some subs accepted,
  the rest named in the report; `blocked` = could not accept.
- `--claims-open`: the visual claims still awaiting a human eye - the number
  the runs table sums into the morning TODO. 0 when the visual pass settled
  everything.
- `--report`: save the final report (the same markdown as the chat report)
  so board `F` opens it. Write it to a file first.
- `--session`: the SAME id the claim was taken with - a live own claim
  passes, a stranger's live claim refuses (do not force it).
- Order matters: **record first, release after** - `pm finish release` stays
  a separate step, exactly as before. For a REMOTE run, record over ssh with
  the runner's pm, in the runner's data dir.
- A pm predating `record` (`pm finish record --help` fails): say so in the
  report instead of skipping silently.
- Drain mode does NOT re-record: the headless run already wrote its own
  `.finish.json`, and recording over it would replace the real run's turns
  and cost with a hand entry. Only record when the acceptance was YOURS.

### The final report - written for a cold reader

The report follows **batch-finish Step 7** exactly - same four sections, same
order, same banned words - extended from one ticket to the batch. The reader
launched the run, walked away for hours, and does not remember what the
tickets were about; they will read section 1 and maybe section 2, and they
must be able to act on those two alone. In the user's conversation language
(Polish for this user).

**1. Co z ticketami** - one ticket paragraph per sub (`Bug / Stan /
Sprawdzone / Przed PR-em`, batch-finish Step 7 section 1), headed by the
external ticket id and a plain-words title of the bug, never by the pm sub
id alone. Source: the agent's draft paragraph (Step 3, item 7) with the
`Sprawdzone:` line completed from what the visual pass ACTUALLY settled
(Step 6) - which device, which account, whether it was the reporter's own
scenario or a stand-in, and what the human can do to close the gap. After
completing it, rewrite that sub's brief so it carries the same four lines -
the board must not tell a different story than the report.

**2. Co zrobiła sesja odbioru poza sprawdzaniem** - per ticket, one line:
fixes pushed to the branch by the acceptance (what each changes for the user
+ commit hash), tests added, or "nic nie zmieniała". Then: nothing merged, no
PR opened, statuses untouched (or the exception, named). This is what the user
must know before assembling, so it stays its own section, never folded into 1.

**3. Sprzątanie po testach** - every side effect on shared data or devices,
across all subs and the visual pass, each "zostawione, skasuj jeśli zbędne"
or "skasowane"; plus the runtime state left behind (which sim, which Metro,
which checkout).

**4. Szczegóły techniczne** - the table the report used to BE: sub, verdict
on the worker's assumptions (clean / fixed-N-refuted / blocked), visually
verified (yes / no + reason), **channel** (what actually settled the visual
claim: measured delta / onLayout number / anchor probe / screenshot - the
column exists so "screenshot" everywhere is visible as the weak pass it is),
what evidence carried it; then gates with their numbers per sub, unreviewed
commits, run totals (turns, cost, time window), acceptance agent models.

Save this markdown as the `--report` file (board `F` opens it) and send the
same text to the chat. Before either: read section 1 once as the returning
user. Any line that needs the spec, the Log or the code to be understood is a
defect - rewrite it in the user's words.

Statuses stay where the run left them. Closing tasks, merging branches,
assembling, and opening PRs are the user's decisions.

## Out of scope

- Launching or re-launching the batch (`batch-prep-run` does that).
- Assembling/merging branches, PRs, version bumps - human calls.
- Deciding a task is done.
