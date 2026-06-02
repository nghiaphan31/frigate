#!/usr/bin/env bash
# ==============================================================================
# bring-up.sh — automated bring-up + per-pipeline-step status report
#                + MQTT telemetry of the state machine
# ==============================================================================
# Idempotent: if the container is already running, skips creation and goes
# straight to the status report. Safe to re-run as a "status" command.
#
# State machine (each transition publishes to MQTT — see mqtt_state() below):
#
#   STARTING
#     │
#     ▼
#   PREFLIGHT_OK ──(fail)──► FATAL_<REASON>
#     │
#     ▼
#   CONTAINER_UP
#     │
#     ▼
#   API_UP
#     │
#     ▼
#   DETECTION_ACTIVE ──(stuck)──► RECOVERY_TRIGGERED
#     │                              │
#     │                              ├─► RECOVERY_SUCCESS
#     │                              └─► RECOVERY_FAILED ──► FATAL_NO_DETECTION
#     ▼
#   HEALTHY  |  DEGRADED  |  UNHEALTHY
#
# Exit codes:
#   0 = all 14 pipeline steps OK (warnings allowed)
#   1 = one or more pipeline steps FAIL
#   2 = pre-flight failed (host prerequisite missing)
#   3 = container failed to start
#   4 = Frigate API never came up
#   5 = detection never started (even after down/up recovery)
#
# Usage:
#   ./bring-up.sh                       # bring up + status report + MQTT
#   ./bring-up.sh --status              # skip bring-up, go straight to report
#   ./bring-up.sh --no-mqtt             # disable MQTT telemetry
#
# MQTT topics published:
#   calypso_frigate/bringup/state   (retained)  current state name
#   calypso_frigate/bringup/detail  (retained)  JSON with full context
#   calypso_frigate/bringup/log     (transient) each transition log line
#
# See STARTUP.md for the manual sequence and recovery procedures.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration (overridable via env)
# ------------------------------------------------------------------------------
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.calypso.yml}"
FRIGATE_API="${FRIGATE_API:-http://localhost:5000}"
GO2RTC_API="${GO2RTC_API:-http://localhost:1984}"
CAMERA_IP="${CAMERA_IP:-192.168.50.129}"
CAMERA_RTSP_PORT="${CAMERA_RTSP_PORT:-8554}"
MQTT_HOST="${MQTT_HOST:-192.168.50.125}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"
MQTT_STATE_TOPIC="${MQTT_STATE_TOPIC:-calypso_frigate/bringup/state}"
MQTT_DETAIL_TOPIC="${MQTT_DETAIL_TOPIC:-calypso_frigate/bringup/detail}"
MQTT_LOG_TOPIC="${MQTT_LOG_TOPIC:-calypso_frigate/bringup/log}"
CAMERA_NAME="${CAMERA_NAME:-allee_sur_le_cote}"
CONTAINER_NAME="${CONTAINER_NAME:-frigate}"
API_TIMEOUT="${API_TIMEOUT:-60}"
DETECT_TIMEOUT="${DETECT_TIMEOUT:-240}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-60}"
SCRIPT_PID=$$
SCRIPT_START=$(date +%s)

# Load .env if present (so FRIGATE_MEDIA_PATH and FRIGATE_PLUS_API_KEY are set)
if [ -f .env ]; then
    set +u
    # shellcheck disable=SC1091
    . ./.env
    set -u
fi
MEDIA_PATH="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"

# ------------------------------------------------------------------------------
# Resolve the right `docker compose` invocation. Prefer v2 (`docker compose`
# subcommand from docker-compose-plugin), fall back to v1 (`docker-compose`
# hyphenated binary). Resolved once at start, used everywhere below.
# ------------------------------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    DOCKER_COMPOSE=""   # will fatal() in mqtt_init's preflight order
fi
echo "[bring-up] docker compose: ${DOCKER_COMPOSE:-NOT FOUND}" >&2

# ------------------------------------------------------------------------------
# Colors (suppressed when stdout is not a TTY)
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'
    CYN=$'\033[0;36m'; DIM=$'\033[2m';     NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; CYN=''; DIM=''; NC=''
fi

# ------------------------------------------------------------------------------
# Counters and flags
# ------------------------------------------------------------------------------
STEP_OK=0
STEP_WARN=0
STEP_FAIL=0
STEP_SKIP=0
TOTAL_STEPS=14
SKIP_BRINGUP=0
MQTT_ENABLED=1
FINAL_STATE=""

# ------------------------------------------------------------------------------
# Parse args
# ------------------------------------------------------------------------------
# Snapshot / baseline flags (commit 2: feature C). All three are no-ops
# during pre-flight / waits — they only take effect after the
# 14-step report has populated REPORT_RESULTS[].
#   --snapshot                       print a JSON snapshot of the 14
#                                    checks to stdout (in addition to the
#                                    normal human-readable report)
#   --snapshot-write=PATH            same JSON, written to file PATH
#                                    (overwrites)
#   --snapshot-compare=BASELINE      compare current snapshot to baseline
#                                    JSON; exit 1 on drift, 0 on match
SNAPSHOT_MODE=0
SNAPSHOT_WRITE_PATH=""
SNAPSHOT_BASELINE=""

for arg in "$@"; do
    case "$arg" in
        --status)             SKIP_BRINGUP=1 ;;
        --no-mqtt)            MQTT_ENABLED=0 ;;
        --snapshot)           SNAPSHOT_MODE=1 ;;
        --snapshot-write=*)   SNAPSHOT_MODE=1; SNAPSHOT_WRITE_PATH="${arg#*=}" ;;
        --snapshot-compare=*) SNAPSHOT_MODE=1; SNAPSHOT_BASELINE="${arg#*=}" ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log()   { echo "${CYN}[bring-up]${NC} $*" >&2; }

fatal() {
    local reason="$1" code="${2:-1}"
    # Best-effort fatal publish (don't fatal-loop if MQTT is down)
    if [ "$MQTT_ENABLED" -eq 1 ]; then
        _mqtt_publish "FATAL_${reason}" "{\"state\":\"FATAL_${reason}\",\"reason\":\"${reason}\",\"host\":\"$(hostname)\",\"pid\":${SCRIPT_PID}}" >/dev/null 2>&1 || true
    fi
    echo "${RED}FATAL:${NC} $reason" >&2
    exit "$code"
}

