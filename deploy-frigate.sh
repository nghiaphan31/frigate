#!/usr/bin/env bash
# =============================================================================
# deploy-frigate.sh — Safe Frigate deployment script (Calypso / RTX 5060 Ti)
# =============================================================================
# Usage:
#   ./deploy-frigate.sh                  # auto-detect: restart or full recreate
#   ./deploy-frigate.sh restart          # config-only change (stop+start, NOT docker restart)
#   ./deploy-frigate.sh recreate         # force full container recreation
#   ./deploy-frigate.sh boot             # ZMQ-fix cycle after host reboot (used by frigate.service)
#   ./deploy-frigate.sh install-service  # install + enable frigate.service (requires sudo)
#   ./deploy-frigate.sh status           # show current health (inference speed, det_fps, shm)
#   ./deploy-frigate.sh dump             # run Option-B event dump (Track A soak output)
#
# Why this script exists — issues encountered 2026-05-22:
#   1. `docker-compose up --force-recreate` fails with KeyError: 'ContainerConfig'
#      on docker-compose v1.29.2 with newer OCI images. Use stop+rm+up instead.
#   2. `docker-compose restart` leaves ZMQ IPC sockets between capture and detect
#      processes in a broken state → det_fps=0 on ALL cameras (even config-only changes).
#      Fix: ALWAYS use stop+start, never `docker-compose restart`.
#   3. After container recreation (stop+rm+up), a second stop+start cycle is also
#      required to clear the ZMQ IPC deadlock introduced by the recreation itself.
#   4. shm_size changes require recreation (not just restart) to take effect.
#   5. The plain `stable` image ships CPU-only onnxruntime → 146ms inference.
#      Always use `stable-tensorrt` for GPU inference (11ms).
# =============================================================================

set -euo pipefail

COMPOSE_FILE="docker-compose.calypso.yml"
SERVICE="frigate"
FRIGATE_API="http://localhost:5000"
# Maximum number of extra ZMQ-fix stop+start retries after the initial cycle.
# 3 retries (4 total cycles) gives P(any camera still ZMQ-stuck) < 0.55% at 15% per-cycle
# failure probability. See plans/deploy-reliability-fix-plan.md § REL-9 for the math.
MAX_ZMQ_RETRIES=3

# Soak epoch — update this after each container recreation or soak reset
# Used by the `dump` command to filter events since last soak start
SOAK_EPOCH=1779919998  # soak restart after ZMQ-fix + reboot robustness: 2026-05-27 22:13 UTC

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ❌ $*" >&2; exit 1; }

dc() { docker-compose -f "$COMPOSE_FILE" "$@"; }

# ZMQ-fix stop+start cycle.
# Uses `docker stop -t 30` (30s graceful timeout) instead of `dc stop` (default 10s).
# With restart: unless-stopped, the container must be fully stopped before Docker
# auto-restarts it. 10s is not enough for Frigate to close all ZMQ IPC sockets;
# 30s gives the processes time to flush and exit cleanly.
#
# WHY 20s sleep (not 3s):
#   Under network_mode: host, Frigate's internal WebSocket server binds a TCP port
#   on the HOST network namespace. After docker stop (even with SIGKILL), the OS
#   needs ~10-15s to fully release that port — confirmed by OSError: [Errno 98]
#   Address already in use in frigate/comms/ws.py on restart with sleep=3.
#   20s gives a comfortable margin above the 10-15s observed window; the extra 5s
#   over 15s eliminates port-release races on loaded systems at negligible latency cost.
zmq_fix_cycle() {
    local container
    container=$(docker-compose -f "$COMPOSE_FILE" ps -q "$SERVICE" 2>/dev/null | head -1)
    if [[ -z "$container" ]]; then
        warn "zmq_fix_cycle: no running container found — using dc stop/start fallback"
        dc stop "$SERVICE"
        sleep 20
        dc start "$SERVICE"
        return
    fi
    log "ZMQ-fix: stopping container ${container} (timeout=30s)..."
    docker stop -t 30 "$container"
    sleep 20
    log "ZMQ-fix: starting ${SERVICE}..."
    dc start "$SERVICE"
}

