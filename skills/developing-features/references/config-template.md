# developing-features config - <app name>

Everything project-specific that the `developing-features` skill reads. Copy this
file to `<repo-root>/.developing-features/config.md` and fill it in.

**Keep this directory out of git.** Add `.developing-features/` to `.gitignore`,
or to `.git/info/exclude` if you would rather not touch the shared ignore file.

## How to fill this in, and why it is strict about it

Most fields below carry a **`measure with:`** line - the command that produces the
answer from this repo. Run it. Do not fill a field from a project document, from
another skill, or from what a similar repo did, because all three go stale without
announcing it and this file is trusted blind by every later phase.

That is not a hypothetical. The first version of this file for the first project
was filled from its predecessor skill's prose, and four values were wrong within a
day - including a commit format that **zero** of the last 200 commits used, and a
CI workflow filename that did not exist. Both had been wrong in the predecessor
for months. `git log` and `ls .github/workflows` would have caught both in seconds.

Two rules that follow from it:

- **A placeholder is a valid answer; a guess is not.** The skill is written to ask
  when it hits a `<...>`. It cannot ask about a confident wrong value.
- **Record provenance per value, not in a header.** Write `(git log, 2026-07-30)`
  next to a value that can drift. A blanket "everything here was verified" at the
  top is unfalsifiable, ages invisibly, and tells the next reader not to check -
  it is worse than no claim at all.

Run the skill with no feature argument to re-derive everything and report drift.
Treat this file as a living document: a convention discovered the hard way goes in
here, not into the skill.

## Ticket system

- **name**: `<Linear / Jira / GitHub Issues / none>`
- **key format**: `<e.g. ACME-1234>` - the shape the skill matches in a request.
  Write `none` if the project does not use ticket keys.
  - measure with: `git log --format=%s -n 100 | grep -oE '[A-Z]+-[0-9]+' | sort -u | head`
- **how to fetch an issue**: `<e.g. Linear MCP: mcp__linear__get_issue by identifier>`
- **how to fetch its comments**: `<e.g. mcp__linear__list_comments with the issue id>`
  - The skill fetches both, always. Most APIs need two calls, and the comments
    are where the real decisions are. If comments come back with the issue in
    one call here, say so.
- **how to change state**: `<e.g. mcp__linear__save_issue with state: "<name>">`
- **in-progress state**: `<exact board state name, e.g. In Progress>`
- **in-review state**: `<exact board state name, e.g. In PR Review>`
  - Exact strings, from the board itself - a state name that does not exist fails
    the call mid-flow. This is the one group of fields no repo can confirm: ask.
  - The flow moves a ticket no further. Anything past it is the human's.
- **board / project URL**: `<url, for linking>`

## Branch

- **base branch**: `<development / main / staging>` - what features fork from and
  what PRs target. The value most likely to differ from the project you last
  worked in.
  - measure with: `git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||'`
- **branch convention**: `<e.g. APP-{ticket}-{kebab-slug}>`
  - measure with: `git branch -r --sort=-committerdate | head -20`
- **how to create the branch**: `<e.g. git fetch origin <base> && git checkout -B <branch> origin/<base>>`
  - Spell it out if the repo insists on branching off the *remote* base. "Make
    sure the base is up to date" is not the same instruction, and a branch cut
    from a stale local base carries already-merged commits into the PR.
- **fallback with no ticket**: `<e.g. {kebab-slug}>`

## Validation gate

- **command**: `<e.g. yarn validate>` - run before every commit. Name the exact
  script, not an approximation of what it does.
  - measure with: `node -e 'console.log(require("./package.json").scripts)'`
    (look for an aggregate: validate / verify / check / ci)
- **what it covers**: `<expand the script and list the steps>`
- **what it does NOT cover**: `<e.g. tests, performance baselines, secret scan -
  those run in the pre-PR gate and in CI>` - so the skill knows what is still
  unchecked when this passes.
- **is it green on a clean checkout right now?** `<yes / no + why>`
  - measure with: running it. If it is red on the base branch, say so here and
    name the cause - otherwise every later run blames the current change for it.

## Pre-commit hooks

Anything that runs on `git commit` and can reject it. Workers hit these, not CI.

- **hooks**: `<e.g. lint-staged -> eslint --fix --max-warnings=0 + a token scan>`
  - measure with: `cat .husky/pre-commit 2>/dev/null; cat lint-staged.config.* .lintstagedrc* 2>/dev/null; node -e 'console.log(require("./package.json")["lint-staged"])'`
  - Read the hook file itself, not just the lint-staged config: hooks often chain
    something before it (a secret scan is common) that fails the commit on its own.
  - Note which paths the config actually covers - a rule scoped to `src/**` does
    not fire on a file elsewhere, and knowing that saves a confused retry.
- **surprising behaviour**: `<e.g. the token scan is whole-file, not diff-aware, so
  a pre-existing violation in a file you merely staged blocks the commit>`
  - This is the kind of thing that reads as a broken tool when you meet it
    unprepared, and costs a round of confusion each time.
