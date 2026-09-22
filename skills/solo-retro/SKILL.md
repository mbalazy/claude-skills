---
name: solo-retro
description: Reviews one solo run afterwards - computes cost, time, compaction placement and the procedure trace from the artifacts the shift left (state file, report, transcript, solo journal), answers whether the shift kept to its procedure, and proposes concrete changes to the solo skill, the autocompact window or the project's setup. Sibling of executor-retro for the unattended-session mode. Use when the user says "/solo-retro", "retro solo", "jak poszło solo", "co poprawić w solo", "ile kosztował solo run", or comes back after a solo run and wants to know what happened before reading the report.
---

# Solo Retro

Closes the loop for `solo`: the shift leaves artifacts on its own
(state file, report, transcript, journal); this turns them into decisions.
Numbers first, judgement second, changes only with the user's ack.

## Step 1: The numbers

```
python3 ~/.claude/skills/solo-retro/scripts/retro.py [<shift-id>|latest] [--project <slug>]
```

It finds the state file under `~/.claude/pm/<slug>/.shift/`, the report next
to it, the transcript by shift id (both config dirs) and the project's
`solo` journal, and prints per task: minutes, API calls, tokens,
estimated cost, compactions that fell inside the task; for the shift: totals,
average context, every compaction with its position relative to the tasks,
guard blocks, over-budget ticks, and a procedure trace (task-start/task-end
lines, reviewer spawns, brief updates, journal writes, shift-close). `--json`
for the raw shape. No transcript found = say so; the state file and report
still answer most of it.

## Step 2: Four questions, in this order

1. **Cost** - per task and per shift; compare against the interactive
   baseline the user knows (a session with the user present does ~3 subs for
   $50-75) and against what this task would have cost as a batch sub plus
   its acceptance. Name the expensive task and what ate it (runtime rounds,
   review, a rig fight).
2. **Time** - minutes per task against the 120-minute budget; which step
   took the time (read the report's section 5 and the state file's Log);
   parked tasks and why.
3. **Compaction** - how many, and WHERE: between tasks (harmless by design)
   or inside one (the case the state file exists for). For each inside one,
   read the transcript around the boundary: did the session re-read the
   state file and `prompts/task.md`, did it redo or skip a step (a branch
   created twice, a gate run twice, a review missing)? This is what decides
   the `--autocompact` window in the launch abbreviation: compactions inside
   tasks -> raise (400k); none all night -> the window can drop (250k).
4. **Procedure** - did every task leave every mark: task-start and task-end
   lines, one reviewer spawn, a brief in the four plain lines, a task Log
   block, the journal entries at close, `shift-close.sh` last. A guard block
   is a fact to read closely: what did the model try, and what did it do
   next (record and move on = good; a workaround = a rule for the prompt).
   Read the report's section 1 as the returning user: any line that needs
   the spec to be understood is a defect to name.

With one shift, report observations, not statistics, and say so.

## Step 3: Recommendations, mapped to the lever

- **autocompact window** (the launch abbreviation in the user's shell config): from question 3 only.
- **solo prompts** (`~/.claude/skills/solo/prompts/*.md`): a
  step that left no mark, a decision the model kept re-deriving, a runtime
  reading taken without both controls.
- **guard / scripts** (`~/.claude/skills/solo/scripts/`): a block that
  should not have happened, a write that should have been blocked (check
  with `guard.py --explain`).
- **project setup** (`project.yaml`, MCP registration, journals): what
  onboarding-projects should have caught.
- **the task specs** (`batch-prep` Step 4 shape via `prompts/intake.md`): a
  task that failed on a missing precondition, not on the work.

Propose only. Then, with the ack: apply the edits, and record the retro as
ONE journal entry (`pm_journal_add` on `solo`, tag `review`) that
`resolves` the shift's entries whose fixes actually landed - the journal is
append-only, an open entry closes only through a later one.

## Out of scope

Reviewing the code the shift produced (that is the morning PR review),
re-running tasks, closing tasks or opening PRs.
