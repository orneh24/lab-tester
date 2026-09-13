# Lab-Tester: Alpine Linux Golden Image Build Guide

This guide walks through building Alpine Linux VMs for the lab-tester connectivity testing system. You will create a base VM, configure it for one of two roles (test VM or hub VM), then convert it to a vCenter template for rapid deployment.

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Base VM Creation](#2-base-vm-creation-in-vcenter)
3. [Alpine Installation](#3-alpine-installation)
4. [Base Package Installation](#4-base-package-installation)
5. [Test VM Configuration](#5-test-vm-configuration)
6. [Hub VM Configuration](#6-hub-vm-configuration)
7. [Golden Image Preparation](#7-golden-image-preparation)
8. [Cloning and Deployment](#8-cloning-and-deployment)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

Before starting, make sure you have:

- **vCenter / ESXi 7.0 access** with permissions to create VMs, templates, and port groups
- **Alpine Linux Virtual ISO** -- download the `alpine-virt-<version>-x86_64.iso` image from [alpinelinux.org/downloads](https://alpinelinux.org/downloads/). The "Virtual" edition is optimized for hypervisors and is under 60 MB.
- **Network information:**
  - A management/routable subnet where the hub VM will live (IP address, gateway, DNS)
  - Knowledge of which port groups map to each router's inside VLAN
  - The hub VM's IP address or hostname (test VMs push results here)
- **The lab-tester project files** on a machine you can SCP from, or uploaded to a datastore
- **Console access** to VMs via vCenter (the web console or VMRC)

---

## 2. Base VM Creation in vCenter

Create a single base VM that will later be configured for either role.

### 2.1 Create New Virtual Machine

1. In vCenter, right-click your target ESXi host or cluster and select **New Virtual Machine**.
2. Choose **Create a new virtual machine**.
3. Name it something like `alpine-lab-tester-base`.
4. Select the target datastore.

### 2.2 Recommended VM Specs

| Setting         | Value                                |
|-----------------|--------------------------------------|
| Guest OS Family | Linux                                |
| Guest OS Version| Other Linux (64-bit)                 |
| vCPU            | 1                                    |
| RAM             | 256 MB (enough for either role)      |
| Disk            | 2 GB, thin provisioned               |
| NIC             | VMXNET3, connected to a network with DHCP for initial setup |
| SCSI Controller | VMware Paravirtual                   |

> **Note:** Production test VMs need only ~128 MB RAM. The hub needs ~192 MB. Using 256 MB for the base keeps both options open. You can reduce RAM after cloning if desired.

### 2.3 Mount the ISO

1. Edit the VM settings.
2. Under **CD/DVD Drive**, select **Datastore ISO File** and browse to the uploaded Alpine Virtual ISO.
3. Check **Connect at power on**.

### 2.4 Boot the VM

1. Power on the VM.
2. Open a console (Web Console or VMRC).
3. You should see the Alpine boot prompt. Log in as `root` (no password).

---

## 3. Alpine Installation

### 3.1 Run setup-alpine

At the root prompt, start the installer:

```sh
setup-alpine
```

Walk through the prompts as follows:

| Prompt                        | Recommended Answer                        |
|-------------------------------|-------------------------------------------|
| Keyboard layout               | `us` (or your layout)                     |
| Keyboard variant              | `us` (or your variant)                    |
| Hostname                      | `lab-tester` (will change per clone)      |
| Network interface             | `eth0`                                    |
| IP address for eth0           | `dhcp`                                    |
| Manual network config         | `n`                                       |
| Root password                 | Set a strong password                     |
| Timezone                      | `UTC` (or your lab's timezone)            |
| HTTP/FTP proxy                | `none` (unless your lab requires one)     |
| NTP client                    | `chrony`                                  |
| Mirror                        | `1` or `f` to auto-detect fastest         |
| SSH server                    | `dropbear`                                |
| Disk to use                   | `sda`                                     |
| How to use disk               | `sys`                                     |
| Erase disk?                   | `y`                                       |

> **Alpine quirk:** `sys` mode installs Alpine to disk as a traditional system. The other modes (`diskless`, `data`) run from RAM and are not what we want here.

### 3.2 Reboot

Once installation completes:

```sh
reboot
```

Disconnect the ISO in vCenter (edit VM settings, disconnect the CD/DVD drive) so it boots from disk.

### 3.3 Verify Boot

Log in as `root`. Confirm networking is up:

```sh
ip addr show eth0
ping -c 2 alpinelinux.org
```

---

## 4. Base Package Installation

### 4.1 Enable the Community Repository

Alpine ships with the `main` repository enabled. Several packages we need are in `community`:

```sh
vi /etc/apk/repositories
```

Uncomment the line containing `/community` (remove the leading `#`). The file should look like:

```
https://dl-cdn.alpinelinux.org/alpine/v3.XX/main
https://dl-cdn.alpinelinux.org/alpine/v3.XX/community
```

> **Alpine quirk:** Alpine uses `vi` (actually BusyBox vi) by default. There is no `nano` unless you install it (`apk add nano`).

Then update the package index:

```sh
apk update
```

### 4.2 Package Choices That Are Load-Bearing (Both Roles)

Both `build-template.sh` scripts install their own package sets — the hub's
and the test VM's differ, and each script is the authoritative list for its
role. You do not need to install these by hand; this section exists so the
choices are legible when you read either script.

Two of them are not interchangeable with what BusyBox or dropbear give you, and
both failures are silent:

- `openssh-client` (virtual, provided by `openssh-client-default`) installs
  `/usr/bin/ssh`. `test-cycle.sh` passes `-o StrictHostKeyChecking=no -o
  UserKnownHostsFile=/dev/null`, which dropbear's `dbclient` rejects. Never add
  the `dropbear-ssh` subpackage — it installs its own `/usr/bin/ssh` symlink and
  collides at that path. Plain `dropbear` is the server only.
- `iputils-ping` **replaces** BusyBox's `/bin/ping` at the same path. The PMTU
  probe needs its `-M do`, which BusyBox ping does not implement, so this is a
  package swap rather than a `PATH` question.

A third package choice is not silent but is still worth getting right:
`samba-server` and `samba-client`, never the `samba` metapackage. The
metapackage pulls in winbind and the AD domain-controller machinery that this
lab has no use for; `samba-server` alone does not depend on either.

> CLAUDE.md constraint 14 has the full reasoning. `test-vm/build-template.sh`
> checks the ping binary — and, for SMB, that `smbclient`/`smbd` both run —
> at build time and warns.

### 4.3 Hub-Only Packages (Python, Flask, waitress)

The hub needs Python, Flask and waitress on top of the shared set.
`hub/build-template.sh` installs them and handles the awkward part for you: it
falls back to `pip3 install --break-system-packages` when a package is not in
the Alpine repository, which newer Alpine/Python versions require because they
enforce PEP 668.

> Waitress matters more than it looks. `serve.py` falls back to Flask's
> development server when it cannot import waitress — single-threaded, so the
> whole mesh's result pushes queue behind one another. If the hub feels slow
> under load, check the first lines of its log for that fallback warning.

---

## 5. Test VM Configuration

> **Superseded by `test-vm/build-template.sh`**, exactly as §6 is by the hub's
> script. Copy `test-vm/` to the VM and run it: it installs the package set
> above, populates `/usr/local/bin/lab-tester/`, installs the services and the
> logrotate config, generates the shared SSH keypair, and enables `dropbear`,
> `crond`, `lab-httpd`, `chronyd`, `open-vm-tools` and the first-boot service.
> `DEPLOYMENT.md` stage 4 is the current procedure.
>
> Following the steps below by hand is worse than redundant here: they assume a
> package set you installed yourself, and a missing `openssh-client` or
> `iputils-ping` produces a VM that registers and reports green while its SSH
> and PMTU tests can never pass (§4.2). Keep this section for reading what the
> script does.

Starting from the base VM (or a clone of it), configure it as a test VM.

### 5.1 Create Directory Structure

```sh
mkdir -p /etc/lab-tester
mkdir -p /usr/local/bin/lab-tester
mkdir -p /var/www/localhost/htdocs
```

### 5.2 Copy Project Files

From the machine hosting the project files, SCP them onto the VM. Adjust paths to match your source:

```sh
# From your workstation:
scp test-vm/scripts/register.sh    root@<VM_IP>:/usr/local/bin/lab-tester/
scp test-vm/scripts/test-cycle.sh  root@<VM_IP>:/usr/local/bin/lab-tester/
scp test-vm/scripts/setup.sh       root@<VM_IP>:/usr/local/bin/lab-tester/
scp test-vm/config.sample           root@<VM_IP>:/etc/lab-tester/config.sample
scp test-vm/services/iperf3.initd  root@<VM_IP>:/etc/init.d/iperf3
scp test-vm/services/smbd.initd    root@<VM_IP>:/etc/init.d/lab-smbd
scp test-vm/services/smb.conf      root@<VM_IP>:/etc/samba/smb.conf
scp test-vm/services/lab-tester-httpd.conf root@<VM_IP>:/etc/httpd.conf
scp test-vm/services/crontab       root@<VM_IP>:/etc/lab-tester/crontab
```

> **Do not copy the crontab onto `/etc/crontabs/root`.** That replaces root's
> crontab wholesale and destroys Alpine's `run-parts` entries, which are what
> drive `/etc/periodic/*` — including the daily logrotate run. The disk then
> fills with rotation installed but never triggered. `setup.sh` merges the
> lab-tester block into the existing crontab instead; let it. (CLAUDE.md
> constraint 12.)

### 5.3 Create the Configuration File

```sh
cp /etc/lab-tester/config.sample /etc/lab-tester/config
vi /etc/lab-tester/config
```

Set the required values:

```sh
HUB_URL="http://<hub-ip>"
ROUTER_NAME="CSR1"
SUBNET="10.1.1.0/24"
```

> **Note:** For the golden image, you can leave placeholder values here. Each clone will need its own `ROUTER_NAME` and `SUBNET`.

### 5.4 Set Permissions and Run Setup

```sh
chmod +x /usr/local/bin/lab-tester/*.sh
chmod +x /etc/init.d/iperf3
chmod +x /etc/init.d/lab-smbd
/usr/local/bin/lab-tester/setup.sh
```

### 5.5 Enable Services in OpenRC

```sh
rc-update add iperf3 default
rc-update add crond default
```

> `lab-smbd` is not enabled here. Like `iperf3` under `ENABLE_IPERF`,
> `setup.sh` only `rc-update add`s it when `ENABLE_SMB=true` in the config —
> `build-template.sh` installs the package and service file but leaves it
> off by default (CLAUDE.md test-type section).

> **Alpine quirk:** Alpine uses OpenRC, not systemd. Services are managed with `rc-service <name> start|stop|restart` and enabled at boot with `rc-update add <name> <runlevel>`. The `default` runlevel is equivalent to systemd's multi-user target.

Start the services now to verify:

```sh
rc-service iperf3 start
rc-service crond start
```

### 5.6 Set Up the Identity Web Page

BusyBox httpd serves a simple page that identifies this VM to other test nodes:

```sh
cat > /var/www/localhost/htdocs/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Lab Tester</title></head>
<body>
<h1>Lab Tester Node</h1>
<p>Router: PLACEHOLDER</p>
<p>Subnet: PLACEHOLDER</p>
</body>
</html>
EOF
```

The `setup.sh` script or a first-boot script should populate the actual values from `/etc/lab-tester/config`.

Start httpd:

```sh
rc-service lab-httpd start
rc-update add lab-httpd default
```

The service is `lab-httpd`, not `httpd` — `rc-update add httpd` enables a
service that does not exist, and the web server then fails to come back after a
reboot, silently breaking every HTTP test in the mesh.

### 5.7 Verify

```sh
# Check services are running
rc-status

# Test local HTTP
curl -s http://localhost/

# Test iperf3 is listening
iperf3 -c 127.0.0.1 -t 1

# If ENABLE_SMB=true, test smbd is listening
smbclient -N //127.0.0.1/labshare -c 'get probe.bin /dev/null'

# loss test (always on, no flag) -- confirm fping actually landed
fping -c 3 127.0.0.1

# Check cron is loaded
crontab -l
```

---

## 6. Hub VM Configuration

> **Superseded by `hub/build-template.sh`.** Copy `hub/` to the VM and run that
> script: it installs the packages, populates `/opt/lab-tester-hub/`, writes
> `hub.env` and `/etc/init.d/lab-tester-hub`, installs `set-static-ip`, sets the
> lab credentials, and enables the hub, `chronyd`, `open-vm-tools` and dropbear.
> `DEPLOYMENT.md` stage 3 is the current procedure.
>
> The steps below are kept as a reference for reading what the script does and
> for troubleshooting a half-built hub. Do not follow them as a build: they
> predate the script, they omit `hub.env`, `set-static-ip`, the credentials and
> the service enables, and 6.5's init script is wrong (see the note there).

Starting from the base VM (or a fresh clone), configure it as the hub.

### 6.1 Create Directory Structure

```sh
mkdir -p /opt/lab-tester-hub/app
mkdir -p /opt/lab-tester-hub/templates
```

### 6.2 Copy Hub Files

```sh
# From your workstation:
scp hub/app/__init__.py      root@<HUB_IP>:/opt/lab-tester-hub/app/
scp hub/app/app.py           root@<HUB_IP>:/opt/lab-tester-hub/app/
scp hub/app/config.py        root@<HUB_IP>:/opt/lab-tester-hub/app/
scp hub/app/syslog_server.py root@<HUB_IP>:/opt/lab-tester-hub/app/
scp hub/templates/dashboard.html root@<HUB_IP>:/opt/lab-tester-hub/templates/
scp hub/templates/syslog.html    root@<HUB_IP>:/opt/lab-tester-hub/templates/
scp hub/requirements.txt     root@<HUB_IP>:/opt/lab-tester-hub/
scp hub/serve.py             root@<HUB_IP>:/opt/lab-tester-hub/
scp hub/run.sh               root@<HUB_IP>:/opt/lab-tester-hub/
```

`serve.py` is the entrypoint the OpenRC service runs (6.5) — without it the
service has nothing to start. `app/__init__.py` is empty but must exist, or
`app.app` is not an importable package. `syslog_server.py` and `syslog.html` are the
syslog receiver and its viewer (6.7), and they fail very differently if you
forget one:

- **`syslog_server.py` missing → the hub does not start at all.** `serve.py`
  imports it at module level, so the service dies with `ModuleNotFoundError`
  before `main()` runs: no dashboard, no `/register`, no result collection.
  Copy it alongside `serve.py`, not as an optional extra.
- **`syslog.html` missing → only `/syslog` breaks**, with a template error.
  Everything else serves normally.

### 6.3 Install Python Dependencies

```sh
cd /opt/lab-tester-hub
pip3 install -r requirements.txt --break-system-packages
```

If `py3-flask` was already installed via apk in step 4.3, the requirements file may have nothing extra to install. Either way, running pip against the requirements file ensures everything is covered.

### 6.4 Configure Static IP (Recommended)

The hub needs a stable address so all test VMs can reach it. Edit the network configuration:

```sh
vi /etc/network/interfaces
```

Replace the DHCP config with a static block:

```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 10.0.0.10/24
    gateway 10.0.0.1
```

Set DNS:

```sh
echo "nameserver 10.0.0.1" > /etc/resolv.conf
```

Restart networking:

```sh
rc-service networking restart
```

> **Alternative:** If your lab DHCP server supports reservations, you can keep DHCP on the hub and create a reservation by MAC address. This avoids hardcoding the IP in the VM.

### 6.5 Create an OpenRC Service for the Hub

Create the init script:

> **This snippet is wrong and kept only to be recognisable.** It runs
> `run.sh`, the foreground debug launcher. What `build-template.sh` actually
> installs is `command="/usr/bin/python3"` with
> `command_args="/opt/lab-tester-hub/serve.py"`, plus a `start_pre` that sources
> `hub.env`. Going through `run.sh` skips `serve.py`'s runtime `HUB_PORT`
> handling, so a port set in `hub.env` is ignored.

```sh
cat > /etc/init.d/lab-tester-hub << 'EOF'
#!/sbin/openrc-run

name="lab-tester-hub"
description="Lab Tester Hub Dashboard"
command="/opt/lab-tester-hub/run.sh"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/lab-tester-hub.log"
error_log="/var/log/lab-tester-hub.log"

depend() {
    need net
    after firewall
}
EOF

chmod +x /etc/init.d/lab-tester-hub
chmod +x /opt/lab-tester-hub/run.sh
```

Enable and start:

```sh
rc-update add lab-tester-hub default
rc-service lab-tester-hub start
```

### 6.6 Test the Dashboard

From the hub VM itself:

```sh
curl -s http://localhost/
```

From another machine on the network, open `http://<hub-ip>` in a browser. You should see the dashboard (initially with no test results).

### 6.7 Verify the Syslog Receiver

The hub listens for Cisco syslog on UDP/514 and stores it in the same database
as the test results, so a red cell in the matrix can be read against what the
routers said at that moment.

Nothing needs enabling — `serve.py` starts the listener. Confirm it bound:

```sh
rc-service lab-tester-hub restart
grep syslog /var/log/lab-tester-hub.log     # or the service's stdout
```

Expect `[syslog] listening on 0.0.0.0:514 (cap 300000 rows)`. If instead you
see `[syslog] not listening on 0.0.0.0:514 — ...`, the usual causes are the
service not running as root (514 is privileged) or something else already bound
to it. The hub keeps serving results either way — a syslog failure is never
allowed to take the collector down with it.

Send a test message from the hub itself:

```sh
# BusyBox's logger has no network option and util-linux is not installed, so
# send the packet with the Python that is already here for the hub itself.
python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'<190>1: R-TEST: %SYS-5-CONFIG_I: hello from the hub', ('127.0.0.1', 514))"
curl -s 'http://localhost/api/syslog?minutes=5'
```

You should get one row back, with `host` `R-TEST` and `mnemonic`
`%SYS-5-CONFIG_I`. An empty array means the packet was sent but not stored —
check the listener line above rather than the router config.

Then configure each router to log to the hub:

```
logging host <hub-ip>
logging trap informational
service timestamps log datetime msec show-timezone
```

Open `http://<hub-ip>/syslog` and confirm messages appear. Filters are window,
sender, severity and a substring search; `severity=4` means *warning or worse*,
as it does on the router. Lines the parser could not read have no severity and
stay visible under every severity filter, by design.

The header shows the hub's clock state from `chronyc tracking` (green when
disciplined, amber on the `local stratum 10` fallback or >100 ms out, red when
unsynchronised). It is there because the correlation links depend on it: a
±5 min window pinned around a test result is only as good as the clock that
stamped it. `chronyd` is installed and enabled by `build-template.sh`; if the
indicator reads "clock: unknown", check `rc-service chronyd status`.

From the dashboard, clicking a matrix cell now gives a `syslog ±5 min` link per
test card, pinned to that sample, plus per-router links in the pair header.
Those filter on the router's *syslog* hostname — the name it puts in its own
messages — so if a router link is empty while the plain window link shows the
message, that router logs under a different name than its
`guestinfo.lab.router` value. Set `logging origin-id hostname` (or match the
names) if you want those links to line up.

Two things worth knowing before you rely on it:

- **It is not an audit trail.** UDP syslog is lossy and unauthenticated —
  anything that can reach the segment can inject messages. Treat it as a
  troubleshooting aid.
- **It is capped by rows, not time** (`HUB_SYSLOG_MAX_ROWS`, default 300000).
  A router left at debug level will roll the window shorter than you expect;
  that is the cap doing its job, not lost messages.

To disable it entirely, set `HUB_SYSLOG_ENABLED=false` in `hub.env`.

---

## 7. Golden Image Preparation

Before converting to a template, clean up the VM so each clone starts fresh.

### 7.1 Clean Up (Test VM Image)

Run these commands on the fully configured test VM:

```sh
# Remove SSH host keys (regenerated on first boot)
rm -f /etc/dropbear/dropbear_*

# Clear machine-id so each clone gets a unique one
echo "" > /etc/machine-id

# Reset hostname (clones should set their own)
echo "lab-tester" > /etc/hostname

# Clear config to force per-clone setup
cp /etc/lab-tester/config.sample /etc/lab-tester/config

# Clean logs
rm -f /var/log/*.log
find /var/log -type f -name "*.log.*" -delete
> /var/log/messages

# Clear shell history
> /root/.ash_history

# Clear package cache
apk cache clean 2>/dev/null
rm -rf /var/cache/apk/*
```

### 7.2 Zero Free Space (Thin Provisioning Optimization)

This step helps vCenter reclaim unused space in thin-provisioned disks:

```sh
dd if=/dev/zero of=/zero.fill bs=1M 2>/dev/null; rm -f /zero.fill
sync
```

> **Note:** This will temporarily fill the disk, then delete the fill file. It makes the VMDK compressible and thin-friendly.

### 7.3 Shutdown

```sh
poweroff
```

### 7.4 Dropbear Host Key Regeneration

Dropbear automatically regenerates missing host keys on service start, so no additional first-boot script is needed for SSH keys. After cloning, the first `rc-service dropbear start` creates new keys.

### 7.5 Convert to Template in vCenter

1. In vCenter, right-click the powered-off VM.
2. Select **Template > Convert to Template**.
3. Name it descriptively, e.g., `lab-tester-test-vm-template-v1`.

> Repeat sections 6 and 7 separately if you want a dedicated hub template. Since there is typically only one hub, you may prefer to keep it as a regular VM.

---

## 8. Cloning and Deployment

### 8.1 Clone from Template

1. In vCenter, right-click the template.
2. Select **New VM from This Template**.
3. Name the VM to match its role, e.g., `test-csr1-inside` or `test-csr3-dmz`.
4. Select the target host and datastore.
5. Choose **Thin Provision** for the virtual disk format.

### 8.2 Assign the Correct Port Group

Before booting the clone:

1. Edit the VM settings.
2. Change the NIC's **Network** to the port group corresponding to the target router's inside VLAN.

This is critical -- the test VM must be on the same L2 segment as the router's inside interface to get an IP via DHCP and to test that specific link.

### 8.3 Adjust RAM (Optional)

If you used 256 MB for the base, you can reduce test VM clones to 128 MB:

1. Edit VM settings while powered off.
2. Set Memory to **128 MB**.

### 8.4 Supply the per-VM configuration

Each clone needs four values: the hub URL, the router it sits behind, its
subnet, and its hostname. There are two ways to deliver them.

**Every clone must end up with a unique hostname.** The hub keys its endpoint
table by hostname, so two VMs sharing one name will overwrite each other and
the mesh will collapse to a single entry.

#### Option A — guestinfo (recommended)

`open-vm-tools` lets the guest read any custom key set on the VM in vCenter.
Set the keys before first boot and `setup.sh` runs without prompting.

Note that vCenter does *not* expose the VM's display name to the guest — that
is deliberate on VMware's part. You set explicit keys instead, which is more
flexible anyway since they can carry the whole configuration.

**In the vSphere Client:**

1. Right-click the clone → **Edit Settings**
2. **VM Options** tab → expand **Advanced**
3. Click **Edit Configuration…** next to Configuration Parameters
4. **Add Configuration Params**, then add one row per key:

   The keys, and the config variable each one sets, are listed in the header of
   `test-vm/config.sample` — that file ships beside the code that reads them, so
   work from it rather than from a copy here. `hub_url`, `router` and `subnet`
   are required; the rest are optional. The PowerCLI and govc examples below
   show the three required keys in context.

5. OK → OK, then power on.

`guestinfo.lab.hostname` is optional — omit it and the name is derived from
the router as `test-<router>` (so `R1` becomes `test-r1`).

**With PowerCLI**, which is worth it from the second VM onward:

```powershell
$vm = Get-VM "lab-test-r1"
$vm | New-AdvancedSetting -Name guestinfo.lab.hub_url  -Value "http://10.0.0.100" -Confirm:$false
$vm | New-AdvancedSetting -Name guestinfo.lab.router   -Value "R1"                -Confirm:$false
$vm | New-AdvancedSetting -Name guestinfo.lab.subnet   -Value "10.1.1.0/24"       -Confirm:$false
$vm | New-AdvancedSetting -Name guestinfo.lab.hostname -Value "test-r1"           -Confirm:$false
```

Deploying the whole lab in one pass:

```powershell
$hub = "http://10.0.0.100"
$lab = @(
    @{ Name="lab-test-r1"; Router="R1"; Subnet="10.1.1.0/24"; PortGroup="VLAN101-R1-inside" }
    @{ Name="lab-test-r2"; Router="R2"; Subnet="10.2.2.0/24"; PortGroup="VLAN102-R2-inside" }
    @{ Name="lab-test-r3"; Router="R3"; Subnet="10.3.3.0/24"; PortGroup="VLAN103-R3-inside" }
)

foreach ($n in $lab) {
    $vm = New-VM -Name $n.Name -Template "lab-tester-testvm" `
                 -VMHost (Get-VMHost | Select-Object -First 1) -Confirm:$false

    Get-NetworkAdapter -VM $vm |
        Set-NetworkAdapter -NetworkName $n.PortGroup -Confirm:$false

    $vm | New-AdvancedSetting -Name guestinfo.lab.hub_url  -Value $hub       -Confirm:$false
    $vm | New-AdvancedSetting -Name guestinfo.lab.router   -Value $n.Router  -Confirm:$false
    $vm | New-AdvancedSetting -Name guestinfo.lab.subnet   -Value $n.Subnet  -Confirm:$false
    $vm | New-AdvancedSetting -Name guestinfo.lab.hostname -Value ("test-" + $n.Router.ToLower()) -Confirm:$false

    Start-VM -VM $vm -Confirm:$false
}
```

To change a key later, use `Get-AdvancedSetting | Set-AdvancedSetting` rather
than `New-AdvancedSetting`, which fails on an existing name:

```powershell
Get-VM "lab-test-r1" | Get-AdvancedSetting -Name guestinfo.lab.subnet |
    Set-AdvancedSetting -Value "10.1.99.0/24" -Confirm:$false
```

**With govc:**

```sh
govc vm.change -vm lab-test-r1 \
  -e guestinfo.lab.hub_url=http://10.0.0.100 \
  -e guestinfo.lab.router=R1 \
  -e guestinfo.lab.subnet=10.1.1.0/24 \
  -e guestinfo.lab.hostname=test-r1
```

Confirm from inside the guest that the keys arrived:

```sh
vmware-rpctool "info-get guestinfo.lab.router"
```

An unset key reports `No value found` — that is the expected response, not an
error, and `setup.sh` treats it as "fall back to the next source".

#### Option B — interactive

Skip the keys entirely and let `setup.sh` prompt for the values. Fine for one
or two VMs, tedious past that.

### 8.5 Run setup and register

```sh
/usr/local/bin/lab-tester/setup.sh
```

This writes `/etc/lab-tester/config`, sets the hostname, enables the services,
installs the cron entries, builds the identity page, and performs an initial
registration against the hub. It is safe to re-run — an existing config file is
kept, and a live `guestinfo.lab.hostname` still takes effect.

Precedence for each value is: **guestinfo → environment variable → prompt**.

### 8.5a Zero-touch: let first boot do it

The template ships an OpenRC service, `lab-tester-firstboot`, that runs
`setup.sh` automatically when `guestinfo.lab.hub_url` and `guestinfo.lab.router`
are both present. With the keys set at clone time you never open a console —
power on and the VM configures, names itself, and registers.

If the keys are absent the service stands down and leaves the MOTD
instructions, because `setup.sh` would otherwise block on prompts with nobody
attached. It stamps `/etc/lab-tester/.firstboot-done` on success so it runs
once, and logs to `/var/log/lab-tester/firstboot.log`.

To re-run it deliberately:

```sh
rm /etc/lab-tester/.firstboot-done /etc/lab-tester/config
rc-service lab-tester-firstboot start
```

### 8.6 Verify on the dashboard

Open the hub dashboard at `http://<hub-ip>/` (port 80). The clone should appear
in the endpoint list within a few seconds of `setup.sh` finishing. Test results
begin populating on the next cron tick, within 60 seconds.

Checking from the clone itself:

```sh
hostname                                    # unique, e.g. test-r1
cat /etc/lab-tester/config                  # values landed correctly
rc-service lab-httpd status                 # identity page is being served
/usr/local/bin/lab-tester/test-cycle.sh     # run one cycle in the foreground
tail -f /var/log/lab-tester/test-cycle.log
```

---

## 8A. Ongoing operation

### 8A.1 Test types

| Label | Test | Runs when |
|-------|------|-----------|
| H | HTTP fetch of the target's identity page | always |
| S | SSH session using the shared mesh key | always |
| T | traceroute | every `TRACEROUTE_INTERVAL` (default 300s), or immediately when H or S to that target fails |
| M | path-MTU probe, DF bit set | always |
| D | DNS resolution | only when `DNS_SERVER` is set |
| I | iperf3 throughput | only when `ENABLE_IPERF=true` |
| B | SMB fetch of the probe file (`smbclient` against `lab-smbd`) | only when `ENABLE_SMB=true` |
| L | Packet loss % / RTT jitter (`fping`) | always |

**Why M matters.** Every other test uses small payloads, so a tunnel that
carries small packets but drops large ones reads green right across the
matrix — peering up, HTTP fine, SSH fine, large transfers hanging. The PMTU
probe sends at `PMTU_SIZE` (default 1472 payload = 1500 total) with DF set.
On failure it steps down through 1400/1300/1200/1000/500 to bracket the break
and reports, for example, `PMTU below 1500; largest passing 1428 bytes`.

If nothing answers at any size it reports `path down, not an MTU issue`, so a
dead path is not mistaken for a clamped one.

**Why T is rationed.** traceroute's default is 3 probes per hop; at a 2-second
wait an unanswered hop costs 6s, and a fully black-holed path to 15 hops costs
90s — per target, tested serially. That used to overrun the 60-second cycle
whenever paths were broken, which is precisely when you want the data. It now
runs with `-q 1 -m 10` on a slower schedule, plus on demand on failure.

### 8A.2 Static targets

Addresses that run no agent — a router loopback, a VRF interface, an outside
host — are held on the hub and merged into every VM's cycle. Configure once,
not per VM. Each target declares which tests apply, since a loopback answers
traceroute and a PMTU probe but has no HTTP server.

```sh
# add
curl -X POST http://<hub-ip>/targets -H 'Content-Type: application/json' \
  -d '{"name":"R1-Lo0","ip":"10.255.255.1","tests":["traceroute","pmtu"],"note":"R1 loopback"}'

# list
curl -s http://<hub-ip>/targets | jq

# remove
curl -X DELETE http://<hub-ip>/targets/R1-Lo0
```

Valid test names are `http`, `ssh`, `traceroute`, `pmtu`, `dns`, `iperf3`,
`smb`, `loss`; an unknown name is rejected with a 400 listing what it
accepts. Test VMs pick up changes on their next cycle, within 60 seconds.

### 8A.3 Updating the agent scripts

The hub serves the agent scripts from `/opt/lab-tester-hub/agent/`, and every
VM converges there on its 5-minute registration run. Editing the file *is* the
deploy — checksums are computed on request, so there is no rebuild step:

```sh
vi /opt/lab-tester-hub/agent/test-cycle.sh
```

Three gates run before a VM trusts an update: the download must match the
sha256 the hub publishes, it must pass `sh -n`, and for `test-cycle.sh` it
must complete a real run. The previous copy is kept as `.known-good` and
restored if that run fails, so a bad edit cannot leave the mesh dead — the
VMs simply stay on the last working version and log why.

Watch it land:

```sh
tail -f /var/log/lab-tester/register.log
```

Pin a VM with `AGENT_AUTOUPDATE=false` in `/etc/lab-tester/config`.

> **Note:** the hub API is unauthenticated. Anyone who can reach it can post
> results, add targets, or change the agent scripts every VM then executes.
> That is acceptable on an isolated lab segment and nowhere else — do not
> expose the hub to a shared or production network.

### 8A.4 SNMP polling

Opt-in (`HUB_SNMP_ENABLED=false` by default in `hub.env`). Requires the hub
to have an address on the routers' Management VLAN — `HUB_MGMT_IP` — because
every poll is source-bound to that address specifically; the routers' SNMP
ACL (`docs/csr-baseline.cfg`) only answers it. Leaving `HUB_MGMT_IP` unset
while `HUB_SNMP_ENABLED=true` is a startup failure, logged loudly, not a
silent no-op.

```sh
# Enable (edit /opt/lab-tester-hub/hub.env, then restart)
HUB_SNMP_ENABLED=true
HUB_MGMT_IP=10.0.1.100      # the hub's address on the Management VLAN
HUB_SNMP_COMMUNITY=public   # must match snmp-server community in csr-baseline.cfg
rc-service lab-tester-hub restart

# Register a router to poll
curl -X POST http://<hub-ip>/snmp/targets -H 'Content-Type: application/json' \
  -d '{"name":"R1","mgmt_ip":"10.0.1.1"}'

# Read what it collected
curl -s http://<hub-ip>/api/snmp?router=R1 | jq
```

Results render on the dashboard's "Router SNMP" panel — per-router `sysName`,
poll status, and per-interface counters with nonzero errors/discards flagged.
Not part of the pair matrix; this is router telemetry, not a VM test result.

### 8A.5 Config file server

Always on, unlike the tests above — `lab-tester-serve` (busybox httpd) serves
`/srv/lab-tester-configs/` read-only on port 8080, bound to every address.
Directory listing is automatic for any path with no `index.html`; never place
one there.

```sh
# On the hub: publish a file
publish-config /root/r1-new.cfg

# Prints the URL, MD5, and the exact router-side commands. On the router:
copy http://<hub-ip>:8080/r1-new.cfg flash:
verify /md5 flash:r1-new.cfg <md5-from-publish-config>
reload in 5
configure replace flash:r1-new.cfg
reload cancel
```

`reload in 5` and `reload cancel` are the safety net: if `configure replace`
locks you out, the router reloads back to the last-saved config on its own.
Never `copy <url> running-config` — that merges into the running config
instead of replacing it, which defeats the point of a known-good template.

---

## 9. Troubleshooting

### VM Cannot Reach the Hub

**Symptoms:** `curl http://<hub-ip>` times out or is refused.

```sh
# Check if the VM has an IP
ip addr show eth0

# Check default route
ip route

# Ping the gateway (router's inside interface)
ping -c 2 <gateway-ip>

# Ping the hub
ping -c 2 <hub-ip>

# Check if it is a port/firewall issue (hub listening?)
curl -v http://<hub-ip>/ 2>&1 | head -20
```

**Common causes:**
- VM is on the wrong port group (wrong VLAN)
- Router has no route to the hub's subnet (check router config)
- Hub's Flask app is not running (`rc-service lab-tester-hub status` on the hub)
- Hub is bound to `127.0.0.1` instead of `0.0.0.0` (check `run.sh` or `config.py`)

### DHCP Not Working

**Symptoms:** `eth0` has no IP address after boot.

```sh
# Request a lease manually
udhcpc -i eth0

# Check if the DHCP client is configured
cat /etc/network/interfaces
```

**Common causes:**
- Router's DHCP pool is not configured for the inside interface
- VM is on the wrong port group
- VMXNET3 driver issue (rare -- check `dmesg | grep -i vmxnet`)

### Tests Failing

**Symptoms:** Dashboard shows failures for specific test types.

```sh
# Run a test cycle manually and watch the output
/usr/local/bin/lab-tester/test-cycle.sh

# Test individual services on a remote VM
curl -s http://<remote-vm-ip>/
ssh root@<remote-vm-ip> echo ok
iperf3 -c <remote-vm-ip> -t 2
smbclient -N //<remote-vm-ip>/labshare -c 'get probe.bin /dev/null'
fping -c 5 <remote-vm-ip>
traceroute <remote-vm-ip>
```

**Common causes:**
- Target VM's service is not running (iperf3, httpd, dropbear, lab-smbd)
- ACLs or firewall rules on the router blocking specific ports
- SSH host key issues (dropbear regenerated keys but known_hosts has old key)
  ```sh
  # Clear known hosts if needed
  > /root/.ssh/known_hosts
  ```

### Dashboard Not Loading

**Symptoms:** Browser cannot reach `http://<hub-ip>`.

On the hub VM:

```sh
# Check if the service is running
rc-service lab-tester-hub status

# Check logs
cat /var/log/lab-tester-hub.log

# Check if Flask is listening
netstat -tlnp | grep ':80 '

# Try starting manually to see errors
cd /opt/lab-tester-hub && /bin/sh run.sh
```

**Common causes:**
- Python dependency missing (`pip3 install -r requirements.txt --break-system-packages`)
- SQLite database permissions (check that the db directory is writable)
- Port conflict (something else on port 80 — or on `HUB_PORT`, if changed in `hub.env`)
- Syntax error in `app.py` or `config.py` (check the log output)

### Services Not Starting After Clone

```sh
# List enabled services
rc-update show default

# Start all services in the default runlevel
rc default

# Check for errors
rc-status -a
```

If a service fails to start, check its log or run it manually. OpenRC logs to `/var/log/messages` by default:

```sh
grep -i error /var/log/messages | tail -20
```

### General Tips

- **Alpine's shell is `ash`, not `bash.`** Most bash syntax works, but arrays and some advanced features do not. Scripts should use `#!/bin/sh`.
- **Package management** uses `apk`, not `apt` or `yum`:
  ```sh
  apk update          # refresh package index
  apk add <pkg>       # install
  apk del <pkg>       # remove
  apk search <term>   # search
  ```
- **Service management** uses OpenRC, not systemd:
  ```sh
  rc-service <svc> start|stop|restart|status
  rc-update add|del <svc> default
  ```
- **Persistent changes** require `lbu commit` only in diskless mode. Since we installed in `sys` mode, changes are written to disk normally.