wait_healthy() {
    local max_wait="${1:-120}"  # optional arg: wait_healthy 300 for crash-recovery scenarios
    local interval=5
    local elapsed=0
    log "Waiting for Frigate API to become available (timeout=${max_wait}s)..."
    while ! curl -sf "${FRIGATE_API}/api/version" >/dev/null 2>&1; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            fail "Frigate API did not respond within ${max_wait}s"
        fi
        log "  ...still waiting (${elapsed}s)"
    done
    ok "Frigate API is up"
}

# Wait until the detector has loaded its model and entered its ZMQ receive loop.
# Polls /api/stats until inference_speed > 0 for any detector.
#
# IMPORTANT CAVEAT: inference_speed in /api/stats is STALE CACHED DATA from the
# previous run. It becomes > 0 as soon as the API starts, even before the detector
# process has entered its ZMQ receive loop. Do NOT use inference_speed > 0 as a
# signal that ZMQ is healthy — use wait_all_processing() for that instead.
#
# This function is only useful for waiting out the TRT engine build (~65s first run)
# before doing the ZMQ-fix stop+start. After the stop+start, use wait_all_processing()
# to confirm the ZMQ IPC connection is actually working.
#
# WHY the ZMQ-fix stop+start is needed at all:
#   After `up -d`, the detect process blocks in ort.InferenceSession() for the
#   duration of the TRT engine build (~65s first run, ~5s from cache). During
#   this time it has NOT entered its ZMQ IPC receive loop. The capture processes
#   connect immediately (ZMQ connect is non-blocking) and start queuing frames.
#   If we stop+start before the detector enters its ZMQ loop, the capture processes
#   go through one failed connection cycle → inconsistent state → process_fps=0.
#   Doing the stop+start AFTER the TRT build (when inference_speed first appears)
#   gives the best chance of a clean ZMQ connection on the next start.
wait_detector_ready() {
    local max_wait="${1:-300}"  # default 300s — TRT build ~65s, 4× headroom
    local interval=5
    local elapsed=0
    log "Waiting for detector to become ready (inference_speed > 0, timeout=${max_wait}s)..."
    while true; do
        local speed
        speed=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
            | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    speeds = [v.get('inference_speed', 0) for v in s.get('detectors', {}).values()]
    print(max(speeds) if speeds else 0)
except Exception:
    print(0)
" 2>/dev/null) || speed=0
        # Use awk for float comparison (avoids bc dependency)
        if awk "BEGIN{exit !($speed > 0)}"; then
            ok "Detector model loaded: inference_speed=${speed}ms (stale cache — ZMQ not yet confirmed)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            warn "Detector did not become ready within ${max_wait}s — proceeding anyway"
            return 1
        fi
        log "  ...detector not ready yet (${elapsed}s elapsed, inference_speed=${speed}ms)"
    done
}

# Check whether any camera has detection_fps > 0.
# Returns 0 (success) if at least one camera is detecting, 1 otherwise.
any_det_fps() {
    curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    fps = [v.get('detection_fps', 0) for v in s.get('cameras', {}).values()]
    print(1 if any(f and f > 0 for f in fps) else 0)
except Exception:
    print(0)
" 2>/dev/null | grep -q '^1$'
}

