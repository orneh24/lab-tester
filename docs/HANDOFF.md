# Lab-Tester — Session Handoff

Last updated: 2026-09-14. Written so a fresh session on any surface (Claude Code
in the terminal, the desktop app, claude.ai) can pick up without the prior chat.
Architecture lives in `CLAUDE.md`, build order and the deployment checklist in
`docs/DEPLOYMENT.md`, step detail in `docs/BUILD_GUIDE.md`. This file is state
and intent only.

**Reminder/To-Do list — answered 2026-09-11:**
1. *How DNS tests work* — `test-cycle.sh:run_dns_test` (`dig +short`, `bind-tools`
   package), run against the configured resolver (`DNS_SERVER`, once per cycle)
   and/or against any static target whose `tests` list includes `dns`. Only
   runs when `DNS_SERVER` is set or a static target declares it — otherwise
   silently skipped, no red cell.
2. *Is DNS visible on the dashboard* — yes, its own panel (`#dns-section`),
   deliberately outside the pair matrix: `dns` is one test per source against
   a resolver, not a source→target pair, so `PAIR_TEST_TYPES` excludes it and
   it would only ever render as a permanently grey matrix column otherwise.
3. *Can hub/clients verify a valid NTP source* — hub: yes, `GET /api/time`
   parses `chronyc tracking` (stratum, offset, synced, `local_only` fallback)
   and never fails hard. It was rendered on `/syslog` only; **now also on the
   main dashboard** (see Recent changes below). Clients: no — chrony is
   installed on test VMs but nothing configures, checks, or reports their sync
   state. Still open; see Designed-but-NOT-implemented.
4. *ARP table on the dashboard* — recommended against. ARP only reflects a
   VM's own L2 segment; every tested pair crosses a router, so it would show
   one router MAC and nothing about the paths this tool exists to test. Not
   pursued.
5. *CSR config (networks, VLANs) on the dashboard* — recommended against. Would
   require the hub authenticating to every router (a trust relationship this
   design deliberately avoids — it tests *through* routers, never manages
   them) and a config parser that drifts against IOS versions. Belongs in a
   Netmiko/NAPALM tool against the CSRs directly, not this connectivity
   tester. Not pursued.

> **Read the "Designed but NOT implemented" section before trusting anything
> here.** An earlier revision of this file described a body of work as
> delivered that had never landed in the code — `/api/time`, the config file
> server, NTP service, per-interface network state. Someone following it would
> have run helpers that do not exist and verified behaviour that could not
> occur. Every claim below was re-checked against the code on 2026-09-10; the
> unimplemented ones were moved, not deleted, because the intent is still
> sound.

## Recent changes

**Re-scope: Hub + Node only, routers moved to a separate project (2026-09-14).**

The project scope narrowed to the Hub and the Node (formerly "test VM").
Router/switch design, configuration, and deployment are no longer part of
this codebase — they move to a dedicated project. Direct CSR1000v references
are removed throughout.

Concretely:

- `test-vm/` renamed to `node/`; "test VM" → "Node" everywhere in docs, UI,
  and agent/skill text.
- `endpoints.router` renamed to `endpoints.group_name` (wire field `router` →
  `group_name`, guestinfo key `lab.router` → `lab.group`, config var
  `ROUTER_NAME` → `GROUP_NAME`). A migration in `init_db()` renames the
  column on an existing database. `group_name` is a plain operator-chosen
  label — it clusters nodes on the dashboard and filters syslog by sender,
  and carries no network-topology meaning to the hub.
- **SNMP polling removed entirely** — `hub/app/snmp_client.py`,
  `snmp_poller.py`, the `snmp_targets`/`snmp_metrics` tables, the
  `/snmp/targets` and `/api/snmp*` routes, the "Router SNMP" dashboard panel,
  and all `HUB_SNMP_*`/`HUB_MGMT_IP` config keys. This was device monitoring
  for routers specifically and belongs with the router project now.
- **Config file download server removed entirely** — `lab-tester-serve`,
  `serve.initd`/`serve.conf`, `publish-config`, and `/srv/lab-tester-configs`.
  This existed only so routers could pull IOS config files from the hub.
- **PowerCLI router deployment removed** — `deploy/deploy-routers.ps1` and
  `deploy/lab-manifest.sample.ps1` (added earlier the same day, see the
  entry below — superseded within the day by this re-scope) deleted along
  with the whole `deploy/` directory.
- **Router config templates removed** — `docs/csr-baseline.cfg`,
  `docs/csr-example-r1.cfg` deleted.
