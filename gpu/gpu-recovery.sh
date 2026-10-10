#!/usr/bin/env bash
# ==============================================================================
# gpu-recovery.sh — GPU wedge recovery for Calypso (RTX 5060 Ti)
# ==============================================================================
# Sequence: stop all GPU containers → kill GDM & X/Wayland sessions → rmmod nvidia_* →
#           (PCIe reset if needed) → modprobe nvidia_* → restart Frigate (P1) → P2/P3
#
# Modes:
#   ./gpu-recovery.sh                    dry-run (default)
#   ./gpu-recovery.sh --apply            execute recovery
#   ./gpu-recovery.sh --apply --force    execute recovery (bypass rate limit)
#   ./gpu-recovery.sh --status           check GPU health only
#   ./gpu-recovery.sh --reset-rate-limit reset the rate-limit counter
# ==============================================================================
set -euo pipefail

MODE="--dry-run"
FORCE=0
LOG_FILE="/var/log/gpu-recovery.log"
MQTT_HOST="${GPU_MQTT_HOST:-192.168.50.125}"
MQTT_TOPIC="calypso_frigate/maintenance/gpu-recovery"
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"
RECOVERY_STATE_FILE="/var/run/gpu-recovery-count"
MAX_RECOVERIES_PER_HOUR=3
PCI_DEV="0000:2b:00.0"

for arg in "$@"; do
    case "$arg" in
        --apply) MODE="--apply" ;;
        --status) MODE="--status" ;;
        --dry-run) MODE="--dry-run" ;;
        --force) FORCE=1 ;;
        --reset-rate-limit)
            rm -f "$RECOVERY_STATE_FILE" /run/gpu-recovery-count /tmp/gpu-recovery-count 2>/dev/null || true
            echo "Rate limit counter reset."
            exit 0
            ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
    esac
done

# Source shared GPU env if available
[ -f /etc/calypso-gpu.env ] && . /etc/calypso-gpu.env

# Fallback log location if /var/log is not writable
[ -w "$(dirname "$LOG_FILE")" ] 2>/dev/null || LOG_FILE="$HOME/.gpu-recovery.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/gpu-recovery.log"

