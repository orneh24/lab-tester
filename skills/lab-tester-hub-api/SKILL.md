---
name: lab-tester-hub-api
description: The lab-tester hub contract — Flask endpoints, SQLite schema, result JSON shape, and dashboard data flow. Read before changing hub/app/app.py, adding an API route, altering the results schema, or touching anything a node posts to.
origin: lab-tester
---

# Lab-Tester Hub API

The hub (`hub/app/app.py`) is the single source of truth for endpoints and results. Nodes are dumb clients: they register, pull the mesh list, test, and push. Any change to the shapes below is a breaking change for every deployed golden image.

## When to Activate

- Adding or changing a route in `hub/app/app.py`
- Changing the `endpoints` or `results` table
- Changing what `test-cycle.sh` or `register.sh` sends
- Writing dashboard code that consumes `/api/results`

## Contract (do not break without reflashing nodes)

`POST /register` — body must contain all four:

```json
{"hostname": "node-1", "ip": "10.1.1.50", "subnet": "10.1.1.0/24", "group_name": "site-a"}
```

Upsert keyed on `hostname`; `last_seen` is set server-side to UTC ISO-8601. Missing any field → 400.

`GET /endpoints` — array of `{hostname, ip, subnet, group_name, last_seen}`, ordered by group then hostname. Nodes skip their own hostname when iterating.

`POST /results`:

```json
{"source": "node-1", "results": [{
  "target_hostname": "node-2", "target_ip": "10.2.1.50",
  "test_type": "http", "success": true, "latency_ms": 12.4,
  "output": "HTTP 200 in 0.012s", "timestamp": "2026-01-01T00:00:00Z"
}]}
```

`success` is stored as INTEGER 0/1. `latency_ms` is REAL and may be null. `output` is free text (traceroute dumps land here — keep it, the dashboard drill-down reads it). Empty `results` or missing `source` → 400.

`DELETE /endpoints/<hostname>` — for stale clones. 404 if unknown.

`GET /api/results?minutes=N` (default 10) — dashboard matrix. `GET /api/results/<source>/<target>` — drill-down, newest first, LIMIT 200.

## Syslog

