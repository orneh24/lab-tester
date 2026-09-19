# Lab-Tester — Deployment Checklist

Order of operations for building the lab from nothing. Step detail lives in
`BUILD_GUIDE.md`; this file is the sequence and the dependencies between stages.
`CLAUDE.md` holds the architecture, `HANDOFF.md` the current state.

The network between nodes — routers, switches, firewalls, however many hops
— is out of scope here. This checklist assumes that network already exists
and is reachable; building or configuring it belongs to a separate project.

> **Nothing here has run on real hardware yet.** The hub code is container-tested
> with chrony faked. The OpenRC services, the UDP/514 bind under the service, and
> the Alpine package set have never been exercised on an actual VM. Expect to fix
> something in stage 2.

---

## Quick Start

The command path to a working hub and one registered node, for anyone who
just wants to get moving. No verification steps, no explanations — those are
in the numbered stages below; come back to them when something doesn't work.

```sh
# 1. One base Alpine VM, installed by hand (interactive — see BUILD_GUIDE §1-3)
setup-alpine
# then, once: apk add --no-cache git && git clone <repo-url> /root/lab-tester
# (dropbear alone can't receive scp/sftp — see stage 1's note if git isn't
# reachable from the VM)
# then snapshot/clone it twice: one clone becomes the hub, one becomes the
# node golden image — both already have the checkout

# 2. Hub — do this first; its IP gets baked into the node image
#    (on the hub clone)
sh /root/lab-tester/hub/build-template.sh
set-static-ip <hub-ip>/<cidr> <gateway>
rc-service networking restart
rc-service lab-tester-hub start
# confirm: http://<hub-ip>/ loads

# 3. Node golden image
#    (on the other clone)
sh /root/lab-tester/node/build-template.sh
vi /etc/lab-tester/config        # set HUB_URL, GROUP_NAME, SUBNET
/usr/local/bin/lab-tester/setup.sh
# confirm it registers against the live hub, THEN undo what that just
# did before sealing it (see stage 3 below) — verifying re-creates the
# config and hostname the build script had just cleared:
rm -f /etc/lab-tester/config /etc/lab-tester/.firstboot-done
printf 'lab-tester-template\n' > /etc/hostname
# now shut down and convert to a vCenter template

# 4. Clone the node template once per subnet
#    (on each clone) set a unique hostname, then:
register.sh
# confirm it appears in http://<hub-ip>/endpoints
```

That's a working two-node lab. Syslog correlation is optional (stage 5
below); static targets and the `ENABLE_SMB`/`ENABLE_IPERF`/`ENABLE_SMTP`
flags are optional too (BUILD_GUIDE §6A).

---

## 0. Addressing

Everything downstream bakes these in. Settle them before touching a VM.

- [ ] One subnet per node (or per network segment under test), e.g.
      `10.1.1.0/24`, `10.2.1.0/24`
- [ ] Hub segment, routable from every node subnet
- [ ] Hub address (with gateway)
- [ ] vCenter port groups created: one per node subnet, one for the hub segment

---

## 1. Base Alpine VM

- [ ] One VM from the alpine-virt ISO (BUILD_GUIDE 2–3)
- [ ] `setup-alpine`, community repository enabled, core packages installed (4.1–4.2)
- [ ] Get the project files onto the VM **once, before cloning**:
      `apk add --no-cache git && git clone <repo-url> /root/lab-tester`.
      `git` lives in Alpine's `main` repo, so this works even before
      community is enabled. Both `hub/` and `node/` come along in the one
      checkout, so this replaces copying files separately onto the hub and
      node clones later (stages 2–3) — see the note below if git access
      from the VM isn't available.
- [ ] Snapshot or clone twice — this base becomes both the hub and the node
      image

> **No git access from the VM?** SCP the `hub/`/`node/` directories over
> instead (BUILD_GUIDE Appendix A.2 / B.2) — but not yet. A bare
> `setup-alpine` install with only dropbear has **no `scp` or `sftp` binary
> at all**; you need `apk add --no-cache openssh-client-default` first, and
> even then the client must pass `scp -O` (legacy protocol) — dropbear can
> run `scp` fine but has no `sftp-server` to serve OpenSSH's SFTP-based
> default, which is what current `scp` clients (OpenSSH 9.0+, the default
> since 2022) try first.

---

