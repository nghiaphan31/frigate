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
#   ./deploy-frigate.sh diagnose   # read-only 5-layer health snapshot (Phase 2, no state change)
#   ./deploy-frigate.sh validate   # 9 read-only validation tests (Phase 2, no state change)
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
SOAK_EPOCH=1779782843  # iter3 soak start: 2026-05-26 08:06 UTC

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

# wait_for_port_release <port> <timeout_seconds>
#   Returns 0 if <port> is NOT bound to anything within <timeout_seconds>,
#   1 otherwise. Used by safe_stop to ensure the new container's process
#   can bind to Frigate's main API port (5000) without hitting
#   'OSError: [Errno 98] Address already in use'. Without this check, the
#   old Frigate process can hold the port via TIME_WAIT or half-closed
#   sockets even after `docker stop -t 30` returns.
#   Tries `ss` first (Linux), falls back to `/proc/net/tcp*` if missing.
wait_for_port_release() {
    local port="$1"
    local timeout="${2:-30}"
    local interval=2
    local elapsed=0
    # Use ss (modern) if available, else /proc/net/tcp (port in hex)
    if command -v ss >/dev/null 2>&1; then
        while [[ $elapsed -lt $timeout ]]; do
            if ! ss -tlnH "sport = :$port" 2>/dev/null | grep -q LISTEN; then
                return 0
            fi
            sleep "$interval"
            elapsed=$((elapsed + interval))
        done
    else
        # Fallback: parse /proc/net/tcp and /proc/net/tcp6
        local hex_port
        hex_port=$(printf '%04X' "$port")
        while [[ $elapsed -lt $timeout ]]; do
            if ! grep -E ":${hex_port} " /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -q " 0A "; then
                # 0A = TCP_LISTEN state
                return 0
            fi
            sleep "$interval"
            elapsed=$((elapsed + interval))
        done
    fi
    return 1
}

