#!/bin/sh
# build-template.sh — Build the hub golden template on a fresh Alpine install.
# Run as root after booting the Alpine ISO and completing setup-alpine.
#
# This script:
#   1. Enables the community repo
#   2. Installs all required packages (Python, Flask, etc.)
#   3. Copies the hub application into place
#   4. Creates an OpenRC service for the hub
#   5. Cleans up for template conversion
#
# Usage:
#   1. SCP the entire hub/ directory to the Alpine VM
#   2. Run: sh /root/hub/build-template.sh
#   3. Shutdown and convert to template in vCenter
#
# After cloning:
#   1. Set a static IP (or a DHCP reservation)
#   2. Boot — the hub dashboard starts automatically on port 80

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_INSTALL_DIR="/opt/lab-tester-hub"
DB_DIR="/var/lib/lab-tester"
LAB_ROOT_PASSWORD="${LAB_ROOT_PASSWORD:-lab123}"

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
log() {
    printf '[build-template] %s\n' "$1"
}

die() {
    printf '[build-template] FATAL: %s\n' "$1" >&2
    exit 1
}

# -------------------------------------------------------------------
# Sanity checks
# -------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Must run as root"

log "=== lab-tester hub template builder ==="

# -------------------------------------------------------------------
# 1. Enable community repository
# -------------------------------------------------------------------
log "Enabling community repository"
ALPINE_VERSION=$(cat /etc/alpine-release | cut -d. -f1,2)
if ! grep -q "^[^#].*community" /etc/apk/repositories; then
    echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
    log "Community repo added"
else
    log "Community repo already enabled"
fi

# -------------------------------------------------------------------
# 2. Install packages
# -------------------------------------------------------------------
log "Updating package index"
apk update

log "Installing packages"
apk add --no-cache \
    python3 \
    py3-pip \
    py3-flask \
    sqlite \
    curl \
    open-vm-tools \
    chrony \
    lldpd

log "Packages installed"

# Enable open-vm-tools on boot
rc-update add open-vm-tools default

# The hub stamps every result with its own receipt time, so its clock is the
# reference for the whole mesh. Keep it disciplined.
rc-update add chronyd default

# LLDP neighbor discovery, for troubleshooting and network discovery — not a
# test participant, just always-on infrastructure like chrony.
rc-update add lldpd default

# -------------------------------------------------------------------
# 2b. Set default lab credentials
# -------------------------------------------------------------------
log "Setting root password"
echo "root:${LAB_ROOT_PASSWORD}" | chpasswd

log "Credentials: root / ${LAB_ROOT_PASSWORD}"

# -------------------------------------------------------------------
# 3. Create directories
# -------------------------------------------------------------------
log "Creating directories"
mkdir -p "$HUB_INSTALL_DIR" "$DB_DIR"

# -------------------------------------------------------------------
# 4. Copy hub application
# -------------------------------------------------------------------
log "Installing hub application to $HUB_INSTALL_DIR"

# Copy app directory
cp -r "${SCRIPT_DIR}/app" "$HUB_INSTALL_DIR/"

# Copy templates
cp -r "${SCRIPT_DIR}/templates" "$HUB_INSTALL_DIR/"

# Copy static (even if empty — the app references it)
mkdir -p "$HUB_INSTALL_DIR/static"
if [ -d "${SCRIPT_DIR}/static" ]; then
    cp -r "${SCRIPT_DIR}/static/"* "$HUB_INSTALL_DIR/static/" 2>/dev/null || true
fi

# Copy requirements, entrypoint and run script
cp -f "${SCRIPT_DIR}/requirements.txt" "$HUB_INSTALL_DIR/"
cp -f "${SCRIPT_DIR}/serve.py" "$HUB_INSTALL_DIR/"
cp -f "${SCRIPT_DIR}/run.sh" "$HUB_INSTALL_DIR/"
cp -f "${SCRIPT_DIR}/scripts/hub-setup.sh" "$HUB_INSTALL_DIR/"
chmod +x "$HUB_INSTALL_DIR/run.sh" "$HUB_INSTALL_DIR/serve.py" "$HUB_INSTALL_DIR/hub-setup.sh"
ln -sf "$HUB_INSTALL_DIR/hub-setup.sh" /usr/local/bin/hub-setup.sh

