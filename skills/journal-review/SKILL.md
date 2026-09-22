---
name: journal-review
description: Reviews a project's pm journal - the running record of a repeatedly-troublesome subsystem - clusters the open entries by shared cause, and proposes concrete fixes to the flow or tool that would stop them recurring. Applies only what the user picks, then records the review as one new journal entry that closes the entries whose fixes actually landed. Use when the user says "/journal-review", "przejrzyj journal", "co poprawić w [podsystemie]", "review journala", "zrób przegląd", or when a journal has accumulated open entries nobody has acted on.
---

# Journal Review

A pm journal collects incidents with a chosen flaky subsystem so they stop being rediscovered. This skill closes that loop: read the whole journal, find what recurs, propose the change that would end it, and record what was done.

Sibling of `executor-retro`, which mines the executor's own run journal. This one mines the subsystem journals (`pm journal`).

## When to Use

- The user asks for a journal review, or asks what to fix in a journaled subsystem
- A journal's open count has grown and nothing has acted on it
- After a stretch of work that kept hitting the same subsystem

## Process

### 1. Find the journals

```sh
pm journal list                 # project auto-detected from cwd
```

No journals declared → say so, show how to declare one in `project.yaml`, stop:

```yaml
journals:
    - name: sim-rig
      subject: iOS simulator rig - which sim, which Metro, which build
```

Several declared → ask which, unless the user named one.

### 2. Read all of it

```sh
pm journal show <name> --limit 0
pm journal stats <name>
```

Read every entry, not just the open ones - a closed entry records a fix that was tried, and a cluster that keeps reappearing after a fix means the fix was aimed wrong.

Find the newest entry tagged `review`: its date is the watermark. Report how many entries arrived since it, so the user sees what is new versus what has been sitting there.

### 3. Cluster by cause, not by tag

Tags are author-chosen and drift into synonyms; the `cause` and `false_conclusion` text is the real evidence. Group entries whose cause is the same mechanism or the same tool.

Rank the clusters by, in order:

1. **How many entries produced a FALSE CONCLUSION.** A subsystem that fails loudly is cheap. One that returns a confident wrong answer is what burns afternoons and sends people fixing imaginary bugs. This is the strongest argument a journal can make.
2. **How many entries share the cluster**, and whether they are still arriving after a previous fix.
3. **Recorded cost** (`cost_min`), where present. Treat it as a floor - most entries record nothing.
4. **Recency.**

### 4. Propose fixes, ranked by what they actually prevent

For each cluster, name the concrete change: which file, which tool, what it would do differently. Then classify it honestly, because these are not equivalent:

- **Best - the failure becomes impossible.** The tool derives what it was guessing, or refuses to proceed on ambiguity.
- **Good - the failure becomes loud.** It still happens, but it announces itself instead of returning a plausible wrong answer.
- **Weakest - a doc or a rule tells someone to be careful.** Flag it as weak out loud. A journal exists because doc-only guidance already failed; propose it only when the first two are genuinely impossible, and say why they are.

Ground every proposal in the entries. Do not invent a cause that no entry recorded, and do not propose a fix whose success depends on a human remembering something at the right moment.

If a cluster has no available fix (the tool cannot know, the platform is at fault), say that plainly and leave the entries open. An honest open entry beats a closed one with a rule nobody will follow.

### 5. Get the user's pick

Present the ranked clusters with their evidence and proposals. **Wait for an explicit choice.** Never start editing.

### 6. Apply and verify

Only what was picked. Verify each change by running it, not by reading it. An unverified fix must not be recorded as a fix.

### 7. Record the review as one entry

This is the whole point of the loop - the journal is append-only, so a fix decided today reaches a months-old entry only as a new event pointing back.

```sh
pm journal add <name> \
  --symptom "journal review <date>: <n> open, <k> clusters, acted on <m>" \
  --cause "<what the review found - the clusters and their evidence>" \
  --fix "<what actually landed, and where>" \
  --resolves <id> --resolves <id> \
  --tag review
```

Ids come from `pm journal show`. Then re-run `pm journal stats <name>` and show the user the new open count.

**Hard rule: `--resolves` only for entries whose fix landed AND was verified in this session.** Everything discussed, deferred, or "now documented" stays open. Closing an entry claims the problem is gone; a backlog cleared by optimism is worse than one nobody touched, because it stops arguing for the fix.

If nothing was applied, still record the review entry with no `--resolves` - the watermark is worth having, and "reviewed, nothing actionable yet" is a real finding.

### 8. Put the rule where rules live

A fix usually also produces a rule ("check X before Y"). That belongs in the tool's own doc or skill, not in the journal - the journal holds events, docs hold current truth. Write it there, and let the review entry's `fix` name where it went. Do not write the same lesson into both.

## Output

- Ranked clusters with the entries backing each one, and a proposal per cluster classified as impossible / loud / doc-only
- Whatever the user picked, applied and verified
- One new journal entry: the review record, the watermark, and the closure of what was actually fixed
- The new open count

## Example

```
# sim-rig - 10 entries, 7 open, last review: never

Cluster 1: sim-ui.sh returns plausible wrong answers  (3 entries, 3 false conclusions)
  20260803-413d  stale screenshot frame        -> "my taps are doing nothing"
  20260803-8f3d  tap takes points, not pixels  -> "the screenshot is stale"
  20260730-74da  elements mounts a lazy tab    -> "lazy: true is not working"
  All three: the tool answered confidently and was wrong. Nothing failed loudly.

  Proposal (makes it loud): sim-ui.sh screenshot compares consecutive frames and
  warns when identical; tap rejects coordinates outside the device's point bounds
  instead of passing silently; elements prints a one-line warning that it mounts
  every tab controller.

Cluster 2: the app runs code that is not your tree  (2 entries, 1 already fixed by rig-check.sh)
  ...
```

After applying cluster 1:

```sh
pm journal add sim-rig \
  --symptom "journal review 2026-08-10: 7 open, 2 clusters, acted on 1" \
  --cause "3 of 7 open entries were sim-ui.sh answering confidently and wrongly" \
  --fix "sim-ui.sh: frame-identity warning on screenshot, bounds check on tap, mount warning on elements" \
  --resolves 20260803-413d --resolves 20260803-8f3d --resolves 20260730-74da \
  --tag review
```
