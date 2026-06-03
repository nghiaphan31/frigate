# Frigate NVR — Startup & Operations

Manual, robust procedure to bring up the Frigate NVR from a host reboot to fully operational state. Designed so **every prerequisite is verified before the next step** — a failed step halts the sequence and tells you exactly what to check.

> For the pipeline itself, see [ARCHITECTURE.md](ARCHITECTURE.md). For automation, see [bring-up.sh](bring-up.sh).

## Table of contents

1. [Overview](#1-overview)
2. [Pre-flight checklist](#2-pre-flight-checklist) — host prerequisites
3. [Manual startup sequence](#3-manual-startup-sequence) — 8 ordered steps
3.5. [Boot automation (systemd)](#35-boot-automation-systemd) — frigate-stack.service + watchdog timer (incl. path-maintenance note)
4. [Health checks](#4-health-checks) — 6 transparent monitoring commands
4.5. [MQTT state subscription](#45-mqtt-state-subscription) — live `calypso_frigate/bringup/#` feed
5. [Failure recovery](#5-failure-recovery) — per failure mode
5.8. [Failure mode catalog](#58-failure-mode-catalog-per-check) — machine-greppable per-step table
6. [Logging locations](#6-logging-locations)

---

## 1. Overview

The startup sequence is **fail-fast, fail-loud**: every command has a clear pass / fail outcome; any failure prints the exact check that failed and stops. The intended audience is an operator at a Calypso host console, but the same commands can be scripted (and are, in [`bring-up.sh`](bring-up.sh)).

**Guarantees** when the sequence completes successfully:

- NVIDIA driver loaded, 5 device nodes present
- NAS at `$FRIGATE_MEDIA_PATH` is mounted and writable
- 3 Reolink Duo 3 cameras at `192.168.50.7:8554`, `192.168.50.18:8554`, `192.168.50.129:8554` are reachable
- Docker daemon is up with `nvidia` runtime registered
- Splitter service is running (6 half-cropped RTSP mounts on `0.0.0.0:8556`)
- Frigate container is running (14 cameras total: 8 original + 6 new half-cropped)
- `/api/version` returns 200 within 60 s
- `allee_sur_le_cote.detection_fps > 0` within 240 s (covers first-run TRT build)
- MQTT broker at `192.168.50.125:1883` is connected
- Recording path is writable

**Failure budget**: zero. If any step fails, the operator is told what to check; the next step is not attempted.

---

## 2. Pre-flight checklist

Run these from the host shell. Each is a hard gate; the startup sequence is **not** safe to attempt if any check fails.

### 2.1 Host kernel & NVIDIA driver

```bash
uname -r                          # expect 6.x
nvidia-smi                        # expect driver version 570+ on RTX 5060 Ti
ls -l /dev/nvidia{0,ctl,modeset,uvm,uvm-tools}
                                  # all 5 must exist
lsmod | grep -E '^nvidia'         # nvidia, nvidia_uvm, nvidia_modeset must be loaded
```

If any device is missing, load the module:
```bash
sudo modprobe nvidia nvidia-uvm nvidia-modeset nvidia-uvm-tools
```

### 2.2 System time sync

```bash
timedatectl status | grep -E '(NTP|System clock)'   # expect "synchronized: yes"
```

If unsynchronized, force a sync:
```bash
sudo systemctl enable --now systemd-timesyncd
sudo timedatectl set-ntp true
```

Frigate timestamps and event lifecycle depend on a sane wall clock.

### 2.3 NAS mount

`FRIGATE_MEDIA_PATH` (from `.env`) does not have to **be** the mount point — it
can be a subdirectory inside one. The pre-flight walks up the path until it
finds a mount point, then verifies the directory exists (auto-creates it if
needed) and is writable.

```bash
cat .env | grep FRIGATE_MEDIA_PATH
df -h "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}" | tail -1
[ -w "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}" ] && echo "WRITABLE" || echo "NOT WRITABLE"
```

If not mounted (after a host reboot, NFS may not auto-mount), re-mount:
```bash
sudo systemctl restart nfs-client.target   # or systemd-mount, depending on setup
# or:
sudo mount -a
```

The script will then auto-create the subfolder if missing (e.g. `frigate_calypso`
inside `/mnt/nas/video`) and refuse to proceed if the resulting directory is
read-only.

### 2.4 Camera reachability

```bash
timeout 3 bash -c ">/dev/tcp/192.168.50.129/8554" \
    && echo "OK" || echo "UNREACHABLE"
```

If unreachable, check the LAN — is the Reolink online, is the switch up, is the firewall allowing outbound TCP to `.129:8554`?

### 2.5 Docker daemon

```bash
systemctl is-active docker
docker info | grep -E 'Server Version|Runtimes'
                                  # expect "nvidia" under Runtimes
```

If `nvidia` is missing, re-register the runtime:
```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 2.6 Frigate+ API key

```bash
grep -E '^FRIGATE_PLUS_API_KEY=' .env   # expect a non-empty value
```

A missing key disables the Frigate+ custom model — the detector falls back to the generic SSD model.

### 2.7 TRT libs (host)

```bash
[ -d trt-libs ] && ls trt-libs/libnvinfer.so* 2>/dev/null \
    | head -1 || echo "MISSING — see install instructions"
```

The `./trt-libs/` directory must contain the **TensorRT 10.9.0** runtime libs (for SM 120 / Blackwell support). To (re)install:
```bash
pip install --target=./trt-libs --no-deps \
    tensorrt-cu12-libs==10.9.0.34 \
    tensorrt-cu12-bindings==10.9.0.34
```

These libs are bind-mounted into the container as `/trt-libs:ro` and registered with the dynamic linker by [`frigate-init.sh`](frigate-init.sh), invoked as the s6-overlay stage-2 hook (`$S6_STAGE2_HOOK`) before the s6-supervised Frigate starts — see [ARCHITECTURE.md §2.3](ARCHITECTURE.md#23-container-init--s6-overlay-v3--stage-2-hook). Earlier compose versions did this in a `command:` block, but that also spawned a duplicate Frigate process (same `client_id` → MQTT takeover loop). The hook pattern fixes both problems.

### 2.8 Disk space

```bash
df -h . | tail -1                # ./trt-cache + .env + config.yml, expect ≥ 1 GB free
df -h "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}" | tail -1
                                  # NAS, expect ≥ 20 GB free for 1-day motion retention
```

### 2.9 Splitter service health (NEW, 2026-06-03)

The 6 new half-cropped cameras (`allee_sur_le_cote_left/_right`,
`jardin_devant_left/_right`, `piscine_vue_toit_left/_right`) consume RTSP
streams from the splitter service on port 8556. The splitter must be up
BEFORE the Frigate container starts (the `go2rtc.streams` entries in
`config.yml` pull from the splitter's RTSP server).

```bash
# 1. The splitter compose file must exist
[ -f splitter/docker-compose.splitter.yml ] \
    && echo "OK" || echo "MISSING — cd splitter && docker build -t frigate-splitter:local ."

# 2. If the splitter container is already running, port 8556 must accept connections
docker ps --format '{{.Names}}' | grep -q '^splitter$' && \
    timeout 2 bash -c ">/dev/tcp/127.0.0.1/8556" \
    && echo "splitter port 8556 OK" || echo "splitter port 8556 NOT REACHABLE"
```

If the splitter image hasn't been built yet, run:

```bash
cd splitter
docker build -t frigate-splitter:local .
cd ..
docker compose -f splitter/docker-compose.splitter.yml up -d splitter
```

The build pulls `nvidia/cuda:12.4.1-runtime-ubuntu22.04` (~1.5 GB compressed)
plus the GStreamer + NVIDIA plugin packages from the `ruffy8919` PPA
(~50 MB). First build: ~90 s. Subsequent builds: ~5 s (cached layers).

The 3 Reolink Duo 3 main streams (4096×1152, 4K) are the splitter's
upstream source. Each camera must be reachable on TCP 8554 from the host:

```bash
for ip in 192.168.50.7 192.168.50.18 192.168.50.129; do
    timeout 3 bash -c ">/dev/tcp/$ip/8554" \
        && echo "$ip:8554 OK" || echo "$ip:8554 UNREACHABLE"
done
```

If any of these are unreachable, the splitter's 2 affected pipelines
(`*_left`, `*_right`) will return 503 on the corresponding RTSP mounts,
and the 2 affected cameras in Frigate will go into "disabled" state.
The other 4 streams keep serving.

---

## 3. Manual startup sequence

After all pre-flight checks pass, execute the 9 steps below in order. **Stop on the first failure.**

The **splitter service** (added 2026-06-03 for the 6 new half-cropped cameras) must be
started **before** the Frigate container so the 6 new streams are ready when go2rtc
pulls. Steps 1 and 2 below cover the splitter; step 3 starts Frigate.

### Step 1 — Build and start the splitter service

```bash
cd /home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/frigate

# One-time: build the splitter image (≈ 90 s, pulls nvidia/cuda + GStreamer
# + the 3 NVIDIA GStreamer plugin packages from the ruffy8919 PPA).
cd splitter
docker build -t frigate-splitter:local .
cd ..

# Start the splitter container (idempotent).
docker compose -f splitter/docker-compose.splitter.yml up -d splitter
```

**Exit criteria**: `docker ps` shows `splitter` in `running` state within 30 s.

If the build fails, the most common cause is the `ruffy8919` PPA being unreachable;
the Dockerfile will print the apt error before exiting. If the container exits
immediately, see [splitter/README.md — Failure modes & troubleshooting](splitter/README.md#failure-modes--troubleshooting).

### Step 2 — Wait for the splitter RTSP port

```bash
for i in $(seq 1 60); do
    timeout 2 bash -c ">/dev/tcp/127.0.0.1/8556" && break
    sleep 1
done
echo "splitter port 8556 ready in ${i}s"
```

**Exit criteria**: TCP connect to `127.0.0.1:8556` succeeds within 60 s.

The container may be up before the gst-rtsp-server has bound the port (it
takes a few seconds for the GLib main loop to start and the rtspsrc plugins
to negotiate the upstream connection). If the port never comes up, see
[§ 5.X](#5x-splitter-rtsp-port-8556-unreachable-new).

Quick smoke test of all 6 mounts once the port is up:

```bash
for m in allee_sur_le_cote_left allee_sur_le_cote_right \
         jardin_devant_left jardin_devant_right \
         piscine_vue_toit_left piscine_vue_toit_right; do
    timeout 3 ffprobe -v error -of json -show_streams \
        "rtsp://127.0.0.1:8556/$m" >/dev/null 2>&1 \
        && echo "OK   $m" || echo "FAIL $m"
done
```

### Step 3 — Create / restart the Frigate container

```bash
cd /home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/frigate

# If container already exists, restart is sufficient (config-only changes).
# If image / devices / shm / volumes changed, recreate.
docker compose -f docker-compose.calypso.yml up -d frigate
```

**Exit criteria**: `docker compose ps` shows `frigate` in `running` state within 30 s.

The compose file does **not** override the image's default `command:`. The image's
`ENTRYPOINT` is `/init` (s6-overlay v3) and its `CMD` is `null`, so by design only
the s6-supervised `frigate` service runs. Init that used to be tacked on at
the end of an old `command:` block now lives in [`frigate-init.sh`](frigate-init.sh)
and runs once as the `$S6_STAGE2_HOOK` before s6-rc brings the services up.
If the container exits immediately, see [§ 5.1](#51-container-exits-immediately-after-up).

If the container exits immediately, see [§ 5.1](#51-container-exits-immediately-after-up).

### Step 4 — Wait for the Frigate API

```bash
for i in $(seq 1 60); do
  curl -fsS http://localhost:5000/api/version >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://localhost:5000/api/version | python3 -m json.tool
```

**Exit criteria**: `/api/version` returns 200 with a `version` field within 60 s.

While waiting, you can `docker logs -f frigate` to see the init progress (go2rtc connecting, model download, TRT engine build).

### Step 5 — Wait for detection to start

```bash
for i in $(seq 1 240); do
  fps=$(curl -fsS http://localhost:5000/api/cameras 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('allee_sur_le_cote',{}).get('detection_fps',0)))")
  [ "${fps:-0}" -ge 1 ] && break
  sleep 1
done
echo "detection_fps=$fps (after ${i}s)"
```

**Exit criteria**: `allee_sur_le_cote.detection_fps >= 1` within 240 s.

The first run can take ~65 s longer than subsequent runs (TRT engine build). Watch `docker logs frigate | grep -E '(TensorRT|engine|TRT)'`.

If you have 11 cameras (the 6 new half-cropped cameras need separate
detection warm-up; on a fresh `trt-cache` Frigate will build the engine
once and the engine is shared across all cameras), consider also
checking a half-cropped camera:

```bash
for i in $(seq 1 240); do
  fps=$(curl -fsS http://localhost:5000/api/cameras 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d.get('allee_sur_le_cote_left',{}).get('detection_fps',0)))")
  [ "${fps:-0}" -ge 1 ] && break
  sleep 1
done
echo "allee_sur_le_cote_left detection_fps=$fps (after ${i}s)"
```

### Step 6 — (only if detection is stuck) stop / start cycle

If `detection_fps` is still 0 after step 5, run a stop / start cycle on
both containers. This clears any stale ZMQ IPC state that `up -d` may
have left behind on a re-create:

```bash
# Restart the splitter first (cheaper, no TRT build)
docker compose -f splitter/docker-compose.splitter.yml restart splitter
sleep 5
# Then the Frigate container
docker compose -f docker-compose.calypso.yml stop  frigate
docker compose -f docker-compose.calypso.yml start frigate
# then re-run step 5
```

**Exit criteria**: `detection_fps >= 1` within 60 s of `start`.

### Step 7 — Verify MQTT connection

```bash
curl -fsS http://localhost:5000/api/stats \
    | python3 -c "import json,sys; d=json.load(sys.stdin)['mqtt']; print(d)"
```

**Exit criteria**: output contains `"connected": true` and the broker `host:port` matches `192.168.50.125:1883`.

If MQTT is disconnected, the most common cause is the Mosquitto broker not being up on the Home Assistant host. See [§ 5.5](#55-mqtt-disconnected).

### Step 8 — Verify camera is producing events on demand

Trigger a person in the `prive` zone (e.g. walk to the gate):

```bash
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto \
              -t 'calypso_frigate/events' -v -W 30
```

You should see at least one `start` and one `end` message in 30 s. If not, see [§ 5.4](#54-no-events-published).

To verify the 6 new half-cropped cameras separately:

```bash
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto \
              -t 'calypso_frigate/events' -v -W 30 \
              | grep -E 'allee_sur_le_cote_left|allee_sur_le_cote_right'
```

### Step 9 — Verify recording is being written

```bash
ls -lt "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"/recordings/allee_sur_le_cote/ 2>/dev/null | head -3
ls -lt "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"/recordings/allee_sur_le_cote_left/ 2>/dev/null | head -3
```

**Exit criteria**: a directory and recent file exist for BOTH the original
camera and the half-cropped one. The exact retention depends on the
`record.motion.days: 1` setting in [config.yml](config.yml).

### Step 10 — Final status report

Either run [`bring-up.sh`](bring-up.sh) (it is idempotent — skips container creation if already up, runs the 14-step status report) or use the abbreviated check:

```bash
docker compose -f docker-compose.calypso.yml ps
curl -fsS http://localhost:5000/api/stats | python3 -m json.tool | head -30
curl -fsS http://localhost:5000/api/cameras | python3 -m json.tool
```

---

---

## 3.5 Boot automation (systemd)

Two systemd units wrap [`bring-up.sh`](bring-up.sh) so the system comes up automatically on host reboot and stays up indefinitely.

### Files

| File | Role |
|---|---|
| [`frigate-stack.service`](frigate-stack.service) | oneshot, runs `bring-up.sh` once on boot |
| [`frigate-stack-watchdog.service`](frigate-stack-watchdog.service) | oneshot, runs `bring-up.sh` (idempotent) on each timer tick |
| [`frigate-stack-watchdog.timer`](frigate-stack-watchdog.timer) | triggers the watchdog every 5 min (after the previous run completes) |

### Install (one-time, on the host)

**Recommended** — run the install script. It copies the units, reloads systemd,
enables them, starts the stack now, and tails the journal:

```bash
./install-systemd.sh
```

Equivalent manual steps (kept here for reference / when the script is not
appropriate, e.g. in a container or read-only environment):

```bash
# 1. Copy the units to /etc/systemd/system
sudo cp frigate-stack.service              /etc/systemd/system/
sudo cp frigate-stack-watchdog.service     /etc/systemd/system/
sudo cp frigate-stack-watchdog.timer       /etc/systemd/system/

# 2. Reload systemd and enable both
sudo systemctl daemon-reload
sudo systemctl enable frigate-stack.service
sudo systemctl enable --now frigate-stack-watchdog.timer

# 3. Start the stack now without rebooting
sudo systemctl start frigate-stack.service
```

To uninstall later:

```bash
./install-systemd.sh --uninstall
```

### Inspect

```bash
# Last bring-up result
systemctl status frigate-stack.service
journalctl -u frigate-stack.service -n 50 --no-pager

# Watchdog schedule + last runs
systemctl list-timers frigate-stack-watchdog.timer
journalctl -u frigate-stack-watchdog.service -n 50 --no-pager

# Live follow during a bring-up
journalctl -u frigate-stack.service -f
```

### Path maintenance

The systemd units in this repo hard-code the absolute path to
the repo. If the repo is ever moved (renamed parent directory,
checked out under a different path, etc.), the units installed
at `/etc/systemd/system/` will silently fail with
`status=203/EXEC` ("could not exec") and the journal will be
dominated by that one repeating error every 5 min — the bring-up
script itself never runs.

**Symptom check**:
```bash
journalctl -u frigate-stack-watchdog.service -n 20 --no-pager
# if every line ends in "code=exited, status=203/EXEC", the path drifted
```

**Fix** (pick one):
```bash
# Cleanest — reinstall the units from the new location
./install-systemd.sh

# Surgical — just refresh the watchdog unit
sudo cp -v frigate-stack-watchdog.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl reset-failed frigate-stack-watchdog.service
sudo systemctl start frigate-stack-watchdog.service
```

The repo-side unit files have a `NOTE:` comment in `[Service]`
reminding future maintainers of the same constraint. The
canonical path is
`/home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/frigate`.

### Why the dual-unit design

| Concern | Handled by |
|---|---|
| Host reboot must bring the system up | `frigate-stack.service` (oneshot, `RemainAfterExit=yes`) |
| Container may die hours after boot | `frigate-stack-watchdog.timer` triggers re-run every 5 min |
| Bring-up may take up to 4 min (TRT build) | `TimeoutStartSec=420` on both units |
| A long bring-up must not pile up with the timer | `OnUnitActiveSec` in the timer avoids overlap |
| The system is unreachable at boot (camera/NAS down) | `SuccessExitStatus=0 1` lets the service "succeed" with WARN, the watchdog retries 5 min later |
| The system is unrecoverable | exit codes 2/3/4/5 mark the service failed → visible in `systemctl status` and via MQTT `FATAL_*` events |
| Override the default auto-recovery strategy | set `RECOVER_STRATEGY=remount-nas\|flush-zmq\|rebuild-trt` in the watchdog's `EnvironmentFile` (default: `restart-container`; see [§ 5.8](#58-failure-mode-catalog-per-check) for when to use which) |

### Uninstall

```bash
sudo systemctl disable --now frigate-stack.service
sudo systemctl disable --now frigate-stack-watchdog.timer
sudo rm /etc/systemd/system/frigate-stack{,-watchdog.service,-watchdog.timer}
sudo systemctl daemon-reload
```

---

## 4. Health checks

These six commands give a complete picture of steady-state operation. Run them in any order; the responses are non-mutating.

| # | What to check | Command |
|---|---|---|
| 1 | Container up | `docker compose -f docker-compose.calypso.yml ps` |
| 2 | API responsive | `curl -fsS http://localhost:5000/api/version` |
| 3 | Per-camera fps | `curl -fsS http://localhost:5000/api/cameras \| jq '.allee_sur_le_cote'` |
| 4 | Detector inference speed | `curl -fsS http://localhost:5000/api/stats \| jq '.detectors.onnx1'` |
| 5 | MQTT connected | `curl -fsS http://localhost:5000/api/stats \| jq '.mqtt'` |
| 6 | Last 5 events | `curl -fsS 'http://localhost:5000/api/events?limit=5'` |
| 7 | **One-shot JSON snapshot** (for archival / drift detection) | `./bring-up.sh --no-mqtt --snapshot-write=/var/lib/frigate/baseline.json` |
| 8 | **Diff against baseline** (exit 1 on drift, 0 on match) | `./bring-up.sh --no-mqtt --snapshot-compare=/var/lib/frigate/baseline.json` |
| 9 | **Targeted recovery** (e.g. NAS remount, TRT rebuild) | `./bring-up.sh --recover=remount-nas` (or `restart-container` / `flush-zmq` / `rebuild-trt`; see [§ 5.8](#58-failure-mode-catalog-per-check)) |

**Healthy-state signature**:

| Check | Healthy value |
|---|---|
| Container | `running`, `Up X minutes` |
| API | `{"version": "0.17.0", ...}` |
| Camera fps | `detection_fps ≥ 1`, `camera_fps ≥ 5` |
| Detector | `inference_speed ≤ 20 ms` (TRT) |
| MQTT | `connected: true`, `host: "192.168.50.125:1883"` |
| Events | non-empty list when activity present |

For a per-pipeline-step breakdown, run [`bring-up.sh`](bring-up.sh) (idempotent — see its tail-end 14-step report).

### 4.5 MQTT state subscription

If MQTT telemetry is enabled (default), every state transition is published to `calypso_frigate/bringup/state` (retained) and `calypso_frigate/bringup/detail` (retained JSON). Subscribe from any host with `mosquitto_sub` (already required for the Mosquitto broker):

```bash
# Tail every bring-up transition in real time
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto \
              -t 'calypso_frigate/bringup/#' -v
```

The retained `state` topic always reflects the **last completed transition**, so a fresh subscriber immediately sees the current state without waiting for the next one. Use this for HA dashboards, mobile notifications on `FATAL_*` or `RECOVERY_*`, or simple bash checks:

```bash
# Is the system healthy right now?
[ "$(mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto \
   -t 'calypso_frigate/bringup/state' -C 1 -W 2)" = "HEALTHY" ] && echo OK || echo NOT_OK
```

The full state schema and HA integration snippets are in [ARCHITECTURE.md §7](ARCHITECTURE.md#7-operations-state-machine-and-mqtt-telemetry). The state list is: `STARTING`, `PREFLIGHT_OK`, `CONTAINER_UP`, `API_UP`, `DETECTION_ACTIVE`, `RECOVERY_TRIGGERED`, `RECOVERY_INVOKED` (manual `--recover=` operator action), `RECOVERY_SUCCESS`, `RECOVERY_FAILED`, `HEALTHY` / `DEGRADED` / `UNHEALTHY`, `FATAL_*`.


---

## 5. Failure recovery

Each failure mode has one explicit recovery procedure. **Always re-run [`bring-up.sh`](bring-up.sh) after a recovery** to confirm all 14 pipeline steps report OK.

### 5.1 Container exits immediately after `up`

**Symptoms**: `docker compose ps` shows `Exit 1` (or other non-zero) within seconds of `up -d`.

**Diagnose**:
```bash
docker logs --tail=50 frigate
```

**Common causes**:
- `config.yml` syntax error → run `python3 -c 'import yaml; yaml.safe_load(open("config.yml"))'`
- Missing volume → check `mountpoint -q $FRIGATE_MEDIA_PATH`
- NVIDIA device gone → re-run pre-flight § 2.1

### 5.2 `detection_fps == 0` after step 3

**Symptoms**: API responds, container is up, but `allee_sur_le_cote.detection_fps` stays 0.

**Diagnose**:
```bash
docker logs --tail=100 frigate | grep -E '(TRT|engine|motion|detect|cuda|error)'
```

**Common causes** (in order of likelihood):
1. **TRT engine build in progress** (first run only) — wait another 60 s.
2. **TRT build failed** (kernel not supported, OOM) — check logs; if so, set `device: "CPU"` in [config.yml](config.yml) as fallback and restart.
3. **Stale ZMQ IPC** — run the stop / start cycle (step 4).
4. **No motion** — the scene is quiet; throw a sheet in front of the camera to test.
5. **Camera unreachable** — `timeout 3 bash -c ">/dev/tcp/192.168.50.129/8554"`.

### 5.3 TRT engine cache corrupt

**Symptoms**: persistent `engine build failed` or `TRT kernel not supported` in logs.

**Recovery**:
```bash
# 1. stop the container
docker compose -f docker-compose.calypso.yml stop frigate

# 2. remove the engine cache (keeps the plus:// model and the Jina embeddings)
rm -rf trt-cache/tensorrt/ort/trt-engines/*

# 3. start the container — engine will be rebuilt (~65 s on RTX 5060 Ti)
docker compose -f docker-compose.calypso.yml start frigate

# 4. re-run bring-up.sh to verify
./bring-up.sh
```

### 5.4 No events published

**Symptoms**: motion is visible in the UI, `detection_fps > 0`, but no `calypso_frigate/events` MQTT messages.

**Diagnose**:
```bash
# Subscribe to all topics, watch for 60 s
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto \
              -t 'calypso_frigate/#' -v -W 60
```

**Common causes**:
- Person not in `prive` or `rodage` zone → check [config.yml](config.yml) `review:` block; the person must be in the zone for an event.
- Detection score below `threshold: 0.55` → lower the threshold in [config.yml](config.yml) for testing.
- MQTT broker auth rejected → verify `mqtt.user: mosquitto` / `mqtt.password: mosquitto` matches the broker.

### 5.5 MQTT disconnected

**Symptoms**: `curl -fsS http://localhost:5000/api/stats | jq '.mqtt'` shows `"connected": false`.

**Diagnose**:
```bash
# Reachability
timeout 3 bash -c ">/dev/tcp/192.168.50.125/1883" && echo OK

# Auth (if mosquitto_sub is available)
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto \
              -t '$SYS/broker/version' -W 5 -v
```

**Common causes**:
- Mosquitto down on the Home Assistant host → restart it there.
- Auth changed on the broker → update `mqtt.user` / `mqtt.password` in [config.yml](config.yml) and restart.
- Network partition → check switch / VLAN.
- **Historical** (now resolved): the compose file used to override
  `command:` with `exec python3 -u -m frigate`, which spawned a
  second Frigate process that shared the same `client_id` with
  the s6-supervised one. They kicked each other off the broker
  every ~1 s ("session taken over" — 174 disconnects in the last
  200 log lines at peak). The fix is in
  [ARCHITECTURE.md §2.3](ARCHITECTURE.md#23-container-init--s6-overlay-v3--stage-2-hook)
  (init moved to `S6_STAGE2_HOOK`, `command:` removed). If you
  still see per-second disconnects after that fix is in place,
  the cause is a different client_id collision (look for
  `session taken over` in the broker log, not the Frigate log).

> The script's `11/14 MQTT publisher` step now prints the exact
> probe command under the WARN line (`fix: mosquitto_sub -h
> $MQTT_HOST -p $MQTT_PORT -u mosquitto -P mosquitto -t
> '$SYS/broker/version' -W 5`). No need to memorise it — read the
> live report. The full per-step catalog is in
> [§ 5.8](#58-failure-mode-catalog-per-check).

**Recovery** (no Frigate restart needed — the client auto-reconnects):
```bash
# wait 30 s; re-check
sleep 30
curl -fsS http://localhost:5000/api/stats | jq '.mqtt.connected'
```

If still disconnected after the network is fixed, restart Frigate to reset the MQTT client.

### 5.6 GPU out-of-memory

**Symptoms**: `nvidia-smi` shows 16 GB fully used, or `docker logs` shows `CUDA out of memory`.

**Diagnose**:
```bash
nvidia-smi | head -15
docker logs --tail=50 frigate | grep -iE '(cuda|memory|oom)'
```

**Recovery**:
1. If a one-shot — Frigate will recover; check `detection_fps` returns to 5.
2. If persistent — another process is hogging the GPU:
   ```bash
   sudo fuser -v /dev/nvidia* /dev/nvidia-uvm
   ```
   Kill the offending process or reboot.

### 5.7 NAS unmounted

**Symptoms**: recordings stop, `ls $FRIGATE_MEDIA_PATH` fails.

**Recovery**:
```bash
mountpoint -q "$FRIGATE_MEDIA_PATH" && echo OK || {
  sudo mount -a
  docker compose -f docker-compose.calypso.yml restart frigate
}
```

Detection continues during the NAS outage (Frigate buffers in memory briefly, then drops new segments with a `failed to write segment` log line).

### 5.9 Splitter service down (NEW, 2026-06-03)

**Symptoms**:
- 6 new half-cropped cameras (`allee_sur_le_cote_left/_right`,
  `jardin_devant_left/_right`, `piscine_vue_toit_left/_right`) appear in
  the Frigate UI as `disabled` or `not connected`.
- The 3 original panoramic cameras + the 2 single-lens Reolink cameras
  + the 3 indoor Tapo cameras all keep working (they don't depend on
  the splitter).
- TCP probe of `127.0.0.1:8556` fails.

**Diagnose**:
```bash
docker ps --format '{{.Names}}' | grep '^splitter$' || echo "splitter not running"
timeout 2 bash -c ">/dev/tcp/127.0.0.1/8556" || echo "splitter port 8556 not listening"
docker logs --tail=50 splitter | grep -iE 'error|warning|failed|gst'
```

**Recovery** (in order of cost):
1. **Restart the splitter** (clears transient GStreamer errors):
   ```bash
   docker compose -f splitter/docker-compose.splitter.yml restart splitter
   sleep 10
   timeout 2 bash -c ">/dev/tcp/127.0.0.1/8556" && echo "splitter back" || echo "still down"
   ```
2. **Recreate from scratch** (the watchdog will do this on its next 5-min
   tick if you don't want to act now):
   ```bash
   docker compose -f splitter/docker-compose.splitter.yml down
   docker compose -f splitter/docker-compose.splitter.yml up -d
   ```
3. **Rebuild the image** (if the container exits immediately on every
   restart; the issue is probably a missing NVIDIA plugin package):
   ```bash
   docker compose -f splitter/docker-compose.splitter.yml down
   cd splitter
   docker build --no-cache -t frigate-splitter:local . 2>&1 | tee /tmp/splitter-build.log
   cd ..
   docker compose -f splitter/docker-compose.splitter.yml up -d
   ```
   The build log will show the failing apt / pip step. The most common
   culprit is the `ruffy8919` PPA being unreachable.

**If you want to bring Frigate up WITHOUT the splitter** (the 6 new
cameras will stay in 'disabled' state, the rest of the stack works):
```bash
SPLITTER_REQUIRED=0 ./bring-up.sh
```

### 5.8 Failure mode catalog (per check)

This table is the machine-greppable counterpart to the inline `fix:` hints
in the [`bring-up.sh`](bring-up.sh) report. **Same strings, same
recommendations** — the inline hint shows on the live report, this
section is the in-depth view. Use it for documentation, for cross-references
in your runbook, and as the source of truth for what to expect when
`./bring-up.sh --recover=STRATEGY` is the right action.

The 8 pre-flight gates (run first, before any container interaction)
are listed first; the 14 status-report checks follow.

| Check | Likely causes | First action | Recovery strategy |
|---|---|---|---|
| **Pre-flight 1/8** `nvidia-smi OK` | Driver not loaded; module not modprobed | `sudo modprobe nvidia nvidia-uvm nvidia-modeset nvidia-uvm-tools` | — |
| **Pre-flight 2/8** `/dev/nvidia*` present | Modules loaded but devices missing | `ls -l /dev/nvidia*` (re-modprobe) | — |
| **Pre-flight 3/8** `$MEDIA_PATH` mounted | NFS dropped; fstab not loaded; auto-mount not enabled | `mountpoint -q "$MEDIA_PATH" && echo OK`; if not: `sudo mount -a` | (if NFS) `--recover=remount-nas` |
| **Pre-flight 4/8** Camera reachable | Switch down; Reolink offline; firewall block | `timeout 3 bash -c '>/dev/tcp/192.168.50.129/8554'` | — |
| **Pre-flight 5/8** Docker daemon | `dockerd` stopped; socket missing | `systemctl status docker` | — |
| **Pre-flight 6/8** nvidia runtime | Runtime not registered with Docker | `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker` | — |
| **Pre-flight 7/8** `$COMPOSE_FILE` present | Wrong cwd; file deleted | `ls -la docker-compose.calypso.yml` | — |
| **Pre-flight 8/8** `trt-libs/libnvinfer.so.10` | TRT 10.9.0 not installed; wrong pip target | `pip install --target=./trt-libs --no-deps tensorrt-cu12-libs==10.9.0.34 tensorrt-cu12-bindings==10.9.0.34` | — |
| **Pre-flight 9/9** `splitter compose + port 8556` (NEW) | Splitter image not built; container not started; upstream camera unreachable; NVIDIA GStreamer plugin missing | `docker compose -f splitter/docker-compose.splitter.yml ps`; `timeout 2 bash -c '>/dev/tcp/127.0.0.1/8556'` | (next watchdog tick rebuilds) |
| **1/14** `NVIDIA GPU` | nvidia-smi returns no data (driver loaded but no GPU) | `sudo modprobe nvidia nvidia-uvm nvidia-modeset nvidia-uvm-tools` | — |
| **2/14** `Camera RTSP reachability` | Camera offline; switch down; VLAN misconfig | `timeout 3 bash -c '>/dev/tcp/192.168.50.129/8554'` (LAN / camera / firewall) | — |
| **3/14** `go2rtc internal` | go2rtc process dead; port 8554 not bound | `docker logs --tail=100 frigate \| grep -E 'go2rtc\|listen'` | `--recover=restart-container` |
| **3b/14** `splitter RTSP port 8556` (NEW) | Splitter container down; NVIDIA plugin missing; ruffy8919 PPA unreachable | `docker logs --tail=50 splitter` | (next watchdog tick rebuilds) |
| **4/14** `Capture ffmpeg` | camera entry not in `/api/stats.cameras`; ffmpeg process died | `docker logs --tail=100 frigate \| grep -E 'capture\|ffmpeg\|allee_sur_le_cote'` | `--recover=restart-container` |
| **5/14** `Detect process` | `detection_fps=0` despite camera_fps>0. Either (a) TRT engine build failed, (b) ZMQ deadlock, (c) scene is quiet (throw a sheet at the camera to test) | `docker logs --tail=100 frigate \| grep -E 'TRT\|engine\|motion'` | `--recover=flush-zmq` (ZMQ) or `--recover=rebuild-trt` (engine) |
| **6/14** `Motion pre-filter` | Config check only; should not FAIL | inspect `motion.threshold` and `motion.contour_area` in config.yml | — |
| **7/14** `Object detection (TRT)` | `inference_speed=?` (TRT still building) | `docker logs --tail=50 frigate \| grep -E 'TRT\|tensorrt'` (first-run build is ~65s) | `--recover=rebuild-trt` |
| **8/14** `Person filter (physics)` | Config check only; FAIL means `filters.person` block is missing | `see config.yml cameras.allee_sur_le_cote.objects.filters.person` | — |
| **9/14** `Zone filters` | No zones configured for the camera | add zones under `cameras.<name>.zones` in config.yml | — |
| **10/14** `Event lifecycle` | `/api/events` could not be queried (Frigate still starting, or DB locked) | `curl -fsS 'http://localhost:5000/api/events?limit=5'` | — |
| **11/14** `MQTT publisher` | `frigate.comms.mqtt ERROR: MQTT disconnected` in container log. Causes: client_id collision, broker ACL, broker unreachable | `mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquitto -P mosquitto -t '$SYS/broker/version' -W 5` (verify broker); check `client_id: frigate_calypso` is unique | — |
| **12/14** `Recording path` | `$MEDIA_PATH` not mounted or not writable | `mountpoint -q "$MEDIA_PATH"` (if not: `sudo mount -a`) | `--recover=remount-nas` |
| **13/14** `Semantic search` | jina-clip model not loaded yet (lazy on first event) | `docker logs --tail=50 frigate \| grep -E 'semantic\|embedding\|jina'` | — |
| **14/14** `Web UI / API` | `/api/version` returns empty `version` field (Frigate 0.17 known cosmetic bug) | `curl -v http://localhost:5000/api/version` | — |

#### Self-healing strategies (cross-reference)

| Strategy | When to use | Command |
|---|---|---|
| `restart-container` | First try for any transient failure (generic 'try restarting') | `./bring-up.sh --recover=restart-container` |
| `remount-nas` | NFS dropped; step 12/14 (Recording path) FAILs with 'not mounted' | `./bring-up.sh --recover=remount-nas` |
| `flush-zmq` | Step 5/14 (Detect process) FAILs with TRT logs but no build error (ZMQ deadlock) | `./bring-up.sh --recover=flush-zmq` |
| `rebuild-trt` | Step 7/14 (Object detection) reports engine build failures; TRT detector wedged | `./bring-up.sh --recover=rebuild-trt` |

---

## 6. Logging locations

| Source | Where | Notes |
|---|---|---|
| Frigate stdout/stderr | `docker logs frigate` | `FRIGATE_LOG_LEVEL: warning` (env in compose) raises default to WARN; set `info` or `debug` in compose to see more |
| Frigate process logs | `/media/frigate/frigate.log` (on NAS) | ring buffer, retained for 7 days |
| go2rtc logs | in Frigate stdout (prefixed `go2rtc:`) | — |
| ffmpeg logs | in Frigate stdout (prefixed `ffmpeg.<camera>.detect:`) | `log_level: info` per-camera in [config.yml](config.yml) for verbosity |
| Docker daemon | `journalctl -u docker` | only relevant if container fails to start |
| NVIDIA driver | `journalctl -k \| grep -i nvidia` | only if pre-flight § 2.1 fails |
| NAS mount | `journalctl -u '*mount*'` or `dmesg \| tail` | only if pre-flight § 2.3 fails |

**Recommended tail for a quick health glance**:
```bash
docker logs --tail=20 --since=5m frigate
```
