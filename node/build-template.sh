#!/bin/sh
# build-template.sh — Build the node golden template on a fresh Alpine install.
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
#   1. SCP the entire node/ directory to the Alpine VM
#   2. Run: sh /root/node/build-template.sh
#   3. Shutdown and convert to template in vCenter

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/bin/mesh-probe"
CONFIG_DIR="/etc/mesh-probe"
LOG_DIR="/var/log/mesh-probe"
WEB_ROOT="/var/www/localhost/htdocs"
MESH_PROBE_ROOT_PASSWORD="${MESH_PROBE_ROOT_PASSWORD:-lab123}"

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

log "=== mesh-probe node template builder ==="

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
    iputils-ping \
    fping \
    samba-server \
    samba-client \
    lldpd \
    opensmtpd

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
#   samba-server     — provides /usr/sbin/smbd only. Deliberately NOT the
#                      `samba` metapackage, which drags in winbind and the AD
#                      DC machinery this test has no use for on a 128 MB VM.
#   samba-client     — provides /usr/bin/smbclient, the probe tool
#                      test-cycle.sh's run_smb_test() drives. Split from
#                      samba-server so a static SMB target could in principle
#                      be probed from a VM that never runs the server side,
#                      though in this mesh every VM installs both.
#   fping            — verified against the Alpine index: a real package,
#                      main repo (not community), ~56 KiB, installs to
#                      /usr/sbin/fping. No path collision or metapackage trap
#                      like the entries above — a client-only ICMP tool with
#                      nothing else on the image at that path. run_loss_test()
#                      drives it for the always-on loss/jitter probe.
#   opensmtpd        — verified against the Alpine index: community repo,
#                      v3.20 branch shows 7.5.0_p0-r0, ~325 KiB download /
#                      ~820 KiB installed. depends="!postfix ca-certificates",
#                      so there is no ambiguity with another MTA — apk would
#                      refuse to have both installed. No metapackage trap
#                      (opensmtpd is the base package here, unlike samba).
#                      It also provides /usr/sbin/sendmail, mailq,
#                      newaliases, makemap and smtpctl (the first three are
#                      symlinks to smtpctl) — harmless today since nothing
#                      else on this image uses the sendmail-compatible
#                      interface, but a future collision risk if postfix,
#                      ssmtp or msmtp is ever added; the !postfix depend
#                      would catch that one, the others wouldn't.
#                      Deliberately NOT installing opensmtpd-openrc: its init
#                      script installs as the bare /etc/init.d/smtpd (verified
#                      against the installed package), the same generic-name
#                      collision risk this project already avoided with
#                      mesh-probe-httpd (not httpd). It would let an operator
#                      `rc-update add smtpd` by accident, bypassing
#                      ENABLE_SMTP and every guard smtpd.conf writes in. This
#                      project ships its own service/smtpd.initd instead,
#                      installed as mesh-probe-smtpd — see that file's header.
#                      run_smtp_test() drives smtpd for the SMTP ESMTP-
#                      capability-masking probe.

# Verify the ping we need actually landed; a BusyBox ping here means the PMTU
# test will fail everywhere with a confusing "invalid option" rather than a
# real result.
if ! ping -M do -c 1 -s 1 127.0.0.1 >/dev/null 2>&1; then
    log "WARNING: ping does not support -M do — PMTU tests will not work"
    log "         check that iputils-ping installed over BusyBox's /bin/ping"
fi

# Verify the SMB tools actually landed. Same warn-don't-fail discipline as
# the ping check above: a missing binary here means every smb test fails
# with a confusing "not found" rather than a real result, but it should not
# abort an otherwise-good template build.
if ! command -v smbclient >/dev/null 2>&1 || ! smbclient --version >/dev/null 2>&1; then
    log "WARNING: smbclient missing or not runnable — smb tests will not work"
fi
if [ ! -x /usr/sbin/smbd ] || ! /usr/sbin/smbd -b >/dev/null 2>&1; then
    log "WARNING: smbd missing or not runnable — smb server will not start"
fi

# fping has no BusyBox-replacement gotcha to check for (unlike ping) — a
# simple presence check is enough to catch a broken install.
if ! command -v fping >/dev/null 2>&1; then
    log "WARNING: fping missing — loss/jitter tests will not work"
fi

# Enable open-vm-tools on boot
rc-update add open-vm-tools default

# Time sync. Nodes stamp their own results and the hub compares times
# across the mesh; unsynchronised clocks make per-test timings meaningless
# and traceroute correlation impossible to read.
rc-update add chronyd default

