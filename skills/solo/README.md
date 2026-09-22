# solo

One unattended Claude Code session working a queue of pm tasks while the user
is away. The procedure is `SKILL.md`; the per-task prompts are in `prompts/`,
the shift state template in `templates/`, and the scripts the procedure calls
in `scripts/` (the guard hook, the shift open/close, the launch check, the
compaction counter).

## Requires

- **pm-cli 0.66.0 or newer** - <https://github.com/mbalazy/pm-cli>. The skill
  reads the queue and the project's executor profile from pm (`pm session-id`,
  `pm executor show`, `pm executor doctor`, the `pm` MCP tools) and pm reads the
  shift's state file and report back from the project's `.shift/` directory.
  The report's section headings are a contract with pm's parser: change them in
  both places or in neither.
- **Claude Code** with the guard hook installed as a `PreToolUse` hook:

  ```json
  {"matcher": "Bash|mcp__.*",
   "hooks": [{"type": "command", "command": "python3 ~/.claude/skills/solo/scripts/guard.py"}]}
  ```

  The hook only acts in a session that carries a marker under
  `~/.claude/solo/<session-id>.active`; every other session passes through.
- A launcher for unattended runs: `claude --dangerously-skip-permissions
  --autocompact 400k` (bypass rather than `auto`, because the auto classifier
  falls back to prompting after a few blocks and nobody is there to answer).
  Most people keep it behind a shell abbreviation and name it in their
  CLAUDE.md; `solo-prep` writes the launch block with that launcher.

## Launch

```
cd <repo>
<launcher> --model <model>
/solo <tracker-or-task-ids> <--web|--sim|--no-runtime> [--base <branch>] [--max-hours H]
```

`/solo resume` continues a shift that a session left open. The morning after,
`/solo-retro` reads what the shift left behind.
