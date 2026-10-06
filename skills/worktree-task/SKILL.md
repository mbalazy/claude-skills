---
name: worktree-task
description: Runs one pm task in its own git worktree with its own Claude Code background session, in parallel with other sessions on the same repo (a /solo run in the main checkout, another task) - one task = one worktree = one session = one lane of ports. `wt.py open` creates the worktree from the task's branch, seeds the untracked files a session needs with the main checkout's path and ports rewritten, renders per-worktree overlays, installs and builds; `launch` starts `claude --bg` with a kickoff under the taking-over contract and arms the solo guard for that session; `status` shows every lane; `close` removes the worktree after the work is committed (branch kept, or deleted once it is in the base). Takes a loose request too ("/worktree-task <what to do>"): finds the pm task it means or creates one, picks the branch, then opens and launches. Use when the user says "/worktree-task", "odpal ten task w worktree", "osobna sesja na ten task", "puść to równolegle", "jeden task jeden worktree", "nie ruszaj głównego checkoutu, zrób to obok", or when a task must run while another session owns the main checkout.
---

# worktree-task

Several sessions on one repository collide on more than files: ports, caches
shared behind your back, untracked config that names the main checkout, the
pm project a directory resolves to, the guard's markers. This skill does the
isolation once, mechanically, per task. The procedure is in `scripts/wt.py`;
this file says when to use it, what a project must declare, and what is and
is not isolated.

## From a loose request to a lane

The user usually types what they want ("/worktree-task popraw ten flaky
test", "odpal ACME-270 obok"), not a task id and a branch. Turn that into
`open` + `launch` yourself; ask only where noted.

1. **Project.** The pm project whose `.worktrees/config.env` belongs to the
   repo you are in: `ls ~/.claude/pm/*/.worktrees/config.env`, then match its
   project's `path` (project.yaml) against `git rev-parse --git-common-dir`.
   Do not trust `pm_context` from cwd here - a worktree directory can resolve
   to a parent project. No declaration for this repo: stop and say the project
   needs one first (see "A project's declaration").
2. **Task.** An id or a title fragment in the request: `pm_get_task` (fuzzy).
   Otherwise search the project's open tasks (`pm_list_tasks`) for the thing
   described. Exactly one plausible match: use it and name it in your reply.
   Several: ask one question listing them. None: create it (step 3).
3. **Creating the task.** Read `pm docs authoring` first. `pm_add_task` with
   the project, a title in the user's terms, and a spec holding the request
   quoted verbatim plus the facts you checked with a tool (file paths, the
   failing test, the ticket) - no invented plan. The launched session starts
   cold and the task is all it gets, so if the request does not say WHAT to
   change or WHERE well enough to act on, ask one question instead of
   guessing. `ac`: what the user stated, else the repo's standard gate (the
   AC of the project's recent tasks).
4. **Branch.** The task's `branch` if set. Otherwise name one in the repo's
   convention (`git for-each-ref --sort=-committerdate --count=10
   refs/remotes/origin` - e.g. `feat/ACME-265-...`, `fix/...`), with a ticket
   key only when the request or the task names one, never a pm id; write it
   to the task (`pm_update_task` `branch`) before `open`.
5. **Open, then launch** - unless the user wants the worktree for themselves
   ("bez launch", "sam w nim popracuję", "tylko worktree"): then `open` only
   and give them `wt.py env` for their shell.
6. **Reply in three lines:** task (id + title, "created" when new), worktree
   path and ports, `claude attach <short>`.

## Commands

```
S=~/.claude/skills/worktree-task/scripts/wt.py
$S open   <project> <task-id> [--name N] [--branch B] [--base B] [--no-prepare]
$S launch <project> <name> [--model opus] [--max-hours 6] [--dry-run]
$S status [<project>]
$S env    <project> <name>                  # lane variables, for a human shell
$S close  <project> <name> [--delete-branch] [--discard-ignored]
$S arm    <project> <name>                  # inside the session: guard for THIS session id
```

- **open**: lane = the lowest number whose ports are all free and not held by
  an open lane; worktree at `<WT_ROOT>/<name>` (name defaults to the task id)
  on the task's `branch` (existing branch reused, else created `--no-track`
  from `origin/<base>`); SEED copied with path/ports rewritten; OVERLAYS
  rendered and added to the repo's shared `info/exclude`; PREPARE run with the
  lane's environment. Idempotent for an open lane. Exit 1 = prepare failed or
  the tree is not clean - read the printed log path.
