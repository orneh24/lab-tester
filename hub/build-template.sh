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
#   1. Set a static IP (or DHCP reservation on the router)
#   2. Boot — the hub dashboard starts automatically on port 80

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_INSTALL_DIR="/opt/lab-tester-hub"
DB_DIR="/var/lib/lab-tester"
SERVE_DIR="/srv/lab-tester-configs"
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
    lldpd \
    busybox-extras

log "Packages installed"

# busybox-extras provides the httpd applet lab-tester-serve runs (the config
# file download server, section 9b below) -- same package test-vm's lab-httpd
# already depends on for the identical reason.

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
mkdir -p "$HUB_INSTALL_DIR" "$DB_DIR" "$SERVE_DIR"

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
# Agent scripts served to the test VMs.
#
# This is the single place agent scripts are edited: drop a new version in
# /opt/lab-tester-hub/agent/ and every VM picks it up within 5 minutes.
# Checksums are computed on demand, so no rebuild step is needed after an
# edit — just save the file.
# -------------------------------------------------------------------
log "Installing agent scripts for distribution"
mkdir -p "$HUB_INSTALL_DIR/agent"

# Prefer a sibling test-vm/ tree (the usual layout when the whole project is
# copied across); fall back to an agent/ directory shipped alongside hub/.
if [ -d "${SCRIPT_DIR}/../test-vm/scripts" ]; then
    cp -f "${SCRIPT_DIR}/../test-vm/scripts/test-cycle.sh" "$HUB_INSTALL_DIR/agent/"
    cp -f "${SCRIPT_DIR}/../test-vm/scripts/register.sh"   "$HUB_INSTALL_DIR/agent/"
    log "  agent scripts copied from ../test-vm/scripts"
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
# is single-threaded: with every test VM POSTing results on the same tick and
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
# table grows by roughly 100k rows a day at 5 VMs.
HUB_RESULT_RETENTION_HOURS=24

# Drop endpoints that have not re-registered within this many hours.
# Test VMs re-register every 5 minutes.
HUB_STALE_ENDPOINT_HOURS=6

# Port to listen on
HUB_PORT=80

# Debug mode. Currently read into config.DEBUG but not acted on by serve.py —
# setting it true changes nothing today.
HUB_DEBUG=false

# --- Syslog receiver -------------------------------------------------
# Set false to disable the UDP listener entirely.
HUB_SYSLOG_ENABLED=true

# Bind address. 0.0.0.0 accepts syslog from every reachable segment; set this
# to the management IP to accept it only there.
HUB_SYSLOG_BIND=0.0.0.0

# 514 is privileged — the service runs as root, so this only needs raising for
# a non-root manual run.
HUB_SYSLOG_PORT=514

# Row cap, not a time window: a router at debug level outpaces any retention
# period, so rows are what must be bounded.
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

# --- SNMP polling (interface counters, opt-in) -------------------------
# Off by default. Enabling requires the hub to have an address on the
# routers' Management VLAN -- every poll is source-bound to HUB_MGMT_IP,
# because the routers' SNMP ACL (docs/csr-baseline.cfg) only answers it.
# Leaving HUB_MGMT_IP empty while enabled is a startup failure, logged
# loudly, not a silent no-op.
HUB_SNMP_ENABLED=false
HUB_MGMT_IP=

# Must match snmp-server community in the routers' config.
HUB_SNMP_COMMUNITY=public

# Seconds between poll rounds.
HUB_SNMP_POLL_INTERVAL=60

# Per-request timeout, in seconds.
HUB_SNMP_TIMEOUT_S=3

# Age-based retention for polled interface counters.
HUB_SNMP_RETENTION_HOURS=24
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

# First-boot autoconfiguration from guestinfo -- mirrors the test-vm image's
# lab-tester-firstboot. Stands down when guestinfo.hub.ip/gateway are absent
# rather than blocking on a prompt nobody is there to answer; the interactive
# path is login-setup.sh below instead.
cp -f "${SCRIPT_DIR}/services/firstboot.initd" /etc/init.d/lab-tester-hub-firstboot
chmod +x /etc/init.d/lab-tester-hub-firstboot

# -------------------------------------------------------------------
# 9b. Config file server (lab-tester-serve)
#
# Originally designed in docs/HANDOFF.md, built here -- "config file server":
# read-only router config files, served for a router to pull with
# `copy http://`. publish-config (section 10 below) is the write side --
# an operator-run helper, never the web server itself, which never writes.
# -------------------------------------------------------------------
log "Installing config file server (lab-tester-serve)"
cp -f "${SCRIPT_DIR}/services/serve.initd" /etc/init.d/lab-tester-serve
chmod +x /etc/init.d/lab-tester-serve
cp -f "${SCRIPT_DIR}/services/serve.conf" /etc/lab-tester-serve.conf

