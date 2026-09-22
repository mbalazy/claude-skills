---
name: batch-prep
description: Prepares a batch of 2-10 UNRELATED tickets as a pm-cli parent+subs epic in independent mode (`epic_mode: independent`) for `pm run-epic` - each sub runs best-effort on its own branch off the base, gets pushed, and the human finishes each task separately (sim verify, remaining 0-30%, per-task PR). Sibling of epic-prep (which is for ONE coherent feature on an integration branch). Use when the user wants to batch several unrelated tickets through the executor, says "/batch-prep", "przygotuj batcha", "wrzuć te tickety w batch", "odpal executor na tych N taskach", or "batch niepowiązanych tasków".
---

# Batch Prep

Prepares a batch of **unrelated** tickets for `pm run-epic` in **independent
mode**: one parent tracker with `epic_mode: independent`, one auto sub per
ticket. The executor drives the subs sequentially; each sub gets its own fresh
branch off the base branch, the worker delivers 70-100% best-effort, the branch
is pushed, and nothing is merged anywhere. The human then returns to every task
separately: validates the worker's recorded assumptions, does the manual pieces
(simulator verify, design judgment), and opens a per-task PR.

**batch-prep vs epic-prep:** epic-prep = ONE coherent feature, subs build on
each other via an integration branch, ends in one epic PR. batch-prep =
UNRELATED tickets, no integration branch, no epic PR, one PR per task later.
If the tickets depend on each other or touch the same feature, stop and use
`/epic-prep` instead.

## Process

### Step 1: Create the parent tracker FIRST - before any gathering

The parent's id is the **handoff token**: the user needs it to start the odbiór
session (`/batch-finish-auto <parent-id>`) in a SECOND window, and they want
that window open while the prep still runs. Nothing about the id depends on
ticket contents - pm allocates the next free number, and the ticket ids come
from this invocation. Creating the parent after gathering + screening made the
user wait 5-10 minutes for a number that can exist in the first 15 seconds.
So it goes first.

Create the parent via `pm_add_task` (no `parent`), title
"Batch: <ticket ids from the invocation> (<date>)", passing
`epic_mode: "independent"` in the same call (`pm_update_task` takes it too).
The MCP write holds the project lock, so a parallel session can't drop the
line.

**`finish_mode` goes in the same call.** When the user asked for an automatic
odbiór - "finish_mode - auto", "auto odbiór", "sam się odbierze", "idę spać,
ma być odebrane" - pass `finish_mode: "auto"` too (pm >= 0.41). It is a TASK
field, not a run flag: when the run ends, `pm run-epic` spawns a detached
`pm finish <parent>` on the same machine, which runs this same acceptance
procedure headless and `--no-sim` - the mechanical half happens overnight,
the visual queue stays for the human. Nothing asked = leave it unset (off).

If the invocation did NOT name the tickets (`/batch-prep` with the tickets
still to be agreed in conversation), do not stall on the title: create it as
"Batch: <date>" and rewrite it with `pm_update_task` once the list is settled.
The id is what the user is waiting for, not the wording.

**Always read it back** with `pm_get_task` and confirm the response carries
`epic_mode: independent` - and `finish_mode: auto` when you set it. If a
field is missing, the running `pm` binary predates the parameter (it silently
ignores unknown params) - then, and only then, fall back to hand-editing the
frontmatter: `ls ~/.claude/pm/<project>/<parent-id>-*.md`, add the line
`epic_mode: independent` (and `finish_mode: auto` if asked for), and tell the
user to `make install` in pm-cli. A tracker without
that line runs in INTEGRATION mode (epic branch + cross-ticket merges) -
exactly what this skill exists to prevent.

Then, **before starting Step 2**, print the handoff line - and WHICH line
depends on `finish_mode`. Never print both: a second acceptance window next
to an armed auto-chain is two acceptances racing on the same branches.

- `finish_mode` unset/off - the odbiór needs a human-started session, so hand
  it over now:

  ```
  Rodzic: <parent-id>
  Drugie okno, wklej teraz: /batch-finish-auto <parent-id> --sim
  ```

  That session is designed for this: a parent with no subs and no run yet
  makes it wait, not fail (batch-finish-auto Step 1).

