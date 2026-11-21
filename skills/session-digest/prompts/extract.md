# Extract: one question, its files, one ledger entry

Used by the main session when it reads the files itself, and as the brief of
a fresh extraction agent. For an agent, the prompt is this file's "Brief"
section with the placeholders filled - nothing about how the session went,
no conclusions of your own.

## Brief

```
Read-only. Do not edit, move or create any file except <ledger-path>.

Question (asked by <who>): "<the question in their words>"
Ticket: <key and summary, or none>

Files that answer it, newest first:
<current files, full paths>
Reviews of those files (their OPEN points still count):
<review files>
Superseded versions (read only to see what changed):
<superseded files>
What the session showed the user earlier, numbered S1..Sn:
<work-dir>/shown-messages.md

Write ONE ledger entry to <ledger-path> in the format below. Every claim
carries the path and heading it came from. State only what the files say;
where they disagree, the newest wins and the disagreement goes to
"Earlier versions". Plain language: no question numbers, no CONFIRMED /
REFUTED, no run or pass names in the answer fields.
```

## Ledger entry

```
## <who asked>: "<question>"
Ticket: <key - summary | none>

Answer now: <1-2 sentences>
Confidence: <widziane: <where> | kod | dokumentacja: <source> | opinia | niesprawdzone>
Confidence per part: <part - label - source path#heading>, one per line
Catches: <0-3 bullets: what the answer does not say on its own>
What it means: <blocks X / tell Y / nothing follows> - from the files, or "not stated"
Open: <what is unknown + what would settle it>

Criteria table (when the question is a ticket's criteria):
| Criterion | Result | Confidence | Source |

Earlier versions:
- <time> <file or S-number>: <what it said> -> now: <what holds> | shown to the user: yes (S<n>) / no
Decisions left to the user: <each with what it fixes, its side effect, the options and their cost, the default>
Manual checks: <file path + heading of the NEWEST device-steps section; setup steps it needs; number of steps; what each group settles>
Code: <branch - what is on it - pushed or local - commits named in the files>
Cleanup: <side effects on shared accounts / devices the files record>
Sources: <every file read, with its class: current / review / superseded>
```

## Rules

- **Newest wins.** A later pass, a fix-up or an acceptance that names an
  earlier claim as wrong replaces it. An acceptance's open point that no later
  file closes stays open and goes to `Catches` or `Open`.
- **A reversal shown to the user is the most valuable line.** Search
  `shown-messages.md` for this question's topic; every claim there that the
  newest files contradict goes to "Earlier versions" with `shown to the
  user: yes (S<n>)`.
- **Meaning is not invented.** When no file says whether a finding blocks
  anything, write "not stated" - the main session decides what to ask.
- **Manual checks are located, not copied.** Name the newest section and
  count its steps; `phone-plan.md` is assembled once, from all entries.