- **staging discipline**: `<e.g. always `git diff --cached --stat` before committing;
  this tree often carries a parallel session's changes>`

## Required test files per component

- **required?** `<yes / no>`
- **shape**: `<e.g. a sibling .perf.tsx using measureRenders + reassure, wrapped
  in ThemeProvider, heavy children mocked>`
- **copy the shape from**: `<path to a real existing example>`
- **enforced by what, exactly?** `<CI job / review convention / nothing>`
  - measure with: `grep -rn "perf\|test" .github/workflows/*.yml | head -20`
  - Be precise: "the repo requires it" and "CI fails without it" are different
    claims with different consequences, and a convention documented as REQUIRED
    is often not actually checked by any job. Do not upgrade one into the other.
- **how the check decides pass/fail**: `<e.g. reassure classifies runs as
  significant/stable and the aggregate job filters significant regressions>`
  - Quote a threshold ONLY if you found it in the repo. An invented number here
    is repeated by everyone downstream forever.
- **mocks needed before green means anything**: `<e.g. a new native module must be
  mocked in jest.setup.js or the suite crashes at import and hides every other
  failure>`

Write `no` and delete the rest if the project has no such requirement.

## Architecture + code patterns

- **architecture document**: `<e.g. .claude/CLAUDE.md>` - owns the code
  templates. The skill points at it and never restates it.
- **component registry / design-system index**: `<path, or none>` - checked for a
  reusable component before anything new is created.
- **import convention**: `<e.g. path aliases only (@components, @store); no
  relative ../../; no barrel index.ts>`
- **design tokens**: `<where they live>`
- **file layout**: `<the sibling-file pattern for a screen or component>`
- **anti-patterns worth naming**: `<the two or three the reviewers actually flag>`

## Artifacts

- **specs**: `<e.g. .claude/specs/{ticket-or-slug}.md>`
- **research**: `<e.g. .claude/research/{topic}.md>`
- **are they ignored by the REPO, or only by your machine?**
  - measure with: `git check-ignore -v .claude/specs/x.md`
  - A global `~/.gitignore_global` rule protects you and nobody else. If that is
    what is holding, say so - on a teammate's machine those files are committable.

## Handoffs

- **runtime verification skill**: `<e.g. simulator-verify, or none>` - invoked in
  the ship phase to confirm the feature works in the running app.
- **pre-PR gate**: `<a skill name, a command, or none>`
- **who owns each**: `<which are checked into this repo and therefore exist
  nowhere else, and which come from a shared toolkit>`
  - measure with: `git ls-files .claude/skills | head`
  - This distinction is the reason the gate is configured instead of hardcoded.
- **is the gate itself current?** `<note it here if the gate skill names CI jobs or
  workflows that no longer exist>` - a stale gate reports on checks nobody runs.

If this project is registered with `pm`, `pm executor show <slug>` prints the
runtime skill and the verification command as pm resolved them - worth
cross-checking against this file so the two do not drift.

## PR conventions

- **target**: `<the base branch above>`
- **title format**: `<e.g. ACME-1234: short description, under 80 chars>`
  - measure with: `gh pr list --state merged --limit 30 --json title -q '.[].title'`
- **body policy**: `<what the repo's own document says, quoted>`
  - measure with: the architecture document's PR section. Do not infer it from
    what previous automation did - that is how "leave the body empty" survives in
    a repo whose own guide asks for two sentences of why.
- **commit convention**: `<the shape the repo actually uses>`
  - measure with - group by the PREFIX shape, not the whole subject:
    ```sh
    git log origin/<base> --format=%s -n 200 \
      | grep -oE '^([a-z]+(\([^)]+\))?: |[A-Z]+-[0-9]+: |[a-z]+\([A-Z]+-[0-9]+\): )' \
      | sed -E 's/\([^)]+\)/(scope)/; s/[A-Z]+-[0-9]+/KEY/' \
      | sort | uniq -c | sort -rn
    ```
    Normalising the whole subject instead (`sed 's/[0-9]*/n/g'` over the full line)
    looks like it works and answers nothing: every subject is unique, so the
    histogram comes back all-ones. Ask about the prefix, which is the convention.
  - Count, do not eyeball, and do not copy an aspirational format out of a style
    guide. If two shapes coexist, name the dominant one as the rule and mention
    the other as encountered.
- **squash policy**: `<when, if ever, the branch gets squashed - and by whom>`
  - The common trap: a repo asks for a squashed history *before review* while the
    merge is also a squash. Say which one applies at which moment, because a
    checkpoint-per-commit branch walks into this every time.
- **what CI runs on the PR**: `<the job names, from the workflow files>`
  - measure with: `ls .github/workflows/ && grep -nE '^  [a-z][a-z0-9-]*:' .github/workflows/<pr-workflow>.yml`
  - List jobs by their real names and note any `if:` conditions that skip them
    (a job gated on the base branch does not run on a stacked PR).

## Local tracker

- **tracker**: `<pm / none>`
- **project slug**: `<the slug in the tracker, if any>`
- **notes**: `<how the phases interact with it, and the never-auto-close rule>`

Write `none` and the skill skips every tracker step.
