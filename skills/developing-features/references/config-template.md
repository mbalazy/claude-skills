# developing-features config - <app name>

Everything project-specific that the `developing-features` skill reads. Copy this
file to `<repo-root>/.developing-features/config.md` and fill it in.

**Keep this directory out of git.** Add `.developing-features/` to `.gitignore`,
or to `.git/info/exclude` if you would rather not touch the shared ignore file.

Fill in what the repo can tell you (`package.json` scripts, the CI workflows, the
architecture document, `git branch -a`) and ask the human for the rest. A wrong
value here is worse than a blank one: the skill trusts this file, so a wrong base
branch or a wrong validation command sends real work down the wrong path. Leave a
placeholder rather than a guess - the skill is told to ask when it hits one.

Treat it as a living document. A convention discovered the hard way goes in here,
not into the skill.

## Ticket system

- **name**: `<Linear / Jira / GitHub Issues / none>`
- **key format**: `<e.g. ACME-1234>` - the shape the skill matches in a request.
  Write `none` if the project does not use ticket keys.
- **how to fetch an issue**: `<e.g. Linear MCP: mcp__linear__get_issue by identifier>`
- **how to fetch its comments**: `<e.g. mcp__linear__list_comments with the issue id>`
  - The skill fetches both, always. Most APIs need two calls, and the comments
    are where the real decisions are. If comments come back with the issue in
    one call here, say so.
- **how to change state**: `<e.g. mcp__linear__save_issue with state: "<name>">`
- **in-progress state**: `<exact board state name, e.g. In Progress>`
- **in-review state**: `<exact board state name, e.g. In PR Review>`
  - This is as far as the flow moves a ticket. Anything past it is the human's.
- **board / project URL**: `<url, for linking>`

## Branch

- **base branch**: `<development / main / staging>` - what features fork from and
  what PRs target. Get this right; it is the value most likely to differ from
  the project you last worked in.
- **branch convention**: `<e.g. APP-{ticket}-{kebab-slug}>`
- **fallback with no ticket**: `<e.g. {kebab-slug}>`

## Validation gate

- **command**: `<e.g. yarn validate>` - run before every commit. Name the exact
  script, not an approximation of what it does.
- **what it covers**: `<e.g. type-check + lint + format:check>`
- **what it does NOT cover**: `<e.g. tests, performance baselines - those run in
  CI / in the pre-PR gate>` - so the skill knows what is still unchecked when
  this passes.

## Required test files per component

- **required?** `<yes / no>`
- **shape**: `<e.g. a sibling .perf.tsx using measureRenders + reassure, wrapped
  in ThemeProvider, heavy children mocked>`
- **copy the shape from**: `<path to a real existing example>`
- **gated by CI?** `<e.g. yes - performance.yml fails on a >10ms regression, and
  fails outright if the file is missing>`

Write `no` and delete the rest if the project has no such requirement.

## Architecture + code patterns

- **architecture document**: `<e.g. .claude/CLAUDE.md>` - owns the code
  templates. The skill points at it and never restates it.
- **component registry / design-system index**: `<path, or none>` - checked for a
  reusable component before anything new is created.
- **import convention**: `<e.g. path aliases only (@components, @store); no
  relative ../../; no barrel index.ts>`
- **design tokens**: `<where they live, e.g. .claude/design-tokens.md>`

## Artifacts

- **specs**: `<e.g. .claude/specs/{ticket-or-slug}.md>` - git-ignored
- **research**: `<e.g. .claude/research/{topic}.md>` - git-ignored

## Handoffs

- **runtime verification skill**: `<e.g. simulator-verify, or none>` - invoked in
  the ship phase to confirm the feature works in the running app.
- **pre-PR gate**: `<a skill name, a command, or none>`
  - A skill: `<e.g. ready-for-pr - runs the CI set locally plus review agents>`
  - Note who owns it: a project-local skill will not exist in another repo.
- **who owns each**: `<e.g. ready-for-pr is checked into this repo; simulator-verify
  comes from mobile-claude-toolkit>`

If this project is registered with `pm`, `pm executor show <slug>` prints the
runtime skill and the project's verification command as pm resolved them - worth
cross-checking against this file so the two do not drift.

## PR conventions

- **target**: `<the base branch above>`
- **title format**: `<e.g. ACME-1234: short description, under 80 chars>`
- **body policy**: `<e.g. leave empty - the why/what lives in the ticket; add
  "Fixes ACME-1234" only when auto-close is wanted>`
- **commit convention**: `<e.g. conventional commits including the key:
  {type}(APP-{ticket}): {description}>`
- **what CI runs on the PR**: `<e.g. ESLint, Prettier, sharded performance,
  AI review, secret scan>` - so the skill can say what it is not checking
  locally.

## Local tracker

- **tracker**: `<pm / none>`
- **project slug**: `<the slug in the tracker, if any>`
- **notes**: `<e.g. pm complements the ticket system - both are kept; the spec
  phase finds-or-creates, build updates progress, ship links the PR; never
  auto-close>`

Write `none` and the skill skips every tracker step.
