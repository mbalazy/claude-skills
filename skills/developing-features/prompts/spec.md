# Phase 1: spec

Turn a request (a ticket or a description) into a checkpoint-driven spec, on a
feature branch, ready to build.

Values marked *(config)* come from `<repo-root>/.developing-features/config.md`.
Read it first if you have not already.

## Input resolution

- **Ticket key given** (the key format is *(config)*): fetch the issue through
  the ticket system's tooling *(config)*. Use its title, description and
  acceptance criteria. Branch name follows the branch convention *(config)*.
- **Description given**: work from it directly. If the project's convention is to
  always carry a ticket key, prefer one when it exists; otherwise use the
  fallback branch shape *(config)*.

If the ticket system's tooling is unavailable or unauthenticated, say so and
continue from the description rather than blocking.

## Process

### Step 0: Re-read the LIVE ticket + comments (source of truth)

**Before anything else, when a ticket key is given, fetch BOTH the issue AND its
comments, fresh.**

- Most ticket APIs return the issue and the comments through **separate calls**.
  Fetching only the issue is the common mistake and it silently loses the most
  valuable half.
- For tickets filed by a bug-reporting tool the description is boilerplate. The
  real context - decisions, copy, endpoint shapes, "this is front-end only for
  now", answers from product - lives in the **comments**. Always read them.
- **A local tracker task may be stale.** It was frozen when written. Treat the
  live ticket plus comments as the source of truth. If a task exists, compare:
  are there comments newer than the task's last update? Did a decision change,
  did an endpoint ship, did an "open question" get answered? **Surface any
  new or changed context to the user before specifying**, and reconcile the spec
  to the live truth - never carry forward an open question the comments already
  answer.
- Follow related or linked issues when the comments point at them ("same bug as
  X", "covered by Y").

### Step 1: Branch + signal start on the board

Create the feature branch with the exact command the config gives under "how to
create the branch". If you are already on the right feature branch, stay on it.

Use that command literally rather than a `git checkout -b` of your own: where a
repo insists on branching off the *remote* base, "the base looked up to date"
is not the same check, and a branch cut from a stale local base drags
already-merged commits into the PR and into every diff-based gate.

If a ticket key was given, move the ticket to the in-progress state *(config)*
now - that is the start-of-work signal, so the board reflects reality. Skip it
when the ticket is already in a started state. Never touch the board when working
from a bare description with no ticket.

### Step 2: Read the real code (do not assume)

Before specifying, open the files this feature actually touches. The repo's
architecture document *(config)* names the layout; use it to find:

- The closest existing screen(s) and component(s) - study the real file layout of
  the nearest match rather than inventing one.
- The data layer: does a query for this server data already exist? does a store
  slice already hold this UI state?
- The component registry or design-system index *(config)*, if the project has
  one - reuse an existing component before creating a new one.
- The shared types.

### Step 3: Write the spec

Use `templates/spec-template.md`. Fill every section from what you READ, not what
you assume. The implementation checkpoints are the key output - each one is a
committable unit, and checkpoint 1 is usually structure plus types plus data
wiring.

Write it to the artifacts path *(config)*, which is git-ignored. If you did
research worth keeping, put it in the research path *(config)*.

### Step 4: Track it locally

If the project uses a local tracker *(config)*, find-or-create the task for this
work. Search by the ticket key first; if a task exists, **update** it - never
duplicate. Otherwise create one with the ticket link, the spec summary, a
cold-start summary, the branch, and an in-progress status.

Attach the current session id if the tracker supports it, so the conversation is
recoverable later.

If the project has no local tracker, skip this step entirely - the ticket system
is then the only record, which is fine.

### Step 5: Proceed

Go straight to build (`prompts/build.md`). The spec is the plan of record - there
is no approval gate. The user interjects if they want to. Under `--yolo`, never
pause.

## Output

- Feature branch checked out
- A spec with checkpoints at the artifacts path

## Next

Proceed to Phase 2: `prompts/build.md`

## Error handling

| Condition | Action |
|---|---|
| On the base branch / dirty tree | Create the feature branch; if uncommitted changes exist, offer to stash |
| Ticket tooling unavailable | Continue from the description; note that the ticket was not pulled |
| Request too vague to spec | Ask one focused question, then proceed (do not stall) |
| A needed *(config)* value is missing | Ask for that one value; do not guess a branch, base or validation command |
