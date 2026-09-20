"""Traceroute path-change detection.

Pure stdlib, no Flask/sqlite3 imports, so this is unit-testable standalone and
the message format has exactly one place it is defined (writer in app.py,
reader in the /api/path-changes route and, eventually, any other consumer —
both go through split_message rather than re-parsing syslog text by hand).

Every function here is written never to raise: bad or unexpected input
degrades to "no data"/"no change", matching the hub's existing
never-fail-on-bad-input discipline (see /api/time, /api/health in app.py).
A detection bug must never cost a node its results.
"""

import re

# ---------------------------------------------------------------------------
# The synthetic syslog row a detected change is written as. Kept here, next
# to the format functions that use them, so app.py's INSERT and this module's
# own split_message() can never disagree about what a hub-authored path-change
# row looks like.
# ---------------------------------------------------------------------------
HOST = "lab-tester-hub"
SOURCE_IP = "127.0.0.1"          # literally true: this row is written
                                  # locally, never received over UDP.
FACILITY = 16                    # local0 — customary "local use" facility
                                  # for a message with no real device origin.
SEVERITY = 5                     # notice: a path change (ECMP flip, working
                                  # failover) is not inherently a fault; 3/err
                                  # would paint a healthy lab red under an
                                  # "err or worse" filter.
MNEMONIC = "%LABTESTER-5-PATHCHANGE"

HOP_LINE_RE = re.compile(r"^\s*(\d{1,3})\s+(\S.*)$")
IPV4_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
MESSAGE_RE = re.compile(
    r"^(?P<source>\S+) -> (?P<target>\S+) \((?P<target_ip>[^)]*)\): (?P<detail>.*)$",
    re.S,
)


def parse_hops(output):
    """Parse raw `traceroute -n -q 1 -w 2 -m N` text into hop data.

    Returns an ordered list of (hop_number, address) tuples, one per hop that
    got a real reply — keyed by traceroute's own hop number (the leading
    integer on each line), not line position, so a header line or a merged
    stderr line (the node captures 2>&1) can't shift every later hop.

    A hop with no reply ('*') or a non-IPv4 token (hostname, IPv6, garbage)
    is simply omitted rather than included as a value — this is what makes
    diff_hops' "both samples must have a real reply" rule automatic rather
    than a separate check.

    Never raises. Returns [] on anything unparseable, including empty input.
    """
    try:
        hops = []
        if not output:
            return hops
        for line in str(output).splitlines():
            m = HOP_LINE_RE.match(line)
            if not m:
                continue
            try:
                hop_num = int(m.group(1))
            except ValueError:
                continue
            if not (1 <= hop_num <= 255):
                continue
            rest = m.group(2).strip()
            if not rest or rest[0] == "*":
                continue
            token = rest.split()[0]
            if not IPV4_RE.match(token):
                continue
            hops.append((hop_num, token))
        return hops
    except Exception:
        return []


def diff_hops(prev, cur):
    """Compare two parse_hops() results. Returns None or a short summary.

    The core rule: a hop position only counts when BOTH samples got a real
    reply. Since parse_hops() already omits no-reply hops, comparing only the
    hop numbers common to both lists implements that rule directly — a
    dropped single probe (traceroute here runs -q 1) reads as ordinary noise,
    not a path change.

    Path length alone is deliberately not a trigger either, for the same
    reason: only common hop numbers are ever compared, so a trace that simply
    got longer or shorter produces no diff by itself. A real reroute shows up
    as a positional mismatch on a hop both samples reached.

    Never raises.
    """
    try:
        if not prev or not cur:
            return None
        prev_map = dict(prev)
        cur_map = dict(cur)
        common = sorted(set(prev_map) & set(cur_map))
        diffs = [n for n in common if prev_map[n] != cur_map[n]]
        if not diffs:
            return None
        first = diffs[0]
        detail = "hop {}: {} -> {}".format(first, prev_map[first], cur_map[first])
        if len(diffs) > 1:
            detail += " (+{} more)".format(len(diffs) - 1)
        return detail
    except Exception:
        return None


def hops_text(hops):
    """Render a parse_hops() list as compact text, e.g. '1=10.0.0.1 2=10.0.0.2'.

    Used to build the raw field so both full hop lists are recoverable from
    the stored syslog row, not just the single differing hop in the message.
    Never raises.
    """
    try:
        return " ".join("{}={}".format(n, a) for n, a in hops)
    except Exception:
        return ""


def format_message(source, target, target_ip, detail):
    """Build the syslog.message text for a detected path change.

    Human-readable (the syslog viewer renders message as plain text) and
    machine-parseable by split_message(), which is the only reader of this
    shape — keeping both in this module means the format can change without
    touching app.py or the template.
    """
    try:
        return "{} -> {} ({}): {}".format(source, target, target_ip, detail)
    except Exception:
        return ""


def format_raw(prev_hops, cur_hops):
    """Build the syslog.raw text: both full hop lists, not just the diff."""
    try:
        return "prev: {}\ncur: {}".format(hops_text(prev_hops), hops_text(cur_hops))
    except Exception:
        return ""


def split_message(message):
    """Parse a format_message() string back into its parts.

    Returns None (never raises) if message is empty or does not match the
    shape format_message() produces — e.g. a row that shares this module's
    host/mnemonic tag but wasn't actually written by _note_path_change().
    """
    try:
        if not message:
            return None
        m = MESSAGE_RE.match(message)
        if not m:
            return None
        return {
            "source": m.group("source"),
            "target": m.group("target"),
            "target_ip": m.group("target_ip"),
            "detail": m.group("detail"),
        }
    except Exception:
        return None
