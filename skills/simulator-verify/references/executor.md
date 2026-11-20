# Executor workers (optional)

Only for a session that runs as a `pm run-epic` / `pm work` worker (pm-cli's executor). A hand session or any other orchestrator can ignore this file.

- **Inside an executor run (a `pm run-epic` / `pm work` worker) the slot env is ALREADY set** - `SIM_UDID`, `WDA_PORT` and `ADDITIONAL_METRO_PORT` are in your process (`printenv SIM_UDID` shows them). Do NOT `export` them and do NOT prefix a command with `SIM_UDID=... scripts/sim-ui.sh`: the worker's allowlist is a literal prefix match on the command you type, and both forms are refused. Call the scripts by the absolute path the `## Runtime rig` section of your prompt lists - `<your worktree>/.claude/skills/simulator-verify/scripts/sim-ui.sh ...` - never `sh <script>` / `bash <script>` (a different prefix, refused). `xcrun simctl`, `curl`, `python3` and `printenv` are allowed under their plain names.

The project-local install exists for the same reason: `pm executor doctor` resolves the runtime skill only under `<repo>/.claude/skills`, so `install.sh --project` links this skill there (see the comment in `install.sh`).
