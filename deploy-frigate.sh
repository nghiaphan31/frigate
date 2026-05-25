#!/usr/bin/env bash
# =============================================================================
# deploy-frigate.sh — Safe Frigate deployment script (Calypso / RTX 5060 Ti)
# =============================================================================
# Usage:
#   ./deploy-frigate.sh            # auto-detect: restart or full recreate
#   ./deploy-frigate.sh restart    # config-only change (stop+start, NOT docker restart)
#   ./deploy-frigate.sh recreate   # force full container recreation
#   ./deploy-frigate.sh status     # show current health (inference speed, det_fps, shm)
#   ./deploy-frigate.sh dump       # run Option-B event dump (Track A soak output)
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

# Soak epoch — update this after each container recreation or soak reset
# Used by the `dump` command to filter events since last soak start
SOAK_EPOCH=1779474180  # 2026-05-25 17:43 UTC = 2026-05-25 19:43 CEST (soak 2 start)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✅ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠️  $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ❌ $*" >&2; exit 1; }

dc() { docker-compose -f "$COMPOSE_FILE" "$@"; }

wait_healthy() {
    local max_wait=120
    local interval=5
    local elapsed=0
    log "Waiting for Frigate API to become available..."
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

check_det_fps() {
    log "Checking det_fps on all cameras..."
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
zero = [c for c, v in cameras.items() if v.get('detection', {}).get('det_fps', 0) == 0]
nonzero = [c for c, v in cameras.items() if v.get('detection', {}).get('det_fps', 0) > 0]
print(f'det_fps>0: {len(nonzero)}/{len(cameras)} cameras')
if zero:
    print(f'det_fps=0: {zero}')
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
    local shm_info
    # Read from inside the container — the host /dev/shm is a different tmpfs
    shm_info=$(docker exec "frigate_${SERVICE}_1" df -h /dev/shm 2>/dev/null \
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

cmd_restart() {
    log "=== Config-only restart (stop+start — never docker-compose restart) ==="
    # IMPORTANT: `docker-compose restart` leaves ZMQ IPC sockets broken → det_fps=0.
    # Always use stop+start instead, even for config-only changes.
    log "Stopping ${SERVICE}..."
    dc stop "$SERVICE"
    log "Starting ${SERVICE}..."
    dc start "$SERVICE"
    wait_healthy
    sleep 15  # allow detectors to initialise and first frames to arrive
    log "Post-restart health:"
    check_inference
    check_det_fps
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
    dc rm -f "$SERVICE"
    dc up -d "$SERVICE"

    # Brief pause to let the container start its init sequence
    sleep 5

    # Step 2: stop + start to fix ZMQ IPC deadlock
    # After `up -d` following `rm -f`, ZMQ IPC sockets between the capture
    # and detect processes are in a broken state → det_fps=0 on all cameras.
    # A stop/start cycle resets the IPC correctly.
    log "Step 2/2 — stop + start (fix ZMQ IPC deadlock)..."
    dc stop "$SERVICE"
    dc start "$SERVICE"

    wait_healthy
    sleep 15  # allow detectors to initialise and first frames to arrive

    log "Post-recreation health:"
    check_inference
    check_det_fps
    check_shm

    ok "Recreation complete"
    warn "If det_fps=0 persists after 60s, run: docker-compose -f ${COMPOSE_FILE} stop ${SERVICE} && docker-compose -f ${COMPOSE_FILE} start ${SERVICE}"
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
    status)
        cmd_status
        ;;
    dump)
        cmd_dump
        ;;
    auto)
        # Detect whether the running container matches the compose definition.
        # If the image or shm_size has changed, a recreation is needed.
        log "=== Auto-detect deploy mode ==="
        RUNNING_IMAGE=$(docker inspect frigate --format '{{.Config.Image}}' 2>/dev/null || echo "")
        COMPOSE_IMAGE=$(grep '^\s*image:' "$COMPOSE_FILE" | head -1 | awk '{print $2}')
        if [[ -z "$RUNNING_IMAGE" ]]; then
            log "No running container found — performing full recreation"
            cmd_recreate
        elif [[ "$RUNNING_IMAGE" != "$COMPOSE_IMAGE" ]]; then
            log "Image changed: running='${RUNNING_IMAGE}' compose='${COMPOSE_IMAGE}'"
            log "Full recreation required"
            cmd_recreate
        else
            log "Image unchanged — config-only restart"
            cmd_restart
        fi
        ;;
    *)
        echo "Usage: $0 [restart|recreate|status|dump|auto]"
        echo ""
        echo "  auto      (default) detect whether recreation is needed"
        echo "  restart   config.yml change only — no container recreation"
        echo "  recreate  image/shm_size/devices changed — full stop+rm+up+stop+start"
        echo "  status    show inference speed, det_fps, /dev/shm usage"
        echo "  dump      Option-B event dump for Track A soak analysis"
        exit 1
        ;;
esac
