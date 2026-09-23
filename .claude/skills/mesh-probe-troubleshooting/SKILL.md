---
name: mesh-probe-troubleshooting
description: Diagnosing mesh-probe failures end to end — blank dashboard cells, missing endpoints, one-way test failures, and separating a genuine network problem from a broken node. Read when results look wrong rather than when code is being changed.
origin: mesh-probe
---

# Mesh-Probe Troubleshooting

The system reports failures it cannot explain. This is the order to work through them so that a lab problem (the interesting case) is not confused with a harness problem (the common case).

## When to Activate

- The dashboard shows empty cells, stale data, or a whole missing row/column
- A pair fails in one direction only
- HTTP fails but ICMP works, or traceroute stops mid-path
- A newly cloned node never appears

## Triage Order

1. **Is the endpoint registered?** `curl http://<hub>/endpoints` — check the node is listed and `last_seen` is recent. Absent or stale → registration problem, not connectivity.
2. **Is data arriving?** `curl 'http://<hub>/api/results?minutes=10'`. Rows present but the matrix looks empty → time-window/timestamp problem, not a network problem.
3. **Is the cycle running?** On the node: `tail /var/log/mesh-probe/test-cycle.log` and `tail /var/log/mesh-probe/register.log`.
4. **Only then** treat it as a genuine network problem between the nodes.

## Missing Endpoint

- Duplicate hostname — two clones with the same name overwrite each other in `endpoints`. Check for a `last_seen` that jumps between IPs.
- DHCP lease not obtained: `ip -4 -o addr show scope global` returns nothing → `register.sh` exits before POSTing.
- `HUB_URL` wrong or has a trailing slash; hub unreachable from that subnet.
- Config missing: `/etc/mesh-probe/config` absent → both scripts exit 1 immediately.
- Stale entry from a decommissioned clone: `DELETE /endpoints/<hostname>`.

## "Not Reporting" — and where amber actually lives

**The matrix has three states only: green pass, red fail, grey no-data.** There
is no amber cell. Amber appears in the separate **Endpoints** list, on a row
whose `last_seen` is over 5 minutes old — registration staleness, not a test
result.

So a node that stops submitting shows up as grey cells (no new results) *and*
an amber endpoint row (no new registrations), and the two can disagree: cron
stopped but the node alive keeps registering every 5 minutes, so the endpoint
row stays normal while its cells go grey. That split is diagnostic — grey
cells with a healthy endpoint row means the test cycle specifically, not the
node.

Either way it is a node problem first: cron, config, or the node being down.
Go to the node logs before looking at the network.

## Blank or Stale Cells

- **Not a client-clock problem.** `/api/results` filters on `received_at`, which the hub stamps itself with `sqlite_now()` when the batch arrives. The client's own `timestamp` is stored as a record and never used for windowing, so neither a skewed node clock nor an odd timestamp format can empty a window. Do not start here — this dead end cost real time before the hub took over stamping.
- Malformed JSON in the payload (unescaped output) → hub 400, whole cycle's results lost. Look for `failed to submit results` in the log.
- Cycle overrunning 60 s (many endpoints × timeouts) → cron runs overlap and results arrive irregularly.
- Rejected payloads — the batch was posted and refused, so the cycle ran and
  recorded nothing. Look for a non-200 on `POST /results` in the hub log, and
  for `failed to submit results` on the node. A single bad record fails the
  whole batch (CLAUDE.md constraints 9 and 19), so the symptom is a whole
  cycle missing, not one cell.
- **The hub's own clock still matters, for correlation only.** Check
  `/api/time` or the indicator in the `/syslog` header: a ±5 min window pinned
  around a `received_at` is only meaningful if the hub is disciplined. A red
  indicator means every correlation on that page is suspect — but it does not
  explain a blank matrix, which is windowed on the same clock that stamped the
  rows.

## One-Way Failures

A failing direction with a working reverse points at the *target*, not the path:

