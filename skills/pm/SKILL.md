---
name: pm
description: Manages freelance project tasks. Use when user says "/pm", asks about project status, wants to add/update/list tasks, or mentions task tracking. Dispatches to pm MCP tools.
---

# Project Manager (pm)

Dispatch layer for the `pm` MCP server. All data lives in `~/.claude/pm/` as markdown files with YAML frontmatter.

## Command Routing

| Command | MCP Tool | Notes |
|---------|----------|-------|
| `/pm` | `pm_context` | Cross-project overview (all doing tasks, counts) |
| `/pm <project>` | `pm_context` (project=slug) | Project detail with active tasks |
| `/pm add <project> "title"` | `pm_add_task` | Create task enriched with conversation context |
| `/pm update <project> <task-id>` | `pm_update_task` | Append progress notes, merge links |
| `/pm done <project> <task-id>` | `pm_move_task` (new_status = last project status) | Mark complete |
| `/pm archive <project> <task-id>` | `pm_move_task` (new_status = archived) | Hide from board |
| `/pm unarchive <project> <task-id>` | `pm_move_task` (new_status = first project status) | Restore to board |
| `/pm brief <project> <task-id>` | `pm_update_task` (brief=...) | Summarize current session state into task's brief field |
| `/pm info <project>` | `pm_context` for reading | Show project info |
| `/pm info <project> update` | `pm_update_project` | Update project metadata (links merge, tags/statuses replace, scalars overwrite) |

## Task Creation Rules

When creating tasks with `pm_add_task`:
- Enrich from conversation context: include relevant technical details, links, branch names
- Use descriptive link keys: `azure`, `pr`, `slack`, `figma`, `sentry`, `jira` (freeform key=url)
- Body should include sections as needed: description, context, acceptance criteria, next steps
- `## Acceptance Criteria` - what must be true for the task to be done. Only criteria the user stated or clearly implied. Never invent criteria.
- Status defaults to the first project status (usually `todo`)

## Task Update Rules

When updating tasks with `pm_update_task`:
- **Links merge** — new links are added, existing ones are never removed
- **Body appends** — use `body_append` to add notes; existing content is never replaced
- **Tags replace** — if `tags` is provided, it replaces the entire tags list
- **Brief overwrites** — latest brief replaces previous (current state, not history)
- Always set `updated` to today (handled automatically by the tool)

## Brief Field

The `brief` field stores a short session context summary in task frontmatter. Use it to capture "where we left off" so the next session can pick up immediately.

- **Overwrites** each time (not append) - it's "current state", not history
- **Cleared on done/archive** - no longer relevant once task is complete
- **Returned by pm_context** - CC reads it at session start to resume context
- Use `/pm brief <project> <task-id>` or `pm_update_task` with `brief` param

### How to write a brief (`/pm brief`)

When user says `/pm brief <project> <task-id>`, generate a brief from the current conversation and save it via `pm_update_task` with `brief` param.

**Required sections** (use these exact headers):

```
Goal: <one-liner - what we're doing and why>

Decisions:
- <key decision 1>
- <key decision 2>

Status:
- Done: <what's completed>
- TODO: <what remains>
- Blocker: <if any - PRs waiting, questions pending, external deps>

Files:
- <path/to/key/file.go> - <why it matters>
- <path/to/another.ts> - <what was changed/needs change>
```

Guidelines:
- Be thorough - this is the only context the next session gets
- Plain text, no markdown headers (just the labels above)
- Include concrete values: PR numbers, branch names, error messages, line numbers
- "Decisions" = choices made AND rejected alternatives worth remembering
- "Files" = only files actively relevant, not every file touched

If no task-id is given but there's an obvious "doing" task from conversation context, use that one. If ambiguous, ask.

## Important

- Statuses are per-project (configured in project.yaml) — don't assume todo/doing/done
- `archived` is a system-level status — never include in a project's `statuses` list
- Links are freeform `map[string]string` — any key=url pair is valid
- Task filenames: `<id>-<slugified-title>.md`
