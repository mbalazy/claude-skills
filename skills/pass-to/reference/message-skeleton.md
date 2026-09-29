# The handoff message - skeleton and a worked example

The receiver runs alone. Every section answers one question it would
otherwise have to ask - and it cannot ask.

## Skeleton

```
<one line: task key + outcome + where it runs + who to report to>

## 1. Rules
- contract in force (taking-over: local only, zero push / PR / merge / Linear /
  messages to people); what must not be touched (paths, sims, ports, other
  sessions' checkouts); nothing destructive (no deleting sims, branches, data)
- repo rules that bite (AGENTS.md items relevant to THIS task)
- identifiers that must not leak into code / commits
- tool quirks: Bash cwd resets between calls, PATH additions, Metro never as
  a background task

## 2. Ticket / source
- key, title, reporter, date, environment, device, build
- reporter's scenario in their words; what is NOT known (gesture, video)
- pinned copies: absolute paths (ticket text, screenshots, contracts)

## 3. Code
- absolute path + symbol + line range for every file the receiver must read
- shared components: name their consumers and the blast-radius rule
- related unmerged branches that touch the same area

## 4. Already done - do not repeat
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

## 6. What to deliver
- branch (exists? sha) and the naming rule the hook enforces
- steps: reproduce (record the cause before fixing) -> fix within scope ->
  verify with a negative control on the base code -> gate command(s) ->
  pm task: read brief + Log first, attach the session, body_append findings,
  final brief in the project's format; do not change status
- evidence directory and file prefix

## 7. Report back
- SendMessage to <your session name> with: state (fixed / partial /
  not reproduced), cause in one sentence, branch + commit shas, evidence
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
Task: deliver APP-1845 (overscroll on the summary step of the invite in
"Add a client") on the iPhone SE simulator, locally, and report to session
`solo-prep-1`, which will do the acceptance. You work in
/Users/mart/repos/littleEngine/app.littleengine-additional (pm worktree slot 1).

## 1. Rules (hard, unattended session, "taking-over, local only" mode)
- Everything stays local: ZERO git push, ZERO PRs, ... Marcin opens the PR.
- Do not touch the main checkout ... or sims 2CE98C80 / E31D24EE / EBC3D758
  (EBC3D758 is shut down - you may only READ files from its disk).
- Bash does not keep cd between calls - start every command with cd ...

## 2. Ticket
Linear APP-1845 ..., iPhone SE (750x1334 px = 375x667 pt), iOS 26.6, build
0.1.1 (20260924133408) ... Reporter's screenshot: /Users/mart/.claude/pm/
littleengine/evidence/solo-2026-09-25/app-1845-reporter-screenshot-2026-09-25.png

## 3. Code
- src/screens/clients/addCustomerFlow/components/FlowTranscript.tsx ~730-775:
  SummaryWidget ... SUMMARY_SHRINK_STYLE line 47 ...

## 4. What the previous session already did - do NOT repeat
Not reproduced on 402x874 across five hypotheses: (H1) ... (H5) ... Evidence:
/Users/mart/.claude/pm/littleengine/.shift/evidence/littleengine-186-1/
Cleanup note: an invite was sent to (512) 555-0189; use 512 555 02xx.

## 5. Rig
- Sim: udid B1831F4E-1BB9-4246-AA23-CCFD48F88CCE, iOS 27.0, Booted, 375x667
  pt. State at 02:55: NO app and NO WDA. Metro :8090 is up (screen metro8090).
  1. xcrun simctl install B1831F4E-... "<path to Little Engine.app>"
  2. WDA: xcrun simctl install B1831F4E-... <WebDriverAgentRunner-Runner.app
     from the slot>, then SIMCTL_CHILD_USE_PORT=8102 xcrun simctl launch ...
  3. Session without OTP: shut the sim DOWN, rsync the data container + Keychains from the slot
  4. If the app is signed out: do NOT sign in yourself; write to Marcin in the
     terminal and send the same to solo-prep-1.
  5. rig-check.sh --repo "$PWD" --udid B1831F4E-... --port 8090 --bundle-id
     com.littleengine.development must print RIG OK.

## 6. What to deliver
- Branch APP-1845-add-client-invite-summary-overscroll exists locally at
  7e0d5a8d8 with no commits - check it out, do not create a new one.
- Step 1 reproduce ... Step 2 fix ... Step 3 verify with a negative
  control ... Step 4 gate: node .../validate.js, yarn perf:test ALONE,
  yarn test:unit ... Step 5 pm: littleengine-186-1 ...

## 7. Report back
SendMessage to solo-prep-1 with: state, cause in one sentence, branch +
sha, evidence paths, gate result, rig state, Cleanup list. Leave the SE
sim booted with the app on the summary step and the branch checked out.
```
