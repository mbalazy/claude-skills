# mobile-claude-toolkit

Claude Code skills for React Native / Expo work on iOS. Three of them, built out
of real sessions rather than written up front.

The point of a skill here is to replace guessing with observing. None of these
tells Claude what your app looks like or how your team works - they give it a way
to go and find out, and to prove a claim with a number instead of "looks about
right".

## What is in here

### `simulator-verify`

Drives a booted iOS simulator so a UI claim can be verified against the running
app: launch the dev build, read the accessibility element tree, tap and swipe,
take screenshots, read the app's own console logs from the shell, and measure
alignment or spacing off a full-resolution screenshot.

The measuring part is the reason this exists. A 1-2pt offset is a real defect
that is invisible at a glance, and a screenshot cannot tell a wrong anchor apart
from wrong offset arithmetic. The skill carries a rule learned the expensive
way: **one round of looking that does not settle a visual claim becomes
instrumentation, not a second round of looking.** Colored overlays and layout
logging end in one iteration what eyeballing does not end in three sessions.

Scripts:

| Script | What it does |
|---|---|
| `sim-ui.sh` | Simulator driver - launch, tap, type, swipe, dump the element tree, screenshot. Uses WebDriverAgent over HTTP plus `xcrun simctl`. No MCP server needed. |
| `read-rn-logs.sh` | Reads the app's JavaScript console output straight from the simulator's system log, so nobody has to copy-paste from the Metro terminal. |
| `measure-element.py` | Given a screenshot and a region, reports how far off-center the content is, in pixels and points. A number instead of an opinion. |
| `measure-boxes.py` | For anchored overlays (popover, menu, picker) - measures the anchor rectangle against the frame that actually rendered. |

### `figma-pp`

Implements a Figma node as React Native code and verifies it on the simulator,
with a mandatory step in the middle: every value from the design gets mapped
onto something that already exists in the repo's design system before any code
is written. That step is what stops the drift where each screen gets painted
from scratch with a slightly different set of tokens.

Scripts export assets at the right scale, open a screen by deep link, and build
a side-by-side comparison for sign-off.

### `developing-features`

Takes a feature from a ticket to an open PR in three phases - spec, build, ship.
It writes a checkpoint-driven spec from code it actually read, implements one
committable checkpoint at a time behind the project's validation gate, then hands
off to runtime verification and the pre-PR gate before opening the PR.

It owns the workflow and nothing else. The repo's own architecture document keeps
owning the code patterns; the skill points at it rather than carrying a second
copy that would drift. Two rules in it come from real losses: the live ticket
plus its **comments** beat any local copy of it (most ticket APIs need a separate
call for comments, and that is where the decisions live), and instrumentation
added to observe something comes back out before the commit.

## Install

```sh
git clone <this repo> ~/repos/mobile-claude-toolkit
cd ~/repos/mobile-claude-toolkit
./install.sh --project /path/to/your/rn-repo
```

The installer creates symbolic links, so a `git pull` here updates every place
the skills are linked - no copying, no versions drifting apart.

It never overwrites anything. If a target already exists as a real directory
(say you already have your own `figma-pp`), it says so and skips it.

`--project` is optional and does one extra thing: it links `simulator-verify`
inside that repo as well. That is needed because `pm executor doctor` looks up
the runtime-verification skill by project path, not in the user-wide directory.
For plain Claude Code use, the user-wide link is enough.

Requirements: macOS with Xcode command-line tools (`xcrun simctl`) and a booted
simulator with WebDriverAgent installed.

The two measuring scripts need Pillow and sort that out themselves - on first run
they build a small venv at `~/.local/share/mobile-claude-toolkit/venv` (using `uv`
if it is on PATH, otherwise `python3 -m venv`) and re-exec into it. That is not
gold plating: the scripts were silently broken on the machine they were written
on, because Homebrew moved `python3` from 3.11 to 3.14 and Pillow stayed behind,
and `pip install` into a Homebrew Python is refused outright under PEP 668. An
ImportError in the middle of a verification reads like a bug in the script rather
than in the environment, and costs a session to work out.

## Per-repo configuration

Each skill is generic and knows nothing about any particular app. Everything
app-specific lives in a config directory inside the repo, which the skill offers
to create from a template on first run:

- `simulator-verify` reads `<repo>/.simulator-verify/config.md` - bundle id,
  scheme, device, Metro port, screen map, deep links, which flows send a real
  SMS or email.
- `figma-pp` reads `<repo>/.figma-pp/config.md` - Figma account, URL scheme,
  assets path, design-system package, fonts.
- `developing-features` reads `<repo>/.claude/developing-features/config.md` - ticket
  system and its board state names, base branch and branch convention, the
  validation command, whether every component needs a test file, and which skill
  or command is the pre-PR gate.

**Keep these directories out of git.** They fill up with real account data as you
work: test users, phone numbers, what the dev account actually contains. The
templates say so too.

A wrong value in one of these files is worse than a blank one, because the skills
trust them. They are written to ask when they hit a placeholder, so leaving a
placeholder is a valid answer and guessing is not.

Treat these files as living documents. A screen you had to find by trial and
error, a deep link that works, a flow that turned out to text a real customer -
all of it goes into the config so the next session starts where you finished,
not where you started.

## Conventions

- The skills carry ticket references (`ACME-1164`, `ACME-1287`, `ACME-1368`) next
  to the rules they produced. They are kept on purpose: a rule with a real
  failure behind it gets followed, a rule without one gets argued with.
- Throwaway instrumentation is throwaway. Every overlay, log line and hardcoded
  prop comes out before the commit, and `git status` has to be clean.
- Nothing here starts Metro, boots a simulator or installs a build. That is the
  project's own tooling; these skills drive what is already running.
