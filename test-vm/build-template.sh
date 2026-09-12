#!/bin/sh
# build-template.sh — Build the test-vm golden template on a fresh Alpine install.
# Run as root after booting the Alpine ISO and completing setup-alpine.
#
# This script:
#   1. Enables the community repo
#   2. Installs all required packages
#   3. Copies project files into place
#   4. Configures services for auto-start
#   5. Cleans up for template conversion
#
# Usage:
#   1. SCP the entire test-vm/ directory to the Alpine VM
#   2. Run: sh /root/test-vm/build-template.sh
#   3. Shutdown and convert to template in vCenter

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/bin/lab-tester"
CONFIG_DIR="/etc/lab-tester"
LOG_DIR="/var/log/lab-tester"
WEB_ROOT="/var/www/localhost/htdocs"
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

log "=== lab-tester test-vm template builder ==="

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
    curl \
    jq \
    traceroute \
    bind-tools \
    iperf3 \
    dropbear \
    busybox-extras \
    openssh-client \
    open-vm-tools \
    logrotate \
    chrony \
    iputils-ping

log "Packages installed"

# Package notes, verified against the Alpine package index:
#
#   iputils-ping     — provides /bin/ping, replacing BusyBox's applet symlink
#                      at the same path. The PMTU probe needs its -M do flag,
#                      which BusyBox ping does not implement. Installed as the
#                      subpackage rather than the `iputils` metapackage, which
#                      would also drag in arping, clockdiff and tracepath.
#   openssh-client   — a virtual provided by openssh-client-default, which
#                      installs /usr/bin/ssh and already depends on
#                      openssh-keygen (so that needs no separate entry).
#                      test-cycle.sh passes -o flags that dropbear's dbclient
#                      rejects, so the OpenSSH client is required.
#   dropbear         — the SSH *server* only. Do NOT add the `dropbear-ssh`
#                      subpackage: it installs its own /usr/bin/ssh symlink to
#                      dbclient and would collide with openssh-client-default.

# Verify the ping we need actually landed; a BusyBox ping here means the PMTU
# test will fail everywhere with a confusing "invalid option" rather than a
# real result.
if ! ping -M do -c 1 -s 1 127.0.0.1 >/dev/null 2>&1; then
    log "WARNING: ping does not support -M do — PMTU tests will not work"
    log "         check that iputils-ping installed over BusyBox's /bin/ping"
fi

# Enable open-vm-tools on boot
rc-update add open-vm-tools default

# Time sync. Test VMs stamp their own results and the hub compares times
# across the mesh; unsynchronised clocks make per-test timings meaningless
# and traceroute correlation impossible to read.
rc-update add chronyd default

# -------------------------------------------------------------------
# 2b. Set default lab credentials
# -------------------------------------------------------------------
log "Setting root password"
echo "root:${LAB_ROOT_PASSWORD}" | chpasswd

# Dropbear permits root password login by default (no -w in DROPBEAR_OPTS).

log "Credentials: root / ${LAB_ROOT_PASSWORD}"

# -------------------------------------------------------------------
# 2c. Shared SSH keypair for the mesh
#
# The SSH test runs with BatchMode=yes, which accepts key auth only. With no
# key distributed between clones every SSH test would fail regardless of
# whether the path actually worked. One keypair is generated here, before
# cloning, so every clone trusts every other clone.
#
# This is a deliberately shared lab credential: any VM in the mesh can log
# into any other as root. That is appropriate for an isolated R&S lab and
# nowhere else — do not reuse this template outside it.
# -------------------------------------------------------------------
log "Generating shared lab SSH keypair"
mkdir -p /etc/lab-tester /root/.ssh
chmod 700 /root/.ssh

if [ ! -f /etc/lab-tester/id_lab ]; then
    ssh-keygen -t ed25519 -N '' -C 'lab-tester-mesh' -f /etc/lab-tester/id_lab
fi
chmod 600 /etc/lab-tester/id_lab
chmod 644 /etc/lab-tester/id_lab.pub

# Trust the shared key for root logins.
touch /root/.ssh/authorized_keys
if ! grep -qF "$(cat /etc/lab-tester/id_lab.pub)" /root/.ssh/authorized_keys 2>/dev/null; then
    cat /etc/lab-tester/id_lab.pub >> /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

log "Shared mesh keypair installed"

# -------------------------------------------------------------------
# 3. Create directories
# -------------------------------------------------------------------
log "Creating directories"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$WEB_ROOT"

