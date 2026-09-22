# Example: one complete sub

A trimmed sub from a real stacked queue (a Next.js screen on server-side mock
data). The project's language may differ; the headings do not. Frontmatter
fields are listed first, then the Spec as written to pm.

## Fields

- title: `ACME-230: position detail screen - debt, collateral, and a risk read that fails on its own`
- parent: `vega-230` · order: `20` · depends_on: `[vega-230-1]` · model: `opus`
- branch: `feat/ACME-230-position-screen`
- ac: `pnpm turbo run lint typecheck test build --filter='./packages/*' --filter='./apps/web-*' --force`
- links: `jira`, `plan`, `draft-contract` (the pinned copy), `parent`
- brief: `Goal: first usable position screen. Decisions: server components, independent risk failure, manual refresh. Status: not started; forks from the shared-data branch. Files: plan section 4, pinned contract copy.`

## Spec

```markdown
## Description
Deliver /positions/[positionId]: debt and collateral for both protocols, a risk
read that can fail without hiding the position, and a manual refresh. The
first usable screen of the parent.

## Bug as the user sees it
Not a bug: an investor has no page that shows a position's debt and collateral
and stays readable when risk data does not answer.

## Reporter's scenario
No reporter - a new screen. Data is synthetic (server-side mock in the Next
process); scenarios come from the accepted plan, section 4.

## Context
Parent vega-230. Repo /Users/alice/repos/vega/app. Entry branch:
feat/ACME-230-screen-data (depends_on).

<!-- solo-prep:shared:start -->
- Read the parent Spec on cold start; this sub carries only what it needs.
- Local work only: no push, MR, merge, status done, Jira or Slack. The user
  opens one MR for the whole ticket.
- Internal ids: pm ids (vega-230, vega-230-3), sub numbers and the word "solo"
  never enter code, comments, test names, commit messages or MR text. Write
  ACME-230 and plain words.
- Pinned contract: /Users/alice/repos/vega/docs/acme-213/evidence/acme-226/acme-226-draft-2026-09-14.md
 . Read this copy; a newer page
  mid-queue is logged, not re-pinned.
- Runtime: --web. Config .web-verify/config.md, port 3201, API_MOCK=1. New
  routes go into its Routes table.
- Gate: the ac command, plus `pnpm turbo run e2e --filter=@vega/web`
  for every screen change.
- Obey AGENTS.md and .claude/rules/frontend.md. Approved: adding
  @vega/ui as a workspace dependency (repo owner, 2026-09-14, chat).
- EXCLUDED: live API and wallet (plan section 1: mock-only PoC); new /api/*
  routes (plan section 2: server components only).
<!-- solo-prep:shared:end -->

## Decided approach
- DECIDED (plan 3.1, user 2026-09-14): server components read with
  cache: 'no-store'; refresh is router.refresh(); no browser fetch.
- DECIDED (plan 4): position and risk reads fail independently. A risk 503
  keeps debt, collateral and maturity on screen; health reads "unavailable".
- ASSUMPTION: debt scale comes from the track config read. Check
  src/lib/api/server.ts for an existing reader first; if none, use the
  contract's decimals field and record it in Przed PR-em.
- INVESTIGATE: whether the loading boundary is sent before not-found (it
  decides the status code). One curl before writing the not-found test.

## Acceptance Criteria
- [ ] AC-23: one component set shows Variant A (one health figure, debt as of a
      block) and Variant B (face debt, two figures); no branching on app or
      track id.
- [ ] AC-21: a risk HTTP 503 keeps debt, collateral and maturity; health reads
      "unavailable", never "healthy".
- [ ] Refresh shows a pending state and then the newer reading, in both
      directions (unavailable to available, available to unavailable).
- [ ] Loading, not found and a failed position read are distinct states with
      their own copy.

## Verification recipe
- Scenario selection: the position id prefix picks the server mock scenario
  (pos-risk-recovers-, pos-risk-fails-, pos-position-updates-) plus a fresh
  UUID per test execution, retries included. The mock runs in the Next server
  process, so page.route() cannot drive it.
- Protocols - channel: accessibility tree. Positive: Variant B shows two health
  figures and face debt. Negative: Variant A shows exactly one figure and no
  maturity row.
- Risk recovers - channel: text. Positive: first render says "unavailable" with
  debt visible; after refresh the health figure shows. Negative: a fresh id
  with the same prefix starts at "unavailable" again (the counter is per id).
- Position updates - channel: debt value text. Positive: value A before
  refresh, B after. Negative: refresh on a pos-risk-fails- id leaves the debt
  value unchanged.
- Evidence: e2e report; runtime pass per solo prompts/runtime.md with
  screenshots under ~/.claude/pm/vega/.shift/evidence/<task-id>/.

## Open Questions
- The pinned contract has no 404 error body, so every 404 reads as "no such
  position". Changes if the frozen contract adds one.

## Next Steps
- [ ] Settle the ASSUMPTION and INVESTIGATE lines; record results in the Log.
- [ ] Screen for both protocols with component tests.
- [ ] Independent risk failure and refresh, with e2e for the three scenarios.
- [ ] Gate, runtime pass, one reviewer, brief and Log.
```