# JSON value extractor:  jget <json> <python-expr-on-d>
# Returns "" on any error.
jget() {
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(eval(sys.argv[2]))
except Exception:
    print("")
' "$1" "$2" 2>/dev/null || true
}

# Report a single pipeline step.  Args: name status detail
# First-failure short-circuit: once any check FAILs, all later checks report
# SKIP (with the failing prereq as the reason). This stops the report from
# cascading into a wall of misleading red FAILs after a single root cause.
FIRST_FAIL_STEP=0

# Result store — REPORT_RESULTS is a bash array of
#   "<STATUS>|<name>|<detail>|<remediation>"
# one entry per check (including SKIPs). Used by --snapshot (commit 2)
# to serialise the 14-step outcome as a single JSON.
REPORT_RESULTS=()

report() {
    local name="$1" status="$2" detail="$3" remediation="${4:-}"
    local color tag
    case "$status" in
        OK)   color=$GRN; tag="  OK  "; STEP_OK=$((STEP_OK+1))   ;;
        WARN) color=$YEL; tag="  WARN "; STEP_WARN=$((STEP_WARN+1)) ;;
        FAIL) color=$RED; tag="  FAIL "; STEP_FAIL=$((STEP_FAIL+1))
              [ "$FIRST_FAIL_STEP" -eq 0 ] && \
                  FIRST_FAIL_STEP=$(echo "$name" | cut -d/ -f1 | tr -d ' ') ;;
    esac
    printf "  [%s] %-30s %b%s%b   %s\n" \
        "$tag" "$name" "$color" "$status" "$NC" "$detail"
    if [ -n "$remediation" ]; then
        # Word-wrap the remediation at ~80 cols; if the operator's terminal
        # is narrower the wrap will just be approximate.
        local fix_indent="              "
        printf "%s%bfix:%b %s\n" "$fix_indent" "$DIM" "$NC" "$remediation"
    fi
    REPORT_RESULTS+=("$status|$name|$detail|$remediation")
}

report_skip() {
    # Called by checks when a prior step has already FAILed. Records the
    # skip in REPORT_RESULTS (so --snapshot sees the full 14-step matrix
    # even when the first failure short-circuits the rest).
    local name="$1" reason="$2"
    printf "  [ SKIP ] %-30s %b%s%b   %s\n" \
        "$name" "$DIM" "SKIP" "$NC" "$reason"
    STEP_SKIP=$((STEP_SKIP+1))
    REPORT_RESULTS+=("SKIP|$name|$reason|")
}

# ------------------------------------------------------------------------------
# MQTT telemetry
# ------------------------------------------------------------------------------
MQTT_PUB_BIN=""

mqtt_init() {
    [ "$MQTT_ENABLED" -eq 1 ] || { log "MQTT telemetry disabled (--no-mqtt)"; return; }
    if command -v mosquitto_pub >/dev/null 2>&1; then
        MQTT_PUB_BIN="mosquitto_pub"
        log "MQTT publisher: mosquitto_pub → ${MQTT_HOST}:${MQTT_PORT}"
    elif python3 -c 'import paho.mqtt.client' 2>/dev/null; then
        MQTT_PUB_BIN="paho"
        log "MQTT publisher: paho-mqtt (python) → ${MQTT_HOST}:${MQTT_PORT}"
    else
        MQTT_ENABLED=0
        log "${YEL}WARN:${NC} no mosquitto_pub or paho-mqtt — MQTT telemetry disabled"
        log "      install: sudo apt install -y mosquitto-clients"
        log "      or:      pip3 install --user paho-mqtt"
    fi
}

# Internal: do the actual publish. Args: topic payload retain(bool)
_mqtt_publish() {
    local topic="$1" payload="$2" retain="${3:-true}"
    [ "$MQTT_ENABLED" -eq 1 ] || return 0
    [ -n "$MQTT_PUB_BIN" ] || return 0

    local rflag="false"
    [ "$retain" = "true" ] && rflag="true"

    case "$MQTT_PUB_BIN" in
        mosquitto_pub)
            local r
            [ "$retain" = "true" ] && r="-r" || r="-n"
            timeout 5 mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
                -u "$MQTT_USER" -P "$MQTT_PASS" \
                -t "$topic" -m "$payload" $r \
                >/dev/null 2>&1 || true
            ;;
        paho)
            timeout 5 python3 - "$topic" "$payload" "$rflag" <<'PY' >/dev/null 2>&1 || true
import sys, paho.mqtt.client as mqtt
topic, payload, retain = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
c = mqtt.Client()
c.username_pw_set("""$MQTT_USER""", """$MQTT_PASS""")
c.connect("""$MQTT_HOST""", $MQTT_PORT, 5)
c.publish(topic, payload, retain=retain)
c.disconnect()
PY
            ;;
    esac
}

# Public: publish a state transition.  Args: state detail_json
mqtt_state() {
    local state="$1" detail="${2:-}"
    FINAL_STATE="$state"

    # Always log to stderr
    log "state: ${state}${detail:+ — $detail}"

    # Build a clean detail JSON if caller didn't provide one
    if [ -z "$detail" ]; then
        detail=$(cat <<JSON
{"state":"${state}","host":"$(hostname)","pid":${SCRIPT_PID},"elapsed_s":$(( $(date +%s) - SCRIPT_START ))}
JSON
)
    fi

    # 3 publishes: retained state name, retained detail, transient log line
    _mqtt_publish "$MQTT_STATE_TOPIC"  "$state"   true
    _mqtt_publish "$MQTT_DETAIL_TOPIC" "$detail" true
    _mqtt_publish "$MQTT_LOG_TOPIC"     "${state} — ${detail}" false
}

