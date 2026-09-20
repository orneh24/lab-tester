#!/bin/sh
# dev/hub-start.sh — start a local lab-tester hub for dev/demo use.
# See dev/README.md.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$ROOT/dev/run"
mkdir -p "$RUN_DIR"

HUB_PORT="${HUB_PORT:-8099}"
HUB_SYSLOG_PORT="${HUB_SYSLOG_PORT:-5514}"

if [ -f "$RUN_DIR/hub.pid" ] && kill -0 "$(cat "$RUN_DIR/hub.pid")" 2>/dev/null; then
    echo "Hub already running (pid $(cat "$RUN_DIR/hub.pid")) — http://127.0.0.1:${HUB_PORT}/"
    exit 0
fi

# Populate hub/agent/ the way build-template.sh does at build time. It's
# gitignored and doesn't exist in a fresh checkout; the hub's /agent/manifest
# route serves whatever is physically here (hub/app/app.py's AGENT_DIR).
# test-status.sh is deliberately NOT copied — it isn't in AGENT_SCRIPTS and
# never self-updates (CLAUDE.md, "Agent self-update").
mkdir -p "$ROOT/hub/agent"
cp -f "$ROOT/node/scripts/register.sh" "$ROOT/node/scripts/test-cycle.sh" "$ROOT/hub/agent/"

export HUB_PORT HUB_SYSLOG_PORT
export HUB_DB_PATH="$RUN_DIR/hub.db"
# Root is needed for the real port 514; this box has none, so keep syslog on
# an unprivileged port like the README's "Running the hub locally" already
# recommends, rather than have start() silently fail to bind.

( cd "$ROOT/hub" && exec python3 serve.py ) >"$RUN_DIR/hub.log" 2>&1 &
echo $! > "$RUN_DIR/hub.pid"

sleep 1
if ! kill -0 "$(cat "$RUN_DIR/hub.pid")" 2>/dev/null; then
    echo "Hub failed to start — see $RUN_DIR/hub.log" >&2
    exit 1
fi

echo "Hub running at http://127.0.0.1:${HUB_PORT}/ (pid $(cat "$RUN_DIR/hub.pid"))"
echo "Syslog viewer: http://127.0.0.1:${HUB_PORT}/syslog"
echo "Log: $RUN_DIR/hub.log   DB: $RUN_DIR/hub.db"
echo "Stop with: dev/hub-stop.sh"