# -------------------------------------------------------------------
# 4. Install scripts
# -------------------------------------------------------------------
log "Installing scripts"
cp -f "${SCRIPT_DIR}/scripts/register.sh"   "$INSTALL_DIR/register.sh"
cp -f "${SCRIPT_DIR}/scripts/test-cycle.sh" "$INSTALL_DIR/test-cycle.sh"
cp -f "${SCRIPT_DIR}/scripts/setup.sh"      "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR"/*.sh

# -------------------------------------------------------------------
# 5. Install sample config
# -------------------------------------------------------------------
log "Installing sample config"
cp -f "${SCRIPT_DIR}/config.sample" "$CONFIG_DIR/config.sample"

# -------------------------------------------------------------------
# 6. Install service configs
# -------------------------------------------------------------------
log "Installing service configs"

# httpd config
cp -f "${SCRIPT_DIR}/services/lab-tester-httpd.conf" /etc/httpd.conf

# iperf3 OpenRC init script
cp -f "${SCRIPT_DIR}/services/iperf3.initd" /etc/init.d/iperf3
chmod +x /etc/init.d/iperf3

# busybox httpd OpenRC init script — without this the web server would not
# come back after a reboot and every HTTP test in the mesh would fail.
cp -f "${SCRIPT_DIR}/services/httpd.initd" /etc/init.d/lab-httpd
chmod +x /etc/init.d/lab-httpd

# First-boot autorun — configures the clone from guestinfo with no console
# session. Stands down when the keys are absent rather than blocking on a
# prompt nobody is there to answer.
cp -f "${SCRIPT_DIR}/services/firstboot.initd" /etc/init.d/lab-tester-firstboot
chmod +x /etc/init.d/lab-tester-firstboot

# Log rotation — test-cycle.sh appends traceroute output every 60 seconds.
mkdir -p /etc/logrotate.d
cp -f "${SCRIPT_DIR}/services/logrotate.conf" /etc/logrotate.d/lab-tester

# crontab (installed but not activated until setup.sh runs)
cp -f "${SCRIPT_DIR}/services/crontab" "$CONFIG_DIR/crontab"

# -------------------------------------------------------------------
# 7. Create placeholder identity page
# -------------------------------------------------------------------
log "Creating placeholder identity page"
cat > "${WEB_ROOT}/index.html" <<'IDEOF'
<!DOCTYPE html>
<html>
<head>
  <title>lab-tester (unconfigured)</title>
  <style>
    body { font-family: monospace; margin: 2em; background: #1a1a2e; color: #e0e0e0; }
    h1 { color: #ff6b6b; }
  </style>
</head>
<body>
  <h1>lab-tester — not configured</h1>
  <p>Run <code>/usr/local/bin/lab-tester/setup.sh</code> to configure this VM.</p>
</body>
</html>
IDEOF

# -------------------------------------------------------------------
# 8. Enable base services (they start on boot)
# -------------------------------------------------------------------
log "Enabling services"

# dropbear (SSH)
rc-update add dropbear default

# crond (needed for test cycle, activated by setup.sh)
rc-update add crond default

# identity web server — enabled here so it survives reboots even if the
# operator forgets to re-run setup.sh
rc-update add lab-httpd default

# first-boot autoconfiguration from guestinfo
rc-update add lab-tester-firstboot default

log "Services enabled"

# -------------------------------------------------------------------
# 9. Create first-boot helper
# -------------------------------------------------------------------
log "Creating first-boot setup reminder"
cat > /etc/motd <<'MOTDEOF'

  ┌──────────────────────────────────────────────┐
  │           lab-tester test VM                  │
  │                                               │
  │  First-boot setup:                            │
  │    1. Edit /etc/lab-tester/config             │
  │       (copy from config.sample)               │
  │    2. Run: /usr/local/bin/lab-tester/setup.sh │
  └──────────────────────────────────────────────┘

MOTDEOF

# -------------------------------------------------------------------
# 10. Clean up for template conversion
# -------------------------------------------------------------------
log "Cleaning up for template conversion"

# Remove SSH *host* keys so each clone generates its own on first boot.
# The shared mesh keypair in /etc/lab-tester/ is deliberately kept — it has
# to survive cloning for the SSH test to work.
rm -f /etc/dropbear/dropbear_*_host_key

# Remove any config left from build-time testing so clones start clean and
# setup.sh actually runs its configuration path. The first-boot stamp must
# go too, or clones would consider themselves already configured.
rm -f /etc/lab-tester/config /etc/lab-tester/.firstboot-done
rm -f /usr/local/bin/lab-tester/*.known-good

# Reset the hostname to an obviously-unconfigured value. setup.sh replaces
# it with a unique per-clone name; leaving a real one here invites the
# collision this template is built to avoid.
printf 'lab-tester-template\n' > /etc/hostname

# Clear machine-id (regenerated on boot)
: > /etc/machine-id 2>/dev/null || true

# Clear logs
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
: > "$LOG_DIR/register.log" 2>/dev/null || true
: > "$LOG_DIR/test-cycle.log" 2>/dev/null || true

# Clear shell history
: > /root/.ash_history 2>/dev/null || true

# Clear apk cache
apk cache clean 2>/dev/null || true
rm -rf /var/cache/apk/*

# Remove this build script (not needed on clones)
rm -f "${SCRIPT_DIR}/build-template.sh"

# Zero free space for thin provisioning (takes a moment)
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
log "To deploy a clone (zero-touch, recommended):"
log "  Set these guestinfo keys on the clone in vCenter, then boot:"
log "    guestinfo.lab.hub_url   http://10.0.0.100"
log "    guestinfo.lab.router    R1"
log "    guestinfo.lab.subnet    10.1.1.0/24"
log "    guestinfo.lab.hostname  test-r1     (optional)"
log "  Then run: /usr/local/bin/lab-tester/setup.sh"
log ""
log "To deploy a clone (manual):"
log "  1. Clone from template, assign to correct port group"
log "  2. Boot and log in (root / ${LAB_ROOT_PASSWORD})"
log "  3. Run: /usr/local/bin/lab-tester/setup.sh  (it will prompt)"