- **launch**: `claude --bg` in the worktree with bypass, `--autocompact 400k`,
  `--setting-sources user,local` when the repo's shared settings carry `ask`
  rules (refused unless the worktree's `settings.local.json` mirrors the
  shared deny list), `--settings` with `worktree.bgIsolation: none` and the
  lane's env, the parent's `CLAUDE_CODE_*` env stripped. Prompt =
  `/taking-over` + `templates/kickoff.md` (+ the project's `notes.md`), saved
  as `lanes/<name>/kickoff.md`. Then it resolves the session UUID from
  `claude agents --json --all` and writes the solo guard marker for it. The
  kickoff's step 0 runs `arm` too, so the guard is on even if the launcher
  could not resolve the id. Watch with `claude attach <short>`.
- **close**: refuses a busy session, uncommitted changes, and ignored files
  that are not build output (pass `--discard-ignored` after moving what
  matters); stops its own servers on the lane ports (only processes whose cwd
  is inside the worktree), `git worktree remove` (never `rm`), closes the
  guard marker, marks the lane closed. The branch stays; `--delete-branch`
  deletes it only when it is an ancestor of `origin/<base>` - a squash merge is
  not, so then the branch is kept and the output says why.

Who calls it: a session asked through `/worktree-task` (see "From a loose
request to a lane"), a human from a terminal, or a coordinating session (as
in the first use, 2026-10-06). A worktree session never opens or closes lanes.

## A project's declaration

`~/.claude/pm/<project>/.worktrees/` (pm's project dir, private, reachable
from every checkout; the skill repo is public and holds nothing per project):

| File | Content |
|---|---|
| `config.env` | `WT_ROOT`, `BASE`, `SEED`, `PORTS`, `LANE_STEP`, `OVERLAYS`, `PREPARE`, `LANE_ENV`, `DISPOSABLE` - documented in `wt.py`'s header |
| `templates/<repo path>` | one template per overlay, `{{NAME}}` placeholders (entry fields and port names) |
| `notes.md` | project rules appended to every kickoff (same placeholders) |
| `lanes/<name>/` | written by wt.py: `entry.env`, `prepare.log`, `kickoff.md`, `state.md` (guard), `evidence/` |

Before writing `config.env` for a new project, establish (each with a tool
call, not from memory):

1. **Untracked files the work needs**: `git status --ignored --short | grep '^!!'`
   in the main checkout, minus build output. Read each for the main
   checkout's absolute path and its ports - those go to SEED and get
   rewritten; a verbatim copy points the new session at the other session's
   server.
2. **Every port a run binds**: dev server, e2e web servers, storybook.
   Committed configs with hardcoded ports need an OVERLAY that moves them
   without touching a tracked file (Playwright: `playwright.config.mts` is
   resolved before `.mjs`), or the project cannot run that command in two
   checkouts at once.
3. **Caches that follow the git repo, not the directory**: Turborepo 2.10
   shares one local cache across all worktrees ("using shared worktree
   cache" in its log) - `LANE_ENV="TURBO_CACHE_DIR={{WT}}/.turbo/cache"`.
4. **What pm and Claude Code key by path**: pm resolves a project from cwd by
   path prefix, so a worktree outside the repo dir resolves to whichever
   project's path contains it (or none) - the kickoff names the project
   explicitly. Memory, `~/.claude.json` trust and per-project MCP servers are
   keyed by the exact path: the worktree starts with no memory (the kickoff
   points at the main checkout's index, read-only) and without project-scoped
   MCP servers.
5. **PREPARE in an empty tree**: run `open` once and read `prepare.log`; a
   cache hit replayed from another checkout is not proof.

## What is isolated, what is shared

Isolated per lane: working tree and index, branch, ports, Next/Turbo build
output and cache, untracked config, the session and its guard marker,
evidence dir. Shared on purpose and safe: the git object store and refs
(`git worktree add`, `fetch`), one exclude line per overlay in the common
`info/exclude`, the pnpm content store, the Playwright browser cache, the pm
data. **Shared and NOT isolatable: CPU and memory** - a heavy loop in a lane
slows the main checkout's gate; the project's notes say when heavy runs may
start.

Not supported: `/solo` inside a worktree. `/solo resume` takes the newest
unclosed state file of the PROJECT, so a worktree shift would be a candidate
for the main run's resume, and solo's Step 0 resolves the project from cwd.
A worktree session gets the taking-over contract plus the solo guard instead.

## Facts this rests on (dated, re-check when a version moves)

- 2026-10-06, Claude Code 2.1.291: `claude agents --json --all` lists
  sessions with `sessionId`, `cwd`, `status` (busy/idle). Under `--bg`,
  `--session-id` is ignored (pm-cli solo.go, verified 2026-09-15 on 2.1.272);
  without `worktree.bgIsolation: none` a bg session blocks Edit/Write outside
  `.claude/worktrees/`.
- 2026-10-06, Turborepo 2.10.12: shared worktree cache by default;
  `TURBO_CACHE_DIR` overrides it (cache miss in the worktree, nothing written
  to the main checkout's `.turbo/cache`).
- 2026-10-06, Playwright 1.63: config lookup order `.ts, .js, .mts, .mjs,
  .cts, .cjs` (`lib/common/index.js`, resolveConfigFile).
- 2026-10-06, pnpm on APFS: `node_modules` files are clones (copy-on-write),
  not hard links - the same file in the main checkout and a worktree has a
  different inode and `links=1` - so an edit under a worktree's
  `node_modules` does not reach another checkout.
- 2026-10-06, Playwright's list reporter does not print the web server's port:
  a lane's port is confirmed with `lsof` while the run is up, not from the log.
- The solo guard (`~/.claude/skills/solo/scripts/guard.py`) is a global
  PreToolUse hook applied per session id; wt.py arms it through solo's own
  `shift-open.sh` and closes it with `shift-close.sh`, never by editing
  solo's files.

## After a lane's session finishes

The background session goes `idle` and stays attachable; its guard marker
stays armed until `close` (or until it goes stale at MAX_HOURS + 2h). So a
push asked of THAT session is blocked by design: push from a terminal
(`git -C <worktree> push -u origin <branch>`), then `close` once the MR is
merged.

## Changelog

- 2026-10-06: first version, built for the vega project while a /solo run
  owned the main checkout; first lanes vega-256 and vega-257.
  Result: both sessions finished cold from the kickoff (vega-256: 8 commits,
  validate 27/27 + e2e 153 on lane 1; vega-257: cause found, 2 commits, stress
  loops 0/7 red after vs 3/4 before, gate green on lane 2), while the /solo
  run in the main checkout closed two subs with its full gate (e2e on 3098)
  green in the same hour - no port, cache or file collision.
- 2026-10-06: a loose request resolves to a task (found or created) and a
  branch before `open`; `launch` is skipped when the user wants the worktree
  for themselves.
