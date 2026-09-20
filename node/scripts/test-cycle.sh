#!/bin/sh
# test-cycle.sh — Run connectivity tests against all other lab-tester endpoints.
# Runs every 60 seconds via cron.
# Pulls the endpoint list from the hub, tests each one, and POSTs results back.

set -u

CONFIG="/etc/lab-tester/config"
LOG_TAG="lab-tester-test"

# -------------------------------------------------------------------
# Logging helper
# -------------------------------------------------------------------
log() {
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_TAG" "$1"
}

# -------------------------------------------------------------------
# Load configuration
# -------------------------------------------------------------------
if [ ! -f "$CONFIG" ]; then
    log "ERROR: config file $CONFIG not found"
    exit 1
fi

# shellcheck source=/dev/null
. "$CONFIG"

ENABLE_IPERF="${ENABLE_IPERF:-false}"
# Inline default, not just config.sample: setup.sh never rewrites an
# existing config file, so every already-deployed node runs this script
# against a config with no ENABLE_SMB or ENABLE_SMTP line at all.
ENABLE_SMB="${ENABLE_SMB:-false}"
ENABLE_SMTP="${ENABLE_SMTP:-false}"
MY_HOSTNAME=$(hostname)
SSH_KEY="${SSH_KEY:-/etc/lab-tester/id_lab}"

# Same inline-default reasoning as ENABLE_SMB/ENABLE_SMTP above: no
# already-deployed config has these lines. Console output defaults ON — the
# whole point is that a clone shows its own results on its vSphere console
# with zero configuration; CONSOLE_OUTPUT=false opts a node out.
CONSOLE_OUTPUT="${CONSOLE_OUTPUT:-true}"
CONSOLE_DEVICE="${CONSOLE_DEVICE:-/dev/console}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-/run/lab-tester/last-cycle.txt}"

# -------------------------------------------------------------------
# Console / test-status output.
#
# The hub dashboard is the source of truth, but an operator sitting at a
# node's own console (or SSH'd into it) has no way to see whether THIS
# node's tests are passing without opening it. Every cycle's summary is
# rendered once and fanned out to three places: stdout (which cron already
# redirects to test-cycle.log), the snapshot file test-status.sh reads, and
# the console device itself, so all three can never disagree about what
# happened.
#
# snapshot_note() is the lightweight form, used on early-exit paths (no
# endpoints, hub unreachable, lock held) so test-status and the login banner
# show *why* nothing ran rather than silently keeping a stale green table
# from an hour ago.
# -------------------------------------------------------------------
snapshot_note() {
    _line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${MY_HOSTNAME} $1"
    printf '%s\n' "$_line"
    if [ "$CONSOLE_OUTPUT" = "true" ] && [ -w "$CONSOLE_DEVICE" ] 2>/dev/null; then
        printf '%s\n' "$_line" > "$CONSOLE_DEVICE" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$SNAPSHOT_FILE")" 2>/dev/null || true
    _tmp="${SNAPSHOT_FILE}.$$"
    if printf '%s\n' "$_line" > "$_tmp" 2>/dev/null; then
        mv -f "$_tmp" "$SNAPSHOT_FILE" 2>/dev/null || true
    fi
}

# Full per-cycle table. Written via a temp file + mv so a concurrent
# test-status read (or the login banner) never sees a half-written table.
render_summary() {
    _out="$1"
    printf '%s\n' "$_out"
    if [ "$CONSOLE_OUTPUT" = "true" ] && [ -w "$CONSOLE_DEVICE" ] 2>/dev/null; then
        printf '%s\n' "$_out" > "$CONSOLE_DEVICE" 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$SNAPSHOT_FILE")" 2>/dev/null || true
    _tmp="${SNAPSHOT_FILE}.$$"
    if printf '%s\n' "$_out" > "$_tmp" 2>/dev/null; then
        mv -f "$_tmp" "$SNAPSHOT_FILE" 2>/dev/null || true
    fi
}

# Render one result JSON blob as a fixed-width table cell.
#   kind=bool -> OK / FAIL / - (json empty, i.e. test didn't run)
#   kind=loss -> loss percentage / - (mirrors run_loss_test's philosophy:
#                loss is data, not a pass/fail gate, so the cell shows the
#                number rather than collapsing it to OK/FAIL)
result_cell() {
    if [ -z "$1" ]; then
        printf -- '-'
        return 0
    fi
    if [ "$2" = "loss" ]; then
        _pct=$(printf '%s' "$1" | jq -r '.output // empty' | sed -n 's/^Loss: \([0-9]*\)%.*/\1/p')
        if [ -n "$_pct" ]; then printf '%s%%' "$_pct"; else printf -- '-'; fi
    else
        if [ "$(printf '%s' "$1" | jq -r '.success')" = "true" ]; then
            printf 'OK'
        else
            printf 'FAIL'
        fi
    fi
}

append_row() {
    [ -z "$1" ] && return 0
    if [ -n "$ROWS" ]; then
        ROWS="${ROWS}
$1"
    else
        ROWS="$1"
    fi
}
ROWS=""

