# Task contract for a solo queue

Content rules for the parent and its subs. `templates/example-sub.md` shows one
complete sub; `scripts/check-queue.py` enforces everything marked "checked".

## Heading contract (checked)

pm finds a section by its exact `## ` heading (case-insensitive), and the
runner's prompts look for these names. Use them verbatim, at level two, in this
order. Extra `## ` sections may follow (`## Sources`, `## Gate`), but a contract
heading is never renamed, merged or demoted: `## Context wspólny` is not
`## Context`, and `#### Context` is not either.

### Sub

| Heading | Read by | Content |
|---|---|---|
| `## Description` | solo `prompts/task.md` cold start | one reviewable result and how it serves the parent |
| `## Bug as the user sees it` | solo `prompts/report.md`, the `Bug:` line | one sentence, no code words; a feature: what the user cannot do today; purely technical: say so plainly |
| `## Reporter's scenario` | `prompts/runtime.md`, positive control | device, account, data, steps from the source; "not given" when absent; synthetic data named as a stand-in |
| `## Context` | `prompts/task.md` | parent id, repo, entry branch, then the shared block verbatim |
| `## Decided approach` | `prompts/task.md`, the reviewer | DECIDED / ASSUMPTION / INVESTIGATE / BLOCKED lines for this sub only, with provenance; approvals from SKILL.md Step 5 |
| `## Acceptance Criteria` | `prompts/task.md`, reviewer, report | checkboxes, each observable, with source ids (AC-21); error, empty and retry states when in scope |
| `## Verification recipe` | `prompts/runtime.md` | per material behavior: entry point, data and how it is selected, action, channel, positive control, negative control, command, evidence path |
| `## Open Questions` | report, `Przed PR-em:` | unresolved items with their consequence, or "none" |
| `## Next Steps` | `prompts/task.md` plan | checkpoint checkboxes; no count prescribed |

### Parent

| Heading | Content |
|---|---|
| `## Description` | the result, who it is for, why |
| `## Context` | sources with dates, base head, DECIDED lines (runtime mode, approvals, overrides of older sources with who/when/why), rejected alternatives with reasons |
| `## Pinned sources` | table: source, stable id or URL, version stamp, fetched at, local copy path |
| `## Queue and delivery` | per sub: result, order, depends_on, branch; stacked or independent; final MR/PR shape; blocked follow-ups |
| `## Shared constraints` | the canonical shared block |
| `## Acceptance Criteria` | every source criterion, mapped to its sub(s) |
| `## Verification and launch` | literal commands (gate, e2e, others), automated vs runtime, profile discrepancies, the launch block |
| `## Open Questions` | genuine blockers with owner and artifact |
| `## Next Steps` | not-yet-done steps ending at delivery |

A dated status table in the parent is a prep snapshot; pm's rollup is the live
state.

## Shared block (checked)

Common constraints that would cause a wrong implementation if a sub missed
them. The runner loads only the sub, so the sub must carry them; the markers
make the copies checkable.

```
<!-- solo-prep:shared:start -->
...
<!-- solo-prep:shared:end -->
```

Put the canonical copy in the parent's `## Shared constraints` and the same
text in every sub's `## Context`. The checker compares the text between the
markers after trimming trailing spaces and collapsing blank-line runs. What
goes inside:

- parent id, repo path, base branch; "read the parent Spec on cold start";
- authority limits: no push, PR, merge, done or external writes unless the
  launch flags say so; who opens the final MR/PR;
- the internal-id rule (SKILL.md Step 7.3), naming this project's prefix;
- pinned sources: paths, and "read the copy; do not re-pin mid-queue";
- runtime mode with its entry point (config path, port), or "code-only: visual
  claims UNVERIFIED";
- literal gate commands and required automated tests;
- repo rule files to obey, and recorded approvals;
- EXCLUDED items, each with its reason.

## Fields

- **Parent:** project (the code project's slug), title `<KEY>: <plain outcome>`,
  not-started status, branch (the accumulated branch if the plan has one),
  brief, spec, links (ticket, plan, pinned copies, related tasks, MR/PR),
  model, tags (no day/night), `ac`.
- **Sub:** parent, order, branch, depends_on, status (+ `waiting_for` when
  blocked), spec, brief, links, literal `ac`, model, tags.

**Brief at creation:** Goal / Decisions / Dead ends / Status / Files. Status
says "not started". The run overwrites the brief with the runner's four lines.

## An executable verification recipe

- Where the request runs (browser, server process, worker) and how the chosen
  scenario reaches that process. "Mock the next response" is not a mechanism.
- How each test isolates its data under retries and parallel workers, and which
  caches or prefetching could consume a response sequence.
- A negative control: another state, route or count where the claim must be
  false. "n/a" is not one; a claim without it stays UNVERIFIED.
- Planned evidence is not observed evidence. Anything observed during prep
  goes into the Log with its date.
- Reuse the accepted test mechanism. A control endpoint or shared mutable
  switch created only to satisfy a recipe is out of scope.
