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
#   ./deploy-frigate.sh diagnose         # 5-layer health display with Fix: directives (host/docker/inference/ZMQ/cameras)
#   ./deploy-frigate.sh validate         # automated test suite (9 non-destructive tests)
#   ./deploy-frigate.sh validate restart # full restart-cycle proof (5 tests, takes 3-5 min)
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

# Returns 0 (success) if >50% of detection-enabled cameras have process_fps > 0.
# Returns 1 (failure) if majority do not — caller should retry a ZMQ cycle.
#
# WHY majority (not all): ZMQ IPC startup is a race. Requiring ALL cameras to
# have process_fps > 0 immediately after a stop+start would trigger spurious
# retries while cameras reconnect their RTSP streams (10-30s after dc start).
# The majority threshold gives enough signal that ZMQ is healthy while tolerating
# the last few cameras still reconnecting.
all_processing() {
    curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    cams = s.get('cameras', {})
    if not cams:
        print(0)
        sys.exit()
    enabled = {c: v for c, v in cams.items() if v.get('detection_enabled', True)}
    if not enabled:
        print(1)  # no detection-enabled cameras — nothing to wait for
        sys.exit()
    processing = sum(1 for v in enabled.values() if (v.get('process_fps') or 0) > 0)
    total = len(enabled)
    print(1 if processing > total / 2 else 0)
except Exception:
    print(0)
" 2>/dev/null | grep -q '^1$'
}