# -------------------------------------------------------------------
# Serialise test cycles.
#
# A slow traceroute (15 hops x 2s) against several targets can outlast the
# 60-second cron interval. Without a lock, cycles pile up on top of each
# other and the node ends up running several at once, skewing every timing it
# reports. Skip this run if the previous one is still going.
# -------------------------------------------------------------------
LOCK_DIR="/run/lab-tester-test-cycle.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Clear a lock left behind by a killed run (older than 10 minutes).
    if [ -d "$LOCK_DIR" ] && [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then
        log "Removing stale lock"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { log "Could not acquire lock, skipping"; snapshot_note "SKIPPED: could not acquire lock"; exit 0; }
    else
        log "Previous cycle still running, skipping this run"
        snapshot_note "SKIPPED: previous cycle still running"
        exit 0
    fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# -------------------------------------------------------------------
# Fetch endpoint list from hub
# -------------------------------------------------------------------
log "Fetching endpoint list from ${HUB_URL}/endpoints"

ENDPOINTS=$(curl -s --connect-timeout 5 --max-time 10 "${HUB_URL}/endpoints" 2>/dev/null)

if [ -z "$ENDPOINTS" ]; then
    log "ERROR: could not fetch endpoints from hub"
    snapshot_note "ERROR: could not fetch endpoints from hub (${HUB_URL})"
    exit 1
fi

# Validate JSON
if ! printf '%s' "$ENDPOINTS" | jq empty 2>/dev/null; then
    log "ERROR: invalid JSON from /endpoints"
    snapshot_note "ERROR: invalid JSON from ${HUB_URL}/endpoints"
    exit 1
fi

ENDPOINT_COUNT=$(printf '%s' "$ENDPOINTS" | jq 'length')
log "Received $ENDPOINT_COUNT endpoints"

# -------------------------------------------------------------------
# Escape a string for safe JSON embedding
# -------------------------------------------------------------------
json_escape() {
    printf '%s' "$1" | jq -Rs '.'
}

# -------------------------------------------------------------------
# Run HTTP test against a target
# -------------------------------------------------------------------
run_http_test() {
    _target_ip="$1"
    _start=$(date +%s%N 2>/dev/null || date +%s)

    _result=$(curl -s -o /dev/null \
        -w '%{http_code} %{time_total}' \
        --connect-timeout 5 \
        --max-time 10 \
        "http://${_target_ip}/" 2>&1) || true

    _http_code=$(printf '%s' "$_result" | awk '{print $1}')
    _time_total=$(printf '%s' "$_result" | awk '{print $2}')

    if [ -n "$_http_code" ] && [ "$_http_code" -ge 200 ] 2>/dev/null && [ "$_http_code" -lt 400 ] 2>/dev/null; then
        _success="true"
    else
        _success="false"
    fi

    # Convert time_total (seconds with decimals) to milliseconds
    if [ -n "$_time_total" ]; then
        _latency=$(printf '%s' "$_time_total" | awk '{printf "%.2f", $1 * 1000}')
    else
        _latency="null"
    fi

    _output_escaped=$(json_escape "HTTP ${_http_code:-000} in ${_time_total:-?}s")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"http","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Run SSH test against a target
# -------------------------------------------------------------------
run_ssh_test() {
    _target_ip="$1"
    _start_s=$(date +%s)

    # BatchMode=yes disables password prompts, so this needs the shared lab
    # keypair that build-template.sh bakes into the image; without a key the
    # test could never pass. UserKnownHostsFile=/dev/null keeps a rebuilt
    # clone (new host key, recycled DHCP address) from tripping host-key
    # mismatches and reporting a routing failure that isn't one.
    _output=$(ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "$SSH_KEY" \
        "root@${_target_ip}" echo ok 2>&1) || true

    _end_s=$(date +%s)
    _elapsed=$(( _end_s - _start_s ))
    _latency=$(( _elapsed * 1000 ))

    if printf '%s' "$_output" | grep -q "^ok$"; then
        _success="true"
    else
        _success="false"
    fi

    _output_escaped=$(json_escape "$_output")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"ssh","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Run traceroute against a target
# -------------------------------------------------------------------
run_traceroute_test() {
    _target_ip="$1"
    _start_s=$(date +%s)

    # -q 1 and a lower -m matter more than they look. traceroute's default is
    # 3 probes per hop, so with -w 2 an unanswered hop costs 6s and a fully
    # black-holed path to -m 15 costs 90s for a single target. Targets are
    # tested serially, so a few broken paths used to overrun the 60s cycle
    # entirely — the tool got slowest precisely when the lab was broken.
    # One probe per hop and 10 hops caps a dead path at ~20s.
    _output=$(traceroute -n -q 1 -w 2 -m "${TRACEROUTE_MAX_HOPS:-10}" "$_target_ip" 2>&1) || true

    _end_s=$(date +%s)
    _elapsed=$(( _end_s - _start_s ))
    _latency=$(( _elapsed * 1000 ))

    # Traceroute "succeeds" if we reached the destination (last hop shows the IP)
    if printf '%s' "$_output" | tail -1 | grep -q "$_target_ip"; then
        _success="true"
    else
        _success="false"
    fi

    _output_escaped=$(json_escape "$_output")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"traceroute","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Path MTU probe.
#
# The failure this exists to catch: a GRE/IPsec/MPLS tunnel comes up, the
# peering establishes, small packets pass, and large transfers hang. Every
# other test here uses small payloads, so the whole matrix reads green
# through a PMTU black hole. Sending with DF set at a real payload size is
# what surfaces it.
#
# On failure, step down through common sizes to bracket where the path
# actually breaks — bounded at six probes, so a broken path costs a couple
# of seconds rather than a binary search.
# -------------------------------------------------------------------
pmtu_probe() {
    # Returns 0 if a DF packet of payload size $2 reaches $1.
    ping -c 1 -W 2 -M do -s "$2" "$1" >/dev/null 2>&1
}

run_pmtu_test() {
    _target_ip="$1"
    _size="${PMTU_SIZE:-1472}"
    _start_s=$(date +%s)

    if pmtu_probe "$_target_ip" "$_size"; then
        _success="true"
        _summary="OK at $(( _size + 28 )) bytes (payload ${_size})"
    else
        # Bracket the break point. 1472 payload = 1500 MTU, the usual
        # baseline; the lower rungs cover common tunnel overheads.
        _largest=""
        for _try in 1400 1300 1200 1000 500; do
            if [ "$_try" -ge "$_size" ]; then continue; fi
            if pmtu_probe "$_target_ip" "$_try"; then
                _largest="$_try"
                break
            fi
        done

        if [ -n "$_largest" ]; then
            _success="false"
            _summary="PMTU below $(( _size + 28 )); largest passing $(( _largest + 28 )) bytes"
        else
            # Nothing got through at any size — the path is down, not clamped.
            _success="false"
            _summary="no ICMP response at any size (path down, not an MTU issue)"
        fi
    fi

    _end_s=$(date +%s)
    _latency=$(( ( _end_s - _start_s ) * 1000 ))
    _output_escaped=$(json_escape "$_summary")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"pmtu","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Loss/jitter probe.
#
# Every other test here is pass/fail: it either connects or it doesn't. Real
# links degrade gracefully — a small amount of loss or RTT jitter on an
# otherwise-working path is a real, common signal none of
# http/ssh/traceroute/pmtu/dns/iperf3/smb surface, because they only notice a
# fully broken path.
#
# Mirrors pmtu's philosophy, not a binary tool's: success means the target
# replied at all (loss < 100%), not zero loss. Some loss is exactly the
# condition this test exists to report — treating any loss as failure would
# turn nearly every real link red in the matrix and defeat the point. Loss
# percentage and RTT spread are carried as data in `output`, never as the
# pass/fail gate. Only a fully dark target (100% loss, no replies at all) is
# success:false.
#
# Runs unconditionally, every cycle, against every peer and any static target
# that declares it — unlike iperf3/smb there is no ENABLE_ flag, so this has
# to stay cheap with no opt-out. 10 probes at a 100ms period with a 500ms
# per-probe timeout measured ~1.4s worst case against a fully dark target
# (9 x 100ms inter-probe spacing + the final 500ms wait for a reply that
# never comes) and ~0.9s against a reachable one — comfortably under 2s per
# peer either way.
# -------------------------------------------------------------------
run_loss_test() {
    _target_ip="$1"
    _count="${LOSS_COUNT:-10}"
    _period="${LOSS_PERIOD_MS:-100}"
    _timeout="${LOSS_TIMEOUT_MS:-500}"

    # fping's quiet-mode summary line goes to stderr, not stdout — capture
    # both. -q gives one line per target:
    #   reachable:   "<ip> : xmt/rcv/%loss = 10/10/0%, min/avg/max = a/b/c"
    #   unreachable: "<ip> : xmt/rcv/%loss = 10/0/100%"          (no rtt part)
    _output=$(fping -c "$_count" -p "$_period" -t "$_timeout" -q "$_target_ip" 2>&1) || true

    _summary_line=$(printf '%s' "$_output" | grep '%loss' | tail -1)
    _loss_pct=$(printf '%s' "$_summary_line" | sed -n 's/.*%loss = [0-9]*\/[0-9]*\/\([0-9]*\)%.*/\1/p')

    if [ -z "$_loss_pct" ]; then
        # fping itself did not produce a parseable summary (bad target,
        # binary missing) — report a failed probe rather than guessing.
        _success="false"
        _latency="null"
        _summary="loss probe failed: $(printf '%s' "$_output" | tr '\n' ' ')"
    else
        if [ "$_loss_pct" -lt 100 ]; then
            _success="true"
        else
            _success="false"
        fi

        _rtt=$(printf '%s' "$_summary_line" | sed -n 's#.*min/avg/max = \([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*#\1 \2 \3#p')
        if [ -n "$_rtt" ]; then
            _min=$(printf '%s' "$_rtt" | awk '{print $1}')
            _avg=$(printf '%s' "$_rtt" | awk '{print $2}')
            _max=$(printf '%s' "$_rtt" | awk '{print $3}')
            # fping already reports in milliseconds with real decimal
            # precision (sub-ms on a LAN), unlike the whole-second
            # date-based timers the coarse tests use — pass it through
            # arithmetically (awk, not a printf string trick) rather than
            # truncating to a whole-second elapsed time.
            _latency=$(printf '%s' "$_avg" | awk '{printf "%.2f", $1}')
            _summary="Loss: ${_loss_pct}% avg/min/max: ${_avg}/${_min}/${_max} ms"
        else
            # 100% loss: no RTT stats to report, only the loss line.
            _latency="null"
            _summary="Loss: ${_loss_pct}% (no replies)"
        fi
    fi

    _output_escaped=$(json_escape "$_summary")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"loss","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# DNS resolution test.
#
# Only runs when DNS_SERVER is configured; skipped silently otherwise so
# labs without DNS in the topology see no spurious red cells.
# -------------------------------------------------------------------
run_dns_test() {
    _server="$1"
    _query="${DNS_QUERY:-example.com}"
    _start_s=$(date +%s)

    _answer=$(dig "@${_server}" "$_query" +short +time=2 +tries=1 2>&1) || true

    _end_s=$(date +%s)
    _latency=$(( ( _end_s - _start_s ) * 1000 ))

    if [ -n "$_answer" ] && ! printf '%s' "$_answer" | grep -qi "timed out\|no servers\|connection refused"; then
        _success="true"
        _summary="$(printf '%s' "$_answer" | head -3 | tr '\n' ' ')"
    else
        _success="false"
        _summary="no answer: $(printf '%s' "$_answer" | head -2 | tr '\n' ' ')"
    fi

    _output_escaped=$(json_escape "${_query} -> ${_summary}")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"dns","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_server" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Run iperf3 test against a target
# -------------------------------------------------------------------
run_iperf3_test() {
    _target_ip="$1"
    _start_s=$(date +%s)

    # An iperf3 server handles one client at a time. With every node testing
    # every other node on the same 60-second tick, collisions are routine and
    # are contention, not a connectivity fault — so retry once after a
    # randomised pause, then report the run as skipped rather than failed.
    _attempt=1
    _output=""
    while [ "$_attempt" -le 2 ]; do
        _output=$(iperf3 -c "$_target_ip" -t 3 -J 2>&1) || true
        case "$_output" in
            *"busy running a test"*)
                if [ "$_attempt" -eq 2 ]; then
                    log "    iperf3 server busy, skipping this target"
                    return 1
                fi
                # ash has no $RANDOM; the PID gives adequate spread here.
                sleep "$(( ($$ % 5) + 1 ))"
                ;;
            *) break ;;
        esac
        _attempt=$(( _attempt + 1 ))
    done

    _end_s=$(date +%s)
    _elapsed=$(( _end_s - _start_s ))
    _latency=$(( _elapsed * 1000 ))

    # Extract bits_per_second from iperf3 JSON output
    _bps=$(printf '%s' "$_output" | jq -r '.end.sum_sent.bits_per_second // empty' 2>/dev/null)

    if [ -n "$_bps" ]; then
        _success="true"
        _mbps=$(printf '%s' "$_bps" | awk '{printf "%.2f Mbps", $1 / 1000000}')
        _summary="Bandwidth: ${_mbps}"
    else
        _success="false"
        _summary="iperf3 failed"
    fi

    _output_escaped=$(json_escape "$_summary")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"iperf3","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Run SMB test against a target.
#
# SMB is chatty and session-oriented — the test type most likely to catch an
# inspection policy, an MSS/MTU problem mid-transfer, or a NAT path that only
# tolerates short-lived flows, none of which HTTP/SSH/iperf3 would notice.
# Every node runs smbd exporting one small read-only share (lab-smbd,
# gated by ENABLE_SMB); this pulls the fixed probe file from a peer.
#
# Unlike iperf3, smbd forks a child per connection, so simultaneous peers
# hitting the same server in one cycle is normal, not contention — there is
# no retry/skip path here.
# -------------------------------------------------------------------
run_smb_test() {
    _target_ip="$1"
    _share="${SMB_SHARE:-labshare}"
    _probe_file="${SMB_PROBE_FILE:-probe.bin}"
    _start_s=$(date +%s)

    # Outer `timeout` is the hard bound test-cycle.sh's budget depends on;
    # smbclient's own -t is its per-operation socket timeout. -N is a null
    # (anonymous) session, matching smb.conf's "map to guest = Bad User".
    # probe.bin is 8 MB (build-template.sh); 15s/12s give a slower-but-healthy
    # link room to finish without being mistaken for a black hole.
    _output=$(timeout 15 smbclient -N "//${_target_ip}/${_share}" -t 12 \
        -c "get ${_probe_file} /dev/null" 2>&1) || true

    _end_s=$(date +%s)
    _elapsed=$(( _end_s - _start_s ))
    _latency=$(( _elapsed * 1000 ))

    # smbclient prints a "getting file ... (RATE kb/s)" line on a completed
    # transfer; anything else (auth failure, connection refused, timeout) is
    # a failure.
    if printf '%s' "$_output" | grep -qE 'getting file.*\([0-9.]+.*/sec\)'; then
        _success="true"
        _rate=$(printf '%s' "$_output" | grep -oE '\([0-9.]+ *[A-Za-z]*/sec\)' | head -1 | tr -d '()')
        _summary="Transfer OK: ${_rate:-unknown rate}"
    else
        _success="false"
        _summary="smb failed: $(printf '%s' "$_output" | tail -2 | tr '\n' ' ')"
    fi

    _output_escaped=$(json_escape "$_summary")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"smb","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Run SMTP test against a target.
#
# Nothing else in this mesh catches a device that PASSES SMTP while
# REWRITING it. SMTP ALG / ESMTP inspection -- common on firewalls and NAT
# gateways -- masks unrecognised capability verbs with runs of X (a client
# sees "250-XXXXXXXX" instead of "250-STARTTLS"). smb catches inspection
# that drops or stalls a session; this catches inspection that silently
# edits one.
#
# Success stops at EHLO, not RCPT. A real, correctly-configured relay will
# (and should) reject RCPT TO:<probe@lab.invalid> with something like
# "550 relay access denied" -- that must NOT paint a healthy relay red.
# Mirrors run_loss_test()'s philosophy: the interesting signal here is data
# (the capability list, whether it's masked, what MAIL/RCPT/RSET actually
# said), not a binary gate, so all of that goes into `output` and only
# banner+EHLO decide success/failure.
#
# The conversation never issues DATA -- it's aborted with RSET right after
# the envelope. That is what makes probing a real, unconfigured-by-us relay
# safe: a node may sit behind NAT with a real default route off the lab, so
# "it's an isolated lab" is not a valid defence -- never reaching DATA is a
# hard guarantee this test cannot actually send mail anywhere, healthy relay
# or not.
#
# Client is hand-rolled nc (BusyBox, already on the image via
# busybox-extras), not curl: curl's smtp:// support issues VRFY rather than
# MAIL FROM/RCPT TO without a -T upload, and most relays disable or misread
# VRFY as address-harvesting. See build-template.sh's package notes / the
# design doc for the fuller reasoning.
# -------------------------------------------------------------------
run_smtp_test() {
    _target_ip="$1"
    _port="${SMTP_PORT:-25}"
    _helo="${SMTP_HELO:-$MY_HOSTNAME}"
    _from="${SMTP_MAIL_FROM:-}"
    _rcpt="${SMTP_RCPT:-probe@lab.invalid}"
    _timeout="${SMTP_TIMEOUT:-10}"
    _start_s=$(date +%s)

    # The leading `sleep 1` before writing anything is not padding: anti-spam
    # "early talker" detection drops clients that speak before reading the
    # 220 banner, which is exactly the false failure this test must not
    # cause. Everything from EHLO onward is pipelined deliberately (RFC 2920
    # permits pipelining once EHLO has succeeded) -- that's what keeps this
    # near 3s instead of 6s. Both `sleep 1`s stay: they give the server time
    # to finish writing its full multiline 250- capability list before
    # anything downstream reads the buffer, and reliably capturing that full
    # list is this test's entire value.
    #
    # `timeout` wraps nc only, not this whole pipeline: the generator here
    # has nothing but fixed sleeps and printf, so it cannot hang on its own.
    # If nc exits first (timeout, refusal, RST), the generator gets EPIPE on
    # its next write, which the trailing `|| true` on the whole assignment
    # absorbs.
    _output=$( { sleep 1
                 printf 'EHLO %s\r\n' "$_helo"
                 sleep 1
                 printf 'MAIL FROM:<%s>\r\n' "$_from"
                 printf 'RCPT TO:<%s>\r\n' "$_rcpt"
                 printf 'RSET\r\n'
                 printf 'QUIT\r\n'
               } | timeout "$_timeout" nc -w 5 "$_target_ip" "$_port" 2>&1 ) || true

    _end_s=$(date +%s)
    _elapsed=$(( _end_s - _start_s ))
    _latency=$(( _elapsed * 1000 ))

    # Banner: the very first line of the session must be a 220. EHLO
    # response: any 250-/250 line following it. Since EHLO is the first and
    # only command sent before this check, a bare "250" appearing at all
    # after a real banner is, in practice, EHLO's response -- a server that
    # rejected EHLO would answer MAIL FROM with "503 bad sequence", not 250.
    _banner_ok="no"
    printf '%s' "$_output" | head -1 | grep -q '^220' && _banner_ok="yes"

    _ehlo_ok="no"
    printf '%s' "$_output" | grep -qE '^250[ -]' && _ehlo_ok="yes"

    if [ "$_banner_ok" = "yes" ] && [ "$_ehlo_ok" = "yes" ]; then
        _success="true"
    else
        _success="false"
    fi

    # Capability masking detector -- the single most important line of logic
    # in this function. A run of 4+ literal X characters where a capability
    # token should be is the signature an SMTP ALG / ESMTP inspection engine
    # leaves behind when it scrubs a verb it doesn't recognise.
    _mask_note=""
    if printf '%s' "$_output" | grep -qE '^250[ -]X{4,}'; then
        _mask_note="ESMTP capabilities masked (XXXXXXXX) -- ALG/inspection rewriting on path. "
    fi

    _summary="${_mask_note}$(printf '%s' "$_output" | tr -d '\r' | tr '\n' ' ')"
    _output_escaped=$(json_escape "$_summary")

    printf '{"target_hostname":"%s","target_ip":"%s","test_type":"smtp","success":%s,"latency_ms":%s,"output":%s,"timestamp":"%s"}' \
        "$2" "$_target_ip" "$_success" "$_latency" "$_output_escaped" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# -------------------------------------------------------------------
# Decide whether traceroute runs this cycle.
#
# Traceroute is by far the most expensive test, and its value is diagnostic
# rather than continuous: you want the path *after* something breaks, not on
# every tick. So it runs on a slower schedule, and additionally whenever a
# connectivity test to that target has just failed — which is exactly when
# the path detail is worth having.
# -------------------------------------------------------------------
TRACEROUTE_INTERVAL="${TRACEROUTE_INTERVAL:-300}"
TRACEROUTE_STAMP="/run/lab-tester-last-traceroute"

traceroute_due() {
    [ ! -f "$TRACEROUTE_STAMP" ] && return 0
    _last=$(cat "$TRACEROUTE_STAMP" 2>/dev/null || echo 0)
    _now=$(date +%s)
    [ "$(( _now - _last ))" -ge "$TRACEROUTE_INTERVAL" ]
}

if traceroute_due; then
    TRACE_THIS_CYCLE="yes"
    date +%s > "$TRACEROUTE_STAMP" 2>/dev/null || true
    log "Traceroute scheduled this cycle (every ${TRACEROUTE_INTERVAL}s)"
else
    TRACE_THIS_CYCLE="no"
fi

# -------------------------------------------------------------------
# Build the target list: the node mesh plus any static targets the hub
# holds (gateways, outside addresses, device loopbacks — things that run no
# agent).
# -------------------------------------------------------------------
append_result() {
    [ -z "$1" ] && return 0
    if [ -n "$RESULTS" ]; then
        RESULTS="${RESULTS},$1"
    else
        RESULTS="$1"
    fi
}

RESULTS=""
TESTED=0

log "Fetching static targets from ${HUB_URL}/targets"
TARGETS=$(curl -s --connect-timeout 5 --max-time 10 "${HUB_URL}/targets" 2>/dev/null) || TARGETS=""
if [ -z "$TARGETS" ] || ! printf '%s' "$TARGETS" | jq empty 2>/dev/null; then
    TARGETS="[]"
fi
TARGET_COUNT=$(printf '%s' "$TARGETS" | jq 'length')
log "Received $TARGET_COUNT static targets"

# -------------------------------------------------------------------
# Mesh endpoints — full test suite against each peer
# -------------------------------------------------------------------
i=0
while [ "$i" -lt "$ENDPOINT_COUNT" ]; do
    EP=$(printf '%s' "$ENDPOINTS" | jq -r ".[$i]")
    EP_HOSTNAME=$(printf '%s' "$EP" | jq -r '.hostname')
    EP_IP=$(printf '%s' "$EP" | jq -r '.ip')

    # Skip self
    if [ "$EP_HOSTNAME" = "$MY_HOSTNAME" ]; then
        log "Skipping self ($EP_HOSTNAME)"
        i=$((i + 1))
        continue
    fi

    log "Testing $EP_HOSTNAME ($EP_IP)"

    # Reset per-target so a target that skips traceroute this cycle doesn't
    # inherit the previous target's TRACE_RESULT in its console row.
    TRACE_RESULT=""

    # Each test is isolated so one failure cannot prevent the others running.

    log "  HTTP test -> $EP_IP"
    HTTP_RESULT=$(run_http_test "$EP_IP" "$EP_HOSTNAME") || true
    append_result "$HTTP_RESULT"

    log "  SSH test -> $EP_IP"
    SSH_RESULT=$(run_ssh_test "$EP_IP" "$EP_HOSTNAME") || true
    append_result "$SSH_RESULT"

    log "  PMTU probe -> $EP_IP"
    PMTU_RESULT=$(run_pmtu_test "$EP_IP" "$EP_HOSTNAME") || true
    append_result "$PMTU_RESULT"

    # Loss/jitter probe. Unconditional like http/ssh/pmtu above — no
    # ENABLE_ gate — so it has to stay cheap; see run_loss_test()'s comment.
    log "  Loss probe -> $EP_IP"
    LOSS_RESULT=$(run_loss_test "$EP_IP" "$EP_HOSTNAME") || true
    append_result "$LOSS_RESULT"

    # Traceroute when scheduled, or when something just failed on this path.
    _failed_now="no"
    printf '%s' "$HTTP_RESULT$SSH_RESULT" | grep -q '"success":false' && _failed_now="yes"

    if [ "$TRACE_THIS_CYCLE" = "yes" ] || [ "$_failed_now" = "yes" ]; then
        [ "$_failed_now" = "yes" ] && log "  Traceroute -> $EP_IP (triggered by failure)" \
                                  || log "  Traceroute -> $EP_IP"
        TRACE_RESULT=$(run_traceroute_test "$EP_IP" "$EP_HOSTNAME") || true
        append_result "$TRACE_RESULT"
    fi

    # Console/test-status row for this target. Built from the same result
    # variables just posted to the hub, not a second parse of $RESULTS, so
    # the console table can never drift from what the dashboard shows.
    append_row "$(printf '%-14s %-15s %-5s %-5s %-5s %-6s %-3s' \
        "$EP_HOSTNAME" "$EP_IP" \
        "$(result_cell "$HTTP_RESULT" bool)" \
        "$(result_cell "$SSH_RESULT" bool)" \
        "$(result_cell "$PMTU_RESULT" bool)" \
        "$(result_cell "$LOSS_RESULT" loss)" \
        "$([ -n "$TRACE_RESULT" ] && printf '*' || printf -- '-')")"

    # iperf3 (optional). A skipped run returns nothing, and appending that
    # blindly would leave a trailing comma and produce invalid JSON.
    if [ "$ENABLE_IPERF" = "true" ]; then
        log "  iperf3 test -> $EP_IP"
        IPERF_RESULT=$(run_iperf3_test "$EP_IP" "$EP_HOSTNAME") || IPERF_RESULT=""
        append_result "$IPERF_RESULT"
    fi

    # SMB (optional). No skip case here (unlike iperf3) — smbd forks per
    # connection, so this always produces a result and append_result is used
    # only for the ordinary "one failure shouldn't drop the others" reason.
    if [ "$ENABLE_SMB" = "true" ]; then
        log "  SMB test -> $EP_IP"
        SMB_RESULT=$(run_smb_test "$EP_IP" "$EP_HOSTNAME") || true
        append_result "$SMB_RESULT"
    fi

    # SMTP (optional). Like SMB, OpenSMTPD handles concurrent sessions fine
    # (no iperf3-style contention/skip path needed) -- every failure is
    # isolated with || true, same as every other test here.
    if [ "$ENABLE_SMTP" = "true" ]; then
        log "  SMTP test -> $EP_IP"
        SMTP_RESULT=$(run_smtp_test "$EP_IP" "$EP_HOSTNAME") || true
        append_result "$SMTP_RESULT"
    fi

    TESTED=$((TESTED + 1))
    i=$((i + 1))
done

# -------------------------------------------------------------------
# Static targets — only the tests each one declares
# -------------------------------------------------------------------
j=0
while [ "$j" -lt "$TARGET_COUNT" ]; do
    TG=$(printf '%s' "$TARGETS" | jq -r ".[$j]")
    TG_NAME=$(printf '%s' "$TG" | jq -r '.name')
    TG_IP=$(printf '%s' "$TG" | jq -r '.ip')
    TG_TESTS=$(printf '%s' "$TG" | jq -r '.tests | join(",")')

    log "Testing static target $TG_NAME ($TG_IP) [$TG_TESTS]"

    # Reset per-target so console-row cells reflect only tests this target
    # actually declares, not whatever a previous target left behind.
    TG_HTTP=""; TG_SSH=""; TG_PMTU=""; TG_LOSS=""; TG_TRACE=""

    case ",$TG_TESTS," in
        *,http,*)
            TG_HTTP=$(run_http_test "$TG_IP" "$TG_NAME") || true; append_result "$TG_HTTP" ;;
    esac
    case ",$TG_TESTS," in
        *,ssh,*)
            TG_SSH=$(run_ssh_test "$TG_IP" "$TG_NAME") || true; append_result "$TG_SSH" ;;
    esac
    case ",$TG_TESTS," in
        *,pmtu,*)
            TG_PMTU=$(run_pmtu_test "$TG_IP" "$TG_NAME") || true; append_result "$TG_PMTU" ;;
    esac
    case ",$TG_TESTS," in
        # A device loopback is a legitimate loss/jitter target, same as pmtu
        # and traceroute above — no ENABLE_ gate, always available to declare.
        *,loss,*)
            TG_LOSS=$(run_loss_test "$TG_IP" "$TG_NAME") || true; append_result "$TG_LOSS" ;;
    esac
    case ",$TG_TESTS," in
        *,dns,*)
            R=$(run_dns_test "$TG_IP" "$TG_NAME") || true; append_result "$R" ;;
    esac
    case ",$TG_TESTS," in
        # A static SMB target is realistic (a real file server), unlike a
        # device loopback — so this gets an arm even though iperf3 doesn't.
        *,smb,*)
            if [ "$ENABLE_SMB" = "true" ]; then
                R=$(run_smb_test "$TG_IP" "$TG_NAME") || true; append_result "$R"
            fi ;;
    esac
    case ",$TG_TESTS," in
        # Deliberately UNGATED, unlike the smb arm above. Registering a
        # static target via POST /targets is already an explicit opt-in by
        # an operator, and the probe never issues DATA (see run_smtp_test's
        # comment) -- it cannot send mail even against a real production
        # relay. Requiring ENABLE_SMTP=true on top of that opt-in would force
        # standing up a local OpenSMTPD instance just to probe an external
        # target this node can do nothing dangerous against. This asymmetry
        # vs. smb is intentional, not a missed gate.
        *,smtp,*)
            R=$(run_smtp_test "$TG_IP" "$TG_NAME") || true; append_result "$R" ;;
    esac
    case ",$TG_TESTS," in
        *,traceroute,*)
            if [ "$TRACE_THIS_CYCLE" = "yes" ]; then
                TG_TRACE=$(run_traceroute_test "$TG_IP" "$TG_NAME") || true; append_result "$TG_TRACE"
            fi ;;
    esac

    # Same console row as the mesh loop above — cells a target doesn't
    # declare naturally stay "-" since TG_* was reset empty for this target.
    append_row "$(printf '%-14s %-15s %-5s %-5s %-5s %-6s %-3s' \
        "$TG_NAME" "$TG_IP" \
        "$(result_cell "$TG_HTTP" bool)" \
        "$(result_cell "$TG_SSH" bool)" \
        "$(result_cell "$TG_PMTU" bool)" \
        "$(result_cell "$TG_LOSS" loss)" \
        "$([ -n "$TG_TRACE" ] && printf '*' || printf -- '-')")"

    TESTED=$((TESTED + 1))
    j=$((j + 1))
