#!/usr/bin/env bash
# ==============================================================================
# gpu-power-tune.sh — Hardware power & clock smoothing for Calypso RTX 5060 Ti
# ==============================================================================
set -euo pipefail

[ -f /etc/calypso-gpu.env ] && . /etc/calypso-gpu.env

GPU_POWER_LIMIT_W="${GPU_POWER_LIMIT_W:-160}"
GPU_MAX_CLOCK_MHZ="${GPU_MAX_CLOCK_MHZ:-2400}"

echo "[gpu-power-tune] Enabling NVIDIA persistence mode..."
nvidia-smi -pm 1

echo "[gpu-power-tune] Setting power limit to ${GPU_POWER_LIMIT_W}W..."
nvidia-smi -pl "$GPU_POWER_LIMIT_W"

if [ -n "$GPU_MAX_CLOCK_MHZ" ] && [ "$GPU_MAX_CLOCK_MHZ" -gt 0 ]; then
    echo "[gpu-power-tune] Setting locked GPU clocks ceiling to ${GPU_MAX_CLOCK_MHZ}MHz..."
    nvidia-smi -lgc 210,"$GPU_MAX_CLOCK_MHZ" || echo "[gpu-power-tune] Note: lock clocks not supported or restricted, continuing..."
fi

echo "[gpu-power-tune] Power tuning applied successfully:"
nvidia-smi --query-gpu=persistence_mode,power.limit,clocks.current.graphics,temperature.gpu --format=csv