The hub also receives syslog on UDP/514 (`hub/app/syslog_server.py`, started by `serve.py`'s `main()` — deliberately not at import time, since the Flask reloader imports `app.app` twice and would double-start the listener). It is a separate ingest path from the test results and has no wire contract with the nodes — network devices (switches, firewalls, anything that speaks RFC3164) are the senders, and sending to it is entirely optional.

- `GET /api/syslog` — newest first. Params: `minutes` (default 60), `from`/`to` (UTC ISO-8601, used by the dashboard drill-down links and mutually exclusive with `minutes`), `severity` (maximum, 0–7), `host` (a single value, matched against parsed hostname OR source IP — not a list), `q` (substring of message/mnemonic/raw), `limit` (default and cap both 2000).
- `GET /api/syslog/sources` — distinct senders with counts, for the filter dropdown.
- `GET /syslog` — the page. A `from`/`to` pair pins the view and disables auto-refresh.

Storage rules that differ from `results`:

- Identity is the parsed hostname with the source IP as fallback; there is no IP→device map. A device whose syslog hostname differs from a node's `GROUP_NAME` label will not match the dashboard's filtered link — the unfiltered ±5 min link is the reliable one.
- Row cap only (`HUB_SYSLOG_MAX_ROWS`, default 300000), enforced every 500 inserts by an id-range delete. There is no time-based pruning, so the table can hold anything from an hour to a month depending on volume. Actual row count can exceed the cap by up to 500 between prunes.
- The listener is one thread with its own connection (`check_same_thread=False`, guarded by a lock). Do not reuse `get_db()` there — it is request-scoped via `g`.
- Unparseable lines are stored with `raw` intact and null severity/mnemonic. Never drop a message because it did not parse.
- Starting is idempotent: a second call sees the started flag, and a second process (Flask reloader) fails to bind and logs instead of crashing.

## Time

The hub runs chrony to discipline **its own** clock, which matters because the
hub stamps every `received_at` and those stamps are what results and syslog are
filtered and correlated on. It is **not an NTP server**: `build-template.sh`
installs chrony and enables `chronyd` and configures nothing further — there is
no access list and no `set-ntp-clients`. Point nodes and any logging network
devices at real upstream time. The app exposes the hub's own state:

- `GET /api/time` — always returns the hub's UTC time; `chrony` is null with a
  `reason` when `chronyc` is missing or fails. Parsed from `chronyc -n tracking`
  with a short timeout; never let it block a request longer than that. Every
  failure path returns 200 — see R21 in `regression-tester`.
- `local_only` means chrony is serving its own clock (refid `7F7F…`), which is
  normal in an isolated lab. It is reported independently of `synced`.
- The `/syslog` header renders this: green when synced to an upstream and within
  100 ms, yellow for local-clock or larger offset, red for unsynchronised.

Clock correctness is not cosmetic here — `/api/results` and `/api/syslog` both
filter on UTC text comparison, so skew makes rows invisible rather than wrong.

## Schema Rules

- `endpoints.hostname` is PRIMARY KEY — hostnames must be unique per clone. A duplicated hostname silently overwrites another node's registration; that is the most common cause of a "missing" node in the matrix.
- `results` is append-only. Never UPDATE a row; the timeline depends on immutability.
- Indexes exist on `received_at` and `(source, target_hostname)` for results, and on `received_at` and `host` for syslog. Any new query should use one of them or add its own index.
- **Everything is stored in SQLite's own format, `YYYY-MM-DD HH:MM:SS`, and windows are `datetime('now', ...)`.** Write it with `sqlite_now()`; convert with `iso()` on the way out so browsers parse it as UTC. This is the opposite of what an earlier version of this file said, and the reason it matters is that the two formats sort against each other: `T` (0x54) is above space (0x20), so string-comparing an ISO timestamp against a `datetime('now', ...)` bound lets **every row from the same UTC date** through any window. See CLAUDE.md constraints 2 and 18.
- The client's own `timestamp` field stays ISO-8601 and is passed through untouched — it is a record, never a filter. Filter on `received_at`, which the hub controls and which is immune to node clock drift.
- Results are pruned **by age** (`HUB_RESULT_RETENTION_HOURS`), syslog **by row count** (`HUB_SYSLOG_MAX_ROWS`, id-range delete). They are bounded differently on purpose: see Retention below.
- Set `PRAGMA busy_timeout` on any new connection. The syslog receiver is a second writer; without it a result submission during a burst fails with `database is locked` and the node loses that whole cycle.

## Adding a Test Type

A new test type needs no schema change — `test_type` is free text. Add the producer in `node/scripts/test-cycle.sh` and teach the dashboard to render it. Keep the type string lowercase and stable. `VALID_TESTS` in `app.py` is the authoritative set; it must agree with what `test-cycle.sh` emits and with `TYPE_LABELS` in the dashboard, and the regression suite's Tier 3 checks exactly that three-way agreement. Also decide `COARSE_TIMING` deliberately: whole-second `date +%s` timing (ssh/traceroute/pmtu/dns/iperf3/smb/smtp) goes in it, real sub-second precision (http, loss) does not — adding a fine-grained type to `COARSE_TIMING` by copy-paste habit silently throws away its resolution.

## Retention

**Retention already runs, at request time, and must stay there.** `push_results()` calls `prune_old_results(db)` on every `POST /results`, and `list_endpoints()` prunes stale endpoints the same way. There is deliberately no cron on the hub — an opportunistic indexed DELETE on each push is cheap at this scale, and it cannot silently stop running the way a cron entry can. ~100k result rows/day at 5 nodes makes this load-bearing, not housekeeping.

Do not "improve" this into a scheduled job: CLAUDE.md constraint 8 exists because the unpruned version already filled a disk once. An earlier version of this file recommended exactly that change, which is how it got written down as a warning.

## Config

Every hub setting is an env var with a default. **Read `hub/app/config.py` for the list** — it is short, and any copy of it here would be wrong within a release. Two things that file will not tell you:

- The bind address is `HUB_HOST`, read directly in `hub/serve.py`, not through `config.py`.
- A new setting must be added to the `hub.env` block in `hub/build-template.sh` in the same change. A setting with nowhere to set it at deploy time is not configurable in practice.

`set-static-ip` manages one interface and rewrites `/etc/network/interfaces` wholesale, so a second NIC is a hand-edit if you ever need one. Nothing pins `net.ipv4.ip_forward=0` either — Alpine's default is 0, but the build does not assert it. `HUB_SYSLOG_BIND` lets you restrict the UDP listener to one address if the hub ever grows a second interface.

`serve.py` reads `HUB_PORT` **at runtime**, and the init script sources `hub.env` in `start_pre`. Do not move a setting into the init script's `command_args`: OpenRC expands those at parse time, before `start_pre` runs, so the value in `hub.env` would be ignored. That ordering is why `serve.py` exists rather than invoking flask or waitress directly.

## Anti-Patterns

```
# BAD: renaming a JSON field on the hub without rebuilding the golden image
# Deployed nodes post the old field names forever; results go silently empty.

# BAD: returning 200 on a malformed payload
# Nodes only check the HTTP code; a lenient hub hides broken clients.

# BAD: SELECT * in dashboard queries
# The dashboard depends on column order/names; list them explicitly.

# BAD: writing timestamps with local time
# Breaks the ?minutes= window without any error.
```

## Related Skills

- lab-tester-node
- lab-tester-troubleshooting