- `docs/TOPOLOGY.md` rewritten generically: hub plus N nodes, the network
  between them drawn as one opaque cloud, syslog shown as an optional
  one-way arrow into the hub. The router-topology PNG (`docs/img/topology.png`)
  deleted along with it.
- The syslog receiver **stays** — the hub still optionally receives
  RFC3164/Cisco-style syslog from whatever network devices an operator points
  at it, for troubleshooting correlation. It never assumed CSR1000v
  specifically at the protocol level; only the docs and some comments did,
  and those are reworded.
- The SMTP ALG-detection rationale is reworded vendor-neutrally ("SMTP ALG /
  ESMTP inspection, common on firewalls and NAT gateways") without weakening
  constraint 21's guarantee — the underlying detector and the no-relay
  structural guarantee are unchanged.
- 9 vendored generic network-device skills and 3 generic network agents
  deleted (`cisco-ios-patterns`, `netmiko-ssh-automation`,
  `network-bgp-diagnostics`, `network-config-validation`,
  `network-interface-health`, the wireshark/tshark/packet-capture skills,
  the Palo-Alto skill, and the `network-architect`/`network-config-reviewer`/
  `network-troubleshooter` agents) — none were lab-tester-specific.
- Two dead config keys removed as a side effect of the cleanup:
  `HUB_TEST_INTERVAL`/`HUB_DEBUG` (read, never acted on) and the node's
  `TEST_INTERVAL` (documented as informational-only; the crontab is
  `* * * * *` regardless).
- `docs/img/dashboard-mock.jpg` re-captured against the current dashboard: a
  synthetic 5-node mesh (`site-a`..`site-e`), one failing path (`node-3` →
  `node-5`) selected with its syslog correlation panel open, no SNMP panel.
  README caption matches.

Every numbered constraint in `CLAUDE.md` survives with its number unchanged;
only the router-specific citations inside constraints 20 and 21 were
reworded, not weakened.

**PowerCLI router deployment script, Phase 1 (2026-09-14).**

`deploy/deploy-routers.ps1` + `deploy/lab-manifest.sample.ps1`. Deploys N
bare CSR1000v VMs from a manifest with correct sizing (1 vCPU / 4 GB / 8 GB
thin, `ipbase`) and correct per-router network mapping — three vNICs mapped
at OVA import time via `Get-OvfConfiguration`/`Import-VApp`, never with a
post-import `Set-NetworkAdapter` (piping all adapters into one call would
put mgmt/outside/inside on the same port group, silently). Establishes and
now documents (in `csr-example-r1.cfg`'s placeholder header and
`DEPLOYMENT.md` stage 1) the vNIC convention every future router-facing tool
should assume: `GigabitEthernet1`=mgmt, `2`=outside, `3`=inside.

Deliberately does **not** inject day-0 config via OVF properties —
`csr-baseline.cfg` applies `vrf forwarding MGMT` to the mgmt interface as
its first act, and `vrf forwarding` wipes an interface's existing IP
config, so an injected management IP would be wiped by the very config
that's meant to use it. Config application stays a manual console step,
per `DEPLOYMENT.md` stage 1 exactly as before.

This reopens `docs/HANDOFF.md`'s prior "No vCenter tooling, deliberately"
decision — the user explicitly asked for PowerCLI. The **manifest** half of
that entry's reasoning survives: one router identity (VM name, IOS
`hostname`, the name syslog puts in its own messages, `guestinfo.lab.router`,
`snmp_targets.name`) is load-bearing in five places that previously shared
no single source. Config rendering and hub auto-registration from that same
manifest remain unbuilt — see "Designed but NOT implemented" below.

**`smtp` test type, the ninth (2026-09-14).**

Client-compatible (no schema/contract change) — `VALID_TESTS` plus dashboard
`TYPE_LABELS`/`PAIR_TEST_TYPES`/`TYPE_NAMES`/`COARSE_TIMING` (letter `E`).
Full mesh, gated behind `ENABLE_SMTP` (default false); the static-target arm
is deliberately **ungated**, unlike `smb`'s — registering a target is already
an explicit opt-in, and the client side can't send mail regardless.