# safe_stop <container_name> <port> [<port> ...]
#   Stops a container with 30s grace and waits for ALL named ports to be
#   released before returning. If any port is still held after 30s, sends
#   SIGKILL to force the container to release it, then waits 10s more.
#   This is the shared core of cmd_restart and cmd_recreate — both
#   previously used `dc stop` (10s default) which was too short for
#   Frigate to release its sockets cleanly, causing the new process to
#   hit 'OSError: [Errno 98] Address already in use' on the WebSocket
#   server (port 5002), making the detect process unable to register.
#   The result was a ZMQ-stuck state where ffmpeg captures ran
#   (camera_fps > 0) but detection never registered (process_fps = 0).
#   This function prevents that regression.
#   Frigate ports: 5000 (main API), 5002 (WebSocket — the critical one).
safe_stop() {
    local container_name="$1"
    shift
    local ports=("$@")

    log "Stopping ${container_name} (30s grace)..."
    if ! docker stop -t 30 "$container_name" >/dev/null 2>&1; then
        warn "docker stop returned non-zero (container may already be stopped) — continuing"
    fi

    log "Waiting for ports ${ports[*]} to be released..."
    local all_released=true
    for port in "${ports[@]}"; do
        if ! wait_for_port_release "$port" 30; then
            all_released=false
            break
        fi
    done

    if $all_released; then
        ok "All ports released (${ports[*]})"
    else
        warn "Port still held after 30s — sending SIGKILL to force release"
        if ! docker kill "$container_name" >/dev/null 2>&1; then
            warn "docker kill returned non-zero (container may already be gone) — continuing"
        fi
        for port in "${ports[@]}"; do
            if ! wait_for_port_release "$port" 10; then
                fail "Port ${port} still held even after SIGKILL — manual intervention needed"
            fi
        done
        ok "All ports released (after SIGKILL)"
    fi
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
# Read-only diagnostic helpers (Phase 2 — no behavioral change)
# ---------------------------------------------------------------------------

# is_on_mount <path>
#   Returns 0 (success) if <path> is on a mounted filesystem (i.e. not on the
#   host rootfs), 1 (failure) otherwise.
#   Unlike `mountpoint -q`, this correctly handles subdirectories of mountpoints
#   (e.g. /mnt/nas/video/frigate is on a NAS mount — mountpoint -q returns 1
#   for subdirs, but is_on_mount correctly returns 0 by walking up to the
#   actual mount target via `df --output=target`).
is_on_mount() {
    local path="$1"
    [[ -e "$path" ]] || return 1
    # df --output=target prints the mountpoint of the filesystem containing
    # the file. If the path is on the root filesystem, the target is "/".
    local mount_target
    mount_target=$(df --output=target "$path" 2>/dev/null | tail -n 1 | tr -d ' ')
    if [[ -z "$mount_target" || "$mount_target" == "/" ]]; then
        return 1
    fi
    return 0
}

# check_host_readiness
#   Read-only host-level health snapshot: NVIDIA device nodes, NAS mount
#   (via is_on_mount), NUC RTSP proxy, MQTT broker reachability.
#   NO state changes — purely observability. Used by cmd_diagnose (HOST LAYER)
#   and cmd_validate (V8, V9). Returns 0 if all checks passed, 1 otherwise.
check_host_readiness() {
    local media_path="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"
    local ret=0

    # 1. NVIDIA device nodes
    local nvidia_devs=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools)
    local missing=()
    for d in "${nvidia_devs[@]}"; do
        [[ -e "$d" ]] || missing+=("$d")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "  NVIDIA devices     ✅  all 5 nodes present (nvidia0/ctl/modeset/uvm/uvm-tools)"
    else
        warn "  NVIDIA devices     ❌  missing: ${missing[*]}"
        warn "                          → Fix: sudo modprobe nvidia-uvm  OR  wait for driver init"
        ret=1
    fi

    # 2. NAS mount (uses is_on_mount — correctly handles NFS subdirs)
    if is_on_mount "$media_path"; then
        local mount_target
        mount_target=$(df --output=target "$media_path" 2>/dev/null | tail -n 1 | tr -d ' ')
        ok "  NAS mount          ✅  ${media_path} is on mount '${mount_target}'"
    else
        warn "  NAS mount          ⚠️   ${media_path} is NOT on a mount (rootfs or missing)"
        warn "                          Recordings will go to container overlay (data LOSS risk)"
        warn "                          → Fix: sudo mount -a  OR  check NAS and /etc/fstab"
    fi

    # 3. NUC RTSP proxy (warn only — go2rtc retries internally)
    if timeout 3 bash -c "echo >/dev/tcp/192.168.50.112/8556" 2>/dev/null; then
        ok "  RTSP proxy         ✅  192.168.50.112:8556 reachable"
    else
        warn "  RTSP proxy         ⚠️   192.168.50.112:8556 unreachable — cameras will show no frames"
        ret=1
    fi

    # 4. MQTT broker (warn only — Frigate retries internally)
    if timeout 3 bash -c "echo >/dev/tcp/192.168.50.125/1883" 2>/dev/null; then
        ok "  MQTT broker        ✅  192.168.50.125:1883 reachable"
    else
        warn "  MQTT broker        ⚠️   192.168.50.125:1883 unreachable — HA events won't publish"
    fi

    return $ret
}

# _py <data> <<'PYEOF'
#   Run a Python script (read from a quoted heredoc on stdin) with <data>
#   on python3's stdin. The script is written verbatim to a temp file so
#   indentation is preserved correctly (no leading-whitespace stripping).
#   Errors are swallowed via `|| true` so a Python crash NEVER exits the
#   parent script under `set -e`. Returns 0 always.
_py() {
    local data="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/frigate_py_XXXXXX.py 2>/dev/null) || { return 0; }
    cat > "$tmpfile"
    echo "$data" | python3 "$tmpfile" 2>/dev/null || true
    rm -f "$tmpfile"
    return 0
}

