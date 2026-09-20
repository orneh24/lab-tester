#!/bin/sh
# setup.sh — First-boot setup for a lab-tester node.
# Creates config, installs cron, enables services, and builds the identity page.
# Run as root on a fresh Alpine Linux VM.

set -eu

SCRIPT_DIR="/usr/local/bin/lab-tester"
CONFIG_DIR="/etc/lab-tester"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/lab-tester"
WEB_ROOT="/var/www/localhost/htdocs"
CRONTAB_FILE="${CONFIG_DIR}/crontab"

# -------------------------------------------------------------------
# Logging helper
# -------------------------------------------------------------------
log() {
    printf '[setup] %s\n' "$1"
}

# -------------------------------------------------------------------
# Create directories
# -------------------------------------------------------------------
log "Creating directories"
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$SCRIPT_DIR" "$WEB_ROOT"

# -------------------------------------------------------------------
# Read a value from the VMware guestinfo channel.
#
# vCenter does not expose the VM's display name to the guest, but any
# custom key set on the VM (VM Options -> Advanced -> Configuration
# Parameters, or PowerCLI's New-AdvancedSetting) is readable here. That
# makes a clone fully self-configuring: set the keys at clone time and
# setup.sh needs no interactive input at all.
#
#   PowerCLI, per clone:
#     $vm | New-AdvancedSetting -Name guestinfo.lab.hostname -Value test-node1
#     $vm | New-AdvancedSetting -Name guestinfo.lab.group    -Value site-a
#     $vm | New-AdvancedSetting -Name guestinfo.lab.subnet   -Value 10.1.1.0/24
#     $vm | New-AdvancedSetting -Name guestinfo.lab.hub_url  -Value http://10.0.0.100
# -------------------------------------------------------------------
read_guestinfo() {
    _key="guestinfo.$1"
    _val=""

    if command -v vmware-rpctool >/dev/null 2>&1; then
        _val=$(vmware-rpctool "info-get $_key" 2>/dev/null) || _val=""
    elif command -v vmtoolsd >/dev/null 2>&1; then
        _val=$(vmtoolsd --cmd "info-get $_key" 2>/dev/null) || _val=""
    fi

    # An unset key makes the tool print a diagnostic rather than a value.
    case "$_val" in
        *"No value found"*|*"Unknown command"*) _val="" ;;
    esac

    printf '%s' "$_val" | tr -d '\r\n'
}

# -------------------------------------------------------------------
# Derive the network address from the interface's current DHCP lease.
#
# The lease already carries the prefix (`ip -4 -o addr show` prints CIDR
# form, e.g. 10.1.1.23/24), so SUBNET doesn't need a human to type it --
# only the host bits need zeroing to turn a lease into a network address.
# Pure integer arithmetic (floor-divide by 2^hostbits, multiply back)
# instead of a bitwise AND, since busybox awk has no bitwise operators.
# Prints nothing (not an error) if there's no address yet, e.g. DHCP
# hasn't completed at this point in boot -- callers fall through to the
# guestinfo/env/prompt chain in that case, same as any other missing value.
# -------------------------------------------------------------------
derive_subnet() {
    _cidr=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {print $4}')
    [ -z "$_cidr" ] && return 0

    awk -v cidr="$_cidr" 'BEGIN {
        if (split(cidr, parts, "/") != 2) { exit 1 }
        prefix = parts[2] + 0
        if (prefix < 0 || prefix > 32) { exit 1 }
        if (split(parts[1], o, ".") != 4) { exit 1 }
        ipnum = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]
        divisor = 2 ^ (32 - prefix)
        netnum = int(ipnum / divisor) * divisor
        printf "%d.%d.%d.%d/%d", int(netnum/16777216)%256, int(netnum/65536)%256, \
            int(netnum/256)%256, netnum%256, prefix
    }' 2>/dev/null || true
}

# -------------------------------------------------------------------
# Create configuration file
#
# Precedence for each value: guestinfo -> environment -> prompt.
# -------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
    log "Config file already exists at $CONFIG_FILE, keeping it"
