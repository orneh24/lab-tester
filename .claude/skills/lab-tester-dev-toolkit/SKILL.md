---
name: lab-tester-dev-toolkit
description: How to run, launch, start, demo, or locally test the lab-tester project (hub + nodes) without any VM. Use this whenever asked to "run the app," "start the hub," "spin up a test mesh," "see this change working," "demo the dashboard," or to verify a change to hub/, node/scripts/register.sh, or node/scripts/test-cycle.sh actually works end to end — before reaching for docker, a generic dev server guess, or a real VM. Also covers simulating a broken network path in the demo mesh and where to view results.
---

# lab-tester dev toolkit

This project ships its own local dev/demo toolkit under `dev/` — a real hub
plus simulated nodes, entirely on the workstation, no vCenter or VM
required. Full detail lives in `dev/README.md`; this skill is the quick
map to it so you reach for the real commands instead of guessing a launch
pattern. Read `dev/README.md` itself before anything nontrivial — this
file intentionally doesn't repeat its edge cases.

Scripts are POSIX `sh`, matching the real node scripts — run them with the
Bash tool (git-bash/WSL on Windows), not PowerShell.

## Start the hub

```sh
dev/hub-start.sh    # http://127.0.0.1:8099, backgrounded, writes a pidfile
dev/hub-stop.sh
```

Populates `hub/agent/` from `node/scripts/{register,test-cycle}.sh` (mirrors
what `build-template.sh` does at real build time), runs `hub/serve.py`. DB
and log land in `dev/run/` (gitignored) — override with `HUB_DB_PATH`,
`HUB_PORT`, `HUB_SYSLOG_PORT` env vars before calling it. Reset the whole
demo by deleting `dev/run/` and starting over.

## Run simulated nodes

```sh
dev/run-node-cycle.sh <hostname> <ip> <group>
# e.g.
dev/run-node-cycle.sh dev-node-a 10.99.1.11 site-a
dev/run-node-cycle.sh dev-node-b 10.99.1.12 site-a
```

This runs the **real** `register.sh` then `test-cycle.sh` against the
local hub — not a simulation of them. Identity comes from a `hostname`
shim (`DEV_HOSTNAME`), so one workstation plays many nodes.

- `--loop` runs a cycle every 60s until Ctrl-C — useful to leave a mesh
  live in a side terminal while iterating.
- `-h` lists the rest of the flags: group, `ENABLE_SMB`/`ENABLE_SMTP`/
  `ENABLE_IPERF`, `DNS_SERVER`.
- `DEV_FAIL_HOSTS=<comma-separated IP substrings>` (export before calling)
  makes the ssh/ping/fping shims report failure against matching targets —
  the way to put a deliberately broken path into the demo mesh (red cells,
  a failure-triggered traceroute, a losing loss/jitter row).

External binaries the scripts shell out to (`ping`, `ssh`, `traceroute`,
`dig`, `iperf3`, `smbclient`, `fping`, `nc`, `ip`) are shimmed under
`dev/shims/`; `curl` and `jq` are the real thing.

**Known limitation, not a bug: HTTP always reads FAIL here.** `curl` hits a
real socket and nothing listens on these fictional dev IPs. Every other
test type (SSH, PMTU, loss, traceroute, SMB, SMTP, iperf3, DNS) is
genuinely exercised through the real script logic and reads correctly.

## Look at it

- `http://127.0.0.1:8099/` — dashboard
- `http://127.0.0.1:8099/syslog` — syslog viewer

## Which command for which change

- **Changed the hub API, schema, or dashboard** (`hub/`) → `dev/hub-start.sh`,
  then `dev/run-node-cycle.sh` a couple of nodes to get real data on screen.
- **Changed `register.sh` or `test-cycle.sh`** → `dev/run-node-cycle.sh` is
  the point: it runs the actual script, so a syntax slip or a wire-contract
  break shows up exactly as it would on a real node.

## What this is not

This toolkit is for driving things interactively while coding — it is
**not** a substitute for the `regression-tester`, `hub-api-developer`, or
`drift-checker` agents before handing off a change. Use those to verify;
use this to see it work.
