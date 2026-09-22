---
name: commit-split
description: Splits the current uncommitted working-tree diff into small logical commits (imperative messages, feat/fix/refactor prefixes) and auto-links them to the related pm task. Use when the user says "/commit-split", "rozbij diff na commity", "porozbijaj to na commity", "zacommituj to porzadnie", "checkpoint", or when a large uncommitted diff has accumulated and needs to become clean history.
---

# Commit Split

Turn a messy uncommitted working tree into a sequence of small, logical,
well-messaged commits - the executable version of the "commit early, commit
often" rule. Also usable proactively: when you notice a big diff piling up
mid-session, suggest running this.

## Process

### Step 1: Inventory

```
git status --short
git diff --stat
git log --oneline -10
```

- Note the branch (`git branch --show-current`) and the repo's commit-message
  conventions from recent log (prefix style, tense, scope tags). Match them.
- Untracked files: decide per file - source that belongs to a group, junk to
  ignore (never commit scratch/debug files), or something to ask about.
- If the repo has uncommitted changes you can't explain from this session's
  context, that's a signal another session or the user worked here - group by
  reading the diffs, don't guess from filenames alone.

### Step 2: Group into logical commits

- Group by **concern** (one feature / one fix / one refactor per commit), not
  by directory or file type. Tests and docs go WITH the change they cover,
  not in a separate "tests" commit.
- Order groups so the history reads causally: infrastructure/storage first,
  then features built on it, then docs. Each commit should build+test green
  on its own if feasible.
- Granularity: file-level. `git add -p` is interactive and unavailable -
  when one file genuinely mixes two concerns, put it in the dominant group
  and say so in that commit's body. Don't craft partial-file patches.

### Step 3: Propose the plan and WAIT

Present a table: commit message + files per group. Wait for the user's ack
before committing anything. Exception: the user explicitly asked to just do
it ("bez pytania", "yolo") - then proceed.

### Step 4: Execute

For each group, in order:

```
git add <explicit paths>       # NEVER git add . / -A / commit -a
git diff --cached --stat       # verify scope = exactly this group
git commit -m "<message>"
```

- Messages: imperative, concise, repo's prefix convention
  (`feat:`/`fix:`/`refactor:`/`docs:`...). Body only when a file mixes
  concerns or context is non-obvious.
- Never commit: secrets (`.env*`, keys, tokens), lock/debug/scratch files,
  binaries the repo doesn't already track. Flag them instead.
- After the last group: `git status` must be clean (or leave only the files
  the user said to skip - list them).

### Step 5: Link to pm

If a pm task relates to this work (check `pm_context` / the session's active
task), after committing run `pm_update_task` with:
- `branch`: current branch
- `body_append`: one line per commit - `<short-hash> <message>`

Skip silently if no related task exists - don't create one just for this.

### Step 6: Report

Print `git log --oneline` for the new commits + what was intentionally left
uncommitted and why. Don't push and don't open a PR unless asked.

## Guardrails

- Verify the branch before every commit (`git branch --show-current`) - if a
  parallel session may share this worktree, follow /parallel-guard rules.
- Never rewrite existing history (no amend/rebase of already-pushed commits)
  - this skill only creates new commits from the working tree.
- If the diff is small and obviously one concern, say so and make ONE commit
  - don't manufacture artificial splits.
