#!/usr/bin/env bash
# ==============================================================================
# gpu-watchdog.sh — GPU health watchdog for Calypso (RTX 5060 Ti)
# ==============================================================================
# Runs periodically (every 2 min via gpu-watchdog.timer).
# Checks: nvidia-smi, cuInit, temperature, memory, dmesg Xid errors.
# On failure: publishes MQTT alert, triggers gpu-recovery.sh if wedged.
# ==============================================================================
set -euo pipefail

[ -f /etc/calypso-gpu.env ] && . /etc/calypso-gpu.env

LOG_FILE="${GPU_RECOVERY_LOG:-/var/log/gpu-recovery.log}"
AUDIT_LOG="${GPU_AUDIT_LOG:-/var/log/gpu-audit.jsonl}"
MQTT_HOST="${GPU_MQTT_HOST:-192.168.50.125}"
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"
MQTT_TOPIC="${GPU_MQTT_STATE_TOPIC:-calypso_frigate/maintenance/gpu-state}"

[ -w "$(dirname "$LOG_FILE")" ] 2>/dev/null || LOG_FILE="$HOME/.gpu-recovery.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/gpu-recovery.log"

log() { echo "$(date -Iseconds) [gpu-watchdog] $*" | tee -a "$LOG_FILE" >&2; }

mqtt_publish() {
    local payload="$1"
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout 5 mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$MQTT_TOPIC" -m "$payload" -r >/dev/null 2>&1 || true
}

audit() {
    local event="$1" detail="${2:-}"
    local audit_file="${GPU_AUDIT_LOG:-/var/log/gpu-audit.jsonl}"
    if [ ! -w "$audit_file" ] && [ ! -w "$(dirname "$audit_file")" ]; then
        audit_file="$HOME/.gpu-audit.jsonl"
        touch "$audit_file" 2>/dev/null || audit_file="/tmp/gpu-audit.jsonl"
    fi
    printf '{"ts":"%s","workload":"gpu-watchdog","event":"%s","detail":"%s"}\n' \
        "$(date -Iseconds)" "$event" "$detail" >> "$audit_file" 2>/dev/null || true
}

trigger_recovery() {
    local reason="$1"
    local now
    now=$(date +%s)
    local last_file="/run/gpu-watchdog-last-recovery"
    if [ -f "$last_file" ]; then
        local last_ts
        read -r last_ts < "$last_file" 2>/dev/null || last_ts=0
        if [ $((now - last_ts)) -lt 300 ]; then
            log "Recovery was already attempted < 5 min ago — waiting before retry"
            return 0
        fi
    fi
    echo "$now" > "$last_file" 2>/dev/null || true
    if [ -x /usr/local/bin/gpu-recovery.sh ]; then
        /usr/local/bin/gpu-recovery.sh --apply || true
    fi
}

# 1. nvidia-smi alive check
if ! timeout 10 nvidia-smi > /dev/null 2>&1; then
    log "CRITICAL: nvidia-smi failed or timed out — GPU wedged"
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"wedged\",\"reason\":\"nvidia_smi_failed\"}"
    audit "gpu_wedged" "nvidia_smi_failed"
    trigger_recovery "nvidia_smi_failed"
    exit 0
fi

# 2. CUDA cuInit check
CU_RC=$(python3 -c "import ctypes; cuda=ctypes.CDLL('libcuda.so.1'); print(cuda.cuInit(0))" 2>/dev/null || echo "1")
if [ "$CU_RC" != "0" ]; then
    log "CRITICAL: cuInit failed (return code $CU_RC) — GPU wedged"
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"wedged\",\"reason\":\"cuInit_failed\",\"cu_rc\":\"$CU_RC\"}"
    audit "gpu_wedged" "cuInit_rc=$CU_RC"
    trigger_recovery "cuInit_failed"
    exit 0
fi

# 3. Temperature check
TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
TEMP="${TEMP// /}"
if [ -n "$TEMP" ] && [[ "$TEMP" =~ ^[0-9]+$ ]]; then
    if [ "$TEMP" -ge "${GPU_TEMP_CRITICAL:-90}" ] 2>/dev/null; then
        log "CRITICAL: GPU temp ${TEMP}°C >= ${GPU_TEMP_CRITICAL:-90}°C"
        mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"overheating\",\"temp\":$TEMP}"
        audit "overheating" "temp=${TEMP}"
        for ctn in demucs cas-core cas-immich-ml; do
            docker pause "$ctn" 2>/dev/null || true
        done
    elif [ "$TEMP" -ge "${GPU_TEMP_WARN:-80}" ] 2>/dev/null; then
        log "WARN: GPU temp ${TEMP}°C >= ${GPU_TEMP_WARN:-80}°C"
        mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"warm\",\"temp\":$TEMP}"
    fi
fi

# 4. Memory pressure check
MEM_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
MEM_FREE="${MEM_FREE// /}"
MEM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
MEM_USED="${MEM_USED// /}"
if [ -n "$MEM_FREE" ] && [[ "$MEM_FREE" =~ ^[0-9]+$ ]]; then
    if [ "$MEM_FREE" -le "${GPU_MEM_FREE_CRITICAL_MB:-1024}" ] 2>/dev/null; then
        log "CRITICAL: GPU memory free ${MEM_FREE} MB <= ${GPU_MEM_FREE_CRITICAL_MB:-1024} MB"
        mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"mem_critical\",\"mem_free_mb\":$MEM_FREE,\"mem_used_mb\":$MEM_USED}"
        audit "mem_critical" "free=${MEM_FREE}MB"
        docker pause demucs 2>/dev/null || true
    elif [ "$MEM_FREE" -le "${GPU_MEM_FREE_WARN_MB:-2048}" ] 2>/dev/null; then
        log "WARN: GPU memory free ${MEM_FREE} MB <= ${GPU_MEM_FREE_WARN_MB:-2048} MB"
    fi
fi

# 5. Xid errors in dmesg (last 200 lines)
XID_COUNT=$(dmesg 2>/dev/null | tail -200 | grep -c "NVRM: Xid" || true)
XID_COUNT=$(echo "${XID_COUNT:-0}" | head -1 | tr -d '[:space:]')
if [ -n "$XID_COUNT" ] && [[ "$XID_COUNT" =~ ^[0-9]+$ ]] && [ "$XID_COUNT" -gt 0 ]; then
    log "WARN: $XID_COUNT Xid errors in recent dmesg"
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"xid_errors\",\"count\":$XID_COUNT}"
    audit "xid_errors" "count=$XID_COUNT"
fi

# 6. Publish healthy heartbeat
UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
UTIL="${UTIL// /}"
mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"state\":\"healthy\",\"temp\":${TEMP:-0},\"mem_free_mb\":${MEM_FREE:-0},\"mem_used_mb\":${MEM_USED:-0},\"util_pct\":${UTIL:-0}}"

log "OK: temp=${TEMP:-?}°C, mem_free=${MEM_FREE:-?}MB, util=${UTIL:-?}%"

# 7. Dynamic throttle check if script exists
if [ -x /usr/local/bin/gpu-throttle.sh ]; then
    /usr/local/bin/gpu-throttle.sh || true
fi