else
    _gi_hub=$(read_guestinfo "lab.hub_url")
    _gi_group=$(read_guestinfo "lab.group")
    _gi_subnet=$(read_guestinfo "lab.subnet")
    _gi_host=$(read_guestinfo "lab.hostname")

    [ -n "$_gi_hub$_gi_group$_gi_subnet$_gi_host" ] && \
        log "Found configuration in VMware guestinfo"

    _hub_url="${_gi_hub:-${HUB_URL:-}}"
    _group_name="${_gi_group:-${GROUP_NAME:-}}"
    _subnet="${_gi_subnet:-${SUBNET:-}}"
    if [ -z "$_subnet" ]; then
        _subnet=$(derive_subnet)
        [ -n "$_subnet" ] && log "Derived subnet from DHCP lease: $_subnet"
    fi
    _hostname="${_gi_host:-${LAB_HOSTNAME:-}}"
    _enable_iperf="${ENABLE_IPERF:-false}"
    # Environment-only, like ENABLE_IPERF — no guestinfo key for this.
    _enable_smb="${ENABLE_SMB:-false}"
    # Environment-only, like ENABLE_SMB — no guestinfo key for this either.
    _enable_smtp="${ENABLE_SMTP:-false}"

    # Optional tuning, also overridable from guestinfo so a whole lab can be
    # retuned at clone time without touching any VM's filesystem.
    _dns_server=$(read_guestinfo "lab.dns_server")
    _dns_server="${_dns_server:-${DNS_SERVER:-}}"
    _dns_query=$(read_guestinfo "lab.dns_query")
    _dns_query="${_dns_query:-${DNS_QUERY:-example.com}}"
    _pmtu_size="${PMTU_SIZE:-1472}"
    _traceroute_interval="${TRACEROUTE_INTERVAL:-300}"
    _autoupdate="${AGENT_AUTOUPDATE:-true}"

    # `|| _var=""` guards each read: firstboot only checks guestinfo.lab.hub_url
    # and .group before calling this script, not .subnet, so a clone missing
    # just the subnet key hits this prompt with stdin closed (firstboot.initd
    # redirects it from /dev/null so a prompt can't hang the boot). Without the
    # guard, `read`'s EOF exit status would abort the whole script under set -e
    # before cron or services ever got installed -- worse than the tolerated
    # "hub not up yet" case below.
    if [ -z "$_hub_url" ]; then
        printf 'Hub URL (e.g., http://10.0.0.100): '
        read -r _hub_url || _hub_url=""
    fi
    if [ -z "$_group_name" ]; then
        printf 'Group name (e.g., site-a): '
        read -r _group_name || _group_name=""
    fi
    if [ -z "$_subnet" ]; then
        printf 'Subnet (e.g., 10.1.1.0/24): '
        read -r _subnet || _subnet=""
    fi

    cat > "$CONFIG_FILE" <<EOF
# lab-tester node configuration
# Generated by setup.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')

HUB_URL=${_hub_url}
GROUP_NAME=${_group_name}
SUBNET=${_subnet}

# Explicit hostname. If empty, the hostname is derived as
# <HOSTNAME_PREFIX>-<group>, e.g. test-node-site-a.
LAB_HOSTNAME=${_hostname}
HOSTNAME_PREFIX=test-node

# Test cadence. Traceroute runs on the slower TRACEROUTE_INTERVAL because an
# unanswered hop costs roughly the probe timeout, making a black-holed path
# expensive; it also runs on demand whenever HTTP or SSH to a target fails.
TRACEROUTE_INTERVAL=${_traceroute_interval}
TRACEROUTE_MAX_HOPS=10

# Path-MTU probe payload. 1472 + 28 bytes of header = 1500.
PMTU_SIZE=${_pmtu_size}

ENABLE_IPERF=${_enable_iperf}

# Enable the SMB probe test (true/false). Costs smbd's resident memory on a
# 128 MB VM plus up to ~8s per peer in the cycle budget.
ENABLE_SMB=${_enable_smb}

