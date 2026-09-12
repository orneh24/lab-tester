"""UDP syslog receiver for the lab-tester hub.

Listens on UDP/514 in a daemon thread and stores parsed messages in the same
SQLite database as the test results, so the dashboard can link a failing pair
to what the routers said at that moment.

Deliberately minimal: no relay, no TLS, no authentication. UDP syslog is lossy
and anything on the segment can inject into it — this is a troubleshooting aid,
never an audit trail.
"""

import re
import socket
import socketserver
import sqlite3
import sys
import threading
from datetime import datetime, timezone

from . import config

SEVERITY_NAMES = {
    0: "emerg", 1: "alert", 2: "crit", 3: "err",
    4: "warning", 5: "notice", 6: "info", 7: "debug",
}

MAX_RAW = 4096          # truncate absurd messages before they reach the DB
PRUNE_EVERY = 500       # rows between row-cap enforcement

# <190>123: R1: *Sep  8 12:00:00.123 UTC: %LINK-3-UPDOWN: Interface Gi2, ...
PRI_RE       = re.compile(r"^<(\d{1,3})>")
SEQ_RE       = re.compile(r"^\d+:\s+")
HOSTCOLON_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]{0,62}):\s+")
# The timezone group requires a following colon (Cisco writes "12:00:00.123
# UTC: %LINK-..."). Without that lookahead it swallows the hostname in plain
# RFC3164 lines like "Sep  8 12:02:00 R3 %SEC-...".
TIMESTAMP_RE = re.compile(
    r"^\*?[A-Z][a-z]{2}\s+\d{1,2}\s+\d{1,2}:\d{2}:\d{2}(?:\.\d+)?"
    r"(?:\s+[A-Z]{2,5}(?=:))?:?\s*"
)
HOSTWORD_RE  = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]{0,62})\s+(?=[%\w])")
MNEMONIC_RE  = re.compile(r"%([A-Z0-9_]+)-(\d)-([A-Z0-9_]+)\s*:\s*(.*)$", re.S)


def parse(raw, source_ip):
    """Best-effort parse of a Cisco/RFC3164 syslog line.

    Never raises and never returns None — an unparseable line is still stored
    with its raw text, because a message you cannot parse is often the one you
    most want to see.
    """
    result = {
        "source_ip": source_ip,
        "host": None,
        "facility": None,
        "severity": None,
        "mnemonic": None,
        "device_time": None,
        "message": raw,
        "raw": raw,
    }

    rest = raw.strip()

    m = PRI_RE.match(rest)
    if m:
        try:
            pri = int(m.group(1))
            if 0 <= pri <= 191:
                result["facility"] = pri // 8
                result["severity"] = pri % 8
        except ValueError:
            pass
        rest = rest[m.end():]

    rest = SEQ_RE.sub("", rest, count=1)

    # "R1: *Sep  8 ..." — Cisco with origin-id
    m = HOSTCOLON_RE.match(rest)
    _host_taken = False
    if m and not TIMESTAMP_RE.match(rest):
        # Only an origin-id if what follows looks like the rest of a Cisco
        # line — its own timestamp, or a %FACILITY-severity-MNEMONIC. Without
        # this, "kernel: out of memory" or "ERROR: disk full" files itself
        # under host "kernel"/"ERROR", and those then appear as separate
        # devices in /api/syslog/sources and in the page's filter, where
        # picking the real router by name hides them.
        _after = rest[m.end():]
        if TIMESTAMP_RE.match(_after) or MNEMONIC_RE.match(_after):
            result["host"] = m.group(1)
            rest = _after
            _host_taken = True

    if not _host_taken:
        # "Sep  8 12:00:00 R1 %LINK-3-..." — plain RFC3164. A bare word is only
        # treated as a hostname when a timestamp preceded it; otherwise the
        # first word of an unparseable line would become the host.
        m = TIMESTAMP_RE.match(rest)
        if m:
            result["device_time"] = m.group(0).strip().rstrip(":")
            rest = rest[m.end():]
            m = HOSTWORD_RE.match(rest)
            if m and not rest.startswith("%"):
                result["host"] = m.group(1)
                rest = rest[m.end():]

    # Cisco puts its own timestamp after the origin-id
    if result["device_time"] is None:
        m = TIMESTAMP_RE.match(rest)
        if m:
            result["device_time"] = m.group(0).strip().rstrip(":")
            rest = rest[m.end():]

    m = MNEMONIC_RE.search(rest)
    if m:
        result["mnemonic"] = "%{}-{}-{}".format(m.group(1), m.group(2), m.group(3))
        result["message"] = m.group(4).strip()
        if result["severity"] is None:
            try:
                result["severity"] = int(m.group(2))
            except ValueError:
                pass
    else:
        result["message"] = rest.strip() or raw

    return result


