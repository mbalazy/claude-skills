---
name: epic-prep
description: Splits a new pm-cli parent+subtask epic into an executor-ready structure for `pm run-epic` - classifies each sub as mode:auto (autonomous, done = a command) or mode:manual (human/CC interactive work, e.g. simulator verification), sequences all auto subs before all manual subs, and wires depends_on correctly. Use when the user is about to create a pm-cli tracker+subs meant to run through `pm run-epic`, says "/epic-prep", "przygotuj epika pod executor", "czy to jest gotowe pod run-epic", or "podziel to na auto/manual".
---

# Epic Prep

Prepares a pm-cli parent+subtask epic for `pm run-epic` by splitting subs into
an auto-run prefix and a manual-verification suffix, then creates them via the
`pm` MCP tools with `mode`/`order`/`depends_on` set correctly.

## When to use

- User is about to create a new tracker+subs in pm-cli intended for `pm run-epic`.
- User asks to prep a feature/epic for the executor, or asks whether a planned
  split is "executor-ready".
- **Creation-time only.** This skill does not audit or fix an already-created
  tracker - if the subs already exist, that's out of scope (ask the user
  first if they actually want a retrofit; don't silently do one).

## Core rule

Every sub is either `mode: auto` or `mode: manual`. Never interleave: all auto
subs get a lower `order` than all manual subs. A manual sub is a **permanent
gate** in `pm run-epic` - it's skipped on every run (no worker spawned, status
untouched) until the human does the work and moves it to done themselves.

## Process

### Step 1: Gather the breakdown

Work out the subs and their natural technical order with the user (e.g. types
-> hooks -> component+perf test -> screen wiring -> visual verification).
Never invent scope beyond what's been discussed in the conversation.

### Step 2: Classify each sub as auto or manual

For each sub, ask: can "done" be reduced to a single command with a pass/fail
result (`yarn type-check`, `yarn test <path>`, `yarn validate`, `go test ./...`, etc.)?

- **Yes** -> `mode: auto`. The task's `ac` field MUST be that literal command,
  not a prose description.
- **No** (needs eyes on a simulator, a Figma/design comparison, a product
  judgment call) -> `mode: manual`.

If unsure, or the AC can't be written as a command, default to `manual`. Never
force a visual/judgment task into `auto` just to keep the auto count high -
that's what tanks the executor's success rate.