# -------------------------------------------------------------------
# Agent scripts served to nodes.
#
# This is the single place agent scripts are edited: drop a new version in
# /opt/lab-tester-hub/agent/ and every node picks it up within 5 minutes.
# Checksums are computed on demand, so no rebuild step is needed after an
# edit — just save the file.
# -------------------------------------------------------------------
log "Installing agent scripts for distribution"
mkdir -p "$HUB_INSTALL_DIR/agent"

# Prefer a sibling node/ tree (the usual layout when the whole project is
# copied across); fall back to an agent/ directory shipped alongside hub/.
if [ -d "${SCRIPT_DIR}/../node/scripts" ]; then
    cp -f "${SCRIPT_DIR}/../node/scripts/test-cycle.sh" "$HUB_INSTALL_DIR/agent/"
    cp -f "${SCRIPT_DIR}/../node/scripts/register.sh"   "$HUB_INSTALL_DIR/agent/"
    log "  agent scripts copied from ../node/scripts"
elif [ -d "${SCRIPT_DIR}/agent" ]; then
    cp -f "${SCRIPT_DIR}/agent/"*.sh "$HUB_INSTALL_DIR/agent/" 2>/dev/null || true
    log "  agent scripts copied from ./agent"
else
    log "  WARNING: no agent scripts found — self-update will be unavailable"
    log "  copy test-cycle.sh and register.sh into $HUB_INSTALL_DIR/agent/ later"
fi

# -------------------------------------------------------------------
# 5. Install Python dependencies (if not covered by apk)
# -------------------------------------------------------------------
log "Checking Python dependencies"
if ! python3 -c "import flask" 2>/dev/null; then
    log "Installing Flask via pip"
    pip3 install --break-system-packages flask
fi

# Waitress serves the dashboard instead of Flask's development server, which
# is single-threaded: with every node POSTing results on the same tick and
# the dashboard polling every 30s, requests would queue behind each other.
log "Installing waitress WSGI server"
if ! python3 -c "import waitress" 2>/dev/null; then
    apk add --no-cache py3-waitress 2>/dev/null || \
        pip3 install --break-system-packages waitress
fi

# -------------------------------------------------------------------
# 6. Create hub configuration file
# -------------------------------------------------------------------
log "Creating hub configuration"
cat > "$HUB_INSTALL_DIR/hub.env" <<'ENVEOF'
# Hub environment configuration
# Edit these values after cloning if needed.

# Path to the SQLite database
HUB_DB_PATH=/var/lib/lab-tester/hub.db

# How long to keep test results (hours).
# The hub prunes older rows on each result push; without this the results
# table grows by roughly 100k rows a day at 5 nodes.
HUB_RESULT_RETENTION_HOURS=24

# Drop endpoints that have not re-registered within this many hours.
# Nodes re-register every 5 minutes.
HUB_STALE_ENDPOINT_HOURS=6

# Port to listen on
HUB_PORT=80

# --- Syslog receiver -------------------------------------------------
# Set false to disable the UDP listener entirely.
HUB_SYSLOG_ENABLED=true

# Bind address. 0.0.0.0 accepts syslog from every reachable segment; set this
# to the management IP to accept it only there.
HUB_SYSLOG_BIND=0.0.0.0

# 514 is privileged — the service runs as root, so this only needs raising for
# a non-root manual run.
HUB_SYSLOG_PORT=514

# Row cap, not a time window: a network device at debug level outpaces any
# retention period, so rows are what must be bounded.
HUB_SYSLOG_MAX_ROWS=300000

