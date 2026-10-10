#!/usr/bin/env bash
# ==============================================================================
# gpu-usage-logger.sh — pre-start memory gate + audit logger for GPU workloads
# ==============================================================================
# Usage:
#   gpu-usage-logger.sh check <workload> <budget_mb>
#   gpu-usage-logger.sh start <workload>
#   gpu-usage-logger.sh stop  <workload>
#
# Called by each workload's systemd unit via ExecStartPre/ExecStartPost/ExecStopPost.
# ==============================================================================
set -euo pipefail

[ -f /etc/calypso-gpu.env ] && . /etc/calypso-gpu.env

ACTION="${1:-}"
WORKLOAD="${2:-unknown}"
BUDGET_MB="${3:-0}"

AUDIT_LOG="${GPU_AUDIT_LOG:-/var/log/gpu-audit.jsonl}"
MQTT_HOST="${GPU_MQTT_HOST:-192.168.50.125}"
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"
MQTT_AUDIT_TOPIC="${GPU_MQTT_AUDIT_TOPIC:-calypso_frigate/maintenance/audit}"

write_audit() {
    local event="$1" detail="${2:-}"
    local mem_used mem_free
    mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    mem_free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    mem_used="${mem_used// /}"
    mem_free="${mem_free// /}"
    local audit_file="${GPU_AUDIT_LOG:-/var/log/gpu-audit.jsonl}"
    if [ ! -w "$audit_file" ] && [ ! -w "$(dirname "$audit_file")" ]; then
        audit_file="$HOME/.gpu-audit.jsonl"
        touch "$audit_file" 2>/dev/null || audit_file="/tmp/gpu-audit.jsonl"
    fi
    local line
    line=$(printf '{"ts":"%s","workload":"%s","event":"%s","gpu_mem_used_mb":%s,"gpu_mem_free_mb":%s,"budget_mb":%s,"detail":"%s"}\n' \
        "$(date -Iseconds)" "$WORKLOAD" "$event" "${mem_used:-0}" "${mem_free:-0}" "$BUDGET_MB" "$detail")
    echo "$line" >> "$audit_file" 2>/dev/null || true
    if command -v mosquitto_pub >/dev/null 2>&1; then
        timeout 5 mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "$MQTT_AUDIT_TOPIC" -m "$line" >/dev/null 2>&1 || true
    fi
}

case "$ACTION" in
    check)
        MEM_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
        MEM_FREE="${MEM_FREE// /}"
        if [ -z "$MEM_FREE" ] || ! [[ "$MEM_FREE" =~ ^[0-9]+$ ]]; then
            echo "[gpu-usage-logger] ERROR: cannot query GPU memory (nvidia-smi failed or GPU wedged: $MEM_FREE)" >&2
            write_audit "check_failed" "gpu_query_failed:${MEM_FREE}"
            exit 1
        fi
        if [ "$MEM_FREE" -lt "$BUDGET_MB" ] 2>/dev/null; then
            echo "[gpu-usage-logger] REFUSED: $WORKLOAD needs ${BUDGET_MB}MB but only ${MEM_FREE}MB free" >&2
            write_audit "start_refused" "need=${BUDGET_MB}MB,free=${MEM_FREE}MB"
            exit 1
        fi
        echo "[gpu-usage-logger] OK: $WORKLOAD gate passed (need=${BUDGET_MB}MB, free=${MEM_FREE}MB)"
        write_audit "check_passed" "need=${BUDGET_MB}MB,free=${MEM_FREE}MB"
        ;;
    start)
        write_audit "start" "workload_started"
        echo "[gpu-usage-logger] $WORKLOAD started — logged to $AUDIT_LOG"
        ;;
    stop)
        write_audit "stop" "workload_stopped"
        echo "[gpu-usage-logger] $WORKLOAD stopped — logged to $AUDIT_LOG"
        ;;
    *)
        echo "Usage: gpu-usage-logger.sh {check|start|stop} <workload> [<budget_mb>]" >&2
        exit 2
        ;;
esac
