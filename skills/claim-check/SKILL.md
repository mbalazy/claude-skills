---
name: claim-check
description: Verifies every factual claim in a text that is about to leave the session (a PR description, a PR or Linear comment, a ticket description, a report) with a FRESH-context subagent that never saw how the text was written, then writes the marker the claim-check-gate hook requires before `gh pr create/edit/comment` or a Linear save goes through. Use when the user says "/claim-check <file>", "sprawdź twierdzenia", "zweryfikuj opis PR-a", "claim check", or when a publish is denied by the gate with "no fresh claim-check marker".
---

# Claim check

Self-review in the same context does not work (Huang et al., ICLR 2024; and the
2026-09-15 session, where a same-context "what else is overstated?" pass deleted a
false sentence without noticing it contradicted the session's own earlier evidence).
The verifier here is a separate agent with the text and the repo, nothing else.
`<skill>` is this skill's directory.

## Procedure

1. **Input is a file.** If the text is still only in the conversation, write it to
   `<scratchpad>/claim-check/<name>.md` first. The published text must be byte-for-byte
   this file's content (whitespace differences are tolerated, nothing else).
2. **Spawn ONE subagent** (`general-purpose`, synchronous) with the content of
   `<skill>/prompts/verifier.md`, `{FILE}` and `{CWD}` filled in. Give it NOTHING from
   the conversation: no reasoning, no summary, no "context". That isolation is the whole
   mechanism.
3. **Save its report** verbatim to `<file>.claims.md`.
4. **Triage**, in this order:
   - REFUTED -> fix the sentence in the file, or delete it.
   - UNVERIFIABLE -> delete it, or rewrite so the text says it is unverified
     ("not checked in this session").
   - VERIFIED -> keep.
   If the fix introduced a NEW claim, run step 2 again for the changed lines. Editing
   the text changes its hash, so the marker is always for the final wording.
5. **Mark**: `bash <skill>/scripts/mark.sh <file> --report <file>.claims.md`. It refuses
   while the report holds a REFUTED line.
6. **Publish** with `gh ... --body-file <file>`, or send exactly the file's text to
   Linear. The gate (`~/.claude/hooks/claim-check-gate.py`) allows it for 6 hours.

## What the gate covers

`gh pr create|edit|comment`, `gh issue create|comment` bodies over 200 characters
(inline `--body` of that size is denied outright: use `--body-file`), and Linear
`save_comment.body` / `save_issue.description` over 200 characters. Not covered: pm
briefs and task bodies (internal; the Compact Instructions in CLAUDE.md carry the
"fact with its source" rule there), commit messages, chat.

## Limits, stated plainly

The gate proves a verifier report exists for this exact text, not that the text is
true. `mark.sh` can be run without step 2; doing so defeats the point and leaves an
auditable marker naming a report that does not exist. `CLAIM_CHECK_GATE=0` disables
the hook for a session when the user says so.