log() {
    local msg
    msg="$(date -Iseconds) [gpu-recovery] $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

mqtt_publish() {
    local payload="$1"
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout 5 mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$MQTT_TOPIC" -m "$payload" -r >/dev/null 2>&1 || true
}

audit_log() {
    local event="$1" detail="${2:-}"
    local gpu_mem_used gpu_util
    gpu_mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    local audit_file="${GPU_AUDIT_LOG:-/var/log/gpu-audit.jsonl}"
    if [ ! -w "$audit_file" ] && [ ! -w "$(dirname "$audit_file")" ]; then
        audit_file="$HOME/.gpu-audit.jsonl"
        touch "$audit_file" 2>/dev/null || audit_file="/tmp/gpu-audit.jsonl"
    fi
    local line
    line=$(printf '{"ts":"%s","workload":"gpu-recovery","event":"%s","gpu_mem_used_mb":%s,"gpu_util_pct":%s,"detail":"%s"}\n' \
        "$(date -Iseconds)" "$event" "${gpu_mem_used// /}" "${gpu_util// /}" "$detail")
    echo "$line" >> "$audit_file" 2>/dev/null || true
}

# Rate limit: max 3 recoveries per hour
check_rate_limit() {
    if [ "$FORCE" -eq 1 ]; then
        log "FORCE mode: rate limit bypassed by operator"
        return 0
    fi
    local now count last_reset
    now=$(date +%s)
    if [ -f "$RECOVERY_STATE_FILE" ]; then
        read -r count last_reset < "$RECOVERY_STATE_FILE" 2>/dev/null || { count=0; last_reset=$now; }
        if [ $((now - last_reset)) -gt 3600 ]; then
            echo "0 $now" > "$RECOVERY_STATE_FILE" 2>/dev/null || true
            count=0
        fi
    else
        count=0
        echo "0 $now" > "$RECOVERY_STATE_FILE" 2>/dev/null || true
        last_reset=$now
    fi
    if [ "$count" -ge "$MAX_RECOVERIES_PER_HOUR" ]; then
        log "RATE LIMIT: $count recoveries in last hour (max=$MAX_RECOVERIES_PER_HOUR) — use --force to override"
        mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"event\":\"rate_limited\",\"count\":$count,\"max\":$MAX_RECOVERIES_PER_HOUR}"
        audit_log "rate_limited" "count=$count"
        return 1
    fi
    echo "$((count + 1)) ${last_reset:-$now}" > "$RECOVERY_STATE_FILE" 2>/dev/null || true
    return 0
}

# GPU health check — returns 0=healthy, 1=wedged, 2=degraded
check_gpu_health() {
    if ! timeout 10 nvidia-smi > /dev/null 2>&1; then
        log "GPU WEDGED: nvidia-smi timeout/failure"
        return 1
    fi

    local cu_rc
    cu_rc=$(python3 -c "import ctypes; cuda=ctypes.CDLL('libcuda.so.1'); print(cuda.cuInit(0))" 2>/dev/null || echo "1")
    if [ "$cu_rc" != "0" ]; then
        log "GPU WEDGED: cuInit returned $cu_rc (expected 0)"
        return 1
    fi

    local temp
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
    temp="${temp// /}"
    if [ -n "$temp" ] && [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -gt 92 ] 2>/dev/null; then
        log "GPU DEGRADED: temperature ${temp}°C > 92°C"
        return 2
    fi

    local util
    util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
    util="${util// /}"
    [ -n "$util" ] && log "GPU health OK: temp=${temp:-?}°C, util=${util:-?}%"

    return 0
}

do_recovery() {
    log "=== RECOVERY START (mode=$MODE) ==="
    audit_log "recovery_start" "mode=$MODE"
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"event\":\"recovery_start\"}"

    # Step 1: Stop ALL GPU containers (reverse priority order)
    log "Step 1: Stopping GPU containers..."
    for ctn in demucs cas-core cas-immich-ml frigate; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ctn}$"; then
            log "  stopping container $ctn"
            if [ "$MODE" = "--apply" ]; then
                timeout 30 docker stop "$ctn" 2>/dev/null || true
            fi
        fi
    done

    # Step 2: Terminate GDM and all graphical sessions holding nvidia_drm
    log "Step 2: Terminating GDM and display sessions (holds nvidia_drm refcount)..."
    if [ "$MODE" = "--apply" ]; then
        systemctl stop gdm.service 2>/dev/null || true
        loginctl terminate-user gdm 2>/dev/null || true
        pkill -9 -u gdm 2>/dev/null || true
        pkill -9 -f "gnome-shell|gdm-x-session|gdm-session-worker|Xorg" 2>/dev/null || true
        fuser -k -9 /dev/nvidia* /dev/dri/* 2>/dev/null || true
        sleep 2
    fi

    # Step 3: Unload NVIDIA kernel modules
    log "Step 3: Unloading NVIDIA kernel modules..."
    if [ "$MODE" = "--apply" ]; then
        # Order matters: drm first, then modeset, then uvm, then nvidia
        for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
            local retries=5
            while lsmod | grep -q "^${mod}" && [ "$retries" -gt 0 ]; do
                log "  rmmod $mod (attempt $retries)"
                if rmmod "$mod" 2>/dev/null; then
                    break
                fi
                # Find holders and force kill
                local holders
                holders=$(lsof /dev/nvidia* /dev/dri/* 2>/dev/null | grep -v "^COMMAND" | awk '{print $1, $2}' | sort -u || echo "")
                if [ -n "$holders" ]; then
                    log "  force killing holders: $holders"
                    echo "$holders" | awk '{print $2}' | xargs -r kill -9 2>/dev/null || true
                fi
                sleep 1
                retries=$((retries - 1))
            done
            if lsmod | grep -q "^${mod}"; then
                log "  WARN: could not unload $mod (refcount still > 0)"
            fi
        done
        sleep 2
    fi

    # Step 4: Hardware / PCIe reset & Reload NVIDIA kernel modules
    log "Step 4: Loading NVIDIA kernel modules..."
    if [ "$MODE" = "--apply" ]; then
        # If /sys/bus/pci/devices/$PCI_DEV/reset exists, trigger PCIe function-level reset
        if [ -w "/sys/bus/pci/devices/$PCI_DEV/reset" ]; then
            log "  triggering PCIe function-level reset on $PCI_DEV"
            echo 1 > "/sys/bus/pci/devices/$PCI_DEV/reset" 2>/dev/null || true
            sleep 1
        fi

        modprobe nvidia 2>/dev/null || true
        modprobe nvidia-uvm 2>/dev/null || true
        modprobe nvidia-modeset 2>/dev/null || true
        sleep 2

        # Check if nvidia-smi works
        if ! nvidia-smi > /dev/null 2>&1; then
            log "WARN: nvidia-smi failed after first modprobe, attempting PCI remove/rescan cycle..."
            if [ -w "/sys/bus/pci/devices/$PCI_DEV/remove" ] && [ -w "/sys/bus/pci/rescan" ]; then
                echo 1 > "/sys/bus/pci/devices/$PCI_DEV/remove" 2>/dev/null || true
                sleep 2
                echo 1 > "/sys/bus/pci/rescan" 2>/dev/null || true
                sleep 2
                modprobe nvidia 2>/dev/null || true
                modprobe nvidia-uvm 2>/dev/null || true
                modprobe nvidia-modeset 2>/dev/null || true
                sleep 2
            fi
        fi

        # Final check
        if ! nvidia-smi > /dev/null 2>&1; then
            log "FATAL: nvidia-smi failed after modprobe — REBOOT REQUIRED"
            mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"event\":\"recovery_failed\",\"reason\":\"modprobe_failed\"}"
            audit_log "recovery_failed" "modprobe_failed"
            return 1
        fi
        log "  nvidia-smi OK after modprobe"
    fi

    # Step 5: Restart containers in priority order (P1 first, wait, then P2)
    log "Step 5: Restarting Frigate (P1)..."
    if [ "$MODE" = "--apply" ]; then
        systemctl restart frigate-stack.service || true
        local i
        for i in $(seq 1 120); do
            if curl -fsS --max-time 2 http://localhost:5000/api/version > /dev/null 2>&1; then
                log "  Frigate API up in ${i}s"
                break
            fi
            sleep 1
        done
    fi

    # Step 6: Restart P2 containers (30s delay to let Frigate stabilize)
    log "Step 6: Waiting 30s before starting P2 workloads..."
    if [ "$MODE" = "--apply" ]; then
        sleep 30
        for svc in cas-immich-ml.service cas-core.service; do
            if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
                log "  starting $svc"
                systemctl start "$svc" 2>/dev/null || log "  WARN: $svc start failed"
            fi
        done
    fi

    log "=== RECOVERY COMPLETE ==="
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"event\":\"recovery_complete\"}"
    audit_log "recovery_complete" "mode=$MODE"
    return 0
}

# Main
case "$MODE" in
    --status)
        check_gpu_health
        exit $?
        ;;
    --dry-run)
        log "DRY-RUN mode — checking GPU health and showing recovery sequence"
        check_gpu_health || true
        do_recovery
        exit 0
        ;;
    --apply)
        if ! check_rate_limit; then
            exit 3
        fi
        if check_gpu_health; then
            log "GPU is healthy — recovery not needed"
            exit 0
        fi
        do_recovery
        exit $?
        ;;
    *)
        echo "Usage: gpu-recovery.sh [--dry-run|--apply|--status] [--force] [--reset-rate-limit]" >&2
        exit 2
        ;;
esac
