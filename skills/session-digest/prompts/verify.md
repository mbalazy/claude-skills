# Verify: a fresh reader checks the digest against the files

The digest is a summary of summaries; the one failure it must not have is a
claim its sources do not carry. One fresh agent (no context from this
session, `model: "opus"`) checks it. Brief, placeholders filled, nothing else added:

```
Read-only. Do not edit any file.

Check <out-dir>/digest.md and <out-dir>/phone-plan.md against their
sources. The sources are the files each block's "Źródła:" names, plus
<work-dir>/shown-messages.md (what the user was told earlier) and
<work-dir>/asks.md (what the user asked).

Report, as a numbered list, only defects:
1. a claim no named source supports, or a source says otherwise (quote both);
2. an answer taken from a superseded file when a newer one says something else;
3. a confidence label stronger than the source allows (e.g. "widziane" for
   something only read in code, a simulator result stated as device behaviour);
4. a claim in shown-messages.md that the digest now contradicts and that is
   missing from section 2 "Zmieniło się w trakcie";
5. a question in asks.md that the user handed over and that the digest
   leaves out;
6. a phone-plan step copied from a superseded file, a step that refers back
   to another step, or setup repeated inside a block.

For each: the line in the digest, the evidence (path + heading + quote), the fix.
Nothing found in a category: say "none" for it. Do not praise, do not summarise.
```

Apply every defect that the evidence supports; one that rests on a
misreading is rejected with a line in `digest.md` under `## Weryfikacja`
(what was raised, why it does not hold). No second verification round
unless more than a third of the blocks changed.