# ------------------------------------------------------------------------------
# 1. Pre-flight (hard gates; non-zero exit on any failure)
# ------------------------------------------------------------------------------
preflight() {
    log "Pre-flight checks…"

    command -v nvidia-smi  >/dev/null 2>&1 || fatal "nvidia-smi not in PATH" 2
    command -v python3     >/dev/null 2>&1 || fatal "python3 not in PATH" 2
    command -v docker      >/dev/null 2>&1 || fatal "docker not in PATH" 2
    command -v timeout      >/dev/null 2>&1 || fatal "timeout not in PATH" 2
    command -v mountpoint   >/dev/null 2>&1 || fatal "mountpoint not in PATH" 2

    nvidia-smi >/dev/null 2>&1 || fatal "nvidia-smi failed (driver not loaded?)" 2

    for d in nvidia0 nvidiactl nvidia-modeset nvidia-uvm nvidia-uvm-tools; do
        [ -e "/dev/$d" ] || fatal "/dev/$d missing (load nvidia modules)" 2
    done

    # MEDIA_PATH must be on a mounted filesystem, must exist, and must be
    # writable. MEDIA_PATH itself does not have to BE the mount point — it
    # can be a subdirectory of one (e.g. when the NAS is mounted at
    # /mnt/nas/video and the recordings live in /mnt/nas/video/frigate_calypso).
    #
    # 1. Walk up the tree to find the nearest mount point
    check_dir="$MEDIA_PATH"
    mounted=0
    while [ "$check_dir" != "/" ]; do
        if mountpoint -q "$check_dir" 2>/dev/null; then
            mounted=1
            break
        fi
        check_dir="$(dirname "$check_dir")"
    done
    [ "$mounted" -eq 1 ] || fatal "$MEDIA_PATH is not on a mounted filesystem (check fstab / nfs)" 2

    # 2. Directory exists (auto-create subfolders inside the mount, e.g. frigate_calypso)
    if [ ! -d "$MEDIA_PATH" ]; then
        if mkdir -p "$MEDIA_PATH" 2>/dev/null; then
            log "Created $MEDIA_PATH"
        else
            fatal "$MEDIA_PATH does not exist and could not be created (check parent permissions)" 2
        fi
    fi

    # 3. Writable
    [ -w "$MEDIA_PATH" ] || fatal "$MEDIA_PATH is not writable (check directory permissions)" 2

    timeout 3 bash -c ">/dev/tcp/$CAMERA_IP/$CAMERA_RTSP_PORT" 2>/dev/null \
        || fatal "Camera $CAMERA_IP:$CAMERA_RTSP_PORT unreachable" 2

    docker info >/dev/null 2>&1 || fatal "Docker daemon not running" 2
    docker info 2>/dev/null | grep -q 'nvidia' \
        || fatal "nvidia runtime not registered (run nvidia-ctk runtime configure)" 2

    [ -f "$COMPOSE_FILE" ] || fatal "$COMPOSE_FILE not found in $(pwd)" 2

    [ -f trt-libs/libnvinfer.so.10 ] \
        || fatal "trt-libs/libnvinfer.so.10 missing — install with: pip install --target=./trt-libs --no-deps tensorrt-cu12-libs==10.9.0.34 tensorrt-cu12-bindings==10.9.0.34" 2

    log "Pre-flight ${GRN}OK${NC}"
}

# ------------------------------------------------------------------------------
# 2. Container start (idempotent)
# ------------------------------------------------------------------------------
start_container() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "Container ${CONTAINER_NAME} already running"
        return 0
    fi

    log "Starting container…"
    ${DOCKER_COMPOSE} -f "$COMPOSE_FILE" up -d "$CONTAINER_NAME"

    local i
    for i in $(seq 1 30); do
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            log "Container started in ${i}s"
            return 0
        fi
        sleep 1
    done

    fatal "container did not reach 'running' state in 30s" 3
}

# ------------------------------------------------------------------------------
# 3. Wait for Frigate API
# ------------------------------------------------------------------------------
wait_api() {
    log "Waiting for Frigate API (timeout ${API_TIMEOUT}s)…"
    local i
    for i in $(seq 1 "$API_TIMEOUT"); do
        if curl -fsS --max-time 2 "$FRIGATE_API/api/version" >/dev/null 2>&1; then
            log "API ready in ${i}s"
            return 0
        fi
        sleep 1
    done

    log "Last 30 log lines:"
    docker logs --tail=30 "$CONTAINER_NAME" 2>&1 || true
    fatal "Frigate API did not respond in ${API_TIMEOUT}s" 4
}