# OpenRC sources /etc/conf.d/<service-name> automatically -- these three
# become plain shell variables inside serve.initd with no extra code needed.
cat > /etc/conf.d/lab-tester-serve <<CONFDEOF
# SERVE_BIND=0.0.0.0 listens on every address, per explicit lab requirement
# -- unlike SNMP polling, which must go OUT the management NIC specifically,
# this is routers pulling IN, and any router may not yet have its
# management-VLAN interface configured when it needs to fetch a config.
SERVE_BIND=0.0.0.0
SERVE_PORT=8080
SERVE_DIR=${SERVE_DIR}
CONFDEOF

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

# Config file download server
rc-update add lab-tester-serve default

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
  │  Configs:   http://<this-vm-ip>:8080/         │
  │    publish-config <file>                      │
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
SIPEOF

chmod +x /usr/local/bin/set-static-ip

# -------------------------------------------------------------------
# 10b. Create publish-config helper script
#
# The write side of lab-tester-serve: copies a file into the served
# directory, prints its URL and md5, and the exact router-side commands
# from docs/HANDOFF.md's original design -- copy, verify /md5, reload in 5
# as a safety net, then configure replace (never copy ... running-config,
# which merges instead of replacing).
# -------------------------------------------------------------------
log "Creating publish-config helper script"
cat > /usr/local/bin/publish-config <<'PUBEOF'
#!/bin/sh
# Publish a router config file for download via lab-tester-serve.
# Usage: publish-config <local-file> [name-on-server]

set -eu

if [ $# -lt 1 ]; then
    echo "Usage: publish-config <local-file> [name-on-server]"
    exit 1
fi

SRC="$1"
DEST_NAME="${2:-$(basename "$SRC")}"

if [ ! -f "$SRC" ]; then
    echo "publish-config: $SRC not found" >&2
    exit 1
fi

_serve_dir=$(grep -m1 '^SERVE_DIR=' /etc/conf.d/lab-tester-serve 2>/dev/null | cut -d= -f2)
_serve_dir="${_serve_dir:-/srv/lab-tester-configs}"
_port=$(grep -m1 '^SERVE_PORT=' /etc/conf.d/lab-tester-serve 2>/dev/null | cut -d= -f2)
_port="${_port:-8080}"
_ip=$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
_ip="${_ip:-<hub-ip>}"

mkdir -p "$_serve_dir"
cp -f "$SRC" "$_serve_dir/$DEST_NAME"
chmod 0444 "$_serve_dir/$DEST_NAME"

_md5=$(md5sum "$_serve_dir/$DEST_NAME" | awk '{print $1}')

echo "Published: $_serve_dir/$DEST_NAME"
echo "URL:       http://${_ip}:${_port}/${DEST_NAME}"
echo "MD5:       $_md5"
echo
echo "On the router:"
echo "  copy http://${_ip}:${_port}/${DEST_NAME} flash:"
echo "  verify /md5 flash:${DEST_NAME} $_md5"
echo "  reload in 5"
echo "  configure replace flash:${DEST_NAME}"
echo "  reload cancel"
PUBEOF

chmod +x /usr/local/bin/publish-config

# -------------------------------------------------------------------
# 11. Clean up for template conversion
# -------------------------------------------------------------------
log "Cleaning up for template conversion"

# Remove SSH host keys (regenerated on boot)
rm -f /etc/dropbear/dropbear_*_host_key

# Nothing should be published on the golden image itself -- publish-config
# is an operator action taken after cloning.
rm -f "$SERVE_DIR"/*

# Clear machine-id
: > /etc/machine-id 2>/dev/null || true

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
log "=== Template build complete ==="
log ""
log "Next steps:"
log "  1. Shutdown:   poweroff"
log "  2. In vCenter: right-click VM → Template → Convert to Template"
log ""
log "To deploy a clone (guestinfo, zero-touch):"
log "  1. Clone from template"
log "  2. Set these guestinfo keys on the clone in vCenter, then boot:"
log "     guestinfo.hub.ip       10.0.0.100/24"
log "     guestinfo.hub.gateway  10.0.0.1"
log "  3. The dashboard starts automatically on port 80"
log ""
log "To deploy a clone (manual):"
log "  1. Clone from template, boot, log in (root / ${LAB_ROOT_PASSWORD})"
log "  2. hub-setup.sh runs automatically at login and prompts for the"
log "     static IP -- or run it by hand any time"
log "  3. The dashboard starts automatically on port 80"
