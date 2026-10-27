#!/usr/bin/env bash
# ==============================================================================
# /usr/local/bin/cas-container-ready.sh
# Fast non-blocking ExecCondition check for CAS background units.
# Returns: 0 (proceed), 1 (skip cleanly).
# ==============================================================================
set -euo pipefail

CONTAINER="${1:-cas-core}"
MAX_LOAD="${2:-12.0}"

# 1. Check Docker daemon responsiveness and container health
if ! docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null | grep -q "^healthy$"; then
    echo "Condition failed: Container $CONTAINER is not healthy" >&2
    exit 1
fi

# 2. Check 1-minute system load average
LOAD1=$(awk '{print $1}' /proc/loadavg)
if (( $(echo "$LOAD1 > $MAX_LOAD" | bc -l 2>/dev/null || awk -v l="$LOAD1" -v m="$MAX_LOAD" 'BEGIN{print (l>m)?1:0}') )); then
    echo "Condition failed: Load average ($LOAD1) exceeds threshold ($MAX_LOAD)" >&2
    exit 1
fi

# 3. Check SQLite WAL size threshold (< 256 MB)
WAL_DIR="/home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/CAS_Management/local_ssd/vault/index"
if [ -d "$WAL_DIR" ]; then
    TOTAL_WAL_BYTES=$(find "$WAL_DIR" -name "*.db-wal" -exec stat -c %s {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')
    if [ "$TOTAL_WAL_BYTES" -gt 268435456 ]; then
        echo "Condition failed: WAL files size (${TOTAL_WAL_BYTES} bytes) exceeds 256MB" >&2
        exit 1
    fi
fi

exit 0
