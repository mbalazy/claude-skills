---
name: parallel-guard
description: Warns Claude Code that another CC session is running in the SAME git worktree and installs defensive rules for the rest of the session (never bulk-stage, verify branch before commits, re-read before edits, no worktree-wide destructive git ops). Use when the user says "/parallel-guard", "idzie druga sesja", "mam odpaloną równoległą sesję", "uważaj, druga sesja CC", or otherwise signals a concurrent CC session shares this working tree.
---

# Parallel Guard

Another Claude Code session is running in the **same git worktree** as you. From this point in the session, you operate defensively: assume files, the staging index, and the current branch can change underneath you at any moment.

## The one thing to understand

A single git worktree has **one working directory, one staging index, and one HEAD**. Two CC sessions in that same worktree share all three. Anything the other session does - edit a file, stage something, switch branches, stash - lands in the exact same place you're working. There is no isolation.

(If the two lines of work are genuinely independent, the real fix is a separate `git worktree` per session so nothing is shared. Mention this to the user once. This skill is for when they choose to share one tree anyway.)

## Rules for the rest of this session

### Editing files
- **Re-Read a file immediately before you Edit it.** Your cached view may be stale - the other session may have rewritten it.
- **If an Edit fails on an `old_string` mismatch, stop and assume the other session changed the file.** Re-Read, reconcile, and only then re-apply. Never brute-force the match or rewrite the whole file to force it through.
- If you run tests/build/lint, remember the source can shift mid-run; a surprising failure may be the other session mid-edit, not your change.

### Git - the dangerous part
- **Verify the branch right before every commit and push:** `git branch --show-current`. HEAD is shared - the other session may have switched branches, and your commit would land on the wrong one.
- **Never bulk-stage.** No `git add .`, `git add -A`, or `git commit -a`. The index is shared, so those sweep up the other session's staged files. Stage explicit paths you own.
- **Always `git diff --cached --stat` before committing** to confirm the scope is exactly your files and nothing else.
- **Never run worktree-wide destructive git ops:** `git reset --hard`, `git checkout .`, `git checkout -- <path>`, `git clean`, `git stash`. They rewrite files and HEAD under the other session and can wipe its uncommitted work.
- **Do not `git checkout <branch>` / `git switch`** without flagging it to the user first - it yanks the working tree out from under the other session.

### Reading a dirty tree
- If `git status` shows changes you didn't make, that's the other session's work in progress. **Do not revert, stage, or "clean up" those files.** Leave them alone.
- Track which files are *yours* this session and touch only those.

## On invocation

1. If the user named what the other session is doing (a branch, a feature, specific files), note those as **off-limits** and steer clear of them.
2. Print a one-line acknowledgment listing the active guards, then continue the actual task under these rules. Don't over-explain - just confirm the mode is on.

Example ack:

> Parallel-guard on. Shared worktree - I'll re-read before edits, stage explicit paths only, verify the branch before every commit, and avoid any reset/checkout/stash. Other session owns `feature/x` - staying off it.