Catches what `smb` can't: a device that *passes* SMTP while *rewriting* it —
Cisco ESMTP inspection / ASA ESMTP fixup masks unrecognised capability verbs
(e.g. `STARTTLS`) with runs of `X`. The probe holds a real envelope
conversation (`EHLO` → `MAIL FROM:<>` → `RCPT TO:<probe@lab.invalid>` →
`RSET` → `QUIT`) via hand-rolled `nc` (curl was considered and rejected —
without a real upload it issues `VRFY` instead of `MAIL`/`RCPT`, and its
exact verb behavior has regressed across versions). `success` gates on the
banner + `EHLO` response only, never `RCPT` — a real relay correctly
rejecting the probe with `550` must not read as a failure. Never issues
`DATA`.

**Security is the load-bearing part of this change**, now CLAUDE.md
constraint 21: `test-vm/services/smtpd.conf` must never contain a `relay`
action or a `match ... for any` — structural guarantees, not policy, since
this lab has a real NAT/default-route path to the internet
(`docs/csr-example-r1.cfg`). The Alpine `opensmtpd` package's default config
*does* ship a relay action, so the `cp -f` that installs our own config in
`build-template.sh` is load-bearing, backed by a build-time grep warning and
a new regression-tester check (`grep -n relay test-vm/services/smtpd.conf`
must be comments-only). Own `lab-smtpd` OpenRC service, deliberately not the
packaged `opensmtpd-openrc` (bare `smtpd` service name — same collision risk
`httpd` was, and it would bypass `ENABLE_SMTP` and every safety guard if an
operator enabled it directly).

**`loss` test type, SNMP polling, and the config file download server (2026-09-13).**

Three additions. `loss` is client-compatible (no schema/contract change);
SNMP polling and the config server are new hub subsystems, neither touching
the existing wire contract. Regression suite CLEAR.

1. **`loss` test type** (8th, dashboard letter `L`) — `fping`-based packet
   loss %/jitter, full mesh, always on, no `ENABLE_*` gate. `success` is
   `true` whenever at least one probe replies (loss < 100%); the loss
   percentage itself lives in `output`, not the success field — some loss is
   the real signal this test exists to surface, so it is never a hard
   failure on its own (same philosophy `pmtu` already uses). Fine-grained
   timing (real decimal-ms from `fping`), deliberately excluded from the
   dashboard's `COARSE_TIMING` map, unlike every other non-`http` type.
2. **SNMP polling** (`hub/app/snmp_client.py`, `snmp_poller.py`) — opt-in
   (`HUB_SNMP_ENABLED`, default false). A background thread polls each
   router in a new `snmp_targets` table for `sysName` and per-interface
   counters (octets/errors/discards), stored in `snmp_metrics` and rendered
   on a new "Router SNMP" dashboard panel. Every outgoing packet is
   source-bound to `HUB_MGMT_IP` — the routers' SNMP ACL
   (`docs/csr-baseline.cfg`) only answers that address, so `snmp_client.py`
   is a small hand-rolled stdlib SNMPv2c client rather than `pysnmp` or the
   `net-snmp` CLI tools, neither of which reliably exposes a local-source-bind
   option. `HUB_MGMT_IP` unset while enabled is a startup failure, logged
   loudly — never a silent bind to the wrong interface. This also gives the
   hub its first real IP→router-name mapping, from each router's own
   `sysName` (see the syslog correlation caveat above).
3. **Config file download server** — `lab-tester-serve` (busybox httpd),
   always on, serves `/srv/lab-tester-configs/` read-only on port 8080,
   bound to every address (deliberately the opposite of SNMP's binding: a
   router pulling a config may not have its management NIC configured yet).
   Directory listing is automatic. `publish-config <file>` on the hub is the
   only write path. This closes the gap the "Designed but NOT implemented"
   section below used to list under "Config file server" — removed from
   there now that it's built.

**Router config templates, hub self-health, and hub zero-touch setup (2026-09-12).**

Five additions, all additive — no changes to the wire contract or existing
routes/tables, regression suite CLEAR (22/22 constraints, Tier 2/3, R21/R22):

1. **CSR1000v config templates** — `docs/csr-baseline.cfg` (identical across
   every router) and `docs/csr-example-r1.cfg` (per-router worked example).
   Routing is eBGP, one AS per router, full mesh over a shared outside
   segment, no IGP underneath. Management interface in a VRF (`MGMT`), with
   syslog/NTP/SNMP all explicitly `vrf MGMT` — the actual config realizing
   the "management separation" design described below. Includes NAT
   overload for internet access and an SNMP read-only community restricted
   by ACL to the hub's mgmt IP. Every value is a `<PLACEHOLDER>` token, not
   a real address. Diagram: `docs/TOPOLOGY.md` (Mermaid + a rendered PNG,
   `docs/img/topology.png`).
