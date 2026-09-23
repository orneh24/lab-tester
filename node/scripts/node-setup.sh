#!/bin/sh
# node-setup.sh — interactive first-time configuration prompt for a
# mesh-probe node.
#
# Run automatically at first interactive login (see services/login-setup.sh)
# when the node hasn't been configured yet, or by hand at any time. Safe to
# re-run; does nothing once configured unless you pass --force.
#
# This wizard collects NO configuration values itself -- it only asks
# permission and delegates to setup.sh, which already does all of that
# (guestinfo -> environment -> prompt, plus the DHCP subnet/IP derivation).
# Keeping collection in one place matters: firstboot.initd calls only
# setup.sh, so any value-collecting logic added here instead would be
# invisible on the zero-touch guestinfo path.

set -eu

CONF_DIR="/etc/mesh-probe"
CONFIG="${CONF_DIR}/config"
STAMP="${CONF_DIR}/.setup-done"
SETUP="/usr/local/bin/mesh-probe/setup.sh"

case "${1:-}" in
    "") FORCE="" ;;
    --force) FORCE="1" ;;
    *)
        echo "Usage: node-setup.sh [--force]" >&2
        exit 2
        ;;
esac

mkdir -p "$CONF_DIR"

if [ -f "$STAMP" ] && [ -z "$FORCE" ]; then
    echo "Node already configured ($(cat "$STAMP"))."
    echo "Re-run with --force to reconfigure."
    exit 0
fi

# Adoption: a config exists but this wizard never ran (e.g. setup.sh was
# run by hand). Adopt it silently rather than nagging every login for a
# node that is, in fact, already configured.
if [ -f "$CONFIG" ] && [ ! -f "$STAMP" ] && [ -z "$FORCE" ]; then
    date -u '+%Y-%m-%dT%H:%M:%SZ configured (existing config)' > "$STAMP"
    echo "Found an existing config -- adopted, won't ask again."
    exit 0
fi

echo "=== mesh-probe node setup ==="
echo

CURRENT_HOSTNAME=$(hostname 2>/dev/null || echo unknown)
CURRENT_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | head -1)
echo "Hostname: $CURRENT_HOSTNAME"
echo "Address:  ${CURRENT_IP:-none}"
echo
echo "Values come from guestinfo/environment first; this only prompts for"
echo "whatever's still missing (HUB_URL, GROUP_NAME -- SUBNET derives from"
echo "the DHCP lease automatically)."
echo

# EOF must not be read as "yes" on this defaulted-yes prompt -- `if ! read`
# (not `|| ANSWER=""`) is the correct guard here for exactly that reason.
printf 'Configure this node now? [Y/n] '
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
                echo "Won't ask again. Run 'node-setup.sh --force' any time to configure."
                ;;
            *)
                echo "Skipped for now -- you'll be asked again at next login."
                ;;
        esac
        exit 0
        ;;
esac

# Reachable with an existing config only via --force (the adoption gate
# above already exited for the non-force case). Offer to discard it,
# since setup.sh's own idempotency gate is "does this file exist" -- a
# --force that only reset this wizard's stamp would re-run setup.sh but
# silently keep the old values.
if [ -f "$CONFIG" ]; then
    echo
    echo "Existing config:"
    grep -E '^(HUB_URL|GROUP_NAME|SUBNET)=' "$CONFIG" 2>/dev/null || true
    echo
    printf 'Discard this config and collect fresh values? [y/N] '
    read -r DISCARD || DISCARD=""
    case "$DISCARD" in
        [yY]*)
            BACKUP="${CONFIG}.bak-$(date -u '+%Y%m%dT%H%M%SZ')"
            mv "$CONFIG" "$BACKUP"
            echo "Backed up to $BACKUP"
            ;;
        *)
            echo "Keeping existing config -- setup.sh will refresh services/cron only."
            ;;
    esac
    echo
fi

if "$SETUP"; then
    date -u '+%Y-%m-%dT%H:%M:%SZ configured' > "$STAMP"
    echo
    echo "Node configured."
else
    echo
    echo "setup.sh failed -- not marking configured; you'll be asked again at next login."
    exit 1
fi
