---
name: executor-retro
description: Mines the pm-cli executor journal (real logs of pm work / pm run-epic runs) for failure patterns, park reasons, durations, and kill/crash rates, then proposes concrete improvements to the epic flow (task specs, epic-prep rules, executor profiles, pm-cli itself). Use when the user says "/executor-retro", "przeanalizuj logi executora", "jak sobie radzi executor", "retro egzekutora", "co poprawic w executor flow", or after a batch of executor runs has accumulated.
---

# Executor Retro

Close the loop the executor observability was built for: real run history ->
patterns -> flow improvements. The data accumulates on its own (every run
journals itself); this skill turns it into decisions.

## Data sources

1. **Journal (primary):** `~/.claude/pm/<project>/.executor/journal.jsonl` -
   append-only JSONL, one line per event. `start` (run begins: kind, model,
   yolo/additional flags, branch, pid), `end` (per-sub outcomes: result/note/
   duration_s/session/turns/cost_usd + run duration; turns and cost come off
   the claude envelope, so effort per outcome is measurable), `killed` (board
   kill on the manager's behalf). A `start` with NO matching `end`/`killed` line = untracked crash
   (SIGKILL, reboot, OOM) - count those separately.
2. Run-state JSONs (`<project>/.executor/<taskID>.json`) - last/live state.
3. Worker logs (`<project>/.executor/<taskID>.log`) and transcript `.jsonl`
   (via each sub's `session` id) - deep-dive into WHY a specific sub failed.
4. Parent trackers' `## Manager Notes (cross-cutting)` - parked subs' bubbled
   reasons.
5. The parked subs themselves (`waiting` status) - their briefs/bodies.

Journal exists since pm 0.18 - if it's empty/missing, say so and fall back to
run-states + Manager Notes for whatever history they hold.

## Analysis

Scan journals across projects (or the one project the user named). Compute:

- **Outcome distribution** per sub result: merged vs blocked/failed/conflict
  vs skipped/manual. The headline: merge rate of attempted subs (exclude
  skips/manual from the denominator).
- **Failure clustering:** group `note` fields of blocked/failed/conflict subs
  into recurring causes (unmet spec, test env broken, merge conflicts, model
  gave up, timeout). Quote representative notes.
- **Kill & crash rate:** `killed` lines + start-without-end anomalies. Many
  kills = runs going visibly wrong mid-flight; investigate what the user saw.
- **Duration profile:** per-sub `duration_s` - median, and outliers near the
  45m timeout (timeouts often masquerade as failures). Whole-run durations.
- **Effort/cost weighting:** per-sub `turns` and `cost_usd` - a sub failing
  after 110 turns is a different diagnosis (spec too big / thrashing) than one
  failing after 8 (spec unclear / missing precondition). Flag the most
  cost-expensive failures first; they're where retro fixes pay back fastest.
- **Retry thrash:** same sub id appearing across multiple runs without ever
  merging - a sub the flow keeps failing at; those specs deserve a read.
- **Config correlations** (if sample allows): yolo vs not, additional
  worktree vs main checkout, model - any visible effect on merge rate.

Don't overfit single digits - with <10 runs, report observations, not
statistics, and say so.

## Output

1. **Scorecard** - runs analyzed (per project), merge rate, top 3 failure
   causes with counts, kill/crash count, duration medians + outliers.
2. **Findings** - each pattern with evidence (task ids, quoted notes).
3. **Recommendations** - concrete and mapped to the right lever:
   - *Task/spec level*: what epic-prep/epic-audit rules would have caught
     (AC not a command, open questions in auto subs...).
   - *Profile level*: `project.yaml` executor block (phases, timeout,
     start/done statuses, worktree env).
   - *Skill level*: rule changes for `/epic-prep` / `/epic-audit` - if the
     same avoidable failure recurs, the rulebook is missing a rule.
   - *pm-cli level*: feature/fix candidates -> propose as pm tasks.
4. Propose only - implement nothing (rule edits, pm tasks, config changes)
   without the user's ack.

## Out of scope

- Re-running failed subs or launching the executor - the user does that.
- Judging code the workers produced - this is flow retro, not code review.