2. **`GET /api/health`** (`hub/app/app.py`) and a "Hub Health" dashboard
   panel — OpenRC service status, syslog listener state, load average,
   memory, disk, uptime. Same never-500 discipline as `/api/time`: every
   check is independently fault-tolerant.
3. **Hub zero-touch setup** — `guestinfo.hub.ip` / `guestinfo.hub.gateway`,
   read by a new `lab-tester-hub-firstboot` OpenRC service
   (`hub/services/firstboot.initd`), mirroring the test-VM's existing
   `lab-tester-firstboot`. With neither key present, it stands down (no
   reliable tty inside an OpenRC `start()` to prompt from) and
   `hub-setup.sh` prompts interactively at first login instead
   (`hub/services/login-setup.sh` invites it via `/etc/profile.d`).
4. **`LAB_ROOT_PASSWORD`** — both `build-template.sh` scripts now read this
   env var (default `lab123`) instead of hardcoding the root password.
5. Doc pass: `DEPLOYMENT.md` stages 1/3/6 now point at the config templates
   and the zero-touch/interactive setup options; `README.md` and `CLAUDE.md`
   updated to match.

**Hub NTP-sync indicator added to the main dashboard (2026-09-11).**
`GET /api/time` (added 2026-09-10) was rendered on `/syslog` only. The same
endpoint is now also polled from `templates/dashboard.html` (`loadClock()`,
60s interval) into a `#clock` span in the header status bar — red when the
hub has no chrony info or is on chrony's `local_only` stratum-10 fallback
(no reachable upstream NTP server), yellow for a synced-but->100ms offset,
green otherwise. No backend change; reuses the existing route and its
never-500s contract. Regression suite run against it: **CLEAR**, 22/22
constraints plus the wire contract and R21/R22, 0 failures, 0 skipped —
confirmed the diff is additive-only and does not touch `/api/time`,
`/syslog`'s own separate clock implementation, or any wire-contract field.

**Test-VM config requires three variables — reducing it to one was designed,
never built.** `register.sh` validates `HUB_URL`, `ROUTER_NAME` *and* `SUBNET`,
and `exit 1`s on the first empty one. There is no `subnet_from_cidr()` anywhere
in the tree and no defaulting of `ROUTER_NAME`.

The argument for reducing it still stands: each required variable is another way
for a clone to fail silently, since an unregistered VM is simply invisible in
the matrix rather than visibly broken. But until someone writes the derivation,
all three must be set per clone — `BUILD_GUIDE` §8.4 is the accurate account.
This entry described the intended design as delivered for some time; corrected
2026-09-10.

**Syslog receiver wired up (2026-09-10).**
`hub/app/syslog_server.py` and `templates/syslog.html` had been in the tree for
some time as *dead code* — no config keys, no table, no routes, and nothing
calling `start()`. All four were added:

- `config.py`: `SYSLOG_ENABLED`, `SYSLOG_BIND`, `SYSLOG_PORT`,
  `SYSLOG_MAX_ROWS`, `BUSY_TIMEOUT_MS`, all overridable from `hub.env`, which
  `build-template.sh` now writes.
- `app.py`: the `syslog` table plus indexes on `received_at` and `host`;
  `GET /api/syslog` (`minutes` | `from`/`to`, `host`, `severity`, `q`,
  `limit`), `GET /api/syslog/sources`, `GET /syslog`.
- `serve.py` calls `syslog_server.start()` — after the schema exists, and
  tolerant of a failed bind, because a syslog problem must never stop the hub
  collecting results.

Row cap only (`HUB_SYSLOG_MAX_ROWS`, default 300000), enforced every 500
inserts by an indexed delete on `id`.

**Correlation from the dashboard (2026-09-10).**
Each test card in the drill-down links to `/syslog` pinned to ±5 min around
*that sample*; the pair header links to the same window plus one link per
router behind the pair. `GET /api/time` reports chrony's tracking state and the
syslog header renders it — the pinning is only meaningful if the hub's clock is
disciplined, so an undisciplined one is surfaced rather than left to misalign
every window silently.

**Fixes from a code review of the syslog work (2026-09-10).**

1. *`received_at` shipped raw from `/api/results`.* Both results routes
   returned `jsonify([dict(r) for r in rows])`, emitting SQLite's
   space-separated form while `/endpoints` emitted ISO. `result_row()` now
   applies `iso()` in both. The dashboard's `parseTs()` had been masking it, so
   the page looked correct while the API lied to every other consumer.