# Sub-streams (panoramic whole-lens views) have camera_fps=0 by design.
# Used by cmd_diagnose and cmd_validate to exclude them from "stuck camera" counts.
SUB_STREAMS=("allee_sur_le_cote" "jardin_devant" "piscine_vue_toit")

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
    local container_name="frigate_${SERVICE}_1"
    log "=== Config-only restart (stop+start — never docker-compose restart) ==="
    # IMPORTANT: `docker-compose restart` leaves ZMQ IPC sockets broken → det_fps=0.
    # Always use stop+start instead, even for config-only changes.
    # safe_stop() ensures the old container's ports are FULLY released before
    # the new container starts; this prevents the port-conflict regression
    # that caused cameras to get stuck (camera_fps > 0, process_fps = 0).
    safe_stop "$container_name" 5000 5002
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
    # safe_stop() (30s grace + port-release check + SIGKILL fallback) ensures
    # the old container's port 5000 is FULLY released before we `rm` and `up`.
    # Without this, the new container's API server hits 'OSError: [Errno 98]
    # Address already in use' and fails to start, leaving all cameras
    # ZMQ-stuck (camera_fps > 0 but process_fps = 0).
    log "Step 1/2 — stop (30s grace) + wait for port + rm + up..."
    safe_stop "frigate_${SERVICE}_1" 5000 5002
    dc rm -f "$SERVICE"
    dc up -d "$SERVICE"

    # Brief pause to let the container start its init sequence
    sleep 5

    # Step 2: stop + start to fix ZMQ IPC deadlock
    # After `up -d` following `rm -f`, ZMQ IPC sockets between the capture
    # and detect processes are in a broken state → det_fps=0 on all cameras.
    # A stop/start cycle resets the IPC correctly. We use safe_stop() again
    # to ensure the second start can actually bind to ports 5000 and 5002.
    log "Step 2/2 — stop (30s grace) + wait for port + start (fix ZMQ IPC deadlock)..."
    safe_stop "frigate_${SERVICE}_1" 5000 5002
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
# cmd_diagnose  (Phase 2 — read-only 5-layer health snapshot)
# ---------------------------------------------------------------------------
# STRICTLY READ-ONLY. Does NOT modify any state. Output is for human eyes
# (no --json flag yet — see plan §9 open question #3). Each failure line
# includes a → Fix: directive.

cmd_diagnose() {
    local container_name="frigate_${SERVICE}_1"
    log "=== Frigate System Diagnostics [$(date '+%Y-%m-%d %H:%M:%S')] ==="
    echo ""

    # ---- LAYER 1: HOST ----
    log "HOST LAYER"
    check_host_readiness
    echo ""

    # ---- LAYER 2: DOCKER ----
    log "DOCKER LAYER"
    if docker inspect "${container_name}" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        local img started
        img=$(docker inspect "${container_name}" --format '{{.Config.Image}}' 2>/dev/null || echo "?")
        started=$(docker inspect "${container_name}" --format '{{.State.StartedAt}}' 2>/dev/null || echo "?")
        ok "  Container          ✅  running (${img})"
        ok "                          started: ${started}"
    else
        warn "  Container          ❌  NOT running (no container named '${container_name}')"
        warn "                          → Fix: ./deploy-frigate.sh recreate"
    fi
    check_shm
    local cache_info
    cache_info=$(docker exec "${container_name}" df -h /tmp/cache 2>/dev/null \
        | tail -1 | awk '{print "size="$2" used="$3" avail="$4" use%="$5}') \
        || cache_info="(could not read)"
    echo "  /tmp/cache:         $cache_info"
    echo ""

    # ---- LAYER 3: INFERENCE ----
    log "INFERENCE LAYER"
    local stats
    stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null) || {
        warn "  Could not reach Frigate stats API"
        stats=""
    }
    if [[ -n "$stats" ]]; then
        _py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
det = s.get('detectors', {})
if not det:
    print('  (no detectors reported)')
for name, v in det.items():
    spd = v.get('inference_speed', 0) or 0
    if spd == 0:
        sym, status = '⚠️ ', '(TRT engine building — first run ~65s on RTX 5060 Ti)'
    elif spd < 10:
        sym, status = '✅', '(TRT active)'
    elif spd < 50:
        sym, status = '⚠️ ', '(CUDA EP — TRT not loaded)'
    else:
        sym, status = '❌', '(CPU fallback — inference is broken)'
    print(f'  {name:<16} {sym}  inference_speed={spd:.1f}ms  {status}')
PYEOF
    else
        warn "  (no stats available)"
    fi
    # TRT engine cache presence
    if find ./trt-cache -maxdepth 2 -type f \( -name '*.engine' -o -name '*.plan' \) 2>/dev/null | grep -q .; then
        ok "  TRT engine cache   ✅  ./trt-cache populated"
    else
        warn "  TRT engine cache   ⚠️  no engine files found — first run will build (~65s)"
    fi
    echo ""

    # ---- LAYER 4: ZMQ / IPC ----
    log "ZMQ / IPC LAYER"
    if [[ -n "$stats" ]]; then
        local stuck_line
        stuck_line=$(_py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
SUB = {'allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'}
cams = s.get('cameras', {})
stuck = [c for c, v in cams.items()
         if c not in SUB
         and (v.get('camera_fps') or 0) > 0
         and (v.get('process_fps') or 0) == 0]
print(len(stuck))
print(','.join(stuck))
PYEOF
)
        local stuck_n stuck_list
        stuck_n=$(echo "$stuck_line" | head -1 | tr -d ' \t\n')
        stuck_list=$(echo "$stuck_line" | tail -1)
        stuck_n=${stuck_n:-0}
        if [[ "$stuck_n" -eq 0 ]]; then
            ok "  ZMQ status         ✅  no stuck cameras detected"
        else
            warn "  ZMQ status         ❌  ${stuck_n} camera(s) ZMQ-stuck: ${stuck_list}"
            warn "                          camera_fps > 0 (RTSP OK) but process_fps = 0 (ZMQ IPC broken)"
            warn "                          → Fix: ./deploy-frigate.sh restart"
        fi
    else
        warn "  ZMQ status         ❌  (no stats — cannot evaluate)"
    fi
    echo ""

    # ---- LAYER 5: CAMERA STREAMS ----
    log "CAMERA STREAMS"
    if [[ -n "$stats" ]]; then
        _py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