- `finish_mode: auto` - the acceptance spawns itself when the run ends, so
  the line says NO second window plus where to look afterwards:

  ```
  Rodzic: <parent-id>
  Auto-odbiór uzbrojony (finish_mode: auto) - drugie okno NIEPOTRZEBNE.
  Po runie: raport ~/.claude/pm/<slug>/.executor/<parent-id>.finish.md, stan w `pm runs`.
  Wizualia potem: /batch-finish-auto <parent-id> --sim (rozpozna zrobiony odbiór, dociągnie tylko drain).
  ```

Repeat whichever line you printed in the final report as well.

**If prep aborts after this point** (a ticket unfit for the batch, an
unresolved decision, the `epic_mode` read-back missing), DELETE the parent with
`pm_delete_task` before reporting, and say the handoff line is void. It has no
subs, so nothing is lost - and a stray `epic_mode: independent` tracker parked
in `doing` is exactly what any "which batch is current?" lookup would latch
onto.

The parent body at creation is only the ticket ids plus this reminder block (so
no future session forgets the finishing step); per-ticket links and one-liners
get filled in after Step 2, and if Step 3 drops a ticket, rewrite the title
with `pm_update_task`:

```
## Po przejściu robota
Każdy sub domykaj przez `/batch-finish <sub-id>` - NAJPIERW weryfikuje
ASSUMPTIONs workera dowodowo (logi/network/dev API), dopiero potem TODO,
symulator i PR.
```

Status rollup is generated (`pm_context`) - never hand-maintain a status table.

### Step 2: Gather the tickets

Collect the 2-10 tickets with the user. For Linear tickets ALWAYS pull the full
description AND `list_comments` (comments are the source of truth, not just the
description). Capture everything into each sub's spec - the headless worker
sees ONLY what's in the task.

### Step 3: Screen each ticket for batch fitness

Reject (or warn about) tickets where the worker can realistically deliver well
under 70%:

- **Design-heavy / Figma-dependent** - headless workers cannot use
  interactive-auth MCP (figma). A ticket that is mostly "build this screen from
  the design" delivers 40-60% at best; flag it and let the user decide.
- **Blocked on a human decision** - if the core approach is undecided, resolve
  it with the user NOW or drop the ticket from the batch.
- **Same-files collision** - two tickets touching the same files won't conflict
  during the run (each forks fresh off the base) but WILL conflict later at PR
  merge time. Point it out; the user picks which one stays.

There are NO manual subs in a batch - the manual 30% lives inside each task as
the worker's handoff, not as a separate sub. Don't create verification subs.

### Step 4: Create one auto sub per ticket

The parent already exists (Step 1) - fill in its body now: one line per ticket
with the external ID/link, keeping the reminder block.

Each sub via `pm_add_task` with `parent` set, and:

- **`branch`** - ALWAYS set explicitly, following the project's convention
  (e.g. `me-login/acme-1234-short-slug`). Without it the branch falls back to
  `feat/<title-slug>`, which for a Polish title makes a mess.
