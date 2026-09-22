# Draft and write the seed

Input: the facts file from `gather.py`. Output: a printed draft; after the
user's go, the writes.

A timeline records what happened TO the project. What happened inside a task
is that task's Log - the entry is the task landing, not its story.

## The state (exactly one)

10-20 lines, fits on a screen, as of today, in the language of the project's
notes and briefs:

```
Where we stand: ...
Blocks: ...
Next: ...
Open questions: ...
Links: ...
```

- Drawn from the in-progress briefs and waiting_for, the notes, the newest
  landed tasks and the knowledge-base section.
- An undated fact belongs here, never in a dated entry.
- Name the tasks behind a line by id, so the reader can open them.

## Dated entries (`event`, `decision`)

- Only for a fact whose date is in the facts file: the first commit, a merge
  into the base, a tag, a dated CHANGELOG heading, a landed task.
- A landed task is dated by its `git:` line (the merge of its branch, else
  the commits naming it) - that is when the work landed. Its status-change
  date only when it has no `git:` line AND the date is not marked as a bulk
  move (a clean-up that moved many tasks the same day). A `(last edit)` date
  or a bulk-move date never dates an entry: that milestone goes into the
  state undated, or is left out.
- `event` = something happened to the project (it started, a feature landed,
  a release). `decision` = a direction chosen, one sentence plus the ref to
  where it is recorded.
- Milestones, not a log: 5-15 entries a newcomer needs. Skip routine fixes,
  chores, version bumps.
- 1-3 sentences each. `refs` name the source: a task id, `git:<sha>` as
  printed, a tag, a doc path.
- The date is the source's date exactly as printed. No source date = no
  dated entry.

## Print the draft

Number the entries so the user can strike them:

```
Timeline seed for <slug> - nothing written yet

STATE (today)
<the state lines>

ENTRIES (oldest first)
1. YYYY-MM-DD event     <text>   refs: <ref>, <ref>
2. YYYY-MM-DD decision  <text>   refs: <ref>

Sources: <facts file>. "zapisz" writes all of it; name numbers to strike; anything else writes nothing.
```

## Write (only after the go)

Entries oldest first, the state last (dated today, so the default read starts
from it):

```bash
pm timeline add -p '<slug>' --kind event --date YYYY-MM-DD --ref '<ref>' --ref '<ref>' --text '<text>'
pm timeline add -p '<slug>' --kind state --text - <<'STATE'
<the state lines>
STATE
```

- One `--ref` per reference. Every value in single quotes - a ref can be a
  path with a space or a URL with `?` / `&`; a `'` inside a value becomes `'\''`.
- A failed add: stop, show the error and which entries were already written.
  Never retry a whole batch - entries are never edited, and a duplicate stays.
- Finish with `pm timeline <slug>`: the state, nothing after it.