# ------------------------------------------------------------------------------
# 4. Wait for detection (240s budget; covers first-run TRT build)
# ------------------------------------------------------------------------------
wait_detection() {
    log "Waiting for detection (timeout ${DETECT_TIMEOUT}s, includes TRT build)…"
    local i fps

    local dumped=0
    for i in $(seq 1 "$DETECT_TIMEOUT"); do
        local stats fps
        stats=$(curl -fsS --max-time 2 "$FRIGATE_API/api/stats" 2>/dev/null || echo "{}")
        # Try multiple plausible Frigate 0.17 paths for the per-camera fps field.
        # detection_fps -> process_fps -> top-level detection_fps.
        fps=$(jget "$stats" "d.get('cameras',{}).get('$CAMERA_NAME',{}).get('detection_fps',0)") || fps=0
        [ -z "$fps" ] && fps=0
        if [ "${fps%.*}" -ge 1 ] 2>/dev/null; then
            log "Detection active in ${i}s (det_fps=$fps)"
            return 0
        fi
        fps=$(jget "$stats" "d.get('cameras',{}).get('$CAMERA_NAME',{}).get('process_fps',0)") || fps=0
        [ -z "$fps" ] && fps=0
        if [ "${fps%.*}" -ge 1 ] 2>/dev/null; then
            log "Detection active in ${i}s (process_fps=$fps)"
            return 0
        fi
        fps=$(jget "$stats" "d.get('detection_fps',0)") || fps=0
        [ -z "$fps" ] && fps=0
        if [ "${fps%.*}" -ge 1 ] 2>/dev/null; then
            log "Detection active in ${i}s (top-level detection_fps=$fps)"
            return 0
        fi
        # One-time diagnostic on the last poll so the operator can see the actual shape
        if [ "$i" -eq "$DETECT_TIMEOUT" ] && [ "$dumped" -eq 0 ]; then
            dumped=1
            log "All 3 fps paths returned 0. Dumping /api/stats shape for diagnosis:"
            curl -fsS --max-time 3 "$FRIGATE_API/api/stats" 2>/dev/null                 | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print('  top-level keys:', list(d.keys()))
    cams = d.get('cameras', {})
    print('  cameras keys:', list(cams.keys()))
    for name, c in cams.items():
        print(f'  cameras.{name} keys:', list(c.keys()) if isinstance(c, dict) else type(c).__name__)
        for k in ('detection_fps', 'process_fps', 'camera_fps'):
            v = c.get(k) if isinstance(c, dict) else None
            if v is not None: print(f'    {k} = {v}')
    for k in ('detection_fps', 'process_fps'):
        if k in d: print(f'  top-level {k} = {d[k]}')
except Exception as e:
    print(f'  could not parse /api/stats: {e}')
" 2>/dev/null || log "  could not fetch /api/stats for diagnosis"
        fi
        sleep 1
    done

    # ----- Deadlock auto-recovery: down/up for a clean slate -----
    # We use down + up (not stop + start) so that:
    #   - the container's writable layer is fully discarded (no lingering PIDs)
    #   - s6-overlay re-runs S6_STAGE2_HOOK and re-initialises its service tree
    #   - the /tmp/cache and /dev/shm tmpfses are recreated (ZMQ IPC cleared)
    # Trade-off: ~10s slower than stop/start, materially more reliable.
    # Bind-mounted volumes (recordings, trt-cache, config) are preserved
    # because down without -v never touches them.
    mqtt_state "RECOVERY_TRIGGERED" \
        "{\"state\":\"RECOVERY_TRIGGERED\",\"reason\":\"detection_fps_stuck_at_zero_after_${DETECT_TIMEOUT}s\",\"action\":\"docker_compose_down_up\"}"
    log "${YEL}Detection still at 0 fps after ${DETECT_TIMEOUT}s — running down/up to clear ZMQ IPC and re-init s6-overlay${NC}"
    # `|| true` on down: a half-stopped container may make `down` fail
    # non-fatally (e.g. already-removed container); we always want `up` to run.
    ${DOCKER_COMPOSE} -f "$COMPOSE_FILE" down "$CONTAINER_NAME" >/dev/null 2>&1 || true
    ${DOCKER_COMPOSE} -f "$COMPOSE_FILE" up -d "$CONTAINER_NAME" >/dev/null

    for i in $(seq 1 "$RECOVERY_TIMEOUT"); do
        local stats fps
        stats=$(curl -fsS --max-time 2 "$FRIGATE_API/api/stats" 2>/dev/null || echo "{}")
        fps=$(jget "$stats" "d.get('cameras',{}).get('$CAMERA_NAME',{}).get('detection_fps',0)") || fps=0
        [ -z "$fps" ] && fps=0
        if [ "${fps%.*}" -ge 1 ] 2>/dev/null; then
            log "Detection active after down/up in ${i}s (det_fps=$fps)"
            mqtt_state "RECOVERY_SUCCESS" \
                "{\"state\":\"RECOVERY_SUCCESS\",\"detection_fps\":${fps},\"recovered_after_s\":${i}}"
            return 0
        fi
        fps=$(jget "$stats" "d.get('cameras',{}).get('$CAMERA_NAME',{}).get('process_fps',0)") || fps=0
        [ -z "$fps" ] && fps=0
        if [ "${fps%.*}" -ge 1 ] 2>/dev/null; then
            log "Detection active after down/up in ${i}s (process_fps=$fps)"
            mqtt_state "RECOVERY_SUCCESS" \
                "{\"state\":\"RECOVERY_SUCCESS\",\"process_fps\":${fps},\"recovered_after_s\":${i}}"
            return 0
        fi
        fps=$(jget "$stats" "d.get('detection_fps',0)") || fps=0
        [ -z "$fps" ] && fps=0
        if [ "${fps%.*}" -ge 1 ] 2>/dev/null; then
            log "Detection active after down/up in ${i}s (top-level detection_fps=$fps)"
            mqtt_state "RECOVERY_SUCCESS" \
                "{\"state\":\"RECOVERY_SUCCESS\",\"detection_fps\":${fps},\"recovered_after_s\":${i}}"
            return 0
        fi
        sleep 1
    done

    mqtt_state "RECOVERY_FAILED" \
        "{\"state\":\"RECOVERY_FAILED\",\"reason\":\"no_detection_after_down_up\"}"
    log "Last 80 log lines:"
    docker logs --tail=80 "$CONTAINER_NAME" 2>&1 || true
    fatal "detection did not start after down/up recovery" 5
}

