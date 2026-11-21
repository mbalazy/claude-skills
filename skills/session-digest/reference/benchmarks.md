# Measurements

## First real run (2026-11-21, Apple Silicon Mac, Claude Code CLI)

Source: an orchestrator session over three overnight solo shifts on a React
Native app (iOS spikes), with two executor sessions and ten acceptance agents
under it.

| Step | Measured |
|---|---|
| `inventory.py` on the transcript (20 MB, ~3,000 JSONL lines, 2 compactions) | 29 s wall; 87 md files found (199k words), 23 asks, 36 shown texts, 39 commits |
| Questions the session was given | 5 (two people's questions, three tickets' criteria) |
| Extraction, one fresh agent per question, in parallel | 129k-178k tokens and 2.3-4.2 min each |
| `phone-plan.md` merge, one fresh agent, 7 device sections | 263k tokens, 15.5 min; 9 blocks, 204 steps, 4 sittings |

What the run surfaced that the session's own end report had not:

- a ticket criterion not met at all (no deep link on a Live Activity: the
  URL API is never called) - present in one findings file, absent from every
  report;
- two claims shown to the user in an interim sync and later reversed or
  narrowed without a word (a "mismatch" that was two different quantities; a
  side effect "that breaks the one-minute credit" that changes nothing a
  member sees today).

Both came from the rule that every claim in the shown messages is compared
with the newest files - the reason section 2 is mandatory.
