# Lab Tester — Network End-to-End Connectivity Testing

## Project Overview
A lightweight system for testing end-to-end connectivity between hosts —
"nodes" — on a network. Goes beyond ICMP — validates real TCP connections
(HTTP, SSH, SMB, SMTP, iperf3), packet loss/jitter, path MTU, DNS resolution
and traceroute, and visualizes results on a web dashboard. The hub also
optionally receives syslog from network devices on the path, so a failure in
the matrix can be read next to what those devices logged at the same moment.

The scope of this project is the Hub and the Node only. Router/switch design,
configuration, and deployment belong to a separate project — this system
treats the network between nodes as an opaque path it tests, not something it
configures.

## Architecture

Diagram: `docs/TOPOLOGY.md`.

### Hub VM (standalone)
- Alpine Linux VM, ~192 MB RAM
- NOT a test participant — purely infrastructure
- Sits on a segment routable from all node subnets and the workstation
- Static IP (helper: `set-static-ip <ip/cidr> <gateway>`)
- Runs:
  - Flask API (registry + result collector) served by **waitress**, not the
    Flask dev server (which is single-threaded and would queue the mesh's
    simultaneous pushes)
  - SQLite database (WAL mode) at `/var/lib/lab-tester/hub.db`
  - Web dashboard on **port 80**
  - UDP syslog receiver on **port 514**, in a daemon thread (see Syslog below)
- Installed to `/opt/lab-tester-hub/`, started by OpenRC service `lab-tester-hub`
- Entrypoint is `serve.py` — it reads `HUB_PORT` at runtime. Do not move the
  port into the init script's `command_args`: OpenRC expands that at parse
  time, before `start_pre` sources `hub.env`, so the setting would be ignored.
- API endpoints:
  - `POST /register` — hostname, ip, subnet, group_name
  - `GET /endpoints` — mesh list (prunes stale endpoints as a side effect)
  - `POST /results` — result batch (runs the retention sweep as a side effect)
  - `GET /api/results?minutes=N`, `GET /api/results/<source>/<target>`
  - `DELETE /endpoints/<hostname>`
  - `GET|POST /targets`, `DELETE /targets/<name>` — static targets
  - `GET /agent/manifest`, `GET /agent/<script>` — agent distribution
  - `GET /api/syslog` — stored messages; `minutes=N` (default 60) *or*
    `from=&to=` for a pinned window, plus `host=`, `severity=N`, `q=`,
    `limit=N` (capped at 2000)
  - `GET /api/syslog/sources` — distinct senders with counts, for the filter
  - `GET /syslog` — syslog viewer page
  - `GET /api/time` — hub clock plus chrony tracking state, for the syslog
    header. Always 200: every failure (no chronyc, daemon down, timeout,
    unparseable output) returns `chrony: null` with a `reason`
  - `GET /api/health` — hub self-health for the dashboard's "Hub Health"
    panel: OpenRC service status (`HUB_HEALTH_SERVICES`, default
    `lab-tester-hub,chronyd,dropbear,open-vm-tools,lldpd`), syslog listener state,
    load average, memory, disk, uptime. Same never-500 discipline as
    `/api/time` — a check that can't run (e.g. `rc-service` missing) reports
    `null`/a reason rather than failing the page

### Test types
`http`, `ssh`, `traceroute`, `pmtu`, `dns`, `iperf3`, `smb`, `loss`, `smtp`.
The dashboard labels them H / S / T / M / D / I / B / L / E. `dns` only runs
when `DNS_SERVER` is set; `iperf3` only when `ENABLE_IPERF=true`; `smb` only
when `ENABLE_SMB=true`; `smtp`'s mesh side only when `ENABLE_SMTP=true` (its
static-target arm runs ungated — see below). `loss` is full mesh and always
on, like http/ssh/pmtu — no gate.

`loss` (fping-based packet loss/jitter) is fine-grained-timed like `http`,
**not** coarse like the `date +%s`-timed tests — it is deliberately excluded
from the dashboard's `COARSE_TIMING` map. Its `success` is `true` whenever
at least one probe got a reply (loss < 100%); the loss percentage itself is
data carried in `output`, not a pass/fail gate — some loss is the normal,
real signal this test exists to surface, and treating any nonzero loss as a
hard failure would defeat that (same philosophy `pmtu` already uses for a
partial/bracketed result).

