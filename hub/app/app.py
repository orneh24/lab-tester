"""Lab-tester hub — collects registrations and test results, serves dashboard."""

import sqlite3
import os
import hashlib
import shutil
import subprocess
from datetime import datetime, timezone

from flask import Flask, request, jsonify, render_template, g, Response

from . import config
from . import syslog_server

app = Flask(__name__, template_folder=os.path.join(os.path.dirname(__file__), "..", "templates"),
            static_folder=os.path.join(os.path.dirname(__file__), "..", "static"))


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db():
    """Get a database connection for the current request."""
    if "db" not in g:
        g.db = sqlite3.connect(config.DB_PATH)
        g.db.row_factory = sqlite3.Row
        # busy_timeout first: the syslog listener writes to this same file from
        # its own thread, and journal_mode itself can contend. Setting the
        # timeout after it would leave that one statement unprotected.
        g.db.execute("PRAGMA busy_timeout={:d}".format(config.BUSY_TIMEOUT_MS))
        g.db.execute("PRAGMA journal_mode=WAL")
        g.db.execute("PRAGMA foreign_keys=ON")
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    """Create tables if they don't exist, and migrate older databases."""
    db = sqlite3.connect(config.DB_PATH)
    db.execute("PRAGMA busy_timeout={:d}".format(config.BUSY_TIMEOUT_MS))
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS endpoints (
            hostname   TEXT PRIMARY KEY,
            ip         TEXT NOT NULL,
            subnet     TEXT NOT NULL,
            group_name TEXT NOT NULL,
            last_seen  TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS results (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            source          TEXT NOT NULL,
            target_hostname TEXT NOT NULL,
            target_ip       TEXT NOT NULL,
            test_type       TEXT NOT NULL,
            success         INTEGER NOT NULL,
            latency_ms      REAL,
            output          TEXT,
            timestamp       TEXT NOT NULL,
            received_at     TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS targets (
            name    TEXT PRIMARY KEY,
            ip      TEXT NOT NULL,
            tests   TEXT NOT NULL,
            note    TEXT DEFAULT '',
            added   TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS syslog (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT NOT NULL,
            source_ip   TEXT NOT NULL,
            host        TEXT,
            facility    INTEGER,
            severity    INTEGER,
            mnemonic    TEXT,
            device_time TEXT,
            message     TEXT,
            raw         TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_results_received ON results(received_at);
        CREATE INDEX IF NOT EXISTS idx_results_source_target ON results(source, target_hostname);
        CREATE INDEX IF NOT EXISTS idx_syslog_received ON syslog(received_at);
        CREATE INDEX IF NOT EXISTS idx_syslog_host ON syslog(host);
    """)

    # Migration for databases created before received_at existed.
    cols = {r[1] for r in db.execute("PRAGMA table_info(results)").fetchall()}
    if "received_at" not in cols:
        db.execute("ALTER TABLE results ADD COLUMN received_at TEXT NOT NULL DEFAULT ''")
        db.execute("UPDATE results SET received_at = timestamp WHERE received_at = ''")
        db.execute("CREATE INDEX IF NOT EXISTS idx_results_received ON results(received_at)")
        db.commit()

    # Migration for the router-scope removal: the endpoints column was
    # `router`, and two tables existed only to poll router SNMP counters.
    ep_cols = {r[1] for r in db.execute("PRAGMA table_info(endpoints)").fetchall()}
    if "router" in ep_cols and "group_name" not in ep_cols:
        db.execute("ALTER TABLE endpoints RENAME COLUMN router TO group_name")
        db.commit()
    db.execute("DROP TABLE IF EXISTS snmp_metrics")
    db.execute("DROP TABLE IF EXISTS snmp_targets")
    db.commit()

    db.close()


def sqlite_now():
    """UTC timestamp in SQLite's own comparable format: 'YYYY-MM-DD HH:MM:SS'.

    Nodes send ISO-8601 with a 'T' separator and a 'Z' suffix. Comparing
    those against datetime('now', ...) is a string comparison in which 'T'
    (0x54) sorts above ' ' (0x20), so any same-day row passes any window.
    The hub therefore stamps its own receipt time in this format and filters
    on that, which also makes filtering immune to node clock drift.
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def prune_old_results(db):
    """Delete results older than the configured retention window."""
    db.execute(
        "DELETE FROM results WHERE received_at < datetime('now', ? || ' hours')",
        (f"-{config.RESULT_RETENTION_HOURS}",),
    )


def prune_stale_endpoints(db):
    """Remove endpoints that have not re-registered within the stale window.

    Nodes re-register every 5 minutes, so an endpoint that has been silent
    for hours is gone. Without this, every remaining node keeps testing a dead
    IP forever and the matrix stays red.
    """
    db.execute(
        "DELETE FROM endpoints WHERE last_seen < datetime('now', ? || ' hours')",
        (f"-{config.STALE_ENDPOINT_HOURS}",),
    )


# ---------------------------------------------------------------------------
# API endpoints
# ---------------------------------------------------------------------------

@app.route("/register", methods=["POST"])
def register():
    """Register or update a node endpoint."""
    data = request.get_json(force=True)
    required = ("hostname", "ip", "subnet", "group_name")
    if not all(k in data for k in required):
        return jsonify({"error": "Missing required fields", "required": list(required)}), 400

    now = sqlite_now()
    db = get_db()
    db.execute(
        """INSERT INTO endpoints (hostname, ip, subnet, group_name, last_seen)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(hostname) DO UPDATE SET
               ip=excluded.ip, subnet=excluded.subnet,
               group_name=excluded.group_name, last_seen=excluded.last_seen""",
        (data["hostname"], data["ip"], data["subnet"], data["group_name"], now),
    )
    db.commit()
    return jsonify({"status": "ok", "hostname": data["hostname"], "last_seen": iso(now)})


def iso(sqlite_ts):
    """Render a stored 'YYYY-MM-DD HH:MM:SS' UTC value as ISO-8601 with Z.

    Browsers parse a space-separated timestamp as *local* time, which would
    skew the dashboard's staleness display by the viewer's UTC offset.
    """
    return sqlite_ts.replace(" ", "T") + "Z" if sqlite_ts else sqlite_ts


def result_row(r):
    """Render a results row for the API with the hub's own timestamp in ISO.

    `received_at` is stored in SQLite's space-separated format, so it has to
    go through iso() like every other value that leaves the hub. The dashboard
    normalises defensively too (parseTs), but the invariant belongs here —
    /api/results is read directly by other consumers that do not.

    `timestamp` is the client's own record and already ISO-8601, so it is
    passed through untouched.
    """
    d = dict(r)
    d["received_at"] = iso(d["received_at"])
    return d


@app.route("/endpoints", methods=["GET"])
def list_endpoints():
    """Return all registered endpoints, pruning any that have gone stale."""
    db = get_db()
    prune_stale_endpoints(db)
    db.commit()
    rows = db.execute(
        "SELECT hostname, ip, subnet, group_name, last_seen FROM endpoints ORDER BY group_name, hostname"
    ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["last_seen"] = iso(d["last_seen"])
        out.append(d)
    return jsonify(out)


@app.route("/endpoints/<hostname>", methods=["DELETE"])
def delete_endpoint(hostname):
    """Remove a stale endpoint."""
    db = get_db()
    cur = db.execute("DELETE FROM endpoints WHERE hostname = ?", (hostname,))
    db.commit()
    if cur.rowcount == 0:
        return jsonify({"error": "not found"}), 404
    return jsonify({"status": "deleted", "hostname": hostname})


@app.route("/results", methods=["POST"])
def push_results():
    """Accept test results from a node.

    Missing and explicitly-null fields are both coerced to empty strings. This
    matters more than it looks: `.get(k, default)` returns the default only
    when the key is *absent*, so a payload carrying `"target_ip": null` used to
    put None into a NOT NULL column, raise IntegrityError, and — because the
    commit never ran — discard every other row in the same batch. That is the
    whole-batch loss of constraint 9 arriving by a different route, and it
    would show as a 500 with no clue which record caused it.
    """
    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Body must be a JSON object"}), 400

    source = data.get("source")
    results_list = data.get("results") or []
    if not source or not results_list:
        return jsonify({"error": "Missing source or results"}), 400
    if not isinstance(results_list, list):
        return jsonify({"error": "results must be a list"}), 400

    def text(record, key, default=""):
        """A NOT NULL column's value: absent, null and non-string all become text."""
        value = record.get(key)
        return default if value is None else str(value)

    received = sqlite_now()
    db = get_db()
    for index, r in enumerate(results_list):
        if not isinstance(r, dict):
            return jsonify({"error": "result must be an object", "index": index}), 400
        latency = r.get("latency_ms")
        if latency is not None and not isinstance(latency, (int, float)):
            # Keep the row rather than reject the batch: a bad latency is worth
            # less than the pass/fail beside it.
            latency = None
        db.execute(
            """INSERT INTO results
               (source, target_hostname, target_ip, test_type, success,
                latency_ms, output, timestamp, received_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                str(source),
                text(r, "target_hostname"),
                text(r, "target_ip"),
                text(r, "test_type"),
                1 if r.get("success") else 0,
                latency,
                text(r, "output"),
                text(r, "timestamp", iso(received)),
                received,
            ),
        )

    # Opportunistic retention sweep — avoids needing a separate cron job on
    # the hub. One indexed DELETE per push is cheap at this scale.
    prune_old_results(db)
    db.commit()
    return jsonify({"status": "ok", "accepted": len(results_list)})


@app.route("/api/results", methods=["GET"])
def api_results():
    """Return recent results as JSON. ?minutes=N (default 10)."""
    minutes = request.args.get("minutes", "10")
    try:
        minutes = int(minutes)
    except ValueError:
        minutes = 10
    # A negative value would build '--5 minutes', which SQLite evaluates to
    # NULL — every comparison then fails and the dashboard shows an empty
    # matrix with a 200, indistinguishable from a dead lab.
    minutes = abs(minutes)

    db = get_db()
    rows = db.execute(
        """SELECT source, target_hostname, target_ip, test_type, success,
                  latency_ms, output, timestamp, received_at
           FROM results
           WHERE received_at >= datetime('now', ? || ' minutes')
           ORDER BY received_at DESC""",
        (f"-{minutes}",),
    ).fetchall()
    return jsonify([result_row(r) for r in rows])


@app.route("/api/results/<source>/<target>", methods=["GET"])
def api_results_pair(source, target):
    """Detailed history between two endpoints."""
    db = get_db()
    rows = db.execute(
        """SELECT source, target_hostname, target_ip, test_type, success,
                  latency_ms, output, timestamp, received_at
           FROM results
           WHERE source = ? AND target_hostname = ?
           ORDER BY received_at DESC
           LIMIT 200""",
        (source, target),
    ).fetchall()
    return jsonify([result_row(r) for r in rows])


# ---------------------------------------------------------------------------
# Static targets
#
# Beyond the node mesh, a lab usually wants reachability checked against
# fixed addresses that run no agent at all — a gateway, an outside host, a
# device loopback. These live on the hub so they are configured once rather
# than on every node, and each declares which tests apply to it (a loopback
# answers traceroute and a PMTU probe but has no HTTP server).
# ---------------------------------------------------------------------------

VALID_TESTS = ("http", "ssh", "traceroute", "iperf3", "pmtu", "dns", "smb", "loss", "smtp")


@app.route("/targets", methods=["GET"])
def list_targets():
    """Static targets for nodes to include in each cycle."""
    db = get_db()
    rows = db.execute(
        "SELECT name, ip, tests, note FROM targets ORDER BY name"
    ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["tests"] = [t for t in d["tests"].split(",") if t]
        out.append(d)
    return jsonify(out)


@app.route("/targets", methods=["POST"])
def add_target():
    """Add or update a static target."""
    data = request.get_json(force=True)
    name = data.get("name")
    ip = data.get("ip")
    if not name or not ip:
        return jsonify({"error": "name and ip are required"}), 400

    tests = data.get("tests") or ["traceroute", "pmtu"]
    if isinstance(tests, str):
        tests = [t.strip() for t in tests.split(",")]

    unknown = [t for t in tests if t not in VALID_TESTS]
    if unknown:
        return jsonify({"error": "unknown test types",
                        "unknown": unknown,
                        "valid": list(VALID_TESTS)}), 400

    db = get_db()
    db.execute(
        """INSERT INTO targets (name, ip, tests, note, added)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(name) DO UPDATE SET
               ip=excluded.ip, tests=excluded.tests, note=excluded.note""",
        (name, ip, ",".join(tests), data.get("note", ""), sqlite_now()),
    )
    db.commit()
    return jsonify({"status": "ok", "name": name, "tests": tests})


@app.route("/targets/<name>", methods=["DELETE"])
def delete_target(name):
    db = get_db()
    cur = db.execute("DELETE FROM targets WHERE name = ?", (name,))
    db.commit()
    if cur.rowcount == 0:
        return jsonify({"error": "not found"}), 404
    return jsonify({"status": "deleted", "name": name})


# ---------------------------------------------------------------------------
# Syslog
#
# The receiver itself is syslog_server.py, started by serve.py in a daemon
# thread. These routes only read what it stored. Correlation is the point:
# a failing pair in the matrix means much more next to what the network
# devices between the nodes logged in that minute.
#
# Rows here are attacker-controlled in the sense that anything on the segment
# can send UDP/514 with no authentication — so they are rendered as text by
# the page and never interpreted. Treat the content as data.
# ---------------------------------------------------------------------------

SYSLOG_MAX_LIMIT = 2000


def sqlite_ts_arg(value):
    """Normalise an ISO-8601 or SQLite timestamp argument for comparison.

    Everything in this database is stored in SQLite's 'YYYY-MM-DD HH:MM:SS'
    form so that datetime() comparisons work (see sqlite_now). A caller — or a
    dashboard drill-down link — may hand us the ISO form we emit, so accept
    both and normalise inward rather than string-comparing mixed formats,
    which is the trap described in sqlite_now's docstring.

    Returns None for anything that is not a timestamp, so the caller drops the
    bound rather than comparing against garbage. A numeric UTC offset is
    *converted*, never truncated: chopping "+02:00" off the end would shift the
    window silently by the offset, which is the mixed-format bug this exists to
    prevent.
    """
    if not value:
        return None
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1]
    try:
        parsed = datetime.fromisoformat(v.replace(" ", "T"))
    except ValueError:
        return None
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
    return parsed.strftime("%Y-%m-%d %H:%M:%S")


def like_arg(value):
    r"""Wrap a substring search for LIKE, escaping its wildcards.

    Without this a search for "100%" or "GigabitEthernet0_1" silently matches
    far more than the user typed.
    """
    escaped = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return "%{}%".format(escaped)


def syslog_row(r):
    """Render a syslog row, with received_at in ISO-8601 like every other route."""
    d = dict(r)
    d["received_at"] = iso(d["received_at"])
    return d


@app.route("/api/syslog", methods=["GET"])
def api_syslog():
    """Stored syslog messages, newest first.

    ?minutes=N (default 60), or ?from=&to= for a pinned window — from/to win
    when either is present, because a pinned window is an explicit request and
    should not be silently widened by a default. Also ?host= (matches the
    parsed hostname or the source IP), ?severity=N, ?q= substring, ?limit=N.
    """
    args = request.args
    where = []
    params = []

    frm = sqlite_ts_arg(args.get("from"))
    to = sqlite_ts_arg(args.get("to"))
    if frm or to:
        if frm:
            where.append("received_at >= ?")
            params.append(frm)
        if to:
            where.append("received_at <= ?")
            params.append(to)
    else:
        try:
            minutes = int(args.get("minutes", "60"))
        except ValueError:
            minutes = 60
        where.append("received_at >= datetime('now', ? || ' minutes')")
        params.append("-{:d}".format(abs(minutes)))

    host = args.get("host")
    if host:
        # A device that never sent a parseable hostname is only addressable by
        # its source IP, and the page offers both in one dropdown.
        where.append("(host = ? OR source_ip = ?)")
        params.extend([host, host])

    severity = args.get("severity")
    if severity not in (None, "", "all"):
        try:
            level = int(severity)
        except ValueError:
            level = None
        # Parse before building the clause: appending the SQL first and then
        # failing to append its parameter leaves a placeholder with nothing to
        # bind, which is a 500 rather than the ignored-filter this intends.
        if level is not None:
            # Lower is more severe, so a chosen level means "this bad or worse"
            # — matching how the same filter reads on a network device. NULL
            # rows are kept: a line the parser could not read has no severity, and
            # dropping it here would hide exactly the line the parser is
            # written never to discard.
            where.append("(severity <= ? OR severity IS NULL)")
            params.append(level)

    q = args.get("q")
    if q:
        where.append("(message LIKE ? ESCAPE '\\' OR mnemonic LIKE ? ESCAPE '\\' "
                     "OR raw LIKE ? ESCAPE '\\')")
        params.extend([like_arg(q)] * 3)

    try:
        limit = int(args.get("limit", SYSLOG_MAX_LIMIT))
    except ValueError:
        limit = SYSLOG_MAX_LIMIT
    limit = max(1, min(limit, SYSLOG_MAX_LIMIT))

    sql = """SELECT id, received_at, source_ip, host, facility, severity,
                    mnemonic, device_time, message
             FROM syslog"""
    if where:
        sql += " WHERE " + " AND ".join(where)
    # id breaks ties: received_at has one-second resolution and a device can
    # emit a whole interface flap inside one second, which must stay in order.
    sql += " ORDER BY received_at DESC, id DESC LIMIT ?"
    params.append(limit)

    db = get_db()
    rows = db.execute(sql, params).fetchall()
    return jsonify([syslog_row(r) for r in rows])


@app.route("/api/syslog/sources", methods=["GET"])
def api_syslog_sources():
    """Distinct senders with message counts, for the page's filter dropdown.

    Falls back to source_ip where nothing parseable was sent, so a device is
    always selectable by something.

    Bounded to a window (?minutes=, default 1440) so it stays an indexed range
    rather than a full scan of the row cap on every page load. A sender silent
    for longer than the window is not a filter anyone needs offered.
    """
    try:
        minutes = abs(int(request.args.get("minutes", "1440")))
    except ValueError:
        minutes = 1440

    db = get_db()
    rows = db.execute(
        """SELECT COALESCE(NULLIF(host, ''), source_ip) AS name, COUNT(*) AS count
           FROM syslog
           WHERE received_at >= datetime('now', ? || ' minutes')
           GROUP BY name
           ORDER BY count DESC, name""",
        ("-{:d}".format(minutes),),
    ).fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/syslog")
def syslog_page():
    """Serve the syslog viewer."""
    return render_template("syslog.html")


# ---------------------------------------------------------------------------
# Hub clock
#
# The hub stamps received_at on everything and the syslog page pins windows
# around it, so every correlation on that page is only as good as this clock.
# A ±5 min window around a test failure means nothing if the hub's own idea of
# "now" has drifted — so the state is shown in the header rather than buried.
# ---------------------------------------------------------------------------

CHRONY_TIMEOUT_S = 3
# chrony's local reference ID: it is disciplining nothing and serving its own
# clock (the `local stratum 10` fallback), which looks synchronised but is not
# traceable to real time.
LOCAL_REFID_PREFIX = "7F7F"


def parse_chrony_tracking(text):
    """Parse `chronyc tracking` output into the shape the syslog header wants.

    Returns None if the output does not look like tracking output at all,
    rather than a half-filled dict that would render as a confident wrong
    answer.
    """
    fields = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip().lower()] = value.strip()

    if "stratum" not in fields and "reference id" not in fields:
        return None

    try:
        stratum = int(fields.get("stratum", ""))
    except ValueError:
        stratum = None

    # "0.000000012 seconds fast of NTP time" — fast is ahead, slow is behind.
    offset = None
    system_time = fields.get("system time", "")
    parts = system_time.split()
    if parts:
        try:
            offset = float(parts[0])
            if "slow" in system_time:
                offset = -offset
        except ValueError:
            offset = None

    refid = fields.get("reference id", "")
    source = None
    if "(" in refid and ")" in refid:
        source = refid[refid.index("(") + 1:refid.rindex(")")].strip() or None
    if not source:
        source = refid.split()[0] if refid.split() else None

    return {
        "stratum": stratum,
        "system_offset_s": offset,
        # "Normal" is the only leap status that means disciplined; "Not
        # synchronised" is what an isolated lab hub reports.
        "synced": fields.get("leap status", "").lower() == "normal",
        "local_only": refid.upper().startswith(LOCAL_REFID_PREFIX),
        "source": source,
    }


@app.route("/api/time", methods=["GET"])
def api_time():
    """The hub's clock, and whether chrony has it disciplined.

    Never 500s and never blocks the page: every failure mode — no chronyc, no
    daemon, a hung query — returns 200 with `chrony: null` and a reason, and
    the header renders that as a warning rather than losing the whole page.
    """
    out = {"utc": iso(sqlite_now()), "chrony": None}

    if shutil.which("chronyc") is None:
        out["reason"] = "chronyc not installed"
        return jsonify(out)

    try:
        proc = subprocess.run(
            ["chronyc", "-n", "tracking"],
            capture_output=True, text=True, timeout=CHRONY_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        out["reason"] = "chronyc timed out"
        return jsonify(out)
    except OSError as exc:
        out["reason"] = "chronyc failed: {}".format(exc.__class__.__name__)
        return jsonify(out)

    if proc.returncode != 0:
        # chronyd down, or the socket is not readable by this user.
        out["reason"] = (proc.stderr or proc.stdout or "chronyd not responding").strip()[:120]
        return jsonify(out)

    tracking = parse_chrony_tracking(proc.stdout)
    if tracking is None:
        out["reason"] = "unrecognised chronyc output"
        return jsonify(out)

    out["chrony"] = tracking
    return jsonify(out)


# ---------------------------------------------------------------------------
# Hub self-health
#
# The hub is infrastructure, not a test participant, but it can still fail
# quietly: a full disk stops both the sweep and the syslog cap from helping,
# and a dead service (chronyd, dropbear, the syslog listener) degrades
# correlation or access without ever showing up in the matrix. This is a
# separate concern from /api/time, which is specifically about clock
# discipline for syslog pinning; this endpoint is the general "is the box
# itself OK" check.
#
# Same failure-tolerance rule as /api/time: never 500. Each metric and each
# service check is independently guarded, so one missing binary or unreadable
# /proc file degrades that one field to null/"unknown" rather than blanking
# the whole response — this is meant to be useful on a flaky node, not just a
# healthy one, and it is routinely run on non-Alpine dev boxes where
# rc-service does not exist at all.
# ---------------------------------------------------------------------------

def _service_status(name):
    """Query one OpenRC service via `rc-service <name> status`.

    Returns {"status": "up"|"down"|None, "detail": str}. None status means the
    check itself could not be performed (no rc-service binary, timeout,
    unexpected error) — that is different from a service that responded and
    is stopped, so the two are not folded together.
    """
    if shutil.which("rc-service") is None:
        return {"status": None, "detail": "rc-service not installed"}
    try:
        proc = subprocess.run(
            ["rc-service", name, "status"],
            capture_output=True, text=True, timeout=config.HEALTH_SERVICE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return {"status": None, "detail": "rc-service timed out"}
    except OSError as exc:
        return {"status": None, "detail": "rc-service failed: {}".format(exc.__class__.__name__)}

    out = (proc.stdout or proc.stderr or "").strip()
    # OpenRC's `status` exits 0 for started, non-zero for stopped/crashed —
    # same shape as chronyc's returncode check in api_time.
    if proc.returncode == 0:
        return {"status": "up", "detail": out[:120] or "started"}
    return {"status": "down", "detail": out[:120] or "not running"}


def _load_avg():
    try:
        one, five, fifteen = os.getloadavg()
        return {"1m": one, "5m": five, "15m": fifteen}
    except (OSError, AttributeError):
        # AttributeError: not available on Windows, which is where this is
        # routinely exercised in development.
        return None


def _memory_info():
    """Parse /proc/meminfo rather than shelling out to `free`.

    MemAvailable (not MemFree) is what accounts for reclaimable cache, so it
    is the number that matches what an operator means by "how much is free".
    """
    try:
        fields = {}
        with open("/proc/meminfo", "r") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                rest = rest.strip()
                if rest.endswith("kB"):
                    rest = rest[:-2].strip()
                try:
                    fields[key] = int(rest)
                except ValueError:
                    pass
        total = fields.get("MemTotal")
        available = fields.get("MemAvailable")
        if total is None or available is None:
            return None
        used = total - available
        pct = round(used / total * 100, 1) if total else None
        return {
            "total_kb": total,
            "available_kb": available,
            "used_kb": used,
            "used_pct": pct,
        }
    except OSError:
        return None


def _disk_info():
    """Usage of the filesystem holding the SQLite DB.

    The DB and the syslog table both grow (retention sweep and row cap are
    both about bounding this), so this is the filesystem an operator actually
    cares about, not the root filesystem in general.
    """
    try:
        directory = os.path.dirname(os.path.abspath(config.DB_PATH)) or "."
        usage = shutil.disk_usage(directory)
        pct = round(usage.used / usage.total * 100, 1) if usage.total else None
        return {
            "path": directory,
            "total_bytes": usage.total,
            "used_bytes": usage.used,
            "free_bytes": usage.free,
            "used_pct": pct,
        }
    except OSError:
        return None


def _uptime_s():
    try:
        with open("/proc/uptime", "r") as fh:
            return float(fh.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


@app.route("/api/health", methods=["GET"])
def api_health():
    """Hub self-health: services, load, memory, disk, uptime.

    Always 200, matching /api/time — a health check that itself 500s on a
    flaky node would defeat the point. Every field degrades independently.
    """
    services = {}
    for name in config.HEALTH_SERVICES:
        try:
            services[name] = _service_status(name)
        except Exception as exc:  # belt and braces: one bad service must not blank the rest
            services[name] = {"status": None, "detail": "check failed: {}".format(exc.__class__.__name__)}

    return jsonify({
        "checked_at": iso(sqlite_now()),
        "services": services,
        "syslog_listening": syslog_server.is_listening(),
        "load_avg": _load_avg(),
        "memory": _memory_info(),
        "disk": _disk_info(),
        "uptime_s": _uptime_s(),
    })


# ---------------------------------------------------------------------------
# Agent distribution
#
# The hub is the single place agent scripts are edited; nodes pull updates
# on their 5-minute registration run. Checksums are published so a node can
# verify a download before trusting it — see register.sh, which additionally
# syntax-checks and keeps a known-good copy before swapping anything in.
# ---------------------------------------------------------------------------

AGENT_DIR = os.path.join(os.path.dirname(__file__), "..", "agent")
AGENT_SCRIPTS = ("test-cycle.sh", "register.sh")


def _agent_path(name):
    """Resolve an agent script path, refusing anything outside AGENT_DIR."""
    if name not in AGENT_SCRIPTS:
        return None
    path = os.path.abspath(os.path.join(AGENT_DIR, name))
    if not path.startswith(os.path.abspath(AGENT_DIR) + os.sep):
        return None
    return path if os.path.isfile(path) else None


@app.route("/agent/manifest", methods=["GET"])
def agent_manifest():
    """Checksums and sizes for the agent scripts the hub is serving."""
    scripts = {}
    for name in AGENT_SCRIPTS:
        path = _agent_path(name)
        if not path:
            continue
        with open(path, "rb") as fh:
            body = fh.read()
        scripts[name] = {
            "sha256": hashlib.sha256(body).hexdigest(),
            "size": len(body),
        }
    return jsonify({"scripts": scripts})


@app.route("/agent/<name>", methods=["GET"])
def agent_script(name):
    """Serve one agent script as plain text."""
    path = _agent_path(name)
    if not path:
        return jsonify({"error": "not found"}), 404
    with open(path, "r") as fh:
        return Response(fh.read(), mimetype="text/plain")


@app.route("/favicon.ico")
def favicon():
    """Inline favicon.

    Browsers request this unconditionally; without it every page load logged
    a 404 and put an error in the console, which is noise to scroll past when
    something is actually wrong.
    """
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">'
        '<rect width="16" height="16" rx="3" fill="#0d1117"/>'
        '<circle cx="5" cy="5" r="2" fill="#3fb950"/>'
        '<circle cx="11" cy="5" r="2" fill="#3fb950"/>'
        '<circle cx="5" cy="11" r="2" fill="#3fb950"/>'
        '<circle cx="11" cy="11" r="2" fill="#f85149"/>'
        "</svg>"
    )
    return Response(svg, mimetype="image/svg+xml")


@app.route("/")
def dashboard():
    """Serve the dashboard page."""
    return render_template("dashboard.html")


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

init_db()
