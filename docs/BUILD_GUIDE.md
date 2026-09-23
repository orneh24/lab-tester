# Mesh Probe — Build Guide

Detail behind each step of the [README quick start](../README.md#quick-start)
and the `DEPLOYMENT.md` checklist. You build one Alpine base VM, clone it,
turn one clone into the hub and one into the node template, then clone the
template once per network segment.

`install.sh` and the two `build-template.sh` scripts do all the package,
service and file setup. This guide covers what they can't: the VM itself,
the Alpine install, and configuring the clones.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Create the base VM](#2-create-the-base-vm)
3. [Install Alpine](#3-install-alpine)
4. [Build the hub and the node template](#4-build-the-hub-and-the-node-template)
5. [Deploy nodes](#5-deploy-nodes)
6. [Ongoing operation](#6-ongoing-operation)
7. [Troubleshooting](#7-troubleshooting)
8. [No GitHub access](#8-no-github-access)

---

## 1. Prerequisites

- vCenter / ESXi access to create VMs, templates and port groups
- The Alpine **Virtual** ISO (`alpine-virt-<version>-x86_64.iso`) from
  [alpinelinux.org/downloads](https://alpinelinux.org/downloads/)
- A hub subnet that every node subnet can reach, and the hub's static IP
- A port group per node subnet
- Internet access from each VM while it is built (Alpine mirror, GitHub)
- Console access to the VMs (vCenter web console or VMRC)

---

## 2. Create the base VM

| Setting | Value |
|---|---|
| Guest OS | Linux, Other 5.x or later Linux (64-bit) |
| vCPU | 1 |
| RAM | 256 MB |
| Disk | 2 GB, thin provisioned |
| NIC | VMXNET3, on a network with DHCP |
| SCSI controller | VMware Paravirtual |

If your vCenter has no "Other 5.x or later" option, pick "Other Linux
(64-bit)". vCenter then warns that Paravirtual is "not recommended". Ignore
it: Alpine's kernel has the driver. LSI Logic Parallel also works.

256 MB fits either role. After cloning you can drop nodes to 128 MB and the
hub to 192 MB.

---

## 3. Install Alpine

Boot the ISO, log in as `root` (no password) and run `setup-alpine`:

| Prompt | Answer |
|---|---|
| Keyboard layout | your layout |
| Hostname | `mesh-probe` (each clone renames itself) |
| Network interface | `eth0`, `dhcp` |
| Root password | anything; the build sets it to `lab123` (see below) |
| Timezone | `UTC` or your lab's timezone |
| Proxy | `none`, unless your lab needs one |
| NTP client | `chrony` |
| Mirror | `f` (fastest) |
| SSH server | `dropbear` |
| Disk | `sda`, mode `sys`, erase `y` |

`sys` installs to disk. The other modes run from RAM.

Reboot, disconnect the ISO in vCenter, log in and check the network:

```sh
ip addr show eth0
ping -c 2 alpinelinux.org
```

The build scripts set the root password to `lab123`. To use your own, run
the build with `MESH_PROBE_ROOT_PASSWORD=<password>` set.

Now clone the VM twice (hub and node template).

---

## 4. Build the hub and the node template

On each clone, run as root:

```sh
wget -O- https://github.com/orneh24/mesh-probe/archive/refs/heads/main.tar.gz | tar -xz -C /root && mv /root/mesh-probe-main /root/mesh-probe && sh /root/mesh-probe/install.sh
```

Pick **hub** on one clone and **node** on the other. The build enables the
community repository, installs packages, installs the services and cleans
the VM for cloning. It takes a few minutes; zeroing free space at the end is
the slow part.

Some package choices matter (for example, `iputils-ping` instead of
BusyBox ping, which the PMTU test needs). `CLAUDE.md` constraint 14 explains
them. `node/build-template.sh` checks the important ones and warns if they
are wrong.

### 4.1 Hub

Log out and back in. `hub-setup.sh` asks for the static IP and gateway, then
restarts networking and starts the hub. To do it by hand instead:

```sh
set-static-ip <hub-ip>/<cidr> <gateway> [dns] [hostname]
rc-service networking restart
rc-service mesh-probe-hub start
```

Or set `guestinfo.hub.ip` (e.g. `10.0.0.100/24`) and `guestinfo.hub.gateway`
on the VM and reboot; the `mesh-probe-hub-firstboot` service applies them.

Open `http://<hub-ip>/` to check. Settings live in
`/opt/mesh-probe-hub/hub.env`; restart the hub after editing it.

A lab normally has one hub, so you don't need to make it a template.

### 4.2 Node template

The build leaves the node clean: no config, hostname `mesh-probe-template`,
no SSH host keys, no login stamp. Shut it down and convert it to a template:

```sh
rm -rf /root/mesh-probe   # optional
poweroff
```

Name the template something like `mesh-probe-node-template-v1`.

**Don't run `setup.sh` or answer the login prompt on the template.** That
writes a config, hostname, SSH host keys and login stamp, and every clone
would inherit them. Test on the first clone instead.

---

## 5. Deploy nodes

### 5.1 Clone and connect

1. Clone the template.
2. Before booting, set the NIC to the port group of the segment this node
   tests. The node needs DHCP on that segment.
3. Optional: lower RAM to 128 MB.

### 5.2 Configure: guestinfo (recommended)

Set the keys on the VM before first boot. On boot, the
`mesh-probe-firstboot` service runs `setup.sh` with them, and the node
configures and registers itself with no console session.

The keys are listed in the [README](../README.md#vmware-guestinfo-keys).
Only `hub_url` and `group` are required. In the vSphere Client: VM →
**Edit Settings** → **VM Options** → **Advanced** → **Edit Configuration** →
add one row per key.

With PowerCLI:

```powershell
$vm = Get-VM "mp-site-a"
$vm | New-AdvancedSetting -Name guestinfo.meshprobe.hub_url -Value "http://10.0.0.100" -Confirm:$false
$vm | New-AdvancedSetting -Name guestinfo.meshprobe.group   -Value "site-a"            -Confirm:$false
```

To change a key later, use `Get-AdvancedSetting | Set-AdvancedSetting`;
`New-AdvancedSetting` fails if the key exists. To deploy a whole lab at once,
use `deploy/Deploy-MeshProbe.ps1` (see `deploy/README.md`).

With govc:

```sh
govc vm.change -vm mp-site-a \
  -e guestinfo.meshprobe.hub_url=http://10.0.0.100 \
  -e guestinfo.meshprobe.group=site-a
```

To check from inside the guest: `vmware-rpctool "info-get guestinfo.meshprobe.group"`.
`No value found` just means the key isn't set.

The first-boot service logs to `/var/log/mesh-probe/firstboot.log`. With no
keys set it does nothing, and the login prompt takes over. To run it again:

```sh
rm /etc/mesh-probe/.firstboot-done /etc/mesh-probe/config
rc-service mesh-probe-firstboot start
```

### 5.3 Configure: at login

Boot the clone and log in. `node-setup.sh` asks
`Configure this node now? [Y/n]` and runs `setup.sh`, which asks for anything
not already set. You can also run `/usr/local/bin/mesh-probe/setup.sh`
yourself at any time.

The prompt appears only in an interactive login on a real terminal, never
for `ssh host cmd` or scp. If you decline, you can choose not to be asked
again; `node-setup.sh --force` asks again later.

Each value comes from guestinfo first, then an environment variable, then a
prompt. `SUBNET` is taken from the DHCP lease before prompting. The hostname
is `mp-<group>-<ip>` unless you set one.

### 5.4 What `setup.sh` does

It writes `/etc/mesh-probe/config`, sets the hostname, starts the services,
adds the cron jobs (every 60 s for tests, every 5 min for registration) and
registers with the hub. It is safe to re-run: it keeps an existing config.

### 5.5 Check

The node appears on the dashboard within seconds, and results within a
minute. On the node:

```sh
hostname                                   # e.g. mp-site-a-10-1-1-10
test-status                                # last cycle's results (-f to follow)
tail -f /var/log/mesh-probe/test-cycle.log
```

---

## 6. Ongoing operation

### 6.1 Test types

| Label | Test | Runs |
|---|---|---|
| H | HTTP fetch of the target's identity page | always |
| S | SSH login with the shared mesh key | always |
| T | traceroute | every `TRACEROUTE_INTERVAL` (300 s), and right after H or S fails |
| M | path MTU, DF bit set | always |
| D | DNS lookup of `DNS_QUERY` | when `DNS_SERVER` is set |
| I | iperf3 throughput | when `ENABLE_IPERF=true` |
| B | SMB download of a probe file | when `ENABLE_SMB=true` |
| L | packet loss and jitter (`fping`) | always |
| E | SMTP conversation, never sends mail | mesh: when `ENABLE_SMTP=true`; static targets: always |

**M (path MTU)** sends a full-size packet (1472-byte payload, 1500 total)
with DF set. Every other test uses small packets, so a tunnel that drops
large packets looks green everywhere else. On failure it steps down through
smaller sizes and reports, for example,
`PMTU below 1500; largest passing 1428 bytes`. If nothing gets through at
any size, it reports `path down, not an MTU issue`.

**E (SMTP)** catches a firewall that *rewrites* traffic instead of blocking
it. SMTP inspection engines replace capability words they don't know with
`X`s, so `250-XXXXXXXX` in the output means something is editing the
session. The test passes on the greeting and `EHLO` reply only; a real relay
rejecting the probe address with `550` is normal. See `CLAUDE.md`
constraint 21 for why this can never send mail.

**T (traceroute)** runs rarely because a dead path is slow to trace. It
uses one probe per hop and at most 10 hops, so it can't overrun the
60-second cycle when the network breaks.

### 6.2 Static targets

Addresses with no agent (a gateway, a loopback, an outside host). Add them
once on the hub; every node tests them from its next cycle. List only the
tests the target can answer.

```sh
curl -X POST http://<hub-ip>/targets -H 'Content-Type: application/json' \
  -d '{"name":"gw-a","ip":"10.1.1.1","tests":["traceroute","pmtu"],"note":"site-a gateway"}'
curl -s http://<hub-ip>/targets
curl -X DELETE http://<hub-ip>/targets/gw-a
```

Test names: `http ssh traceroute pmtu dns iperf3 smb loss smtp`. An unknown
name gets a 400.

### 6.3 Updating the node scripts

The hub serves `test-cycle.sh` from `/opt/mesh-probe-hub/agent/`. Edit it
there, and every node picks it up at its next registration (within 5
minutes). A node only accepts the new version if its checksum matches, it
passes `sh -n`, and a real test cycle succeeds. Otherwise it keeps the old
one. Watch `/var/log/mesh-probe/register.log`. To stop a node updating, set
`AGENT_AUTOUPDATE=false` in its config.

Only `test-cycle.sh` updates itself. Copy changes to `register.sh`,
`setup.sh` or `test-status.sh` to nodes yourself (`CLAUDE.md` constraint 13).

> **The hub API has no authentication.** Anyone who can reach it can post
> results, add targets or change the script every node runs. Keep the hub on
> an isolated lab network.

### 6.4 Syslog

Point devices at `<hub-ip>`, UDP 514, RFC3164. For example (syntax varies by
vendor):

```
logging host <hub-ip>
logging trap informational
service timestamps log datetime msec show-timezone
```

To test from the hub itself (BusyBox `logger` can't send to the network):

```sh
python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'<190>1: SW-TEST: %SYS-5-CONFIG_I: hello from the hub', ('127.0.0.1', 514))"
curl -s 'http://localhost/api/syslog?minutes=5'
```

You should get one row with host `SW-TEST`. If `/var/log/mesh-probe-hub.log`
doesn't show `[syslog] listening on ...:514`, the port was taken or the hub
isn't running as root. The hub keeps collecting results either way.

On `http://<hub-ip>/syslog` you can filter by time, sender, severity and
text. `severity=4` means warning or worse. Lines the hub couldn't parse have
no severity and always show.

The header shows the hub clock's state: green when synced, amber when
running on its own clock or >100 ms off, red when unsynced. The ±5 min
links from the dashboard depend on this clock.

On the dashboard, each test result links to syslog from ±5 min around it,
and each pair has links filtered by group. Those filter on the hostname the
device puts in its messages. If a group link is empty but the plain link
shows the message, the device logs under a different name than the group.

Keep in mind:

- UDP syslog is lossy and anyone on the network can fake it. Use it for
  troubleshooting, not as an audit trail.
- It is capped at `HUB_SYSLOG_MAX_ROWS` (300000) rows, not by time. A
  chatty device shortens the history.
- `HUB_SYSLOG_ENABLED=false` in `hub.env` turns it off.

---

## 7. Troubleshooting

### Node can't reach the hub

```sh
ip addr show eth0
ip route
ping -c 2 <gateway-ip>
ping -c 2 <hub-ip>
curl -v http://<hub-ip>/ 2>&1 | head -20
```

Usual causes: wrong port group, no route between the subnets, or the hub
isn't running (`rc-service mesh-probe-hub status` on the hub).

### No DHCP address

```sh
udhcpc -i eth0
cat /etc/network/interfaces
```

Usual causes: no DHCP pool on the subnet, or wrong port group. If the subnet
really has no DHCP, run `setup.sh` at the console: it asks for a static IP.
The zero-touch path can't ask, so it leaves the node unconfigured.

### Tests failing

Run a cycle by hand, or test one service against a peer:

```sh
/usr/local/bin/mesh-probe/test-cycle.sh
curl -s http://<peer-ip>/
ssh -i /etc/mesh-probe/id_mesh_probe root@<peer-ip> echo ok
iperf3 -c <peer-ip> -t 2
smbclient -N //<peer-ip>/labshare -c 'get probe.bin /dev/null'
fping -c 5 <peer-ip>
printf 'EHLO test\r\nQUIT\r\n' | nc -w 3 <peer-ip> 25
traceroute <peer-ip>
```

Usual causes: the service isn't running on the peer (dropbear,
`mesh-probe-httpd`, `iperf3`, `mesh-probe-smbd`, `mesh-probe-smtpd`), or a
firewall on the path blocks the port.

### Dashboard doesn't load

On the hub:

```sh
rc-service mesh-probe-hub status
tail -50 /var/log/mesh-probe-hub.log
netstat -tlnp | grep ':80 '
```

To see startup errors directly, stop the service and run it in the
foreground: `rc-service mesh-probe-hub stop; cd /opt/mesh-probe-hub && sh run.sh`.

If the log warns that waitress is missing, the hub fell back to Flask's
single-threaded server and will be slow. Install it with
`apk add py3-waitress`.

### Services not running after a clone

```sh
rc-update show default
rc-status -a
rc default          # start everything in the default runlevel
```

OpenRC service errors go to `/var/log/messages`.

### Alpine basics

- The shell is BusyBox `ash`, not bash.
- Packages: `apk update`, `apk add <pkg>`, `apk del <pkg>`, `apk search <term>`.
- Services: `rc-service <svc> start|stop|restart|status`,
  `rc-update add|del <svc> default`.

---

## 8. No GitHub access

If a VM can reach the Alpine mirror but not GitHub, copy the repo over with
scp instead of the download command.

A fresh Alpine install with dropbear has no `scp` binary, so install one on
the VM first:

```sh
apk add --no-cache openssh-client-default
```

Then copy from your workstation with `scp -O`. The `-O` matters: modern scp
uses SFTP by default, and dropbear has no SFTP server.

```sh
scp -O -r mesh-probe root@<vm-ip>:/root/
```

Then run `sh /root/mesh-probe/install.sh` on the VM.
