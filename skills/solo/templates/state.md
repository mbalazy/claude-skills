# solo <shift-id>

## Status: open <started-ts>
project: <slug> · repo: <path> · base: <branch>@<sha at start>
runtime: <sim|web|off> · reason: <declared by pm executor show | --flag | doctor failed>
flags: <--push --pr --max-tasks N --max-hours H>
window: <output of scripts/window.sh, e.g. 400k (flag --autocompact) | 400k (settings <config-dir>/settings.json)>
budget: <120 | N (queue of one: max-hours*60-30)>
env: SIM_UDID=<...> WDA_PORT=<...> WEB_PORT=<...>   (from the runtime skill's config)
rig: <not checked | OK <ts> | DEAD <ts>: <verdict> | cold start attempted <ts>: <result>>

## Queue
<task-id> · <title> · <todo|doing> · runtime <yes|no> · after <base | dep-id ...>
...

## Progress
<task-id> · <started-ts> · step <n> · <doing|done|parked: why|untouched: waits for <dep-id> (<why>)> · <branch>@<sha> · from <base|dep-branch> · <minutes> · runtime <CONFIRMED n / REFUTED n / UNVERIFIED n | off>
...

## Checkpoints (current task)
- [ ] <what · files · verified by>

## Decisions
- <ts> <task-id>: chose X over Y because Z

## Cleanup
- <what> · <skasowane | zostawione, skasuj jeśli zbędne>

## Compactions noticed
- <ts> resumed at <task-id> step <n>

## Log
(append-only, written by scripts/note.sh - keep this section LAST)
