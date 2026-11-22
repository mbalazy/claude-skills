# The end-of-work answer: one format, three users

The ONLY definition of what the user reads when work ends. Three procedures
produce it and none of them carries its own copy:

| Who | When |
|---|---|
| `session-digest` | on demand, about this session or another one - a background agent; light unless asked for `full` |
| `solo` (Step Z, `--digest`) | closing a shift - the chat answer, inline; the cockpit report file keeps its own contract (`solo/prompts/report.md`) |
| `taking-over` (`digest`) | the final report when the user comes back, inline |

solo and taking-over always produce the full answer. Light (on demand only)
writes no `phone-plan.md`, runs no verifier, and differs from full in two
places: the line under `Od Ciebie` and section 4.

`--digest` / `digest` is hardcoded ON in solo and taking-over for now; the
flag exists so the user can make it selective later.

Change this file and all three change. The user's own CLAUDE.md report rules
apply on top and win on conflict (language, first line, dashes, naming).

## The one rule

**Organise by what the reader does with it, never by how the work ran.** The
reader asks: what is the answer to what I (or someone) asked, what changed
since I last looked, what must I decide, what must I check by hand, what is
left behind. Runs, sessions, trackers, passes, agents and ports are how the
work ran - they go to the bottom, in three lines.

Failure this file exists for (an orchestrator session over three overnight
runs, 40+ md files, 100k+ words): the end report followed every form rule
and was still unreadable - organised per run, the answer to one question
spread over four layers of findings, one conclusion reversed between the
morning sync and the final report without a word, and every detail behind
"read findings.md in 14 folders".

## Outputs

| Output | What | Size |
|---|---|---|
| chat answer | the sections below, short | up to ~700 words |
| `digest.md` | the same sections, each claim with its source (`path` + heading), the earlier versions, the file map | no limit |
| `phone-plan.md` | every check that needs a human with a device, merged into one session | no limit; only when there are such checks; full mode only |

Both files go to ONE directory next to the evidence:
`<project evidence root>/digest-<YYYY-MM-DD>-<session-name>/` - for a pm
project `~/.claude/pm/<slug>/.shift/evidence/`; without one
`$CLAUDE_CONFIG_DIR/digests/` (`scripts/inventory.py` prints the suggestion).
A re-run overwrites both files; the previous pair is moved to `previous/`.
The inventory and the ledger the digest was built from stay in `work/` next
to them (`S<n>` in the digest = message n of `work/shown-messages.md`).

## Chat answer - sections, in this order

The Polish headings and field labels are literal. A section with nothing in
it is left out, except section 2.

**First line:** `Od Ciebie:` and a numbered list of what the user has to do,
each one action naming its object (decide X, test Y, answer Z) - or
`Od Ciebie: nic`.

Light only, the line right after the list:
`Wersja light: bez weryfikacji i bez planu telefonu. Pełna: /session-digest full <session>`
(the session as the user can type it - its name, else its uuid).

### `## 1. Pytania i zadania, z którymi weszliśmy`