class _Store:
    """Single writer, guarded by a lock. WAL is already enabled by the hub."""

    def __init__(self, db_path, max_rows):
        self.max_rows = max_rows
        self.lock = threading.Lock()
        self.since_prune = 0
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        # This is the second writer against the hub database; without a busy
        # timeout a burst here makes result submissions fail with
        # "database is locked". Set before journal_mode, which can itself
        # contend — otherwise that one statement runs unprotected.
        self.db.execute("PRAGMA busy_timeout={}".format(config.BUSY_TIMEOUT_MS))
        self.db.execute("PRAGMA journal_mode=WAL")
        # One commit per datagram at synchronous=FULL means an fsync before the
        # next recvfrom, on a single-threaded UDP drain — the enlarged receive
        # buffer then only buys headroom for a burst, not throughput, and a
        # router at debug level drops steadily. NORMAL is safe under WAL: a
        # crash can lose the last transactions but cannot corrupt the file, and
        # this is explicitly a troubleshooting aid, not an audit trail. The
        # results table is written by the Flask side, which keeps FULL.
        self.db.execute("PRAGMA synchronous=NORMAL")

    def insert(self, rec):
        # Must match app.sqlite_now() exactly. Every timestamp in this database
        # is stored in SQLite's own 'YYYY-MM-DD HH:MM:SS' form so that
        # datetime('now', ...) window queries compare correctly; storing the
        # ISO form here instead would put 'T' (0x54) above ' ' (0x20) in those
        # comparisons and let any same-day row pass any window. The API applies
        # iso() on the way out.
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        with self.lock:
            self.db.execute(
                """INSERT INTO syslog
                   (received_at, source_ip, host, facility, severity,
                    mnemonic, device_time, message, raw)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (now, rec["source_ip"], rec["host"], rec["facility"],
                 rec["severity"], rec["mnemonic"], rec["device_time"],
                 rec["message"], rec["raw"]),
            )
            self.since_prune += 1
            if self.since_prune >= PRUNE_EVERY:
                # Row cap only, by id. AUTOINCREMENT ids are monotonic, so this
                # is a single indexed range delete rather than a scan.
                self.db.execute(
                    "DELETE FROM syslog WHERE id <= "
                    "(SELECT MAX(id) FROM syslog) - ?",
                    (self.max_rows,),
                )
                self.since_prune = 0
            self.db.commit()


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request[0]
        try:
            raw = data.decode("utf-8", "replace").strip()
        except Exception:
            return
        if not raw:
            return
        if len(raw) > MAX_RAW:
            raw = raw[:MAX_RAW] + " …[truncated]"
        try:
            _store.insert(parse(raw, self.client_address[0]))
        except Exception as exc:            # never let one bad packet kill the listener
            # stderr, not stdout: under OpenRC stdout is a file and therefore
            # block-buffered, and waitress never returns to flush it — a
            # print() here stays invisible for the life of the process, which
            # is exactly when someone is looking for it.
            sys.stderr.write("[syslog] store failed: {}\n".format(exc))


class _Server(socketserver.UDPServer):
    # Deliberately NOT allow_reuse_address. SO_REUSEADDR on a UDP socket does
    # not reliably reject a duplicate bind on Linux: two sockets that both set
    # it can hold the same port, after which the kernel hands each datagram to
    # only one of them. Running run.sh while the service is up would then split
    # the routers' messages between two processes writing to two databases, and
    # the dashboard would show a log with silent holes in it — far worse than a
    # clean failure to start. Leaving the flag off makes the second bind fail
    # with EADDRINUSE, which is exactly what start() is written to expect.
    max_packet_size = 8192

    def server_bind(self):
        # A router logging at debug level bursts faster than one thread drains
        # the socket. A larger receive buffer absorbs the burst; UDP still
        # drops under sustained overload, which is syslog's nature, not a bug.
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        except OSError:
            pass
        socketserver.UDPServer.server_bind(self)


_store = None
_started = False
_start_lock = threading.Lock()


def is_listening():
    """Whether the UDP listener actually bound. Used by /api/health.

    Reads the same flag start() sets, rather than re-deriving the state (e.g.
    by trying to bind again), so this can never disagree with what actually
    happened at startup.
    """
    return _started


def start():
    """Start the listener once. Safe to call repeatedly.

    A second call (or a second process under the Flask reloader) either sees
    the started flag or fails to bind, and in both cases returns quietly.
    """
    global _store, _started

    with _start_lock:
        if _started or not config.SYSLOG_ENABLED:
            return
        try:
            server = _Server((config.SYSLOG_BIND, config.SYSLOG_PORT), _Handler)
        except OSError as exc:
            sys.stderr.write("[syslog] not listening on {}:{} — {}\n".format(
                config.SYSLOG_BIND, config.SYSLOG_PORT, exc))
            return

        _store = _Store(config.DB_PATH, config.SYSLOG_MAX_ROWS)
        threading.Thread(target=server.serve_forever, name="syslog",
                         daemon=True).start()
        _started = True
        sys.stderr.write("[syslog] listening on {}:{} (cap {} rows)\n".format(
            config.SYSLOG_BIND, config.SYSLOG_PORT, config.SYSLOG_MAX_ROWS))