done

# -------------------------------------------------------------------
# Configured resolver, if any. Skipped silently when DNS_SERVER is unset so
# labs without DNS in the topology see no spurious red cells.
# -------------------------------------------------------------------
if [ -n "${DNS_SERVER:-}" ]; then
    log "DNS test -> ${DNS_SERVER}"
    DNS_RESULT=$(run_dns_test "$DNS_SERVER" "dns:${DNS_SERVER}") || true
    append_result "$DNS_RESULT"
fi

log "Tested $TESTED targets"

# -------------------------------------------------------------------
# POST results to hub
# -------------------------------------------------------------------
# Guard on RESULTS rather than TESTED: a cycle with no peers can still have
# produced a static-target or DNS result worth submitting.
if [ -z "$RESULTS" ]; then
    log "No results produced, skipping submission"
    snapshot_note "no results produced this cycle"
    exit 0
fi

PAYLOAD=$(printf '{"source":"%s","results":[%s]}' "$MY_HOSTNAME" "$RESULTS")

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 \
    --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${HUB_URL}/results" 2>/dev/null) || HTTP_CODE="000"

SUBMIT_OK="no"
if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 300 ] 2>/dev/null; then
    log "Results submitted successfully (HTTP $HTTP_CODE)"
    SUBMIT_OK="yes"