# Check whether any detection-enabled camera is ZMQ-stuck.
#
# A camera is ZMQ-stuck when BOTH of the following are true:
#   camera_fps  > 0 — go2rtc is delivering RTSP frames (feed exists, not a network issue)
#   process_fps = 0 — Frigate is NOT processing those frames (ZMQ IPC is broken)
#
# WHY this replaces the old majority (>50%) check:
#   The majority check silently passes when 5 of 11 cameras are stuck — those cameras
#   show "no frames received" in the UI permanently. Even one stuck camera is a real
#   failure that should trigger a retry.
#   camera_fps > 0 is the discriminator: it confirms the camera feed exists and the
#   failure is ZMQ, not camera connectivity (camera_fps=0 → network/camera issue,
#   not ZMQ → excluded from the stuck-camera check).
#
# Returns 0 (success/all clear) if no camera is ZMQ-stuck.
# Returns 1 (failure/retry needed) if any camera is ZMQ-stuck.
all_processing() {
    curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    cams = s.get('cameras', {})
    if not cams:
        print(0)  # no cameras yet — API not fully up, signal retry
        sys.exit()
    # A camera is ZMQ-stuck if it receives RTSP frames but Frigate does not process them.
    # Cameras with camera_fps=0 are excluded: no feed = connectivity issue, not ZMQ.
    stuck = [
        c for c, v in cams.items()
        if (v.get('camera_fps') or 0) > 0        # go2rtc delivers RTSP frames
        and (v.get('process_fps') or 0) == 0     # Frigate does not process them
        and v.get('detection_enabled', True)     # detection is supposed to be on
    ]
    print(0 if stuck else 1)
except Exception:
    print(0)
" 2>/dev/null | grep -q '^1$'
}

# Wait until no camera is ZMQ-stuck (camera_fps > 0 AND process_fps = 0).
# See all_processing() above for the stuck-camera definition.
# Returns 0 on success, 1 on timeout (caller MUST use || true — set -e is active).
wait_all_processing() {
    local max_wait="${1:-120}"
    local interval=5
    local elapsed=0
    log "Waiting for all cameras to process frames (no ZMQ-stuck camera, timeout=${max_wait}s)..."
    while true; do
        if all_processing; then
            ok "All active cameras processing (ZMQ IPC healthy)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            warn "ZMQ-stuck cameras still detected after ${max_wait}s — ZMQ IPC may need another cycle"
            return 1  # caller MUST use || true — set -e is active
        fi
        log "  ...waiting: some cameras have camera_fps>0 but process_fps=0 (${elapsed}s elapsed)"
    done
}

check_det_fps() {
    log "Checking detection_fps on all cameras..."
    local stats
    stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null) || {
        warn "Could not reach stats API"
        return
    }
    local zero_cams
    zero_cams=$(echo "$stats" | python3 -c "
import sys, json
s = json.load(sys.stdin)
cameras = s.get('cameras', {})
# Frigate 0.17.x: detection_fps is a top-level field on each camera object
zero    = [c for c, v in cameras.items() if not (v.get('detection_fps') or 0) > 0]
nonzero = [c for c, v in cameras.items() if (v.get('detection_fps') or 0) > 0]
print(f'detection_fps>0: {len(nonzero)}/{len(cameras)} cameras')
if zero:
    print(f'detection_fps=0: {zero}')
" 2>/dev/null)
    echo "$zero_cams"
}

check_inference() {
    local speed
    speed=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
        | python3 -c "
import sys, json
s = json.load(sys.stdin)
det = s.get('detectors', {})
for name, v in det.items():
    spd = v.get('inference_speed', 0)
    print(f'  {name}: inference_speed={spd:.1f}ms')
" 2>/dev/null) || speed="  (could not read)"
    echo "$speed"
}