# The syslog listener is a second writer against the same SQLite file. Without
# this, a message burst makes a concurrent result push fail with "database is
# locked" instead of waiting its turn.
HUB_BUSY_TIMEOUT_MS=5000

# --- Hub self-health (/api/health) ------------------------------------
# OpenRC services to report on, comma-separated. Queried with
# `rc-service <name> status`; a missing binary, timeout, or non-zero exit
# degrades to a per-service "unknown" rather than failing the endpoint.
HUB_HEALTH_SERVICES=lab-tester-hub,chronyd,dropbear,open-vm-tools,lldpd

# Timeout for each rc-service check, in seconds.
HUB_HEALTH_SERVICE_TIMEOUT_S=3
ENVEOF

# -------------------------------------------------------------------
# 7. Create OpenRC init script
# -------------------------------------------------------------------
log "Creating OpenRC init script"
cat > /etc/init.d/lab-tester-hub <<'INITEOF'
#!/sbin/openrc-run

name="lab-tester-hub"
description="Lab-tester hub dashboard and API"

directory="/opt/lab-tester-hub"
command="/usr/bin/python3"
command_args="/opt/lab-tester-hub/serve.py"
command_background="yes"
pidfile="/run/lab-tester-hub.pid"
output_log="/var/log/lab-tester-hub.log"
error_log="/var/log/lab-tester-hub.log"

# Load environment from hub.env.
#
# Note: command_args is expanded when this script is parsed, before start_pre
# runs. An earlier version interpolated ${HUB_PORT} there, so changing the
# port in hub.env had no effect. serve.py now reads the port itself at
# runtime, which is why it exists rather than invoking flask/waitress
# directly from this line.
start_pre() {
    if [ -f /opt/lab-tester-hub/hub.env ]; then
        while IFS= read -r line; do
            case "$line" in
                \#*|"") continue ;;
                *=*) export "$line" ;;
            esac
        done < /opt/lab-tester-hub/hub.env
    fi

    checkpath --directory --mode 0755 /var/lib/lab-tester
}

depend() {
    need net
    after firewall lab-tester-hub-firstboot
}
INITEOF

chmod +x /etc/init.d/lab-tester-hub

# First-boot autoconfiguration from guestinfo -- mirrors the node image's
# lab-tester-firstboot. Stands down when guestinfo.hub.ip/gateway are absent
# rather than blocking on a prompt nobody is there to answer; the interactive
# path is login-setup.sh below instead.
cp -f "${SCRIPT_DIR}/services/firstboot.initd" /etc/init.d/lab-tester-hub-firstboot
chmod +x /etc/init.d/lab-tester-hub-firstboot

# Invite an unconfigured hub to run hub-setup.sh at first interactive login,
# where a real tty is guaranteed (unlike an OpenRC start()).
cp -f "${SCRIPT_DIR}/services/login-setup.sh" /etc/profile.d/lab-tester-hub-setup.sh

# -------------------------------------------------------------------
# 8. Enable services
# -------------------------------------------------------------------
log "Enabling services"

# Hub service starts on boot
rc-update add lab-tester-hub default

# First-boot autoconfiguration from guestinfo
rc-update add lab-tester-hub-firstboot default

# SSH access for management
apk add --no-cache dropbear
rc-update add dropbear default

log "Services enabled"

