#!/usr/bin/env bash
# ==============================================================================
# gpu-throttle.sh — Dynamic throttle of P2/P3 workloads based on Frigate health
# ==============================================================================
set -euo pipefail

[ -f /etc/calypso-gpu.env ] && . /etc/calypso-gpu.env

FRIGATE_API="${FRIGATE_API:-http://localhost:5000}"
MQTT_HOST="${GPU_MQTT_HOST:-192.168.50.125}"
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"
THROTTLE_TOPIC="${GPU_MQTT_THROTTLE_TOPIC:-calypso_frigate/maintenance/throttle}"

mqtt_publish() {
    command -v mosquitto_pub >/dev/null 2>&1 || return 0
    timeout 5 mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$THROTTLE_TOPIC" -m "$1" -r >/dev/null 2>&1 || true
}

# Get minimum detection_fps across all cameras that have detection enabled
MIN_FPS=$(curl -fsS --max-time 3 "$FRIGATE_API/api/stats" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    cameras = d.get('cameras', {})
    fps_values = [float(c.get('detection_fps', 0)) for c in cameras.values()
                  if c.get('detection_fps') is not None and float(c.get('detection_fps', 0)) > 0]
    if fps_values:
        print(min(fps_values))
    else:
        print(-1)
except Exception:
    print(-1)
" 2>/dev/null || echo "-1")

if [ "$MIN_FPS" = "-1" ]; then
    # Cannot read stats or no active detection, don't throttle blindly
    exit 0
fi

MIN_FPS_INT=${MIN_FPS%.*}

if [ "${MIN_FPS_INT:-0}" -lt 3 ] 2>/dev/null; then
    echo "[gpu-throttle] detection_fps=$MIN_FPS < 3 — pausing P2/P3"
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"action\":\"pause\",\"reason\":\"detection_fps_low\",\"fps\":$MIN_FPS}"
    for ctn in cas-immich-ml cas-core demucs; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${ctn}$"; then
            docker pause "$ctn" 2>/dev/null || true
        fi
    done
elif [ "${MIN_FPS_INT:-0}" -ge 5 ] 2>/dev/null; then
    for ctn in cas-immich-ml cas-core demucs; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${ctn}$"; then
            state=$(docker inspect --format '{{.State.Paused}}' "$ctn" 2>/dev/null || echo "false")
            if [ "$state" = "true" ]; then
                echo "[gpu-throttle] detection_fps=$MIN_FPS >= 5 — unpausing $ctn"
                docker unpause "$ctn" 2>/dev/null || true
            fi
        fi
    done
    mqtt_publish "{\"ts\":\"$(date -Iseconds)\",\"action\":\"resume\",\"reason\":\"detection_fps_ok\",\"fps\":$MIN_FPS}"
fi