# LLDP neighbor discovery, for troubleshooting and network discovery — not a
# test type, just always-on infrastructure like chrony. Lets an engineer read
# `lldpcli show neighbors` on a node to confirm which switch/port it's
# actually plugged into without console access to that device.
rc-update add lldpd default

# -------------------------------------------------------------------
# 2b. Set default lab credentials
# -------------------------------------------------------------------
log "Setting root password"
echo "root:${MESH_PROBE_ROOT_PASSWORD}" | chpasswd

# Dropbear permits root password login by default (no -w in DROPBEAR_OPTS).

log "Credentials: root / ${MESH_PROBE_ROOT_PASSWORD}"

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
mkdir -p /etc/mesh-probe /root/.ssh
chmod 700 /root/.ssh

if [ ! -f /etc/mesh-probe/id_mesh_probe ]; then
    ssh-keygen -t ed25519 -N '' -C 'mesh-probe' -f /etc/mesh-probe/id_mesh_probe
fi
chmod 600 /etc/mesh-probe/id_mesh_probe
chmod 644 /etc/mesh-probe/id_mesh_probe.pub

# Trust the shared key for root logins.
touch /root/.ssh/authorized_keys
if ! grep -qF "$(cat /etc/mesh-probe/id_mesh_probe.pub)" /root/.ssh/authorized_keys 2>/dev/null; then
    cat /etc/mesh-probe/id_mesh_probe.pub >> /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

log "Shared mesh keypair installed"

# -------------------------------------------------------------------
# 3. Create directories
# -------------------------------------------------------------------
log "Creating directories"
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$WEB_ROOT"

# -------------------------------------------------------------------
# 3b. SMB probe share
#
# One small, fixed file that every peer fetches over SMB — the protocol
# most likely to be broken by an inspection policy, an MSS/MTU problem
# mid-transfer, or a NAT path that only tolerates short-lived flows. The
# share and this file must survive cloning (cleanup below only removes the
# Samba state databases, not this directory).
# -------------------------------------------------------------------
log "Creating SMB probe share"
mkdir -p /srv/mesh-probe-smb
dd if=/dev/zero of=/srv/mesh-probe-smb/probe.bin bs=1M count=8 2>/dev/null
chmod 0444 /srv/mesh-probe-smb/probe.bin
chmod 0555 /srv/mesh-probe-smb

# No equivalent probe-payload step for SMTP: unlike SMB's fixed 8 MB
# probe.bin, run_smtp_test() carries no payload at all (it never issues
# DATA), so there is nothing here for it to create. Absence is deliberate,
# not a missed step.