SUB = {'allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'}
cams = s.get('cameras', {})
print(f'  {"Camera":<32} {"cam_fps":>8} {"proc_fps":>9} {"det_fps":>8}   ZMQ')
print('  ' + '-'*32 + ' ' + '-'*8 + ' ' + '-'*9 + ' ' + '-'*8 + '   ' + '-'*3)
active = processing = detecting = stuck = 0
for name in sorted(cams.keys()):
    v = cams[name]
    cf = v.get('camera_fps') or 0
    pf = v.get('process_fps') or 0
    df = v.get('detection', {}).get('det_fps', 0) or 0
    if name in SUB:
        zmq = '— sub'
    elif cf > 0 and pf > 0:
        zmq = '✅'
        active += 1; processing += 1; detecting += 1
    elif cf > 0 and pf == 0:
        zmq = '❌'
        active += 1; stuck += 1
    else:
        zmq = '—'
    print(f'  {name:<32} {cf:>8.1f} {pf:>9.1f} {df:>8.1f}   {zmq}')
print()
print(f'  Active: {active}   Processing: {processing}   Detecting: {detecting}   ZMQ-stuck: {stuck}')
PYEOF
    else
        warn "  (no camera stats available)"
    fi
    echo ""

    # ---- LAYER 6: SERVICE (systemd unit) ----
    log "SERVICE LAYER"
    if command -v systemctl >/dev/null 2>&1; then
        local svc_state
        svc_state=$(systemctl is-active frigate.service 2>/dev/null || echo "unknown")
        case "$svc_state" in
            active|inactive)
                ok "  frigate.service    ✅  ${svc_state}"
                ;;
            failed)
                warn "  frigate.service    ❌  failed"
                warn "                          → Fix: journalctl -u frigate -n 50"
                ;;
            *)
                warn "  frigate.service    ⚠️  ${svc_state}"
                ;;
        esac
        echo "                          Last boot log: journalctl -u frigate -n 50"
    else
        echo "  frigate.service    (systemctl not available on this host)"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# cmd_validate  (Phase 2 — Tier 1 + Phase 3 — Tier 2)
# ---------------------------------------------------------------------------
# Tier 1 (default): STRICTLY READ-ONLY. Does NOT modify any state. 9 tests.
# Tier 2 ('restart'): DESTRUCTIVE — runs cmd_restart and validates the
#   post-restart state. Opt-in by passing 'restart' as the second arg.
#   5 tests: V10 (restart completes), V11 (no spurious ZMQ retry),
#   V12 (duration < 5 min), V13 (post-restart ZMQ health), V14 (post-restart detection).