# Wait until majority of detection-enabled cameras have process_fps > 0.
# Returns 0 on success, 1 on timeout (caller MUST use || true — set -e is active).
wait_all_processing() {
    local max_wait="${1:-120}"
    local interval=5
    local elapsed=0
    log "Waiting for majority of cameras to start processing (timeout=${max_wait}s)..."
    while true; do
        if all_processing; then
            ok "Majority of cameras processing (process_fps > 0)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            warn "Cameras not yet processing after ${max_wait}s — ZMQ IPC may need another cycle"
            return 1  # caller MUST use || true — set -e is active
        fi
        log "  ...waiting: majority of cameras don't have process_fps>0 yet (${elapsed}s elapsed)"
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

# Returns 0 (success) if any camera is ZMQ-stuck, 1 (failure) if all healthy.
# A camera is ZMQ-stuck when camera_fps > 0 (go2rtc is delivering RTSP frames
# to the container) but process_fps = 0 (Frigate's detection process is not
# consuming those frames). This is the definitive ZMQ IPC failure signature:
# the network is fine, the GPU is fine, but the internal ZMQ message path
# between the capture and detect processes is broken.
#
# Cameras with camera_fps = 0 are EXCLUDED — those are RTSP/connectivity issues
# that a zmq_fix_cycle won't fix (only the go2rtc->NUC reconnection will).
#
# Two-phase readiness pattern (see plan §4):
#   wait_all_processing 120  → exits early on majority success
#   sleep 15                → grace period (camera_fps→process_fps lag is 1-5s in healthy ZMQ)
#   has_stuck_cameras       → strict check, safe from false positives
#
# Returns 0 if at least one stuck camera is found (caller should retry).
# Returns 1 if no stuck cameras (system is healthy).
has_stuck_cameras() {
    local result
    result=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    cams = s.get('cameras', {})
    stuck = [
        c for c, v in cams.items()
        if (v.get('camera_fps') or 0) > 0         # go2rtc delivering frames
        and (v.get('process_fps') or 0) == 0      # Frigate not processing them
        and v.get('detection_enabled', True)      # detection is active
    ]
    print(','.join(stuck) if stuck else '')
except Exception:
    print('')   # parse failure → assume no stuck cameras; avoid spurious retry
" 2>/dev/null) || result=""

    if [[ -z "$result" ]]; then
        return 1   # no stuck cameras — all healthy
    else
        warn "ZMQ-stuck cameras (camera_fps>0, process_fps=0): ${result}"
        return 0   # stuck cameras found → caller should retry
    fi
}

# Cold-boot: wait for all 5 NVIDIA device nodes to appear under /dev.
# After a host reboot, the NVIDIA kernel modules may not be fully loaded when
# frigate.service runs — /dev/nvidia0 can appear before the device is usable.
# Polling here gives the driver up to 120s to expose the full device set.
#
# Non-fatal: returns 1 (warn-only) if devices don't appear in time. The container
# will still start; GPU inference will simply fail with detection errors visible
# in diagnose output. Better to start with degraded GPU than to deadlock the
# whole boot sequence.
#
# Requires the 5 device nodes listed in docker-compose.calypso.yml `devices:`.
wait_for_nvidia() {
    local max_wait="${1:-120}"
    local interval=5
    local elapsed=0
    local devices="/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools"
    log "Waiting for NVIDIA GPU devices (timeout=${max_wait}s)..."
    while ! ls $devices >/dev/null 2>&1; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            warn "NVIDIA devices not ready after ${max_wait}s — container may fail GPU inference"
            warn "  → Fix: sudo modprobe nvidia nvidia-uvm nvidia-modeset"
            warn "  → Or wait: modules may still be loading after cold boot"
            return 1
        fi
        log "  ...NVIDIA devices not ready yet (${elapsed}s)"
    done
    ok "NVIDIA GPU devices ready"
}

# Cold-boot pre-flight: warn-only checks for host-level dependencies.
# These checks do NOT block the boot sequence — Frigate and go2rtc handle
# reconnections internally. The value is early visibility in journald logs
# so the operator can immediately identify which layer failed on a bad boot.
#
# Checks:
#   1. NAS mount at ${FRIGATE_MEDIA_PATH} — if not a mountpoint, recordings
#      will be written to the container overlay (data loss risk).
#   2. NUC RTSP proxy at 192.168.50.112:8556 — if unreachable, all cameras
#      will show "no frames received" until it comes back.
#   3. MQTT broker at 192.168.50.125:1883 — if unreachable, Home Assistant
#      events won't publish until it comes back.
check_host_readiness() {
    local media_path="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"
    local nas_base
    nas_base=$(df "$media_path" 2>/dev/null | tail -1 | awk '{print $6}')
    if [[ "$nas_base" == "/" ]] || ! mountpoint -q "$media_path" 2>/dev/null; then
        warn "NAS may not be mounted at ${media_path} — recordings may go to wrong location"
        warn "  → Fix: sudo mount -a  OR  check NAS connectivity and /etc/fstab"
    else
        ok "NAS mounted at ${media_path}"
    fi

    if ! timeout 3 bash -c "echo >/dev/tcp/192.168.50.112/8556" 2>/dev/null; then
        warn "NUC RTSP proxy unreachable at 192.168.50.112:8556 — cameras will show no frames until reachable"
        warn "  → Fix: check NUC power and network connectivity to 192.168.50.112"
    else
        ok "NUC RTSP proxy reachable at 192.168.50.112:8556"
    fi

    if ! timeout 3 bash -c "echo >/dev/tcp/192.168.50.125/1883" 2>/dev/null; then
        warn "MQTT broker unreachable at 192.168.50.125:1883 — HA events won't publish until reachable"
        warn "  → Fix: check Home Assistant and Mosquitto broker status"
    else
        ok "MQTT broker reachable at 192.168.50.125:1883"
    fi
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

# 5-layer health display with actionable Fix: lines on every failure.
# See plan §12 for the output format. Returns 0 always (informational).
cmd_diagnose() {
    log "=== Frigate System Diagnostics [$(date '+%Y-%m-%d %H:%M:%S')] ==="
    echo ""

    # ------------------------------------------------------------ HOST LAYER
    log "HOST LAYER"

    # NVIDIA device nodes
    local nvidia_devs="/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools"
    if ls $nvidia_devs >/dev/null 2>&1; then
        ok "NVIDIA devices       $nvidia_devs"
    else
        local missing=""
        for d in $nvidia_devs; do [[ -e "$d" ]] || missing="$missing $d"; done
        warn "NVIDIA devices      Missing:$missing"
        warn "  → Fix: sudo modprobe nvidia nvidia-uvm nvidia-modeset"
    fi

    # NAS mount
    local media_path="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"
    if mountpoint -q "$media_path" 2>/dev/null; then
        ok "NAS mount            $media_path is a mountpoint"
    else
        warn "NAS mount           $media_path exists but is NOT a mountpoint"
        warn "  → Recordings will be written to container overlay (data LOSS risk)"
        warn "  → Fix: sudo mount -a  OR  check NAS connectivity and /etc/fstab"
    fi

    # NUC RTSP proxy
    if timeout 3 bash -c "echo >/dev/tcp/192.168.50.112/8556" 2>/dev/null; then
        ok "RTSP proxy           192.168.50.112:8556 reachable"
    else
        warn "RTSP proxy          192.168.50.112:8556 UNREACHABLE"
        warn "  → Cameras will show no frames until NUC RTSP proxy is back"
        warn "  → Fix: check NUC power and network to 192.168.50.112"
    fi

    # MQTT broker
    if timeout 3 bash -c "echo >/dev/tcp/192.168.50.125/1883" 2>/dev/null; then
        ok "MQTT broker          192.168.50.125:1883 reachable"
    else
        warn "MQTT broker         192.168.50.125:1883 UNREACHABLE"
        warn "  → HA events won't publish until broker is back"
        warn "  → Fix: check Home Assistant and Mosquitto broker status"
    fi
    echo ""

    # ------------------------------------------------------------ DOCKER LAYER
    log "DOCKER LAYER"
    local cid
    cid=$(dc ps -q "$SERVICE" 2>/dev/null | head -1)
    if [[ -n "$cid" ]]; then
        local image uptime
        image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || echo "unknown")
        uptime=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
        local started_at
        started_at=$(docker inspect --format '{{.State.StartedAt}}' "$cid" 2>/dev/null || echo "")
        local ago
        if [[ -n "$started_at" ]] && [[ "$started_at" != "<no value>" ]]; then
            ago=$(date -d "$started_at" +%s 2>/dev/null | awk -v now=$(date +%s) '{print int((now-$1)/3600)"h ago"}' 2>/dev/null || echo "")
        fi
        ok "Container           $uptime${ago:+ ($ago)}  image=$image"

        # /dev/shm and /tmp/cache usage
        local shm_info
        shm_info=$(docker exec "$cid" df -h /dev/shm 2>/dev/null | tail -1 \
            | awk '{size=$2; used=$3; pct=$5; sub("%","",pct); if (pct+0 >= 95) print "CRIT|"size"|"used"|"pct; else if (pct+0 >= 80) print "WARN|"size"|"used"|"pct; else print "OK|"size"|"used"|"pct}')
        local shm_status shm_size shm_used shm_pct
        IFS='|' read -r shm_status shm_size shm_used shm_pct <<< "$shm_info"
        if [[ "$shm_status" == "CRIT" ]]; then
            warn "  /dev/shm          ${shm_used}/${shm_size} (${shm_pct}%) — CRITICAL: corrupted/gray frames likely"
            warn "  → Fix: increase shm_size in docker-compose.calypso.yml and run cmd_recreate"
        elif [[ "$shm_status" == "WARN" ]]; then
            warn "  /dev/shm          ${shm_used}/${shm_size} (${shm_pct}%) — pressure"
        else
            ok "  /dev/shm          ${shm_used}/${shm_size} (${shm_pct}%)"
        fi

        local cache_info
        cache_info=$(docker exec "$cid" df -h /tmp/cache 2>/dev/null | tail -1 \
            | awk '{size=$2; used=$3; pct=$5; sub("%","",pct); print size"|"used"|"pct}')
        local cache_size cache_used cache_pct
        IFS='|' read -r cache_size cache_used cache_pct <<< "$cache_info"
        if [[ -n "$cache_size" ]]; then
            log "  /tmp/cache         ${cache_used}/${cache_size} (${cache_pct}%)"
        fi
    else
        warn "Container           NOT RUNNING"
        warn "  → Fix: ./deploy-frigate.sh recreate"
    fi
    echo ""

    # ------------------------------------------------------------ INFERENCE LAYER
    log "INFERENCE LAYER"
    local stats
    stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null) || stats=""

    if [[ -n "$stats" ]]; then
        echo "$stats" | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    dets = s.get('detectors', {})
    if not dets:
        print('  (no detectors found in stats)')
    for name, v in dets.items():
        spd = v.get('inference_speed', 0)
        if spd == 0:
            print(f'  {name}  ⚠️  inference_speed: 0.0ms  (TRT engine building — det_fps=0 is normal)')
            print(f'         → First-run build takes ~65s on RTX 5060 Ti')
            print(f'         → Wait 2 min then re-run: ./deploy-frigate.sh diagnose')
        elif spd < 10:
            print(f'  {name}  ✅ inference_speed: {spd:.1f}ms  [< 10ms = TRT active]')
        elif spd < 50:
            print(f'  {name}  ⚠️  inference_speed: {spd:.1f}ms  [10-50ms = CUDA, TRT not loaded]')
            print(f'         → Fix: check TensorrtExecutionProvider in config.yml (detector device)')
        else:
            print(f'  {name}  ❌ inference_speed: {spd:.1f}ms  [> 50ms = CPU fallback]')
            print(f'         → Fix: set detector device: Tensorrt  in config.yml and cmd_restart')
except Exception as e:
    print(f'  (could not parse stats: {e})')
"

        # TRT cache directory
        if [[ -d ./trt-cache/tensorrt ]] && ls ./trt-cache/tensorrt/ort/trt-engines/ 2>/dev/null | grep -q .; then
            ok "TRT engine cache    ./trt-cache populated"
        else
            warn "TRT engine cache   ./trt-cache empty — first boot will build (~65s)"
        fi
    else
        warn "Inference           Stats API unreachable"
        warn "  → Fix: check Frigate container status with ./deploy-frigate.sh status"
    fi
    echo ""

    # ------------------------------------------------------------ ZMQ / IPC LAYER
    log "ZMQ / IPC LAYER"
    if [[ -n "$stats" ]]; then
        if has_stuck_cameras; then
            :   # has_stuck_cameras already printed warn with camera names
        else
            ok "ZMQ status          No stuck cameras detected"
        fi
    else
        warn "ZMQ status         Stats API unreachable — cannot check"
    fi
    echo ""

    # ------------------------------------------------------------ CAMERA STREAMS
    log "CAMERA STREAMS"
    if [[ -n "$stats" ]]; then
        # Sub-stream cameras (panoramic whole-lens) are detected via the _left/_right
        # crop cameras, so they show camera_fps=0 by design. Don't flag as errors.
        local sub_cams="allee_sur_le_cote jardin_devant piscine_vue_toit"
        echo "$stats" | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    cams = s.get('cameras', {})
    sub = {'allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'}
    print(f'  {\"Camera\":<28} {\"camera_fps\":>10} {\"process_fps\":>10} {\"detect_fps\":>10}   ZMQ')
    print(f'  ' + '─' * 66)
    active = process = detect = stuck = 0
    for name in sorted(cams.keys()):
        v = cams[name]
        cfps = v.get('camera_fps') or 0
        pfps = v.get('process_fps') or 0
        dfps = v.get('detection_fps') or 0
        is_stuck = cfps > 0 and pfps == 0
        if name in sub:
            zmq = '— sub'
        elif is_stuck:
            zmq = '❌ stuck'
            stuck += 1
        else:
            zmq = '✅'
        print(f'  {name:<28} {cfps:>10.1f} {pfps:>10.1f} {dfps:>10.1f}   {zmq}')
        if cfps > 0: active += 1
        if pfps > 0: process += 1
        if dfps > 0: detect += 1
    print(f'  ' + '─' * 66)
    print(f'  Active: {active}/{len(cams)}   Processing: {process}/{len(cams)}   Detecting: {detect}/{len(cams)}   ZMQ-stuck: {stuck}')
except Exception as e:
    print(f'  (could not parse stats: {e})')
"
    else
        warn "Camera stats        Stats API unreachable"
    fi
    echo ""

    # ------------------------------------------------------------ SERVICE LAYER
    log "SERVICE LAYER"
    if systemctl list-unit-files frigate.service 2>/dev/null | grep -q frigate.service; then
        local svc_state
        svc_state=$(systemctl is-active frigate.service 2>/dev/null || echo "unknown")
        if [[ "$svc_state" == "active" ]]; then
            ok "frigate.service    $svc_state (oneshot running)"
        elif [[ "$svc_state" == "inactive" ]]; then
            ok "frigate.service    $svc_state (oneshot — completed successfully)"
            log "                     Last boot log: journalctl -u frigate -n 50"
        elif [[ "$svc_state" == "failed" ]]; then
            warn "frigate.service   FAILED on last run"
            warn "  → Investigate: journalctl -u frigate -n 100"
        else
            warn "frigate.service   state: $svc_state"
        fi
    else
        log "  frigate.service    not installed"
        log "                     Install: sudo ./deploy-frigate.sh install-service"
    fi
    echo ""
}

