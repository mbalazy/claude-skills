# Phase 3: ship

Confirm the feature works against the running app, pass the local pre-PR gate,
open the PR. This phase delegates - it does not re-implement checks.

Values marked *(config)* come from `<repo-root>/.developing-features/config.md`.

## Process

### Step 1: Verify against the running app

Invoke the runtime verification skill *(config)* against the feature's screen(s):
reach the view, confirm the new elements and behaviour are present and correct,
no errors. Any discrepancy goes back to build (`prompts/build.md`) and gets
re-verified.

If the project declares no runtime verification skill, do not silently skip this
step: say plainly that the change is unverified against a running app, and ask
the user to check it or to point at how it is done here. "It compiles" is not
verification, and a UI claim nobody looked at is the single most common thing to
come back after review.

### Step 2: Local pre-PR gate

Run the pre-PR gate *(config)* - a skill, a command, or nothing declared.

- **A skill**: invoke it and address every blocker it raises, at the source.
- **A command**: run it and fix what it reports.
- **Nothing declared**: run the validation command *(config)* one more time
  against the full diff and report what CI is expected to run, so the user knows
  what is not being checked locally.

No suppressions to get a gate green.

### Step 3: Open the PR - only on an explicit go

**Stop here and ask.** Report what is ready (branch, checkpoints delivered, Step 1
result, Step 2 result) and wait for the user to say open it. Do not push and do
not create the PR on your own initiative, and do not treat a green Step 1 and 2 as
the go-ahead - they are the precondition for asking, not the answer.

`--yolo` does **not** cover this. It suppresses pauses between checkpoints, which
are yours to make; a PR is outward-facing - it notifies reviewers, triggers CI
minutes, and moves a ticket on a board other people read. That is the user's call
every time, and a flag they set an hour ago is not consent for it.

Once you have the go:

- Push the feature branch.
- Open the PR against the base branch *(config)*, with the title format
  *(config)*.
- Follow the PR body policy *(config)*. Where the project keeps the why and what
  in the ticket, the body stays empty on purpose - do not generate a description
  section to fill space.
- Link the PR back to the local tracker task if there is one *(config)*, and
  leave its status alone.
- Move the ticket to the in-review state *(config)*. Do not push it further -
  QA, merge and done are the user's call.

## Output

Verified against the running app, locally clean, and either a PR open against the
base branch or a branch waiting on the user's go.

## Done

Report: branch, PR link (or that you are waiting for the go), checkpoints
delivered, ticket key. Do **not** mark the ticket or the tracker task done - that
is the user's call.