- **`ac`** - a literal verification command (`yarn validate`,
  `yarn test <path>`, `go test ./...`), not prose. The worker's verify gate
  runs on it. Anything not command-checkable belongs in the handoff, not the AC.
  **If that command is a repo-wide gate** (`yarn validate`, `make check`,
  `go test ./...` - it validates the whole repo, not just this sub's diff),
  the project MUST have `executor.baseline` set. Check once for the batch:
  `pm executor doctor <slug>` warns when it is unset, `pm executor show <slug>`
  prints the value. Unset = report it and do not create the subs yet; the fix
  is one line in `project.yaml`, usually the same command, and it is the user's
  call. Without it the worker is never told what was already broken, so a gate
  that is red on pre-existing breakage elsewhere reads as damage this ticket
  caused. This is not hypothetical and it is not an epic-mode problem: runs
  `orbit-62` + `orbit-63` (2026-07-23) were BATCHES - 8 subs,
  0 green, $44.25, every AC the literal `yarn validate`, the work itself done
  in nearly every case and pushed.
- **Sizing vs the 120-minute default timeout** (60 min until pm 0.54.1) - a
  ticket whose deliverable is a document rather than a diff (research, audit,
  "survey every call site") is the shape that reaches the ceiling, and the
  ceiling sat inside the real distribution: median sub 14.1 min across 74
  worker-backed subs, but three died at exactly ~3600 s under the old
  60-minute wall - and all three were batch subs, so this is the
  batch flow's problem first, not the epic flow's. Split such a ticket or tell
  the user it needs `--timeout` above the default - never leave it on the
  default silently. A wall hit reads as `failed` with commits on the branch:
  truncated work, not an impossible ticket.
- **`spec`** - self-sufficient: exact file paths, decided approach, constraints,
  error messages verbatim, links. Zero "ask the user" / "TBD" - resolve open
  questions with the user before writing the sub.
- **The spec OPENS with two sections written for the acceptance report, not
  for the worker** - the acceptance copies them into the report the user reads
  cold, hours later, without remembering the ticket (batch-finish Step 7).
  Without them the acceptance writes that part from its memory of the code,
  which produced a report the user could not understand at all (orbit-159,
  2026-09-05: "NO. new_lead was forced, there was no real inbound-only client
  at all").
  - `## Bug as the user sees it` - ONE sentence, no code words: which screen,
    what the user does, what they see instead of what they expected. Written
    so the person who filed it would nod.
  - `## Reporter's scenario` - the concrete circumstances of the report, from
    the Shake report / ticket / comments: device and OS, build, which kind of
    account or data (a real client with a photo; a client who only ever called;
    a provider with 8+ services), and the steps. This is the scenario the
    acceptance must reproduce or explicitly say it did not - so name it here
    even when the ticket is thin ("unknown device, staging build X, no steps
    given" is a valid, honest entry).
  The technical `## Ticket` / `## Root cause` / `## Decided approach` sections
  follow as before; the two new ones are additions, not replacements.
- **Decisions baked into the spec** - a product/data-shape decision (which
  option set is canonical, what an enum accepts, what a field can hold) may be
  written as DECIDED only when verified against the AUTHORITATIVE source at
  prep time - grep the BE enum/endpoint in the reference repo, it costs
  minutes. Evidence from one repo only ("the settings screen doesn't list it")
  is NOT authority for what the system supports. Can't verify now? Then don't
  decide - write the sub "investigate, don't assume" with explicit hypotheses
  (ACME-1421 style), which measurably produces evidence-driven workers.
- **ASSUMPTION phrasing - never closed.** "Przyjmij wariant X, alternatywa
  odrzucona" suppresses the worker's own verification even when it's dirt
  cheap. Always leave an escape hatch: "default = X, BUT first <cheap check,
  e.g. grep the BE enum>; if it refutes the premise, follow the evidence and
  record what you found". Lesson ACME-1305: a closed spec decision removed the
  72h option on a false FE-only premise; the worker never opened the BE repo
  (0 reads in 36 turns) because the spec said the alternative was rejected,
  and even a reviewer-caught data-loss signal got papered over with a
  fallback guard instead of triggering premise verification.
- **`order`** - 10, 20, 30... (pure sequence; subs are unrelated).
- **`runtime: on` subs: the AC names BOTH controls per reading, and the
  negative one is CROSS-ROUTE or a count.** A worker records every runtime
  reading as `OBSERVED: ... positive control ... negative control ...`, and
  the acceptance refutes BY FORM any line whose negative control is `n/a`
  (batch-finish Step 2b) - the browser really looked, and the evidence is
  still unusable. For a presence-only claim on one route there is no natural
  negative on that route, so the spec must hand the worker one: another
  route that must NOT show the new element (`/privacy` has no "Get in touch"
  heading), or a count (`measure` returns exactly 6 boxes, no 7th). Lesson
  orbit-web-4 (orbit-web, 2026-09-08): 3 of 9 readings came back `n/a`
  because the recipe said "record both controls" without naming the
  negative; journal `web-rig` 20260908-27d0.
- **`depends_on`** - NONE between unrelated tickets. If you're tempted to add
  one, the tickets aren't unrelated - move them to `/epic-prep`.
- **`mode`** - leave empty (auto). No manual subs in a batch (see Step 3).
- **`model`** (0.21.1+) - token economy: `model: sonnet` is the DEFAULT for a
  well-prepped batch sub. If Step 4 did its job, the spec already names the
  files, the approach, and the verify command - executing a written-down plan
  does not need opus. Leave empty (= run-level model, opus) ONLY when the sub
  genuinely investigates: root-causing an unknown, design decisions left to
  the worker, or cross-repo premise checks. Calibration from pm-cli-36
  (2026-07-25, 5/5 green): sonnet subs cost $1-5, opus subs $12-28 - and the
  two opus subs whose specs carried a concrete plan would most likely have
  passed on sonnet at a quarter of the cost. An explicit `--model` on
  `pm work` still wins; in `pm run-epic` the per-sub tag wins over the
  run-level flag.

### Step 5: Verify and hand off the launch

1. Dry-run: `pm run-epic <project> <parent-id> --dry-run --additional` - the
   output MUST say `mode: INDEPENDENT` (proves the frontmatter edit took) and
   list every sub as `[READY ]` with the right branch.
2. Tell the user to launch from the board: select the parent -> `X` -> `#`
   (additional worktree, keeps their checkout free) -> `b` (background).
   Don't launch it yourself.
   The `#` slot only works if the base branch is NOT checked out anywhere else
   - a slot cannot take a branch the main checkout is sitting on, and the run
   dies seconds after starting (`git checkout <base>: exit status 128`). Check
   `git worktree list`; if the main checkout is on the base branch and clean,
   say so and point at the default (no-slot) launch instead.
3. Set expectations: subs run SEQUENTIALLY (~10-30 min each) - a 20-60 min
   window fits 2-4 subs; a bigger batch needs a longer window. Watch with `W`,
   kill with `K`.

### Step 6: Report

Print a table: sub id, external ticket, branch, order, one-line AC. Then tell
the user which variant fits what they are about to do - always both halves,
launch AND finish, because a batch nobody finishes delivered nothing:

| Situation | Launch | Finish |
|---|---|---|
| At the keyboard, watching | this skill, then launch from the board (`X` -> `#` -> `b`) | `/batch-finish <sub-id>`, one sub at a time |
| Leaving / going to sleep | `/batch-prep-run` (preps AND launches in one go) | `/batch-finish-auto <parent-id> --sim` in a SECOND session |
| Leaving, wants it self-accepted | `/batch-prep-run ..., finish_mode - auto` (or board `X` -> `&`) | none to start - the run chains `pm finish` itself; in the morning `/batch-finish-auto <parent-id> --sim` drains the visual queue |

`/batch-finish-auto` is the unattended path: it watches the run, spawns one
agent per sub as that sub lands, verifies the worker's assumptions with
evidence, and runs the visual pass itself. Do not hand-write a prompt for
this - name the skill. It can be started at ANY point from Step 1 onward
(that's why the parent is created first) - it waits for the subs and the run
to appear. Repeat the Step 1 handoff line here so the user does not have to
scroll back.

With `finish_mode: auto` the chained acceptance covers only the mechanical
half (it is `--no-sim` by design - a detached run never touches the
simulator), its spawn is best-effort (a failed spawn is one stderr line,
nothing retries), and a killed run or an account wall means no chain at all -
`pm runs` next morning is how the user finds out. PRs, merges and statuses
stay the user's in every variant.

Whichever finish variant runs: it pushes fixes onto the subs' own branches and
stops there. PRs, merges, statuses and closing tasks stay the user's calls.

## Out of scope

- Launching the run (user does it from the board).
- Opening PRs - always human, per task, after manual verification.
- Retrofitting an existing tracker to independent mode - that's one
  `pm_update_task` with `epic_mode: "independent"` plus `/epic-audit` for the
  subs, not this skill.