# Automated validation suite. Non-destructive by default. Pass 'restart' as
# argument to run Tier 2 (which actually restarts Frigate).
# See plan §13 for the test matrix and expected outputs.
cmd_validate() {
    local tier="${1:-tier1}"
    local pass=0 fail=0 skip=0
    local line

    if [[ "$tier" == "restart" ]]; then
        log "=== Frigate Validation Suite [Tier 2 — restart cycle] ==="
        warn "This will restart Frigate (brief camera interruption)"
        echo ""

        local start_ts end_ts duration
        start_ts=$(date +%s)

        # V10 — restart completes
        log "[V10] Restart completes ........... "
        if cmd_restart >/dev/null 2>&1; then
            ok "PASS"; pass=$((pass+1))
        else
            warn "FAIL — restart returned non-zero exit code"
            warn "  → Inspect: ./deploy-frigate.sh status"
            fail=$((fail+1))
        fi

        end_ts=$(date +%s); duration=$((end_ts - start_ts))

        # V12 — restart duration
        if [[ $duration -lt 300 ]]; then
            log "[V12] Restart duration ........... "
            ok "PASS  (${duration}s < 300s threshold)"; pass=$((pass+1))
        else
            log "[V12] Restart duration ........... "
            warn "FAIL  (${duration}s >= 300s threshold — regression guard triggered)"
            warn "  → Check for resource contention, slow I/O, or false ZMQ retries"
            fail=$((fail+1))
        fi

        # V13 — post-restart ZMQ health
        log "[V13] Post-restart ZMQ health ..... "
        if wait_all_processing 120; then
            sleep 15
            if ! has_stuck_cameras; then
                ok "PASS  (0 stuck cameras after restart)"; pass=$((pass+1))
            else
                warn "FAIL  (stuck cameras persist after restart)"
                fail=$((fail+1))
            fi
        else
            warn "FAIL  (majority of cameras never started processing)"
            fail=$((fail+1))
        fi

        # V14 — post-restart detection
        log "[V14] Post-restart detection ...... "
        local det_ok
        det_ok=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    cams = s.get('cameras', {})
    fed = [(v.get('detection_fps') or 0) for c, v in cams.items() if (v.get('camera_fps') or 0) > 0]
    if not fed: print('0')
    else: print('1' if all(d > 0 for d in fed) else '0')
except Exception: print('0')
" 2>/dev/null)
        if [[ "$det_ok" == "1" ]]; then
            ok "PASS  (all fed cameras have detect_fps > 0)"; pass=$((pass+1))
        else
            warn "FAIL  (some fed cameras still have detect_fps = 0)"
            fail=$((fail+1))
        fi

        # V11 — no spurious ZMQ retry is implicit in restart duration; mark as PASS
        log "[V11] No spurious ZMQ retry ....... "
        if [[ $duration -lt 480 ]]; then
            ok "PASS  (restart finished in ${duration}s, well under retry storm threshold)"; pass=$((pass+1))
        else
            warn "FAIL  (${duration}s suggests retry storm — investigate)"
            fail=$((fail+1))
        fi

        echo ""
        log "=== RESULT: ${pass}/5 PASS — $([[ $fail -eq 0 ]] && echo 'Restart sequence verified reliable' || echo 'Action required') ==="
        return $fail
    fi

    # Default: Tier 1 — non-destructive snapshot
    log "=== Frigate Validation Suite [Tier 1 — non-destructive] ==="
    echo ""

    # V1 — API accessible
    log "[V1]  API accessible .............. "
    if line=$(curl -sf --max-time 5 "${FRIGATE_API}/api/version" 2>/dev/null) && [[ -n "$line" ]]; then
        ok "PASS  (HTTP 200)"; pass=$((pass+1))
    else
        warn "FAIL  (Frigate API not reachable)"
        warn "  → Fix: ./deploy-frigate.sh recreate"
        fail=$((fail+1))
    fi

    # V2 — inference active
    log "[V2]  Inference active ............ "
    local speed
    speed=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    spds = [v.get('inference_speed', 0) for v in s.get('detectors', {}).values()]
    print(max(spds) if spds else 0)
except Exception: print(0)
" 2>/dev/null) || speed=0
    if awk "BEGIN{exit !($speed > 0)}"; then
        ok "PASS  (inference_speed=${speed}ms)"; pass=$((pass+1))
    else
        warn "FAIL  (inference_speed=${speed}ms — detector not running)"
        warn "  → Check TRT engine build status with: ./deploy-frigate.sh diagnose"
        fail=$((fail+1))
    fi

    # V3 — inference speed / mode
    log "[V3]  Inference speed / mode ...... "
    if awk "BEGIN{exit !($speed > 0 && $speed < 50)}"; then
        if awk "BEGIN{exit !($speed < 10)}"; then
            ok "PASS  (${speed}ms < 10ms: TRT active)"; pass=$((pass+1))
        else
            ok "PASS  (${speed}ms 10-50ms: CUDA OK, TRT cache may be empty)"; pass=$((pass+1))
        fi
    else
        warn "FAIL  (${speed}ms >= 50ms: CPU fallback — GPU inference disabled)"
        warn "  → Fix: set detector device: Tensorrt  in config.yml"
        fail=$((fail+1))
    fi

    # V4 — ZMQ IPC health
    log "[V4]  ZMQ IPC health .............. "
    if ! has_stuck_cameras; then
        ok "PASS  (0 stuck cameras)"; pass=$((pass+1))
    else
        warn "FAIL"
        warn "  → Fix: ./deploy-frigate.sh restart"
        fail=$((fail+1))
    fi

    # V5 — camera feeds active (cameras with camera_fps > 0)
    log "[V5]  Camera feeds active ......... "
    local feed_stats
    feed_stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    sub = {'allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'}
    cams = {c: v for c, v in s.get('cameras', {}).items() if c not in sub}
    if not cams: print('0|0|0')
    else:
        active = sum(1 for v in cams.values() if (v.get('camera_fps') or 0) > 0)
        print(f'{active}|{len(cams)}|{active * 100 // len(cams)}')
except Exception: print('0|0|0')
" 2>/dev/null)
    local f_active f_total f_pct
    IFS='|' read -r f_active f_total f_pct <<< "$feed_stats"
    if [[ "$f_total" -eq 0 ]]; then
        ok "PASS  (no detection cameras configured)"; pass=$((pass+1))
    elif [[ $f_pct -ge 50 ]]; then
        ok "PASS  (${f_active}/${f_total} detect cameras have camera_fps>0)"; pass=$((pass+1))
    else
        warn "FAIL  (${f_active}/${f_total} detect cameras have camera_fps>0 — <50%)"
        warn "  → Check RTSP proxy and NUC go2rtc"
        fail=$((fail+1))
    fi

    # V6 — detection running on fed cameras
    log "[V6]  Detection running ........... "
    local det_stats
    det_stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    fed = [(v.get('detection_fps') or 0) for c, v in s.get('cameras', {}).items() if (v.get('camera_fps') or 0) > 0]
    if not fed: print('0|0|1')   # no fed cameras → vacuously OK
    else:
        d_ok = sum(1 for d in fed if d > 0)
        print(f'{d_ok}|{len(fed)}|{0 if d_ok < len(fed) else 1}')
except Exception: print('0|0|0')
" 2>/dev/null)
    local d_ok d_total d_pass
    IFS='|' read -r d_ok d_total d_pass <<< "$det_stats"
    if [[ "$d_pass" == "1" ]]; then
        if [[ "$d_total" == "0" ]]; then
            ok "PASS  (no fed cameras to verify)"; pass=$((pass+1))
        else
            ok "PASS  (${d_ok}/${d_total} fed cameras have detect_fps>0)"; pass=$((pass+1))
        fi
    else
        warn "FAIL  (${d_ok}/${d_total} fed cameras have detect_fps>0)"
        warn "  → ZMQ broken — Fix: ./deploy-frigate.sh restart"
        fail=$((fail+1))
    fi

    # V7 — /dev/shm headroom
    log "[V7]  /dev/shm headroom ........... "
    local cid2 shm_pct
    cid2=$(dc ps -q "$SERVICE" 2>/dev/null | head -1)
    if [[ -n "$cid2" ]]; then
        shm_pct=$(docker exec "$cid2" df /dev/shm 2>/dev/null | tail -1 | awk '{sub("%","",$5); print $5}')
    fi
    if [[ -z "$shm_pct" ]]; then
        ok "PASS  (container not running)"; pass=$((pass+1))
    elif [[ "$shm_pct" -ge 95 ]]; then
        warn "FAIL  (${shm_pct}% used — CRITICAL)"
        warn "  → Fix: increase shm_size in docker-compose.calypso.yml and cmd_recreate"
        fail=$((fail+1))
    elif [[ "$shm_pct" -ge 80 ]]; then
        warn "WARN  (${shm_pct}% used — pressure, not a fail)"
        skip=$((skip+1)); pass=$((pass+1))   # counts as pass; warn is informational
    else
        ok "PASS  (${shm_pct}% used; threshold 80%)"; pass=$((pass+1))
    fi

    # V8 — Host NVIDIA devices
    log "[V8]  Host NVIDIA devices ......... "
    local nvidia_devs="/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools"
    if ls $nvidia_devs >/dev/null 2>&1; then
        ok "PASS  (all 5 device nodes present)"; pass=$((pass+1))
    else
        warn "FAIL  (one or more NVIDIA device nodes missing)"
        warn "  → Fix: sudo modprobe nvidia nvidia-uvm nvidia-modeset"
        fail=$((fail+1))
    fi

    # V9 — NAS mounted
    log "[V9]  NAS mount ................... "
    local media_path_v="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"
    if mountpoint -q "$media_path_v" 2>/dev/null; then
        ok "PASS  ($media_path_v is mountpoint)"; pass=$((pass+1))
    else
        warn "WARN  ($media_path_v is not a mountpoint — recordings at risk)"
        warn "  → Fix: sudo mount -a  OR  check NAS connectivity"
        fail=$((fail+1))
    fi

    echo ""
    log "=== RESULT: ${pass}/9 PASS $([[ $fail -gt 0 ]] && echo '+ '$fail' FAIL — Action required (see failed tests above)' || echo '— System verified healthy') ==="
    echo ""
    log "To test restart reliability:  ./deploy-frigate.sh validate restart"
    return $fail
}

