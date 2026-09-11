---
name: lab-tester-test-vm
description: Alpine test-VM conventions for lab-tester — POSIX sh constraints, /etc/lab-tester/config, register.sh and test-cycle.sh structure, cron cadence, and golden-image/clone deployment. Read before editing anything under test-vm/ or changing what a cloned VM does on boot.
origin: lab-tester
---

# Lab-Tester Test VM

Test VMs are ~128 MB Alpine clones from one golden image. They get an IP by DHCP, register with the hub, and run a test cycle from cron. There is no orchestration — each VM is independent and stateless apart from `/etc/lab-tester/config`.

## When to Activate

- Editing `test-vm/scripts/*.sh`, `test-vm/services/*`, or `config.sample`
- Adding a new test type to the cycle
- Changing the boot/registration behaviour or cron cadence
- Writing golden-image or clone-deployment steps

## Hard Constraints

- **BusyBox ash, not bash.** `#!/bin/sh` with `set -u`. No arrays, no `[[ ]]`, no `local`, no process substitution, no `${var,,}`. Prefix function-local variables with `_` (existing convention) since everything is global.
- **Every dependency must be in the golden image.** The authoritative list is the `apk add` block in `test-vm/build-template.sh`. Adding a tool means rebuilding the image, not `apk add` on a clone.
- **`ssh` is OpenSSH, not dropbear.** `test-cycle.sh` passes `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`, which `dbclient` rejects. dropbear is the *server* only; never add the `dropbear-ssh` subpackage, which would install its own `/usr/bin/ssh` symlink and collide with `openssh-client-default`. Likewise `ping` must be `iputils-ping`, whose `-M do` the PMTU probe needs and BusyBox ping does not implement.
- **Small RAM.** Avoid holding large outputs in variables beyond one endpoint's results; traceroute output is the largest thing carried.
- **DHCP means the IP changes.** Nothing may cache a peer IP across cycles — always pull `/endpoints` fresh.
- **No bitwise awk builtins.** BusyBox awk may lack `and()`/`compl()`, so any address maths must use plain arithmetic (`int(addr / block) * block`) rather than bit operations.

## Config

`/etc/lab-tester/config` (from `test-vm/config.sample`), sourced by both scripts: `HUB_URL` (no trailing slash), `ROUTER_NAME` and `SUBNET` — all three required — plus optional `ENABLE_IPERF`, `TRACEROUTE_INTERVAL`, `TRACEROUTE_MAX_HOPS`, `PMTU_SIZE`, `DNS_SERVER`, `DNS_QUERY`, `AGENT_AUTOUPDATE`.

**`register.sh` requires all three of `HUB_URL`, `ROUTER_NAME` and `SUBNET`**, and `exit 1`s on the first one that is empty. Nothing is derived and nothing is defaulted. Per-clone values are therefore: hostname, `ROUTER_NAME`, `SUBNET` — normally supplied through guestinfo rather than edited by hand.

Be conservative about adding a fourth. Each required variable is another way for a clone to fail silently: an unregistered VM is invisible in the matrix rather than visibly broken, so the failure looks like a VM that was never built. Deriving or defaulting a value beats validating it — that argument is why reducing this set to `HUB_URL` alone was once planned. It was never implemented, so do not write code that assumes it.

## Script Structure

`register.sh` — boot + every 5 min. Detects hostname and the first global IPv4 (`ip -4 -o addr show scope global`), POSTs `/register`, retries 3× with 5 s backoff. Re-registration is what makes DHCP renewals invisible to the rest of the system; don't lengthen the interval past the lease's usable window.

`test-cycle.sh` — every minute. Pulls `/endpoints`, validates JSON with `jq empty`, skips self by hostname, then per peer runs HTTP → SSH → PMTU, with traceroute only on `TRACEROUTE_INTERVAL` or right after an HTTP/SSH failure, and iperf3 when `ENABLE_IPERF=true`. Static targets from `/targets` run whichever tests each one declares. DNS runs once per cycle against `DNS_SERVER`, not per target — it is a per-source test, which is why the dashboard renders it in its own panel rather than as a matrix column. All results POST in one payload.

Each test function returns one JSON object and is isolated with `|| true` so a failure never aborts the cycle. Build JSON with `printf`, and escape any free text through `json_escape()` (`jq -Rs '.'`) — raw command output contains quotes and newlines that will corrupt the payload otherwise.

Timeouts are deliberately short so a full cycle fits inside 60 s — read the actual values off `test-cycle.sh`, which owns them. What matters when you add a test is the budgeting rule: worst case × number of endpoints against the cron interval. A cycle that overruns overlaps with the next one and skews every timing it reports, which is why traceroute is rationed rather than run per cycle.

## Adding a Test Type

1. Write `run_<type>_test()` returning the standard result JSON (`test_type` lowercase, `success` as bare `true`/`false`, `latency_ms` numeric or `null`).
2. Call it in the endpoint loop, append to `RESULTS`.
3. Gate anything expensive behind a config flag, like `ENABLE_IPERF`.
4. If it needs a listening service, add it to the image and to `test-vm/services/`.

## Time

`build-template.sh` installs chrony and enables `chronyd`, but **nothing points
a test VM at the hub**: `setup.sh` contains no chrony configuration at all, so
VMs run against Alpine's default pool. In an isolated lab that pool is
unreachable and the VM drifts.

That is tolerable today only because VM clocks are not load-bearing: the hub
stamps `received_at` itself and filters on that, so a drifting VM skews the
`timestamp` it reports but cannot hide its own results. The hub's clock is the
one that matters — see `/api/time` and the `/syslog` header.

Pointing VMs at the hub is designed and unimplemented (`HANDOFF.md`). If you
build it, it belongs in `setup.sh` beside the other config writes, and the hub
needs an access list before it will answer.

## Services

Servers on each VM: dropbear (SSH), busybox httpd (`lab-tester-httpd.conf`), iperf3 (`iperf3.initd`). They exist so *other* VMs can test *this* one — a VM that fails only inbound tests usually has a service down, not a routing problem.

## Cron

`test-vm/services/crontab`: register every 5 min, test cycle every minute, both logging to `/var/log/lab-tester/`. Cron granularity is one minute — `TEST_INTERVAL` below 60 does nothing. Ensure `/var/log/lab-tester/` exists in the image and that logs rotate or truncate; a full disk on a 2 GB image is a silent failure mode.

## Cloning

Golden image → clone → boot → edit hostname/`ROUTER_NAME`/`SUBNET` → restart or run `register.sh`. Hostname uniqueness is mandatory: the hub keys `endpoints` on hostname, so two clones sharing one overwrite each other. Clear machine-id/SSH host keys in the image prep step, not after cloning.

## Anti-Patterns

```
# BAD: bash-isms in test-vm scripts — they run under BusyBox ash and fail at boot with no console watcher

# BAD: embedding command output in JSON without json_escape

# BAD: caching the endpoint list between cycles — DHCP moves peers

# BAD: forgetting to set a unique hostname on a clone — it hijacks another VM's registration

# BAD: unbounded timeouts — one dead peer stalls the whole cycle past its cron slot
```

## Related Skills

- lab-tester-hub-api
- lab-tester-troubleshooting
- cisco-ios-patterns
