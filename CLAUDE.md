# claude-skills

Skills for Claude Code, linked into `~/.claude/skills` by `install.sh`. Conventions for the
skills themselves are in README.md ("Conventions").

## Public repo: no work data

This repository is public. The skills are distilled from real client sessions, which makes
those sessions the main source of leaks.

- Never write names of clients, companies, projects, products or people, bundle ids, ticket
  prefixes, links to trackers / Slack / Figma, hosts, Apple team ids, udids, device names or
  home-directory paths.
- Use placeholders: `com.example.app`, `MyApp`, `PROJ-123`, `<METRO_PORT>`, `<DEVICE_NAME>`,
  `/Users/alice/...`. The fictional project slugs `orbit` and `vega` and the ticket prefix
  `ACME-` are the repo's own (README, "Conventions").
- Project-specific values belong in the project's git-ignored config
  (`<repo>/.simulator-verify/config.md` and its siblings), never in a skill.
- When a lesson from a session goes into a skill, describe the mechanism in general terms.
  Do not paste session text, logs, screenshots' contents or names.
- Measurements go into the skill's `references/benchmarks.md` (or next to the rule they
  justify) with their date, hardware and versions - not into the core SKILL.md.
- Every commit runs `scripts/check-leaks.sh` through `.githooks/` (installed by
  `install.sh`). The names it blocks come from a denylist kept OUTSIDE the repo
  (`~/.config/claude-skills/denylist.txt`), so this file and the script never contain them.
  When it reports a hit, fix the text; never commit with `--no-verify`. A FICTIONAL value
  that looks real (a fake udid in a test) goes into `.leak-allow`.
