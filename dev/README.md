# Dev/demo toolkit

Runs a real hub plus a small simulated mesh, entirely on the workstation —
for hub/dashboard work and for exercising node-script changes without a
vCenter lab. Everything here is dev tooling, not something that ships to a
VM; see `CLAUDE.md` for the actual project.

## 1. Start the hub

```sh
dev/hub-start.sh          # http://127.0.0.1:8099, backgrounded, pidfile
dev/hub-stop.sh
```

Populates `hub/agent/` from `node/scripts/{register,test-cycle}.sh` (gitignored,
build-time-only in production — this just mirrors what `build-template.sh`
does) and runs `hub/serve.py` with `HUB_DB_PATH`/`HUB_PORT`/`HUB_SYSLOG_PORT`
pointed at `dev/run/`. Override any of those env vars before calling it.
Log and db land in `dev/run/`, gitignored.

`test-status.sh` is deliberately **not** copied into `hub/agent/` — it isn't
in the hub's `AGENT_SCRIPTS` manifest and never self-updates (see CLAUDE.md,
"Agent self-update").

## 2. Run simulated nodes — the real scripts, unmodified logic

```sh
dev/run-node-cycle.sh dev-node-a 10.99.1.11 site-a
dev/run-node-cycle.sh dev-node-b 10.99.1.12 site-a
dev/run-node-cycle.sh dev-node-c 10.99.1.13 site-b
```

Each call runs the actual `register.sh` then `test-cycle.sh` against the
local hub, so this is the tool to reach for when you've changed either
script and want to see it work end to end — including the console table,
`/run/lab-tester/last-cycle.txt`-equivalent snapshot, and `test-status.sh`,
all exercised for real.

One workstation plays many nodes: identity comes from a `hostname` shim
(`dev/shims/hostname`, driven by `DEV_HOSTNAME`), the same thing real
node scripts call — nothing about the scripts themselves changes.

Two edits, and only two, are made to scratch copies before running (same
precedent the `regression-tester` agent uses for its own live-hub runs):
`CONFIG` in both scripts, and — `test-cycle.sh` only — `LOCK_DIR` and
`TRACEROUTE_STAMP`. All three are OS-root paths (`/etc/lab-tester/...`,
`/run/...`) that don't exist off a real Alpine node. `SNAPSHOT_FILE` needs no
edit — it already honors an env override, which this also happens to prove.

`--loop` keeps a node running a cycle every 60s (Ctrl-C to stop) instead of
once — useful for leaving a mesh live in a side terminal during a coding
session. `-h` for the rest of the flags (group, `ENABLE_SMB`/`ENABLE_SMTP`/
`ENABLE_IPERF`/`DNS_SERVER`, `DEV_FAIL_HOSTS`).

### What's real vs. what's shimmed

`dev/shims/` stands in for `ping`, `ssh`, `traceroute`, `dig`, `iperf3`,
`smbclient`, `fping`, `nc` and `ip` — every external binary these scripts
shell out to, matching exactly the call shape each script actually uses (see
each shim's own header comment). `curl` and `jq` are the real thing.

**HTTP is the one test type that reads FAIL here, always.** `run_http_test`
talks to a real socket via `curl` — there's no PATH trick for that — and
nothing is listening on any of these fictional IPs. This is a known,
accepted limitation, not a bug: every other test type (SSH, PMTU, loss,
traceroute, SMB, SMTP, iperf3, DNS) is genuinely exercised through the real
script logic and reads OK.

`DEV_FAIL_HOSTS` (comma-separated IP substrings, exported before calling
`run-node-cycle.sh`) makes the ssh/ping/fping shims report failure for a
matching target — the one knob for putting a deliberately broken path (red
cells, a failure-triggered traceroute, a losing loss/jitter row) into the
demo mesh:

```sh
DEV_FAIL_HOSTS=10.99.1.13 dev/run-node-cycle.sh dev-node-a 10.99.1.11 site-a
```

## 3. Look at it

`http://127.0.0.1:8099/` — dashboard. `http://127.0.0.1:8099/syslog` — syslog
viewer (send it a message per the main README's local-hub section). Reset by
deleting `dev/run/` and starting over.

## When to use which

- **Changed the hub API, schema, or dashboard?** `dev/hub-start.sh`, then
  `dev/run-node-cycle.sh` a couple of nodes to get real data on screen.
- **Changed `register.sh` or `test-cycle.sh`?** `dev/run-node-cycle.sh` is
  the point — it's the real script, so a syntax slip or a wire-contract
  break shows up exactly as it would on a real node.
- **Verifying a change before handing it off?** Still use the
  `regression-tester` / `hub-api-developer` / `drift-checker` agents — this
  toolkit is for driving things interactively while coding, not a
  replacement for that gate.
