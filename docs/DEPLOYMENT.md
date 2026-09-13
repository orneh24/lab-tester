# Lab-Tester — Deployment Checklist

Order of operations for building the lab from nothing. Step detail lives in
`BUILD_GUIDE.md`; this file is the sequence and the dependencies between stages.
`CLAUDE.md` holds the architecture, `HANDOFF.md` the current state.

> **Nothing here has run on real hardware yet.** The hub code is container-tested
> with chrony faked. The OpenRC services, the UDP/514 bind under the service, and
> the Alpine package set have never been exercised on an actual VM. Expect to fix
> something in stage 3.

---

## 0. Addressing and port groups

Everything downstream bakes these in. Settle them before touching a VM.

- [ ] Inside subnet per router (separate /24s), e.g. `10.1.1.0/24`, `10.2.1.0/24`
- [ ] Hub segment, routable from every inside subnet
- [ ] Management VLAN subnet (router mgmt interfaces + hub NIC2)
- [ ] Hub NIC1 address (hub segment, with gateway)
- [ ] Hub NIC2 address (management VLAN, no gateway) — **intent, not a built
      step.** `set-static-ip` manages one interface and rewrites
      `/etc/network/interfaces` wholesale, so NIC2 is a hand-edit afterwards.
      Settle the address here anyway; stage 3 has the detail
- [ ] vCenter port groups created: one per inside VLAN, one management, one hub segment

---

## 1. Routers (CSR1000v)

`docs/csr-baseline.cfg` (identical on every router) and
`docs/csr-example-r1.cfg` (per-router worked example, R1) cover this stage —
eBGP full mesh over Outside-shared, one AS per router, NAT overload for
internet access, and the SNMP read-only community. See `docs/TOPOLOGY.md` for
the diagram. Both files use `<PLACEHOLDER>` tokens throughout; nothing in them
is a real address.

- [ ] Deploy the routers; configure inside and outside interfaces
- [ ] Routing between routers so inside subnets reach each other
- [ ] DHCP pool on each inside interface
- [ ] Routing so every inside subnet reaches the hub segment (global table)
- [ ] Management interface into a VRF on the management VLAN. There is no
      walkthrough for this in BUILD_GUIDE — it is router-side work

Syslog, NTP and SNMP configuration comes in stage 6, once the hub has an
address.

> Do the VRF now rather than later: `vrf forwarding` wipes the interface's IP
> configuration, which is painless before anything depends on the router and
> disruptive afterwards.

---

## 2. Base Alpine VM

- [ ] One VM from the alpine-virt ISO (BUILD_GUIDE 2–3)
- [ ] `setup-alpine`, community repository enabled, core packages installed (4.1–4.2)
- [ ] Snapshot or clone twice — this base becomes both the hub and the test-VM image

---

## 3. Hub — must be finished before the golden image

**Ordering dependency: `HUB_URL` is baked into the test-VM image, so the hub
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

> **A second management NIC is a hand-build.** `set-static-ip` manages one
> interface and rewrites the file, so a second address must be added to
> `/etc/network/interfaces` by hand afterwards, gateway omitted. There is no
> per-interface state and no helper. Everything below assumes one NIC unless you
> have done that work.

Verify before moving on:

- [ ] Dashboard loads on `http://<hub-ip>/`
- [ ] `grep syslog /var/log/lab-tester-hub.log` contains
      `[syslog] listening on <bind>:514`
- [ ] `curl http://<hub-ip>/api/syslog?minutes=5` returns JSON (`[]` before any
      router is configured — an error means the listener did not start)
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
      neighbors` should name the switch/router port on the other end
- [ ] `rc-service lab-tester-serve status`, then `curl http://<hub-ip>:8080/`
      returns a directory listing (empty until the first `publish-config`)

> **The hub is not an NTP server.** `chronyd` runs to discipline the hub's own
> clock, which is the mesh reference because the hub stamps every `received_at`.
> It serves time to nobody: there is no access list, no `set-ntp-clients`, and
> no `chrony.conf` shipped. Point the routers at real upstream NTP, not at the
> hub — see stage 6.

> **Config file download server.** `lab-tester-serve` (busybox httpd, read-only,
> directory listing on) serves `/srv/lab-tester-configs/` on port 8080,
> `SERVE_BIND=0.0.0.0` by default — every address, deliberately, since a
> router pulling a config over `copy http://` may not have its management-VLAN
> interface configured yet. `publish-config <file>` copies a file in and
> prints the URL, MD5, and the exact router-side commands (`copy` →
> `verify /md5` → `reload in 5` as a safety net → `configure replace`, never
> `copy <url> running-config`, which merges instead of replacing). Configured
> in `/etc/conf.d/lab-tester-serve` (`SERVE_BIND`, `SERVE_PORT`, `SERVE_DIR`).

---

## 4. Test-VM golden image

- [ ] Copy `test-vm/` to the second VM, run `test-vm/build-template.sh`
- [ ] `/etc/lab-tester/config`: set **all three** of `HUB_URL`, `ROUTER_NAME`
      and `SUBNET`. `register.sh` validates every one of them and `exit 1`s on
      the first that is empty — nothing is derived or defaulted. A clone missing
      any of the three never appears in the matrix, and the only symptom is its
      absence
