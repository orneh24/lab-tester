---
name: lab-tester-node
description: Alpine node conventions for lab-tester — POSIX sh constraints, /etc/lab-tester/config, register.sh and test-cycle.sh structure, cron cadence, and golden-image/clone deployment. Read before editing anything under node/ or changing what a cloned node does on boot.
origin: lab-tester
---

# Lab-Tester Node

Nodes are ~128 MB Alpine clones from one golden image. They get an IP by DHCP, register with the hub, and run a test cycle from cron. There is no orchestration — each node is independent and stateless apart from `/etc/lab-tester/config`.

## When to Activate

- Editing `node/scripts/*.sh`, `node/services/*`, or `config.sample`
- Adding a new test type to the cycle
- Changing the boot/registration behaviour or cron cadence
- Writing golden-image or clone-deployment steps
- Changing the first-login setup prompt (`node-setup.sh`,
  `node/services/login-setup.sh`) or its `.setup-done` stamp

## Hard Constraints

- **BusyBox ash, not bash.** `#!/bin/sh` with `set -u`. No arrays, no `[[ ]]`, no `local`, no process substitution, no `${var,,}`. Prefix function-local variables with `_` (existing convention) since everything is global.
- **Every dependency must be in the golden image.** The authoritative list is the `apk add` block in `node/build-template.sh`. Adding a tool means rebuilding the image, not `apk add` on a clone.
- **`ssh` is OpenSSH, not dropbear.** `test-cycle.sh` passes `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`, which `dbclient` rejects. dropbear is the *server* only; never add the `dropbear-ssh` subpackage, which would install its own `/usr/bin/ssh` symlink and collide with `openssh-client-default`. Likewise `ping` must be `iputils-ping`, whose `-M do` the PMTU probe needs and BusyBox ping does not implement.
- **Small RAM.** Avoid holding large outputs in variables beyond one endpoint's results; traceroute output is the largest thing carried.
- **DHCP means the IP changes.** Nothing may cache a peer IP across cycles — always pull `/endpoints` fresh.
- **No bitwise awk builtins.** BusyBox awk may lack `and()`/`compl()`, so any address maths must use plain arithmetic (`int(addr / block) * block`) rather than bit operations.

## Config

`/etc/lab-tester/config` (from `node/config.sample`), sourced by both scripts: `HUB_URL` (no trailing slash), `GROUP_NAME` and `SUBNET` — plus optional `ENABLE_IPERF`, `ENABLE_SMB`, `ENABLE_SMTP`, `TRACEROUTE_INTERVAL`, `TRACEROUTE_MAX_HOPS`, `PMTU_SIZE`, `DNS_SERVER`, `DNS_QUERY`, `AGENT_AUTOUPDATE`.

**`register.sh` still requires all three of `HUB_URL`, `GROUP_NAME` and `SUBNET`** to be non-empty in the config file at cron time, and `exit 1`s on the first one that is empty. `SUBNET` is the one exception at the *operator-input* layer, though: `setup.sh`'s `derive_subnet()` computes it from the interface's current DHCP lease (address + prefix already give you the network — see the no-bitwise-awk note above) and only falls through to guestinfo/env/prompt if that fails. `HUB_URL` and `GROUP_NAME` are still not derived or defaulted from anything. Per-clone values are therefore: hostname, `GROUP_NAME` — `SUBNET` normally needs nothing at all now.

Be conservative about adding a required variable that isn't derivable the way `SUBNET` now is. Each one is another way for a clone to fail silently: an unregistered node is invisible in the matrix rather than visibly broken, so the failure looks like a node that was never built. Deriving or defaulting a value beats validating it.

## Script Structure

`register.sh` — boot + every 5 min. Detects hostname and the first global IPv4 (`ip -4 -o addr show scope global`), POSTs `/register`, retries 3× with 5 s backoff. Re-registration is what makes DHCP renewals invisible to the rest of the system; don't lengthen the interval past the lease's usable window.

`test-cycle.sh` — every minute. Pulls `/endpoints`, validates JSON with `jq empty`, skips self by hostname, then per peer runs HTTP → SSH → PMTU → loss (all four always on, no gate — loss is fping-based packet loss/jitter), with traceroute only on `TRACEROUTE_INTERVAL` or right after an HTTP/SSH failure, iperf3 when `ENABLE_IPERF=true`, smb (fetching `probe.bin` via `smbclient`) when `ENABLE_SMB=true` — no contention retry, since `smbd` forks per connection — and smtp (an `EHLO`/`MAIL`/`RCPT`/`RSET`/`QUIT` conversation via hand-rolled `nc`, never `DATA`) when `ENABLE_SMTP=true`. `loss`'s `success` is `true` on any reply at all; the loss percentage lives in `output`, not the success field — never treat nonzero loss as a failure, that's the signal this test exists to report. `smtp`'s `success` gates on the banner+EHLO only, never on RCPT (a real relay correctly rejects the probe's `RCPT TO:<probe@lab.invalid>` with 550) — capability tokens masked as runs of `X` in `output` mean an SMTP ALG / ESMTP inspection engine is rewriting the session, a finding, not a failure. Static targets from `/targets` run whichever tests each one declares — smtp's static-target arm is deliberately ungated, unlike smb's. DNS runs once per cycle against `DNS_SERVER`, not per target — it is a per-source test, which is why the dashboard renders it in its own panel rather than as a matrix column. All results POST in one payload.

