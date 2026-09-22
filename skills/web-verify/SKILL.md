---
name: web-verify
description: Verify a page or feature of a web app (Next.js, Vite + React, any dev server) in a live headless browser. Proves the dev server on the port serves the tree under test, opens the route, reads the accessibility tree + screenshot, and reports PASS or concrete discrepancies - as OBSERVED lines with controls inside an executor run. Use after implementing web UI, as the runtime step of a feature or bugfix flow, or when the user says "/web-verify", "sprawdź w przeglądarce", "zweryfikuj stronę X", "czy to działa na stronie". Generic across web projects; reads per-repo config from .web-verify/.
---

# web-verify

Reusable verification atom for any web app with a dev server. The browser
counterpart of `simulator-verify`: drives a headless Chromium to confirm a page
actually renders and behaves - not by reading the code, but by observing the
running app. Called standalone, or as the `runtime` phase of an executor run.

The skill is generic: everything app-specific (dev command, routes, test data,
outward-facing actions) lives in the per-repo config, never in here.

## Prerequisites

- **`scripts/rig-check.sh`** - proves the port serves YOUR tree. Run it before
  anything else (Rig gate). `--start` warm-starts the dev server when nothing
  listens; it never touches a server that belongs to another tree.
- **`scripts/dev-server.mjs`** - what rig-check wraps: `check | start | status | stop`
  of one tree's dev server on one port, detached, with an ownership check
  (the listening pid's cwd must be the tree).
- **`scripts/web-ui.mjs`** - the driver: `snapshot | text | html | screenshot |
  measure | console`, each one browser session that navigates, runs optional
  `--steps` (click/fill/press/wait/goto/eval) and prints what it saw. Run it
  with no args for the option list. No MCP server, nothing in the model's
  tool schemas.
- **Playwright, installed once in the skill dir** (`npm install && npx playwright
  install chromium` in `~/.claude/skills/web-verify`). When Playwright's own
  Chromium is missing the driver falls back to the installed Google Chrome
  (`channel: chrome`); `WEB_VERIFY_BROWSER=chrome|chromium` forces one.
- **In a git worktree, none of this exists locally.** The skill lives in
  `~/.claude/skills`, the config is git-ignored - so call the scripts by
  absolute path and point them at the tree under test: `<skill-dir>/scripts/rig-check.sh
  --repo <worktree> --port $WEB_PORT`. In a hand session export `WEB_PORT`
  (the slot's port) - `web-ui.mjs` derives its base URL from it and nothing else.
- **Inside an executor run (a `pm run-epic` / `pm work` worker) the slot env is
  ALREADY set** - `WEB_PORT` and `PM_API_PORT` are in your process, read them
  with `printenv WEB_PORT`. Do NOT `export` them and do NOT prefix a command
  with `WEB_PORT=... node ...`: the worker's allowlist is a literal prefix
  match on the command you type, and both forms are refused. Call scripts by
  their absolute path exactly as the `## Runtime rig` section of your prompt
  lists them - `/Users/<you>/.claude/skills/web-verify/scripts/web-ui.mjs ...`
  or `node <that path> ...` - never `~/...`, never `sh <script>` / `bash
  <script>` (each is a different prefix, and refused).

## Setup gate (first thing, every run)

Look for `<repo-root>/.web-verify/config.md`. It holds the dev command, the
route map (which pages need no data, how to get a valid link/hash), the
outward-facing actions to never drive, and the console noise that is not a
finding.

The keys the scripts read from it: the dev command and port, the route map,
and **`api_probe:`** - the API routes `rig-check.sh` GETs when the caller
names none (`- **api_probe**: \`/api/health\`, \`/api/pools\``; a plain
`api_probe: /api/health` or an indented `- /api/...` list is read too). Name
the routes the screens actually read; leave the key out and the rig check only
proves the page.

- **Missing?** Copy `references/config-template.md` there, fill what the repo
  tells you (`package.json` scripts, the `app/` or `pages/` tree, `env.example`),
  and ask the user to confirm the dev command and the backend situation before
  driving anything. Make sure `.web-verify/` is git-ignored - `.git/info/exclude`
  covers every worktree of the repo without touching the shared `.gitignore`.
- **Present?** Read it first. Keep it current: every route reached, every state
  recipe, every trap goes back in there, not in this skill.

## Rig gate (second thing, every run) - no green rig check, no report

A browser will happily read a page served by a DIFFERENT tree: the main
checkout's server on the port you assumed, another session's worktree, a
production build behind a proxy. Every one of those produces a normal-looking,
false reading. So before observing anything, prove the port serves your tree:

```
<skill-dir>/scripts/rig-check.sh --repo <tree> --port $WEB_PORT            # hand session: is it up?
<skill-dir>/scripts/rig-check.sh --repo <tree> --port $WEB_PORT --start    # hand session: warm-start it
```

`RIG OK: http://127.0.0.1:<port> serves <tree> (<branch>@<sha>) - pid N, GET / -> 200, h1 mounted ("...")`
is the only green. `RIG DEAD: ...` names the cause: nothing listening, the port
held by another tree's server (named, never touched - that is someone else's
session), the server not answering, a 5xx on the probe, or **served but the
app did not mount** - the check opens the route in the skill's headless
Chromium and requires `--mount SEL` (default `h1`) to render non-empty text,
because a 200 on `/` is not an app: a Vite kept running across an `npm ci`
served a blank page behind two green HTTP probes (2026-09-06, pm-cli-130).
Pass the selector the page's shell always renders (`--mount 'role=main'`,
`--mount '[data-testid=app]'`) when `h1` is not it; `--mount ''` is the old
HTTP-only check, for an API-only port.

