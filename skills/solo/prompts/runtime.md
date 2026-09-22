# Runtime pass

You own the runtime alone for the whole shift - one simulator (or one dev
server and browser), one session, no lock protocol. What follows are the
rules under which a reading counts as evidence. They come from
`batch-finish` / `batch-finish-auto` (the acceptance skills) and are what
separates a verified task from a confident false PASS.

## Which tools

`pm executor show <project>` names the runtime skill (`simulator-verify` or
`web-verify`), its scripts, the rig skill (`starting-local-rig`) and the
playbook. The skill's SKILL.md holds the measurement and instrumentation
techniques and its per-repo config (`.simulator-verify/config.md`,
`.web-verify/config.md`) holds the screen map, deep links, ports, test data.
**Re-read the runtime skill's SKILL.md before the first runtime pass after a
compaction** - the re-injected copy is truncated and its scripts are unusable
without the numbered sections.

Slot ids and ports: in this mode you work in the MAIN checkout, so use the
main checkout's runtime (the config's default device / Metro port / dev
server port), not a worktree slot's. Export what the skill says a hand
session must export (`SIM_UDID`, `WDA_PORT`, `WEB_PORT`) from the config,
once, and write the values into the state file.

## Rig gate - no green rig check, no reading

Before EVERY round of observation - not only the first one of the shift, and
not only after something that could swap what the app runs (branch switch,
rebuild, Metro/dev-server restart, package install): the runtime skill's
`rig-check.sh` must print `RIG OK` for THIS tree. Never report an observation
from a session whose rig check did not pass; a `RIG DEAD` verdict, a silent
instrumentation or a `js-error` is a fact about the rig, never about the code.

**On the web, check the API too.** A dev server that has taken a series of hot
reloads can serve the page from cache with a dead API proxy behind it, and a
rig check that only GETs `/` calls that green: vega-247 (2026-09-21) spent ten
minutes and recorded one false CHANGED that way. Pass `--api-path <route>` for
the routes the screen reads (or put them in the project config's `api_probe:`
and rig-check takes them from there). **Two `RIG DEAD` verdicts in a row on
the API = cold restart of the dev server**, then the one-cold-start rule below
applies as usual.

**Rig down: one cold start per shift, then stop paying.** On `RIG DEAD`, read
the rig skill whole and run its procedure ONCE (status first, restart only
what reports down, install the newer build `rig-check` points at before any
rebuild). If the rig is still dead after that: runtime OFF for the rest of
the shift, every visual claim of every remaining task recorded UNVERIFIED
with the verdict text as the reason, the fact in the state file and the
report. The sim-rig journal says an incident averages 24 minutes with a human
present; unattended, a second attempt is how a night disappears.

## Timeouts

Every runtime command runs under `timeout` (`/opt/homebrew/bin/timeout`):
`timeout 120` for a driver call, `timeout 600` for a build / install / dev
server start - **600 is the ceiling for anything, a driver script of your
own included**: a script that needs more is a loop that should be several
commands with a look at the result between them. A command that times out
is reported as such - once. Do not retry a hung command more than once;
treat the second hang as rig down.

## Reaching a screen - one attempt, the config's path, ten minutes

The runtime config (`.simulator-verify/config.md` / `.web-verify/config.md`)
holds the screen map and the paths that were verified by hand. To reach a
screen, follow that path exactly, taps and coordinates included, checking
the screen after every step with the element tree, not with a wait. A path
the config does not document is not attempted: the screen is UNVERIFIED
("no entry point in the config for <screen>"). A documented path that does not land: at most ONE more try
from a fresh app state (kill + relaunch, the path again), then UNVERIFIED
("config path to <screen> failed at step <n>: <what the tree showed>") -
never a third path of your own invention. Ten minutes of wall clock per screen, total, is the cap; the
sim-rig journal's average for one unattended detour is 30.
Use `timeout` directly, never a wrapper script of your own: the permission
matcher strips `timeout`/`env`/`nice` and still sees the real command, but
a script hides it from the deny rules and the guard.

## A reading is evidence only with both controls

For every visual claim (from the AC's `## Verification recipe` when batch-prep
wrote one, else derived from the AC):

1. **Name the channel before looking**: measured delta in points/px, a
   number from the layout log, an element-tree probe, `measure`/`text` output,
   or a screenshot only when the claim is binary presence. "Looks right" is
   not a channel.
2. **Positive control**: reach the screen in the reporter's scenario (their
   kind of data, their steps) or the closest stand-in the config offers, and
   read the channel. Record the actual value.
3. **Negative control**: the same channel on a state where the claim must be
   false - another route/screen, the base-branch build, the element count
   that must differ. A claim without a negative control stays UNVERIFIED
   ("no negative control available: <why>"), never CONFIRMED.
4. **One round of looking that does not settle it escalates to
   instrumentation, never to a second round of looking**: a log line, an
   onLayout print, a probe - inside the budget, stripped before the commit.
5. Record: `OBSERVED: <screen> · <channel> · positive <value> · negative
   <value> · <evidence path>` in the task's Log and the state file; screenshots
   and tree dumps go under `~/.claude/pm/<slug>/.shift/evidence/<task-id>/`.

Verdicts: CONFIRMED (both controls agree with the claim), REFUTED (the
positive control contradicts it - reopen the build step for that point),
UNVERIFIED (could not reach, rig down, no negative control - with the reason).

## When the rig lied

A reading that later proves false (the negative control matches the
positive, a screenshot of the wrong tree, a stale bundle): `pm_journal_add`
on the project's runtime journal (`sim-rig` / `web-rig` - `pm_journal_list`
shows the declared names) with `symptom`, `false_conclusion`, `cause`,
`cost_min`, tag `false-reading`, `fix` empty. This is the only feedback the
next shift gets.

## Side effects

Records created on the dev account, fixtures on the simulator, contacts or
appointments added: list each in the state file under `## Cleanup` as
"skasowane" or "zostawione, skasuj jeśli zbędne". At the end of the shift
leave the runtime as the report says: which sim booted, which Metro / dev
server running on which port, which checkout it serves.
