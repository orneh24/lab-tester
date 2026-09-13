---
name: lab-tester-troubleshooting
description: Diagnosing lab-tester failures end to end — blank dashboard cells, missing endpoints, one-way test failures, and separating a real CSR1000v routing/ACL problem from a broken test VM. Read when results look wrong rather than when code is being changed.
origin: lab-tester
---

# Lab-Tester Troubleshooting

The system reports failures it cannot explain. This is the order to work through them so that a lab problem (the interesting case) is not confused with a harness problem (the common case).

## When to Activate

- The dashboard shows empty cells, stale data, or a whole missing row/column
- A pair fails in one direction only
- HTTP fails but ICMP works, or traceroute stops mid-path
- A newly cloned VM never appears

## Triage Order

1. **Is the endpoint registered?** `curl http://<hub>/endpoints` — check the VM is listed and `last_seen` is recent. Absent or stale → registration problem, not connectivity.
2. **Is data arriving?** `curl 'http://<hub>/api/results?minutes=10'`. Rows present but the matrix looks empty → time-window/timestamp problem, not a network problem.
3. **Is the cycle running?** On the VM: `tail /var/log/lab-tester/test-cycle.log` and `tail /var/log/lab-tester/register.log`.
4. **Only then** treat it as a lab connectivity issue and look at the routers.

## Missing Endpoint

- Duplicate hostname — two clones with the same name overwrite each other in `endpoints`. Check for a `last_seen` that jumps between IPs.
- DHCP lease not obtained: `ip -4 -o addr show scope global` returns nothing → `register.sh` exits before POSTing.
- `HUB_URL` wrong or has a trailing slash; hub unreachable from that subnet.
- Config missing: `/etc/lab-tester/config` absent → both scripts exit 1 immediately.
- Stale entry from a decommissioned clone: `DELETE /endpoints/<hostname>`.

## "Not Reporting" — and where amber actually lives

**The matrix has three states only: green pass, red fail, grey no-data.** There
is no amber cell. Amber appears in the separate **Endpoints** list, on a row
whose `last_seen` is over 5 minutes old — registration staleness, not a test
result.

So a VM that stops submitting shows up as grey cells (no new results) *and* an
amber endpoint row (no new registrations), and the two can disagree: cron
stopped but the VM alive keeps registering every 5 minutes, so the endpoint row
stays normal while its cells go grey. That split is diagnostic — grey cells with
a healthy endpoint row means the test cycle specifically, not the VM.

Either way it is a test-VM problem first: cron, config, or the VM being down. Go
to the VM logs before looking at the network.

## Blank or Stale Cells

- **Not a client-clock problem.** `/api/results` filters on `received_at`, which the hub stamps itself with `sqlite_now()` when the batch arrives. The client's own `timestamp` is stored as a record and never used for windowing, so neither a skewed VM clock nor an odd timestamp format can empty a window. Do not start here — this dead end cost real time before the hub took over stamping.
- Malformed JSON in the payload (unescaped output) → hub 400, whole cycle's results lost. Look for `failed to submit results` in the log.
- Cycle overrunning 60 s (many endpoints × timeouts) → cron runs overlap and results arrive irregularly.
- Rejected payloads — the batch was posted and refused, so the cycle ran and
  recorded nothing. Look for a non-200 on `POST /results` in the hub log, and
  for `failed to submit results` on the VM. A single bad record fails the whole
  batch (CLAUDE.md constraints 9 and 19), so the symptom is a whole cycle
  missing, not one cell.
- **The hub's own clock still matters, for correlation only.** Check
  `/api/time` or the indicator in the `/syslog` header: a ±5 min window pinned
  around a `received_at` is only meaningful if the hub is disciplined. A red
  indicator means every correlation on that page is suspect — but it does not
  explain a blank matrix, which is windowed on the same clock that stamped the
  rows.

## One-Way Failures

A failing direction with a working reverse points at the *target*, not the path:

- Target's server is down — dropbear, busybox httpd, iperf3, or (if `ENABLE_SMB=true`/`ENABLE_SMTP=true`) `lab-smbd`/`lab-smtpd` not started. Verify locally on the target first: `nc -z <ip> 22 25 80 445 5201` from a neighbour.
- Target firewalled at the host level (Alpine default has none — if `iptables` rules exist, someone added them).
- If both directions fail for every pair crossing one router, and traceroute dies at that hop, it is a router problem.
- Before concluding it's the router, check `lldpcli show neighbors` on the VM (always-on, not gated) — a VM on the wrong vSwitch port group registers and often still gets a DHCP lease, but is plugged into the wrong place entirely.
- If SNMP polling is on, check the dashboard's "Router SNMP" panel for nonzero interface errors/discards on the routers behind the pair — a queueing/physical problem that a clean `show ip access-lists` won't explain.