**A live page is not a live API.** `GET /` reads no API, so a dev server whose
proxy died after a series of hot reloads keeps serving the page and the check
keeps saying RIG OK - vega-247 (2026-09-21) took one CHANGED reading off a
screen whose every API read was ECONNREFUSED. `--api-path <route>`
(repeatable) GETs the routes the app actually reads: a connection error, a
timeout or a 5xx there is `RIG DEAD` naming the route, while a 4xx (401, 404)
is the server answering and stays green. The verdict line carries
`api <route> -> <status>` per route. With no `--api-path` on the command line
rig-check takes the routes from the project config's `api_probe:`.

**Inside an executor run the verdict is already in your prompt** (`## Runtime
rig`, taken by `executor.rig` once per run): UP = drive, DEAD = skip the phase
and record `TODO: runtime verification not run - rig DEAD: <why>`. Never start,
restart or re-point the server yourself in a run - `--start` is for hand
sessions. Re-run the check after anything that could swap what the server
serves (a branch switch, a restart, `npm ci`).

## What costs the time - one session per reading

Chromium launches in ~0.5 s and a Next dev route compiles on its first hit
(5-30 s, once); after that a reading is ~1-3 s. The waste is elsewhere:

- **Prefer the aria snapshot to a screenshot** when the tree can answer: a few
  hundred bytes of text against an image you also pay tokens to look at. Take
  the screenshot for layout, spacing, colour, overflow - what the tree cannot
  express.
- **One session per state, not one per fact.** `--steps` reaches the state and
  the command reads it; a second fact about the same state is one more command
  with the same steps, not a new plan.
- **`--wait`** is cheaper than a retry: `--wait 'role=dialog'` after a click,
  `--wait 800` after an animation.
- **Reads that must agree**: `--settle` takes the reading twice 2 s apart and
  exits 3 with the diff when they differ - a spinner, a transition, a poll in
  flight. Only two readings that agree are evidence.

## The loop

### 1. Reach
Route from the config's map; the base URL is `http://127.0.0.1:$WEB_PORT`.
State inside the page via `--steps 'click=role=button[name="Next"]'
'fill=input[name=email]=a@b.c' 'press=Enter' 'wait=text=Thanks'`. Selectors
are Playwright's (CSS, `text=`, `role=...[name=...]`, `[data-testid=]`); a
selector matching several elements acts on the FIRST - narrow it (`>> nth=1`,
a parent) instead of hoping.

### 2. Observe
- `web-ui.mjs snapshot <route> [--selector SEL]` - the accessibility tree (roles,
  names, states such as `[disabled]`, `[checked]`, headings with levels). This is
  the primary reading: it says what a user of assistive tech gets, and it is
  diff-able between runs.
- `web-ui.mjs text <route> --selector SEL` - exact copy of one element.
- `web-ui.mjs screenshot <route> [--mobile] [--full] [--selector SEL] --out <path>`
  then Read the PNG. Default viewport 1280x800; `--mobile` = iPhone 13.
