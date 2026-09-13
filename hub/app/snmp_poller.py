"""Background SNMPv2c poller for the CSR1000v routers' interface counters.

Structured like syslog_server.py: an idempotent start() that spawns one
daemon thread, and a never-crash discipline inside the loop — one bad router
degrades that router's row, never the round, never the thread.

The hard requirement this whole module exists to satisfy: every outgoing
SNMP packet must be source-bound to HUB_MGMT_IP, the hub's address on the
management NIC the routers' SNMP ACL is restricted to. snmp_client.get()/
walk() take that address explicitly and bind to it before sending — see
snmp_client.py's module docstring for why that ruled out net-snmp's CLI
tools and pysnmp in favour of a small hand-rolled client.

This is also a *third* writer against the hub's SQLite file, after the Flask
request handlers and the syslog listener — same busy_timeout requirement as
constraint 17, applied to this thread's own connection.
"""

import sqlite3
import sys
import threading
import time
from datetime import datetime, timezone

from . import config
from . import snmp_client

SYSNAME_OID     = "1.3.6.1.2.1.1.5.0"
IFDESCR_BASE    = "1.3.6.1.2.1.2.2.1.2"
HC_IN_OCTETS    = "1.3.6.1.2.1.31.1.1.1.6"
HC_OUT_OCTETS   = "1.3.6.1.2.1.31.1.1.1.10"
IN_ERRORS       = "1.3.6.1.2.1.2.2.1.14"
OUT_ERRORS      = "1.3.6.1.2.1.2.2.1.20"
IN_DISCARDS     = "1.3.6.1.2.1.2.2.1.13"
OUT_DISCARDS    = "1.3.6.1.2.1.2.2.1.19"

INSERT_SQL = """INSERT INTO snmp_metrics
    (router_name, mgmt_ip, sys_name, if_descr, if_in_octets, if_out_octets,
     if_in_errors, if_out_errors, if_in_discards, if_out_discards,
     polled_at, status, error_detail)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"""