# -------------------------------------------------------------------
# 4. Install scripts
# -------------------------------------------------------------------
log "Installing scripts"
cp -f "${SCRIPT_DIR}/scripts/register.sh"    "$INSTALL_DIR/register.sh"
cp -f "${SCRIPT_DIR}/scripts/test-cycle.sh"  "$INSTALL_DIR/test-cycle.sh"
cp -f "${SCRIPT_DIR}/scripts/setup.sh"       "$INSTALL_DIR/setup.sh"
cp -f "${SCRIPT_DIR}/scripts/node-setup.sh"  "$INSTALL_DIR/node-setup.sh"
cp -f "${SCRIPT_DIR}/scripts/test-status.sh" "$INSTALL_DIR/test-status.sh"
chmod +x "$INSTALL_DIR"/*.sh

# On PATH by name, same as the hub's hub-setup.sh / set-static-ip.
ln -sf "$INSTALL_DIR/node-setup.sh" /usr/local/bin/node-setup.sh
ln -sf "$INSTALL_DIR/test-status.sh" /usr/local/bin/test-status

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
cp -f "${SCRIPT_DIR}/services/mesh-probe-httpd.conf" /etc/httpd.conf

# iperf3 OpenRC init script
cp -f "${SCRIPT_DIR}/services/iperf3.initd" /etc/init.d/iperf3
chmod +x /etc/init.d/iperf3

# busybox httpd OpenRC init script — without this the web server would not
# come back after a reboot and every HTTP test in the mesh would fail.
cp -f "${SCRIPT_DIR}/services/httpd.initd" /etc/init.d/mesh-probe-httpd
chmod +x /etc/init.d/mesh-probe-httpd

# First-boot autorun — configures the clone from guestinfo with no console
# session. Stands down when the keys are absent rather than blocking on a
# prompt nobody is there to answer.
cp -f "${SCRIPT_DIR}/services/firstboot.initd" /etc/init.d/mesh-probe-firstboot
chmod +x /etc/init.d/mesh-probe-firstboot

# Invite an unconfigured node to run node-setup.sh at first interactive
# login, where a real tty is guaranteed (unlike an OpenRC start()).
cp -f "${SCRIPT_DIR}/services/login-setup.sh" /etc/profile.d/mesh-probe-node-setup.sh

# Show the last test cycle plus a test-status usage hint at every
# interactive login of a configured node — same tty guard as
# login-setup.sh above, see its own header comment.
cp -f "${SCRIPT_DIR}/services/login-status.sh" /etc/profile.d/mesh-probe-status.sh

# Samba (SMB probe server). Config is installed unconditionally like the
# other service files, but — unlike dropbear/mesh-probe-httpd below — mesh-probe-smbd is
# deliberately NOT rc-update'd here. It only starts when a clone's config
# sets ENABLE_SMB=true, which setup.sh enforces at boot time, matching how
# iperf3 is handled.
mkdir -p /etc/samba
cp -f "${SCRIPT_DIR}/services/smb.conf" /etc/samba/smb.conf
cp -f "${SCRIPT_DIR}/services/smbd.initd" /etc/init.d/mesh-probe-smbd
chmod +x /etc/init.d/mesh-probe-smbd

# OpenSMTPD (SMTP probe server). This cp deliberately REPLACES the packaged
# default /etc/smtpd/smtpd.conf, which (verified against the installed
# opensmtpd package) ships a working `action "relay" relay` — an open relay
# for anything originated on the box. See smtpd.conf's own header for why
# that matters given this lab's NAT + default route to the internet. Like
# mesh-probe-smbd, mesh-probe-smtpd is installed but deliberately NOT rc-update'd here —
# it only starts when a clone's config sets ENABLE_SMTP=true, enforced by
# setup.sh at boot time.
mkdir -p /etc/smtpd
cp -f "${SCRIPT_DIR}/services/smtpd.conf" /etc/smtpd/smtpd.conf
cp -f "${SCRIPT_DIR}/services/smtpd.initd" /etc/init.d/mesh-probe-smtpd
chmod +x /etc/init.d/mesh-probe-smtpd

# Log rotation — test-cycle.sh appends traceroute output every 60 seconds.
mkdir -p /etc/logrotate.d
cp -f "${SCRIPT_DIR}/services/logrotate.conf" /etc/logrotate.d/mesh-probe

# crontab (installed but not activated until setup.sh runs)
cp -f "${SCRIPT_DIR}/services/crontab" "$CONFIG_DIR/crontab"

# -------------------------------------------------------------------
# 6b. Validate OUR smtpd.conf, not the packaged default.
#
# This has to run after the cp -f above, not alongside the ping/smb/fping
# presence checks earlier — those check that a package landed correctly;
# this checks that OUR config file (the one that removes the relay action)
# is actually what's on disk and that smtpd accepts it. Same warn-don't-fail
# discipline as the rest of this script: a directive that doesn't parse on
# whatever OpenSMTPD version this build pulled in should degrade to a loud
# warning, never a broken image build.
# -------------------------------------------------------------------
log "Validating installed smtpd.conf"

if ! /usr/sbin/smtpd -n -f /etc/smtpd/smtpd.conf >/dev/null 2>&1; then
    log "WARNING: /etc/smtpd/smtpd.conf failed to parse (smtpd -n) — SMTP"
    log "         tests will not work until this is fixed. Check the"
    log "         resource-cap and match/action directive names against"
    log "         'man smtpd.conf' for the OpenSMTPD version installed."
fi

if ! command -v nc >/dev/null 2>&1; then
    log "WARNING: nc missing — run_smtp_test() has no client, SMTP tests"
    log "         will not work (nc should come from busybox-extras)"
fi

# Safety net for a failed cp above: if this ever matches, the installed
# config has a relay action and this build must not ship. The one action
# this file is allowed to have is the "sink" mda action, which is not a
# relay — this specifically looks for a relay delivery method.
if grep -qE '^[[:space:]]*action[[:space:]]+.*[[:space:]]relay' /etc/smtpd/smtpd.conf; then
    log "WARNING: /etc/smtpd/smtpd.conf contains a 'relay' action —"
    log "         this build would ship with a working outbound relay."
    log "         Check that the cp -f of services/smtpd.conf actually ran."
fi

# -------------------------------------------------------------------
# 7. Create placeholder identity page
# -------------------------------------------------------------------
log "Creating placeholder identity page"
cat > "${WEB_ROOT}/index.html" <<'IDEOF'
<!DOCTYPE html>
<html>
<head>
  <title>mesh-probe (unconfigured)</title>
  <style>
    body { font-family: monospace; margin: 2em; background: #1a1a2e; color: #e0e0e0; }
    h1 { color: #ff6b6b; }
  </style>
</head>
<body>
  <h1>mesh-probe — not configured</h1>
  <p>Log in and run <code>node-setup.sh</code> (or <code>setup.sh</code> directly) to configure this VM.</p>
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
rc-update add mesh-probe-httpd default

# first-boot autoconfiguration from guestinfo
rc-update add mesh-probe-firstboot default

log "Services enabled"

# -------------------------------------------------------------------
# 9. Create first-boot helper
# -------------------------------------------------------------------
log "Creating first-boot setup reminder"
cat > /etc/motd <<'MOTDEOF'

  ┌────────────────────────────────────────────────┐
  │          mesh-probe node                       │
  │                                                │
  │   Not configured yet? Log in and run:          │
  │     node-setup.sh                              │
  │   (runs automatically at first login if this   │
  │    node hasn't been configured)                │
  │                                                │
  │   Manual path:                                 │
  │     1. Edit /etc/mesh-probe/config             │
  │        (copy from config.sample)               │
  │     2. Run: /usr/local/bin/mesh-probe/setup.sh │
  └────────────────────────────────────────────────┘

MOTDEOF

# -------------------------------------------------------------------
# 10. Clean up for template conversion
# -------------------------------------------------------------------
log "Cleaning up for template conversion"

# Remove SSH *host* keys so each clone generates its own on first boot.
# The shared mesh keypair in /etc/mesh-probe/ is deliberately kept — it has
# to survive cloning for the SSH test to work.
rm -f /etc/dropbear/dropbear_*_host_key

# Remove Samba's state databases (secrets.tdb and friends carry a machine
# SID / server GUID) so each clone generates its own on first start instead
# of every VM in the mesh answering with the same identity. The share
# directory and probe.bin must survive cloning, so only /var/lib/samba/ is
# touched here.
rm -rf /var/lib/samba/*

# Clear OpenSMTPD's queue contents only — never touch the directory tree's
# ownership or mode. smtpd refuses to start on wrong queue permissions, and
# that failure would only ever surface on a clone, which is miserable to
# diagnose with no console session watching first boot.
find /var/spool/smtpd/queue -mindepth 1 -delete 2>/dev/null || true

# Remove any config left from build-time testing so clones start clean and
# setup.sh actually runs its configuration path. Both stamps must go too,
# or clones would consider themselves already configured -- a golden image
# sealed with .setup-done present (e.g. from a build-verification pass that
# answered "skip, don't ask again") would silence node-setup.sh's login
# prompt on every clone made from it, and the only symptom is a node that
# never registers. config.bak-* are node-setup.sh --force's own backups of
# a real (not template) config and must not survive into the image either.
rm -f /etc/mesh-probe/config /etc/mesh-probe/config.bak-* \
      /etc/mesh-probe/.firstboot-done /etc/mesh-probe/.setup-done
rm -f /usr/local/bin/mesh-probe/*.known-good

# Reset the hostname to an obviously-unconfigured value. setup.sh replaces
# it with a unique per-clone name; leaving a real one here invites the
# collision this template is built to avoid.
printf 'mesh-probe-template\n' > /etc/hostname

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
log "    guestinfo.meshprobe.hub_url   http://10.0.0.100"
log "    guestinfo.meshprobe.group     site-a"
log "    guestinfo.meshprobe.subnet    10.1.1.0/24 (optional -- derives from DHCP)"
log "    guestinfo.meshprobe.hostname  test-node-site-a (optional)"
log "  Then boot -- mesh-probe-firstboot configures and registers the clone"
log "  automatically. Nothing to run by hand."
log ""
log "To deploy a clone (manual):"
log "  1. Clone from template, assign to correct network"
log "  2. Boot and log in (root / ${MESH_PROBE_ROOT_PASSWORD})"
log "  3. node-setup.sh runs automatically at first login and prompts;"
log "     or run it (or /usr/local/bin/mesh-probe/setup.sh) by hand any time"
