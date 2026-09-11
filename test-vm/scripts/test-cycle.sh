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
MY_HOSTNAME=$(hostname)
SSH_KEY="${SSH_KEY:-/etc/lab-tester/id_lab}"

# -------------------------------------------------------------------
# Serialise test cycles.
#
# A slow traceroute (15 hops x 2s) against several targets can outlast the
# 60-second cron interval. Without a lock, cycles pile up on top of each
# other and the VM ends up running several at once, skewing every timing it
# reports. Skip this run if the previous one is still going.
# -------------------------------------------------------------------
LOCK_DIR="/run/lab-tester-test-cycle.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Clear a lock left behind by a killed run (older than 10 minutes).
    if [ -d "$LOCK_DIR" ] && [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then
        log "Removing stale lock"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" 2>/dev/null || { log "Could not acquire lock, skipping"; exit 0; }
    else
        log "Previous cycle still running, skipping this run"
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
    exit 1
fi

# Validate JSON
if ! printf '%s' "$ENDPOINTS" | jq empty 2>/dev/null; then
    log "ERROR: invalid JSON from /endpoints"
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

    # An iperf3 server handles one client at a time. With every VM testing
    # every other VM on the same 60-second tick, collisions are routine and
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
# Build the target list: the test-VM mesh plus any static targets the hub
# holds (router loopbacks, outside addresses — things that run no agent).
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

    # Traceroute when scheduled, or when something just failed on this path.
    _failed_now="no"
    printf '%s' "$HTTP_RESULT$SSH_RESULT" | grep -q '"success":false' && _failed_now="yes"

    if [ "$TRACE_THIS_CYCLE" = "yes" ] || [ "$_failed_now" = "yes" ]; then
        [ "$_failed_now" = "yes" ] && log "  Traceroute -> $EP_IP (triggered by failure)" \
                                  || log "  Traceroute -> $EP_IP"
        TRACE_RESULT=$(run_traceroute_test "$EP_IP" "$EP_HOSTNAME") || true
        append_result "$TRACE_RESULT"
    fi

    # iperf3 (optional). A skipped run returns nothing, and appending that
    # blindly would leave a trailing comma and produce invalid JSON.
    if [ "$ENABLE_IPERF" = "true" ]; then
        log "  iperf3 test -> $EP_IP"
        IPERF_RESULT=$(run_iperf3_test "$EP_IP" "$EP_HOSTNAME") || IPERF_RESULT=""
        append_result "$IPERF_RESULT"
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

    case ",$TG_TESTS," in
        *,http,*)
            R=$(run_http_test "$TG_IP" "$TG_NAME") || true; append_result "$R" ;;
    esac
    case ",$TG_TESTS," in
        *,ssh,*)
            R=$(run_ssh_test "$TG_IP" "$TG_NAME") || true; append_result "$R" ;;
    esac
    case ",$TG_TESTS," in
        *,pmtu,*)
            R=$(run_pmtu_test "$TG_IP" "$TG_NAME") || true; append_result "$R" ;;
    esac
    case ",$TG_TESTS," in
        *,dns,*)
            R=$(run_dns_test "$TG_IP" "$TG_NAME") || true; append_result "$R" ;;
    esac
    case ",$TG_TESTS," in
        *,traceroute,*)
            if [ "$TRACE_THIS_CYCLE" = "yes" ]; then
                R=$(run_traceroute_test "$TG_IP" "$TG_NAME") || true; append_result "$R"
            fi ;;
    esac

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

if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 300 ] 2>/dev/null; then
    log "Results submitted successfully (HTTP $HTTP_CODE)"
else
    log "ERROR: failed to submit results (HTTP $HTTP_CODE)"
    exit 1
fi