2. *Explicit JSON `null` discarded whole batches.* `.get(k, default)` returns
   the default only when the key is *absent*, so `{"target_ip": null}` hit a
   `NOT NULL` column, raised `IntegrityError`, skipped the commit and lost
   every other row in the push. Now coerced explicitly. Constraint 19.
3. *`allow_reuse_address` on the UDP listener.* `SO_REUSEADDR` does not
   reliably reject a duplicate UDP bind, so `run.sh` alongside the service
   would split datagrams between two processes and two databases. Removed.
   Constraint 20.
4. *`busy_timeout` set after `journal_mode`*, leaving that statement
   unprotected, and absent entirely from `init_db()`. Now first on all three
   connections. Constraint 17.
5. *Syslog stored ISO timestamps* while everything else used SQLite's format —
   constraint 2 in a new place. Now identical formats, `iso()` on the way out.
   Constraint 18.
6. *Diagnostics used `print()`*, which under OpenRC is block-buffered into the
   service log and never flushed, so `[syslog] listening on …` — the line
   DEPLOYMENT tells you to look for — never appeared. Now `sys.stderr`.
7. *Unparseable lines got fake hostnames.* `kernel: out of memory` was filed
   under host `kernel`, which then appeared as its own device in the source
   filter. A `word:` prefix is now only an origin-id when a timestamp or
   `%MNEMONIC` follows.
8. *One fsync per datagram* capped the single-threaded drain at ~500 msg/s,
   inside what a router at debug level produces. The listener's connection uses
   `synchronous=NORMAL` (safe under WAL; the results path is untouched).
9. *`/api/results?minutes=-5`* built `'--5 minutes'`, which SQLite evaluates to
   NULL — an empty matrix with a 200, indistinguishable from a dead lab.

`CLAUDE.md`'s numbered constraint list now runs to 21. The `regression-tester`
agent has a check per constraint (R1–R21, some split into sub-checks like R14b)
plus a wire-contract tier.

## Designed but NOT implemented

Verified absent from the code on 2026-09-10. Kept because the intent is sound,
but **nothing here works today**:

- **Hub as the lab's NTP source.** `chrony` is installed and `chronyd` enabled
  by `hub/build-template.sh`, so `/api/time` reports real tracking state — but
  no `chrony.conf` is written, there is no `set-ntp-clients` helper and no
  access list, and `node/scripts/setup.sh` does not configure chrony on the
  nodes. The hub disciplines its own clock and serves time to nobody.
- **`set-static-ip` per-interface state.** The helper takes
  `<ip/cidr> <gateway>` only; there is no interface argument and no
  `/etc/lab-tester/net.d`. Configuring a second NIC still overwrites the first.
- **`/etc/sysctl.d/99-lab-tester.conf` pinning `net.ipv4.ip_forward=0`.**
  Absent — Alpine's default is 0, but the build does not assert it.
- **Time-based syslog pruning.** Syslog is row-capped only. (`results` *does*
  have working time-based retention via `HUB_RESULT_RETENTION_HOURS`, swept on
  each `POST /results` — constraint 8.)

## Open items

- **Syslog has never run on the real hub VM.** Everything so far is a local
  Python process on a workstation. Confirm the OpenRC service starts the
  listener, that UDP/514 binds under it (514 is privileged — the service runs
  as root, so this should hold), and that a real network device's packets
  actually arrive.
- **`/api/time` and the dashboard correlation links now have suite coverage**
  (R21 and R22, added 2026-09-10). R21 drives all eight `chronyc` states through
  the route with a faked binary, since the workstation only ever exercises the
  "not installed" path; R22 replays a generated window against a live
  `/api/syslog`, including the `+02:00` truncation probe. Both are suite-only
  checks — CLAUDE.md's numbered list stays at 20, because that list is a bug log
  and neither of these has failed yet.
  What remains hand-verified only is the **rendering**: that the clock indicator
  actually colours red/amber/green and that the links are clickable in a
  browser. No headless check reaches that.
- **Severity filter and unparseable lines — decided, 2026-09-10.**
  `/api/syslog` now applies `(severity <= ? OR severity IS NULL)`, so a line
  the parser could not assign a severity to stays visible under every severity
  filter. The old clause dropped it, which contradicted the parser's own
  principle that a message you cannot parse is often the one you most want to
  see. Cost of the decision: an unparseable line shows up even when filtering
  for emergencies only, so a noisy unrecognised format cannot be filtered out
  by severity — judged the better failure of the two.
