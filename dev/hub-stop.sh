#!/bin/sh
# dev/hub-stop.sh — stop the hub started by dev/hub-start.sh.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="$ROOT/dev/run/hub.pid"

if [ ! -f "$PID_FILE" ]; then
    echo "No pidfile at $PID_FILE — hub not started by dev/hub-start.sh, or already stopped."
    exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    echo "Stopped hub (pid $PID)"
else
    echo "No process at pid $PID — already stopped"
fi
rm -f "$PID_FILE"