`smtp` catches what `smb` can't: a device that **passes** traffic while
**rewriting** it. An SMTP ALG / ESMTP inspection engine — common on
firewalls and NAT gateways — masks unrecognised capability verbs (e.g.
`STARTTLS`) with runs of `X`, so `250-XXXXXXXX` in the recorded `output`
means an inspection engine is editing the session in flight, not blocking
it. The probe never issues `DATA` — it holds a real envelope conversation
(`EHLO` → `MAIL FROM:<>` → `RCPT TO:<probe@lab.invalid>` → `RSET` → `QUIT`)
and aborts before any message exists. `success` gates on the banner + `EHLO`
response only, never on `RCPT`: a real relay correctly rejects
`RCPT TO:<probe@lab.invalid>` with `550`, and that must not paint a healthy
relay red — the response codes are data in `output`, same philosophy as
`loss`/`pmtu`. The static-target arm is deliberately **ungated** (unlike
`smb`'s): registering a target is already an explicit opt-in, and the client
side cannot send mail regardless of `ENABLE_SMTP`, so requiring a local mail
daemon just to probe a real external relay would be pure friction. See
constraint 21 for why this can never become an open relay.

`smb` is SMB-shaped rather than ICMP-shaped on purpose: it is the protocol
most likely to be broken by an inspection policy, an MSS/MTU problem
mid-transfer, or a NAT path that passes short flows but not a sustained one.
Every node runs `smbd` exporting one read-only share and pulls a fixed probe
file from every peer with `smbclient`. Full mesh, like the other tests — not
client-only against static targets.

`pmtu` catches what nothing else here does: it sends with DF set at a real
payload size, which is the only test here that catches a path where peering
is up and small packets pass but large transfers hang. On failure it steps
down through common sizes to bracket where the path breaks.

### Static targets
Addresses that run no agent — gateways, device loopbacks, outside hosts —
held on the hub in the `targets` table and merged into every node's cycle.
Each declares which tests apply, since a loopback answers traceroute and
PMTU but has no HTTP server. Configured once on the hub rather than per
node.

### Syslog
The hub can optionally receive Cisco/RFC3164-style syslog over UDP/514 from
network devices on the path between nodes, and stores it in the `syslog`
table of the same SQLite database, so a failing pair in the matrix can be
read next to what those devices said in that minute. Correlation is the
whole reason it exists; without it the matrix tells you *that* a path broke
and nothing about why. Nothing here requires it — a lab with no devices
configured to log to the hub simply has an empty `/syslog`.

- Receiver is `hub/app/syslog_server.py`, started by `serve.py` in a daemon
  thread. `start()` is idempotent and returns quietly if it cannot bind — the
  hub must keep serving results even with no syslog.
- **Binding 514 needs root.** The OpenRC service runs as root, so this is only
  a constraint for a manual `run.sh` or a test run; set `HUB_SYSLOG_PORT` above
  1024 for those.
- Parsing is best-effort and **never** discards. An unrecognised line is stored
  with its raw text and a null host/severity, because the line you cannot parse
  is often the one you most need to see. The parser recognises the Cisco-style
  origin-id and `%FAC-SEV-MNEMONIC` framing many network vendors emit, but
  falls back to storing the raw line unparsed for anything else.
- Severity comes from the PRI header when present, else from the mnemonic's
  middle digit. `severity=N` filters *at or worse than* N (lower is more
  severe), matching how the filter reads on most network devices. Rows with a
  **null severity are always kept**, whatever the filter: the parser is
  written never to discard a line it cannot read, and filtering it away at
  query time would undo that at the only point where anyone would notice.
- Bounded by a **row cap** (`HUB_SYSLOG_MAX_ROWS`, default 300000), enforced
  every 500 inserts by an indexed delete on `id`. Not a time window: a device
  at debug level outpaces any retention period, so rows are what must be
  bounded.
- **Not an audit trail.** UDP is lossy and unauthenticated — anything on the
  segment can inject. It is a troubleshooting aid, and stored rows are data to
  be rendered, never trusted or interpreted.
- The listener's connection runs `synchronous=NORMAL`; the Flask side keeps
  the default. One commit per datagram at `FULL` means an fsync before the
  next `recvfrom` on a single-threaded drain, which measured ~500 msg/s — well
  inside what a device at debug level produces, so the listener became the
  bottleneck rather than the network. `NORMAL` is safe under WAL (a crash can
  lose the last transactions, not corrupt the file), and losing the tail of a
  troubleshooting log to a hub crash is an acceptable trade that losing
  *results* would not be.
- A `word:` prefix is only read as an origin-id when a Cisco-style timestamp
  or a `%MNEMONIC` follows it. Otherwise `kernel: out of memory` files itself
  under host `kernel`, which then appears as its own device in the source
  filter and hides real messages behind a name nobody recognises.

**Correlation from the dashboard.** The drill-down carries the moment across:
each test card links to `/syslog` pinned to ±5 min around *that sample*, and
the pair header links to the same window plus one link per group behind the
pair. Group links filter on `host`, which is the name the device puts in its
own messages — **not** `guestinfo.lab.group`. Where those differ the filtered
link comes back empty while the unfiltered window beside it still works, which
is the intended failure: an empty view rather than a wrong one. The hub does
not maintain an IP→device map.

**The clock is shown because the pinning depends on it.** `/api/time` reports
chrony's tracking state in the syslog header. A ±5 min window around a
`received_at` is only meaningful if the hub's clock is disciplined, so an
undisciplined one is surfaced rather than left to silently misalign every
correlation.

Config: `HUB_SYSLOG_ENABLED`, `HUB_SYSLOG_BIND`, `HUB_SYSLOG_PORT`,
`HUB_SYSLOG_MAX_ROWS`, `HUB_BUSY_TIMEOUT_MS`.

### Agent self-update
The hub serves `test-cycle.sh` and `register.sh` from
`/opt/lab-tester-hub/agent/`; nodes converge on their 5-minute registration run.
Checksums are computed on demand, so editing a file there is the whole
deploy — no rebuild step. Three gates before anything is trusted: sha256
match, `sh -n`, and (for test-cycle.sh) a successful real run. The prior
version is kept as `.known-good` and restored if that run fails. Opt a node out
with `AGENT_AUTOUPDATE=false`.

### Node (one per network segment under test)
- Alpine Linux VM, ~128 MB RAM, DHCP on its interface
- Installed to `/usr/local/bin/lab-tester/`, config at `/etc/lab-tester/config`
- Servers: dropbear (SSH), busybox httpd via OpenRC service **`lab-httpd`**,
  iperf3, `smbd` via OpenRC service **`lab-smbd`** (opt-in, `ENABLE_SMB`),
  `smtpd` (OpenSMTPD) via OpenRC service **`lab-smtpd`** (opt-in, `ENABLE_SMTP`)
- Clients: curl, ssh, traceroute, iperf3, smbclient, fping, `nc` (hand-rolled
  SMTP conversation — see below) — driven by cron every 60s
- Cloned from a single golden template

### Discovery
- Hub is the registry — single source of truth
- Hub URL comes from guestinfo / config; nodes register on boot and every 5 min
- Nodes pull the endpoint list before each cycle
- Endpoints unseen for `HUB_STALE_ENDPOINT_HOURS` (default 6) are dropped

## Infrastructure
- ESXi 7.0 + vCenter, `open-vm-tools` on both roles
- Two separate golden templates, each built by its own `build-template.sh`
- Default credentials: **root / lab123** (isolated lab only) — override with
  `LAB_ROOT_PASSWORD` when running either `build-template.sh`
- `chrony` on all VMs — the hub's clock is the mesh reference
- `lldpd` on both roles, always-on, not gated by any `ENABLE_*` flag — LLDP
  neighbor discovery for troubleshooting (e.g. `lldpcli show neighbors` to
  confirm which switch/port a node actually landed on). Not a test
  participant: it has no result type and never appears in the matrix.

## Per-VM configuration: guestinfo
vCenter does not expose the VM display name to the guest. Instead, custom
keys set on the VM are read in-guest via `vmware-rpctool "info-get <key>"`:

| Key | Example |
|-----|---------|
| `guestinfo.lab.hub_url` | `http://10.0.0.100` |
| `guestinfo.lab.group` | `site-a` |
| `guestinfo.lab.subnet` | `10.1.1.0/24` |
| `guestinfo.lab.hostname` | `test-site-a` (optional) |
| `guestinfo.lab.dns_server` | `10.0.0.53` (optional; unset skips the DNS test) |
| `guestinfo.lab.dns_query` | `example.com` (optional) |

Precedence in `setup.sh`: **guestinfo → environment → prompt**.
If hostname is omitted it is derived as `<HOSTNAME_PREFIX>-<group-slug>`.
`group` is an arbitrary operator-chosen label — it clusters nodes on the
dashboard and filters syslog by sender; it carries no network-topology
meaning to the hub.

The table above is read by the nodes. The **hub** has its own, smaller
set, read by `lab-tester-hub-firstboot` (`hub/services/firstboot.initd`) and
set on the hub's own VM object, not the nodes':

| Key | Example |
|-----|---------|
| `guestinfo.hub.ip` | `10.0.0.100/24` |
| `guestinfo.hub.gateway` | `10.0.0.1` |

Both optional — with neither present, the firstboot service stands down
(same reasoning as the nodes: no reliable tty inside an OpenRC `start()`
to prompt from) and `hub-setup.sh` prompts interactively at first login
instead (`hub/scripts/hub-setup.sh`, invited by `hub/services/login-setup.sh`).

## Project Structure
```
hub/
  build-template.sh   — builds the hub golden template
  serve.py            — production entrypoint (reads HUB_PORT at runtime)
  run.sh              — foreground launcher for debugging
  app/                — Flask API (app.py, config.py, syslog_server.py)
  templates/          — dashboard.html, syslog.html
  static/
  agent/              — scripts served to nodes (created at build time)
  services/           — firstboot.initd, login-setup.sh
  scripts/            — hub-setup.sh
node/
  build-template.sh   — builds the node golden template
  scripts/            — register.sh, test-cycle.sh, setup.sh
  services/           — httpd.initd (lab-httpd), iperf3.initd,
                        smbd.initd (lab-smbd), smb.conf,
                        smtpd.initd (lab-smtpd), smtpd.conf, crontab,
                        lab-tester-httpd.conf, logrotate.conf,
                        firstboot.initd (lab-tester-firstboot)
  config.sample
docs/BUILD_GUIDE.md
```

## Design Decisions
- Pull-based/cron: each node tests independently and pushes results
- Hub is standalone: collects and displays, never participates
- Shared registry over HTTP: no NFS, exercises the same stack being tested
- Alpine Linux: ~128 MB RAM, fast boot, good package ecosystem
- **Keep code simplistic to avoid over-engineering.** Shell and Flask that a
  network engineer can read at 2am beats a clever abstraction. Prefer the
  plain approach until something concrete forces otherwise; the numbered
  constraints below are the exceptions that earned their complexity.

## Working style
- Keep output minimalistic and use simple English.
- Do not output large code snippets. Point at `file:line` and say what
  changed; the file itself is the record.
- Do not display code changes in output unless asked to.

## Non-obvious constraints — do not regress these
These were live bugs that a review caught; each has a comment at the site.

1. **Hostnames must be unique per clone.** `endpoints.hostname` is the PRIMARY
   KEY, so duplicate names make clones overwrite each other and the mesh
   collapses to one entry — which every node then skips as "self". `setup.sh`
   sets the hostname; the template ships as `lab-tester-template`.
2. **Timestamps: the hub stamps `received_at` and filters on that.** Nodes
   send ISO-8601 (`2026-09-09T08:00:00Z`); SQLite's `datetime('now', ...)`
   yields `2026-09-09 18:04:04`. String-comparing them is wrong because `T`
   (0x54) sorts above space (0x20), so any same-day row passes any window.
   `received_at` is stored in SQLite's format; `iso()` converts on the way out
   so browsers parse it as UTC rather than local time.
3. **The SSH test needs the shared keypair.** It runs `BatchMode=yes` (key auth
   only). `/etc/lab-tester/id_lab` is generated at build time and trusted in
   root's `authorized_keys`, so it must survive cloning — the cleanup step
   deletes dropbear *host* keys but deliberately keeps this one.
4. **`setup.sh` must not copy scripts onto themselves.** Source and destination
   both resolve to `/usr/local/bin/lab-tester/` when run in place; `cp` exits 1
   and `set -e` aborts the script. It compares the paths first.
5. **The web server is an OpenRC service (`lab-httpd`).** Launching busybox
   httpd by hand does not survive a reboot, which silently breaks every HTTP
   test in the mesh.
6. **`test-cycle.sh` takes a lock.** Traceroutes can outrun the 60s cron
   interval; overlapping cycles skew every reported timing.
7. **iperf3 serves one client at a time.** Contention is retried once, then
   reported as skipped rather than failed — and a skipped run emits no JSON,
   so the caller must not append it blindly (trailing comma → invalid JSON).
8. **Retention is not optional.** ~100k result rows/day at 5 nodes. The sweep
   runs opportunistically on each `POST /results`; there is no cron on the hub.
9. **Never build `latency_ms` with `printf '%d000'`.** A sub-second test then
   emits `0000`, and JSON forbids leading zeros in numbers. `jq` accepts it
   but Python's parser does not, so the hub rejects the *entire* batch with a
   400 — and on a healthy lab SSH is always sub-second, so nothing would ever
   be recorded. Use arithmetic: `$(( _elapsed * 1000 ))`.
10. **Traceroute is rationed, deliberately.** `-q 1` with `-m 10`, run on
   `TRACEROUTE_INTERVAL` (default 300s) and on demand when HTTP or SSH to a
   target has just failed. At the old settings (3 probes, 15 hops, 2s wait) a
   black-holed path cost 90s per target and, tested serially, overran the 60s
   cycle — the tool slowed down exactly when the lab broke.
11. **`register.sh` must not `exit 0` on successful registration.** Self-update
   and the identity-page refresh run after it; an early exit silently skips
   both.
12. **`setup.sh` merges into root's crontab, never replaces it.** `crontab
   FILE` overwrites wholesale, and Alpine's crontab carries the run-parts
   entries that drive `/etc/periodic/*` — including the daily logrotate run.
   Replacing it left log rotation installed but never triggered, so the disk
   still filled. It now strips any prior lab-tester block, appends, and
   reports how many periodic entries survived.
13. **Only `test-cycle.sh` auto-updates.** register.sh is the updater; a copy
   of it that parses but fails at runtime would stop registration *and*
   disable the mechanism that would repair it, bricking every node at once.
   There is also no non-circular way to verify it. Push register.sh changes
   deliberately.
14. **Package selection on Alpine is load-bearing** (verified against the
   Alpine package index, not assumed):
   - `iputils-ping`, not `iputils`. The ping binary lives in the subpackage;
     the metapackage also drags in arping, clockdiff and tracepath. It
     installs to `/bin/ping`, the *same path* BusyBox uses, so this is a
     package replacement rather than a PATH-ordering question. The PMTU
     probe needs its `-M do`, which BusyBox ping does not implement —
     `build-template.sh` checks this at build time and warns.
   - `openssh-client` is a virtual provided by `openssh-client-default`,
     which installs `/usr/bin/ssh` and already depends on `openssh-keygen`
     (so that needs no separate entry). `test-cycle.sh` passes `-o` flags
     that dropbear's `dbclient` rejects, so OpenSSH is required.
   - Never add the `dropbear-ssh` subpackage. It installs its own
     `/usr/bin/ssh` symlink to `dbclient` and collides with
     `openssh-client-default` at that path. Plain `dropbear` is the server
     only and does not pull it in.
   - `samba-server` and `samba-client`, not the `samba` metapackage. The
     metapackage drags in winbind and the AD domain-controller machinery;
     `samba-server` depends on neither (`samba-dc` depends on it, not the
     reverse). Same failure mode as `iputils` above, in a new package.
   - `opensmtpd`, never the `opensmtpd-openrc` subpackage. That subpackage's
     service name is bare `smtpd` — as generic and collision-prone as
     `httpd` was — and would let an operator `rc-update add smtpd` by
     accident, bypassing `ENABLE_SMTP` and every safety guard in our own
     `smtpd.conf`. We ship our own `lab-smtpd` initd instead. `opensmtpd`
     also claims `/usr/sbin/sendmail`/`mailq`/`newaliases`; harmless alone,
     but a hard collision if `postfix`/`ssmtp`/`msmtp` are ever added later.
15. **Agent definitions use `tools:` as a comma-separated string**, not a
   YAML array — `tools: Read, Grep, Bash`. Per the Claude Code subagent
   docs; only `name` and `description` are required. Project-level
   `.claude/agents/` overrides `~/.claude/agents/` on a name collision.
16. **The first-boot service stands down without guestinfo.** `setup.sh`
   prompts interactively, so auto-running it with no keys present would block
   the boot forever waiting on input. It checks for `lab.hub_url` and
   `lab.group` first and redirects to `/dev/null`.
17. **The syslog listener is a second writer, so `busy_timeout` is required.**
   It writes to the same SQLite file as the results API from its own thread.
   WAL permits one writer at a time; without a busy timeout on *both*
   connections, a message burst makes a concurrent `POST /results` fail
   outright with "database is locked" — the mesh losing results exactly when
   the lab is noisy enough to be worth watching. Set via
   `HUB_BUSY_TIMEOUT_MS` (default 5000) in `config.py`, applied in
   `get_db()` and in the listener's own connection.
18. **Syslog timestamps are stored in SQLite's format, like everything else.**
   `syslog_server.insert()` must match `app.sqlite_now()`
   (`YYYY-MM-DD HH:MM:SS`), not ISO-8601. It originally wrote the ISO form,
   which is constraint 2 in a new place: `datetime('now', ...)` window queries
   would compare `T` (0x54) against space (0x20) and let any same-day row pass
   any window. `iso()` converts on the way out, as it does for results.
19. **A missing key and an explicit `null` are not the same thing.**
   `r.get("target_ip", "")` returns the default only when the key is *absent*;
   `{"target_ip": null}` yields `None`, which violates the column's `NOT NULL`
   and raises `IntegrityError`. The commit never runs, so **every other row in
   that batch is discarded too** and the node gets a 500 naming none of them —
   constraint 9's whole-batch loss arriving by a different route. `push_results`
   coerces with an explicit None check, not a `.get` default, and rejects a
   non-object body or record with a 400 rather than an AttributeError 500.
20. **The syslog listener must NOT set `allow_reuse_address`.** `SO_REUSEADDR`
   on a UDP socket does not reliably reject a duplicate bind on Linux: two
   sockets that both set it can hold the same port, and the kernel then hands
   each datagram to only one of them. Running `run.sh` while the service is up
   would split incoming device messages between two processes writing to two
   databases — a log with silent holes, which is worse than a listener that
   refuses to start. Leaving it off makes the second bind fail with
   `EADDRINUSE`, which is what `start()` is written to expect.
21. **The SMTP probe server must never be able to send mail.** No `relay`
   action anywhere in `smtpd.conf`, no `match ... for any` — these are
   structural guarantees the daemon has no configured path off the host, not
   policy settings. The Alpine package's default config *does* ship a relay
   action, so the `cp -f` that installs our own config in
   `build-template.sh` is load-bearing; a build-time `grep` for a `relay`
   action is the safety net if that copy ever silently fails. This isn't
   theoretical: a node may sit behind NAT with a real default route to the
   internet, so "it's an isolated lab" is not a valid defence for this one.
   The probe client never issues `DATA` either, so even a real external
   relay registered as a static target can't have mail sent through it.
