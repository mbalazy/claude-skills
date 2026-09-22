# Readiness - the checks no script can make

Walk this after `scripts/check-queue.py` exits 0. Every answer must point at
text in the tasks.

## Faithful to the sources

- Every criterion from the ticket and the plan sits in some sub's AC, including
  the hard ones and the ones waiting on an external artifact.
- Every user decision and override is a DECIDED line with who and when; nothing
  the user rejected came back.
- Paths, contracts, reporter data, root causes and targets all come from a
  source; unknowns are INVESTIGATE or ASSUMPTION lines with a check.

## Decided before the run

- The user chose the runtime mode (SKILL.md Step 2).
- Every approval the repo reserves for its owner is recorded or was asked for
  (Step 5).
- Pinned version stamps were read again just before handoff (Step 4.4).

## Runnable by a cold session

- Each sub's result is reviewable on its own and carries its own tests; every
  split signal is resolved or justified (Step 6).
- Each recipe names where the request runs, how the scenario reaches that
  process, how tests isolate data under retries and parallel workers, and a
  real negative control.
- Nothing a sub needs lives only in this conversation or in a file the session
  cannot read.
- Blocked work is `waiting` with `waiting_for`; the handoff separates "runnable
  now" from "complete".

## Handoff

- The launch block matches the checker's base, runtime flag and model; `--push`
  and `--pr` appear only with the user's explicit word.
- A review-only request wrote nothing and lists the proposed changes.