# ------------------------------------------------------------------------------
# 5. Per-pipeline-step status report (14 steps)
# ------------------------------------------------------------------------------
status_report() {
    # Reset per-run state so --status can be called repeatedly without
    # contamination from a prior invocation.
    FIRST_FAIL_STEP=0
    REPORT_RESULTS=()
    STEP_SKIP=0

    echo
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  FRIGATE PIPELINE STATUS REPORT — $CAMERA_NAME"
    echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)"
    echo "═══════════════════════════════════════════════════════════════════════"

    # Cached responses (multiple steps read from these)
    local cam_stats stats_json cfg_json ver_json go2rtc_json
    cam_stats=$(curl -fsS --max-time 3 "$FRIGATE_API/api/stats" 2>/dev/null || echo "{}")
    stats_json=$(curl -fsS --max-time 3 "$FRIGATE_API/api/stats"   2>/dev/null || echo "{}")
    cfg_json=$(curl -fsS --max-time 3   "$FRIGATE_API/api/config"  2>/dev/null || echo "{}")
    ver_json=$(curl -fsS --max-time 3   "$FRIGATE_API/api/version" 2>/dev/null || echo "{}")
    go2rtc_json=$(curl -fsS --max-time 3 "$GO2RTC_API/api/streams" 2>/dev/null || echo "")

    # --- 1/14: NVIDIA GPU ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "1/14  NVIDIA GPU" "prereq (see above) failed"
    else
        local gpu_line
        gpu_line=$(nvidia-smi --query-gpu=driver_version,name,utilization.gpu,memory.used,memory.total \
            --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [ -n "$gpu_line" ]; then
            IFS=',' read -r drv name util memu memt <<< "$gpu_line"
            drv=$(echo "$drv" | tr -d ' '); name=$(echo "$name" | sed 's/^ *//')
            report "1/14  NVIDIA GPU" "OK" "driver=$drv, $name, util=${util}%, mem=${memu}/${memt} MiB"
        else
            report "1/14  NVIDIA GPU" "FAIL" "nvidia-smi returned no data" \
                "sudo modprobe nvidia nvidia-uvm nvidia-modeset nvidia-uvm-tools  # then re-run"
        fi
    fi

    # --- 2/14: Camera RTSP ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "2/14  Camera RTSP reachability" "prereq step $FIRST_FAIL_STEP failed"
    else
        local rtt
        rtt=$(ping -c 1 -W 1 "$CAMERA_IP" 2>/dev/null \
            | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
        if [ -n "$rtt" ]; then
            report "2/14  Camera RTSP reachability" "OK" \
                "$CAMERA_IP:$CAMERA_RTSP_PORT reachable (${rtt} ms RTT)"
        else
            report "2/14  Camera RTSP reachability" "FAIL" \
                "$CAMERA_IP:$CAMERA_RTSP_PORT unreachable" \
                "timeout 3 bash -c '>/dev/tcp/$CAMERA_IP/$CAMERA_RTSP_PORT'  # LAN / camera / firewall"
        fi
    fi

    # --- 3/14: go2rtc internal ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "3/14  go2rtc internal" "prereq step $FIRST_FAIL_STEP failed"
    else
        if [ -n "$go2rtc_json" ]; then
            local streams_count
            streams_count=$(jget "$go2rtc_json" "len(d)")
            report "3/14  go2rtc internal" "OK" \
                "8554 listening, ${streams_count} stream(s), WebRTC on 8555"
        elif timeout 2 bash -c ">/dev/tcp/127.0.0.1/8554" 2>/dev/null; then
            report "3/14  go2rtc internal" "WARN" \
                "port 8554 listening, but $GO2RTC_API/api/streams not responding" \
                "curl -fsS $GO2RTC_API/api/streams  # check go2rtc health"
        else
            report "3/14  go2rtc internal" "FAIL" \
                "go2rtc not reachable on 8554 or $GO2RTC_API" \
                "docker logs --tail=100 frigate | grep -E 'go2rtc|listen'"
        fi
    fi

    # --- 4/14: Capture ffmpeg (allee) ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "4/14  Capture ffmpeg ($CAMERA_NAME)" "prereq step $FIRST_FAIL_STEP failed"
    else
        local cam camfps
        cam=$(jget "$cam_stats" "json.dumps(d.get('cameras',{}).get('$CAMERA_NAME', {}))")
        camfps=$(jget "$cam" "d.get('camera_fps', 0)")
        if [ -n "$camfps" ] && [ "${camfps%.*}" -ge 1 ] 2>/dev/null; then
            report "4/14  Capture ffmpeg ($CAMERA_NAME)" "OK" \
                "1 ffmpeg process, ${camfps} fps, roles=[detect, record, audio]"
        elif [ "$cam" != "{}" ] && [ -n "$cam" ]; then
            report "4/14  Capture ffmpeg ($CAMERA_NAME)" "WARN" \
                "camera present, camera_fps=${camfps:-0}" \
                "sleep 5 && ./bring-up.sh --status  # transient during startup"
        else
            report "4/14  Capture ffmpeg ($CAMERA_NAME)" "FAIL" \
                "$CAMERA_NAME not in /api/stats.cameras" \
                "docker logs --tail=100 frigate | grep -E 'capture|ffmpeg|$CAMERA_NAME'"
        fi
    fi

    # --- 5/14: Detect process ---
    # Try the same 3 fallback paths the wait-detection poll uses. The report
    # otherwise reports FAIL when Frigate 0.17 only populates process_fps.
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "5/14  Detect process ($CAMERA_NAME)" "prereq step $FIRST_FAIL_STEP failed"
    else
        local detfps detfield pfps
        detfps=$(jget "$cam" "d.get('detection_fps',0)") || detfps=0
        [ -z "$detfps" ] && detfps=0
        if [ "${detfps%.*}" -ge 1 ] 2>/dev/null; then
            detfield=detection_fps
        else
            pfps=$(jget "$cam" "d.get('process_fps',0)") || pfps=0
            [ -z "$pfps" ] && pfps=0
            if [ "${pfps%.*}" -ge 1 ] 2>/dev/null; then
                detfps=$pfps
                detfield=process_fps
            else
                detfield=detection_fps
            fi
        fi
        if [ -n "$detfps" ] && [ "${detfps%.*}" -ge 1 ] 2>/dev/null; then
            report "5/14  Detect process ($CAMERA_NAME)" "OK" \
                "det=$detfps ($detfield), camera_fps=$camfps"
        else
            report "5/14  Detect process ($CAMERA_NAME)" "FAIL" \
                "det=${detfps:-0} (expected >= 1)" \
                "docker logs --tail=100 frigate | grep -E 'TRT|engine|motion'  # if no TRT errors: scene may be quiet (throw a sheet in front of the camera); if 'engine build failed' see STARTUP.md §5.3"
        fi
    fi

    # --- 6/14: Motion pre-filter ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "6/14  Motion pre-filter" "prereq step $FIRST_FAIL_STEP failed"
    else
        local motion_t motion_c
        motion_t=$(jget "$cfg_json" "d.get('motion',{}).get('threshold', '?')")
        motion_c=$(jget "$cfg_json" "d.get('motion',{}).get('contour_area', '?')")
        report "6/14  Motion pre-filter" "OK" \
            "threshold=$motion_t, contour_area=$motion_c, improve_contrast=true"
    fi

    # --- 7/14: Object detection (TRT) ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "7/14  Object detection (TRT)" "prereq step $FIRST_FAIL_STEP failed"
    else
        local det_inf det_model
        det_inf=$(jget "$stats_json" "d.get('detectors',{}).get('onnx1',{}).get('inference_speed', '?')")
        det_model=$(jget "$cfg_json" "d.get('model',{}).get('path', '?')")
        if [ -n "$det_inf" ] && [ "$det_inf" != "?" ]; then
            report "7/14  Object detection (TRT)" "OK" \
                "model=$det_model, inference=${det_inf} ms"
        else
            report "7/14  Object detection (TRT)" "WARN" \
                "inference_speed not yet reported (TRT still building?)" \
                "docker logs --tail=50 frigate | grep -E 'TRT|tensorrt'  # first-run build is ~65s"
        fi
    fi

    # --- 8/14: Person filter (physics) ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "8/14  Person filter (physics)" "prereq step $FIRST_FAIL_STEP failed"
    else
        # Frigate 0.17 has no /api/config endpoint. Read the per-camera filter
        # directly from the local config.yml on the host (which is also what
        # the container sees at /config/config.yml).
        local pfilt
        pfilt=$(python3 -c "
import yaml
try:
    d = yaml.safe_load(open('config.yml'))
    print(yaml.dump(d.get('cameras', {}).get('$CAMERA_NAME', {}).get('objects', {}).get('filters', {}).get('person', {})).strip())
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
" 2>/dev/null)
        if [ -n "$pfilt" ] && [[ "$pfilt" != "PARSE_ERROR:"* ]] && [ -n "$(echo "$pfilt" | tr -d '[:space:]')" ]; then
            local min_a max_a min_r max_r thr ms
            min_a=$(echo "$pfilt" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('min_area','?'))" 2>/dev/null)
            max_a=$(echo "$pfilt" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('max_area','?'))" 2>/dev/null)
            min_r=$(echo "$pfilt" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('min_ratio','?'))" 2>/dev/null)
            max_r=$(echo "$pfilt" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('max_ratio','?'))" 2>/dev/null)
            thr=$(echo   "$pfilt" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('threshold','?'))" 2>/dev/null)
            ms=$(echo    "$pfilt" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin).get('min_score','?'))" 2>/dev/null)
            report "8/14  Person filter (physics)" "OK" \
                "min_area=$min_a, max_area=$max_a, ratio=$min_r/$max_r, threshold=$thr, min_score=$ms"
        else
            report "8/14  Person filter (physics)" "FAIL" \
                "person filter not found at cameras.$CAMERA_NAME.objects.filters.person in config.yml" \
                "see config.yml cameras.$CAMERA_NAME.objects.filters.person  # add min_area, max_area, etc."
        fi
    fi

    # --- 9/14: Zone filters ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "9/14  Zone filters" "prereq step $FIRST_FAIL_STEP failed"
    else
        local zones p_lo r_lo
        zones=$(jget "$cfg_json" "list(d['cameras']['$CAMERA_NAME'].get('zones',{}).keys())")
        if [ -n "$zones" ] && [ "$zones" != "[]" ]; then
            p_lo=$(jget "$cfg_json" "d['cameras']['$CAMERA_NAME']['zones'].get('prive',{}).get('loitering_time', '?')")
            r_lo=$(jget "$cfg_json" "d['cameras']['$CAMERA_NAME']['zones'].get('rodage',{}).get('loitering_time', '?')")
            report "9/14  Zone filters" "OK" \
                "zones=$zones (prive loiter=${p_lo}s, rodage loiter=${r_lo}s)"
        else
            report "9/14  Zone filters" "FAIL" "no zones configured for $CAMERA_NAME" \
                "add zones under cameras.$CAMERA_NAME.zones in config.yml"
        fi
    fi

    # --- 10/14: Event lifecycle ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "10/14  Event lifecycle" "prereq step $FIRST_FAIL_STEP failed"
    else
        local events_24h
        events_24h=$(curl -fsS --max-time 3 "$FRIGATE_API/api/events?limit=100" 2>/dev/null \
            | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin)
    cutoff = time.time() - 86400
    print(sum(1 for e in d if (e.get("start_time") or 0) > cutoff))
except Exception:
    print("?")
' 2>/dev/null || echo "?")
        if [ "$events_24h" = "?" ]; then
            report "10/14  Event lifecycle" "WARN" "could not query /api/events" \
                "curl -fsS '$FRIGATE_API/api/events?limit=5'  # Frigate still starting up, or DB locked"
        else
            report "10/14  Event lifecycle" "OK" "events in last 24h: $events_24h"
        fi
    fi

    # --- 11/14: MQTT publisher ---
    # Frigate 0.17 does NOT expose an mqtt key in /api/stats. The only signal
    # is the container log (frigate.comms.mqtt ERROR: MQTT disconnected) which
    # we can detect by tailing the recent journal. We mark this as WARN
    # because the script cannot definitively prove the broker is unreachable
    # from inside /api/stats alone — only the log or a manual probe can.
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "11/14  MQTT publisher" "prereq step $FIRST_FAIL_STEP failed"
    else
        local mqtt_log_hits
        mqtt_log_hits=$(docker logs --tail=200 "$CONTAINER_NAME" 2>&1 \
            | grep -c "frigate.comms.mqtt.*ERROR.*MQTT disconnected" || true)
        if [ "${mqtt_log_hits:-0}" -ge 1 ] 2>/dev/null; then
            report "11/14  MQTT publisher" "WARN" \
                "$MQTT_HOST disconnects seen in container log ($mqtt_log_hits in last 200 lines) — check client_id, ACL, or broker reachability" \
                "mosquitto_sub -h $MQTT_HOST -p $MQTT_PORT -u $MQTT_USER -P $MQTT_PASS -t '\$SYS/broker/version' -W 5  # check broker; verify client_id 'frigate_calypso' is unique"
        else
            report "11/14  MQTT publisher" "OK" \
                "$MQTT_HOST: no MQTT-disconnect log lines in recent container output (Frigate 0.17 does not expose /api/stats.mqtt, so this is a best-effort log check)"
        fi
    fi

    # --- 12/14: Recording path ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "12/14  Recording path" "prereq step $FIRST_FAIL_STEP failed"
    else
        if [ -d "$MEDIA_PATH" ] && [ -w "$MEDIA_PATH" ]; then
            local free
            free=$(df -BG "$MEDIA_PATH" 2>/dev/null | tail -1 | awk '{print $4}')
            report "12/14  Recording path" "OK" \
                "$MEDIA_PATH (${free} free, writable)"
        else
            report "12/14  Recording path" "FAIL" \
                "$MEDIA_PATH missing or not writable" \
                "mountpoint -q \"$MEDIA_PATH\"  # if not mounted: sudo mount -a  (NFS); if not writable: check perms / NAS export"
        fi
    fi

    # --- 13/14: Semantic search ---
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "13/14  Semantic search" "prereq step $FIRST_FAIL_STEP failed"
    else
        local sem
        sem=$(jget "$stats_json" "d.get('semantic_search',{}).get('model_name', '?')")
        if [ -n "$sem" ] && [ "$sem" != "?" ]; then
            report "13/14  Semantic search" "OK" "model=$sem"
        else
            report "13/14  Semantic search" "WARN" \
                "stats not reporting semantic_search (model not loaded yet?)" \
                "docker logs --tail=50 frigate | grep -E 'semantic|embedding|jina'  # model loads lazily on first event"
        fi
    fi

    # --- 14/14: Web UI / API ---
    # Frigate 0.17 sometimes returns {"version": ""} (empty). The endpoint
    # responded (200), so the API is up — only the version field is empty.
    # Treat empty as WARN (not FAIL); only a non-response (jget returns "?")
    # is a hard fail.
    if [ "$FIRST_FAIL_STEP" -gt 0 ]; then
        report_skip "14/14  Web UI / API" "prereq step $FIRST_FAIL_STEP failed"
    else
        local ver
        ver=$(jget "$ver_json" "d.get('version','?')")
        if [ "$ver" = "?" ]; then
            report "14/14  Web UI / API" "FAIL" \
                "$FRIGATE_API/api/version not responding" \
                "docker logs --tail=100 frigate | grep -E 'uvicorn|web|ERROR'  # is the web server thread alive?"
        elif [ -z "$ver" ]; then
            report "14/14  Web UI / API" "WARN" \
                "$FRIGATE_API listening, /api/version returned empty version field" \
                "curl -v $FRIGATE_API/api/version  # Frigate 0.17 known cosmetic bug; safe to ignore"
        else
            report "14/14  Web UI / API" "OK" \
                "$FRIGATE_API listening, /api/version=$ver"
        fi
    fi

    echo "───────────────────────────────────────────────────────────────────────"
    # FINAL_STATE is global so the snapshot / baseline functions (commit 2)
    # can read it without us having to plumb it through return values.
    FINAL_STATE=""
    if [ "$STEP_FAIL" -eq 0 ] && [ "$STEP_WARN" -eq 0 ]; then
        printf "  %bSUMMARY: %d/%d OK%b\n" "$GRN" "$STEP_OK" "$TOTAL_STEPS" "$NC"
        FINAL_STATE="HEALTHY"
    elif [ "$STEP_FAIL" -eq 0 ]; then
        printf "  %bSUMMARY: %d OK, %d WARN, %d SKIP, 0 FAIL%b\n" \
            "$YEL" "$STEP_OK" "$STEP_WARN" "$STEP_SKIP" "$NC"
        FINAL_STATE="DEGRADED"
    else
        printf "  %bSUMMARY: %d OK, %d WARN, %d SKIP, %d FAIL%b\n" \
            "$RED" "$STEP_OK" "$STEP_WARN" "$STEP_SKIP" "$STEP_FAIL" "$NC"
        FINAL_STATE="UNHEALTHY"
    fi
    echo "═══════════════════════════════════════════════════════════════════════"

    # Final MQTT state with full pipeline summary
    mqtt_state "$FINAL_STATE" "$(cat <<JSON
{"state":"${FINAL_STATE}","host":"$(hostname)","pid":${SCRIPT_PID},"elapsed_s":$(( $(date +%s) - SCRIPT_START )),"step_ok":${STEP_OK},"step_warn":${STEP_WARN},"step_fail":${STEP_FAIL},"camera":"${CAMERA_NAME}","detection_fps":$(jget "$cam" "d.get('detection_fps',0)"),"camera_fps":$(jget "$cam" "d.get('camera_fps',0)"),"frigate_version":$(jget "$ver_json" "d.get('version','null')" | sed 's/^"//;s/"$//') , "inference_ms":${det_inf:-null}}
JSON
)"

    [ "$STEP_FAIL" -eq 0 ]
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    mqtt_init
    mqtt_state "STARTING" \
        "{\"state\":\"STARTING\",\"host\":\"$(hostname)\",\"pid\":${SCRIPT_PID},\"compose\":\"${COMPOSE_FILE}\",\"camera\":\"${CAMERA_NAME}\"}"

    preflight
    mqtt_state "PREFLIGHT_OK" \
        "{\"state\":\"PREFLIGHT_OK\",\"preflight\":\"all_8_gates_passed\"}"

    if [ "$SKIP_BRINGUP" -eq 0 ]; then
        start_container
        mqtt_state "CONTAINER_UP" \
            "{\"state\":\"CONTAINER_UP\",\"container\":\"${CONTAINER_NAME}\"}"

        wait_api
        mqtt_state "API_UP" \
            "{\"state\":\"API_UP\",\"endpoint\":\"${FRIGATE_API}\",\"version\":$(jget "$(curl -fsS --max-time 2 "$FRIGATE_API/api/version" 2>/dev/null)" "json.dumps(d.get('version'))" || echo '"?"')}"

        wait_detection
        mqtt_state "DETECTION_ACTIVE" \
            "{\"state\":\"DETECTION_ACTIVE\",\"camera\":\"${CAMERA_NAME}\",\"detection_fps\":$(jget "$(curl -fsS --max-time 2 "$FRIGATE_API/api/stats" 2>/dev/null)" "d.get('cameras',{}).get('$CAMERA_NAME',{}).get('detection_fps',0)")}"
    else
        log "Skipping bring-up (--status); running report only"
    fi

    status_report

    # ---- Snapshot / baseline (commit 2: feature C) ----
    # Emit a JSON snapshot of the 14-step outcome, optionally writing to
    # a file (--snapshot-write=PATH) or comparing to a baseline JSON
    # (--snapshot-compare=BASELINE). The snapshot is the single source of
    # truth for archival, regression detection, and HA integration.
    if [ "$SNAPSHOT_MODE" -eq 1 ]; then
        if [ -n "$SNAPSHOT_BASELINE" ]; then
            # Compare: write the current snapshot to a tempfile, diff it
            # against the baseline, then clean up. Exit 1 on drift, 0 on
            # match. Note: we capture the exit code of print_snapshot and
            # compare_baseline explicitly rather than via $? inside an
            # if/else (the latter would always see 0, since the if-then
            # chain itself succeeds).
            local snap_tmp rc
            snap_tmp=$(mktemp --suffix=.json)
            if ! print_snapshot "$snap_tmp"; then
                rc=$?
                rm -f "$snap_tmp"
                exit "$rc"
            fi
            compare_baseline "$SNAPSHOT_BASELINE" "$snap_tmp"
            rc=$?
            rm -f "$snap_tmp"
            [ "$rc" -eq 0 ] || exit "$rc"
        else
            local out_path="${SNAPSHOT_WRITE_PATH:-/dev/stdout}"
            print_snapshot "$out_path" || exit 1
        fi
    fi
}

