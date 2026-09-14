"""Configuration for the lab-tester hub."""

import os

DB_PATH = os.environ.get("HUB_DB_PATH", "hub.db")
RESULT_RETENTION_HOURS = int(os.environ.get("HUB_RESULT_RETENTION_HOURS", "24"))
# Endpoints that have not re-registered within this many hours are dropped.
# Nodes re-register every 5 minutes, so this is generously long.
STALE_ENDPOINT_HOURS = int(os.environ.get("HUB_STALE_ENDPOINT_HOURS", "6"))
PORT = int(os.environ.get("HUB_PORT", "80"))

# ---------------------------------------------------------------------------
# Syslog receiver
# ---------------------------------------------------------------------------
SYSLOG_ENABLED = os.environ.get("HUB_SYSLOG_ENABLED", "true").lower() in ("true", "1", "yes")
SYSLOG_BIND = os.environ.get("HUB_SYSLOG_BIND", "0.0.0.0")
# 514 is privileged, so the hub must start as root to bind it. Overridable
# mainly so a non-root test run can use something above 1024.
SYSLOG_PORT = int(os.environ.get("HUB_SYSLOG_PORT", "514"))
# Row cap, not a time window: a debug-level network device can outpace any
# retention period, and the cap is what actually bounds the file. Enforced
# every 500 inserts by syslog_server, by id range — see the note there.
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