check_shm() {
    local cid shm_info
    # Look up the container ID dynamically — works on Docker Compose V1 (underscores)
    # and V2 (hyphens) regardless of container naming convention.
    cid=$(docker-compose -f "$COMPOSE_FILE" ps -q "$SERVICE" 2>/dev/null | head -1)
    # Read from inside the container — the host /dev/shm is a different tmpfs
    shm_info=$(docker exec "$cid" df -h /dev/shm 2>/dev/null \
        | tail -1 | awk '{print "size="$2" used="$3" avail="$4" use%="$5}') \
        || shm_info="(could not read — container may not be running)"
    echo "  /dev/shm: $shm_info"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_status() {
    log "=== Frigate health check ==="
    log "Inference speed:"
    check_inference
    log "Detection fps:"
    check_det_fps
    log "Shared memory:"
    check_shm
}

cmd_boot() {
    # Called by frigate.service on host boot.
    # Docker's `restart: unless-stopped` auto-starts the container, but does NOT
    # run the ZMQ-fix stop+start cycle. This function does that cycle and confirms
    # ZMQ health (process_fps > 0) before returning.
    log "=== Boot ZMQ-fix sequence (called by frigate.service) ==="

    # The container was already started by Docker's restart policy.
    # Wait for the API to come up and the TRT engine to finish building.
    wait_healthy
    # BUG-3 FIX: || true added — if TRT build exceeds 300s (first-ever boot, cold cache),
    # the function returns 1 which would exit the script under set -e without || true.
    # The zmq_fix_cycle below is what actually matters; wait_detector_ready here is only
    # a best-effort signal that TRT is loaded before we stop+start.
    wait_detector_ready 300 || true  # up to 5 min for TRT build on first run after reboot

    # ZMQ-fix stop+start cycle
    log "Performing ZMQ-fix stop+start cycle..."
    zmq_fix_cycle

    wait_healthy
    wait_detector_ready 120 || true  # engine cached — should be <10s
    wait_all_processing 120 || true  # confirm ZMQ IPC healthy (process_fps > 0)

    log "Post-boot health:"
    check_inference
    check_det_fps

    # REL-6/REL-8/REL-9: ZMQ retry loop — up to MAX_ZMQ_RETRIES extra cycles.
    # Triggers if ANY camera has camera_fps>0 AND process_fps=0 (ZMQ-stuck).
    # This is stricter than the old majority check: even one stuck camera retries.
    local zmq_retry=0
    while ! all_processing && [[ $zmq_retry -lt $MAX_ZMQ_RETRIES ]]; do
        zmq_retry=$((zmq_retry + 1))
        warn "ZMQ-stuck cameras detected (retry ${zmq_retry}/${MAX_ZMQ_RETRIES}) — retrying ZMQ reset..."
        check_det_fps
        zmq_fix_cycle
        wait_healthy
        wait_detector_ready 120 || true
        wait_all_processing 120 || true
        log "Post-retry ${zmq_retry} health:"
        check_inference
        check_det_fps
    done
    if ! all_processing; then
        warn "ZMQ IPC still unhealthy after ${MAX_ZMQ_RETRIES} retries — manual check needed"
        warn "Run: ./deploy-frigate.sh status  to see per-camera fps"
    fi

    check_shm
    ok "Boot sequence complete"
}

cmd_install_service() {
    # Install and enable frigate.service as a systemd unit.
    # Must be run with sudo (or as root).
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local SERVICE_SRC="${SCRIPT_DIR}/frigate.service"
    local SERVICE_DST="/etc/systemd/system/frigate.service"

    if [[ ! -f "$SERVICE_SRC" ]]; then
        err "frigate.service not found at ${SERVICE_SRC}"
        exit 1
    fi

    log "Installing ${SERVICE_SRC} → ${SERVICE_DST}..."
    cp "$SERVICE_SRC" "$SERVICE_DST"
    chmod 644 "$SERVICE_DST"

    log "Reloading systemd daemon..."
    systemctl daemon-reload

    log "Enabling frigate.service (auto-start on boot)..."
    systemctl enable frigate.service

    ok "frigate.service installed and enabled."
    echo ""
    echo "  To start now:   systemctl start frigate"
    echo "  To check status: systemctl status frigate"
    echo "  To view logs:   journalctl -u frigate -f"
    echo ""
    warn "NOTE: The service runs deploy-frigate.sh boot, which performs the ZMQ-fix"
    warn "      stop+start cycle. Docker's restart: unless-stopped handles the initial"
    warn "      container start; this service handles the ZMQ health check."
}

cmd_restart() {
    log "=== Config-only restart (stop+start — never docker-compose restart) ==="
    # IMPORTANT: `docker-compose restart` leaves ZMQ IPC sockets broken → process_fps=0.
    # Always use stop+start instead, even for config-only changes.
    zmq_fix_cycle
    wait_healthy
    # Wait for detector model to load (TRT cache: ~5s; first build: ~65s)
    wait_detector_ready 120 || true
    # Wait for ZMQ IPC to be healthy: no ZMQ-stuck camera (camera_fps>0 AND process_fps=0)
    wait_all_processing 120 || true
    log "Post-restart health:"
    check_inference
    check_det_fps

    # REL-6/REL-8/REL-9: ZMQ retry loop — up to MAX_ZMQ_RETRIES extra cycles.
    # Triggers if ANY camera has camera_fps>0 AND process_fps=0 (ZMQ-stuck).
    # This is stricter than the old majority check: even one stuck camera retries.
    local zmq_retry=0
    while ! all_processing && [[ $zmq_retry -lt $MAX_ZMQ_RETRIES ]]; do
        zmq_retry=$((zmq_retry + 1))
        warn "ZMQ-stuck cameras detected (retry ${zmq_retry}/${MAX_ZMQ_RETRIES}) — retrying stop+start..."
        check_det_fps
        zmq_fix_cycle
        wait_healthy
        wait_detector_ready 120 || true
        wait_all_processing 120 || true
        log "Post-retry ${zmq_retry} health:"
        check_inference
        check_det_fps
    done
    if ! all_processing; then
        warn "ZMQ IPC still unhealthy after ${MAX_ZMQ_RETRIES} retries — manual check needed"
        warn "Run: ./deploy-frigate.sh status  to see per-camera fps"
    fi

    check_shm
    ok "Restart complete"
}

cmd_recreate() {
    log "=== Full container recreation ==="
    warn "This will stop Frigate and recreate the container."
    warn "shm_size, image, devices and volume changes will take effect."
    echo ""

    # Step 1: stop + remove + recreate
    log "Step 1/2 — stop + rm + up (container recreation)..."
    dc stop "$SERVICE"

    # IMPORTANT: Delete frigate.db BEFORE removing the container.
    # Frigate stores parsed config in frigate.db (on the overlay filesystem).
    # The DB persists across container lifecycle operations unless explicitly
    # deleted. Without this, config changes are ignored because Frigate loads
    # the stale DB instead of re-parsing config.yml.
    #
    # CRITICAL: Do NOT use `docker cp /dev/null` — that truncates to 0 bytes
    # and corrupts the SQLite DB, causing Frigate to crash with exit code 1.
    # Instead, use a helper container with --volumes-from to properly rm the
    # DB files while the Frigate container is stopped.
    log "Clearing Frigate database (forces re-parse from config.yml)..."
    CONTAINER_ID=$(dc ps -q "$SERVICE" 2>/dev/null | head -1)
    if [[ -n "$CONTAINER_ID" ]]; then
        # --volumes-from works on a STOPPED container — mounts the Frigate
        # container's volumes into a lightweight alpine container and deletes
        # the DB files from inside that context.
        docker run --rm \
            --volumes-from "$CONTAINER_ID" \
            docker.io/library/alpine:latest \
            sh -c 'rm -f /config/frigate.db /config/frigate.db-shm /config/frigate.db-wal' \
            2>/dev/null || warn "DB cleanup failed (continuing anyway)"
    fi

    dc rm -f "$SERVICE"
    dc up -d "$SERVICE"

    # Step 2: wait for TRT engine build, then do the ZMQ-fix stop+start, then
    #         confirm ZMQ is healthy via process_fps > 0 on all cameras.
    #
    # WHY the order matters:
    #   After `up -d`, the detect process blocks in ort.InferenceSession() for
    #   the TRT engine build (~65s first run, ~5s from cache). During this time
    #   it has NOT entered its ZMQ IPC receive loop. If we stop+start too early,
    #   the capture processes go through one failed connection cycle → process_fps=0.
    #   Waiting for inference_speed > 0 (TRT build done) before the stop+start
    #   gives the best chance of a clean ZMQ connection on the next start.
    #   After the stop+start, wait_all_processing() confirms ZMQ is actually healthy
    #   (process_fps > 0 is the real signal — inference_speed is stale cached data).
    log "Step 2/2 — wait for TRT build, stop+start (ZMQ reset), confirm ZMQ healthy..."
    wait_healthy
    # wait_detector_ready uses inference_speed > 0 as the TRT-build-done signal.
    # On a fresh container (after dc rm -f + dc up -d), /dev/shm is zeroed, so
    # inference_speed truly starts at 0 and rises to >0 only after the first real
    # detection (~5s from cache, ~65s first build). The 300s timeout covers the
    # worst-case first-build.
    wait_detector_ready 300  # up to 300s for TRT engine build on first run
    zmq_fix_cycle

    # After the zmq_fix_cycle restart, inference_speed is stale in the (reused)
    # /dev/shm — wait_detector_ready returns immediately here. That's fine: the
    # real health signal is wait_all_processing (process_fps > 0).
    # Use wait_healthy 300 instead of 120: if the zmq_fix_cycle caused an
    # OSError: Address already in use crash in ws.py, s6 takes ~125s to restart
    # Frigate, which exceeds the old 120s timeout and caused fail() → script exit.
    wait_healthy 300
    # BUG-2 FIX: || true added — wait_detector_ready returns 1 on timeout; under
    # set -e this would exit the script. Stale /dev/shm means it typically returns
    # immediately with 0, but || true makes it safe when /dev/shm is cleared.
    wait_detector_ready 120 || true  # stale data — returns immediately; kept for symmetry
    wait_all_processing 120 || true  # confirm ZMQ IPC is healthy (process_fps > 0)

    log "Post-recreation health:"
    check_inference
    check_det_fps

    # REL-6/REL-8/REL-9: ZMQ retry loop — up to MAX_ZMQ_RETRIES extra cycles.
    # Triggers if ANY camera has camera_fps>0 AND process_fps=0 (ZMQ-stuck).
    # This is stricter than the old majority check: even one stuck camera retries.
    local zmq_retry=0
    while ! all_processing && [[ $zmq_retry -lt $MAX_ZMQ_RETRIES ]]; do
        zmq_retry=$((zmq_retry + 1))
        warn "ZMQ-stuck cameras detected (retry ${zmq_retry}/${MAX_ZMQ_RETRIES}) — retrying ZMQ reset..."
        check_det_fps
        zmq_fix_cycle
        wait_healthy
        wait_detector_ready 120 || true
        wait_all_processing 120 || true
        log "Post-retry ${zmq_retry} health:"
        check_inference
        check_det_fps
    done
    if ! all_processing; then
        warn "ZMQ IPC still unhealthy after ${MAX_ZMQ_RETRIES} retries — manual check needed"
        warn "Run: ./deploy-frigate.sh status  to see per-camera fps"
    fi

    check_shm

    ok "Recreation complete"
    echo ""
    warn "Remember to update SOAK_EPOCH in this script if this is a soak restart:"
    echo "  SOAK_EPOCH=\$(date +%s)  # current epoch: $(date +%s)"
}

cmd_dump() {
    log "=== Option-B event dump (Track A soak output) ==="
    log "Fetching person events since epoch ${SOAK_EPOCH} ($(date -d "@${SOAK_EPOCH}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date -r "${SOAK_EPOCH}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo 'unknown'))..."
    echo ""
    curl -s "${FRIGATE_API}/api/events?limit=10000&after=${SOAK_EPOCH}&label=person" \
        | python3 -c "
import json, sys, datetime

events = json.load(sys.stdin)
print(f'Total person events since soak start: {len(events)}')
print()

# Stream pixel counts per camera (width x height).
# data.box is [x1, y1, x2, y2] in NORMALISED coordinates (0-1).
# Multiply normalised area by stream pixels to get pixel area.
# These match the detect: stream resolutions in config.yml.
STREAM_PIXELS = {
    'allee_sur_le_cote':        1536 * 432,   # sub panoramic 3.56:1
    'allee_sur_le_cote_left':   2048 * 1152,  # main left crop
    'allee_sur_le_cote_right':  2048 * 1152,  # main right crop
    'jardin_arriere':           3840 * 2160,  # main 4K
    'jardin_devant':            1536 * 432,   # sub panoramic 3.56:1
    'jardin_devant_left':       2048 * 1152,  # main left crop
    'jardin_devant_right':      2048 * 1152,  # main right crop
    'piscine_vue_toit':         1536 * 432,   # sub panoramic 3.56:1
    'piscine_vue_toit_left':    2048 * 1152,  # main left crop
    'piscine_vue_toit_right':   2048 * 1152,  # main right crop
    'vue_entree':               2560 * 1920,  # main doorbell 4:3
}

# Group by camera
from collections import defaultdict
by_cam = defaultdict(list)
for e in events:
    by_cam[e['camera']].append(e)

for cam in sorted(by_cam.keys()):
    evs = by_cam[cam]
    scores = [e.get('data', {}).get('top_score', e.get('score', 0)) for e in evs]
    px = STREAM_PIXELS.get(cam, 1920 * 1080)  # fallback to 1080p

    # Bounding box: Frigate API stores the box as [x1, y1, x2, y2] in
    # e['data']['box'] in NORMALISED coordinates (0-1).
    # The top-level e['area'] and e['ratio'] fields are always 0 in Frigate 0.17.x
    # (only populated on the /api/events/<id> detail endpoint).
    # Multiply normalised area by stream pixel count to get pixel area.
    areas  = []
    ratios = []
    for e in evs:
        box = e.get('data', {}).get('box') or e.get('box')
        if box and len(box) == 4:
            x1, y1, x2, y2 = box
            w = abs(x2 - x1)
            h = abs(y2 - y1)
            areas.append(w * h * px)
            ratios.append(w / h if h > 0 else 0)
        else:
            areas.append(0)
            ratios.append(0)

    print(f'=== {cam} ({len(evs)} events) [stream {px} px] ===')
    if scores: print(f'  score : min={min(scores):.3f}  max={max(scores):.3f}  median={sorted(scores)[len(scores)//2]:.3f}')
    nz_areas  = [a for a in areas  if a > 0]
    nz_ratios = [r for r in ratios if r > 0]
    if nz_areas:  print(f'  area  : min={min(nz_areas):.0f}  max={max(nz_areas):.0f}  median={sorted(nz_areas)[len(nz_areas)//2]:.0f}  (px²)')
    else:         print(f'  area  : min=0  max=0  (box field absent)')
    if nz_ratios: print(f'  ratio : min={min(nz_ratios):.3f}  max={max(nz_ratios):.3f}  median={sorted(nz_ratios)[len(nz_ratios)//2]:.3f}')
    else:         print(f'  ratio : min=0.000  max=0.000')
    print()
    for e in evs:
        d = e.get('data', {})
        t = datetime.datetime.fromtimestamp(e['start_time']).strftime('%Y-%m-%d %H:%M:%S')
        score = d.get('top_score', e.get('score', 0))
        box = d.get('box') or e.get('box')
        if box and len(box) == 4:
            x1, y1, x2, y2 = box
            w = abs(x2 - x1); h = abs(y2 - y1)
            area  = w * h * px
            ratio = w / h if h > 0 else 0
        else:
            area = 0; ratio = 0
        zones = e.get('zones', [])
        print(f'  {t}  score={score:.3f}  area={area:8.0f}  ratio={ratio:.3f}  zones={zones}')
    print()
"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

MODE="${1:-auto}"

case "$MODE" in
    restart)
        cmd_restart
        ;;
    recreate)
        cmd_recreate
        ;;
    boot)
        cmd_boot
        ;;
    install-service)
        cmd_install_service
        ;;
    status)
        cmd_status
        ;;
    dump)
        cmd_dump
        ;;
    auto)
        # Detect whether the running container matches the compose definition.
        # If the image or config.yml has changed, a recreation is needed.
        #
        # CRITICAL (BUG FIX #5): config.yml changes require DB cleanup (cmd_recreate),
        # NOT cmd_restart. Frigate stores parsed config in frigate.db (named volume,
        # persists across all container operations). /api/config serves the DB version.
        # Even `docker-compose down && up -d` (full rm+create) keeps the old config
        # unless the DB is explicitly cleared. The auto mode must detect config
        # changes and call cmd_recreate (which now clears the DB) instead of
        # cmd_restart.
        log "=== Auto-detect deploy mode ==="
        CONTAINER_ID=$(dc ps -q "$SERVICE" 2>/dev/null | head -1)
        RUNNING_IMAGE=$(echo "$CONTAINER_ID" \
            | xargs -r docker inspect --format '{{.Config.Image}}' 2>/dev/null || echo "")
        COMPOSE_IMAGE=$(grep '^\s*image:' "$COMPOSE_FILE" | head -1 | awk '{print $2}')

        # Check if config.yml has been modified since container was created.
        # If config.yml mtime is newer than the container creation time, the config
        # was modified after the container started and requires full recreation.
        # (Frigate stores parsed config in frigate.db which persists across recreates)
        CONTAINER_CREATED=$(docker inspect --format '{{.Created}}' "$(dc ps -q "$SERVICE" | head -1)" 2>/dev/null | xargs -I{} date -d {} +%s 2>/dev/null || echo 0)
        CONFIG_MTIME=$(stat -c %Y config.yml 2>/dev/null || echo 0)
        CONFIG_CHANGED=false
        if [[ "$CONFIG_MTIME" -gt "$CONTAINER_CREATED" ]] && [[ "$CONTAINER_CREATED" != "0" ]]; then
            CONFIG_CHANGED=true
        fi

        if [[ -z "$CONTAINER_ID" ]] || [[ -z "$RUNNING_IMAGE" ]]; then
            log "No running container found — performing full recreation"
            cmd_recreate
        elif [[ "$RUNNING_IMAGE" != "$COMPOSE_IMAGE" ]]; then
            log "Image changed: running='${RUNNING_IMAGE}' compose='${COMPOSE_IMAGE}'"
            log "Full recreation required"
            cmd_recreate
        elif [[ "$CONFIG_CHANGED" == "true" ]]; then
            # BUG-1 FIX: the original line referenced ${DB_MTIME} which was never defined,
            # causing bash to exit here with "DB_MTIME: unbound variable" under set -euo pipefail.
            # This meant cmd_recreate was never called — the container kept running with
            # the stale Frigate DB that ignored the new config.yml.
            log "config.yml modified after container start (config_mtime=${CONFIG_MTIME} > container_created=${CONTAINER_CREATED})"
            log "Full recreation required (DB will be cleared)"
            cmd_recreate
        else
            log "Image and config unchanged — config-only restart"
            cmd_restart
        fi
        ;;
    *)
        echo "Usage: $0 [restart|recreate|boot|install-service|status|dump|auto]"
        echo ""
        echo "  auto             (default) detect whether recreation is needed"
        echo "  restart          config.yml change only — no container recreation"
        echo "  recreate         image/shm_size/devices changed — full stop+rm+up+stop+start"
        echo "  boot             ZMQ-fix cycle after host reboot (used by frigate.service)"
        echo "  install-service  install + enable frigate.service (requires sudo)"
        echo "  status           show inference speed, det_fps, /dev/shm usage"
        echo "  dump             Option-B event dump for Track A soak analysis"
        exit 1
        ;;
esac