## 2. Hub — must be finished before the golden image

**Ordering dependency: `HUB_URL` is baked into the node image, so the hub
needs its final address first.**

`hub/build-template.sh` is the deploy. It installs the packages, populates
`/opt/lab-tester-hub/`, writes `hub.env` and `/etc/init.d/lab-tester-hub`,
installs `set-static-ip`, and enables the hub, chronyd, open-vm-tools and
dropbear. Do not hand-build any of that — BUILD_GUIDE's Appendix B predates
the script and contradicts it (its init script runs `run.sh`; the real one
runs `python3 serve.py`). It's kept only as reference for what the script
does, not as build steps to follow.

- [ ] Run `sh /root/lab-tester/hub/build-template.sh` (already on the VM if
      you cloned in stage 1; otherwise SCP `hub/` over first — see stage 1's
      note)
- [ ] Set the static IP, either way:
      - **Guestinfo (zero-touch):** set `guestinfo.hub.ip` and
        `guestinfo.hub.gateway` on the VM before boot; `lab-tester-hub-firstboot`
        applies them automatically, no console session needed.
      - **Manual:** log in — `hub-setup.sh` runs automatically at first login
        and prompts for both values, or run `set-static-ip <ip/cidr> <gateway>`
        yourself. **One interface, no NIC argument** — the helper writes the
        whole of `/etc/network/interfaces`.
- [ ] `rc-service networking restart` (skip if `hub-setup.sh` already did it)
- [ ] `/opt/lab-tester-hub/hub.env` if the defaults do not suit. The file is
      written by `build-template.sh` and every key is commented in place with
      what it does; `hub/app/config.py` is where they are read
- [ ] `rc-service lab-tester-hub start` — `rc-update` already ran in the script

Verify before moving on:

- [ ] Dashboard loads on `http://<hub-ip>/`
- [ ] `grep syslog /var/log/lab-tester-hub.log` shows the listener bound
- [ ] `curl http://<hub-ip>/api/syslog?minutes=5` returns JSON
- [ ] `curl http://<hub-ip>/api/health` returns 200
- [ ] `curl http://<hub-ip>/api/time` returns 200, and the `/syslog` header
      clock indicator is not red
- [ ] `chronyc tracking` — Leap status Normal
- [ ] `sysctl net.ipv4.ip_forward` returns 0
- [ ] `rc-service lldpd status` is running, and `lldpcli show neighbors`
      names the switch port on the other end

**Notes on the checks above:**

- **Syslog listener:** expect `[syslog] listening on <bind>:514` in the log.
  `/api/syslog` returns `[]` before any device has sent anything — an error
  response, not an empty array, is what means the listener didn't start.
- **`/api/health`:** backs the dashboard's "Hub Health" panel (service and
  syslog-listener status, load, memory, disk, uptime). It never 500s — a
  check that can't run (e.g. `rc-service` missing) reports `status: null`
  with a reason rather than failing the page.
- **`/api/time` / clock indicator:** reports `chronyc -n tracking`. Red means
  `Leap status` isn't `Normal`; amber means the hub is on its own
  `local stratum 10` clock or more than 100 ms out. `chrony: null` with a
  reason (chronyc missing, daemon down, timed out) renders amber rather than
  failing the page. This matters because the ±5 min syslog correlation
  windows (stage 5) are only as good as this clock.
- **`chronyc tracking`:** the build script installs chrony and enables
  chronyd but configures neither. Edit the `pool` line in
  `/etc/chrony/chrony.conf` by hand if the lab has upstream NTP.
- **`ip_forward`:** Alpine's default is 0, but nothing in the build asserts
  it — check rather than assume.
- **`lldpd`:** always-on, not gated by any `ENABLE_*` flag.

> **The hub is not an NTP server.** `chronyd` disciplines the hub's own
> clock only — it serves time to nobody (no access list, no
> `set-ntp-clients`, no `chrony.conf` shipped). Point any device that logs
> to the hub at real upstream NTP, not at the hub — see stage 5.

---

## 3. Node golden image

- [ ] Run `sh /root/lab-tester/node/build-template.sh` (already on the VM if
      you cloned in stage 1; otherwise SCP `node/` over first — see stage 1's
      note)