# Enable the SMTP probe test (true/false). Costs OpenSMTPD's resident memory
# (multi-process: parent/lka/queue/scheduler/dispatcher/control/ca) on a
# 128 MB VM plus ~3s typical / up to 10s worst-case per peer in the cycle
# budget. Never issues DATA — see config.sample for the full safety note.
ENABLE_SMTP=${_enable_smtp}

# DNS resolver to query; empty disables the DNS test.
DNS_SERVER=${_dns_server}
DNS_QUERY=${_dns_query}

# Pull agent updates from the hub (checksum + syntax verified, with rollback).
AGENT_AUTOUPDATE=${_autoupdate}
EOF

    log "Config written to $CONFIG_FILE"
fi

# Reload config for use below
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# -------------------------------------------------------------------
# Set a unique hostname
#
# Every clone comes off the template with the same hostname. The hub keys
# its endpoint table by hostname, so identical names make all clones
# overwrite one another — the mesh collapses to a single endpoint and each
# node then skips it as "self", testing nothing.
#
# Prefer an explicit name (guestinfo.lab.hostname, captured into the config
# above); otherwise derive one from the group this node belongs to.
# -------------------------------------------------------------------
HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-test-node}"
LAB_HOSTNAME="${LAB_HOSTNAME:-}"

# A live guestinfo value wins even on re-runs, so re-homing a node in vCenter
# is picked up without hand-editing the config.
_gi_host_now=$(read_guestinfo "lab.hostname")
[ -n "$_gi_host_now" ] && LAB_HOSTNAME="$_gi_host_now"

if [ -n "$LAB_HOSTNAME" ]; then
    DESIRED_HOSTNAME="$LAB_HOSTNAME"
