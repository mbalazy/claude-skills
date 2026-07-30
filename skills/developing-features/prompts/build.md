# Phase 2: build

Implement the spec checkpoint by checkpoint. This is the only phase that writes
code.

Values marked *(config)* come from `<repo-root>/.developing-features/config.md`.

## Prerequisites

- A spec at the artifacts path *(config)* with `### Checkpoint N:` entries. If it
  is missing, run `prompts/spec.md` first.
- On the feature branch.

## Resume detection

Read the spec. Find the first checkpoint not marked `[x]` and start there. If all
are `[x]`, go to `prompts/ship.md`.

## Per checkpoint

### 1. Implement against the repo's real patterns

- **File layout**: follow the layout the architecture document *(config)*
  prescribes, confirmed against the nearest existing example you read in Step 2
  of the spec phase. Copy the shape of a real neighbour rather than inventing a
  structure.
- **Use the architecture document's templates** for the project's own patterns -
  the component split, the data-fetching layer, store slices, styling and design
  tokens. This skill deliberately does not restate them; a second copy would
  drift from the first.
- **Imports** follow the project's convention *(config)* - path aliases, relative
  paths, barrel files or their absence.
- Reuse before creating, and prefer the design system's primitives over raw
  platform components where the project says so.

### 2. Required test files

If the project requires a test file per component or screen *(config)* - a
performance baseline, a snapshot, a unit test - add or update it in the same
checkpoint. Copy the shape from a real existing one. Where CI gates on it, a
missing file fails the build, so it is not optional cleanup for later.

### 3. Validate

Run the validation command *(config)*. Fix every error at the source - never
disable a rule, never `@ts-ignore` / `@ts-expect-error`, never `--no-verify`.

If the command reports failures in files you did not touch, they are almost
certainly pre-existing. Confirm that (check the base branch), say so, and do not
try to fix unrelated breakage inside this checkpoint - but never assume it
without checking.

### 4. Commit

Follow the commit convention *(config)*, including the ticket key where the
project uses one.

- Default: commit, note briefly what was done, continue.
- `--yolo`: auto-commit and continue without pausing.

### 5. Mark progress

Set the checkpoint to `[x]` in the spec.

### 6. Update the local tracker

If the project uses one *(config)*: append a one-line progress note and refresh
the cold-start summary, keeping the branch linked. Lightweight - this is
continuity for the next session, not a report.

## Stop only for

Genuine ambiguity or a hard blocker the spec does not answer: a real product
decision, a missing API, a build failure you cannot resolve. Otherwise keep
going.

## Output

All checkpoints implemented, validated and committed on the feature branch.

## Next

Proceed to Phase 3: `prompts/ship.md`
