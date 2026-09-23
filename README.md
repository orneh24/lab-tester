# Lab Tester

> **AI disclaimer:** This project was created using [Claude Code](https://claude.com/claude-code).

Network end-to-end connectivity testing between nodes on a network. Goes
beyond ICMP — validates real TCP connections (HTTP, SSH, SMB, SMTP, iperf3),
packet loss/jitter, path MTU, DNS resolution and traceroute, optionally
correlates failures against syslog from network devices on the path, and
visualizes results on a web dashboard.

![Dashboard with a synthetic 5-node mesh, one failing path selected, and its syslog correlation panel open](docs/img/dashboard-mock.jpg)

*Mock data — a synthetic 5-node mesh seeded locally to exercise every panel,
not a real lab. See [Running the hub locally](#running-the-hub-locally).*

## Quick start

Four separate steps, run on different VMs — copy-paste each block onto the
VM it names, not all at once.

**1. Base VM** — install Alpine, then run this once before cloning it in
vCenter into the two VMs below:

```sh
wget -O- https://github.com/orneh24/lab-tester/archive/refs/heads/main.tar.gz | tar -xz -C /root && mv /root/lab-tester-main /root/lab-tester
```

**2. Hub VM** (the clone that becomes the hub — build this first, its IP
gets baked into the node image):

```sh
sh /root/lab-tester/install.sh hub -y   # asks nothing, runs hub/build-template.sh
set-static-ip <hub-ip>/<cidr> <gateway> [dns] [hostname]   # or guestinfo.hub.ip/.gateway pre-boot
rc-service networking restart
rc-service lab-tester-hub start
```

**3. Node golden image** (the other clone, kept as a template — not a
deployed node itself):

```sh
sh /root/lab-tester/install.sh node -y   # asks nothing, runs node/build-template.sh
vi /etc/lab-tester/config   # HUB_URL, GROUP_NAME required; SUBNET auto-derives from DHCP
/usr/local/bin/lab-tester/setup.sh
# verify it registers, THEN undo that (it recreated the config and
# hostname the build script had just cleared) before sealing the image:
rm -f /etc/lab-tester/config /etc/lab-tester/config.bak-* \
      /etc/lab-tester/.firstboot-done /etc/lab-tester/.setup-done
printf 'lab-tester-template\n' > /etc/hostname
# now shut down, convert to vCenter template
```

**4. Each deployed node** (every clone made from the golden image above) —
set a unique hostname, then either let `node-setup.sh` prompt at login, or
run it (or `register.sh`) by hand:

```sh
/usr/local/bin/lab-tester/register.sh
```

`install.sh` (interactive, no `-y`) asks which role a fresh base VM becomes
and prints or runs the matching `build-template.sh` — it refuses outright on
a VM that's already configured, since re-running `build-template.sh` there
wipes the existing config/hostname or the hub's database.

**VMware guestinfo parameters** — set as custom keys on the VM in vCenter
(VM Options → Advanced → Configuration Parameters, or PowerCLI's
`New-AdvancedSetting`) before first boot, so a clone configures itself with
no console session. All optional except the two marked required; anything
left unset falls back to an environment variable, then an interactive prompt
at first login.

| Key | Applies to | Example | Notes |
|---|---|---|---|
| `guestinfo.lab.hub_url` | node | `http://10.0.0.100` | **required** |
| `guestinfo.lab.group` | node | `site-a` | **required** — clusters nodes on the dashboard, filters syslog by sender |
| `guestinfo.lab.subnet` | node | `10.1.1.0/24` | derived from the DHCP lease if omitted |
| `guestinfo.lab.hostname` | node | `test-node-site-a` | derived as `<prefix>-<group>` if omitted; must be unique lab-wide |
| `guestinfo.lab.dns_server` | node | `10.0.0.53` | unset skips the DNS test entirely |
| `guestinfo.lab.dns_query` | node | `example.com` | name to resolve, used only when `dns_server` is set |
| `guestinfo.hub.ip` | hub | `10.0.0.100/24` | with neither hub key set, `hub-setup.sh` prompts at first login instead |
| `guestinfo.hub.gateway` | hub | `10.0.0.1` | |

Full command/config reference: [`docs/QUICKSTART.md`](docs/QUICKSTART.md).
Checklist with verification steps: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## What it tests

| Type | Dashboard label | Runs against |
|---|---|---|
| HTTP | H | every node pair, static targets |
| SSH | S | every node pair, static targets |
| Traceroute | T | rationed — on a timer, or on demand after a failure |
| Path MTU | M | every node pair, static targets — catches a path that passes small packets but hangs on large transfers |
| DNS | D | one test per source against a resolver, not a pair — its own panel |
| iperf3 | I | every node pair, when `ENABLE_IPERF=true` |
| SMB | B | every node pair, when `ENABLE_SMB=true` |
| Loss/jitter | L | every node pair, always on — packet loss % and RTT jitter via `fping` |
| SMTP | E | every node pair when `ENABLE_SMTP=true`, plus any static target declaring it (ungated) — catches ESMTP inspection that rewrites capability verbs in flight rather than blocking them |

**Static targets** — gateways, outside hosts, device loopbacks — run no agent
and are configured once on the hub, merged into every node's cycle.

**Syslog correlation** — the hub can optionally receive Cisco/RFC3164-style
syslog over UDP/514 from network devices on the path. Every test card and
pair header in the dashboard links to a `/syslog` window pinned to that
sample's ±5 minutes, so a failing path can be read next to what those devices
said at the time. This is entirely optional — the harness works with no
devices logging to the hub at all.

## Architecture

- **Hub** — Alpine VM, ~192 MB RAM. Not a test participant; infrastructure
  only. Flask API + SQLite (WAL) + syslog receiver, served by waitress. Ships
  its own zero-touch static-IP setup (`guestinfo.hub.*`, or an interactive
  prompt at first login) and a "Hub Health" dashboard panel (services, load,
  memory, disk).
- **Nodes** — Alpine VMs, ~128 MB RAM, one per network segment under test.
  Cloned from a single golden template; drive the tests via cron every 60s
  and push results to the hub. Configure via `guestinfo.lab.*` (zero-touch)
  or an interactive prompt at first login (`node-setup.sh`), same pattern as
  the hub's static-IP setup.

Full design and the constraints that must not regress are in
[`CLAUDE.md`](CLAUDE.md).

> **Status:** the hub is exercised locally (this README's screenshot included).
> See [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for what's still unverified
> and [`docs/HANDOFF.md`](docs/HANDOFF.md) for current state and open items.

### Why not Docker?

The point of this project is to measure a real network path, not a
container bridge pretending to be one. Hub and nodes are full Alpine VMs on
separate subnets specifically so the traffic under test crosses the same
switches, VLANs, firewalls and inspection appliances real production traffic
would — Docker containers on one host typically share a kernel and a virtual
bridge, which is exactly the part of the path this project exists to
exercise. Several tests only mean something because of that separation: PMTU
only catches a real tunnel/MTU clamp if packets actually traverse one; SMTP's
ALG-detection only means something against a real inspection device in the
path; loss/jitter is only informative between hosts a real link separates.
A container bridge would make every one of these pass trivially and prove
nothing.

Docker still has a narrow, deliberate role: the `golden-image-verifier` agent
uses an Alpine container as a fast proxy for real `apk` dependency
resolution and real daemon startup/RSS when reviewing `build-template.sh`
changes — and says so explicitly every time, because that's *all* it proves.
It never verifies OpenRC service lifecycle, VMware guestinfo, or any
multi-host behavior, for the same reason a container can't stand in for the
network this project tests.

For fast local iteration without VMs at all — hub/dashboard work, or trying
out a node-script change — see [`dev/README.md`](dev/README.md). That
toolkit is upfront about the same trade-off in the other direction: it runs
the real scripts against a real hub, but every network client they shell out
to is shimmed, so it's for exercising *logic*, not for anything resembling
real network conditions.

## Running the hub locally

```sh
cd hub
HUB_DB_PATH=/tmp/hub.db HUB_PORT=8099 HUB_SYSLOG_PORT=5514 python3 serve.py
```

`serve.py` is the entrypoint — it reads `HUB_PORT` at runtime and starts the
syslog listener; don't run `flask run` against `app/app.py` directly, that
skips both. Ports below 1024 need root, hence `HUB_SYSLOG_PORT` above here.

## Docs

| File | Covers |
|---|---|
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | One-page command/config reference for an experienced sysadmin |
| [`CLAUDE.md`](CLAUDE.md) | Architecture, design decisions, constraints that must not regress |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Build order and checklist, stage by stage |
| [`docs/BUILD_GUIDE.md`](docs/BUILD_GUIDE.md) | Step-by-step detail for each stage |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | Current state, recent changes, open items |
| [`docs/TOPOLOGY.md`](docs/TOPOLOGY.md) | System diagram — hub, nodes, and the network between them |
| [`dev/README.md`](dev/README.md) | Local hub + simulated mesh for coding sessions — no VMs |
| [`deploy/README.md`](deploy/README.md) | PowerCLI script to deploy a hub + N nodes from existing templates |