cmd_validate() {
    local tier="${1:-tier1}"

    if [[ "$tier" == "restart" ]]; then
        cmd_validate_restart
        return $?
    fi

    if [[ "$tier" != "tier1" && "$tier" != "" ]]; then
        warn "Unknown validate tier: '${tier}'. Supported: 'tier1' (default), 'restart' (Tier 2 — destructive)"
        return 1
    fi

    log "=== Frigate Validation Suite [Tier 1 — non-destructive] ==="
    echo ""

    local pass=0 fail=0 warn_count=0
    local stats
    stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null) || stats=""

    # ----- V1: API accessible -----
    local v1_start_ns v1_end_ns v1_ms
    v1_start_ns=$(date +%s%N)
    if curl -sf "${FRIGATE_API}/api/version" -o /dev/null; then
        v1_end_ns=$(date +%s%N)
        v1_ms=$(( (v1_end_ns - v1_start_ns) / 1000000 ))
        ok "  [V1]  API accessible .............. ✅ PASS  (HTTP 200, ${v1_ms}ms)"
        pass=$((pass+1))
    else
        warn "  [V1]  API accessible .............. ❌ FAIL  (curl to ${FRIGATE_API} failed)"
        warn "                              → Fix: ./deploy-frigate.sh recreate"
        fail=$((fail+1))
    fi

    # ----- V2: Inference active -----
    local speed
    speed=$(_py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
det = s.get('detectors', {})
for v in det.values():
    print(v.get('inference_speed', 0))
    break
PYEOF
)
    speed=${speed:-}
    if [[ -n "$speed" ]] && python3 -c "import sys; sys.exit(0 if float('$speed') > 0 else 1)" 2>/dev/null; then
        ok "  [V2]  Inference active ............ ✅ PASS  (inference_speed=${speed}ms)"
        pass=$((pass+1))
    else
        warn "  [V2]  Inference active ............ ❌ FAIL  (inference_speed not > 0 — TRT may be building)"
        warn "                              → Run: ./deploy-frigate.sh diagnose  for details"
        fail=$((fail+1))
    fi

    # ----- V3: Inference speed / mode -----
    if [[ -n "$speed" ]] && python3 -c "import sys; sys.exit(0 if float('$speed') > 0 else 1)" 2>/dev/null; then
        if python3 -c "import sys; sys.exit(0 if float('$speed') < 10 else 1)" 2>/dev/null; then
            ok "  [V3]  Inference speed / mode ...... ✅ PASS  (${speed}ms < 10ms: TRT active)"
            pass=$((pass+1))
        elif python3 -c "import sys; sys.exit(0 if float('$speed') < 50 else 1)" 2>/dev/null; then
            warn "  [V3]  Inference speed / mode ...... ⚠️  WARN  (${speed}ms: CUDA EP, not TRT)"
            warn_count=$((warn_count+1))
        else
            warn "  [V3]  Inference speed / mode ...... ❌ FAIL  (${speed}ms: CPU fallback)"
            fail=$((fail+1))
        fi
    else
        warn "  [V3]  Inference speed / mode ...... ❌ FAIL  (no inference_speed data)"
        fail=$((fail+1))
    fi

    # ----- V4: ZMQ IPC health (no stuck cameras) -----
    local stuck_csv
    stuck_csv=$(_py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
SUB = set(['allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'])
cams = s.get('cameras', {})
stuck = [c for c, v in cams.items()
         if c not in SUB
         and (v.get('camera_fps') or 0) > 0
         and (v.get('process_fps') or 0) == 0]
print(','.join(stuck))
print(len(stuck))
PYEOF
)
    local stuck_names stuck_n
    stuck_names=$(echo "$stuck_csv" | head -1)
    stuck_n=$(echo "$stuck_csv" | tail -1 | tr -d ' \t\n')
    stuck_n=${stuck_n:-0}
    if [[ "$stuck_n" -eq 0 ]]; then
        ok "  [V4]  ZMQ IPC health .............. ✅ PASS  (0 stuck cameras)"
        pass=$((pass+1))
    else
        warn "  [V4]  ZMQ IPC health .............. ❌ FAIL"
        warn "                              Stuck cameras: ${stuck_names}"
        warn "                              camera_fps > 0 but process_fps = 0 — ZMQ IPC broken"
        warn "                              → Fix: ./deploy-frigate.sh restart"
        fail=$((fail+1))
    fi

    # ----- V5: Camera feeds active (>50% of detect cameras have camera_fps>0) -----
    local v5_line
    v5_line=$(_py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
SUB = set(['allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'])
cams = s.get('cameras', {})
detect_cams = [c for c in cams if c not in SUB]
active = [c for c in detect_cams if (cams[c].get('camera_fps') or 0) > 0]
print(len(active))
print(len(detect_cams))
PYEOF
)
    local v5_active v5_total
    v5_active=$(echo "$v5_line" | head -1 | tr -d ' \t\n')
    v5_total=$(echo "$v5_line" | tail -1 | tr -d ' \t\n')
    v5_active=${v5_active:-0}
    v5_total=${v5_total:-0}
    if [[ "$v5_total" -eq 0 ]]; then
        warn "  [V5]  Camera feeds active ......... ❌ FAIL  (no detect cameras found)"
        fail=$((fail+1))
    else
        local v5_pct=$((v5_active * 100 / v5_total))
        if [[ "$v5_pct" -gt 50 ]]; then
            ok "  [V5]  Camera feeds active ......... ✅ PASS  (${v5_active}/${v5_total} detect cameras have camera_fps>0)"
            pass=$((pass+1))
        else
            warn "  [V5]  Camera feeds active ......... ⚠️  WARN  (${v5_active}/${v5_total} only — check RTSP proxy / NUC)"
            warn_count=$((warn_count+1))
        fi
    fi

    # ----- V6: Detection running (all active cameras have detect_fps>0) -----
    local v6_line
    v6_line=$(_py "$stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
SUB = set(['allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'])
cams = s.get('cameras', {})
active = [c for c, v in cams.items()
          if c not in SUB and (v.get('camera_fps') or 0) > 0]
det_ok = [c for c in active if (cams[c].get('detection', {}).get('det_fps', 0) or 0) > 0]
print(len(det_ok))
print(len(active))
PYEOF
)
    local v6_det_ok v6_active
    v6_det_ok=$(echo "$v6_line" | head -1 | tr -d ' \t\n')
    v6_active=$(echo "$v6_line" | tail -1 | tr -d ' \t\n')
    v6_det_ok=${v6_det_ok:-0}
    v6_active=${v6_active:-0}
    if [[ "$v6_active" -eq 0 ]]; then
        warn "  [V6]  Detection running ........... ❌ FAIL  (no active cameras — see V5)"
        fail=$((fail+1))
    elif [[ "$v6_det_ok" -eq "$v6_active" ]]; then
        ok "  [V6]  Detection running ........... ✅ PASS  (${v6_det_ok}/${v6_active} active cameras have detect_fps>0)"
        pass=$((pass+1))
    else
        warn "  [V6]  Detection running ........... ❌ FAIL  (${v6_det_ok}/${v6_active} cameras have detect_fps>0 — ZMQ broken)"
        warn "                              → Fix: ./deploy-frigate.sh restart"
        fail=$((fail+1))
    fi

    # ----- V7: /dev/shm headroom -----
    local shm_line shm_pct
    shm_line=$(docker exec "frigate_${SERVICE}_1" df /dev/shm 2>/dev/null | tail -1)
    if [[ -n "$shm_line" ]]; then
        shm_pct=$(echo "$shm_line" | awk '{print $5}' | tr -d '%' | tr -d ' \t\n')
        shm_pct=${shm_pct:-0}
        if [[ "$shm_pct" -lt 80 ]]; then
            ok "  [V7]  /dev/shm headroom ........... ✅ PASS  (${shm_pct}% used; threshold 80%)"
            pass=$((pass+1))
        elif [[ "$shm_pct" -lt 95 ]]; then
            warn "  [V7]  /dev/shm headroom ........... ⚠️  WARN  (${shm_pct}% used — corrupted frames risk)"
            warn_count=$((warn_count+1))
        else
            warn "  [V7]  /dev/shm headroom ........... ❌ FAIL  (${shm_pct}% used — critical)"
            fail=$((fail+1))
        fi
    else
        warn "  [V7]  /dev/shm headroom ........... ❌ FAIL  (could not read /dev/shm from container)"
        fail=$((fail+1))
    fi

    # ----- V8: Host NVIDIA devices -----
    local nvidia_devs=(/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools)
    local nvidia_missing=()
    for d in "${nvidia_devs[@]}"; do
        [[ -e "$d" ]] || nvidia_missing+=("$d")
    done
    if [[ ${#nvidia_missing[@]} -eq 0 ]]; then
        ok "  [V8]  Host NVIDIA devices ......... ✅ PASS  (all 5 device nodes present)"
        pass=$((pass+1))
    else
        warn "  [V8]  Host NVIDIA devices ......... ❌ FAIL  (missing: ${nvidia_missing[*]})"
        warn "                              → Fix: sudo modprobe nvidia-uvm  OR  wait for driver init"
        fail=$((fail+1))
    fi

    # ----- V9: NAS mounted (uses is_on_mount — handles NFS subdirs) -----
    local media_path="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"
    if is_on_mount "$media_path"; then
        local mount_target
        mount_target=$(df --output=target "$media_path" 2>/dev/null | tail -n 1 | tr -d ' ')
        ok "  [V9]  NAS mount ................... ✅ PASS  (${media_path} is on mount '${mount_target}')"
        pass=$((pass+1))
    else
        warn "  [V9]  NAS mount ................... ⚠️  WARN  (${media_path} is NOT on a mount — recordings at risk)"
        warn "                              → Fix: sudo mount -a  OR  check NAS and /etc/fstab"
        warn_count=$((warn_count+1))
    fi

    echo ""
    local total=$((pass + fail + warn_count))
    if [[ "$fail" -eq 0 ]]; then
        ok "=== RESULT: ${pass}/${total} PASS — System verified healthy ==="
        echo ""
        echo "To test restart reliability (Tier 2 — destructive, will restart Frigate):"
        echo "  ./deploy-frigate.sh validate restart"
    else
        warn "=== RESULT: ${pass}/${total} PASS, ${fail}/${total} FAIL — Action required ==="
        return 1
    fi
}

# ---------------------------------------------------------------------------
# cmd_validate_restart  (Phase 3 — Tier 2, 5 tests, DESTRUCTIVE)
# ---------------------------------------------------------------------------
# Runs cmd_restart and validates that the restart cycle is reliable:
#   V10: cmd_restart returned 0 and 'Restart complete' in its output
#   V11: cmd_restart did NOT log a spurious ZMQ retry (anti-pattern guard)
#   V12: restart duration < 5 min (regression guard against REL-6 17-min bug)
#   V13: within 120s of restart, no cameras ZMQ-stuck (camera_fps>0 & process_fps=0)
#   V14: within 120s of restart, all active cameras have detect_fps>0
#
# This is the "opt-in destructive" test from plan §9 open question #1.
# The default ./deploy-frigate.sh validate is still Tier 1 (read-only).
#
# Safety: this function does NOT introduce any new restart retry logic.
# It calls the existing cmd_restart exactly once. If V13/V14 fail, the
# operator must run ./deploy-frigate.sh restart manually — no automatic
# retries are attempted (this is intentional, per plan §3 anti-patterns).

cmd_validate_restart() {
    log "=== Frigate Validation Suite [Tier 2 — restart cycle] ==="
    warn "⚠️  This test will RESTART Frigate. Cameras will briefly lose detection."
    warn "    Total expected time: 1–3 minutes. There are NO automatic retries."
    echo ""

    local pass=0 fail=0

    # ----- V10: Run the restart and verify it completes -----
    log "Running restart (V10/V11)..."
    local restart_start_ts restart_end_ts restart_duration restart_output restart_rc
    restart_start_ts=$(date +%s)
    restart_output=$(cmd_restart 2>&1) || restart_rc=$?
    restart_rc=${restart_rc:-0}
    restart_end_ts=$(date +%s)
    restart_duration=$((restart_end_ts - restart_start_ts))

    if [[ $restart_rc -eq 0 ]] && echo "$restart_output" | grep -q "Restart complete"; then
        ok "  [V10] Restart completes ........... ✅ PASS  (${restart_duration}s; 'Restart complete' in output)"
        pass=$((pass+1))
    else
        warn "  [V10] Restart completes ........... ❌ FAIL  (rc=${restart_rc}; no 'Restart complete' in output)"
        fail=$((fail+1))
        warn "Cannot run V11–V14 if restart itself failed. Aborting Tier 2."
        echo ""
        warn "=== RESULT: ${pass}/5 PASS, ${fail}/5 FAIL — Action required ==="
        return 1
    fi

    # ----- V11: No spurious ZMQ retry -----
    # The current cmd_restart does NOT retry, so this should always pass.
    # It is a guard against accidentally re-introducing the REL-6 anti-pattern
    # (a 3-retry loop that caused a 17-min regression).
    if echo "$restart_output" | grep -qiE "zmq[- ]?stuck|zmq[- ]?retry|retry.*zmq"; then
        warn "  [V11] No spurious ZMQ retry ....... ❌ FAIL  (ZMQ retry was triggered — see anti-pattern §3)"
        fail=$((fail+1))
    else
        ok "  [V11] No spurious ZMQ retry ....... ✅ PASS  (no spurious retry triggered)"
        pass=$((pass+1))
    fi

    # ----- V12: Restart duration < 5 min (300s) -----
    if [[ $restart_duration -lt 300 ]]; then
        ok "  [V12] Restart duration ............ ✅ PASS  (${restart_duration}s < 300s threshold)"
        pass=$((pass+1))
    else
        warn "  [V12] Restart duration ............ ❌ FAIL  (${restart_duration}s ≥ 300s — regression guard)"
        warn "                              The REL-6 17-min regression should never return."
        fail=$((fail+1))
    fi

    # ----- V13 + V14: Wait for cameras to come up -----
    # Poll for up to 120s. DO NOT exit early when cf=0 on all cameras —
    # that would give a false-positive "0 stuck" reading. The full 120s
    # is needed to allow cameras to fully come up after a restart.
    log "Waiting up to 120s for cameras to come up (V13/V14)..."
    local post_working=0 post_stuck=0 post_total=0 detect_ok=0 detect_total=0
    local last_stats=""
    local deadline_ts=$(($(date +%s) + 120))
    while [[ $(date +%s) -lt $deadline_ts ]]; do
        last_stats=$(curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null) || { sleep 5; continue; }
        [[ -z "$last_stats" ]] && { sleep 5; continue; }
        read -r post_working post_stuck post_total detect_ok detect_total <<< "$(_py "$last_stats" <<'PYEOF'
import sys, json
s = json.load(sys.stdin)
SUB = {'allee_sur_le_cote', 'jardin_devant', 'piscine_vue_toit'}
cams = s.get('cameras', {})
working = stuck = total = det_ok = det_total = 0
for n, v in cams.items():
    if n in SUB:
        continue
    total += 1
    cf = v.get('camera_fps') or 0
    pf = v.get('process_fps') or 0
    df = v.get('detection', {}).get('det_fps', 0) or 0
    if cf > 0 and pf > 0:
        working += 1
    elif cf > 0 and pf == 0:
        stuck += 1
    if cf > 0:
        det_total += 1
        if df > 0:
            det_ok += 1
print(working, stuck, total, det_ok, det_total)
PYEOF
)"
        # Show polling progress (every iteration)
        log "  poll t-$((deadline_ts - $(date +%s)))s: working=${post_working}/${post_total} stuck=${post_stuck} detecting=${detect_ok}/${detect_total}"
        # No early-exit: wait the full 120s so cameras have time to come up.
        sleep 5
    done

    # ----- V13: Post-restart ZMQ health -----
    # Require at least some cameras to be working (post_working > 0); otherwise
    # "0 stuck" is a meaningless reading (no cameras are running at all).
    if [[ $post_working -gt 0 && $post_stuck -eq 0 ]]; then
        ok "  [V13] Post-restart ZMQ health ..... ✅ PASS  (0 stuck cameras; ${post_working}/${post_total} processing)"
        pass=$((pass+1))
    elif [[ $post_total -eq 0 ]]; then
        warn "  [V13] Post-restart ZMQ health ..... ❌ FAIL  (no cameras reported in 120s — restart is broken)"
        fail=$((fail+1))
    else
        warn "  [V13] Post-restart ZMQ health ..... ❌ FAIL  (${post_stuck} stuck cameras of ${post_total}; only ${post_working} processing)"
        warn "                              → Fix: ./deploy-frigate.sh restart  (manual; no auto-retry)"
        fail=$((fail+1))
    fi

    # ----- V14: Post-restart detection -----
    if [[ $detect_total -eq 0 ]]; then
        warn "  [V14] Post-restart detection ...... ❌ FAIL  (no active cameras found in 120s — restart is broken)"
        fail=$((fail+1))
    elif [[ $detect_ok -eq $detect_total ]]; then
        ok "  [V14] Post-restart detection ...... ✅ PASS  (${detect_ok}/${detect_total} active cameras have detect_fps>0)"
        pass=$((pass+1))
    else
        warn "  [V14] Post-restart detection ...... ❌ FAIL  (${detect_ok}/${detect_total} active cameras have detect_fps>0)"
        warn "                              → Fix: ./deploy-frigate.sh restart"
        fail=$((fail+1))
    fi

    echo ""
    if [[ $fail -eq 0 ]]; then
        ok "=== RESULT: ${pass}/5 PASS — Restart sequence verified reliable ==="
    else
        warn "=== RESULT: ${pass}/5 PASS, ${fail}/5 FAIL — Action required ==="
        return 1
    fi
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
    diagnose)
        cmd_diagnose
        ;;
    validate)
        cmd_validate "${2:-tier1}"
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
        echo "Usage: $0 [restart|recreate|status|dump|diagnose|validate|auto]"
        echo ""
        echo "  auto      (default) detect whether recreation is needed"
        echo "  restart   config.yml change only — no container recreation"
        echo "  recreate  image/shm_size/devices changed — full stop+rm+up+stop+start"
        echo "  status    show inference speed, det_fps, /dev/shm usage"
        echo "  dump      Option-B event dump for Track A soak analysis"
        echo "  diagnose  read-only 5-layer health snapshot (no state change)"
        echo "  validate  9 read-only Tier 1 tests; 'validate restart' is Tier 2 (destructive — restarts Frigate)"
        exit 1
        ;;
esac