- `web-ui.mjs measure <route> --selector SEL` - bounding boxes in CSS px, one line
  per match, `not rendered` for a match with no box.
- `web-ui.mjs console <route>` - every console error/warning, uncaught page error
  and failed request (network failure or HTTP >= 400) of the session. Every other
  command prints a one-line `console:` summary too - a silent page with a red
  console is not a passing page; the config's "console noise" list says what
  to ignore.

### 3. Assert
Compare against the AC and, when a design is named, the design: elements
present with the right roles and names, states (`[disabled]` until the form is
valid), copy verbatim, no overflow or cut text on the mobile viewport, no new
console errors. For a bug fix, reproduce the ORIGINAL symptom first when the
route allows it (a bad hash, an expired link) - a fix you cannot tell from
"never rendered" is not verified.

### 3b. Measure - numbers, not eyeballing
`measure` gives boxes; spacing = the gap between two boxes, alignment = equal
`x` or equal `y`, overflow = a box wider than the viewport or `w=0`. Say the
number in the report, not "looks aligned".

### 3c. Reaching a state is not free
Before driving a creation flow (a signup, a booking, a payment step), check
the config's hard stops: some steps fire an SMS, charge a card, or claim a
resource on a shared account. Prefer the preview/mock routes, a throwaway
account, or hardcoding the state at the render site with a `git status` clean
revert afterwards.

### 3d. What a headless browser cannot prove (say so instead of passing)
Real fonts and rendering on a device, third-party iframes (Stripe Elements,
maps) that refuse an automation context, native pickers, animation timing,
anything behind a login the config has no recipe for. Report the browser
result and name the outstanding check.

### 4. Report
- **Rig first**: the `RIG OK` line (tree, sha, port). A report without it is
  not a result.
- **PASS**: what was verified and how - route, steps, which elements, the
  `console:` summary, screenshot path.
- **FAIL**: concrete, ordered discrepancies - element, expected vs actual,
  measurement or screenshot reference. Enough for the calling flow to fix
  without re-observing.

## In an executor run: OBSERVED lines with controls

A worker's reading is EVIDENCE for the acceptance, never a verdict. Each one
goes into `unresolved` as:

```
OBSERVED: <route> shows <what you saw> - expected: <the AC> - positive control: <a thing that MUST be visible and was> - negative control: <a thing that MUST NOT be visible and was not> - evidence: <.web-verify/evidence/<file>.png or the snapshot line>
```

Both controls are required. Good web controls: positive = an element this
task's diff INTRODUCES (its text or test id, seen in the snapshot) - it proves
the server runs this tree; negative = the element the task REMOVES or the
original bug's symptom, absent. `console: 0 errors` is a third control worth
quoting. Evidence goes under `<tree>/.web-verify/evidence/` (git-ignored, the
driver's default) so the acceptance can open it. The acceptance (batch-finish
Step 2b) re-takes every OBSERVED line with the same controls on its own rig;
a line missing a control is refuted by form.

## Fallback

- Playwright Chromium missing -> the driver uses Google Chrome by itself; say
  so in the report (rendering differs slightly).
- A route that only needs its HTML (SSR output, a redirect, a status code):
  `curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://127.0.0.1:$WEB_PORT/<route>`.

## Gotchas

- **Next dev compiles a route on first GET** - the first reading of a route can
  take 30 s and show a compile error that the second reading does not. Read
  the `console:` line, retry once, then report.
- **HMR keeps client state across an edit.** A reading taken after editing a
  file may sit on state from before the edit - a plain `goto` (every command
  navigates fresh) is a reload; only in-page steps carry state.
- **A route that 404s is not "a broken page"** - check the `app/` tree first;
  docs and READMEs name routes that no longer exist.
- **Portals**: sheets, dialogs and menus render outside their trigger's
  subtree - scope with `--selector 'role=dialog'`, not with the parent.
- **`text=` matches substrings and duplicates** (a heading and a button with
  the same label) - use `role=button[name="..."]` for controls.
- **`[disabled]` in the snapshot is the state, not a failure** - a "Next"
  button disabled on an empty form is the AC, not a bug.
- **Port ownership over port number**: the rig check refuses a port served by
  another tree. Never kill that server - it is another session's. Pick the
  slot's port instead.
- **Expected 4xx are console errors too**: a bad-hash route that POSTs to
  `/api/.../magic-link` logs `http.404` by design - list it in the config's
  noise section, do not report it.
