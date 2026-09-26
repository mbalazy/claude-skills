# The handoff message - skeleton and a worked example

The receiver runs alone. Every section answers one question it would
otherwise have to ask - and it cannot ask.

## Skeleton

```
<one line: task key + outcome + where it runs + who to report to>

## 1. Zasady
- contract in force (taking-over: lokalnie, zero push / PR / merge / Linear /
  wiadomości do ludzi); what must not be touched (paths, sims, ports, other
  sessions' checkouts); nothing destructive (no deleting sims, branches, data)
- repo rules that bite (AGENTS.md items relevant to THIS task)
- identifiers that must not leak into code / commits
- tool quirks: Bash cwd resets between calls, PATH additions, Metro never as
  a background task

## 2. Ticket / source
- key, title, reporter, date, environment, device, build
- reporter's scenario in their words; what is NOT known (gesture, video)
- pinned copies: absolute paths (ticket text, screenshots, contracts)

## 3. Kod
- absolute path + symbol + line range for every file the receiver must read
- shared components: name their consumers and the blast-radius rule
- related unmerged branches that touch the same area

## 4. Co już zrobiono - nie powtarzać
- each hypothesis / attempt, its result, where its evidence is
- side effects left behind (test records created, invites sent, events
  deleted) and which test data to use next

## 5. Rig
- verified state with clock time: sims (udid, runtime, size, booted?),
  installed apps, WDA ports and owners, Metro port + screen, checkout branch
  + sha + cleanliness
- exact commands with values filled in: install / transplant / boot / WDA
  start / rig-check / driver exports
- fallback that needs the human (sign-in, OTP, approval) and how to raise it
- traps: first tap swallowed, LogBox banner over the tab bar, WDA screenshot
  returns a stale frame, taps in points not pixels, reading the a11y tree
  mounts lazy tabs

## 6. Co dowieźć
- branch (exists? sha) and the naming rule the hook enforces
- steps: reproduce (record the cause before fixing) -> fix within scope ->
  verify with a negative control on the base code -> gate command(s) ->
  pm task: read brief + Log first, attach the session, body_append findings,
  final brief in the project's format; do not change status
- evidence directory and file prefix

## 7. Powrót
- SendMessage to <your session name> with: state (naprawione / częściowo /
  nie odtworzone), cause in one sentence, branch + commit shas, evidence
  paths, gate result, rig state (sim, WDA port, signed in?), cleanup list
- what to leave running / checked out for the acceptance
```

## Why each rule exists

- **First line is the preview.** The receiving human sees only the first line
  until they expand the message. A greeting there hides the task.
- **Verified, timestamped state.** The receiver will `simctl launch` on the
  udid you give it. A udid recalled from a compaction summary can name a sim
  that was deleted an hour ago; it fails silently or hangs.
- **"Already tried" with evidence paths.** Without it the receiver repeats
  the same five hypotheses and burns the same 22 minutes.
- **Fallbacks that need the human, named.** A fresh session told "never sign
  in" and nothing else parks the whole task; told "write in your terminal
  that Marcin must sign in, and message solo-prep-1" it unblocks in a minute.
- **Fixed return list.** The acceptance checks the branch, the gate and the
  evidence; a return message that omits the shas or the rig state costs a
  round trip.
- **Save the file before sending.** The sender's own context compacts too;
  the file is what the acceptance is checked against.

## Worked example (trimmed)

Sent 2026-09-26 02:58 from `solo-prep-1` to `APP-1845`, after the night shift
had parked the ticket as "not reproduced on a 402pt sim, SE sim would not
launch" and the user had booted a real iPhone SE simulator:

```
Zadanie: dowieź APP-1845 (overscroll na kroku podsumowania zaproszenia w
"Add a client") na symulatorze iPhone SE, lokalnie, i zgłoś się do sesji
`solo-prep-1`, która zrobi odbiór. Pracujesz w
/Users/mart/repos/littleEngine/app.littleengine-additional (pm worktree slot 1).

## 1. Zasady (twarde, sesja bez nadzoru, tryb "taking-over, tylko lokalnie")
- Wszystko zostaje lokalnie: ZERO git push, ZERO PR-ów, ... PR otworzy Marcin.
- Nie dotykaj głównego checkoutu ... ani simów 2CE98C80 / E31D24EE / EBC3D758
  (EBC3D758 jest wyłączony - możesz z niego tylko CZYTAĆ pliki z dysku).
- Bash nie pamięta cd między wywołaniami - każdą komendę zaczynaj od cd ...

## 2. Ticket
Linear APP-1845 ..., iPhone SE (750x1334 px = 375x667 pt), iOS 26.6, build
0.1.1 (20260924133408) ... Zrzut zgłaszającego: /Users/mart/.claude/pm/
littleengine/evidence/solo-2026-09-25/app-1845-reporter-screenshot-2026-09-25.png

## 3. Kod
- src/screens/clients/addCustomerFlow/components/FlowTranscript.tsx ~730-775:
  SummaryWidget ... SUMMARY_SHRINK_STYLE linia 47 ...

## 4. Co już zrobiła poprzednia sesja - NIE powtarzaj
Nie odtworzono na 402x874 w pięciu hipotezach: (H1) ... (H5) ... Dowody:
/Users/mart/.claude/pm/littleengine/.shift/evidence/littleengine-186-1/
Uwaga Cleanup: wysłano zaproszenie do (512) 555-0189; używaj 512 555 02xx.

## 5. Rig
- Sim: udid B1831F4E-1BB9-4246-AA23-CCFD48F88CCE, iOS 27.0, Booted, 375x667
  pt. Stan 02:55: BEZ apki i BEZ WDA. Metro :8090 działa (screen metro8090).
  1. xcrun simctl install B1831F4E-... "<ścieżka Little Engine.app>"
  2. WDA: xcrun simctl install B1831F4E-... <WebDriverAgentRunner-Runner.app
     ze slotu>, potem SIMCTL_CHILD_USE_PORT=8102 xcrun simctl launch ...
  3. Sesja bez OTP: sim WYŁĄCZ, rsync kontenera danych + Keychains ze slotu
  4. Jeśli apka wylogowana: NIE loguj się sam; napisz Marcinowi w terminalu
     i wyślij to samo do solo-prep-1.
  5. rig-check.sh --repo "$PWD" --udid B1831F4E-... --port 8090 --bundle-id
     com.littleengine.development musi wypisać RIG OK.

## 6. Co dowieźć
- Gałąź APP-1845-add-client-invite-summary-overscroll istnieje lokalnie na
  7e0d5a8d8 bez commitów - checkout, nie twórz nowej.
- Krok 1 reprodukcja ... Krok 2 fix ... Krok 3 weryfikacja z kontrolą
  negatywną ... Krok 4 bramka: node .../validate.js, yarn perf:test SAMO,
  yarn test:unit ... Krok 5 pm: littleengine-186-1 ...

## 7. Powrót
SendMessage do solo-prep-1 z: stanem, przyczyną jednym zdaniem, gałęzią +
sha, ścieżkami dowodów, wynikiem bramki, stanem rigu, listą Cleanup. Zostaw
sim SE zabootowany z apką na kroku podsumowania i gałąź wycheckoutowaną.
```
