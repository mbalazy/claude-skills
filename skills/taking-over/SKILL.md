---
name: taking-over
description: Autonomous work contract for when the user leaves the computer and hands over control. Claude acts without asking, makes decisions per a fixed policy, keeps everything local (no push/PR/merge; the user's own VPS runner counts as their machine and is fair game), and presents a structured decision report at the end. Use when the user says "/taking-over", "przejmujesz stery", "odchodzę od kompa", "działaj sam", "masz moją zgodę, działaj", "przejmij", or otherwise signals they are leaving and Claude should continue autonomously on the CURRENT task. For a QUEUE of several pm tasks to work through unattended, use solo instead (it carries this contract plus the per-task loop, the guard hook and the morning report).
---

# Taking Over

The user is leaving the computer. From now until they return, work autonomously: no questions, no waiting for confirmation. Their standing consent covers **how** to implement, never **what** to build - stay strictly within the current task's scope and AC.

The consent covers **this machine AND the user's own VPS runner** - see "VPS runner" below.

## Hard limits (consent does NOT cover these)

- **Everything stays local.** No `git push`, no PRs, no merges to any shared branch. Commit freely on the feature branch; the remote is untouchable.
  - Exception: the user explicitly wrote something like "możesz wypchnąć ten branch na remote" in THIS session - then pushing that one named branch is allowed. Nothing else (still no PR, no merge).
- No messages to people (email, Slack, Teams, comments on external systems). The user's VPS runner is NOT an external system - it is their own machine (see below).
- No destructive operations: no deleting branches, no hard resets discarding work, no removing files outside the task's scope, no editing pm task data beyond brief/body/links for the task being worked.
- No scope creep: no new features, no drive-by refactors, no product decisions. If the task turns out to require a scope decision, park that thread, note it as an open question, and continue with what IS in scope.

## VPS runner - covered by consent

The user's VPS runner - declared under `remotes:` in pm's `config.yaml` (`pm config show`); its ssh alias and its pm MCP server are named in the user's CLAUDE.md - is their own infrastructure, same standing as this machine. Acting on it IS within the handover:

- `ssh <runner>` for anything the task needs: reading logs and run-state, checking executor runs, running commands.
- The runner's pm MCP (e.g. `pm-<runner>`; tasks minted on the runner live there, not in local pm) - same read/write rules as local pm.
- Launching and monitoring executor runs there (e.g. via `/batch-prep-run-vps`), when running the batch remotely is part of the task at hand.
- Branch pushes to origin performed BY the VPS executor as part of its normal run flow are that mechanism working as designed, not a breach of the no-push rule. Claude itself still does not `git push`, open PRs, or merge - on either machine.
- The local hard limits apply on the VPS too: nothing destructive (no deleting data or branches, no killing runs not started this session, no server config changes beyond the task's scope).

## Decision policy

When hitting a fork (design choice, ambiguous spec, failing approach):

1. Prefer the **reversible** option over the irreversible one.
2. If both are reversible, prefer the **simpler** one.
3. If genuinely blocked (both options irreversible, or the choice changes scope): do NOT guess. Park it as an open question, switch to another workable part of the task, or stop and leave a clear report.

**Record each decision the moment it is made** - append a one-liner to a running list (scratchpad file or task Log), never reconstruct from memory at the end. Capture: the fork, what was chosen, what was rejected, and why.

## Checkpoints

- Commit early and often - small logical commits on the feature branch. Uncommitted work dies with a crashed session.
- At natural checkpoints (subgoal done, direction change), update the pm task: `brief` (where we left off) and `body_append` for significant events. Follow the standard brief format (Goal → Decisions → Dead ends → Status → Files).
- If the session is at risk of ending (context long, work wrapping up), save the brief FIRST, then finish the report.

## Final report (mandatory)

When the work is done - or when stopping for any reason - end with a report in exactly this structure:

```
## Raport z przejęcia sterów

**Stan:** [co jest zrobione / gdzie stanąłem i dlaczego]

**Podjęte decyzje:**
- [decyzja] - wybrałem X, odrzuciłem Y, bo [powód]
- ...

**Otwarte pytania:** [rzeczy które wymagają Twojej decyzji; "brak" jeśli nic]

**Do Twojego review:** [co warto obejrzeć okiem człowieka - konkretne pliki/commity/zachowania]

**Commity:** [lista hashy + jednolinijkowe opisy, branch]

**TL;DR:** [2-4 zdania: co zrobione, co nie i dlaczego, co TY masz teraz zrobić]
```

Write the report in Polish. The user reviews it and asks for corrections - so make the decisions section honest and specific, including the rejected alternatives. A vague report defeats the whole point of the handover.

**Style rules for the report** - the user may come back to it hours later, cold:

- Concise, zero filler - but conciseness comes from CUTTING low-value items, never from compressing sentences into fragments, abbreviations, or arrow chains (`A → B → fail`).
- No jargon and no shorthand invented during the session (internal codenames, "wariant B", "ten hack z rana") - the reader was not there. Spell things out: file paths, function names, error messages verbatim.
- Each bullet must be understandable on its own, without scrolling up through the session. If a decision needs context to make sense, give one sentence of context in place.
- A wall of text is as bad as telegraphic fragments: short complete sentences, one decision per bullet, and drop anything that doesn't change what the user would do next.
- **TL;DR goes LAST, always.** It is the part the user reads first when skimming, so it must stand entirely on its own: what got done, what did not (and why), and the single next action expected from the user. 2-4 full sentences, no bullets, no references to the sections above ("see Decisions"). Never skip it, even when the report is short.

## Arguments

Text after the invocation refines the contract for this session, e.g.:
- `/taking-over push ok` or "możesz wypchnąć ten branch" - lifts the push restriction for the current branch.
- Any other instruction ("skup się tylko na testach", "max 1h roboty") - treat as a scope constraint layered on top of this contract.