One block per question or task the session was GIVEN - taken from what the
user typed and from the sources they handed over (a person's message, a
ticket's criteria), never from the names of the tasks the session created for
itself. Group by who asked; a ticket's criteria are one block with a table.

```
▸ <who asked>: "<their question, quoted, shortened>"
  Odpowiedź: <one or two sentences, the answer as it stands NOW>
  Pewność: <label, see below>
  Haczyki: <what the answer does not say on its own; 0-3 bullets>
  Co z tym: <blocks X / tell Y / nothing to do>
  Otwarte: <what is still unknown and what would settle it>
```

For a task (build, fix): `Odpowiedź:` is what now works on which screen, in
the user's words. For criteria: a table `Kryterium | Wynik | Pewność`, one
row each, footnotes under it.

### `## 2. Zmieniło się w trakcie`

Mandatory. Every claim the session SHOWED the user earlier (a sync, an
interim report, an answer) that the final state contradicts or narrows:

```
- <topic>. Wcześniej (<hh:mm>): <what was said>. Teraz: <what holds>. Dlaczego: <one sentence>.
```

Only reversals that change an answer or a decision; corrected wording is not
a reversal. Nothing reversed: `Nic się nie odwróciło.`

### `## 3. Decyzje dla Ciebie`

One block per decision the user has to make:

```
▸ <the decision, as a question>
  O co chodzi: <what the thing does / fixes, one sentence>
  Haczyk: <side effect or risk, one sentence>
  A) <option> - <what happens, what it costs>
  B) <option> - <what happens, what it costs>
  Domyślnie: <what happens if the user does nothing>
  Rekomendacja: <one option + one reason>
```

### `## 4. Do sprawdzenia ręcznie`

Only the summary; the steps live in `phone-plan.md`.

```
Setup raz: <build / install / account, one line>
| Blok | Temat | Kroków | Rozstrzyga |
Plik: <full path to phone-plan.md>
```

Light: no plan was merged, so the section points at where the steps are -
the NEWEST file per topic, never a superseded one:

```
| Temat | Plik | Nagłówek | Rozstrzyga |
Plan telefonu w jednym pliku: /session-digest full <session>
```

### `## 5. Kod`

`| Gałąź | Co na niej | Na origin? | Dalej |` - one row per branch the work
left; "Dalej" names who does what next (PR, cherry-pick, throw away).

### `## 6. Sprzątanie`

Every side effect on shared data or devices (test accounts, records left on
a dev backend, devices and dev servers left running), each with "zostawione,
usuń jeśli przeszkadza" or what was cleaned.

### `## Na dole`

- `Przebieg:` at most three lines - what ran, when, how it ended.
- `Decyzje podjęte za Ciebie:` only the ones that change how a result reads
  (e.g. "checked on a tablet simulator because the phone simulator lacks the
  feature, so the phone look is untested"), each "wybrane / odrzucone /
  dlaczego" in one line. Execution logistics (ordering, ports, worktrees)
  stay out.
- `Pliki:` the full paths of the files written (`digest.md`, and
  `phone-plan.md` in full mode).

### `**TL;DR:**`

LAST, always, in light and full, even when the answer is short: 2-4 full
sentences, no bullets - what got done, what did not and why, and the single
next action expected from the user. It is what a skimming reader reads
first, so it stands entirely on its own: no references to the sections
above ("patrz sekcja 3"), no question numbers. The rule taking-over's old
report had; the user asked for it back on 2026-11-22.

## Confidence labels (closed set)

Every answer and every table row carries exactly one, in the user's language:

| Label | Means |
|---|---|
| `widziane: <where>` | seen running - name the place: phone, simulator of <device>, browser, dev backend |
| `kod` | read in the code, not run |
| `dokumentacja: <source>` | stated by the vendor's or the project's documentation |
| `opinia` | judgement without a source |
| `niesprawdzone` | not established; `Otwarte:` names what would settle it |

An answer built from several gets the WEAKEST one in its headline; the rest
go to `digest.md`. A simulator result about something only a device can
show (suspension, biometrics, real sensors, real network) is `widziane:
simulator` and carries the device gap in `Otwarte:`.

## Writing rules

- **Every fact says what it means.** "X happens" alone is a defect; add
  whether it blocks, who should hear it, or that nothing follows.
- **Current state only, no layers.** When findings were redone (a second
  pass, an acceptance, a fix-up), the newest version wins and the chat answer
  shows only it; the history lives in section 2 (if it was shown to the user)
  and in `digest.md`.
- **No session vocabulary in sections 1-4:** run, pass, sub, tracker,
  acceptance, gate, agent, worker, shift, compaction, CONFIRMED / REFUTED /
  UNVERIFIED, question numbers (Q3, M8), ports, worktrees. Name the thing,
  not the bookkeeping.
- **No pointers instead of content.** "See findings.md" never replaces an
  answer; `Pełne:` paths belong in `digest.md`, the chat names only the two
  output files.
- **Identifiers carry a name on first use**, copied from the source (the
  ticket summary, the branch's purpose).
- **Each bullet stands alone**: no "as above", no "see earlier message".
- Short sentences, one fact each.

## `digest.md`

The chat answer's sections, expanded, plus:

- per block in section 1: `Źródła:` - each claim with `path` + heading of the
  NEWEST file that holds it, and the superseded files it replaces;
- the earlier versions of each answer with times, also those never shown to
  the user;
- under section 5, the commits per branch (hash + subject);
- `## Wszystkie decyzje` - every fork the session took on its own, from its
  decision log or state file: `| Wybrane | Odrzucone | Dlaczego |`, logistics
  included (the chat keeps only the ones that change how a result reads);
- `## Mapa plików` - every md file of the session in three groups: current
  (holds an answer), superseded (an older version of a current file), backstage
  (logistics, briefs, decision logs) - one line each with what it holds.

**Light writes only the first and third bullet** (`Źródła:` per block, the
commits per branch): no earlier versions, no `## Wszystkie decyzje`, no
`## Mapa plików` - the archive, not the answer, and `/session-digest full`
writes it. The chat answer is the same in both modes; section 2 still comes
from the earlier versions the ledger collected, they are just not copied
into the file. The extraction is never cut: a later pass often covers only
the gaps of an earlier one, so reading only the newest file per topic gives
incomplete answers and misses reversals between files.

## `phone-plan.md`

One sitting with the device, merged from every current source; superseded
files are never copied.

```
# Do sprawdzenia ręcznie: <topic> (<date>)

Na czym: <device, OS, build to install>. Czas: ~<minutes>.

## Przygotowanie (raz)
1. ...

## Blok 1: <topic> - rozstrzyga: <the open question it settles>
1. <one action>. Oczekiwane: <what should be seen>.
...
Zapisz: <what to note down for the answer>.

## Po wszystkim
- <cleanup on the device / account>
```

- Setup steps appear once, in `Przygotowanie`; blocks never repeat them.
- Every step is one action plus its expected result, written in full - no
  back-references, no "as in block 1".
- Order the blocks to avoid reinstalls and relogins; a block that needs a
  different build says so in its first line.
- Each block names the question it settles; a step that settles nothing is
  cut.
