# Lab-Tester — Quick Start

One page, for an experienced sysadmin who wants the commands and reference
tables, not the tutorial. Full rationale: `CLAUDE.md`. Full checklist with
verification steps: `DEPLOYMENT.md`. Step-by-step detail: `BUILD_GUIDE.md`.

Out of scope: the network between nodes (routers/switches/firewalls) —
that's a separate project. This assumes the network already exists and is
reachable.

## Deploy

```sh
# base VM: setup-alpine, then git clone the repo, then clone the VM twice
apk add --no-cache git && git clone https://github.com/orneh24/lab-tester.git /root/lab-tester

# Hub (build first — its IP gets baked into the node image)
sh /root/lab-tester/hub/build-template.sh
set-static-ip <hub-ip>/<cidr> <gateway>   # or guestinfo.hub.ip/.gateway pre-boot
rc-service networking restart
rc-service lab-tester-hub start

# Node golden image
sh /root/lab-tester/node/build-template.sh
vi /etc/lab-tester/config   # HUB_URL, GROUP_NAME, SUBNET — all three required
/usr/local/bin/lab-tester/setup.sh
# verify it registers, THEN undo that (it recreated the config and
# hostname the build script had just cleared) before sealing the image:
rm -f /etc/lab-tester/config /etc/lab-tester/.firstboot-done
printf 'lab-tester-template\n' > /etc/hostname
# now shut down, convert to vCenter template

# Per node clone: set a unique hostname, then
register.sh
```

Duplicate hostnames silently collide (`endpoints.hostname` is the primary
key) — that's the one per-clone step that must not be skipped.

## Ports and services

| What | Where | Port |
|---|---|---|
| Dashboard / API | hub, `lab-tester-hub` (waitress) | 80 |
| Syslog receiver (optional, UDP) | hub, same process, daemon thread | 514 |
| HTTP test target | node, `lab-httpd` | 80 |
| SSH test target | node, dropbear | 22 |
| SMB test target (opt-in) | node, `lab-smbd` | 445 |
| SMTP test target (opt-in) | node, `lab-smtpd` | 25 |
| iperf3 (opt-in) | node | 5201 |

Hub files: app at `/opt/lab-tester-hub/`, env at
`/opt/lab-tester-hub/hub.env`, DB at `/var/lib/lab-tester/hub.db`.
Node files: scripts at `/usr/local/bin/lab-tester/`, config at
`/etc/lab-tester/config`.

## Hub config (`hub.env`)

| Key | Default | Notes |
|---|---|---|
| `HUB_PORT` | 80 | read at runtime by `serve.py` — don't move into the initd `command_args` |
| `HUB_DB_PATH` | `hub.db` | set explicitly; importing `app.app` runs `init_db()` at module scope |
| `HUB_RESULT_RETENTION_HOURS` | 24 | swept on each `POST /results`, no cron |
| `HUB_STALE_ENDPOINT_HOURS` | 6 | endpoints unseen this long are dropped from `/endpoints` |
| `HUB_SYSLOG_ENABLED` | true | |
| `HUB_SYSLOG_BIND` | `0.0.0.0` | |
| `HUB_SYSLOG_PORT` | 514 | needs root; use >1024 for a manual `run.sh` |
| `HUB_SYSLOG_MAX_ROWS` | 300000 | row cap, not time-based |
| `HUB_BUSY_TIMEOUT_MS` | 5000 | syslog writer and results API share the DB |
| `HUB_HEALTH_SERVICES` | `lab-tester-hub,chronyd,dropbear,open-vm-tools,lldpd` | polled for `/api/health` |
| `LAB_ROOT_PASSWORD` | `lab123` | read by `build-template.sh` only, not at runtime |

## Node config (`/etc/lab-tester/config`)

| Key | Required | Notes |
|---|---|---|
| `HUB_URL` | yes | no trailing slash |
| `GROUP_NAME` | yes | operator label, clusters the dashboard and filters syslog — no topology meaning |
| `SUBNET` | yes | CIDR |
| `LAB_HOSTNAME` | no | must be unique across the lab; derived from `GROUP_NAME` if empty |
| `DNS_SERVER` | no | unset skips the DNS test entirely |
| `ENABLE_IPERF` / `ENABLE_SMB` / `ENABLE_SMTP` | no | default false; each starts its own OpenRC service |
| `AGENT_AUTOUPDATE` | no | default true; self-updates `test-cycle.sh` on each 5-min registration |

`register.sh` `exit 1`s on the first of `HUB_URL`/`GROUP_NAME`/`SUBNET` that's
empty — nothing is derived. A node missing one just never appears; there's
no error to see.

## Verify

```sh
curl http://<hub-ip>/api/health         # never 500s — check the body, not just the code
curl http://<hub-ip>/api/time           # chrony tracking state
curl http://<hub-ip>/endpoints          # who's registered
curl 'http://<hub-ip>/api/results?minutes=5'
curl 'http://<hub-ip>/api/syslog?minutes=5'   # [] is fine; an error means the listener didn't start
```

Dashboard: `http://<hub-ip>/`. Syslog viewer: `http://<hub-ip>/syslog`.

## Routine admin

**Static targets** (gateways, loopbacks, outside hosts — no agent to install):

```sh
curl -X POST http://<hub-ip>/targets -H 'Content-Type: application/json' \
  -d '{"name":"gw-a","ip":"10.1.1.1","tests":["traceroute","pmtu"]}'
curl http://<hub-ip>/targets
curl -X DELETE http://<hub-ip>/targets/gw-a
```

Valid test types: `http ssh traceroute pmtu dns iperf3 smb loss smtp`. Only
declare what the target actually answers — a loopback has no HTTP server.

**Point a network device's syslog at the hub:** UDP/514, RFC3164, that's it.
Point its NTP at real upstream, not the hub — the hub disciplines its own
clock only, it serves time to nobody.

**A node stopped reporting:** amber in the Endpoints list (`last_seen` >5
min), matrix cells fade grey (not red — grey means no data, not failure).
Check that node's `/var/log/lab-tester/` before the network.

**Remove a dead endpoint:** `curl -X DELETE http://<hub-ip>/endpoints/<hostname>`

**Enable an optional test on a node already deployed:** edit
`/etc/lab-tester/config`, restart cron isn't needed (next 60s cycle picks it
up), but start the matching service by hand if it isn't running yet
(`rc-service lab-smbd start` / `lab-smtpd start`).

**Hub or node logs:** hub under OpenRC's log for `lab-tester-hub`; nodes at
`/var/log/lab-tester/`.

## Traps

| Trap | Symptom |
|---|---|
| Golden image built before the hub had its final IP | every clone has the wrong `HUB_URL` |
| Duplicate node hostname | one node silently overwrites another's registration |
| Verified registration on the golden image, sealed it without re-cleaning | every clone starts with that verification run's real hostname/`GROUP_NAME`/`SUBNET` baked in — same collision as above, from clone one |
| `ENABLE_SMB`/`ENABLE_SMTP` set but service never started | test never runs, no red cell — just absent |
| Static target declares a test it can't answer | permanent red for that pair |