- [ ] Run `setup.sh`. It does **not** configure chrony — test VMs sync to
      Alpine's default NTP pool, and nothing points them at the hub
- [ ] Verify dropbear, httpd, iperf3, crond and lldpd are running; identity
      page renders. If `ENABLE_SMB=true`, verify `lab-smbd` is running too —
      it is not started by default (lldpd, unlike smb, always is)
- [ ] Confirm registration works against the live hub before sealing the image
- [ ] Clean up (BUILD_GUIDE 7): clear machine-id, remove dropbear host keys,
      clear logs, zero free space
- [ ] Shut down, convert to template in vCenter

---

## 5. Clone one VM per inside subnet

Repeat per router:

- [ ] Clone from template
- [ ] Assign that router's inside port group
- [ ] Power on
- [ ] **Set a unique hostname** — the only per-clone edit, and the only silent
      failure left: two clones sharing a hostname means one overwrites the
      other's registration and the second never appears in the matrix
- [ ] Optionally set `ROUTER_NAME` for the dashboard badge
- [ ] Reboot, or run `register.sh`
- [ ] Confirm it appears in `GET /endpoints` with a recent `last_seen`

---

## 6. Point the routers at the hub

This is `docs/csr-baseline.cfg`'s logging/NTP/SNMP block, applied per router
(all three lines carry `vrf MGMT`; drop it only if management is deliberately
in the global table):

```
service timestamps log datetime msec localtime show-timezone
logging host <hub-mgmt-ip> vrf MGMT
logging trap informational
ntp server vrf MGMT <upstream-ntp-ip>
snmp-server community <snmp-ro-community> RO <acl restricted to hub-mgmt-ip>
```

**The hub is not an NTP server** — point `ntp server` at real upstream time, not
at the hub. The hub disciplines its own clock only.

- [ ] `/syslog` shows messages from every router
- [ ] `show ntp status` on each router reports synchronised
- [ ] Router and hub clocks agree — compare `show clock` against the hub's
      `/api/time`. The ±5 min correlation windows are only as good as this
- [ ] SNMP polling works from the hub (`net-snmp` is deliberately not
      installed — the hub's own client is what enforces the `HUB_MGMT_IP`
      source-bind; a CLI `snmpget` here would prove nothing about that):
      set `HUB_SNMP_ENABLED=true` and `HUB_MGMT_IP` in `hub.env`, restart,
      then register the router and read it back —
      `curl -X POST http://<hub-ip>/snmp/targets -d '{"name":"R1","mgmt_ip":"<router-mgmt-ip>"}'`
      followed by `curl -s http://<hub-ip>/api/snmp?router=R1` should show
      `status: "ok"` rows

> A `logging host` or `ntp server` line missing `vrf MGMT` fails silently: the
> router looks the hub up in the global table, finds nothing, and reports no
> error. An empty `/syslog` after this stage is nearly always this.

---

## 7. Acceptance

- [ ] Matrix populates for every pair within two test cycles
- [ ] `shutdown` an inside interface: affected cells go red, and the ±5 min
      syslog link from the drill-down shows the `%LINK-3-UPDOWN` at that moment.
      The per-router links beside it filter on the *syslog* hostname, which is
      whatever the router puts in its own messages — if one comes back empty
      while the unfiltered window has the message, that router logs under a
      different name than `guestinfo.lab.router`
- [ ] Stop cron on one VM: its matrix cells fade to **grey** ("no data") — the
      matrix has only pass / fail / no-data, no amber. The amber "stale" marker
      is in the separate **Endpoints** list, and appears once that VM's
      `last_seen` passes 5 minutes. That list is the "not reporting" indicator
- [ ] Inspect a stored traceroute: **no management IPs in the hop list**. If any
      appear, management separation has leaked and every green cell is suspect
- [ ] Clock check: hub, a test VM and a router all agree within a second

---

## Traps, collected

| Trap | Consequence |
|---|---|
| Golden image built before the hub has its final IP | Every clone has the wrong `HUB_URL` |
| Duplicate hostname on a clone | One VM silently overwrites another's registration |
| `vrf forwarding` applied to a live interface | Drops the session you are configuring over |
| `logging`/`ntp` without `vrf` | Silent failure, no error on the router |
| Management VLAN without a VRF | Routers gain a path outside the tested topology; matrix goes green while measuring nothing |
| Two default gateways on the hub | Asymmetric paths, diagnosed from the box whose job is diagnosing paths |

---

## Routine operations

- Publishing a router config from the hub: `publish-config <file>` on the hub
  copies it into `/srv/lab-tester-configs/` (served by `lab-tester-serve` on
  port 8080, every address) and prints the URL, MD5, and the exact commands
  to run. On the router: `copy http://<hub-ip>:8080/<file> flash:` →
  `verify /md5` → `reload in 5` → `configure replace` → `reload cancel`, and
  **never** `copy <url> running-config` — that merges.
- Add a router: clone a test VM (stage 5), configure syslog/NTP (stage 6).
- An amber row in the **Endpoints** list means a VM stopped registering
  (`last_seen` over 5 minutes). Its matrix cells go grey rather than amber.
  Either way, start at that VM's logs in `/var/log/lab-tester/`, not at the
  network.
