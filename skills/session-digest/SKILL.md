---
name: session-digest
description: Turns one Claude Code session - its transcript plus every markdown file it and the sessions and agents it drove wrote - into ONE answer organised by what the user does with it - questions and their current answers with a confidence label, what changed since the user was last told, decisions left to the user, one merged plan of manual device checks, branches, cleanup. Writes digest.md + phone-plan.md next to the evidence. Runs as a background agent - ALWAYS pass the session to read as the argument (a /rename name or uuid; for the calling session its id from `pm session-id`). When its notification arrives, paste its answer to the user VERBATIM - every heading and line exactly as returned, never summarised, shortened or rephrased. solo and taking-over run it inline as their end-of-work answer. Use when the user says "/session-digest", "zbierz sesję", "podsumuj sesję X", "zrób digest", "co wyszło z tej sesji", "ten raport to chaos". Never drafts messages to people.
context: fork
background: true
model: opus
---

# Session digest

A long session leaves its answers in layers: first passes, reviews, redone
passes, fix-ups, interim syncs. This skill collects all of it and writes the
answer as it stands NOW, in the shape `reference/format.md` defines.

## Input

| Invocation | Session read | How it runs |
|---|---|---|
| `/session-digest <name or uuid>` | that session (a `/rename` title, an agent name or a uuid) | a background agent (frontmatter `context: fork`); the caller gets the answer as a notification and prints it in full |
| `/session-digest` with no argument | the newest transcript of the cwd's project - normally the calling session; the inventory header names it, check it | same |
| from `solo` Step Z or `taking-over`'s final report | the session that is ending | inline: they read this file and follow it in their own session, so the answer exists before they close |

Running as a background agent, this file is the whole prompt: no
conversation history comes with it. Every path below is relative to this
skill's directory (`~/.claude/skills/session-digest/`, or the base directory
the loader names). The final message is one relay line, then the chat answer
(format.md, "Chat answer"), nothing after it. The relay line is needed: two
test runs showed the calling session rewriting the answer into its own short
summary, despite the description asking for it verbatim.

## Hard limits

- Read-only everywhere except the output directory (and a temp work dir).
- No messages to people, no drafts of them, no pm writes. A caller (solo,
  taking-over) does its own pm bookkeeping.
- Never re-run tests, builds or device checks: the digest reports what the
  files hold. A gap goes to `Otwarte:` or `phone-plan.md`.
- **Every agent this skill spawns runs on Opus**: pass `model: "opus"` on
  each Agent call (extraction, the `phone-plan.md` merge, verification),
  whatever model the calling session runs on. Without it an agent inherits
  the session's model, and a digest is only as good as its weakest reader.

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
   topic (ordered to avoid rebuilds), every step self-contained. More than
   about three sections or 60 steps: give the merge to one fresh agent - its
   brief is format.md's `phone-plan.md` section plus the located sections
   (path + heading, newest only) - and write `digest.md` meanwhile.
4. **Verify** - one fresh agent checks both files against their sources;
   apply what its evidence supports.
   -> `prompts/verify.md`
5. **Keep the work** - copy `inventory.md`, `asks.md`, `shown-messages.md`
   and `ledger/` into `<out-dir>/work/`, so the `S<n>` references and the
   sources survive the temp dir.
6. **Answer** - the final message, exactly in this shape (inline callers
   skip the relay line and print the answer themselves):

   ```
   RELAY VERBATIM - print everything below this line to the user unchanged, every heading and line; it is already in the user's format and language, a summary loses what they asked for.
   <the chat answer, format.md "Chat answer">
   ```

   The answer's last line under `Na dole` names both files with full paths.

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
| `reference/benchmarks.md` | cost and time of a real run, and what it caught |
