#!/bin/sh
# test-status.sh — Show this node's own last test cycle on demand.
#
# test-cycle.sh already fans its per-cycle summary out to /dev/console, but
# an SSH session never sees /dev/console — this is the pull-equivalent for
# that case, and for a console session that missed the moment it scrolled
# past. Reads only local files; no hub round trip, so it works even when the
# node can't reach the hub (which is exactly when it's most useful).

set -u

SNAPSHOT_FILE="${SNAPSHOT_FILE:-/run/mesh-probe/last-cycle.txt}"
LOG_FILE="${LOG_FILE:-/var/log/mesh-probe/test-cycle.log}"

usage() {
    cat <<EOF
Usage: test-status [-f|--follow] [-n N] [-h]

  (no args)     Show the last test cycle.
  -f, --follow  Reprint the summary each time a new cycle completes.
  -n N          Show the last N cycle summaries from test-cycle.log.
  -h, --help    This help.
EOF
}

show_last() {
    if [ -f "$SNAPSHOT_FILE" ]; then
        cat "$SNAPSHOT_FILE"
    else
        echo "No test cycle has completed yet (no $SNAPSHOT_FILE)."
        echo "Check that crond is running and /etc/mesh-probe/config is set up."
    fi
}

# Poll the snapshot's mtime rather than tailing the log: the log accumulates
# every log() line test-cycle.sh emits (one per test attempted), not just the
# rendered summary, so a raw tail -f would interleave the table with
# "HTTP test -> 10.1.2.5"-style progress lines.
follow_last() {
    _last_mtime=""
    show_last
    while true; do
        sleep 2
        if [ -f "$SNAPSHOT_FILE" ]; then
            _mtime=$(stat -c '%Y' "$SNAPSHOT_FILE" 2>/dev/null || echo "")
            if [ -n "$_mtime" ] && [ "$_mtime" != "$_last_mtime" ]; then
                _last_mtime="$_mtime"
                printf '\n'
                show_last
            fi
        fi
    done
}

# Reconstruct the last N rendered summaries from the log. Each summary block
# starts with a "<hostname>   <date>   <n> targets" title line (ending
# " targets") and ends with the "N ok / N fail   ->  hub NNN" footer line
# (containing "-> ") — the same shape render_summary() in test-cycle.sh
# writes to stdout every cycle. log()'s own lines never match either pattern.
show_history() {
    _n="$1"
    if [ ! -f "$LOG_FILE" ]; then
        echo "No log at $LOG_FILE."
        return 1
    fi
    awk -v n="$_n" -v logfile="$LOG_FILE" '
        / targets$/ { buf = "" }
        { buf = buf $0 "\n" }
        /-> +hub/ { cycles[++c] = buf }
        END {
            start = (c > n) ? c - n + 1 : 1
            for (i = start; i <= c; i++) {
                printf "%s", cycles[i]
                print "---"
            }
            if (c == 0) print "No complete cycle summaries found in " logfile
        }
    ' "$LOG_FILE"
}

FOLLOW="no"
HISTORY_N=""

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--follow) FOLLOW="yes" ;;
        -n) shift; HISTORY_N="${1:-}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if [ -n "$HISTORY_N" ]; then
    show_history "$HISTORY_N"
elif [ "$FOLLOW" = "yes" ]; then
    follow_last
else
    show_last
fi