# -------------------------------------------------------------------
# 9. Create first-boot helper
# -------------------------------------------------------------------
log "Creating first-boot instructions"
cat > /etc/motd <<'MOTDEOF'

  ┌───────────────────────────────────────────────┐
  │         lab-tester hub VM                     │
  │                                               │
  │  Dashboard: http://<this-vm-ip>/              │
  │  Config:    /opt/lab-tester-hub/hub.env       │
  │  DB:        /var/lib/lab-tester/hub.db        │
  │  Logs:      rc-service lab-tester-hub status  │
  │                                               │
  │  Not configured yet? Log in and run:          │
  │    hub-setup.sh                               │
  │  (runs automatically at first login if the    │
  │   static IP hasn't been set)                  │
  │                                               │
  │  If IP needs changing later:                  │
  │    set-static-ip <ip/cidr> <gateway>          │
  │    rc-service networking restart              │
  └───────────────────────────────────────────────┘

MOTDEOF

# -------------------------------------------------------------------
# 10. Create static IP configuration helper script
# -------------------------------------------------------------------
log "Creating static IP helper script"
cat > /usr/local/bin/set-static-ip <<'SIPEOF'
#!/bin/sh
# Helper to configure a static IP on the hub VM.
# Usage: set-static-ip <ip/cidr> <gateway>
# Example: set-static-ip 10.0.0.100/24 10.0.0.1

set -eu

if [ $# -lt 2 ]; then
    echo "Usage: set-static-ip <ip/cidr> <gateway>"
    echo "Example: set-static-ip 10.0.0.100/24 10.0.0.1"
    exit 1
fi

IP_CIDR="$1"
GATEWAY="$2"

# Detect the primary interface
IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
    address ${IP_CIDR}
    gateway ${GATEWAY}
EOF

echo "Static IP configured on ${IFACE}: ${IP_CIDR} via ${GATEWAY}"
echo "Restart networking: rc-service networking restart"
echo "DNS is not configured -- edit /etc/resolv.conf by hand if the hub needs"
echo "outbound resolution (e.g. a chrony NTP pool hostname)."
SIPEOF

chmod +x /usr/local/bin/set-static-ip

# -------------------------------------------------------------------
# 11. Clean up for template conversion
# -------------------------------------------------------------------
log "Cleaning up for template conversion"

# Remove SSH host keys (regenerated on boot)
rm -f /etc/dropbear/dropbear_*_host_key

# Clear machine-id
: > /etc/machine-id 2>/dev/null || true

# Clear resolv.conf. DHCP wrote this during the build's own internet access,
# but once the hub goes static (set-static-ip / hub-setup.sh), nothing ever
# refreshes it again -- left alone, a clone would silently keep resolving
# through whatever DNS server the build network happened to hand out.
: > /etc/resolv.conf 2>/dev/null || true

# Clear logs
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

# Clear shell history
: > /root/.ash_history 2>/dev/null || true

# Clear apk cache
apk cache clean 2>/dev/null || true
rm -rf /var/cache/apk/*

# Remove the DB if it was created during testing
rm -f "$DB_DIR/hub.db"

# Remove any setup stamp left from build-time testing, or the template would
# consider itself already configured and skip hub-setup.sh on every clone.
rm -f /etc/lab-tester-hub/.setup-done

# Remove this build script (not needed on clones)
rm -f "${SCRIPT_DIR}/build-template.sh"

# Zero free space for thin provisioning
log "Zeroing free space for thin provisioning (this may take a minute)..."
dd if=/dev/zero of=/zero.fill bs=1M 2>/dev/null || true
rm -f /zero.fill
sync

log ""
log "=== Hub build complete ==="
log ""
log "A lab normally has exactly one hub, so converting this VM to a vCenter"
log "template is optional (BUILD_GUIDE.md Sec 5.5) -- most labs can just"
log "finish configuring it in place, right here:"
log ""
log "  set-static-ip <ip/cidr> <gateway>   # or let hub-setup.sh prompt at next login"
log "  rc-service networking restart"
log "  rc-service lab-tester-hub start"
log "  Dashboard: http://<this-vm-ip>/"
log ""
log "Only convert to a template if you expect to redeploy the hub more than"
log "once (e.g. separate labs):"
log "  1. Shutdown:   poweroff"
log "  2. In vCenter: right-click VM → Template → Convert to Template"
log "  3. Clone it, then either set guestinfo keys on the clone before boot"
log "     (zero-touch):"
log "       guestinfo.hub.ip       10.0.0.100/24"
log "       guestinfo.hub.gateway  10.0.0.1"
log "     or log in (root / ${LAB_ROOT_PASSWORD}) and let hub-setup.sh"
log "     prompt for both values (manual)"
