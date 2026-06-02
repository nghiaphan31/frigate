# Frigate NVR — Startup & Operations

Manual, robust procedure to bring up the Frigate NVR from a host reboot to fully operational state. Designed so **every prerequisite is verified before the next step** — a failed step halts the sequence and tells you exactly what to check.

> For the pipeline itself, see [ARCHITECTURE.md](ARCHITECTURE.md). For automation, see [bring-up.sh](bring-up.sh).

## Table of contents

1. [Overview](#1-overview)
2. [Pre-flight checklist](#2-pre-flight-checklist) — host prerequisites
3. [Manual startup sequence](#3-manual-startup-sequence) — 8 ordered steps
4. [Health checks](#4-health-checks) — 6 transparent monitoring commands
5. [Failure recovery](#5-failure-recovery) — per failure mode
6. [Logging locations](#6-logging-locations)

---

## 1. Overview

The startup sequence is **fail-fast, fail-loud**: every command has a clear pass / fail outcome; any failure prints the exact check that failed and stops. The intended audience is an operator at a Calypso host console, but the same commands can be scripted (and are, in [`bring-up.sh`](bring-up.sh)).

**Guarantees** when the sequence completes successfully:

- NVIDIA driver loaded, 5 device nodes present
- NAS at `$FRIGATE_MEDIA_PATH` is mounted and writable
- Reolink camera at `192.168.50.129:8554` is reachable
- Docker daemon is up with `nvidia` runtime registered
- Frigate container is running
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

```bash
cat .env | grep FRIGATE_MEDIA_PATH
mountpoint -q "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}" \
    && echo OK || echo "NOT MOUNTED"
df -h "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}" | tail -1
```

If not mounted (after a host reboot, NFS may not auto-mount), re-mount:
```bash
sudo systemctl restart nfs-client.target   # or systemd-mount, depending on setup
# or:
sudo mount -a
```

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

### 2.8 Disk space

```bash
df -h . | tail -1                # ./trt-cache + .env + config.yml, expect ≥ 1 GB free
df -h "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}" | tail -1
                                  # NAS, expect ≥ 20 GB free for 1-day motion retention
```

---

## 3. Manual startup sequence

After all pre-flight checks pass, execute the 8 steps below in order. **Stop on the first failure.**

### Step 1 — Create / restart the container

```bash
cd /home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/frigate

# If container already exists, restart is sufficient (config-only changes).
# If image / devices / shm / volumes changed, recreate.
docker compose -f docker-compose.calypso.yml up -d frigate
```

**Exit criteria**: `docker compose ps` shows `frigate` in `running` state within 30 s.

If the container exits immediately, see [§ 5.1](#51-container-exits-immediately-after-up).

### Step 2 — Wait for the Frigate API

```bash
for i in $(seq 1 60); do
  curl -fsS http://localhost:5000/api/version >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://localhost:5000/api/version | python3 -m json.tool
```

**Exit criteria**: `/api/version` returns 200 with a `version` field within 60 s.

While waiting, you can `docker logs -f frigate` to see the init progress (go2rtc connecting, model download, TRT engine build).

### Step 3 — Wait for detection to start

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

### Step 4 — (only if detection is stuck) stop / start cycle

If `detection_fps` is still 0 after step 3, run a stop / start cycle. This clears any stale ZMQ IPC state that `up -d` may have left behind on a re-create:

```bash
docker compose -f docker-compose.calypso.yml stop  frigate
docker compose -f docker-compose.calypso.yml start frigate
# then re-run step 3
```

**Exit criteria**: `detection_fps >= 1` within 60 s of `start`.

### Step 5 — Verify MQTT connection

```bash
curl -fsS http://localhost:5000/api/stats \
    | python3 -c "import json,sys; d=json.load(sys.stdin)['mqtt']; print(d)"
```

**Exit criteria**: output contains `"connected": true` and the broker `host:port` matches `192.168.50.125:1883`.

If MQTT is disconnected, the most common cause is the Mosquitto broker not being up on the Home Assistant host. See [§ 5.5](#55-mqtt-disconnected).

### Step 6 — Verify camera is producing events on demand

Trigger a person in the `prive` zone (e.g. walk to the gate):

```bash
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquito -P mosquito \
              -t 'calypso_frigate/events' -v -W 30
```

You should see at least one `start` and one `end` message in 30 s. If not, see [§ 5.4](#54-no-events-published).

### Step 7 — Verify recording is being written

```bash
ls -lt "${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"/recordings/allee_sur_le_cote/ 2>/dev/null | head -3
```

**Exit criteria**: a directory and recent file exist. The exact retention depends on the `record.motion.days: 1` setting in [config.yml](config.yml).

### Step 8 — Final status report

Either run [`bring-up.sh`](bring-up.sh) (it is idempotent — skips container creation if already up, runs the 14-step status report) or use the abbreviated check:

```bash
docker compose -f docker-compose.calypso.yml ps
curl -fsS http://localhost:5000/api/stats | python3 -m json.tool | head -30
curl -fsS http://localhost:5000/api/cameras | python3 -m json.tool
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
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquito -P mosquito \
              -t 'calypso_frigate/#' -v -W 60
```

**Common causes**:
- Person not in `prive` or `rodage` zone → check [config.yml](config.yml) `review:` block; the person must be in the zone for an event.
- Detection score below `threshold: 0.55` → lower the threshold in [config.yml](config.yml) for testing.
- MQTT broker auth rejected → verify `mqtt.user: mosquito` / `mqtt.password: mosquito` matches the broker.

### 5.5 MQTT disconnected

**Symptoms**: `curl -fsS http://localhost:5000/api/stats | jq '.mqtt'` shows `"connected": false`.

**Diagnose**:
```bash
# Reachability
timeout 3 bash -c ">/dev/tcp/192.168.50.125/1883" && echo OK

# Auth (if mosquitto_sub is available)
mosquitto_sub -h 192.168.50.125 -p 1883 -u mosquito -P mosquito \
              -t '$SYS/broker/version' -W 5 -v
```

**Common causes**:
- Mosquitto down on the Home Assistant host → restart it there.
- Auth changed on the broker → update `mqtt.user` / `mqtt.password` in [config.yml](config.yml) and restart.
- Network partition → check switch / VLAN.

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
