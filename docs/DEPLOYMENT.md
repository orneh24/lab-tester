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
- [ ] Snapshot or clone twice — this base becomes both the hub and the node
      image

---

## 2. Hub — must be finished before the golden image

**Ordering dependency: `HUB_URL` is baked into the node image, so the hub
needs its final address first.**

`hub/build-template.sh` is the deploy. It installs the packages, populates
`/opt/lab-tester-hub/`, writes `hub.env` and `/etc/init.d/lab-tester-hub`,
installs `set-static-ip`, and enables the hub, chronyd, open-vm-tools and
dropbear. Do not hand-build any of that — BUILD_GUIDE 6.1–6.5 predates the
script and contradicts it (its init script runs `run.sh`; the real one runs
`python3 serve.py`).

- [ ] Copy `hub/` to the VM, run `hub/build-template.sh`
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
- [ ] `grep syslog /var/log/lab-tester-hub.log` contains
      `[syslog] listening on <bind>:514`
- [ ] `curl http://<hub-ip>/api/syslog?minutes=5` returns JSON (`[]` before any
      device sends anything — an error means the listener did not start)
- [ ] `curl http://<hub-ip>/api/health` returns 200. The dashboard's "Hub
      Health" panel reads this — service/syslog-listener status, load,
      memory, disk, uptime. Never 500s; a service check that can't run
      (e.g. `rc-service` missing) reports `status: null` with a reason
      rather than failing the page
- [ ] `curl http://<hub-ip>/api/time` returns 200 with a `utc`, and the `/syslog`
      header indicator is not red. It reports `chronyc -n tracking`: red means
      `Leap status` is not `Normal`, amber means the hub is on its own
      `local stratum 10` clock or more than 100 ms out. `chrony: null` with a
      reason (chronyc missing, daemon down, timed out) renders amber rather than
      failing the page
- [ ] `chronyc tracking` — Leap status Normal. Edit the `pool` line in
      `/etc/chrony/chrony.conf` by hand if the lab has upstream NTP; the build
      script installs chrony and enables chronyd, and configures neither
- [ ] `sysctl net.ipv4.ip_forward` returns 0 — Alpine's default, but nothing in
      the build asserts it, so check rather than assume
- [ ] `rc-service lldpd status` — always-on, not gated; `lldpcli show
      neighbors` should name the switch port on the other end

> **The hub is not an NTP server.** `chronyd` runs to discipline the hub's own
> clock, which is the mesh reference because the hub stamps every `received_at`.
> It serves time to nobody: there is no access list, no `set-ntp-clients`, and
> no `chrony.conf` shipped. Point any device that logs to the hub at real
> upstream NTP, not at the hub — see stage 5.

---

## 3. Node golden image

- [ ] Copy `node/` to the second VM, run `node/build-template.sh`
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
- [ ] Clean up (BUILD_GUIDE 7): clear machine-id, remove dropbear host keys,
      clear logs, zero free space
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
- [ ] If any device is logging to the hub, disable a link and confirm the
      affected cells go red, and the ±5 min syslog link from the drill-down
      shows the corresponding message at that moment. The per-group links
      beside it filter on the *syslog* hostname, which is whatever the
      device puts in its own messages — if one comes back empty while the
      unfiltered window has the message, that device logs under a different
      name than `guestinfo.lab.group`
- [ ] Stop cron on one node: its matrix cells fade to **grey** ("no data") — the
      matrix has only pass / fail / no-data, no amber. The amber "stale" marker
      is in the separate **Endpoints** list, and appears once that node's
      `last_seen` passes 5 minutes. That list is the "not reporting" indicator
- [ ] Clock check: hub and every node agree within a second

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