def _sqlite_now():
    """Must match app.sqlite_now() exactly — see constraints 2 and 18.

    Duplicated rather than imported (syslog_server.py does the same) so this
    module never depends on app.py's Flask app object being constructed
    first; both stamp 'YYYY-MM-DD HH:MM:SS' UTC, which is what polled_at's
    datetime('now', ...) window queries compare against in /api/snmp.
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def _metric_row(router_name, mgmt_ip, polled_at, sys_name=None, if_descr=None,
                 if_in_octets=None, if_out_octets=None, if_in_errors=None,
                 if_out_errors=None, if_in_discards=None, if_out_discards=None,
                 status="ok", error_detail=None):
    return (router_name, mgmt_ip, sys_name, if_descr, if_in_octets, if_out_octets,
            if_in_errors, if_out_errors, if_in_discards, if_out_discards,
            polled_at, status, error_detail)


def _get_int(varbinds, oid):
    for voi, _tag, value in varbinds:
        if voi == oid:
            return value if isinstance(value, int) else None
    return None


def _poll_target(name, mgmt_ip, community, local_addr, timeout_s):
    """Poll one router: sysName, then the interface table. Never raises —
    every SNMP call is individually guarded, and a failure at any stage
    produces one status-!=ok row rather than losing the whole router.
    """
    now = _sqlite_now()
    rows = []

    try:
        resp = snmp_client.get(mgmt_ip, community, [SYSNAME_OID], local_addr,
                               timeout_s=timeout_s)
    except snmp_client.SNMPTimeout as exc:
        return [_metric_row(name, mgmt_ip, now, status="timeout", error_detail=str(exc))]
    except (snmp_client.SNMPError, OSError) as exc:
        return [_metric_row(name, mgmt_ip, now, status="error", error_detail=str(exc))]

    sys_name = None
    for oid, _tag, value in resp["varbinds"]:
        if oid == SYSNAME_OID and isinstance(value, str):
            sys_name = value

    try:
        if_rows = snmp_client.walk(mgmt_ip, community, IFDESCR_BASE, local_addr,
                                   timeout_s=timeout_s)
    except snmp_client.SNMPTimeout as exc:
        return [_metric_row(name, mgmt_ip, now, sys_name=sys_name, status="timeout",
                            error_detail="ifDescr walk: {}".format(exc))]
    except (snmp_client.SNMPError, OSError) as exc:
        return [_metric_row(name, mgmt_ip, now, sys_name=sys_name, status="error",
                            error_detail="ifDescr walk: {}".format(exc))]

    if not if_rows:
        return [_metric_row(name, mgmt_ip, now, sys_name=sys_name, status="ok",
                            error_detail="agent returned no interfaces")]

    for oid, descr in if_rows:
        idx_part = oid[len(IFDESCR_BASE) + 1:]
        try:
            idx = int(idx_part)
        except ValueError:
            continue  # malformed suffix from a non-conformant agent; skip, don't crash

        counter_oids = [
            "{}.{}".format(HC_IN_OCTETS, idx),
            "{}.{}".format(HC_OUT_OCTETS, idx),
            "{}.{}".format(IN_ERRORS, idx),
            "{}.{}".format(OUT_ERRORS, idx),
            "{}.{}".format(IN_DISCARDS, idx),
            "{}.{}".format(OUT_DISCARDS, idx),
        ]
        try:
            cresp = snmp_client.get(mgmt_ip, community, counter_oids, local_addr,
                                    timeout_s=timeout_s)
        except snmp_client.SNMPTimeout as exc:
            rows.append(_metric_row(name, mgmt_ip, now, sys_name=sys_name, if_descr=descr,
                                    status="timeout", error_detail=str(exc)))
            continue
        except (snmp_client.SNMPError, OSError) as exc:
            rows.append(_metric_row(name, mgmt_ip, now, sys_name=sys_name, if_descr=descr,
                                    status="error", error_detail=str(exc)))
            continue

        varbinds = cresp["varbinds"]
        rows.append(_metric_row(
            name, mgmt_ip, now, sys_name=sys_name, if_descr=descr, status="ok",
            if_in_octets=_get_int(varbinds, counter_oids[0]),
            if_out_octets=_get_int(varbinds, counter_oids[1]),
            if_in_errors=_get_int(varbinds, counter_oids[2]),
            if_out_errors=_get_int(varbinds, counter_oids[3]),
            if_in_discards=_get_int(varbinds, counter_oids[4]),
            if_out_discards=_get_int(varbinds, counter_oids[5]),
        ))

    return rows


def _prune_old_metrics(db):
    """Age-based sweep, mirroring app.prune_old_results — single indexed
    DELETE, piggybacked on this thread's own loop rather than a separate
    scheduled job (there is no cron on the hub; see CLAUDE.md constraint 8).
    """
    db.execute(
        "DELETE FROM snmp_metrics WHERE polled_at < datetime('now', ? || ' hours')",
        ("-{:d}".format(config.SNMP_RETENTION_HOURS),),
    )


def _poll_round(db):
    targets = db.execute("SELECT name, mgmt_ip, community FROM snmp_targets").fetchall()
    for name, mgmt_ip, community in targets:
        comm = community or config.SNMP_COMMUNITY
        try:
            metric_rows = _poll_target(name, mgmt_ip, comm, config.MGMT_IP,
                                       config.SNMP_TIMEOUT_S)
        except Exception as exc:  # belt and braces: one bad router must not stop the round
            metric_rows = [_metric_row(name, mgmt_ip, _sqlite_now(), status="error",
                                       error_detail="poller crashed: {}".format(exc))]
        for row in metric_rows:
            db.execute(INSERT_SQL, row)
        db.commit()

    _prune_old_metrics(db)
    db.commit()


def _run_loop():
    db = sqlite3.connect(config.DB_PATH, check_same_thread=False)
    # Third writer against this database (Flask requests, the syslog
    # listener, and now this) — see constraint 17. Without this, a poll
    # round landing mid-burst could make a concurrent POST /results fail
    # outright with "database is locked".
    db.execute("PRAGMA busy_timeout={:d}".format(config.BUSY_TIMEOUT_MS))
    db.execute("PRAGMA journal_mode=WAL")
    while True:
        try:
            _poll_round(db)
        except Exception as exc:  # a round must never take the thread down
            sys.stderr.write("[snmp] poll round failed: {}\n".format(exc))
        time.sleep(config.SNMP_POLL_INTERVAL)


_started = False
_start_lock = threading.Lock()


def is_polling():
    """Whether the poller thread actually started. Mirrors syslog_server.is_listening()."""
    return _started


def start():
    """Start the poller once. Safe to call repeatedly.

    Opt-in and, unlike the syslog listener, loud on the one misconfiguration
    that must never happen quietly: HUB_SNMP_ENABLED=true with no
    HUB_MGMT_IP. Binding without a management-NIC address would mean SNMP
    traffic leaves from whatever interface the OS route table happens to
    pick — silently violating the one hard requirement this feature has — so
    that case logs loudly and the poller does not start at all, rather than
    degrading gracefully the way /api/time and /api/health do.
    """
    global _started

    with _start_lock:
        if _started or not config.SNMP_ENABLED:
            return
        if not config.MGMT_IP:
            sys.stderr.write(
                "[snmp] HUB_SNMP_ENABLED=true but HUB_MGMT_IP is unset — "
                "refusing to start the SNMP poller. Polling would otherwise "
                "source packets from whatever interface the OS route table "
                "picks, which silently violates the management-NIC-only "
                "requirement. Set HUB_MGMT_IP to the hub's address on the "
                "management VLAN.\n"
            )
            return

        threading.Thread(target=_run_loop, name="snmp-poller", daemon=True).start()
        _started = True
        sys.stderr.write(
            "[snmp] polling started, source {} every {}s\n".format(
                config.MGMT_IP, config.SNMP_POLL_INTERVAL)
        )