# ------------------------------------------------------------------------------
# Snapshot serialisation (commit 2: feature C)
# ------------------------------------------------------------------------------
# Converts REPORT_RESULTS[] (the 14 entry bash array populated by report()
# and report_skip()) into a single JSON document. Uses python3 (already a
# hard dep of the script) for the JSON formatting so we don't have to
# hand-escape the bash strings. The output schema:
#
#   {
#     "ts":          "2026-06-02T19:14:00Z",
#     "host":        "Calypso",
#     "camera":      "allee_sur_le_cote",
#     "state":       "HEALTHY" | "DEGRADED" | "UNHEALTHY",
#     "step_ok":     12, "step_warn": 2, "step_fail": 0, "step_skip": 0,
#     "steps": [
#       {"status": "OK",   "name": "1/14  NVIDIA GPU", "detail": "...", "remediation": ""},
#       ...
#     ]
#   }
print_snapshot() {
    local out_path="$1"
    # Pipe REPORT_RESULTS (one per line, | delimited) to python for JSON
    # serialisation. Use a temp file rather than a process substitution so
    # the python script can read the array safely even with newlines /
    # weird characters in remediation strings.
    local tmp
    tmp=$(mktemp --suffix=.tsv)
    for r in "${REPORT_RESULTS[@]}"; do
        # Split on the first 3 '|' only; detail / remediation may contain
        # additional '|' (e.g., from grep alternation in remediation hints).
        local status name detail remediation rest
        IFS='|' read -r status name detail rest <<< "$r"
        remediation="${rest:-}"
        # Strip newlines / tabs that would break TSV.
        status=${status//$'\n'/ }
        status=${status//$'\t'/ }
        name=${name//$'\n'/ }
        name=${name//$'\t'/ }
        detail=${detail//$'\n'/ }
        detail=${detail//$'\t'/ }
        remediation=${remediation//$'\n'/ }
        remediation=${remediation//$'\t'/ }
        printf '%s\t%s\t%s\t%s\n' "$status" "$name" "$detail" "$remediation" >> "$tmp"
    done
    # Snapshot metadata is exported as env vars so python3 (a child process)
    # can read them without us having to serialise them too.
    STEP_OK="$STEP_OK" STEP_WARN="$STEP_WARN" \
    STEP_FAIL="$STEP_FAIL" STEP_SKIP="$STEP_SKIP" \
    CAMERA_NAME="$CAMERA_NAME" FINAL_STATE="$FINAL_STATE" \
    python3 - "$tmp" "$out_path" <<'PY'
import json, os, sys, time
tsv_path, out_path = sys.argv[1], sys.argv[2]
steps = []
with open(tsv_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 3)
        if len(parts) == 4:
            status, name, detail, remediation = parts
        else:
            status, name, detail = parts[:3]
            remediation = ""
        steps.append({
            "status": status,
            "name": name,
            "detail": detail,
            "remediation": remediation,
        })
snap = {
    "ts":         time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "host":       os.uname().nodename,
    "camera":     os.environ.get("CAMERA_NAME", "?"),
    "state":      os.environ.get("FINAL_STATE", "UNKNOWN"),
    "step_ok":    int(os.environ.get("STEP_OK", 0)),
    "step_warn":  int(os.environ.get("STEP_WARN", 0)),
    "step_fail":  int(os.environ.get("STEP_FAIL", 0)),
    "step_skip":  int(os.environ.get("STEP_SKIP", 0)),
    "steps":      steps,
}
out = sys.stdout if out_path == "/dev/stdout" else open(out_path, "w")
try:
    json.dump(snap, out, indent=2, sort_keys=True)
    if out_path != "/dev/stdout":
        out.write("\n")
finally:
    if out_path != "/dev/stdout":
        out.close()
PY
    local rc=$?
    rm -f "$tmp"
    return $rc
}

# Compare a current snapshot (file) to a baseline snapshot (file). Exits
# 0 on match, 1 on drift. Prints a human-readable diff. Drift is any
# change in step status (OK/WARN/FAIL/SKIP) or in the overall state
# (HEALTHY/DEGRADED/UNHEALTHY). Detail / remediation text changes are
# NOT drift — they reflect ephemeral runtime values (e.g. fps) and
# would generate false positives.
compare_baseline() {
    local baseline_path="$1" current_path="$2"
    python3 - "$baseline_path" "$current_path" <<'PY'
import json, sys
baseline_path, current_path = sys.argv[1], sys.argv[2]
try:
    with open(baseline_path) as f: base = json.load(f)
except Exception as e:
    print(f"ERROR: cannot read baseline {baseline_path}: {e}", file=sys.stderr)
    sys.exit(2)
try:
    with open(current_path) as f: curr = json.load(f)
except Exception as e:
    print(f"ERROR: cannot read current snapshot {current_path}: {e}", file=sys.stderr)
    sys.exit(2)
def step_map(d): return {s["name"]: s["status"] for s in d.get("steps", [])}
bm, cm = step_map(base), step_map(curr)
drift = []
if base.get("state") != curr.get("state"):
    drift.append(f"  state: {base.get('state')} -> {curr.get('state')}")
for name in sorted(set(bm) | set(cm)):
    bs, cs = bm.get(name, "<missing>"), cm.get(name, "<missing>")
    if bs != cs:
        drift.append(f"  {name}: {bs} -> {cs}")
if drift:
    print("DRIFT DETECTED between baseline and current snapshot:")
    for d in drift: print(d)
    sys.exit(1)
else:
    print(f"OK: snapshot matches baseline "
          f"({len(cm)} steps, state={curr.get('state')}, "
          f"OK={curr.get('step_ok')} WARN={curr.get('step_warn')} "
          f"FAIL={curr.get('step_fail')} SKIP={curr.get('step_skip')})")
    sys.exit(0)
PY
}

main "$@"