else
    log "ERROR: failed to submit results (HTTP $HTTP_CODE)"
fi

# -------------------------------------------------------------------
# Console / test-status summary for this cycle. Rendered even on a failed
# submission — a node that cannot reach the hub is exactly when console
# visibility matters most.
#
# OK/FAIL counts come from the actual submitted payload, not a recount of
# the console rows above — smb/smtp/iperf3/dns results post to the hub the
# same as always but don't get their own column in the compact table, so
# counting from $RESULTS keeps the footer honest about everything that ran.
# -------------------------------------------------------------------
OK_COUNT=$(printf '%s' "$PAYLOAD" | jq '[.results[] | select(.success == true)] | length')
FAIL_COUNT=$(printf '%s' "$PAYLOAD" | jq '[.results[] | select(.success == false)] | length')

SUMMARY_TITLE=$(printf '%s   %s   %d targets' "$MY_HOSTNAME" "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$TESTED")
SUMMARY_HEADER=$(printf '%-14s %-15s %-5s %-5s %-5s %-6s %-3s' "TARGET" "IP" "H" "S" "M" "L" "T")
SUMMARY_FOOTER=$(printf '%s ok / %s fail   ->  hub %s' "$OK_COUNT" "$FAIL_COUNT" "$HTTP_CODE")

render_summary "$(printf '%s\n%s\n%s\n%s' "$SUMMARY_TITLE" "$SUMMARY_HEADER" "$ROWS" "$SUMMARY_FOOTER")"

[ "$SUBMIT_OK" = "yes" ] || exit 1
