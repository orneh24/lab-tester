#!/bin/sh
# dev/run-node-cycle.sh — run the REAL register.sh + test-cycle.sh, unmodified
# in logic, as a simulated node against the local dev hub. See dev/README.md.
#
# One workstation, many simulated nodes: identity comes from the `hostname`
# shim (DEV_HOSTNAME below), not from any config key — real nodes work the
# same way, register.sh/test-cycle.sh only ever call `hostname`; it's
# setup.sh that sets the OS hostname from NODE_HOSTNAME once, at setup time.
set -eu

usage() {
    cat <<EOF
Usage: dev/run-node-cycle.sh <name> <ip> [group] [--loop]

  <name>   simulated node hostname, e.g. dev-node-a
  <ip>     simulated node IP, e.g. 10.99.1.1 (fictional — nothing has to be
           listening there; every client test-cycle.sh shells out to is
           shimmed. Real HTTP tests (curl, not shimmable this way) will
           read FAIL against a fake IP — see dev/README.md)
  [group]  GROUP_NAME (default: dev)
  --loop   keep running test-cycle.sh every 60s (Ctrl-C to stop) instead of
           running one cycle and exiting

Env:
  HUB_PORT         hub port (default 8099, matches hub-start.sh's default)
  DEV_FAIL_HOSTS   comma-separated IP substrings the shims report as failing
                   (ssh/pmtu/loss), for a deliberately broken path
  ENABLE_SMB / ENABLE_SMTP / ENABLE_IPERF / DNS_SERVER / DNS_QUERY
                   forwarded into the node's config, same meaning as
                   node/config.sample
EOF
}

[ $# -lt 2 ] && { usage; exit 1; }
NAME="$1"; IP="$2"; shift 2
GROUP="dev"
LOOP="no"
while [ $# -gt 0 ]; do
    case "$1" in
        --loop) LOOP="yes" ;;
        -h|--help) usage; exit 0 ;;
        *) GROUP="$1" ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE_DIR="$ROOT/dev/run/nodes/$NAME"
mkdir -p "$NODE_DIR/run"

HUB_PORT="${HUB_PORT:-8099}"

# -------------------------------------------------------------------
# Node config — same keys node/config.sample documents.
# -------------------------------------------------------------------
cat > "$NODE_DIR/config" <<EOF
HUB_URL=http://127.0.0.1:${HUB_PORT}
GROUP_NAME=${GROUP}
SUBNET=${IP%.*}.0/24
TRACEROUTE_INTERVAL=300
TRACEROUTE_MAX_HOPS=10
PMTU_SIZE=1472
ENABLE_IPERF=${ENABLE_IPERF:-false}
ENABLE_SMB=${ENABLE_SMB:-false}
ENABLE_SMTP=${ENABLE_SMTP:-false}
DNS_SERVER=${DNS_SERVER:-}
DNS_QUERY=${DNS_QUERY:-example.com}
CONSOLE_OUTPUT=true
CONSOLE_DEVICE=${NODE_DIR}/run/console.out
AGENT_AUTOUPDATE=false
EOF

# render_summary's `[ -w "$CONSOLE_DEVICE" ]` guard is right for a real
# character device (/dev/console always exists) but a plain file has to
# exist before `-w` says yes — touch it once so the console write actually
# fires here instead of silently no-opping every cycle.
: > "$NODE_DIR/run/console.out"

# -------------------------------------------------------------------
# Scratch copies of the real agent scripts, patched only for the two
# categories of OS-root path that don't exist off a real node (same
# precedent the regression-tester agent uses): CONFIG in both scripts, and
# — test-cycle.sh only — LOCK_DIR and TRACEROUTE_STAMP. SNAPSHOT_FILE needs
# no patch; it already honors an env override (exported below), which is
# also what proves that override is real and not just documented.
# -------------------------------------------------------------------
mkdir -p "$NODE_DIR/scripts"
sed "s#^CONFIG=\"/etc/mesh-probe/config\"#CONFIG=\"$NODE_DIR/config\"#" \
    "$ROOT/node/scripts/register.sh" > "$NODE_DIR/scripts/register.sh"
sed -e "s#^CONFIG=\"/etc/mesh-probe/config\"#CONFIG=\"$NODE_DIR/config\"#" \
    -e "s#^LOCK_DIR=\"/run/mesh-probe-test-cycle.lock\"#LOCK_DIR=\"$NODE_DIR/run/lock\"#" \
    -e "s#^TRACEROUTE_STAMP=\"/run/mesh-probe-last-traceroute\"#TRACEROUTE_STAMP=\"$NODE_DIR/run/last-traceroute\"#" \
    "$ROOT/node/scripts/test-cycle.sh" > "$NODE_DIR/scripts/test-cycle.sh"
chmod +x "$NODE_DIR/scripts"/*.sh

PATH="$ROOT/dev/shims:$PATH"
export PATH
export DEV_HOSTNAME="$NAME" DEV_IP="$IP"
export SNAPSHOT_FILE="$NODE_DIR/run/last-cycle.txt"

echo "[$NAME] registering with http://127.0.0.1:${HUB_PORT} ..."
sh "$NODE_DIR/scripts/register.sh"

run_one() {
    echo "[$NAME] test cycle..."
    sh "$NODE_DIR/scripts/test-cycle.sh" >> "$NODE_DIR/run/test-cycle.log" 2>&1 || true
    echo "[$NAME] console table: $NODE_DIR/run/console.out"
    echo "[$NAME] test-status equivalent:"
    echo "  SNAPSHOT_FILE=$NODE_DIR/run/last-cycle.txt LOG_FILE=$NODE_DIR/run/test-cycle.log \\"
    echo "    sh node/scripts/test-status.sh"
}

if [ "$LOOP" = "yes" ]; then
    trap 'echo "[$NAME] stopping"; exit 0' INT TERM
    while true; do
        run_one
        sleep 60
    done
else
    run_one
fi
