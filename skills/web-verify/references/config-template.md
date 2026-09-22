# web-verify config - <app name>

Everything project-specific that the `web-verify` skill reads. Copy this file
to `<repo-root>/.web-verify/config.md` and fill it in.

**Keep `.web-verify/` out of git.** It holds the dev server's run files, the
evidence screenshots, and - as the route map fills up - real links, hashes and
test accounts. Add `.web-verify/` to `.git/info/exclude` (shared by every
worktree of the repo, and not a change to the repo's own `.gitignore`).

Treat it as a living document: every route you reach, every way of getting a
page into a state, every flow that fires something outward (an SMS, a payment,
an email) goes back in here. The skill stays generic; this file is where the
project knowledge lives.

## Dev server

- **start**: `<npm run dev -- -p "$PORT">` - the command `rig-check.sh --start`
  runs (`sh -c`, repo root, `PORT` in the env). Next.js takes `-p`, Vite takes
  `--port N --strictPort`, a custom server takes whatever it takes.
- **port**: `<$WEB_PORT>` - decided by the env, never by this file. In an
  executor run every worktree slot has its own (`executor.worktrees[].env`);
  in a hand session export it before driving anything. A port with no owner
  check is how a reading ends up taken on another tree's server.
- **first-hit compile**: `<Next dev compiles a route on its first GET - 5-30 s;
  the rig check's probe waits 60 s, web-ui waits 60 s on the first goto>`
- **env**: `<.env.local (git-ignored) must exist in the tree - what it points
  at (a remote dev API through the Next proxy, a local backend, mocks) and
  where a fresh worktree copies it from>`
- **backend**: `<none needed / remote dev API / local rig via <skill>>` -
  which routes work with no backend at all (static pages, previews with mock
  data), which need data.
- **api_probe**: `</api/health>`, `</api/...>` - the API routes `rig-check.sh`
  GETs on top of the page, when no `--api-path` is given on the command line.
  A connection error, a timeout or a 5xx on one of them is RIG DEAD; a 4xx is
  the server answering. Name the routes the screens actually read: a page
  renders from cache long after its API died, and every reading taken then
  looks normal and is false. No key = the rig check proves the page only.

## Routes (the screen map)

One line per route you have reached, with what it needs and what it shows:

| Route | Needs | Shows / good for |
|-------|-------|------------------|
| `/` | nothing | `<landing>` |
| `/<preview-route>` | nothing (mock data) | `<the onboarding form, all steps reachable>` |
| `/<thing>/[hash]` | a valid hash from `<where>` | `<...>`; a bad hash shows `<the error state>` |

How to get a valid link/hash/session when a route needs one: `<the curl or
the admin step, and which account>`.

## Viewports

- **desktop**: `1280x800` (web-ui default)
- **mobile**: `--mobile` = iPhone 13 (390x844 @3, touch). The design is
  `<mobile-first / desktop-first>`; check `<which>` first.

## Selectors that work here

- `<role=button[name="Next"]>` - the primary CTA on every form step
- `<[data-testid=...]>` - `<which components carry test ids>`
- `<text=...>` pitfalls: `<a label that is rendered twice, a heading that
  differs between locales>`

## Money and irreversibility - hard stops

Actions that cost real money or real state; never drive them to make a check
pass, stop and ask:

- `<POST /api/.../claim - buys a phone number>`
- `<the payment step with a real Stripe key>`
- `<sending the SMS / email>`

## Console noise that is NOT a finding

Errors the page always logs and that mean nothing for the AC (so a
`console:` summary with them is still clean):

- `<http.404 POST /api/v1/.../magic-link on a bad hash - expected>`
- `<Sentry/Amplitude disabled locally - "no DSN" warning>`

## Gotchas

- `<the sheet component renders its content in a portal - use --selector
  'role=dialog' not the trigger's parent>`
- `<HMR keeps client state across an edit - reload (plain goto) before a
  reading that depends on the initial state>`
