---
name: mesh-probe-add-test-type
description: Checklist and decision framework for adding a new connectivity test type to mesh-probe (the pattern behind smb, loss, and smtp) — where it must be wired, and the judgment calls that come before the wiring. Read before starting a new test type, not after.
origin: mesh-probe
---

# Mesh-Probe: Adding a Test Type

Three test types have been added this way (`smb`, `loss`, `smtp`). The
wiring is mechanical and exhaustive; the design decisions are not. Make the
decisions first — they change what the wiring looks like.

## When to Activate

- The user asks to add a new connectivity test, probe, or check to the mesh
- Deciding whether a new test should be gated, full-mesh, or static-target
- Picking a dashboard letter or reasoning about `COARSE_TIMING`
- Reviewing a test-type addition for completeness

## Design decisions — settle these before touching code

**Gating.** Opt-in (`ENABLE_X`, default `false`) for anything that stands up
a new listening daemon on every node (`smb`, `smtp`, `iperf3`) — it has a
real resource and security footprint. Always-on for a client-only probe with
no footprint of its own (`loss`).

**Shape.** Full mesh (server on every node), static-target-only, or both.
`smtp` is the precedent for "both, asymmetrically": its mesh side is gated
behind `ENABLE_SMTP`, but its static-target arm is **ungated** — registering
a static target via `POST /targets` is already an explicit operator opt-in,
so a client-only probe against it doesn't need a second gate stacked on top.
Document any such asymmetry inline, or `drift-checker` will read it as an
oversight.

**Success semantics.** Binary pass/fail is the default. When the interesting
signal is a spectrum — packet loss %, a PMTU breakpoint, masked ESMTP
capability verbs — `success` should gate on "did the test run and get *some*
meaningful response," while the real data goes in `output`. Never conflate
"degraded" with "failed": `pmtu` reports a partial breakpoint rather than a
hard failure, `loss`'s `success` is `true` on any reply at all, and `smtp`'s
gates on the banner + `EHLO` response only, never `RCPT` — a real relay
correctly rejecting the probe's `RCPT TO:<probe@mesh-probe.invalid>` with `550`
must still read `success:true`. Get this wrong and a perfectly healthy
target reads as broken.

**Timing precision.** `date +%s` whole-second deltas belong in the
dashboard's `COARSE_TIMING` map (`ssh`, `traceroute`, `pmtu`, `dns`,
`iperf3`, `smb`, `smtp`). A tool with real sub-second precision of its own
(`fping`, `curl`'s `%{time_total}`) does not (`http`, `loss`). Decide this
deliberately — copy-pasting the wrong pattern silently throws away
resolution the tool actually has.

**Client tool.** Prefer wrapping a real, already-relevant client
(`curl`/`smbclient`/`fping`) over hand-rolling a protocol conversation — but
check the tool actually does what's needed first. `smtp` is the
counter-example: Alpine's `curl` supports `smtp://`, but without a real
upload it issues `VRFY` instead of `MAIL FROM`/`RCPT TO` (which most relays
disable or misread as address harvesting), and its exact verb behavior has
regressed across versions. A hand-rolled `nc` conversation was correct
there. Default to checking, not to hand-rolling.

**Server daemon naming.** Always ship an own `lab-<name>` OpenRC init
script (`mesh-probe-httpd`, `mesh-probe-smbd`, `mesh-probe-smtpd`), never a packaged `*-openrc`
subpackage's default service name. A generic service name (`smtpd`,
`httpd`) is a collision/bypass risk — an operator could enable it directly,
skipping the `ENABLE_X` gate and every safety guard in the config this
project writes (CLAUDE.md constraint 5, constraint 14's `opensmtpd-openrc`
entry).

**Dashboard letter.** Current allocation: H/S/T/M/D/I/B/L/E
(`http`/`ssh`/`traceroute`/`pmtu`/`dns`/`iperf3`/`smb`/`loss`/`smtp`) — check
`hub/templates/dashboard.html`'s `TYPE_LABELS` for the live set before
picking one. Avoid a letter that would be confusing given the test's own
output — `X` was rejected for `smtp` because masked ESMTP capabilities
render as literal `X` runs.

**Security review — mandatory for any new listening daemon.** Can it be
reached from outside the lab? A node may sit behind NAT with a real
default route off the lab, so check that assumption rather than asserting
"it's an isolated lab." Does the daemon's config have a *structural*
guarantee against the worst case
(no relay action, no admin interface, no write path) rather than a policy
setting that could be edited away later? This review produced CLAUDE.md
constraint 21 for `smtp`. The next daemon-backed test type should get the
same scrutiny before it ships, not after.

## The wiring checklist

**`node/scripts/test-cycle.sh`**
- Inline config default (`ENABLE_X="${ENABLE_X:-false}"`) — mandatory, not
  just in `config.sample`. `setup.sh` never rewrites an existing config
  file, so every already-deployed node runs against a config missing the
  new key.