- Target's server is down — dropbear, busybox httpd, iperf3, or (if `ENABLE_SMB=true`/`ENABLE_SMTP=true`) `mesh-probe-smbd`/`mesh-probe-smtpd` not started. Verify locally on the target first: `nc -z <ip> 22 25 80 445 5201` from a neighbour.
- Target firewalled at the host level (Alpine default has none — if `iptables` rules exist, someone added them).
- If both directions fail for every pair crossing one point in the network, and traceroute dies at that hop, that is a real network problem — outside this harness, and the concern of whatever project owns the routing/switching in the lab.
- Before concluding it's the network, check `lldpcli show neighbors` on the node (always-on, not gated) — a node on the wrong vSwitch port group registers and often still gets a DHCP lease, but is plugged into the wrong place entirely.

## `loss` Reads Differently Than the Other Types

Its `success` field is `true` on any reply at all — a pair silently losing 30% of packets every cycle still shows `success: true` on every `loss` row. The loss percentage and jitter live in `output` (the `%loss`/`min/avg/max` text), not in `success`. When a link "passes" every test but users report intermittent slowness, `loss`'s `output` is the first place to look — everything else here is binary pass/fail and won't show it.

## `smtp` Can Pass While Being Rewritten

Its `success` field gates on the banner + `EHLO` response only — a real relay correctly rejecting the probe's `RCPT TO:<probe@mesh-probe.invalid>` with `550` still reads `success: true`, and that's expected, not a bug to chase. The signal worth reading is in `output`: if the EHLO capability list comes back with tokens masked as runs of `X` (e.g. `250-XXXXXXXX` instead of `250-STARTTLS`), a device on the path — an SMTP ALG or ESMTP inspection engine, common on firewalls and NAT gateways — is rewriting the session in flight, not blocking it. That's a `success: true` row that still deserves attention. This is exactly the class of fault `smtp` exists to catch: `smb`/`loss`/`pmtu` all catch a path that drops or degrades traffic, but nothing else here catches one that silently edits it.

## Reading Traceroute Output

The stored `output` is the full traceroute. The last hop matching the target IP is what marks success. Useful patterns:

- Stops at a fixed point every time → a device or ACL on the path that isn't forwarding past it.
- Reaches partway then times out → asymmetric routing, or a return path that differs from the forward one.
- Alternating hops across cycles → asymmetric routing between two paths in the network under test.

## Syslog Is Empty

The hub can optionally collect syslog from network devices on UDP/514 and show
it at `/syslog`. When it is empty, work down this order — the failure is
nearly always configuration, not the network:

1. Receiver running? At service start the hub logs
   `[syslog] listening on <bind>:<port>`. A line saying it could not bind means a
   second process holds the port (usually the Flask reloader).
2. Packets arriving? `tcpdump -ni any udp port 514` on the hub.
3. Bound where they land? `HUB_SYSLOG_BIND` pinned to one address means
   packets arriving on another interface are ignored by design.
4. Sender side: confirm the device is actually configured to log to the hub's
   IP, on the reachable interface/routing table — a common cause is a logging
   source bound to an interface that has no route to the hub.

Absence of syslog is never evidence about the data path: UDP syslog is lossy and
unauthenticated. Use it to corroborate a failure window, never to rule one out.

## Hub-Side Checks

- Hub is not a test participant — it never appears in the matrix, and that is correct.
- SQLite is WAL mode; a hub whose disk is full accepts nothing and returns 500s. Check disk before blaming the network.
- `serve.py` falls back to Flask's single-threaded dev server when `waitress` cannot be imported, and a long request there blocks collection from every node. Check the hub log's first lines for that fallback warning.

## Anti-Patterns

```
# BAD: debugging the network before checking /endpoints and the node logs
# The harness fails far more often than the lab does.

# BAD: concluding "the network is down" from an empty matrix
# An empty matrix is usually a timestamp, hostname, or JSON problem.

# BAD: restarting nodes to fix registration
# It hides the cause; register.sh already retries and logs why.
```

## Related Skills

- mesh-probe-hub-api
- mesh-probe-node
