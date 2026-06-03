#!/usr/bin/env bash
# ==============================================================================
# tests/run-all.sh — run L1 + L2 + L3 in sequence (with skip option)
# ==============================================================================
# L1 + L2 run always (fast, no Frigate required, no GPU).
# L3 is opt-in via --with-bringup, since it spins up a full bring-up
# (1-4 minutes, requires GPU, container, NAS, etc.).
#
# Usage:
#   tests/run-all.sh                # L1 + L2 only (CI-safe, ~10 s)
#   tests/run-all.sh --with-bringup # L1 + L2 + L3 (operator's pre-merge gate)
#   tests/run-all.sh --bringup-only # L3 only (skip L1/L2, useful when re-running
#                                   # a failed L3 after a manual fix)
#
# Exit codes:
#   0  all requested layers passed
#   1  one or more requested layers FAILED (a layer that was skipped is
#      NOT counted as a failure)
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; CYN=''; NC=''
fi

WITH_BRINGUP=0
BRINGUP_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --with-bringup) WITH_BRINGUP=1 ;;
        --bringup-only) BRINGUP_ONLY=1 ;;
        --help|-h)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

OVERALL_RC=0
LAYER_RESULTS=()

run_layer() {
    local name="$1"
    local script="$2"
    local start
    start=$(date +%s)
    echo
    printf "  %b═══ running %s ═══%b\n" "$CYN" "$name" "$NC"
    if [ ! -x "$script" ]; then
        printf "  %b[FAIL]%b  %s not executable\n" "$RED" "$NC" "$script"
        LAYER_RESULTS+=("FAIL $name")
        OVERALL_RC=1
        return
    fi
    if "$script"; then
        local elapsed=$(( $(date +%s) - start ))
        LAYER_RESULTS+=("OK   $name (${elapsed}s)")
    else
        local rc=$?
        local elapsed=$(( $(date +%s) - start ))
        LAYER_RESULTS+=("FAIL $name (exit=$rc, ${elapsed}s)")
        OVERALL_RC=1
    fi
}

# --- Banner ---
echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Frigate NVR — test suite (feature/multi-camera integration branch)"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)"
echo "═══════════════════════════════════════════════════════════════════════"

# --- Layers ---
if [ "$BRINGUP_ONLY" -eq 0 ]; then
    run_layer "L1: YAML parse + structure"          tests/test-config.sh
    run_layer "L2: math derivation + spec match"    tests/test-math.sh
fi
if [ "$WITH_BRINGUP" -eq 1 ] || [ "$BRINGUP_ONLY" -eq 1 ]; then
    run_layer "L3: live bring-up (--all-cameras)"   tests/test-bringup.sh
fi

# --- Summary ---
echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  OVERALL"
echo "═══════════════════════════════════════════════════════════════════════"
for r in "${LAYER_RESULTS[@]}"; do
    case "$r" in
        OK*)   printf "  %b%s%b\n" "$GRN" "$r" "$NC" ;;
        FAIL*) printf "  %b%s%b\n" "$RED" "$r" "$NC" ;;
    esac
done
echo "───────────────────────────────────────────────────────────────────────"
if [ "$OVERALL_RC" -eq 0 ]; then
    printf "  %bALL REQUESTED LAYERS PASSED%b\n" "$GRN" "$NC"
else
    printf "  %bONE OR MORE LAYERS FAILED%b\n" "$RED" "$NC"
fi
echo "═══════════════════════════════════════════════════════════════════════"
exit "$OVERALL_RC"
