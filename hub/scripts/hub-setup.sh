#!/bin/sh
# hub-setup.sh — interactive first-time configuration for the mesh-probe hub.
#
# Run automatically at first interactive login (see services/login-setup.sh)
# when the hub hasn't been configured yet, or by hand at any time. Safe to
# re-run; does nothing once configured unless you pass --force.
#
# Sets the static IP, restarts networking and starts mesh-probe-hub -- every
# step between a finished build and a working dashboard. hub.env defaults are
# sane enough not to need a prompt; edit it by hand afterward if they don't
# suit.

set -eu

CONF_DIR="/etc/mesh-probe-hub"
STAMP="${CONF_DIR}/.setup-done"

mkdir -p "$CONF_DIR"

if [ -f "$STAMP" ] && [ "${1:-}" != "--force" ]; then
    echo "Hub already configured ($(cat "$STAMP"))."
    echo "Re-run with --force to reconfigure."
    exit 0
fi

echo "=== mesh-probe hub setup ==="
echo

CURRENT_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | head -1)
echo "Current address: ${CURRENT_IP:-none}"
echo

# `if ! read` vs `read -r VAR || VAR=""`: use the former wherever a default
# would otherwise fire on EOF (a closed/non-tty stdin reads as an empty
# string, which `||` can't tell apart from a bare Enter) -- ANSWER below
# defaults to yes, so EOF must not be read as consent. `||` stays correct
# everywhere empty-and-EOF should mean the same thing, as with SKIP,
# IP_CIDR, GATEWAY and CONFIRM below, none of which default to an action.
printf 'Configure a static IP now? [Y/n] '
if ! read -r ANSWER; then
    echo
    echo "No input (stdin closed) -- nothing changed."
    exit 0
fi
case "$ANSWER" in
    [nN]*)
        printf "Skip and don't ask again at login? [y/N] "
        read -r SKIP || SKIP=""
        case "$SKIP" in
            [yY]*)
                date -u '+%Y-%m-%dT%H:%M:%SZ skipped' > "$STAMP"
                echo "Won't ask again. Run 'hub-setup.sh --force' any time to configure."
                ;;
            *)
                echo "Skipped for now -- you'll be asked again at next login."
                ;;
        esac
        exit 0
        ;;
esac

printf 'Static IP/CIDR (e.g. 10.0.0.100/24): '
read -r IP_CIDR || IP_CIDR=""
printf 'Gateway (e.g. 10.0.0.1): '
read -r GATEWAY || GATEWAY=""

if [ -z "$IP_CIDR" ] || [ -z "$GATEWAY" ]; then
    echo "Both values are required -- aborting, nothing changed."
    exit 1
fi

echo
echo "About to set: ${IP_CIDR} via ${GATEWAY}"
printf 'Apply now? [y/N] '
read -r CONFIRM || CONFIRM=""
case "$CONFIRM" in
    [yY]*) ;;
    *)
        echo "Cancelled -- nothing changed."
        exit 0
        ;;
esac

set-static-ip "$IP_CIDR" "$GATEWAY"
rc-service networking restart

date -u '+%Y-%m-%dT%H:%M:%SZ configured' > "$STAMP"

# The build only enables the hub at boot; start it now so the dashboard is up
# without a reboot. restart, not start: it also covers a hub that is already
# running. Not fatal -- the IP is set and stamped either way, and the fix is
# the same command by hand.
echo
if rc-service mesh-probe-hub restart; then
    echo "Hub running. Dashboard: http://${IP_CIDR%/*}/"
else
    echo "Static IP set, but mesh-probe-hub failed to start."
    echo "Check: rc-service mesh-probe-hub status"
fi
echo "Edit /opt/mesh-probe-hub/hub.env if the defaults don't suit, then:"
echo "  rc-service mesh-probe-hub restart"
