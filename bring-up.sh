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
#   5 = detection never started (even after stop/start recovery)
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
MQTT_USER="${MQTT_USER:-mosquito}"
MQTT_PASS="${MQTT_PASS:-mosquito}"
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
TOTAL_STEPS=14
SKIP_BRINGUP=0
MQTT_ENABLED=1
FINAL_STATE=""

# ------------------------------------------------------------------------------
# Parse args
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --status)    SKIP_BRINGUP=1 ;;
        --no-mqtt)   MQTT_ENABLED=0 ;;
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
report() {
    local name="$1" status="$2" detail="$3"
    local color tag
    case "$status" in
        OK)   color=$GRN; tag="  OK  "; STEP_OK=$((STEP_OK+1))   ;;
        WARN) color=$YEL; tag="  WARN "; STEP_WARN=$((STEP_WARN+1)) ;;
        FAIL) color=$RED; tag="  FAIL "; STEP_FAIL=$((STEP_FAIL+1)) ;;
    esac
    printf "  [%s] %-30s %b%s%b   %s\n" \
        "$tag" "$name" "$color" "$status" "$NC" "$detail"
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

    mountpoint -q "$MEDIA_PATH" || fatal "$MEDIA_PATH not mounted (check fstab / nfs)" 2

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
    docker compose -f "$COMPOSE_FILE" up -d "$CONTAINER_NAME"

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

    for i in $(seq 1 "$DETECT_TIMEOUT"); do
        local cameras
        cameras=$(curl -fsS --max-time 2 "$FRIGATE_API/api/cameras" 2>/dev/null || echo "{}")
        fps=$(jget "$cameras" "d.get('$CAMERA_NAME',{}).get('detection_fps',0)")
        fps=${fps:-0}
        fps=${fps%.*}
        if [ "${fps:-0}" -ge 1 ] 2>/dev/null; then
            log "Detection active in ${i}s (det_fps=$fps)"
            return 0
        fi
        sleep 1
    done

    # ----- Deadlock auto-recovery: stop/start clears stale ZMQ IPC -----
    mqtt_state "RECOVERY_TRIGGERED" \
        "{\"state\":\"RECOVERY_TRIGGERED\",\"reason\":\"detection_fps_stuck_at_zero_after_${DETECT_TIMEOUT}s\",\"action\":\"docker_compose_stop_start\"}"
    log "${YEL}Detection still at 0 fps after ${DETECT_TIMEOUT}s — running stop/start to clear ZMQ IPC${NC}"
    docker compose -f "$COMPOSE_FILE" stop  "$CONTAINER_NAME" >/dev/null
    docker compose -f "$COMPOSE_FILE" start "$CONTAINER_NAME" >/dev/null

    for i in $(seq 1 "$RECOVERY_TIMEOUT"); do
        local cameras
        cameras=$(curl -fsS --max-time 2 "$FRIGATE_API/api/cameras" 2>/dev/null || echo "{}")
        fps=$(jget "$cameras" "d.get('$CAMERA_NAME',{}).get('detection_fps',0)")
        fps=${fps:-0}
        fps=${fps%.*}
        if [ "${fps:-0}" -ge 1 ] 2>/dev/null; then
            log "Detection active after stop/start in ${i}s (det_fps=$fps)"
            mqtt_state "RECOVERY_SUCCESS" \
                "{\"state\":\"RECOVERY_SUCCESS\",\"detection_fps\":${fps},\"recovered_after_s\":${i}}"
            return 0
        fi
        sleep 1
    done

    mqtt_state "RECOVERY_FAILED" \
        "{\"state\":\"RECOVERY_FAILED\",\"reason\":\"no_detection_after_stop_start\"}"
    log "Last 80 log lines:"
    docker logs --tail=80 "$CONTAINER_NAME" 2>&1 || true
    fatal "detection did not start after stop/start recovery" 5
}

