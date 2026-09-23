# Lab-Tester — Session Handoff

Last updated: 2026-09-20. Written so a fresh session on any surface (Claude Code
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

**Dashboard: Recent Changes / Recent Syslog panels, syslog page nav and controls (2026-09-20).**

Additive dashboard/template work, no backend change beyond reusing existing
routes.

1. **`hub/templates/dashboard.html`** — two new sections between the
   Connectivity Matrix and Static Targets:
   - **Recent Changes** — the last 15 *transitions*, not raw state: a test
     flipping pass→fail or fail→pass, a detected traceroute path change
     (reusing `/api/path-changes`), and a collapse rule for a pair whose
     *every* declared test type fails in the same cycle — rendered as one
     "ALL tests FAILED (N tests)" row instead of N separate flip rows.
     Computed client-side in `computeRecentChanges()` from a wider
     `/api/results?minutes=60` fetch (deliberately separate from the
     matrix's own `minutes=10` fetch). Rows are clickable and open the
     existing Test Detail panel.
   - **Recent Syslog** — last 10 messages via `/api/syslog?minutes=1440&limit=10`,
     a compressed preview of `/syslog` with a "View all →" link.
2. **Nav buttons** — `dashboard.html` and `syslog.html` each get a
   `Dashboard`/`Syslog` button pair in the header: one real link (`.btn-nav`)
   to the other page, one non-clickable `<span class="btn-nav-current">`
   marking which page you're on. Replaces `syslog.html`'s old plain
   "← Connectivity matrix" text link.
3. **`syslog.html`** — heading changed from "Lab syslog" to "Syslog messages";
   the `Window` filter now defaults to "everything" instead of the last hour;
   a `#toggle-live` button added to turn the existing 15s auto-refresh on/off
   (hidden when a `from`/`to` window is pinned, same condition that already
   disables the `Window` select in that case).

No wire-contract change, no new routes — `/api/path-changes` and
`/api/syslog` already existed. Verified live via the `dev/` toolkit: a
static target with 2 declared tests correctly collapsed to a single "ALL
tests FAILED" row when both flipped together in one cycle; a mesh pair with
more test types (one already permanently down) correctly stayed itemized as
separate rows instead of collapsing.

**Node console-output feature: `test-status` command and login banner (2026-09-20).**

Client-compatible — the wire contract to the hub is untouched; this is purely
what a node shows at its own console/SSH session. Use case: view a node's own
test results directly without opening the hub dashboard, e.g. mid coding
session on that VM.

1. **`node/scripts/test-cycle.sh`** — each cycle now also renders a compact
   table (one row per target, one column per always-on test type — H/S/M/L/T)
   to `/dev/console` (`CONSOLE_OUTPUT`, on by default; device configurable via
   `CONSOLE_DEVICE`), in addition to the existing cycle log. Also written to
   a snapshot file at `/run/lab-tester/last-cycle.txt` so it can be read back
   without re-running a cycle.
2. **`node/scripts/test-status.sh`** (new) — reads the snapshot by default;
   `-f`/`--follow` tails it live, `-n N` shows the last N cycles from the log.
   Symlinked onto `PATH` as `test-status`.
3. **`node/services/login-status.sh`** (new) — a `/etc/profile.d` hook that
   shows the last test result and mentions `test-status`'s availability/syntax
   at every interactive login, next to the existing setup-wizard invite. Same
   three-layer guard as `login-setup.sh` (interactive shell, real tty, stamp
   file), so it never fires for `ssh host cmd` or a non-interactive scp/rsync
   shell.
4. **Not in the agent self-update manifest, deliberately** — `test-cycle.sh`
   self-updates via `hub/agent/` and carries the table-rendering logic with
   it, but `test-status.sh`/`login-status.sh` themselves are separate files,
   same category as `register.sh` (constraint 13): pushed deliberately
   (`node/build-template.sh` for new clones, `setup.sh` or a one-off `scp`
   for nodes built before this feature existed).

**Traceroute path-change detection (2026-09-20).**

Client-compatible — no wire-contract change, `test-cycle.sh` untouched. A
traceroute result already landed in `results.output` every cycle; nothing
compared one sample to the next before this. Detection is hub-side, inside
`POST /results`, logged into the **existing** `syslog` table (tagged, not a
new table) and surfaced on the dashboard via the existing `/syslog`
correlation pattern — chosen over a dedicated `path_changes` table (more new
code, duplicates what `/syslog` already does) and over a dashboard-only
computation (no durable record for a pair nobody has open).

1. **`hub/app/pathchange.py`** (new) — pure stdlib, never raises. `parse_hops`
   turns raw traceroute text into an ordered `(hop_number, address)` list,
   keyed by traceroute's own hop number so a header line or a merged stderr
   line (the node captures `2>&1`) can't shift later hops; a hop with no
   reply or a non-IPv4 token is simply omitted. `diff_hops` compares only hop
   numbers present in **both** samples — the noise-suppression rule
   (`-q 1` means a single dropped probe is ordinary noise) and the
   length-is-never-a-trigger rule both fall out of that one design choice
   rather than needing separate checks. `format_message`/`format_raw`/
   `split_message` keep the syslog message shape's writer and reader in one
   place.
2. **`hub/app/app.py`** — new index `idx_results_trace ON results(source,
   target_hostname, test_type, received_at)`; `_previous_traceroute`/
   `_note_path_change` helpers; a hook inside `push_results`'s existing loop
   (before each traceroute row's `INSERT`, look up the previous one on the
   same connection; after, note the change if any) wrapped in try/except,
   stderr-only on failure — a detection bug must never cost a node its
   results; new `GET /api/path-changes?minutes=N` route.
3. **`hub/app/config.py`** — `PATH_CHANGE_ENABLED` (`HUB_PATH_CHANGE_ENABLED`,
   default true).
4. **`hub/templates/dashboard.html`** — one more fetch per refresh
   (`/api/path-changes?minutes=10`, same window as `/api/results`);
   `pathChangeMap()`; `renderIndicators()` composes a `.changed` marker
   (yellow inset ring, `--yellow` token) onto the traceroute cell in both the
   mesh and static-target matrices; the Test Detail panel gets one more line
   under the traceroute card linking out via the existing `syslogUrl()` ±5
   min pin. `syslog.html` needed no change — it already renders host/severity/
   mnemonic/message generically.
5. **`dev/shims/traceroute`** — `DEV_TRACE_PATH` env override (space-separated
   hop list; default unchanged, the original fixed 3-hop output), same
   precedent as `DEV_FAIL_HOSTS`, so a coding session can produce a real path
   change end to end without a real node.
6. **`hub/build-template.sh`** — `HUB_PATH_CHANGE_ENABLED=true` added to the
   `hub.env` heredoc (a drift-checker pass caught this missing on first
   landing — every other hub setting has a `hub.env` line, this one hadn't).

**The honest trade-off, written down in CLAUDE.md's Syslog section:** a
hub-authored row is the one row in `syslog` that's actually trustworthy, and
gains no special protection from it — anything on the segment can forge the
same `host=lab-tester-hub`/`mnemonic=%LABTESTER-5-PATHCHANGE` tag, and
`GET /api/path-changes` would serve it back. The tag is a label, not a
boundary; blast radius is bounded (a spurious marker plus a syslog link, no
`results` row ever altered or lost).

Verified: unit tests for `pathchange.py` standalone (identical→no change,
`*` at the differing position→no change, real mid-path swap→right hop
number, length-only change→no change, malformed/empty/IPv6→`[]`→no change,
`split_message(format_message(...))` round-trips) — all passed. Integration
via `dev/hub-start.sh` + `dev/run-node-cycle.sh`: a second identical cycle
produced no syslog row (false-positive check); `DEV_TRACE_PATH` produced
exactly one path-change row with the correct hop number and both hop lists
in `raw`; `/api/path-changes` returned the right source/target/detail with
`received_at` ending in `Z`; a garbage traceroute shim output still let
`POST /results` accept the full batch (row count grew by the full batch,
no error); `HUB_SYSLOG_ENABLED=false` still ingested results and still wrote
path-change rows (the table exists independent of the listener);
`EXPLAIN QUERY PLAN` confirmed `idx_results_trace` is actually used. Dashboard
rendered via Playwright (system Chrome, no `/opt/pw-browsers` on this
workstation): the `.changed` marker appears on the traceroute cell in both
matrices, correctly asymmetric by direction (a→b marked, b→a not); the
detail-panel line and its syslog link work, landing on the pinned row; no
console/pageerror events.

**`set-static-ip` gains optional DNS and hostname arguments (2026-09-20).**

`set-static-ip <ip/cidr> <gateway> [dns] [hostname]` — two new optional
trailing arguments:
- `[dns]` writes `nameserver <dns>` to `/etc/resolv.conf` after configuring
  the interface. Previously the helper always left DNS unconfigured and
  just printed a reminder to edit `/etc/resolv.conf` by hand (see the
  `resolv.conf` cleanup gap entry below — this is the same gap, now
  closable in one command instead of a manual edit).
- `[hostname]` sets `/etc/hostname`, calls `hostname <name>`, and updates
  (or appends) the `127.0.1.1` line in `/etc/hosts` — same technique
  `node/scripts/setup.sh` already uses for the node's own hostname, so the
  hub gains no second way of doing the same thing. A no-op if the current
  hostname already matches.

`hub-setup.sh`'s interactive wizard still only prompts for IP and gateway
and calls `set-static-ip` with exactly those two arguments — it does not
yet offer DNS or hostname prompts, so both new arguments are reachable
only by invoking `set-static-ip` directly or via `guestinfo`-driven
automation that chooses to pass them.

**Guided install and a node first-login setup prompt (2026-09-20).**

Three new mechanisms, mirroring what the Hub already had one-for-one rather
than inventing a new shape. Client-compatible — no wire-contract change, no
change to `setup.sh`'s own logic.

1. **`install.sh`** (new, repo root) — asks whether a fresh Alpine base VM
   becomes a Hub or a Node and runs (or prints, on decline) the matching
   `build-template.sh`. Refuses outright if the VM already looks built into
   a role (`/usr/local/bin/lab-tester/setup.sh` or `/opt/lab-tester-hub/`
   present) — both `build-template.sh` scripts are destructive on an
   already-configured system (node: wipes config/hostname; hub: wipes the
   results DB) and their only existing protection, self-deleting after a
   successful run, disappears the moment the repo is re-downloaded. Default
   confirmation is "no" before actually running a build; `-y`/`--yes` skips
   it for scripted use.
2. **`node-setup.sh` + `node/services/login-setup.sh`** — the Node's
   missing half of a pattern the Hub already had. `login-setup.sh` is
   installed to `/etc/profile.d/lab-tester-node-setup.sh` (same three-layer
   guard as the Hub's: interactive shell, real tty, stamp file) and invites
   `node-setup.sh` at first login. The wizard collects **no configuration
   values itself** — it only asks `Configure this node now? [Y/n]` and
   delegates to the existing `setup.sh`, which already does all the actual
   collection. Keeping collection in one place matters: `firstboot.initd`
   calls only `setup.sh`, so logic added to the wizard instead would be
   invisible on the zero-touch guestinfo path.
3. **New stamp file `/etc/lab-tester/.setup-done`**, deliberately *not* the
   existing `/etc/lab-tester/.firstboot-done`. That file has exactly one
   writer (`firstboot.initd`) and one meaning ("the zero-touch service
   completed"); if the login wizard also wrote it, declining the prompt with
   "don't ask again" would silently disarm the zero-touch path too — an
   operator who later sets guestinfo keys and reboots would find the node
   quietly ignoring them. `firstboot.initd` now writes *both* stamps on
   success (`.setup-done` gets `configured (guestinfo)`), so a zero-touch
   node never gets nagged at login either. Four provenance words in
   `.setup-done`: `configured`, `skipped`, `configured (guestinfo)`,
   `configured (existing config)` (the last is an adoption gate — a config
   that exists with no stamp, i.e. `setup.sh` was run by hand before the
   wizard ever saw this node, is adopted silently rather than nagged).
   `node-setup.sh --force` on an existing config asks to discard it first
   (backing it up to `config.bak-<timestamp>`, not deleting) — resetting
   only the wizard's own stamp would have re-run `setup.sh` but silently
   kept the old values, since `setup.sh`'s own idempotency gate is separate
   ("does `/etc/lab-tester/config` exist").
4. **`node/build-template.sh`'s cleanup** now also clears
   `/etc/lab-tester/config.bak-*` and `.setup-done`, alongside the existing
   `config`/`.firstboot-done` clear — the same class of bug fixed earlier
   this session for a different file: a golden image sealed with
   `.setup-done` present would silently silence the login prompt on every
   clone made from it, and the only symptom is a node that never registers.
5. **Consistency hardening on `hub/scripts/hub-setup.sh`**: its `read`
   calls had no `|| VAR=""` EOF guard, relying solely on `login-setup.sh`'s
   `[ -t 0 ]` check to never be invoked with closed stdin. Retrofitted the
   same guard convention used elsewhere this session, including the
   `if ! read` form (not `|| VAR=""`) on the one defaulted-yes prompt, where
   the two forms are not interchangeable: `|| VAR=""` can't tell a bare
   Enter from EOF, so on a defaulted-yes prompt EOF would read as consent.
   No behavior change on a real VM (the tty guard already prevented these
   paths from being hit); only changes what happens if `hub-setup.sh --force`
   is ever invoked directly from a non-interactive context.

Verified with a scripted walkthrough (patched copies with only
`/etc/lab-tester(-hub)` paths redirected, diffed against originals to
confirm nothing else changed, stubs for `ip`/`rc-service`/`set-static-ip`/
`vmware-rpctool` on PATH) covering: the EOF-on-main-prompt case (proves
`if ! read` over `|| VAR=""` — under the latter, EOF would have driven
straight into `setup.sh` with closed stdin), decline+skip, decline+ask-again,
accept+success, accept+failure, already-stamped, adoption, `--force`
declining and accepting the discard, `firstboot.initd`'s double-stamp write
on success and neither stamp on failure, the cleanup line's glob, and the
three login-hook guard layers staying silent for both a non-interactive
shell and an interactive-but-no-tty one. Also replayed the same wizard cases
against the now-hardened `hub-setup.sh` to confirm no regression. One real
bug caught by testing: `install.sh`'s already-built check first used `[ -x
... ]` on the node marker, which is fragile if the execute bit is ever lost
(it doesn't need to be executable to prove the node is configured) — changed
to `[ -f ... ]`.

**Also verified against a genuine pty** (Docker, `util-linux`'s `script`
wrapping a real interactive `sh -i`, not the CLI's own non-interactive
Bash tool): the real `login-setup.sh`, sourced from `/etc/profile.d` under
that pty with no stamp present, does invoke the real `node-setup.sh` and
print its actual prompts; declining with "skip, don't ask again" writes the
stamp; a second real login under the same pty afterward stays completely
silent. This closes a gap the Hub's identical, already-shipped mechanism had
never had verified either (`DEPLOYMENT.md`'s "nothing here has run on real
hardware yet" banner predates this session).

**Node first-boot resiliency: DHCP failsafe, subnet auto-derivation, and a
latent `set -e` abort fixed (2026-09-20).**

Four related fixes to `node/scripts/setup.sh`, all client-compatible (no
wire-contract change):

1. **Manual static-IP failsafe.** If DHCP hasn't assigned an address by the
   time `setup.sh` runs, it now prompts for a one-time static IP/CIDR and
   gateway and writes `/etc/network/interfaces` itself (same shape as the
   hub's `set-static-ip`). Before this, a node with no DHCP lease just
   silently never registered, with no error visible anywhere but its own log.
2. **`SUBNET` no longer needs a human to supply it.** The DHCP lease already
   carries address + prefix, so `setup.sh` now derives the network address
   from the current lease (`derive_subnet()`, pure integer arithmetic —
   floor-divide by `2^hostbits` then multiply back, since busybox awk has no
   bitwise operators) and only falls through to guestinfo/env/prompt if that
   fails. This closes the gap `HANDOFF.md` flagged 2026-09-10 as "designed,
   never built" (reducing the three required vars, no `subnet_from_cidr()`
   anywhere) — `guestinfo.lab.subnet` and `SUBNET` are now optional, not
   required. `register.sh` and the wire contract are unchanged: the config
   file still needs a non-empty value by cron time, only now it's usually
   filled in automatically rather than typed in.
3. **Fixed a latent `set -e` abort.** `firstboot.initd` only checks
   `guestinfo.lab.hub_url`/`.group` before invoking `setup.sh`, never
   `.subnet` — so a clone missing just the subnet key hit the subnet prompt
   with stdin redirected from `/dev/null` (deliberate, so firstboot can't
   hang the boot on a prompt nobody will answer). The unguarded `read` there
   returned EOF's nonzero exit status, and under `set -eu` that aborted the
   *entire* script before cron or any service got installed — worse than the
   already-tolerated "hub not up yet" registration failure. All three config
   prompts (`HUB_URL`/`GROUP_NAME`/`SUBNET`) and the new IP prompt now use
   `read -r var || var=""`. In practice, fix 2 mostly closes the door fix 3
   guards, since subnet is rarely absent from *and* underivable at the same
   clone.
4. **Hub's `resolv.conf` cleanup gap.** `hub/build-template.sh`'s
   template-conversion cleanup never touched `/etc/resolv.conf`, so a clone
   could silently inherit whatever DNS server the *build* network's DHCP
   handed out — nothing refreshes it again once the hub goes static.
   Cleanup now blanks it, and `set-static-ip`'s output says DNS is
   unconfigured so an operator who needs it (e.g. a chrony NTP pool
   hostname) knows to set `/etc/resolv.conf` by hand.

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
all three must be set per clone — `BUILD_GUIDE` §6.4 is the accurate account.
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

- **Renaming.** `lab-tester` (and possibly the separate `lab-butler` project)
  may get renamed — current name is generic and a poor search/package term.
  Candidate: `lab-scout` (exact-name collision with an unrelated, low-traffic
  GitHub project, `mithr4ndir/lab-scout`; judged low risk). Also floated:
  something incorporating "Flux" paired with a network-related term — e.g.
  `netflux`, `fluxmesh`, `fluxpath`, `fluxroute` — evoking traffic that
  flows and shifts across paths, which fits the path-change-detection framing
  in particular. None of these have been checked for name collisions. No
  decision made, no renaming done yet — this is tracking only.
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

5 skills in `.claude/skills/` and 8 agents in `.claude/agents/` (a real
directory, not a junction), following the 2026-09-14 re-scope which removed 9 vendored
generic network-device skills and 3 generic network agents that carried no
project-specific content. Project-specific skills: `lab-tester-hub-api`,
`lab-tester-node`, `lab-tester-troubleshooting`, `lab-tester-add-test-type`,
`lab-tester-dev-toolkit`. Claude Code only loads skills from `.claude/skills/`;
they sat unloaded in a root `skills/` folder until 2026-09-22.
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
| `vsphere-deploy-reviewer` | PowerCLI clone scripts — guestinfo keys, unique clone names, power-on ordering. |

Read the relevant skill before changing the code it covers.
