# Lab Tester

> **AI disclaimer:** This project was created using [Claude Code](https://claude.com/claude-code).

Network end-to-end connectivity testing for the "inside" interfaces of
virtualized Cisco CSR1000v routers in an R&S lab. Goes beyond ICMP — validates
real TCP connections (HTTP, SSH, iperf3), path MTU, DNS resolution and
traceroute, correlates failures against the routers' own syslog, and
visualizes results on a web dashboard.

![Dashboard with a synthetic 5-router mesh, one failing path selected, and its syslog correlation panel open](docs/img/dashboard-mock.jpg)

*Mock data — a synthetic 5-router mesh seeded locally to exercise every panel,
not a real lab. See [Running the hub locally](#running-the-hub-locally).*

## What it tests

| Type | Dashboard label | Runs against |
|---|---|---|
| HTTP | H | every VM pair, static targets |
| SSH | S | every VM pair, static targets |
| Traceroute | T | rationed — on a timer, or on demand after a failure |
| Path MTU | M | every VM pair, static targets — catches a tunnel that passes small packets but hangs on large transfers |
| DNS | D | one test per source against a resolver, not a pair — its own panel |
| iperf3 | I | every VM pair, when `ENABLE_IPERF=true` |

**Static targets** — router loopbacks, outside hosts — run no agent and are
configured once on the hub, merged into every VM's cycle.

**Syslog correlation** — the hub also receives Cisco/RFC3164 syslog over
UDP/514. Every test card and pair header in the dashboard links to a `/syslog`
window pinned to that sample's ±5 minutes, so a failing path can be read next
to what the routers said at the time.

## Architecture

- **Hub VM** — Alpine, ~192 MB RAM. Not a test participant; infrastructure
  only. Flask API + SQLite (WAL) + syslog receiver, served by waitress. Ships
  its own zero-touch static-IP setup (`guestinfo.hub.*`, or an interactive
  prompt at first login) and a "Hub Health" dashboard panel (services, load,
  memory, disk).
- **Test VMs** — Alpine, ~128 MB RAM, one per router inside subnet. Cloned
  from a single golden template; drive the tests via cron every 60s and push
  results to the hub.
- **Routers (CSR1000v)** — eBGP full mesh over a shared outside segment (one
  AS per router), a VRF-isolated management plane, NAT for internet access.
  Baseline + worked-example configs in `docs/csr-baseline.cfg` /
  `docs/csr-example-r1.cfg`; diagram in [`docs/TOPOLOGY.md`](docs/TOPOLOGY.md).

Full design and the constraints that must not regress are in
[`CLAUDE.md`](CLAUDE.md).

> **Status:** the hub is exercised locally (this README's screenshot included)
> but nothing here has run on real CSR1000v hardware yet. See
> [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) for what's still unverified and
> [`docs/HANDOFF.md`](docs/HANDOFF.md) for current state and open items.

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
| [`CLAUDE.md`](CLAUDE.md) | Architecture, design decisions, constraints that must not regress |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | Build order and checklist, stage by stage |
| [`docs/BUILD_GUIDE.md`](docs/BUILD_GUIDE.md) | Step-by-step detail for each stage |
| [`docs/HANDOFF.md`](docs/HANDOFF.md) | Current state, recent changes, open items |
| [`docs/TOPOLOGY.md`](docs/TOPOLOGY.md) | Network diagram — segments, routing, hub NICs |
| [`docs/csr-baseline.cfg`](docs/csr-baseline.cfg), [`docs/csr-example-r1.cfg`](docs/csr-example-r1.cfg) | CSR1000v config templates (placeholders, not real addresses) |