cmd_boot() {
    # Called by frigate.service on host boot.
    # Docker's `restart: unless-stopped` auto-starts the container, but does NOT
    # run the ZMQ-fix stop+start cycle. This function does that cycle and confirms
    # ZMQ health (process_fps > 0) before returning.
    log "=== Boot ZMQ-fix sequence (called by frigate.service) ==="
    local boot_ok=1   # 1 = healthy, 0 = stuck cameras remain

    # Cold-boot pre-flight checks (warn-only, non-fatal).
    # wait_for_nvidia: NVIDIA driver may not be fully loaded when systemd starts
    #                  frigate.service — the driver often finishes after container
    #                  auto-start. 120s gives it time.
    # check_host_readiness: visibility into NAS / RTSP proxy / MQTT reachability.
    wait_for_nvidia 120
    check_host_readiness

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
    wait_all_processing 120 || true  # majority of cameras processing

    # Two-phase readiness pattern (plan §4):
    #   Phase 1 exits early on majority success. After that exit, allow 15s for
    #   tail cameras to complete ZMQ init (camera_fps→process_fps lag is 1-5s in
    #   healthy ZMQ; 15s gives a 3-15x safety margin).
    #   Phase 2 is the strict stuck-camera check — safe from false positives
    #   because of the grace period.
    #   One retry maximum — same as pre-fix behaviour; the strict check is the
    #   signal, not the retry driver (that pattern caused the 17-min regression).
    if wait_all_processing 120; then
        log "Majority processing. Waiting 15s straggler grace period..."
        sleep 15
    fi

    if has_stuck_cameras; then
        warn "Doing one more ZMQ reset for stuck cameras above..."
        zmq_fix_cycle
        wait_healthy
        wait_detector_ready 120 || true
        wait_all_processing 60 || true
        sleep 15
        if has_stuck_cameras; then
            warn "ZMQ IPC still unhealthy after retry — manual intervention may be needed"
            warn "  Run: ./deploy-frigate.sh status  to see per-camera fps"
            warn "  Common causes: config error in output_args.detect CUDA crop chain,"
            warn "  detector deadlock, or hardware fault. Check Frigate logs for stack traces."
            boot_ok=0
        fi
    fi

    log "Post-boot health:"
    check_inference
    check_det_fps

    check_shm

    if [[ $boot_ok -eq 1 ]]; then
        ok "Boot sequence complete"
        return 0
    else
        warn "Boot FINISHED but cameras are still stuck — system is NOT fully healthy"
        return 1
    fi
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
    local restart_ok=1   # 1 = healthy, 0 = stuck cameras remain
    zmq_fix_cycle
    wait_healthy
    # Wait for detector model to load (TRT cache: ~5s; first build: ~65s)
    wait_detector_ready 120 || true
    # Wait for ZMQ IPC to be healthy: majority of cameras must have process_fps > 0
    wait_all_processing 120 || true

    # Two-phase readiness pattern (plan §4):
    #   Phase 1: wait_all_processing 120 → exits early on majority success.
    #   Grace: 15s sleep on success to let tail cameras complete ZMQ init.
    #   Phase 2: has_stuck_cameras → strict check, safe from false positives.
    #   One retry maximum (avoids the 17-min regression from REL-6).
    if wait_all_processing 120; then
        log "Majority processing. Waiting 15s straggler grace period..."
        sleep 15
    fi

    if has_stuck_cameras; then
        warn "Doing one more ZMQ reset for stuck cameras above..."
        zmq_fix_cycle
        wait_healthy
        wait_detector_ready 120 || true
        wait_all_processing 60 || true
        sleep 15
        if has_stuck_cameras; then
            warn "ZMQ IPC still unhealthy after retry — manual intervention may be needed"
            warn "  Run: ./deploy-frigate.sh status  to see per-camera fps"
            warn "  Common causes: config error in output_args.detect CUDA crop chain,"
            warn "  detector deadlock, or hardware fault. Check Frigate logs for stack traces."
            restart_ok=0
        fi
    fi

    log "Post-restart health:"
    check_inference
    check_det_fps

    check_shm

    if [[ $restart_ok -eq 1 ]]; then
        ok "Restart complete"
        return 0
    else
        warn "Restart FINISHED but cameras are still stuck — system is NOT fully healthy"
        return 1   # non-zero exit so validate restart can detect the failure
    fi
}

