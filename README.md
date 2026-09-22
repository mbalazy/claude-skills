# claude-skills

Claude Code skills for agent-driven development, built out of real sessions
rather than written up front. Four groups: unattended task queues over
[pm-cli](https://github.com/mbalazy/pm-cli), iOS simulator and Figma work for
React Native, browser verification for web apps, and a few general-purpose
helpers.

The point of a skill here is to replace guessing with observing. None of these
tells Claude what your app looks like or how your team works - they give it a
way to go and find out, and to prove a claim with a number instead of "looks
about right".

## What is in here

### Unattended work over pm-cli

These skills drive [pm-cli](https://github.com/mbalazy/pm-cli), a file-based
task tracker with an MCP server, a kanban TUI, a web cockpit and a headless
executor. Without pm they have nothing to read a queue from; without them pm's
"solo" and "batch" modes are a launcher with no procedure. Tested against
pm-cli **0.66.0** (see [`skills/solo/README.md`](skills/solo/README.md)).

| Skill | What it does |
|---|---|
| `solo` | Works a queue of tasks in ONE unattended Claude Code session - the user is away. Per task: cold start from pm, branch off the base, implement, gate, verify on the live runtime, one reviewer pass, brief + Log, next. Procedure and state live in files so auto-compaction loses nothing; a guard hook enforces the no-push / no-PR / no-done contract; the shift ends with one report for a cold reader. |
| `solo-prep` | Prepares (or audits) a pm parent + subtask queue that a solo session can run cold: runtime mode decided with the user, live sources pinned as dated copies, subs in the heading contract solo reads, readiness proved by `scripts/check-queue.py`. |
| `solo-retro` | After a shift: cost, time, where the compactions fell and whether the procedure was followed - computed from the artifacts the shift left, with concrete proposals for the skill and the project setup. |
| `epic-prep` | Splits one coherent feature into an executor-ready parent + subs for `pm run-epic`: auto vs manual subs, ordering, `depends_on`. Carries the measurements the rules came from. |
| `batch-prep` | Same for a batch of 2-10 unrelated tickets in independent mode: each sub on its own branch, pushed, finished by a human one by one. |
| `batch-finish` | The acceptance of ONE task after a batch run: verifies every ASSUMPTION the worker recorded with evidence, fixes refuted ones first, works the handoff, verifies on the runtime, preps the PR. Discovers the run itself, local or on a remote runner. |
| `batch-finish-auto` | The acceptance of a WHOLE batch, autonomously: watches the run, spawns a `batch-finish` agent per finished sub, owns the visual pass, leaves only judgement calls for the human. |
| `executor-retro` | Mines the executor journal for failure patterns, park reasons, durations and kill/crash rates, then proposes concrete changes. |
| `cleaning-pm-tasks` | Triages the tracker for cleanup with evidence per task (age, branch merged, PR merged, parent's status) and applies only what the user picks. |
| `timeline-bootstrap` | Seeds a project's timeline once from what the repo and the tracker already know - a state plus dated events and decisions, each citing its source. |
| `journal-review` | Reads a project's journals (the record of a repeatedly troublesome subsystem) before touching that subsystem. |
| `pm` | The `/pm` dispatch layer over the pm MCP tools: context, add, update, brief, done. |

### React Native / iOS

| Skill | What it does |
|---|---|
| `simulator-verify` | Drives a booted iOS simulator so a UI claim can be verified against the running app: launch the dev build, read the accessibility element tree, tap and swipe, take screenshots, read the app's own console logs, and measure alignment or spacing off a full-resolution screenshot. The measuring part is the reason this exists: a 1-2pt offset is a real defect that is invisible at a glance. Rule learned the expensive way: **one round of looking that does not settle a visual claim becomes instrumentation, not a second round of looking.** |
| `figma-pp` | Implements a Figma node as React Native code and verifies it on the simulator, with a mandatory step in the middle: every value from the design gets mapped onto something that already exists in the repo's design system before any code is written. |
| `developing-features` | Takes a feature from a ticket to an open PR in three phases - spec, build, ship. A checkpoint-driven spec from code it actually read, one committable checkpoint at a time behind the project's validation gate, then runtime verification and the pre-PR gate. |

Scripts worth knowing in `simulator-verify`:

| Script | What it does |
|---|---|
| `sim-ui.sh` | Simulator driver - launch, tap, type, swipe, dump the element tree, screenshot. WebDriverAgent over HTTP plus `xcrun simctl`. No MCP server needed. |
| `read-rn-logs.sh` | Reads the app's JavaScript console output straight from the simulator's system log. |
| `measure-element.py` | Given a screenshot and a region, reports how far off-center the content is, in pixels and points. A number instead of an opinion. |
| `measure-boxes.py` | For anchored overlays (popover, menu, picker): measures the anchor rectangle against the frame that actually rendered. |

### Web

| Skill | What it does |
|---|---|
| `web-verify` | The same idea for a web app: proves the dev server on the port serves the tree under test, opens the route in a headless browser, reads the accessibility tree and a screenshot, and reports PASS or concrete discrepancies. Playwright is installed once inside the skill directory (`npm ci && npx playwright install chromium` in `skills/web-verify`). |

### General

| Skill | What it does |
|---|---|
| `taking-over` | The contract for "I am leaving the computer, carry on": act without asking, decide by a fixed policy (reversible over irreversible, simpler over cleverer), keep everything local, end with a structured decision report. |
| `parallel-guard` | Defensive rules for a session that shares a working tree with another live session: never bulk-stage, verify the branch before every commit, re-read before every edit. |
| `commit-split` | Splits an accumulated working-tree diff into small logical commits with imperative messages, linked to the related pm task. |
| `claim-check` | Verifies every factual claim in a text about to leave the session (a PR description, a ticket comment, a report) with a fresh-context agent that never saw how the text was written. |
| `session-id` | Prints the current session id with a ready-to-paste handoff card for continuing the conversation on another device. |
| `humanizer` | Removes the signs of AI-generated writing from a text. A trimmed fork of [blader/humanizer](https://github.com/blader/humanizer) (MIT, license kept in the directory). |

## Install

```sh
git clone https://github.com/mbalazy/claude-skills ~/repos/claude-skills
cd ~/repos/claude-skills
./install.sh                              # user-wide: ~/.claude/skills
./install.sh --project /path/to/your/repo # plus the two repo-scoped skills
```

The installer creates symbolic links, so a `git pull` here updates every place
the skills are linked - no copying, no versions drifting apart.

It never overwrites anything. If a target already exists as a real directory
(say you already have your own `humanizer`), it says so and skips it.

`--project` links `simulator-verify` and `developing-features` inside that repo
as well. That is needed because `pm executor doctor` looks up a project's
runtime-verification skill by project path first. For plain Claude Code use,
the user-wide link is enough.

Requirements:

- Claude Code. The pm skills need [pm-cli](https://github.com/mbalazy/pm-cli)
  installed and registered as an MCP server.
- `simulator-verify` and `figma-pp`: macOS with Xcode command-line tools
  (`xcrun simctl`) and a booted simulator with WebDriverAgent installed. The
  two measuring scripts need Pillow and sort that out themselves - on first run
  they build a small venv at `~/.local/share/claude-skills/venv` (using `uv` if
  it is on PATH, otherwise `python3 -m venv`) and re-exec into it, because
  `pip install` into a Homebrew Python is refused under PEP 668.
- `web-verify`: Node and a one-time `npm ci` in its directory.

## Per-repo configuration

Each skill is generic and knows nothing about any particular app. Everything
app-specific lives in a config directory inside the repo, which the skill offers
to create from a template on first run:

- `simulator-verify` reads `<repo>/.simulator-verify/config.md` - bundle id,
  scheme, device, Metro port, screen map, deep links, which flows send a real
  SMS or email.
- `web-verify` reads `<repo>/.web-verify/config.md` - dev server command, port,
  routes, what "mounted" means for this app.
- `figma-pp` reads `<repo>/.figma-pp/config.md` - Figma account, URL scheme,
  assets path, design-system package, fonts.
- `developing-features` reads `<repo>/.claude/developing-features/config.md` -
  ticket system and its board state names, base branch and branch convention,
  the validation command, which skill or command is the pre-PR gate.
- The pm skills read the project's executor profile from pm itself
  (`pm executor show <project>`): base branch, runtime skill, verification
  command, worktree slots.

**Keep these directories out of git.** They fill up with real account data as
you work: test users, phone numbers, what the dev account actually contains.

A wrong value in one of these files is worse than a blank one, because the
skills trust them. They are written to ask when they hit a placeholder, so
leaving a placeholder is a valid answer and guessing is not.

## Conventions

- The skills cite the runs and tickets their rules came from, by date and
  shape, next to the rule they produced. They are kept on purpose: a rule with
  a real failure behind it gets followed, a rule without one gets argued with.
  Project slugs and ticket keys in those citations are fictional (`orbit`,
  `vega`, `ACME-1164`); the dates and the numbers are real.
- Nothing in this repository may name a real client, colleague or machine -
  same rule as pm-cli's, and the same fictional names.
- The pm skills carry Polish trigger phrases in their descriptions and write
  their reports in Polish: that is the author's working language, and the
  reports are read by a human, not by a tool. The procedures themselves are in
  English.
- Throwaway instrumentation is throwaway. Every overlay, log line and hardcoded
  prop comes out before the commit, and `git status` has to be clean.
- Nothing here starts Metro, boots a simulator or installs a build. That is the
  project's own tooling; these skills drive what is already running.