- **No IP→device map.** Sender identity for syslog is the parsed hostname,
  falling back to source IP. Where a device's syslog hostname differs from a
  node's `GROUP_NAME`, the dashboard's filtered link returns an empty view
  while the unfiltered ±5 min link beside it still works — empty rather than
  wrong, by design. A separate identity map would fix it properly, but is
  outside this project's scope now that device identity/configuration lives
  in the router project.
- **Hostname is still the one per-clone input.** `setup.sh` takes it from
  `guestinfo.lab.hostname` or derives it from the group slug. Deriving it from
  IP or MAC at first boot would remove the last manual step and the
  duplicate-hostname failure mode (constraint 1).

Management separation (a VRF-isolated router management plane, a
dual-homed hub, SNMP polling, router config rendering) was designed and
partly specified before the 2026-09-14 re-scope. All of that is now out of
scope for this project — it belongs with whatever owns the router/switch
side, not here. See the 2026-09-14 entry above for exactly what was removed.

## Conventions that must not drift

- **The wire contract is frozen** unless the golden image is rebuilt:
  `/register` requires hostname, ip, subnet, group_name; `/results` uses the
  documented field names. Renaming a field breaks every deployed node silently.
- **Node scripts are BusyBox ash**, `#!/bin/sh` with `set -u`. No bashisms.
- **Timestamps are stored in SQLite's `YYYY-MM-DD HH:MM:SS`**, in every table,
  and converted to ISO-8601 with `Z` by `iso()` on the way out. Window queries
  compare `received_at` against `datetime('now', ...)`. Do **not** store the
  ISO form: `T` (0x54) sorts above space (0x20), so a mixed comparison lets any
  same-day row pass any window. This is constraint 2, and it has now been
  reintroduced twice — once in `/api/results` output, once in the syslog
  writer.
- **`results` is append-only.** The timeline depends on it.
- **Free text into JSON goes through `json_escape()`**, or the hub rejects the
  whole cycle.
- **Numbers in JSON are built with arithmetic**, never string concatenation —
  `printf '%d000'` emits `0000`, which Python's parser rejects while `jq`
  accepts it, so the hub 400s the entire batch. Constraint 9.

## Running the hub locally

`serve.py` is the entrypoint — it reads `HUB_PORT` at runtime and starts the
syslog listener. Do not run `flask run` against `app/app.py`; that skips the
listener entirely and uses the single-threaded dev server.

```sh
cd hub
HUB_DB_PATH=/tmp/hub.db HUB_PORT=8099 HUB_SYSLOG_PORT=5514 python3 serve.py
```

`hub.env` is picked up by `run.sh` if present, so a manual run matches the
service. Ports below 1024 need root; override `HUB_SYSLOG_PORT` when testing as
an ordinary user.

Send a test message:

```sh
python3 -c "import socket;socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(
b'<187>12: SW1: *Sep  8 12:00:00.000 UTC: %OSPF-5-ADJCHG: Nbr 10.0.0.2 FULL to DOWN',
('127.0.0.1',5514))"
curl -s 'http://127.0.0.1:8099/api/syslog?minutes=5'
```

Note that importing `app.app` runs `init_db()` at module scope, so any script
that imports it creates a database in the current directory unless `HUB_DB_PATH`
is set. Set it.

## Skills and agents

4 skills in `skills/` and 7 agents in `.claude/agents/` (a real directory, not
a junction), following the 2026-09-14 re-scope which removed 9 vendored
generic network-device skills and 3 generic network agents that carried no
project-specific content. Project-specific skills: `lab-tester-hub-api`,
`lab-tester-node`, `lab-tester-troubleshooting`, `lab-tester-add-test-type`.
Project-specific agents:

| Agent | Use |
|---|---|
| `regression-tester` | Gate before handing over any change. One check per numbered constraint, plus live-hub and wire-contract tiers. |
| `drift-checker` | Docs, config samples, UI labels and agent definitions vs. what the code does. |
| `hub-api-developer` | Changes under `hub/` — routes, schema, dashboard. |
| `alpine-vm-builder` | Anything running on the nodes. |
| `golden-image-verifier` | Real-Alpine-container verification of `build-template.sh` changes. |
| `lab-tester-diagnostician` | Triage when the dashboard looks wrong. |
| `test-result-analyst` | Interpreting collected results rather than fixing an outage. |

Read the relevant skill before changing the code it covers.
