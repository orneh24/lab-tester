# Mesh Probe — Deployment Checklist

The build order, with a check after each stage. Commands only:
[README quick start](../README.md#quick-start). Detail: `BUILD_GUIDE.md`.
What is still unverified on real VMs: `HANDOFF.md`.

The network between nodes is out of scope. This assumes it exists and is
reachable.

---

## 0. Plan the addresses

- [ ] One subnet (port group) per network segment you want to test
- [ ] A hub segment that every node subnet can reach
- [ ] The hub's static IP and gateway
- [ ] Internet access (Alpine mirror and GitHub) from every VM while it is
      being built

---

## 1. Base Alpine VM

- [ ] Create one VM from the alpine-virt ISO (BUILD_GUIDE §2) and run
      `setup-alpine` (§3)
- [ ] Clone it twice: one clone for the hub, one for the node template

---

## 2. Hub

Build the hub first, so you can test the first node against it.

- [ ] On the hub clone, run the download command from the README quick start
      and pick **hub**. (No GitHub access? See BUILD_GUIDE §8.)
- [ ] Set the static IP, one of:
      - **At login:** log out and back in. `hub-setup.sh` asks for the IP and
        gateway, restarts networking and starts the hub.
      - **By hand:** `set-static-ip <ip/cidr> <gateway>`,
        `rc-service networking restart`, `rc-service mesh-probe-hub start`.
        The helper rewrites all of `/etc/network/interfaces` for one
        interface.
      - **guestinfo:** set `guestinfo.hub.ip` and `guestinfo.hub.gateway` on
        the VM and reboot.
- [ ] Optional: edit `/opt/mesh-probe-hub/hub.env` (each key is commented),
      then `rc-service mesh-probe-hub restart`
- [ ] Optional: set a real NTP server in `/etc/chrony/chrony.conf`. The build
      enables chrony but doesn't configure it.

Check:

- [ ] `http://<hub-ip>/` loads
- [ ] `grep syslog /var/log/mesh-probe-hub.log` shows
      `[syslog] listening on <bind>:514`
- [ ] `curl http://<hub-ip>/api/syslog?minutes=5` returns JSON (`[]` is fine)
- [ ] `curl http://<hub-ip>/api/health` and `/api/time` return 200
- [ ] The clock indicator in the `/syslog` header is not red, and
      `chronyc tracking` shows `Leap status: Normal`. Syslog correlation is
      only as good as this clock.
- [ ] `lldpcli show neighbors` names the switch port the hub is on

The hub is not an NTP server. Point devices that log to it at a real NTP
server.

---

## 3. Node template

- [ ] On the node clone, run the download command and pick **node**
- [ ] Optional: `rm -rf /root/mesh-probe`
- [ ] `poweroff`, then convert the VM to a template in vCenter

**Don't configure or test the template.** The build ends by clearing the
config, hostname, login stamp and SSH host keys so each clone starts fresh.
Running `setup.sh` here puts them back, and every clone would inherit them.
Test on the first clone instead (stage 4).

---

## 4. Nodes

For each network segment:

- [ ] Clone the template and set its NIC to that segment's port group
- [ ] Configure it, one of:
      - **guestinfo:** set `guestinfo.meshprobe.hub_url` and
        `guestinfo.meshprobe.group` before first boot. It configures itself.
      - **At login:** boot, log in, and answer the `node-setup.sh` prompt.
- [ ] The node shows in `http://<hub-ip>/endpoints` with a recent `last_seen`

On the first clone, also check:

- [ ] `test-status` shows passing tests after a minute
- [ ] `rc-service dropbear status`, `mesh-probe-httpd`, `crond`, `lldpd` and
      `open-vm-tools` are running, plus `iperf3` / `mesh-probe-smbd` /
      `mesh-probe-smtpd` for any `ENABLE_*` flag you set
- [ ] With `ENABLE_SMTP=true`: `grep -n relay /etc/smtpd/smtpd.conf` shows
      only comments

The hostname is set automatically (`mp-<group>-<ip>`), so clones don't
collide. If you set `guestinfo.meshprobe.hostname` yourself, make it unique:
two nodes with one name overwrite each other on the hub.

---

## 5. Syslog from network devices (optional)

If you can point devices on the path at the hub, do; if not, `/syslog` stays
empty and nothing else changes.

- [ ] Device logs to `<hub-ip>:514` (RFC3164, UDP), and uses real NTP
- [ ] Messages show in `http://<hub-ip>/syslog`
- [ ] Device clock matches the hub's `/api/time`

---

## 6. Acceptance

- [ ] Every pair in the matrix has results within two test cycles
- [ ] With syslog: take a link down, check the cells go red and the
      "syslog ±5 min" link shows the device's message
- [ ] Stop cron on one node: its cells go grey and it turns amber in the
      Endpoints list after 5 minutes
- [ ] Hub and node clocks agree within a second

If a group's syslog link is empty while the unfiltered window shows the
message, the device logs under a different hostname than the node's group.