- `run_<type>_test()` — the seven-field JSON `printf` shape every test
  function shares; `json_escape()` for free text; `latency_ms` built with
  real arithmetic, never `printf '%d000'` (constraint 9 — this shipped as a
  real bug once).
- The mesh-loop call site, gated if applicable.
- The static-target `case` arm, gated or not per the shape decision above.

**`node/build-template.sh`**
- Package list entry, verified against the live Alpine index — never
  assumed (constraint 14's whole reason for existing).
- A package-notes comment explaining any non-obvious choice (metapackage
  traps, path collisions, `*-openrc` avoidance).
- A build-time capability check, warn-don't-fail. If it validates a config
  file this project installs (not the packaged default), it must run
  *after* that install step, not alongside the other package checks.
- Service-file install (config + initd), `chmod +x` — but do **not**
  `rc-update add` here; only `setup.sh` does that, gated.
- Template cleanup — clear any per-host state the daemon accumulates
  (queue directories, machine IDs), leaving directory ownership/mode
  untouched if the daemon is picky about it.

**`node/services/<name>d.initd` + `<name>d.conf`** (new files, if a
daemon is involved) — mirror the closest existing pair line for line:
RAM guards sized for a 128MB node, not interface-bound (the inside NIC's
identity isn't known until DHCP on a clone), a comment on every
non-default directive, and — if security review found something
structural — that guarantee stated as the file's first comment, not buried.

**`node/scripts/setup.sh`**
- Value resolution (environment-only, no guestinfo key, matching
  `ENABLE_IPERF`/`ENABLE_SMB`'s pattern).
- Config heredoc write.
- Service-config refresh — the path that updates already-deployed nodes from
  an unpacked source tree.
- Conditional enable/start block, with an `else` branch logging why it's
  off.

**`node/config.sample`** — new `ENABLE_X=false` block matching the
existing ~9-line comment density: what it does, why this test specifically,
any safety statement, costs on a 128MB node. A commented-out tunables block
if the test has any, matching `LOSS_*`/`SMTP_*`'s style.

**`hub/app/app.py`** — add to `VALID_TESTS`. No schema change; `test_type`
is free text.

**`hub/templates/dashboard.html`** — `PAIR_TEST_TYPES`, `TYPE_LABELS`,
`TYPE_NAMES`, `COARSE_TIMING` (per the timing decision above), the
pre-results fallback column set (exclude if gated, like `smb`/`smtp`/`iperf3`
— an optional test shouldn't draw a permanently grey column before data
exists), the add-target prompt's "Valid:" string.

## The doc/agent/skill fan-out

Confirmed via two `drift-checker` passes on each of the last three
additions — every one of these needs an entry:

`CLAUDE.md` (test-type list + label line, a rationale paragraph,
servers/clients lines, project-structure services listing, and extend
constraint 14 or add a new numbered constraint if the security review found
something structural) · `README.md` (intro sentence, table) ·
`docs/BUILD_GUIDE.md` (package rationale, manual scp/chmod steps,
verification commands, test-type table + a "Why X matters" paragraph,
"Valid test names" line, troubleshooting lists) · `docs/DEPLOYMENT.md`
(checklist line) · `docs/HANDOFF.md` (a dated "Recent changes" entry — the
one file missed on the `smtp` round) · `.claude/agents/alpine-vm-builder.md`
(package list, budget bullet — recompute the honest worst-case total, don't
just append) · `.claude/agents/hub-api-developer.md` (test-types line, shim
list) · `.claude/agents/drift-checker.md` (service-name set) ·
`.claude/agents/regression-tester.md` (type count, R14 package check, shim
list, a new numbered check if security review found a structural invariant
worth guarding permanently) · `.claude/agents/test-result-analyst.md`
(sample-rate section, coarse-timing note, a trap warning if success
semantics are non-obvious) · `.claude/agents/mesh-probe-diagnostician.md`
(tests-per-pair list, serves list, port list) · the three
`.claude/skills/mesh-probe-*/SKILL.md` files (config vars/services lists,
`COARSE_TIMING` enumeration, a troubleshooting subsection if the test has a
"can pass while degraded" trap).

## Which agent handles which part

`alpine-vm-builder` for every `node/` file — it verifies with real
shimmed-tool round trips. `hub-api-developer` for `hub/app/app.py` +
`hub/templates/dashboard.html` — it drives a live hub round trip. Both can
run **in parallel**, since they touch disjoint files.

Do the doc/agent/skill fan-out directly rather than delegating it — two
parallel agents both wanting to edit the same shared doc files is a real
collision risk, not a hypothetical one.

Finish with `drift-checker` (a coverage pass, not just the touched files)
and `regression-tester` (the full fixed battery) as gates before commit.
Both have found real issues on every one of the last three additions.
Never skip either.
