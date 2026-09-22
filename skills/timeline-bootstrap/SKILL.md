---
name: timeline-bootstrap
description: Seeds a pm project's timeline once from what the project and its repo already know - one state entry plus dated event and decision entries that each cite their source - and writes them with `pm timeline add` only after the user approves the printed draft. Refuses when the project already has a timeline. Use when the user says "/timeline-bootstrap", "zacznij timeline", "zaseeduj timeline", "załóż timeline projektu", or wants to start the timeline of an existing project.
---

# Timeline bootstrap

One run per project: check -> gather -> draft -> the user's go -> write.
`<skill>` below is this skill's directory.

## Quick start

1. `bash <skill>/scripts/check.sh [slug]`
   - exit 1: print its line (`timeline exists: N entries, latest state <date|none>`) and STOP - nothing else runs.
   - exit 2: print the reason and stop.
   - exit 0: go on.
2. `python3 <skill>/scripts/gather.py [slug] > <scratch>/timeline-facts-<slug>.txt`, then read the file whole.
3. Draft the seed and print it - `prompts/draft.md`.
4. Wait for the user's explicit go ("zapisz", "tak", "go"). Struck or edited lines: apply, print again, wait again. "dry run" / "tylko pokaż" / no answer = nothing is written.
5. On the go: run check.sh again (it must still exit 0), write as `prompts/draft.md` says, then show `pm timeline <slug>`.

## Rules

- **Project**: the slug the user names, else the one resolved from the cwd (both scripts take the slug as their only argument). Neither resolves = ask for the slug.
- **Once**: no force flag and no second seed. A timeline with any entry is extended by hand with `pm timeline add`.
- **CLI, not MCP**: writes go through `pm timeline add` on PATH; a running pm MCP server may predate the timeline tools. check.sh exit 2 names a pm without the command.
- **Never invent**: every line of the draft traces to a line of the facts file, and every entry date is a date printed there.

## Sources (gather.py)

| Source | What it reads |
|---|---|
| pm project | `project.yaml`: name, path, repo, group, stack, notes |
| pm tasks | in progress (status date, brief, waiting_for), landed (done/merged/pushed with the status-change date, a bulk move marked, and the git lines naming each), to do, archived (newest 20), any other status the project defines |
| git | first commit, merges into the base branch (newest 40), tags, commits on the base in the last 30 days (newest 30) |
| repo docs | heads of `README.md`, `docs/INDEX.md`, `CHANGELOG.md` |
| knowledge base | the project's section of `~/repos/knowledge/INDEX.md`, when there is one |

## Files

| When | File |
|---|---|
| step 1 and 5 | `scripts/check.sh` |
| step 2 | `scripts/gather.py` |
| steps 3 and 5 | `prompts/draft.md` |
