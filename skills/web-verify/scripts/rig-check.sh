#!/usr/bin/env bash
# rig-check.sh - prove the dev server on the port serves YOUR tree before you
# trust any reading. The web counterpart of simulator-verify's rig-check.sh.
#
# What it checks is the EFFECT, not a port number: the process LISTENING on the
# port must have the tree under test as its working directory (a dev server
# serves its cwd), and a GET must answer. A port held by another tree's server
# is RIG DEAD with the owner named - and is never touched.
#
# Usage:
#   rig-check.sh --repo DIR --port N [--start] [--cmd 'CMD'] [--path /] [--api-path R]... [--mount SEL] [--timeout S]
#     --repo DIR     tree that must be served (default: git root of cwd)
#     --port N       dev server port (default: $WEB_PORT)
#     --start        start the server when nothing listens (warm start, capped
#                    by --timeout; never when something else holds the port)
#     --cmd CMD      start command, `sh -c` in DIR with PORT set
#                    (default: npm run dev -- -p "$PORT")
#     --path P       route to GET (default: /)
#     --api-path R   an API route to GET too (repeatable). ECONNREFUSED, a
#                    timeout or a 5xx there is RIG DEAD naming the route; a 4xx
#                    is fine - the server answered. A page renders from cache
#                    long after the API behind it died, and readings taken then
#                    look normal and are false. With no --api-path on the
#                    command line the routes come from the project's config
#                    (`api_probe:` in <repo>/.web-verify/config.md).
#     --mount SEL    require SEL (default h1) to render non-empty text in a
#                    headless browser - a server that answers is not an app
#                    that mounted (a Vite with stale deps serves 200 + a blank
#                    page); `--mount ''` skips it
#     --timeout S    seconds to wait for the port / the first response (default 120)
#
# Prints ONE verdict line: `RIG OK: ...` (exit 0) or `RIG DEAD: <why>` (exit 1)
# - `RIG DEAD: served but the app did not mount (...)` is the mount probe.
# As executor.rig (pm run-epic / pm work --additional) it runs once per run in
# the claimed slot with the slot's env, so `--repo "$PWD" --port "$WEB_PORT"`.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find --repo among the arguments so the config can be located; no --repo means
# the git root of the cwd, the same default dev-server.mjs uses.
REPO=""
HAS_API=0
prev=""
for a in "$@"; do
  [ "$prev" = "--repo" ] && REPO="$a"
  [ "$a" = "--api-path" ] && HAS_API=1
  prev="$a"
done
[ -n "$REPO" ] || REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"

# api_probe: from the project config, only when the caller named no route.
# Accepted shapes in <repo>/.web-verify/config.md:
#   - **api_probe**: `/api/health`, `/api/pools`
#   api_probe: /api/health
#   api_probe:
#     - /api/health
EXTRA=()
CONFIG="$REPO/.web-verify/config.md"
if [ "$HAS_API" = "0" ] && [ -n "$REPO" ] && [ -f "$CONFIG" ]; then
  while IFS= read -r route; do
    [ -n "$route" ] && EXTRA+=(--api-path "$route")
  done < <(awk '
    function emit(s,   i, n, parts) {
      gsub(/[`,]/, " ", s)
      n = split(s, parts, /[ \t]+/)
      for (i = 1; i <= n; i++) if (parts[i] ~ /^\//) print parts[i]
    }
    /api_probe[*_ ]*:/ {
      line = $0
      sub(/^.*api_probe[^:]*:/, "", line)
      emit(line)
      collecting = 1
      next
    }
    collecting {
      if ($0 ~ /^[ \t]*[-*][ \t]+`?\//) { emit($0); next }
      if ($0 ~ /^[ \t]*$/) next
      collecting = 0
    }
  ' "$CONFIG")
fi

exec node "$SCRIPT_DIR/dev-server.mjs" check "$@" ${EXTRA+"${EXTRA[@]}"}
