#!/bin/sh
# install.sh — entry point for a freshly downloaded mesh-probe repo on a
# fresh Alpine base VM. Asks whether this VM becomes a Hub or a Node, then
# either runs or names the matching build-template.sh.
#
# Usage:
#   sh install.sh              interactive: asks role, confirms before running
#   sh install.sh hub|node     skips the role menu
#   sh install.sh hub -y       skips the menu and the run confirmation too
#
# Deliberately refuses to run on a VM that's already been built into a role
# (see the guard below) — both build-template.sh scripts are destructive if
# re-run on a configured system: they wipe /etc/mesh-probe/config and the
# hostname, or the hub's results database, as their last step. Their only
# existing protection against that is self-deleting after a successful run,
# and that protection disappears the moment the repo is re-downloaded.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
    printf '[install] %s\n' "$1"
}

die() {
    printf '[install] FATAL: %s\n' "$1" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Must run as root"

# -------------------------------------------------------------------
# Refuse on an already-built VM
# -------------------------------------------------------------------
if [ -f /usr/local/bin/mesh-probe/setup.sh ]; then
    die "This VM is already a configured node (/usr/local/bin/mesh-probe/setup.sh exists). Re-running build-template.sh here would wipe its config and hostname. Start from a fresh Alpine install instead."
fi
if [ -d /opt/mesh-probe-hub ]; then
    die "This VM is already a hub (/opt/mesh-probe-hub exists). Re-running build-template.sh here would wipe the results database. Start from a fresh Alpine install instead."
fi

# -------------------------------------------------------------------
# Role selection
# -------------------------------------------------------------------
ROLE="${1:-}"

if [ -z "$ROLE" ]; then
    echo "=== mesh-probe install ==="
    echo
    echo "This VM will become a:"
    echo "  1) Hub  -- infrastructure only, one per lab"
    echo "  2) Node -- one per network segment under test"
    echo
    printf 'Choice [1/2]: '
    if ! read -r ROLE; then
        echo
        echo "No input (stdin closed) -- nothing run. To build directly:"
        echo "  sh $SCRIPT_DIR/hub/build-template.sh"
        echo "  sh $SCRIPT_DIR/node/build-template.sh"
        exit 0
    fi
fi

case "$ROLE" in
    1|[hH]*) ROLE="hub" ;;
    2|[nN]*) ROLE="node" ;;
    *)
        die "Not a valid choice: '$ROLE' -- run this again and pick hub or node"
        ;;
esac

BUILD_SCRIPT="$SCRIPT_DIR/$ROLE/build-template.sh"
[ -f "$BUILD_SCRIPT" ] || die "$BUILD_SCRIPT not found -- is this a full copy of the repo?"

echo
log "Role: $ROLE"
log "Next step: sh $BUILD_SCRIPT"
echo

# -------------------------------------------------------------------
# Confirm before running -- default is No. build-template.sh installs
# packages and services system-wide and is not meant to be re-run once a
# VM is configured (see the guard above); running it should always be a
# deliberate, visible step, never a silent default.
# -------------------------------------------------------------------
AUTO_YES="${2:-}"
if [ "$AUTO_YES" = "-y" ] || [ "$AUTO_YES" = "--yes" ]; then
    RUNNOW="y"
else
    echo "This installs packages and configures this VM as a $ROLE. It is"
    echo "destructive to run again on an already-configured VM."
    printf 'Run it now? [y/N] '
    if ! read -r RUNNOW; then
        RUNNOW=""
    fi
fi

case "$RUNNOW" in
    [yY]*)
        log "Running $BUILD_SCRIPT ..."
        exec sh "$BUILD_SCRIPT"
        ;;
    *)
        log "Not run. When ready:"
        log "  sh $BUILD_SCRIPT"
        ;;
esac
