#!/usr/bin/env bash
# ==============================================================================
# tests/test-bringup.sh — L3 test: live bring-up via bring-up.sh
# ==============================================================================
# Catches: container starts; /api/cameras lists every camera in
# tests/camera_spec.py; detection runs on each (or timeout); the
# 14-step pipeline report is HEALTHY/DEGRADED for every camera.
#
# Layer philosophy (see tests/README.md for the full 3-layer model):
#   L1  ≈ 5 s    — fast, no Frigate running, no GPU
#   L2  ≈ 5 s    — math re-derivation, no Frigate running
#   L3  ≈ 1-4 m  — live bring-up via bring-up.sh --all-cameras --status
#
# This script delegates almost all of the work to bring-up.sh.  The
# --all-cameras flag (commit 1 of this branch) makes bring-up.sh
# loop status_report() over every camera in config.yml and return 1
# if ANY camera's report has a FAIL step.
#
# Exit codes:
#   0  bring-up.sh --all-cameras --status returns 0 (all cameras HEALTHY/DEGRADED)
#   1  one or more cameras FAILed in the 14-step report
#   2  pre-flight failed (host prerequisite missing)
#   3  bring-up.sh not on PATH
#   4  Frigate API never came up
#   5  detection never started (even after down/up recovery)
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; NC=''
fi

echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  L3 — LIVE BRING-UP (all cameras, status-only)"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)"
echo "═══════════════════════════════════════════════════════════════════════"

if [ ! -x ./bring-up.sh ]; then
    printf "  %b[FAIL]%b  ./bring-up.sh not found or not executable in %s\n" \
        "$RED" "$NC" "$(pwd)"
    exit 3
fi

# Always run --status (L3 is not a full bring-up, it just exercises
# the 14-step report on the running container).  --all-cameras
# makes bring-up.sh loop over every camera in config.yml.  The
# --no-mqtt flag is set so we don't pollute the production MQTT
# topics while running tests.
#
# Snapshot baselines: when a baseline file is present at
# tests/baselines/snapshot.json, pass it via --snapshot-compare so
# the test fails on any drift from the last known-good state.
EXTRA_FLAGS=(--status --all-cameras --no-mqtt)
if [ -f tests/baselines/snapshot.json ]; then
    EXTRA_FLAGS+=(--snapshot-compare=tests/baselines/snapshot.json)
    echo "  Using snapshot baseline: tests/baselines/snapshot.json"
    echo "  (regenerate with: ./bring-up.sh --all-cameras --snapshot-write=tests/baselines/snapshot.json)"
fi

# Run the bring-up.  Bring-up.sh prints its own 14-step report per
# camera to stderr (so the test stdout stays clean).  We just want
# the exit code.
echo
echo "─── bring-up.sh ${EXTRA_FLAGS[*]} ───"
./bring-up.sh "${EXTRA_FLAGS[@]}"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
    printf "  %bL3 SUMMARY: HEALTHY%b\n" "$GRN" "$NC"
    exit 0
else
    printf "  %bL3 SUMMARY: UNHEALTHY (bring-up.sh exit=%d)%b\n" "$RED" "$rc" "$NC"
    exit "$rc"
fi
