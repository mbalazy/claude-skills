---
name: session-digest
description: Turns one Claude Code session - its transcript plus every markdown file it and the sessions and agents it drove wrote - into ONE answer organised by what the user does with it - the questions it was given and their current answers with a confidence label, what changed since the user was last told, decisions left to the user with their options, one merged plan of manual device checks, branches, cleanup. Prints it in chat and writes digest.md + phone-plan.md next to the evidence. Its format file is the single source of the end-of-work answer for solo and taking-over too. Use when the user says "/session-digest", "zbierz sesję", "podsumuj sesję X", "zrób digest", "uporządkuj wyniki sesji", "co wyszło z tej sesji", "ten raport to chaos", or a long orchestrator / solo session ends with results spread over many files. Never drafts messages to people - that is a separate step.
---

# Session digest

A long session leaves its answers in layers: first passes, reviews, redone
passes, fix-ups, interim syncs. This skill collects all of it and writes the
answer as it stands NOW, in the shape `reference/format.md` defines.

## Input

| Invocation | Session read |
|---|---|
| `/session-digest` | this session |
| `/session-digest <name or uuid>` | that session (a `/rename` title or agent name) |
| from `solo` Step Z or `taking-over`'s final report | this session, at its end |

## Hard limits

- Read-only everywhere except the output directory (and a temp work dir).
- No messages to people, no drafts of them, no pm writes. A caller (solo,
  taking-over) does its own pm bookkeeping.
- Never re-run tests, builds or device checks: the digest reports what the
  files hold. A gap goes to `Otwarte:` or `phone-plan.md`.

## Procedure

1. **Collect** - inventory the transcript, list the questions the session was
   given, classify the files, pick the extraction mode.
   -> `prompts/collect.md`
2. **Extract** - one ledger entry per question (yourself, or one fresh agent
   per question when the sources are large), into `<work-dir>/ledger/`.
   -> `prompts/extract.md`
3. **Assemble** - read `reference/format.md` and write `digest.md` and
   `phone-plan.md` into the output directory the inventory suggests (move an
   existing pair to `previous/` first). For `phone-plan.md`, read the device
   sections the ledger entries located and merge them: setup once, blocks by
   topic, every step self-contained.
4. **Verify** - one fresh agent checks both files against their sources;
   apply what its evidence supports.
   -> `prompts/verify.md`
5. **Answer** - print the chat answer (format.md, "Chat answer"); its last
   line under `Na dole` names both files with full paths.

Before printing, read section 1 once as the user who was not there: a line
that needs the session, a file or a question number to be understood is
rewritten, not footnoted.

## Files

| File | What |
|---|---|
| `reference/format.md` | THE output format - shared with solo and taking-over |
| `prompts/collect.md` | inventory, questions, file classes, extraction mode |
| `prompts/extract.md` | the ledger entry and the extraction agent's brief |
| `prompts/verify.md` | the fresh verifier's brief |
| `scripts/inventory.py` | transcript -> `inventory.md`, `asks.md`, `shown-messages.md` |
