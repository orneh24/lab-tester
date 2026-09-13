"""Minimal, stdlib-only SNMPv2c client.

Why hand-rolled rather than `pysnmp` or shelling out to net-snmp's
`snmpget`/`snmpwalk`: the hub is meant to be multi-homed, with SNMP polling
required to source its packets from a specific management-NIC address
(`HUB_MGMT_IP`), never whatever the OS picks by default — the routers' SNMP
ACL is restricted to that one address. The net-snmp CLI tools do not
reliably expose a local-source-bind flag across versions, which would
silently defeat that requirement: a request could go out the wrong
interface with no error. `socket.bind((HUB_MGMT_IP, 0))` before sending is
the reliable way to force Linux to source UDP traffic from a specific local
address on a multi-homed host, and getting that guarantee from a library
means either this or auditing an unfamiliar dependency for the same
property. Scope is narrow — SNMPv2c only, GetRequest and GetBulkRequest,
no traps, no v3 — so hand-rolling BER/ASN.1 for it is reasonable.

Only what the poller needs is implemented: INTEGER, OCTET STRING, NULL,
OBJECT IDENTIFIER, SEQUENCE, and the SNMP application types that show up in
interface-table values (Counter32, Gauge32, TimeTicks, Counter64, IpAddress,
Opaque) plus the v2c exception values (noSuchObject, noSuchInstance,
endOfMibView).
"""

import random
import socket

# ---------------------------------------------------------------------------
# BER/ASN.1 tags used
# ---------------------------------------------------------------------------
TAG_INTEGER      = 0x02
TAG_OCTET_STRING = 0x04
TAG_NULL         = 0x05
TAG_OID          = 0x06
TAG_SEQUENCE     = 0x30

TAG_IP_ADDRESS = 0x40
TAG_COUNTER32  = 0x41
TAG_GAUGE32    = 0x42
TAG_TIMETICKS  = 0x43
TAG_OPAQUE     = 0x44
TAG_COUNTER64  = 0x46

TAG_GET_REQUEST     = 0xA0
TAG_GETNEXT_REQUEST = 0xA1
TAG_GET_RESPONSE    = 0xA2
TAG_SET_REQUEST     = 0xA3
TAG_GETBULK_REQUEST = 0xA5

TAG_NO_SUCH_OBJECT   = 0x80
TAG_NO_SUCH_INSTANCE = 0x81
TAG_END_OF_MIB_VIEW  = 0x82

EXCEPTION_TAGS = (TAG_NO_SUCH_OBJECT, TAG_NO_SUCH_INSTANCE, TAG_END_OF_MIB_VIEW)
EXCEPTION_NAMES = {
    TAG_NO_SUCH_OBJECT: "noSuchObject",
    TAG_NO_SUCH_INSTANCE: "noSuchInstance",
    TAG_END_OF_MIB_VIEW: "endOfMibView",
}

SNMP_VERSION_2C = 1


class SNMPError(Exception):
    """The agent replied, but with an error we cannot use (bad encoding,
    error-status set, request-id mismatch)."""


class SNMPTimeout(Exception):
    """No reply within the configured timeout."""


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

def _encode_length(n):
    if n < 0x80:
        return bytes([n])
    body = []
    while n > 0:
        body.insert(0, n & 0xFF)
        n >>= 8
    return bytes([0x80 | len(body)]) + bytes(body)


def _encode_tlv(tag, content):
    return bytes([tag]) + _encode_length(len(content)) + content


