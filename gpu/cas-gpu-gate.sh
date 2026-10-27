#!/usr/bin/env bash
# ==============================================================================
# /usr/local/bin/cas-gpu-gate.sh
# Pre-flight VRAM and thermal gatekeeper for batch workloads.
# Returns: 0 (proceed), 1 (skip execution cleanly).
# ==============================================================================
set -euo pipefail

MIN_FREE_VRAM_MIB="${1:-4500}"
MAX_TEMP_C="${2:-76}"

# 1. Query current free VRAM and temperature with strict timeout
QUERY=$(timeout 3s nvidia-smi --query-gpu=memory.free,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)
if [ -z "$QUERY" ]; then
    echo "GPU Gate: nvidia-smi failed or timed out" >&2
    exit 1
fi

VRAM_FREE=$(echo "$QUERY" | awk -F',' '{print $1}' | tr -d ' ')
TEMP_C=$(echo "$QUERY" | awk -F',' '{print $2}' | tr -d ' ')

# 2. Check temperature
if [ "$TEMP_C" -gt "$MAX_TEMP_C" ]; then
    echo "GPU Gate: Temperature too high (${TEMP_C}°C > ${MAX_TEMP_C}°C). Skipping batch." >&2
    exit 1
fi

# 3. Check VRAM and evict Ollama models if necessary
if [ "$VRAM_FREE" -lt "$MIN_FREE_VRAM_MIB" ]; then
    # Inspect running Ollama models
    MODELS=$(curl -sf http://127.0.0.1:11434/api/ps 2>/dev/null | jq -r '.models[].name' 2>/dev/null || true)
    if [ -n "$MODELS" ]; then
        for m in $MODELS; do
            echo "GPU Gate: Evicting Ollama model $m to recover VRAM..." >&2
            curl -sf -X POST http://127.0.0.1:11434/api/generate -d "{\"model\": \"$m\", \"keep_alive\": 0}" >/dev/null 2>&1 || true
        done
        sleep 2
        # Re-check free VRAM
        VRAM_FREE=$(timeout 3s nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' || echo "0")
    fi
fi

# 4. Final condition evaluation
if [ "$VRAM_FREE" -lt "$MIN_FREE_VRAM_MIB" ]; then
    echo "GPU Gate: Insufficient VRAM (${VRAM_FREE} MiB < ${MIN_FREE_VRAM_MIB} MiB). Skipping batch." >&2
    exit 1
fi

echo "GPU Gate: Clear to proceed (VRAM free: ${VRAM_FREE} MiB, Temp: ${TEMP_C}°C)"
exit 0