## `loss` Reads Differently Than the Other Types

Its `success` field is `true` on any reply at all — a pair silently losing 30% of packets every cycle still shows `success: true` on every `loss` row. The loss percentage and jitter live in `output` (the `%loss`/`min/avg/max` text), not in `success`. When a link "passes" every test but users report intermittent slowness, `loss`'s `output` is the first place to look — everything else here is binary pass/fail and won't show it.

## `smtp` Can Pass While Being Rewritten

Its `success` field gates on the banner + `EHLO` response only — a real relay correctly rejecting the probe's `RCPT TO:<probe@lab.invalid>` with `550` still reads `success: true`, and that's expected, not a bug to chase. The signal worth reading is in `output`: if the EHLO capability list comes back with tokens masked as runs of `X` (e.g. `250-XXXXXXXX` instead of `250-STARTTLS`), a device on the path — most likely Cisco ESMTP inspection or an ASA ESMTP fixup — is rewriting the session in flight, not blocking it. That's a `success: true` row that still deserves attention. This is exactly the class of fault `smtp` exists to catch: `smb`/`loss`/`pmtu` all catch a path that drops or degrades traffic, but nothing else here catches one that silently edits it.

## Reading Traceroute Output

The stored `output` is the full traceroute. The last hop matching the target IP is what marks success. Useful patterns:

- Stops at the local router's inside interface → return route or inside ACL.
- Reaches the far router's outside interface then stops → inside interface down, or ACL blocking into the inside subnet.
- Alternating hops → asymmetric routing between the CSRs.

## Syslog Is Empty

The hub collects router syslog on UDP/514 and shows it at `/syslog`. When it is
empty, work down this order — the failure is nearly always configuration, not the
network:

1. Receiver running? At service start the hub logs
   `[syslog] listening on <bind>:<port>`. A line saying it could not bind means a
   second process holds the port (usually the Flask reloader).
2. Packets arriving? `tcpdump -ni any udp port 514` on the hub.
3. Bound where they land? `HUB_SYSLOG_BIND` pinned to the management NIC means
   packets arriving on the other NIC are ignored by design.
4. Router side: `show logging | include <hub-ip>`. After a VRF change the usual
   cause is a `logging host` line without `vrf MGMT` — the router looks the hub up
   in the global table, finds nothing, and reports no error.

Absence of syslog is never evidence about the data path: UDP syslog is lossy and
unauthenticated. Use it to corroborate a failure window, never to rule one out.

## Management Separation Has Leaked

If management interfaces share a VLAN without a VRF, the routers gain a path to
each other that is not the topology under test, and inter-subnet test traffic can
take it. The matrix then reports success while measuring the management VLAN.

Symptoms: pairs that should traverse two routers pass with implausibly low
latency; traceroute hop lists contain management addresses; a link you shut down
produces no failures at all.

Check:

```
show ip route <target-inside-subnet>   ! global table must not resolve via a mgmt interface
show ip route vrf MGMT                 ! mgmt subnet and default only
```

And in stored results, any management IP appearing in a traceroute `output` is
proof the separation is gone.

## Router-Side Checks (CSR1000v)

Once the harness is exonerated, on the relevant router:

```
show ip interface brief
show ip route <target-subnet>
show ip access-lists
show logging | include denied
debug ip icmp        ! sparingly, and undebug all afterwards
```

Test type matters: ICMP passing while TCP/80 fails is almost always an ACL permitting `icmp` but not `tcp eq www`. iperf3 needs 5201/tcp open in both directions; smb needs 445/tcp open in both directions; smtp needs 25/tcp open in both directions.

## Hub-Side Checks

- Hub is not a test participant — it never appears in the matrix, and that is correct.
- SQLite is WAL mode; a hub whose disk is full accepts nothing and returns 500s. Check disk before blaming the network.
- `HUB_DEBUG` is currently inert — read into `config.DEBUG` and acted on nowhere. What does matter is that `serve.py` falls back to Flask's single-threaded dev server when `waitress` cannot be imported, and a long request there blocks collection from every VM. Check the hub log's first lines for that fallback warning.

## Anti-Patterns

```
# BAD: debugging routers before checking /endpoints and the VM logs
# The harness fails far more often than the lab does.

# BAD: concluding "the network is down" from an empty matrix
# An empty matrix is usually a timestamp, hostname, or JSON problem.

# BAD: restarting VMs to fix registration
# It hides the cause; register.sh already retries and logs why.
```

## Related Skills

- lab-tester-hub-api
- lab-tester-test-vm
- network-interface-health
- performing-network-packet-capture-analysis