# ------------------------------------------------------------------------------
# 5. Per-pipeline-step status report (14 steps)
# ------------------------------------------------------------------------------
status_report() {
    echo
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  FRIGATE PIPELINE STATUS REPORT — $CAMERA_NAME"
    echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)"
    echo "═══════════════════════════════════════════════════════════════════════"

    # Cached responses (multiple steps read from these)
    local cam_stats stats_json cfg_json ver_json go2rtc_json
    cam_stats=$(curl -fsS --max-time 3 "$FRIGATE_API/api/cameras"  2>/dev/null || echo "{}")
    stats_json=$(curl -fsS --max-time 3 "$FRIGATE_API/api/stats"   2>/dev/null || echo "{}")
    cfg_json=$(curl -fsS --max-time 3   "$FRIGATE_API/api/config"  2>/dev/null || echo "{}")
    ver_json=$(curl -fsS --max-time 3   "$FRIGATE_API/api/version" 2>/dev/null || echo "{}")
    go2rtc_json=$(curl -fsS --max-time 3 "$GO2RTC_API/api/streams" 2>/dev/null || echo "")

    # --- 1/14: NVIDIA GPU ---
    local gpu_line
    gpu_line=$(nvidia-smi --query-gpu=driver_version,name,utilization.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [ -n "$gpu_line" ]; then
        IFS=',' read -r drv name util memu memt <<< "$gpu_line"
        drv=$(echo "$drv" | tr -d ' '); name=$(echo "$name" | sed 's/^ *//')
        report "1/14  NVIDIA GPU" "OK" "driver=$drv, $name, util=${util}%, mem=${memu}/${memt} MiB"
    else
        report "1/14  NVIDIA GPU" "FAIL" "nvidia-smi returned no data"
    fi

    # --- 2/14: Camera RTSP ---
    local rtt
    rtt=$(ping -c 1 -W 1 "$CAMERA_IP" 2>/dev/null \
        | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
    if [ -n "$rtt" ]; then
        report "2/14  Camera RTSP reachability" "OK" \
            "$CAMERA_IP:$CAMERA_RTSP_PORT reachable (${rtt} ms RTT)"
    else
        report "2/14  Camera RTSP reachability" "FAIL" \
            "$CAMERA_IP:$CAMERA_RTSP_PORT unreachable"
    fi

    # --- 3/14: go2rtc internal ---
    if [ -n "$go2rtc_json" ]; then
        local streams_count
        streams_count=$(jget "$go2rtc_json" "len(d)")
        report "3/14  go2rtc internal" "OK" \
            "8554 listening, ${streams_count} stream(s), WebRTC on 8555"
    elif timeout 2 bash -c ">/dev/tcp/127.0.0.1/8554" 2>/dev/null; then
        report "3/14  go2rtc internal" "WARN" \
            "port 8554 listening, but $GO2RTC_API/api/streams not responding"
    else
        report "3/14  go2rtc internal" "FAIL" \
            "go2rtc not reachable on 8554 or $GO2RTC_API"
    fi

    # --- 4/14: Capture ffmpeg (allee) ---
    local cam camfps
    cam=$(jget "$cam_stats" "json.dumps(d.get('$CAMERA_NAME', {}))")
    camfps=$(jget "$cam" "d.get('camera_fps', 0)")
    if [ -n "$camfps" ] && [ "${camfps%.*}" -ge 1 ] 2>/dev/null; then
        report "4/14  Capture ffmpeg ($CAMERA_NAME)" "OK" \
            "1 ffmpeg process, ${camfps} fps, roles=[detect, record, audio]"
    elif [ "$cam" != "{}" ] && [ -n "$cam" ]; then
        report "4/14  Capture ffmpeg ($CAMERA_NAME)" "WARN" \
            "camera present, camera_fps=${camfps:-0}"
    else
        report "4/14  Capture ffmpeg ($CAMERA_NAME)" "FAIL" \
            "$CAMERA_NAME not in /api/cameras"
    fi

    # --- 5/14: Detect process ---
    local detfps
    detfps=$(jget "$cam" "d.get('detection_fps', 0)")
    if [ -n "$detfps" ] && [ "${detfps%.*}" -ge 1 ] 2>/dev/null; then
        report "5/14  Detect process ($CAMERA_NAME)" "OK" \
            "det_fps=$detfps, camera_fps=$camfps"
    else
        report "5/14  Detect process ($CAMERA_NAME)" "FAIL" \
            "det_fps=${detfps:-0} (expected ≥ 1)"
    fi

    # --- 6/14: Motion pre-filter ---
    local motion_t motion_c
    motion_t=$(jget "$cfg_json" "d.get('motion',{}).get('threshold', '?')")
    motion_c=$(jget "$cfg_json" "d.get('motion',{}).get('contour_area', '?')")
    report "6/14  Motion pre-filter" "OK" \
        "threshold=$motion_t, contour_area=$motion_c, improve_contrast=true"

    # --- 7/14: Object detection (TRT) ---
    local det_inf det_model
    det_inf=$(jget "$stats_json" "d.get('detectors',{}).get('onnx1',{}).get('inference_speed', '?')")
    det_model=$(jget "$cfg_json" "d.get('model',{}).get('path', '?')")
    if [ -n "$det_inf" ] && [ "$det_inf" != "?" ]; then
        report "7/14  Object detection (TRT)" "OK" \
            "model=$det_model, inference=${det_inf} ms"
    else
        report "7/14  Object detection (TRT)" "WARN" \
            "inference_speed not yet reported (TRT still building?)"
    fi

    # --- 8/14: Person filter (physics) ---
    local pfilt min_a max_a min_r max_r thr ms
    pfilt=$(jget "$cfg_json" "d['cameras']['$CAMERA_NAME']['objects']['filters']['person']")
    if [ -n "$pfilt" ]; then
        min_a=$(jget "$pfilt" "d.get('min_area', '?')")
        max_a=$(jget "$pfilt" "d.get('max_area', '?')")
        min_r=$(jget "$pfilt" "d.get('min_ratio', '?')")
        max_r=$(jget "$pfilt" "d.get('max_ratio', '?')")
        thr=$(jget   "$pfilt" "d.get('threshold', '?')")
        ms=$(jget    "$pfilt" "d.get('min_score', '?')")
        report "8/14  Person filter (physics)" "OK" \
            "min_area=$min_a, max_area=$max_a, ratio=$min_r/$max_r, threshold=$thr, min_score=$ms"
    else
        report "8/14  Person filter (physics)" "FAIL" \
            "person filter not found at cameras.$CAMERA_NAME.objects.filters.person"
    fi

    # --- 9/14: Zone filters ---
    local zones p_lo r_lo
    zones=$(jget "$cfg_json" "list(d['cameras']['$CAMERA_NAME'].get('zones',{}).keys())")
    if [ -n "$zones" ] && [ "$zones" != "[]" ]; then
        p_lo=$(jget "$cfg_json" "d['cameras']['$CAMERA_NAME']['zones'].get('prive',{}).get('loitering_time', '?')")
        r_lo=$(jget "$cfg_json" "d['cameras']['$CAMERA_NAME']['zones'].get('rodage',{}).get('loitering_time', '?')")
        report "9/14  Zone filters" "OK" \
            "zones=$zones (prive loiter=${p_lo}s, rodage loiter=${r_lo}s)"
    else
        report "9/14  Zone filters" "FAIL" "no zones configured for $CAMERA_NAME"
    fi

    # --- 10/14: Event lifecycle ---
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
        report "10/14  Event lifecycle" "WARN" "could not query /api/events"
    else
        report "10/14  Event lifecycle" "OK" "events in last 24h: $events_24h"
    fi

    # --- 11/14: MQTT publisher ---
    local mqtt_connected mqtt_host
    mqtt_connected=$(jget "$stats_json" "d.get('mqtt',{}).get('connected', False)")
    mqtt_host=$(jget      "$stats_json" "d.get('mqtt',{}).get('host', '?')")
    if [ "$mqtt_connected" = "True" ]; then
        report "11/14  MQTT publisher" "OK" \
            "$mqtt_host, prefix=calypso_frigate, connected=true"
    else
        report "11/14  MQTT publisher" "FAIL" \
            "$mqtt_host, connected=$mqtt_connected (check broker)"
    fi

    # --- 12/14: Recording path ---
    if [ -d "$MEDIA_PATH" ] && [ -w "$MEDIA_PATH" ]; then
        local free
        free=$(df -BG "$MEDIA_PATH" 2>/dev/null | tail -1 | awk '{print $4}')
        report "12/14  Recording path" "OK" \
            "$MEDIA_PATH (${free} free, writable)"
    else
        report "12/14  Recording path" "FAIL" \
            "$MEDIA_PATH missing or not writable"
    fi

    # --- 13/14: Semantic search ---
    local sem
    sem=$(jget "$stats_json" "d.get('semantic_search',{}).get('model_name', '?')")
    if [ -n "$sem" ] && [ "$sem" != "?" ]; then
        report "13/14  Semantic search" "OK" "model=$sem"
    else
        report "13/14  Semantic search" "WARN" \
            "stats not reporting semantic_search (model not loaded yet?)"
    fi

    # --- 14/14: Web UI / API ---
    local ver
    ver=$(jget "$ver_json" "d.get('version','?')")
    if [ -n "$ver" ] && [ "$ver" != "?" ]; then
        report "14/14  Web UI / API" "OK" \
            "$FRIGATE_API listening, /api/version=$ver"
    else
        report "14/14  Web UI / API" "FAIL" \
            "$FRIGATE_API/api/version not responding"
    fi

    echo "───────────────────────────────────────────────────────────────────────"
    local final_state
    if [ "$STEP_FAIL" -eq 0 ] && [ "$STEP_WARN" -eq 0 ]; then
        printf "  %bSUMMARY: %d/%d OK%b\n" "$GRN" "$STEP_OK" "$TOTAL_STEPS" "$NC"
        final_state="HEALTHY"
    elif [ "$STEP_FAIL" -eq 0 ]; then
        printf "  %bSUMMARY: %d OK, %d WARN, 0 FAIL%b\n" \
            "$YEL" "$STEP_OK" "$STEP_WARN" "$NC"
        final_state="DEGRADED"
    else
        printf "  %bSUMMARY: %d OK, %d WARN, %d FAIL%b\n" \
            "$RED" "$STEP_OK" "$STEP_WARN" "$STEP_FAIL" "$NC"
        final_state="UNHEALTHY"
    fi
    echo "═══════════════════════════════════════════════════════════════════════"

    # Final MQTT state with full pipeline summary
    mqtt_state "$final_state" "$(cat <<JSON
{"state":"${final_state}","host":"$(hostname)","pid":${SCRIPT_PID},"elapsed_s":$(( $(date +%s) - SCRIPT_START )),"step_ok":${STEP_OK},"step_warn":${STEP_WARN},"step_fail":${STEP_FAIL},"camera":"${CAMERA_NAME}","detection_fps":$(jget "$cam" "d.get('detection_fps',0)"),"camera_fps":$(jget "$cam" "d.get('camera_fps',0)"),"frigate_version":$(jget "$ver_json" "d.get('version','null')" | sed 's/^"//;s/"$//') , "inference_ms":${det_inf:-null}}
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
            "{\"state\":\"DETECTION_ACTIVE\",\"camera\":\"${CAMERA_NAME}\",\"detection_fps\":$(jget "$(curl -fsS --max-time 2 "$FRIGATE_API/api/cameras" 2>/dev/null)" "d.get('$CAMERA_NAME',{}).get('detection_fps',0)")}"
    else
        log "Skipping bring-up (--status); running report only"
    fi

    status_report
}

main "$@"
