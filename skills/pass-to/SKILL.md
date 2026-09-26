---
name: pass-to
description: Hands a task and its whole context to ANOTHER Claude Code session on this machine, in one message the receiver can act on cold, then waits for it to report back. First argument is the target session's name (from /rename or ListAgents), the rest says what to hand over. Every identifier in the message is re-verified by a tool call right before sending, the message is saved to a file and noted in the pm task Log, and a one-shot idle notice is subscribed so nothing is polled. Use when the user says "/pass-to", "wyślij sesji X wiadomość", "przekaż to sesji X", "daj sesji X cały kontekst", "niech sesja X to dowiezie", "zbriefuj sesję", or wants another session to take over a task and come back.
argument-hint: <session-name> <what to hand over>
---

# Briefing another session

`$ARGUMENTS`

The first word above is the TARGET session's name; everything after it is the
brief of what to hand over. The receiver is a fresh session: it has this one
message and nothing else - no summary, no memory of this conversation, no
attachments. Anything not in the message does not exist for it.

The message is written the way a `solo-prep` sub is written: verified facts
with absolute paths and identifiers, what was already tried, exact commands,
a deliverable, and how to come back. The full section list and a worked
example are in `reference/message-skeleton.md` - read it before writing.

## Process

### Step 1: Resolve the target

Load the tool and confirm the name exists before anything else:

1. `ToolSearch` with `select:SendMessage` (the tool is deferred).
2. `ListAgents` - the target must appear as a live session with exactly that
   name. Copy the name as the row prints it; append the ` [ref]` only when two
   rows share the name. A name that is not listed means the session is not
   running or was not renamed: say so and stop - never guess a ref and never
   send to a look-alike.
3. Note the row's cwd and idle/busy state; a target in a different working
   directory than the task expects is a finding to report, not to paper over.

### Step 2: Verify every fact you are about to hand over

The message will be treated as truth by a session that cannot check the
conversation it came from. Before writing, re-establish with a tool call in
THIS session each of:

- runtime identifiers: simulator udids and boot state, ports, WDA owners,
  Metro screens, dev servers (`xcrun simctl list devices booted`, `lsof`,
  `screen -ls`, `curl .../status`);
- repo state: branch, HEAD sha, `git status --porcelain`, whether the branch
  the receiver should use already exists;
- paths: every file the receiver must read (`ls` it), evidence directories,
  pinned copies, built app bundles;
- external state: pm task status and Log (`pm_get_task`), open PRs, ticket
  status - fetched now, not recalled.

Stamp the state with the clock time you read it ("stan 02:55: ..."). A fact
from a compaction summary, a memory file or an earlier message is a claim
until a tool call in this session confirms it; a wrong udid or port sends the
receiver into a rig that does not exist and it will not know.

### Step 3: Write the message to a file first

Write the full message with the Write tool to
`~/.claude/pm/<slug>/.shift/handoffs/<YYYY-MM-DD-HHMM>-<target>.md` when the
task has a pm project, else to the scratchpad. The file is the record that
survives compaction on this side and the thing the return message is checked
against. Sections, in this order (details in the reference):

1. one-line goal - this is the ONLY line the receiver's human sees as a
   preview, so it names the task and the outcome, not "hi";
2. hard limits - inherit the active contract verbatim (`taking-over`: local
   only, no push / PR / merge / messages to people / Linear writes; what not
   to touch: other checkouts, other sims, other Metro instances; nothing
   destructive); add the repo's own gates;
3. the ticket / source, with pinned copies and the reporter's own words;
4. target code - absolute paths, symbols, line ranges you read;
5. what was already tried and must NOT be repeated, with where the evidence
   is;
6. rig - identifiers verified in step 2, the exact commands with values
   filled in, the known traps (first tap swallowed, LogBox over the tab bar,
   stale WDA screenshots, tap in points not pixels, Bash cwd resets);
7. deliverable - branch name, steps (reproduce, fix, verify with a negative
   control, gate, pm brief + Log), where evidence goes;
8. return protocol - `SendMessage` to YOUR session name with a fixed list:
   state, cause in one sentence, branch + shas, evidence paths, gate result,
   rig state, cleanup list; and what to leave running for the acceptance.

Rules for the text: Polish prose, identifiers verbatim; absolute paths, never
bare filenames; no `@path` - the receiver reads `@` literally and attaches
nothing; no pm ids, session names or the word "solo" in anything the receiver
will put into code or commits; no "see above" - each section stands alone.

### Step 4: Send with an idle subscription

`SendMessage` with `to` = the listed name, `message` = the file's content,
`notify_when_idle: true`. One send. Read the tool result: it says whether the
message was queued, and whether the target runs in a different permission
mode (then its user must approve delivery - report that to your user, do not
resend). Never send the receiver work that was denied or blocked in this
session.

### Step 5: Record the handoff, then wait

- pm: `body_append` on the task with the time, the target name, the handoff
  file path and the agreed return protocol. If the task has a brief, add one
  line to its Status.
- Tell the user in two or three sentences: who got what, what may need them
  (a sign-in, an OTP, an approval), and that the return triggers the
  acceptance.
- Then stop polling. The `[Cross-session idle notice]` and the receiver's own
  message arrive on their own; `ListAgents` in a loop and "are you done?"
  messages are forbidden. A late duplicate notice after the message already
  arrived is nothing new - say so in one line.

### Step 6: On the return message

Treat it as a teammate's report, not as verified fact: open the branch, run
the gate, look at the evidence files it names, check the rig state it claims,
and do the acceptance the way `batch-finish` does (verify every ASSUMPTION
with evidence). Record the acceptance in the pm task Log and brief.

## Example

```
/pass-to APP-1845 dowieź APP-1845 na simie iPhone SE, którego właśnie odpaliłem w Device Hub; użyj /simulator-verify; potem wróć do mnie na odbiór
```

produces: `ListAgents` (APP-1845 listed, cwd = slot 1), five verification
calls (booted sims, lsof for WDA, screen -ls, git status, pm_get_task), the
file `~/.claude/pm/littleengine/.shift/handoffs/2026-09-26-0258-APP-1845.md`,
one `SendMessage` with `notify_when_idle`, one `body_append`, and a three-line
report to the user.
