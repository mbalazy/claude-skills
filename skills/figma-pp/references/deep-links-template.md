# Deep links map (per-repo, gitignored)

Copy to `<repo-root>/.figma-pp/deep-links.md`. The `figma-pixel-perfect` skill reads and MAINTAINS this file.

## Instructions for CC (self-maintenance)

- When you reach a screen NOT listed here, append a row to the table below.
- `source` = where the route/flag is defined (`file:line`) so the next session can verify it.
- If a deep link does NOT work, mark its status `⚠ unverified` — do NOT delete it (someone may fix the route).
- Once you've confirmed a deep link reaches the right screen, mark it `✓ verified`.
- Force-open flags (screens with no route) go in the second table.

## Deep links

| screen | route / deep-link | status | source |
|--------|-------------------|--------|--------|
| (example) paywall screen | `myapp:///paywall` | ✓ verified | app/(auth)/... |

## Force-open flags (screens without a route)

| screen | flag | where | source |
|--------|------|-------|--------|
| (example) welcome onboarding modal | `DEV_FORCE_MODAL` | component prop, bypasses isOpen+isRegistered | features/onboarding/... |
