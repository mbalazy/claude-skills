# Collect: from a transcript to a list of questions with their files

## 1. Inventory

```bash
python3 -I <skill>/scripts/inventory.py --session <name|uuid|path> --out <work-dir>
```

- `<work-dir>`: a fresh temp dir (`mktemp -d`), never the output dir.
- `--session` = the argument the skill was given (`$ARGUMENTS`), without the
  mode word `full` / `light`. None given:
  inline (solo, taking-over) pass this session's id from `pm session-id`;
  as a background agent, omit `--session` - the script takes the newest
  transcript of the cwd's project - and name the session it picked in the
  answer's `Na dole`, so a wrong pick is visible.
- The script lists; it does not judge. It writes `inventory.md` (header,
  asks, sessions messaged, agents, skills, pm ids, md files with words and
  mtime, commits), `asks.md` (everything the user typed, in full) and
  `shown-messages.md` (every longer text the session showed the user, in
  full, numbered S1..Sn).

The session drove other sessions (`## Sessions messaged`) whose files are not
in the list? Run the script on each of them too (by name) and merge the file
lists. Their transcripts are input, not output: the answer is still about
the questions THIS session was given.

## 2. The questions the session was given

Read `asks.md` in full. A question or task enters the list when the user
asked it, handed it over (a pasted message from a person, a ticket, a
"check X"), or approved a plan that names it. Also read the sources the
session pinned for itself (a `sources/` or prep folder in the inventory, the
tracker's spec) - they quote the original asks verbatim.

For each: who asked (a person, a ticket's criteria, the user), the question
in their words, and the ticket key with its summary when there is one.
Questions the user later dropped or that were answered in chat on the spot
stay out, with one line in `## Na dole` only when the user might expect them.

## 3. Files per question

Classify every md file from the inventory:

- **current** - holds an answer, and nothing newer replaces it;
- **superseded** - an older version (`*-v1.md`, a first pass that a later
  pass names as replaced, a report a later fix-up rewrote);
- **review** - an acceptance or review OF a current file; its open points are
  input, its closed points are history;
- **backstage** - briefs to other sessions, decision logs, run state, rig
  notes;
- **unrelated** - older than the session and not touched by it (the
  inventory marks `older than the session`), or about another topic.

Assign the current and review files to the questions they answer (titles and
first headings usually name the ticket). One file can serve two questions.

## 4. Extraction mode

| Sources for the questions (current + review) | Mode |
|---|---|
| up to ~6 files and ~20k words | read them yourself, one question at a time |
| more | one fresh agent per question (or per small group of related questions) with `prompts/extract.md`, `model: "opus"` - in parallel, one message |

Either way the result per question is the ledger entry `prompts/extract.md`
defines. Backstage files are read only for sections 3, 5, 6 and `Na dole`
(decisions left to the user, branches, cleanup, the history in three lines).