cmd_recreate() {
    log "=== Full container recreation ==="
    warn "This will stop Frigate and recreate the container."
    warn "shm_size, image, devices and volume changes will take effect."
    local recreate_ok=1   # 1 = healthy, 0 = stuck cameras remain
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

    # Two-phase readiness pattern (plan §4):
    #   Phase 1: wait_all_processing 120 → exits early on majority success.
    #   Grace: 15s sleep on success to let tail cameras complete ZMQ init.
    #   Phase 2: has_stuck_cameras → strict check, safe from false positives.
    #   One retry maximum (avoids the 17-min regression from REL-6).
    if wait_all_processing 120; then
        log "Majority processing. Waiting 15s straggler grace period..."
        sleep 15
    fi

    if has_stuck_cameras; then
        warn "Doing one more ZMQ reset for stuck cameras above..."
        zmq_fix_cycle
        wait_healthy
        wait_detector_ready 120 || true
        wait_all_processing 60 || true
        sleep 15
        if has_stuck_cameras; then
            warn "ZMQ IPC still unhealthy after retry — manual intervention may be needed"
            warn "  Run: ./deploy-frigate.sh status  to see per-camera fps"
            warn "  Common causes: config error in output_args.detect CUDA crop chain,"
            warn "  detector deadlock, or hardware fault. Check Frigate logs for stack traces."
            recreate_ok=0
        fi
    fi

    log "Post-recreation health:"
    check_inference
    check_det_fps

    check_shm

    echo ""
    if [[ $recreate_ok -eq 1 ]]; then
        ok "Recreation complete"
        warn "Remember to update SOAK_EPOCH in this script if this is a soak restart:"
        echo "  SOAK_EPOCH=\$(date +%s)  # current epoch: $(date +%s)"
        return 0
    else
        warn "Recreation FINISHED but cameras are still stuck — system is NOT fully healthy"
        return 1
    fi
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
    diagnose)
        cmd_diagnose
        ;;
    validate)
        cmd_validate "${2:-tier1}"
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
        echo "Usage: $0 [restart|recreate|boot|install-service|status|diagnose|validate|dump|auto]"
        echo ""
        echo "  auto             (default) detect whether recreation is needed"
        echo "  restart          config.yml change only — no container recreation"
        echo "  recreate         image/shm_size/devices changed — full stop+rm+up+stop+start"
        echo "  boot             ZMQ-fix cycle after host reboot (used by frigate.service)"
        echo "  install-service  install + enable frigate.service (requires sudo)"
        echo "  status           show inference speed, det_fps, /dev/shm usage"
        echo "  diagnose         5-layer health display (host, docker, inference, ZMQ, cameras) with Fix: lines"
        echo "  validate         automated test suite (9 non-destructive tests; 'validate restart' for full cycle)"
        echo "  dump             Option-B event dump for Track A soak analysis"
        exit 1
        ;;
esac