Each test function returns one JSON object and is isolated with `|| true` so a failure never aborts the cycle. Build JSON with `printf`, and escape any free text through `json_escape()` (`jq -Rs '.'`) — raw command output contains quotes and newlines that will corrupt the payload otherwise.

`node-setup.sh` is a wizard *wrapper*, not a fourth script with its own config logic — it asks permission (`Configure this node now? [Y/n]`) and, on yes, calls `setup.sh` unmodified. All value collection stays in `setup.sh` because `firstboot.initd` calls only `setup.sh`; any collection logic added to the wizard instead would be invisible on the zero-touch guestinfo path. The wizard's own job is the stamp bookkeeping (`/etc/lab-tester/.setup-done`) and the `--force` discard-confirmation for an existing config — see `docs/BUILD_GUIDE.md` §6.5b for the full stamp/provenance contract.

Timeouts are deliberately short so a full cycle fits inside 60 s — read the actual values off `test-cycle.sh`, which owns them. What matters when you add a test is the budgeting rule: worst case × number of endpoints against the cron interval. A cycle that overruns overlaps with the next one and skews every timing it reports, which is why traceroute is rationed rather than run per cycle.

## Adding a Test Type

1. Write `run_<type>_test()` returning the standard result JSON (`test_type` lowercase, `success` as bare `true`/`false`, `latency_ms` numeric or `null`).
2. Call it in the endpoint loop, append to `RESULTS`.
3. Gate anything expensive behind a config flag, like `ENABLE_IPERF`.
4. If it needs a listening service, add it to the image and to `node/services/`.

## Time

`build-template.sh` installs chrony and enables `chronyd`, but **nothing points
a node at the hub**: `setup.sh` contains no chrony configuration at all, so
nodes run against Alpine's default pool. In an isolated lab that pool is
unreachable and the node drifts.

That is tolerable today only because node clocks are not load-bearing: the hub
stamps `received_at` itself and filters on that, so a drifting node skews the
`timestamp` it reports but cannot hide its own results. The hub's clock is the
one that matters — see `/api/time` and the `/syslog` header.

Pointing nodes at the hub is designed and unimplemented (`HANDOFF.md`). If you
build it, it belongs in `setup.sh` beside the other config writes, and the hub
needs an access list before it will answer.

## Services

Servers on each node: dropbear (SSH), busybox httpd (`lab-tester-httpd.conf`), iperf3 (`iperf3.initd`), smbd (`smbd.initd` → `lab-smbd`, opt-in via `ENABLE_SMB`), and smtpd (`smtpd.initd` → `lab-smtpd`, opt-in via `ENABLE_SMTP` — OpenSMTPD, never the `opensmtpd-openrc` package, whose bare `smtpd` service name would bypass our gate). They exist so *other* nodes can test *this* one — a node that fails only inbound tests usually has a service down, not a routing problem.

`lldpd` also runs on every node, always-on and not gated by any flag. It isn't part of the test harness — no result type, never in the matrix — it's there for `lldpcli show neighbors` when troubleshooting cabling or a wrong port-group assignment.

`node/services/login-setup.sh` is installed to `/etc/profile.d/lab-tester-node-setup.sh` — sourced at interactive login, not a service, not chmod +x. It invites `node-setup.sh` (symlinked onto PATH, same as `set-static-ip`/`hub-setup.sh` on the hub) behind a three-layer guard: interactive shell, real tty, `.setup-done` absent.

## Cron

`node/services/crontab`: register every 5 min, test cycle every minute, both logging to `/var/log/lab-tester/`. Cron granularity is one minute. Ensure `/var/log/lab-tester/` exists in the image and that logs rotate or truncate; a full disk on a 2 GB image is a silent failure mode.

## Cloning

Golden image → clone → boot. With `guestinfo.lab.hub_url`/`.group` set, `firstboot.initd` configures and registers with no console session. Without them, it stands down and `node-setup.sh` prompts at the first interactive login instead — decline it and edit `/etc/lab-tester/config` by hand, or run `setup.sh`/`node-setup.sh` yourself any time. Either way: edit hostname/`GROUP_NAME` (`SUBNET` normally derives itself from DHCP) → restart or run `register.sh`. Hostname uniqueness is mandatory: the hub keys `endpoints` on hostname, so two clones sharing one overwrite each other. Clear machine-id/SSH host keys, the config, and both stamps (`.firstboot-done`, `.setup-done`) in the image prep step, not after cloning.

## Anti-Patterns

```
# BAD: bash-isms in node scripts — they run under BusyBox ash and fail at boot with no console watcher

# BAD: embedding command output in JSON without json_escape

# BAD: caching the endpoint list between cycles — DHCP moves peers

# BAD: forgetting to set a unique hostname on a clone — it hijacks another node's registration

# BAD: unbounded timeouts — one dead peer stalls the whole cycle past its cron slot

# BAD: collecting a config value inside node-setup.sh instead of setup.sh — firstboot.initd never calls the wizard, so it would be invisible on the zero-touch path

# BAD: an unguarded `read` anywhere the login hook can reach — closed stdin under set -e aborts the whole script; use `read -r VAR || VAR=""`, or `if ! read` when a default would otherwise fire on EOF

# BAD: sealing a golden image with /etc/lab-tester/.setup-done present — every clone's login prompt stays silent forever, with no error to see
```

## Related Skills

- lab-tester-hub-api
- lab-tester-troubleshooting