For each `auto` sub, also pick the model (token economy, pm-cli 0.21.1+):
tag TRIVIAL subs with `model: sonnet` (copy/color/one-prop tweaks - "the spec
basically contains the diff"); leave empty (= run-level model, opus) for
investigation or multi-file work. When unsure, leave empty.

#### An AC that names a device or a simulator model is never an auto sub's AC

A headless worker drives no runtime. It has no simulator, no device, and no way
to look at a screen - so an AC that names a **specific device or simulator
model** ("verify on an iPhone SE 3rd gen", a `com.apple.CoreSimulator...`
device type, "check on a physical device", "confirm on the smallest screen") is
not something an auto sub can ever satisfy. Either the whole sub is `mode:
manual`, or the device verification splits off into its own manual sub that
depends on the auto one that wrote the code.

This is the same criterion as Step 2's pass/fail question, narrowed to the one
case that keeps recurring, because it is the expensive kind of misclassification:
the worker CAN do the code half, so it works for the full hour and then parks
itself on the half it never could.

Measured on `orbit-114-1` (2026-08-11, a date-picker clipped on small
screens), created as auto: `blocked` after **120 turns, 44 minutes and $23.75** -
the most expensive live failure in the retro window. Its note, verbatim:

> TODO: prove the fix on an iPhone SE 3rd gen sim (com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-ge

The project's own profile already says where that work belongs: `pm executor
show orbit` reports `handoff.runtime_skill: simulator-verify`, i.e.
runtime verification is a human/acceptance phase by configuration, not something
a sub's AC can borrow.

How to catch it while writing the AC: the AC names a model, a UDID or "physical
device"; or the change's correctness depends on a screen size, a hardware
capability or an OS version the worker cannot instantiate. Either way the code
sub keeps a scoped, commandable AC (the test, the type-check) and the proof on
the device becomes the manual sub.

#### A repo-wide gate as the AC requires the project to have `executor.baseline`

Sort the ACs you just wrote into two kinds:

- **scoped** - it exercises only this sub's own diff (`yarn test
  src/hooks/useFoo.test.ts`, `go test ./internal/storage/`)
- **repo-wide** - it validates the WHOLE repo regardless of what the sub
  touched (`yarn validate`, `make check`, `go test ./...`, `yarn lint`)

If ANY sub's AC is repo-wide, check the project ONCE before creating the subs:

```sh
pm executor doctor <slug>     # warns explicitly when `baseline` is unset
pm executor show <slug>       # prints the value it resolved
```

**`baseline` unset + a repo-wide AC = report it and do not create the subs
yet.** The fix is one line in `project.yaml` (usually the same command as the
AC), and it is the user's call, so state it and wait.

Why this is a hard condition and not advice: `baseline` is captured once per
run and injected into every worker prompt as "any failure you see is NEW".
Without it, a repo-wide gate that is already red on pre-existing breakage
elsewhere in the repo reads to the worker as damage it caused. It then spends
turns diagnosing someone else's lint errors and parks itself. Measured on runs
`orbit-62` and `orbit-63` (2026-07-23): **8 subs, 0 green,
$44.25**, every one with the literal AC `yarn validate`, and a representative
worker note reading "`yarn validate` (the literal AC) fails, but ONLY on
pre-existing errors in files outside this branch's diff". The work itself was
done in nearly every case.

A scoped AC does not need this - it only runs what the sub touched, so
pre-existing breakage elsewhere cannot reach it. Preferring a scoped AC is a
legitimate second way out, when one exists that genuinely proves the sub.

#### Size every auto sub against the 120-minute default timeout

The worker's default `--timeout` is 120 minutes (pm 0.54.1; it was 60 before,
and the VPS runner keeps the old 60 until its binary is redeployed). Even the
old ceiling sat INSIDE the distribution of real sub durations rather than safely
outside it: across 74 worker-backed subs the median was 14.1 minutes, but three
(`pm-cli-57`, `pm-cli-72-1`, `orbit-1-2`) died at exactly ~3600 s and one
(`pm-cli-74-1`) merged at 3530 s - 70 seconds from the then-wall. The raise
buys headroom for the long tail, not a licence to leave a document-shaped sub
unsized.

For each auto sub, ask: **does this sub end in a diff, or in a document?**

- ends in a diff, touching a known set of files -> the default is fine
- ends in a **document or a survey** (research, a test plan, an audit, "go
  through every call site") -> either split it into a bounded piece with a
  concrete deliverable, or say in the report that this sub needs `--timeout`
  raised above the default

Never leave a research/planning sub on the default silently. `orbit-106-3`
(writing a test plan) took 149 turns and 54.6 minutes - it landed, with 5
minutes to spare, by luck rather than by sizing.

Read a wall hit correctly when it happens: the manager records the sub as
`failed`, but the journal still records a branch for it (all three of the above
have one), because the worker had been committing as it went. That is truncated
work, not a task the worker could not do - so the fix is sizing or `--timeout`,
never rewriting the spec on the strength of the failure.

Do NOT propose raising pm-cli's default timeout again. It was lifted once
(60 -> 120 min, 0.54.1) on the strength of those hits; every further raise
lengthens every genuinely hung run, so a sub that still threatens the ceiling
is a sizing problem or a per-run `--timeout`, never a new default.

#### Size every auto sub against the review round cap

The round cap does NOT scale with the size of the change. Only the number of
reviewers does. So a sub big enough to attract three reviewers gets the same two
rounds as a one-line fix, and a big sub exhausts the cap structurally - not
because the worker did anything wrong.

What pm scales and what it does not (`internal/cmd/review_cap.go`):

- **reviewers scale**: up to 2 production files and 50 changed lines -> 1
  reviewer; up to 10 files and 400 lines -> 2; beyond that -> 3.
- **rounds do not**: the cap is the project's `fix_rounds` (default 2), and
  `effectiveFixRounds` only ever LOWERS it (its single case: a doc-only diff ->
  1 round). Nothing raises it.

And the worker's contract at the cap (`internal/cmd/work_prompt.go`, verbatim):
"If valid findings remain at the cap, STOP and return status `blocked` with them
in `unresolved`."

In practice almost every measured sub reaches the cap: 28 rounds over 15
measured subs in `orbit` (1.9 average) and 9 over 5 in `pm-cli` (1.8).
`orbit-114-1` is what running out looks like, verbatim:

> REVIEW DID NOT CONVERGE: the final mechanism (explicit detent) was written to answer round-2's finding that the previous fix was a no-op, so it landed after the review round cap and has had NO adversarial review.

So at prep time, for each auto sub: if you expect the diff to land in the top
band (more than ~10 production files or ~400 changed lines), split it into subs
that each fit in two rounds. A split sub is also a smaller diff per reviewer,
which is the other half of the same win.

Do NOT propose raising `fix_rounds`. A confirming round is a round spent on
nothing (an adversarial reviewer almost never returns an empty list), and the
lever this skill owns is the size of the sub, not the length of the loop.

#### A document sub gets a shape budget in its AC

A sub that ends in a document is the most expensive kind of sub there is, and
the reason is not the writing. In epic `orbit-106` the two document subs
cost **$58.92 of the run's $89.09 (66%)** while the implementation cost $30.17.
The transcript of the worse one (`orbit-106-3`, $40.38, 149 turns) splits
cleanly: the 656-line test plan was written and committed **11 minutes** into a
55-minute sub, and the other 43 minutes were the review loop.

pm-cli 0.39.0 took the review half: a diff whose every changed file is prose
gets ONE reviewer and ONE round, whatever its length, and that reviewer is
briefed to check the document's claims against the repo rather than argue about
prose. You do not have to ask for that and cannot raise it.

What is still unbounded is the **document**. A worker with 120 minutes and no
stated length writes to the limit - roughly 150 lines of that 656-line plan were
its own restatement of setup steps the project's `simulator-verify` skill
already owns. So every document sub's `ac` states, concretely:

- **a length ceiling**, as a checkable command where possible:
  `test $(wc -l < docs/x/plan.md) -le 200`
- **reference, do not restate** - name the skill, README or doc that already
  owns the setup/preconditions, and say the document links to it instead of
  copying it. A copy goes stale; the reference does not.
- **who reads it and what they must be able to do** ("a human at the simulator
  running each scenario", "the next auto sub, which needs the decided data
  shape") - this is what stops a research doc growing a section nobody ordered
- **what it must NOT contain**, especially anything another sub produces

Cross-check with the sub that CONSUMES the document: if the consumer is the next
auto sub, the document only has to carry what that sub's spec cannot. If nothing
consumes it, ask the user whether it needs to exist as an executor sub at all -
a document written in the session you are already in costs a fraction of a fresh
headless worker rebuilding the same context from zero.

### Step 3: Enforce auto-sub self-sufficiency

Before writing an `auto` sub, verify it has zero dependency on this
conversation - a headless worker will see only what's in the task:

- The Spec's `## Open Questions` must be empty. Resolve anything unresolved
  right now with the user, or move the sub to `manual` - never leave "ask
  user" / "TBD" / "decide later" inside an auto sub's spec.
- The Spec names exact file paths, the type/interface names already decided,
  and an existing pattern/component to follow as reference.
- No unresolved design decisions inside the sub - those get resolved with the
  human (design/product owner) before the sub is written, never deferred into
  the prompt.
- A product/data-shape decision goes into the spec as DECIDED only if it was
  verified against the authoritative source at prep time (e.g. grep the BE
  enum/endpoint in the reference repo). Single-repo evidence is not authority.
  If it can't be verified now, phrase the sub "investigate, don't assume"
  (hypotheses, not a mandated variant), and any default MUST carry an escape
  hatch: "default X, BUT if <cheap check> refutes the premise, follow the
  evidence". Closed assumptions ("przyjmij X, alternatywa odrzucona") suppress
  worker verification even when it's cheap (ACME-1305/72h lesson).

`manual` subs are exempt from this - a human works them live with CC, so they
can reference PRs/branches from the completed auto subs, ask to compare
against a Figma link, etc.

### Step 4: Order and wire dependencies

- Set `order` so every auto sub sorts before every manual sub (e.g. 10, 20, 30
  for auto; 100, 110 for manual).
- Set `depends_on` to the real technical dependency, not just position - a
  manual sub typically depends on the last auto sub(s) it verifies.
- Sanity-check: no cycles, and no sub depends on another sub with a higher
  `order` than itself.

### Step 5: Create the tasks

Create the parent tracker first if it doesn't exist yet (`pm_add_task` with no
`parent`). Then create each sub with `pm_add_task`, setting `parent`, `mode`,
`order`, `depends_on`, `ac` (a literal command for auto subs), and a `spec`
that satisfies Step 3 for auto subs.

### Step 6: Report back

Print a short table (sub id, mode, order, depends_on, one-line AC). Call out
any sub you defaulted to `manual` because its AC couldn't be reduced to a
command, so the user understands why the auto/manual line landed where it did.

Four things from Step 2 must appear here explicitly rather than being assumed
handled - each is a decision the user may want to make differently:

- **the baseline verdict**, whenever any AC is repo-wide: either "`baseline` is
  set to X" or "`baseline` is NOT set - these subs will misread pre-existing
  breakage as their own"
- **any sub flagged as timeout-risky**, with what you propose: split it, or run
  with `--timeout` above the default
- **every sub whose verification needs a device or a simulator**, named as such,
  so it is visible that the proof was moved to a manual sub rather than dropped
- **every sub you split because its diff would not fit two review rounds**, with
  the split you chose

## Example

| Sub | Mode | Order | depends_on | AC |
|---|---|---|---|---|
| feat-1 | auto | 10 | - | `yarn type-check` passes for new types |
| feat-2 | auto | 20 | feat-1 | `yarn test src/hooks/useFoo.test.ts` passes |
| feat-3 | auto | 30 | feat-2 | `yarn validate` clean on new component + `.perf.tsx` |
| feat-4 | manual | 100 | feat-3 | Visual check on simulator against Figma; human moves to done |

## Out of scope

- Auditing or reclassifying an already-created tracker's subs.
- Whether `pm run-epic` itself should gain a stop/resume flag - that's a
  pm-cli feature question, not something this skill decides.
- The TUI board's rendering of `mode` - unrelated to task creation.