def _encode_integer(n, tag=TAG_INTEGER):
    if n == 0:
        content = b"\x00"
    elif n > 0:
        octets = bytearray()
        v = n
        while v > 0:
            octets.insert(0, v & 0xFF)
            v >>= 8
        if octets[0] & 0x80:
            octets.insert(0, 0x00)
        content = bytes(octets)
    else:
        nbytes = (n.bit_length() // 8) + 1
        content = (n & ((1 << (nbytes * 8)) - 1)).to_bytes(nbytes, "big")
    return _encode_tlv(tag, content)


def _encode_base128(val):
    if val == 0:
        return bytes([0])
    chunks = []
    v = val
    while v > 0:
        chunks.insert(0, v & 0x7F)
        v >>= 7
    for i in range(len(chunks) - 1):
        chunks[i] |= 0x80
    return bytes(chunks)


def _encode_oid(oid_str):
    parts = [int(x) for x in oid_str.strip(".").split(".")]
    if len(parts) < 2:
        raise SNMPError("OID too short: {}".format(oid_str))
    out = bytearray()
    out += _encode_base128(parts[0] * 40 + parts[1])
    for p in parts[2:]:
        out += _encode_base128(p)
    return _encode_tlv(TAG_OID, bytes(out))


def _encode_octet_string(s):
    if isinstance(s, str):
        s = s.encode("utf-8")
    return _encode_tlv(TAG_OCTET_STRING, s)


def _encode_null():
    return _encode_tlv(TAG_NULL, b"")


def _encode_sequence(parts):
    return _encode_tlv(TAG_SEQUENCE, b"".join(parts))


def _build_message(community, pdu_tag, request_id, field2, field3, oids):
    varbinds = [_encode_sequence([_encode_oid(oid), _encode_null()]) for oid in oids]
    pdu_content = (
        _encode_integer(request_id)
        + _encode_integer(field2)
        + _encode_integer(field3)
        + _encode_sequence(varbinds)
    )
    pdu = _encode_tlv(pdu_tag, pdu_content)
    return _encode_sequence([
        _encode_integer(SNMP_VERSION_2C),
        _encode_octet_string(community),
        pdu,
    ])


def build_get_request(community, oids, request_id):
    """GetRequest-PDU: error-status and error-index fields are 0 on the way out."""
    return _build_message(community, TAG_GET_REQUEST, request_id, 0, 0, oids)


def build_getbulk_request(community, oids, request_id, non_repeaters=0, max_repetitions=10):
    """GetBulkRequest-PDU: field2/field3 are non-repeaters/max-repetitions here."""
    return _build_message(community, TAG_GETBULK_REQUEST, request_id, non_repeaters, max_repetitions, oids)


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

def _decode_tlv(data, offset):
    if offset >= len(data):
        raise SNMPError("truncated packet")
    tag = data[offset]
    offset += 1
    if offset >= len(data):
        raise SNMPError("truncated packet")
    length_byte = data[offset]
    offset += 1
    if length_byte & 0x80:
        num_len_bytes = length_byte & 0x7F
        if num_len_bytes == 0:
            raise SNMPError("indefinite length not supported")
        length = int.from_bytes(data[offset:offset + num_len_bytes], "big")
        offset += num_len_bytes
    else:
        length = length_byte
    content = data[offset:offset + length]
    if len(content) != length:
        raise SNMPError("truncated packet")
    offset += length
    return tag, content, offset


def _decode_integer(content):
    if not content:
        return 0
    return int.from_bytes(content, "big", signed=True)


def _decode_unsigned(content):
    if not content:
        return 0
    return int.from_bytes(content, "big", signed=False)


def _decode_oid(content):
    if not content:
        return ""
    first = content[0]
    parts = [first // 40, first % 40]
    val = 0
    for b in content[1:]:
        val = (val << 7) | (b & 0x7F)
        if not (b & 0x80):
            parts.append(val)
            val = 0
    return ".".join(str(p) for p in parts)


def _decode_value(tag, content):
    if tag == TAG_INTEGER:
        return _decode_integer(content)
    if tag == TAG_OCTET_STRING:
        return content.decode("utf-8", "replace")
    if tag == TAG_NULL:
        return None
    if tag == TAG_OID:
        return _decode_oid(content)
    if tag == TAG_IP_ADDRESS:
        return ".".join(str(b) for b in content) if len(content) == 4 else content.hex()
    if tag in (TAG_COUNTER32, TAG_GAUGE32, TAG_TIMETICKS, TAG_COUNTER64):
        return _decode_unsigned(content)
    if tag == TAG_OPAQUE:
        return content
    if tag in EXCEPTION_TAGS:
        return None
    # Unknown application/context type: hand back raw bytes rather than
    # raising, since the response as a whole is still usable.
    return content


def parse_response(data, expected_request_id=None):
    """Decode an SNMP message and return its PDU contents.

    Raises SNMPError on anything that does not parse as an SNMPv2c message
    with a Response-PDU whose request-id matches (when given). Never raises
    on a well-formed response carrying an SNMP-level error (error-status,
    noSuchObject, ...) — those are handed back for the caller to interpret,
    since a partial answer (some varbinds ok, one missing OID) is still
    useful to a poller.
    """
    tag, content, _ = _decode_tlv(data, 0)
    if tag != TAG_SEQUENCE:
        raise SNMPError("not an SNMP message (top tag {:#x})".format(tag))

    offset = 0
    vtag, vcontent, offset = _decode_tlv(content, offset)
    version = _decode_integer(vcontent)
    if version != SNMP_VERSION_2C:
        raise SNMPError("unexpected SNMP version {}".format(version))

    ctag, ccontent, offset = _decode_tlv(content, offset)

    pdu_tag, pdu_content, offset = _decode_tlv(content, offset)
    if pdu_tag != TAG_GET_RESPONSE:
        raise SNMPError("expected Response-PDU, got tag {:#x}".format(pdu_tag))

    p_off = 0
    rid_tag, rid_content, p_off = _decode_tlv(pdu_content, p_off)
    request_id = _decode_integer(rid_content)
    if expected_request_id is not None and request_id != expected_request_id:
        raise SNMPError("request-id mismatch (sent {}, got {})".format(
            expected_request_id, request_id))

    es_tag, es_content, p_off = _decode_tlv(pdu_content, p_off)
    error_status = _decode_integer(es_content)
    ei_tag, ei_content, p_off = _decode_tlv(pdu_content, p_off)
    error_index = _decode_integer(ei_content)

    vbl_tag, vbl_content, p_off = _decode_tlv(pdu_content, p_off)
    varbinds = []
    v_off = 0
    while v_off < len(vbl_content):
        vb_tag, vb_content, v_off = _decode_tlv(vbl_content, v_off)
        oid_tag, oid_content, vo = _decode_tlv(vb_content, 0)
        oid = _decode_oid(oid_content)
        val_tag, val_content, vo = _decode_tlv(vb_content, vo)
        value = _decode_value(val_tag, val_content)
        varbinds.append((oid, val_tag, value))

    return {
        "request_id": request_id,
        "error_status": error_status,
        "error_index": error_index,
        "varbinds": varbinds,
    }


# ---------------------------------------------------------------------------
# Wire I/O — every socket here is explicitly bound to the management address
# before sending. This is the whole point of hand-rolling this client: there
# is no code path that can send a packet without that bind having succeeded
# first, unlike a CLI tool's source-address flag which may be silently
# ignored on some builds.
# ---------------------------------------------------------------------------

def _new_socket(local_addr, timeout_s):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Source-bind to the management NIC. This is the mechanism the whole
        # design note is about: if this bind fails (bad/absent HUB_MGMT_IP,
        # address not present on this host), the caller must see the
        # exception rather than silently falling back to a wildcard socket
        # that would source from whatever interface the OS route table picks.
        sock.bind((local_addr, 0))
    except OSError:
        sock.close()
        raise
    sock.settimeout(timeout_s)
    return sock


def get(host, community, oids, local_addr, port=161, timeout_s=3):
    """SNMP GetRequest for a small list of OIDs. Returns the parsed response dict.

    Raises SNMPTimeout on no reply, SNMPError on anything malformed.
    """
    request_id = random.randint(1, 0x7FFFFFFF)
    msg = build_get_request(community, oids, request_id)
    sock = _new_socket(local_addr, timeout_s)
    try:
        sock.sendto(msg, (host, port))
        try:
            data, _addr = sock.recvfrom(65535)
        except socket.timeout:
            raise SNMPTimeout("no response from {} within {}s".format(host, timeout_s))
        except (ConnectionResetError, ConnectionRefusedError, OSError) as exc:
            # An unconnected UDP socket normally just times out against a
            # silent/firewalled host. Some stacks (notably Windows, when a
            # prior send drew back an ICMP port-unreachable) instead raise
            # here — treated the same as a timeout, since to a poller both
            # mean "this router did not answer."
            raise SNMPTimeout("no response from {} ({}: {})".format(
                host, exc.__class__.__name__, exc))
    finally:
        sock.close()
    return parse_response(data, expected_request_id=request_id)


def walk(host, community, base_oid, local_addr, port=161, timeout_s=3,
         max_repetitions=20, max_rounds=25):
    """Walk a subtree with GetBulkRequest, returning [(oid, value), ...].

    Stops at the first OID outside base_oid's subtree, at endOfMibView, or
    after max_rounds (a runaway agent must not hang the poller). The tables
    this hub walks (a handful of router interfaces) fit in one or two rounds.
    """
    results = []
    current = base_oid
    sock = _new_socket(local_addr, timeout_s)
    try:
        for _round in range(max_rounds):
            request_id = random.randint(1, 0x7FFFFFFF)
            msg = build_getbulk_request(community, [current], request_id,
                                        non_repeaters=0, max_repetitions=max_repetitions)
            sock.sendto(msg, (host, port))
            try:
                data, _addr = sock.recvfrom(65535)
            except socket.timeout:
                raise SNMPTimeout("no response from {} within {}s".format(host, timeout_s))
            except (ConnectionResetError, ConnectionRefusedError, OSError) as exc:
                # See get(): treated as a timeout, not a hard failure.
                raise SNMPTimeout("no response from {} ({}: {})".format(
                    host, exc.__class__.__name__, exc))
            resp = parse_response(data, expected_request_id=request_id)
            if resp["error_status"] != 0:
                raise SNMPError("agent returned error-status {} at index {}".format(
                    resp["error_status"], resp["error_index"]))
            if not resp["varbinds"]:
                break
            progressed = False
            for oid, tag, value in resp["varbinds"]:
                if tag in EXCEPTION_TAGS:
                    return results
                if oid == base_oid or not oid.startswith(base_oid + "."):
                    return results
                results.append((oid, value))
                current = oid
                progressed = True
            if not progressed:
                break
    finally:
        sock.close()
    return results
