"""Configuration for the lab-tester hub."""

import os

DB_PATH = os.environ.get("HUB_DB_PATH", "hub.db")
TEST_INTERVAL = int(os.environ.get("HUB_TEST_INTERVAL", "60"))
RESULT_RETENTION_HOURS = int(os.environ.get("HUB_RESULT_RETENTION_HOURS", "24"))
# Endpoints that have not re-registered within this many hours are dropped.
# Test VMs re-register every 5 minutes, so this is generously long.
STALE_ENDPOINT_HOURS = int(os.environ.get("HUB_STALE_ENDPOINT_HOURS", "6"))
PORT = int(os.environ.get("HUB_PORT", "80"))
DEBUG = os.environ.get("HUB_DEBUG", "false").lower() in ("true", "1", "yes")

# ---------------------------------------------------------------------------
# Syslog receiver
# ---------------------------------------------------------------------------
SYSLOG_ENABLED = os.environ.get("HUB_SYSLOG_ENABLED", "true").lower() in ("true", "1", "yes")
SYSLOG_BIND = os.environ.get("HUB_SYSLOG_BIND", "0.0.0.0")
# 514 is privileged, so the hub must start as root to bind it. Overridable
# mainly so a non-root test run can use something above 1024.
SYSLOG_PORT = int(os.environ.get("HUB_SYSLOG_PORT", "514"))
# Row cap, not a time window: a debug-level router can outpace any retention
# period, and the cap is what actually bounds the file. Enforced every 500
# inserts by syslog_server, by id range — see the note there.
SYSLOG_MAX_ROWS = int(os.environ.get("HUB_SYSLOG_MAX_ROWS", "300000"))

# The syslog listener is a *second writer* against the same SQLite file as the
# results API. Without a busy timeout on both, a message burst makes a
# concurrent result POST fail outright with "database is locked" — the mesh
# losing data exactly when the lab is noisy enough to be interesting. WAL
# allows one writer at a time; this makes the loser wait instead of erroring.
BUSY_TIMEOUT_MS = int(os.environ.get("HUB_BUSY_TIMEOUT_MS", "5000"))

# ---------------------------------------------------------------------------
# Hub self-health (/api/health)
# ---------------------------------------------------------------------------
# OpenRC services to report on, comma-separated. Queried with
# `rc-service <name> status`, same subprocess pattern as /api/time's chronyc
# call — missing binary, timeout, or non-zero exit all degrade to a per-service
# "unknown" rather than failing the whole endpoint.
HEALTH_SERVICES = [
    s.strip() for s in os.environ.get(
        "HUB_HEALTH_SERVICES", "lab-tester-hub,chronyd,dropbear,open-vm-tools,lldpd"
    ).split(",") if s.strip()
]
HEALTH_SERVICE_TIMEOUT_S = int(os.environ.get("HUB_HEALTH_SERVICE_TIMEOUT_S", "3"))

# ---------------------------------------------------------------------------
# SNMP polling (routers' interface counters)
# ---------------------------------------------------------------------------
# Opt-in, per explicit requirement — false means the poller thread must not
# start at all, not a graceful degrade-to-no-op. See snmp_poller.start().
SNMP_ENABLED = os.environ.get("HUB_SNMP_ENABLED", "false").lower() in ("true", "1", "yes")

# The hub's address on the management NIC (docs/DEPLOYMENT.md's "hub NIC2"),
# the one the routers' SNMP ACL is restricted to. Every outgoing SNMP packet
# must be source-bound to this address specifically — never the data-plane
# NIC the rest of the hub listens on. No default: if SNMP_ENABLED is true and
# this is empty, snmp_poller.start() refuses to start and logs loudly, rather
# than silently sourcing from whatever interface the OS route table picks.
MGMT_IP = os.environ.get("HUB_MGMT_IP", "").strip()

# Default community, used when a row in snmp_targets doesn't override it.
SNMP_COMMUNITY = os.environ.get("HUB_SNMP_COMMUNITY", "public")
SNMP_POLL_INTERVAL = int(os.environ.get("HUB_SNMP_POLL_INTERVAL", "60"))
SNMP_TIMEOUT_S = int(os.environ.get("HUB_SNMP_TIMEOUT_S", "3"))
# Mirrors RESULT_RETENTION_HOURS's default for consistency across the two
# "the hub polls/receives and must eventually forget" tables.
SNMP_RETENTION_HOURS = int(os.environ.get("HUB_SNMP_RETENTION_HOURS", "24"))