else
    _slug=$(printf '%s' "$GROUP_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')
    DESIRED_HOSTNAME="${HOSTNAME_PREFIX}-${_slug}"
fi

CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" != "$DESIRED_HOSTNAME" ]; then
    log "Setting hostname: $CURRENT_HOSTNAME -> $DESIRED_HOSTNAME"
    printf '%s\n' "$DESIRED_HOSTNAME" > /etc/hostname
    hostname "$DESIRED_HOSTNAME"

    # Keep /etc/hosts consistent so local name lookups resolve.
    if grep -q "127.0.1.1" /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${DESIRED_HOSTNAME}/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$DESIRED_HOSTNAME" >> /etc/hosts
    fi
else
    log "Hostname already set to $DESIRED_HOSTNAME"
fi

# -------------------------------------------------------------------
# Install scripts
#
# build-template.sh already placed these in $SCRIPT_DIR. When setup.sh is
# run from that same directory, source and destination are the same file
# and cp exits non-zero — which, under `set -e`, aborts the whole script.
# Only copy when running from somewhere else.
# -------------------------------------------------------------------
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$SRC_DIR" != "$SCRIPT_DIR" ]; then
    log "Installing scripts to $SCRIPT_DIR"
    cp -f "$SRC_DIR/register.sh"    "$SCRIPT_DIR/register.sh"
    cp -f "$SRC_DIR/test-cycle.sh"  "$SCRIPT_DIR/test-cycle.sh"
    cp -f "$SRC_DIR/test-status.sh" "$SCRIPT_DIR/test-status.sh"
else
    log "Scripts already in place at $SCRIPT_DIR"
fi
chmod +x "$SCRIPT_DIR/register.sh" "$SCRIPT_DIR/test-cycle.sh" "$SCRIPT_DIR/test-status.sh"
# On PATH by name, same as node-setup.sh. Re-linked unconditionally (not
# just on first install) so a node built before test-status.sh existed picks
# it up the moment this script is re-run.
ln -sf "$SCRIPT_DIR/test-status.sh" /usr/local/bin/test-status

# -------------------------------------------------------------------
# Install crontab
# -------------------------------------------------------------------
log "Installing cron entries"

# Merge rather than replace.
#
# `crontab FILE` overwrites root's crontab wholesale. Alpine ships that
# crontab with the run-parts entries that drive /etc/periodic/{15min,daily,
# weekly,monthly} — and /etc/periodic/daily/logrotate is what actually runs
# logrotate. Replacing the file silently removed those, so the log rotation
# installed by build-template.sh would never have fired and the disk would
# still fill with traceroute output.
#
# Strip any previous lab-tester block first so re-running setup.sh does not
# accumulate duplicate entries.
TMP_CRON="/tmp/lab-tester-crontab.$$"
crontab -l 2>/dev/null \
    | grep -v '^# lab-tester' \
    | grep -v 'lab-tester/register.sh' \
    | grep -v 'lab-tester/test-cycle.sh' \
    > "$TMP_CRON" || true

cat >> "$TMP_CRON" <<'EOF'
# lab-tester cron entries
*/5 * * * * /usr/local/bin/lab-tester/register.sh >> /var/log/lab-tester/register.log 2>&1
* * * * * /usr/local/bin/lab-tester/test-cycle.sh >> /var/log/lab-tester/test-cycle.log 2>&1
EOF

cp -f "$TMP_CRON" "$CRONTAB_FILE"
crontab "$TMP_CRON"
rm -f "$TMP_CRON"

_preserved=$(crontab -l 2>/dev/null | grep -c 'run-parts' || true)
log "Crontab installed (preserved ${_preserved} periodic entries)"

if [ "$_preserved" -eq 0 ]; then
    log "NOTE: no run-parts entries found; if logrotate does not run, check"
    log "      that /etc/periodic/daily/logrotate is triggered on this image"
fi

# -------------------------------------------------------------------
# Install service configs
#
# build-template.sh normally installed these already. Re-copy only if this
# script is being run from an unpacked source tree that still has them.
# -------------------------------------------------------------------
if [ -d "${SRC_DIR}/../services" ]; then
    log "Refreshing service configs from source tree"
    cp -f "${SRC_DIR}/../services/lab-tester-httpd.conf" /etc/httpd.conf 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/iperf3.initd" /etc/init.d/iperf3 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/httpd.initd"  /etc/init.d/lab-httpd 2>/dev/null || true
    mkdir -p /etc/samba 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/smb.conf"   /etc/samba/smb.conf 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/smbd.initd" /etc/init.d/lab-smbd 2>/dev/null || true
    mkdir -p /etc/smtpd 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/smtpd.conf"  /etc/smtpd/smtpd.conf 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/smtpd.initd" /etc/init.d/lab-smtpd 2>/dev/null || true
    chmod +x /etc/init.d/iperf3 /etc/init.d/lab-httpd /etc/init.d/lab-smbd /etc/init.d/lab-smtpd 2>/dev/null || true
    cp -f "${SRC_DIR}/../services/login-status.sh" /etc/profile.d/lab-tester-status.sh 2>/dev/null || true
fi

# -------------------------------------------------------------------
# Detect hostname and IP, with a manual failsafe if DHCP never came through
#
# Nodes are DHCP by design, but a node with no address can never register
# or be tested -- and nothing surfaces that anywhere except this VM's own
# log (see register.sh's own IP check). Prompt for a one-time static
# fallback rather than leaving the node silently absent from the mesh.
#
# This only helps when a human is actually watching. A firstboot run has
# stdin redirected from /dev/null (firstboot.initd), so `read` there hits
# an immediate EOF -- `|| _static_cidr=""` catches that explicitly rather
# than letting `set -e` abort the rest of setup.sh over it.
# -------------------------------------------------------------------
MY_HOSTNAME=$(hostname)
MY_IP=$(ip -4 -o addr show scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')

if [ -z "$MY_IP" ]; then
    log "WARNING: no IP address detected (DHCP may have failed)"
    printf 'No IP via DHCP. Static IP/CIDR to configure now (blank to skip): '
    read -r _static_cidr || _static_cidr=""
    if [ -n "$_static_cidr" ]; then
        printf 'Gateway: '
        read -r _static_gw || _static_gw=""
        IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
        cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
    address ${_static_cidr}
    gateway ${_static_gw}
EOF
        rc-service networking restart
        MY_IP=$(ip -4 -o addr show scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
        log "Static IP configured on ${IFACE}: ${_static_cidr} via ${_static_gw}"
    else
        log "Skipped -- this node stays unreachable until DHCP succeeds or the network is fixed by hand"
    fi
fi

log "Hostname: $MY_HOSTNAME"
log "IP: ${MY_IP:-none}"
log "Group: $GROUP_NAME"

# -------------------------------------------------------------------
# Create identity web page
# -------------------------------------------------------------------
log "Creating identity web page"
cat > "${WEB_ROOT}/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>${MY_HOSTNAME} - lab-tester</title>
  <style>
    body { font-family: monospace; margin: 2em; background: #1a1a2e; color: #e0e0e0; }
    h1 { color: #00d4ff; }
    table { border-collapse: collapse; margin-top: 1em; }
    td { padding: 0.3em 1em; }
    td:first-child { color: #888; }
  </style>
</head>
<body>
  <h1>${MY_HOSTNAME}</h1>
  <p>lab-tester endpoint</p>
  <table>
    <tr><td>Hostname</td><td>${MY_HOSTNAME}</td></tr>
    <tr><td>IP Address</td><td>${MY_IP}</td></tr>
    <tr><td>Group</td><td>${GROUP_NAME}</td></tr>
    <tr><td>Subnet</td><td>${SUBNET}</td></tr>
    <tr><td>Generated</td><td>$(date -u '+%Y-%m-%dT%H:%M:%SZ')</td></tr>
  </table>
</body>
</html>
EOF

# -------------------------------------------------------------------
# Enable and start services
# -------------------------------------------------------------------
log "Enabling and starting services"

# Start crond
rc-update add crond default 2>/dev/null || true
rc-service crond restart 2>/dev/null || rc-service crond start 2>/dev/null || true

# Start busybox httpd via its OpenRC service.
#
# Previously this tried lighttpd (never installed) and fell back to launching
# httpd by hand — which does not survive a reboot, so every HTTP test would
# fail after the first restart. lab-httpd is a real service, enabled at boot.
rc-update add lab-httpd default 2>/dev/null || true
rc-service lab-httpd restart 2>/dev/null || rc-service lab-httpd start 2>/dev/null || \
    log "WARNING: could not start lab-httpd"

# Start dropbear (SSH server)
rc-update add dropbear default 2>/dev/null || true
rc-service dropbear start 2>/dev/null || true

# Start iperf3 if enabled
if [ "$ENABLE_IPERF" = "true" ]; then
    rc-update add iperf3 default 2>/dev/null || true
    rc-service iperf3 start 2>/dev/null || true
    log "iperf3 server started"
else
    log "iperf3 disabled (ENABLE_IPERF=$ENABLE_IPERF)"
fi

# Start lab-smbd (SMB probe server) if enabled
if [ "${ENABLE_SMB:-false}" = "true" ]; then
    rc-update add lab-smbd default 2>/dev/null || true
    rc-service lab-smbd start 2>/dev/null || true
    log "lab-smbd (SMB probe server) started"
else
    log "SMB disabled (ENABLE_SMB=${ENABLE_SMB:-false})"
fi

# Start lab-smtpd (SMTP probe server) if enabled
if [ "${ENABLE_SMTP:-false}" = "true" ]; then
    rc-update add lab-smtpd default 2>/dev/null || true
    rc-service lab-smtpd start 2>/dev/null || true
    log "lab-smtpd (SMTP probe server) started"
else
    log "SMTP disabled (ENABLE_SMTP=${ENABLE_SMTP:-false})"
fi

# -------------------------------------------------------------------
# Run initial registration
# -------------------------------------------------------------------
log "Running initial registration"
"$SCRIPT_DIR/register.sh" || log "WARNING: initial registration failed (hub may not be up yet)"

log "Setup complete"
