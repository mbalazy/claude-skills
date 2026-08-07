---
name: developing-features
description: Takes a feature from a ticket or a description through spec, implementation, live verification and PR, in a React Native / Expo repo. Use when the user wants to build a feature, implement a ticket, add functionality, names a ticket key to build, or says "/developing-features". Phases - spec, build, ship. Supports --yolo for continuous runs. Generic across projects; reads per-repo config from .claude/developing-features/.
---

# developing-features

End-to-end feature workflow: **spec -> build -> ship**. Connects the ticket
system (entry) to runtime verification and the pre-PR gate (exit).

This skill owns the *workflow* only. The repo's own architecture document owns
the code patterns, and it is never duplicated here - the skill points at it.
Everything project-specific (ticket system, branch convention, validation
command, required test files, handoff skills) lives in the per-repo config.

## Setup gate (first thing, every run)

Look for `<repo-root>/.claude/developing-features/config.md`, falling back to the
legacy `<repo-root>/.developing-features/config.md` if only that one exists.

- **Missing?** Copy `references/config-template.md` there, fill in everything you
  can read out of the repo (`package.json` scripts, CI workflows, the
  architecture doc, `git remote`, the default branch, existing branch names in
  `git branch -a`), then ask the user to confirm the handful of facts a repo
  cannot tell you: the ticket system, the board state names, and which skill or
  command is the pre-PR gate. Make sure the config is kept out of git - it
  accumulates ticket keys and account specifics. Excluding it locally (via
  `.git/info/exclude`) beats a `.gitignore` entry, which itself announces the
  directory to everyone else on the repo. Note that a local exclude hides the
  file from git but NOT from repo-wide tooling: a `prettier --check "**/*.md"`
  or an eslint sweep still walks into it, which is the reason the config now
  lives under `.claude/` - repos already ignore that path in their formatter and
  linter config.
- **Present?** Read it before doing anything else. Every value below marked
  *(config)* comes from it. Keep it current: a convention you had to discover
  goes back into the config, not into this skill.

If a *(config)* value you need is missing or still a placeholder, ask for that
one value rather than guessing - a wrong base branch or a wrong validation
command costs a rebuild or a red CI, and guessing here is how a "generic" skill
quietly becomes wrong everywhere except the repo it was written in.

## Quick start

1. `/developing-features <TICKET-KEY>` or `/developing-features "add X to the Y screen"`
2. The skill writes a spec, builds it checkpoint by checkpoint, verifies it
   against the running app, and hands off to the pre-PR gate.
3. Add `--yolo` to run continuously without pausing between checkpoints.

Invoked with **no feature at all**? That is the config check - see below. Do not
guess at what to build.

## No feature given: check the config against the repo

With no ticket and no description, do this instead of asking what to build:
**re-derive every value in `config.md` and report where it disagrees with the
repo.**

Start with the mechanical half:

```sh
scripts/check-config.sh          # from this skill's directory; takes an optional repo path
```

It gathers evidence and mostly does not judge. `[FAIL]` is a binary fact and
fails the run - a path that is not there, a script package.json does not have, a
base branch that disagrees with `origin/HEAD`. Everything else prints as `[info]`
for you to read, because a checker that adjudicates prose produces false alarms,
and one false alarm is how a checker gets switched off for good. Read the info
lines properly - the citation section in particular, which prints the line each
`file:line` reference currently points at. That is the part that rots silently as
the cited document gets edited.

Then do the half the script cannot: work through the remaining fields with their
`measure with:` commands, and judge the prose ones (PR body policy, squash
policy) against the cited lines. Report per value: matches / disagrees with what
the repo says / still a placeholder.

Then stop - propose the corrections and let the user decide. Do not edit the
config unasked, and do not touch repo config files (lint, test, CI) at all: a
value being wrong in this file is one problem, and a broken gate in the repo is a
different one with a different owner.

Why this is worth a whole mode: **this config is trusted blind by every later
phase.** It tells the build phase what command gates a commit and the ship phase
what a PR body should contain. Nothing else re-checks it, so without a deliberate
pass it goes stale silently, and staleness here does not announce itself - it just
produces work in a format nobody uses. The first real run of this skill found four
wrong values in a config written the day before, one of which had been wrong in
its predecessor since June and had been faithfully copied forward.

Also worth reporting while you are in there: a claim in the config that no longer
has a source (a CI workflow filename that does not exist, a threshold that appears
nowhere in the repo). A number with no source is not a fact, whoever wrote it.

## Phases

### 1. spec -> `prompts/spec.md`
Resolve the request (pull the ticket *and its comments* when a key is given),
read the real code it touches, write a checkpoint-driven spec to a git-ignored
location, create the feature branch. Proceeds straight to build - no approval
gate.

### 2. build -> `prompts/build.md`
Work checkpoint by checkpoint. Each checkpoint creates or edits real files
(structure is checkpoint 1), runs the validation command *(config)*, adds the
required test files *(config)*, and commits.

### 3. ship -> `prompts/ship.md`
Verify against the running app via the runtime verification skill *(config)*,
then the pre-PR gate *(config)*, then open the PR against the base branch
*(config)*.

## Phase detection

| State | Start from |
|---|---|
| No spec for this feature | spec |
| Spec exists, checkpoints incomplete | build (resume at first incomplete) |
| All checkpoints done | ship |

## Manual selection

```
/developing-features spec <TICKET-KEY>
/developing-features build {feature}
/developing-features ship {feature}
```

## Flags

- `--yolo`: never pause for optional confirmation; auto-commit each checkpoint;
  stop only on genuine ambiguity or a hard blocker.

## Rules that do not come from config

These hold in every repo, and each one is here because skipping it has cost real
time:

- **The live ticket beats every local copy.** A spec, a task tracker entry or
  your own memory of the ticket was frozen when it was written; you may be
  picking the work up days later. Re-read the ticket and its comments before
  specifying (see `prompts/spec.md` Step 0).
- **Read the code before specifying.** Fill the spec from files you opened, not
  from what a name suggests. Reuse before creating - check the repo's component
  registry or equivalent first.
- **Fix at the source.** Never disable a lint rule, never `@ts-ignore` /
  `@ts-expect-error`, never `--no-verify` to get past the validation gate. A
  suppression turns a five-minute fix into a defect nobody can find later.
- **Throwaway instrumentation is throwaway.** Anything added to observe
  behaviour - a hardcoded prop, a log line, an overlay - comes out before the
  commit, and `git status` has to be clean afterwards.
- **Nobody else's `done`.** Never close a ticket or a tracker task. Move it as
  far as the config's states say the flow owns (typically "in review") and stop.
  The human decides when work is finished.
- **One checkpoint, one commit.** A checkpoint that cannot be committed on its
  own is two checkpoints.