- [ ] `/etc/lab-tester/config`: set **all three** of `HUB_URL`, `GROUP_NAME`
      and `SUBNET`. `register.sh` validates every one of them and `exit 1`s on
      the first that is empty — nothing is derived or defaulted. A clone missing
      any of the three never appears in the matrix, and the only symptom is its
      absence
- [ ] Run `setup.sh`. It does **not** configure chrony — nodes sync to
      Alpine's default NTP pool, and nothing points them at the hub
- [ ] Verify dropbear, httpd, iperf3, crond and lldpd are running; identity
      page renders. If `ENABLE_SMB=true`, verify `lab-smbd` is running too —
      it is not started by default (lldpd, unlike smb, always is). Same for
      `lab-smtpd` under `ENABLE_SMTP`, plus `grep -n relay /etc/smtpd/smtpd.conf`
      returning nothing but comments before trusting it with a real network path
- [ ] Confirm registration works against the live hub before sealing the image
- [ ] **Redo the config/hostname cleanup** — `node/build-template.sh` already
      cleared `/etc/lab-tester/config` and reset the hostname to
      `lab-tester-template` as its last step, but the config-and-`setup.sh`
      verification above just undid both. Repeat that part by hand:
      `rm -f /etc/lab-tester/config /etc/lab-tester/.firstboot-done` and
      `printf 'lab-tester-template\n' > /etc/hostname`. Skip this and every
      clone starts with this run's real `GROUP_NAME`/`SUBNET` and hostname
      baked in — the hostname collision stage 4 warns about, from clone one.
      The rest of the script's cleanup (machine-id, dropbear host keys,
      logs, zero free space) doesn't need repeating — nothing after it
      touched those
- [ ] `rm -rf /root/lab-tester` if you used a git checkout (stage 1) to get
      the files onto the VM
- [ ] Shut down, convert to template in vCenter

---

## 4. Clone one node per subnet

Repeat per subnet:

- [ ] Clone from template
- [ ] Assign the correct port group
- [ ] Power on
- [ ] **Set a unique hostname** — the only per-clone edit, and the only silent
      failure left: two clones sharing a hostname means one overwrites the
      other's registration and the second never appears in the matrix
- [ ] Optionally set `GROUP_NAME` for the dashboard badge
- [ ] Reboot, or run `register.sh`
- [ ] Confirm it appears in `GET /endpoints` with a recent `last_seen`

---

## 5. Point network devices at the hub's syslog receiver (optional)

Entirely optional, and outside this project's own configuration surface —
if the network between nodes includes devices you can point at the hub for
troubleshooting correlation, do so; if not, `/syslog` simply stays empty and
nothing else is affected.

Whatever the device, logging to `<hub-ip>:514` (RFC3164/UDP) is all that's
needed. Point it at real upstream NTP too, if it has a clock — not at the
hub, which is not an NTP server (see stage 2).

- [ ] `/syslog` shows messages from the device once configured
- [ ] Device and hub clocks agree — compare the device's own clock against
      the hub's `/api/time`. The ±5 min correlation windows are only as good
      as this

---

## 6. Acceptance

- [ ] Matrix populates for every pair within two test cycles
- [ ] If any device is logging to the hub: disable a link, confirm the
      affected cells go red, and confirm the ±5 min syslog link from the
      drill-down shows the corresponding message at that moment
- [ ] Stop cron on one node and confirm its matrix cells fade to grey
- [ ] Clock check: hub and every node agree within a second

**Notes:**

- The per-group syslog links beside the drill-down filter on the *syslog*
  hostname — whatever the device puts in its own messages. If one comes back
  empty while the unfiltered window has the message, that device logs under
  a different name than `guestinfo.lab.group`.
- The matrix has only pass / fail / no-data, no amber — a stopped node's
  cells go grey. The amber "stale" marker lives in the separate
  **Endpoints** list instead, and appears once that node's `last_seen`
  passes 5 minutes; that list is the "not reporting" indicator.

---

## Traps, collected

| Trap | Consequence |
|---|---|
| Golden image built before the hub has its final IP | Every clone has the wrong `HUB_URL` |
| Duplicate hostname on a clone | One node silently overwrites another's registration |

---

## Routine operations

- An amber row in the **Endpoints** list means a node stopped registering
  (`last_seen` over 5 minutes). Its matrix cells go grey rather than amber.
  Either way, start at that node's logs in `/var/log/lab-tester/`, not at the
  network.
