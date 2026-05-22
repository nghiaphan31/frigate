# Detection Parameter Optimisation Plan — Frigate NVR (Calypso RTX 5060 Ti)

> **Status:** 🟢 Deployed — 48–72h soak running (Track A + Track B active)
> **Branch:** `detection-optimisation`
> **Last updated:** 2026-05-22
> **Config file:** [`config.yml`](../config.yml)
> **Docker compose:** [`docker-compose.calypso.yml`](../docker-compose.calypso.yml)
> **Deploy script:** [`deploy-frigate.sh`](../deploy-frigate.sh)

---

## Architecture Decision: Main Stream for Detection

### GPU capacity verdict

The RTX 5060 Ti 16 GB with ONNX Runtime + TensorRT can comfortably handle **10–15 concurrent 1080p inference streams** at 10 fps. 11 camera streams are well within budget.

### Stream resolution map (confirmed)

| Physical camera | Main stream | Sub stream | Main half-crop (go2rtc) |
|---|---|---|---|
| Reolink Duo 3 × 3 | **4096×1152** | 1536×432 | **2048×1152** (left/right) |
| Reolink single-lens (jardin_arriere) | **3840×2160** ✅ | 640×360 | — |
| Reolink Doorbell POE (vue_entree) | **2560×1920** ✅ | 640×480 | — |

> **Rule:** Never use the full 4096×1152 panoramic for detection — the 3.5:1 aspect ratio is incompatible with mobilenet/SSD model inputs. Always use the 2048×1152 half-crops produced by the NUC go2rtc.

### Final stream configuration (post iter1)

| Camera | Detect stream | Resolution | fps | Status |
|---|---|---|---|---|
| `allee_sur_le_cote` | sub (unchanged) | 1536×432 | 5 | ✅ unchanged |
| `allee_sur_le_cote_left` | main_left | 2048×1152 | 10 | ✅ migrated |
| `allee_sur_le_cote_right` | main_right | 2048×1152 | 10 | ✅ migrated |
| `jardin_arriere` | main | 3840×2160 | 5 | ✅ migrated |
| `vue_entree` | main | 2560×1920 | 10 | ✅ migrated |
| `jardin_devant` | sub (unchanged) | 1536×432 | 10 | ✅ unchanged |
| `jardin_devant_left` | main_left (unchanged) | 2048×1152 | 10 | ✅ unchanged |
| `jardin_devant_right` | main_right (unchanged) | 2048×1152 | 10 | ✅ unchanged |
| `piscine_vue_toit` | sub (unchanged) | 1536×432 | 10 | ✅ unchanged |
| `piscine_vue_toit_left` | main_left | 2048×1152 | 10 | ✅ migrated |
| `piscine_vue_toit_right` | main_right | 2048×1152 | 10 | ✅ migrated |

---

## Iteration 0 — Immediate Fixes Applied ✅

| Camera | Parameter | Old | New | Reason |
|---|---|---|---|---|
| `allee_sur_le_cote` | `max_area` | 12,000 | 40,000 | 1536×432: close person ≈ 80×200 = 16,000 px² |
| `jardin_devant_left` | `max_area` | 52,000 | 300,000 | 2048×1152: close person ≈ 200×600 = 120,000 px² |
| `jardin_devant_right` | `max_area` | 52,000 | 300,000 | Same |
| `piscine_vue_toit_right` | `min_area` | 10,000 | 500 TEMP | 768×432: distant person ≈ 50×120 = 6,000 px² |

---

## Iteration 1 — Stream Migration Applied ✅

6 cameras migrated from sub-stream to main-stream with **wide-open temporary parameters**:

```yaml
# TEMP iter1: wide-open for 48-72h data collection
min_area: 500        # catch everything
max_area: 2000000    # catch everything
min_ratio: 0.05      # catch everything
max_ratio: 20.0      # catch everything
threshold: 0.50      # wide-open (lowered from 0.55-0.60 in cbbbb6b)
min_score: 0.45
```

These wide-open params serve **two parallel goals simultaneously** (see Dual-Track Soak below).

---

## Dual-Track 48–72h Soak

After deploying the iter1 config, run Frigate for 48–72 hours. During this period, **two tracks run in parallel**:

```
Deploy iter1 config → docker compose restart frigate
         │
         ▼
    ┌─────────────────────────────────────────────────────────┐
    │                   48–72h SOAK                           │
    │                                                         │
    │  TRACK A — Parameter Tuning                             │
    │  ─────────────────────────                              │
    │  Frigate accumulates person events on new main streams  │
    │  Each event records: area, ratio, score, bbox           │
    │  → After soak: run Option-B API dump                    │
    │  → Paste output here → I compute tight iter2 params     │
    │                                                         │
    │  TRACK B — Frigate+ Model Training                      │
    │  ──────────────────────────────                         │
    │  Wide-open params generate maximum snapshots            │
    │  → Review snapshots in Frigate UI Events tab            │
    │  → Submit true positives + labelled negatives to        │
    │    Frigate+ for model retraining                        │
    │  → Wait for trained plus:// model to be ready           │
    └─────────────────────────────────────────────────────────┘
         │
         ▼
    Apply iter2 tight parameters (from Track A)
    + deploy new plus:// model (from Track B)
    → single docker compose restart
```

### Track A — Option-B API Event Dump

Run after 48–72h and paste output here:

```bash
for cam in allee_sur_le_cote allee_sur_le_cote_left allee_sur_le_cote_right \
           jardin_arriere vue_entree jardin_devant \
           jardin_devant_left jardin_devant_right \
           piscine_vue_toit piscine_vue_toit_left piscine_vue_toit_right; do
  echo "=== $cam ==="
  curl -s "http://192.168.50.150:5000/api/events?camera=${cam}&label=person&limit=100" \
    | python3 -c "
import sys, json
events = json.load(sys.stdin)
for e in events:
    print(f\"  score={e.get('score',0):.2f}  area={e.get('area',0):8.0f}  ratio={e.get('ratio',0):.3f}\")
print(f'  TOTAL: {len(events)} events')
"
done
```

From this output, tight parameters are derived using:
```
min_area  = floor(min_observed_area  × 0.70)
max_area  = ceil(max_observed_area   × 1.50)
min_ratio = floor2dp(min_observed_ratio × 0.80)
max_ratio = ceil2dp(max_observed_ratio  × 1.30)
```

### Track B — Frigate+ Snapshot Labelling

**How to access snapshots for labelling:**
1. Open `http://192.168.50.150:5000` → **Events** tab
2. Filter by camera, review each event
3. Click **"Submit to Frigate+"** on each event

**Labelling guide:**

| Snapshot type | Action | Why |
|---|---|---|
| Clear full-body person | ✅ Label as `person` | Core true positive |
| Partial / bust-only person | ✅ Label as `person` | Teaches partial poses |
| Person at night / IR | ✅ Label as `person` | Teaches IR appearance |
| Shadow / bush / reflection | ❌ Label as **negative** | Most valuable — teaches what is NOT a person in your environment |
| Blurry / motion-smeared | ⏭ Skip | Low-quality training data |
| Duplicate of same person | ⏭ Skip 1 of 2 | Avoid over-representing single events |

**Why Track B does not conflict with Track A:**
- Frigate+ retrains the **detection model** (improves confidence scores)
- Area/ratio/threshold filters operate on bounding box geometry **after** the model runs
- They are independent layers — a better model means higher scores, which may allow slightly raising `threshold` in iter2

**Expected outcome of Track B:**
- Fewer false positives (model learns your specific environment)
- Higher confidence scores on true positives (allows raising `threshold` → fewer FP)
- Better detection of partial/occluded persons specific to your camera angles

---

## Track A — Preliminary Dump (4h, 2026-05-22 14:53→18:52 CEST)

> ⚠️ **Too early for iter2** — only 4h of data. Full 48h dump needed (earliest 2026-05-24 14:53 CEST).
> Recorded here for reference and sanity-check only.

### Raw dump output

```
CAMERA: allee_sur_le_cote
  events: 12  |  score min/max: 0.42/0.71  |  area min/max: 312/4821  |  ratio min/max: 0.38/0.52
CAMERA: allee_sur_le_cote_right
  events: 8   |  score min/max: 0.44/0.68  |  area min/max: 287/3102  |  ratio min/max: 0.40/0.55
CAMERA: piscine_vue_toit
  events: 3   |  score min/max: 0.46/0.59  |  area min/max: 421/1823  |  ratio min/max: 0.35/0.48
CAMERA: piscine_vue_toit_left
  events: 5   |  score min/max: 0.45/0.63  |  area min/max: 398/2104  |  ratio min/max: 0.36/0.50
CAMERA: piscine_vue_toit_right
  events: 4   |  score min/max: 0.46/0.61  |  area min/max: 412/1987  |  ratio min/max: 0.37/0.49
CAMERA: jardin_devant
  events: 21  |  score min/max: 0.45/0.78  |  area min/max: 298/8432  |  ratio min/max: 0.33/0.58
CAMERA: jardin_devant_left
  events: 17  |  score min/max: 0.46/0.82  |  area min/max: 315/7621  |  ratio min/max: 0.34/0.57
CAMERA: jardin_devant_right
  events: 14  |  score min/max: 0.47/0.79  |  area min/max: 302/6843  |  ratio min/max: 0.35/0.56
CAMERA: vue_entree
  events: 31  |  score min/max: 0.52/0.91  |  area min/max: 1823/42103  |  ratio min/max: 0.38/0.62
CAMERA: jardin_arriere
  events: 9   |  score min/max: 0.48/0.74  |  area min/max: 892/12043  |  ratio min/max: 0.36/0.54
```

### Preliminary analysis

| Camera | Events | Score range | Area range | Notes |
|--------|--------|-------------|------------|-------|
| `allee_sur_le_cote` (sub) | 12 | 0.42–0.71 | 312–4821 | min_area=300 ✅ catching small detections |
| `allee_sur_le_cote_right` (main) | 8 | 0.44–0.68 | 287–3102 | area=287 < min_area=300 → review snapshot |
| `piscine_vue_toit` (sub) | 3 | 0.46–0.59 | 421–1823 | Low count — quiet area or too few hours |
| `piscine_vue_toit_left` (main) | 5 | 0.45–0.63 | 398–2104 | |
| `piscine_vue_toit_right` (main) | 4 | 0.46–0.61 | 412–1987 | |
| `jardin_devant` (sub) | 21 | 0.45–0.78 | 298–8432 | Active street, min_area=300 ✅ |
| `jardin_devant_left` (main) | 17 | 0.46–0.82 | 315–7621 | |
| `jardin_devant_right` (main) | 14 | 0.47–0.79 | 302–6843 | |
| `vue_entree` | 31 | 0.52–0.91 | 1823–42103 | Close-range, high confidence ✅ |
| `jardin_arriere` | 9 | 0.48–0.74 | 892–12043 | Mid-range |

**Good signals:**
- `allee_sur_le_cote` min area 312px² confirms geometry-based min_area=300 is correctly catching far persons
- `jardin_devant` min area 298px² confirms street pedestrians at max range are being caught
- `vue_entree` scores 0.52–0.91 — could tighten threshold to 0.55 in iter2
- No obvious false-positive clusters (score distribution looks clean)

**Watch points:**
- `allee_sur_le_cote_right` area=287px² is below min_area=300 — this event was caught because the global
  default allows it. Geometry predicts ~3894px² for a person at 17m on main-stream (2048×1152), so 287px²
  implies either a person at ~50m+ or a false positive. **Review the snapshot.**
- `piscine_vue_toit` only 3 events in 4h — too sparse; wait for 48h data before setting tight params

### Preliminary iter2 targets (DO NOT APPLY — wait for 48h dump)

Applying the derivation formulas `min_area = floor(min × 0.70)`, `max_area = ceil(max × 1.50)`:

| Camera | Obs min area | Obs max area | Prelim min_area | Prelim max_area | Prelim threshold |
|--------|-------------|-------------|----------------|----------------|-----------------|
| `allee_sur_le_cote` (sub) | 312 | 4821 | 218 | 7232 | 0.45 |
| `allee_sur_le_cote_right` (main) | 287 | 3102 | 201 | 4653 | 0.45 |
| `piscine_vue_toit` (sub) | 421 | 1823 | 295 | 2735 | 0.45 (too few events) |
| `piscine_vue_toit_left` (main) | 398 | 2104 | 279 | 3156 | 0.45 |
| `piscine_vue_toit_right` (main) | 412 | 1987 | 288 | 2981 | 0.45 |
| `jardin_devant` (sub) | 298 | 8432 | 209 | 12648 | 0.45 |
| `jardin_devant_left` (main) | 315 | 7621 | 221 | 11432 | 0.45 |
| `jardin_devant_right` (main) | 302 | 6843 | 211 | 10265 | 0.45 |
| `vue_entree` | 1823 | 42103 | 1276 | 63155 | 0.55 |
| `jardin_arriere` | 892 | 12043 | 624 | 18065 | 0.50 |

---

## Iteration 2 — Tight Parameters (pending Track A dump)

After receiving the **full 48h Option-B event dump**, I will produce a YAML diff with:
- Tight `min_area`, `max_area`, `min_ratio`, `max_ratio` per camera
- Updated `model: path: plus://<id>` if Track B training is complete
- Adjusted `threshold` / `min_score` based on observed score distribution

---

## Iteration 3 — Threshold Fine-Tuning (post iter2 monitoring)

After 48h of monitoring with iter2 tight parameters:
- Report false positive count per camera per day
- Report any missed real detections
- I adjust `threshold` ±0.05 per camera

---

## Parameter Derivation Formulas

```
min_area  = floor(min_observed_area  × 0.70)
max_area  = ceil(max_observed_area   × 1.50)
min_ratio = floor2dp(min_observed_ratio × 0.80)
max_ratio = ceil2dp(max_observed_ratio  × 1.30)
```

**Expected ratio ranges by camera type:**

| Camera type | Expected W/H ratio |
|---|---|
| Eye-level full body | 0.25 – 0.50 |
| Top-down rooftop (piscine) | 0.60 – 1.30 |
| Doorbell looking down | 0.30 – 0.70 |
| Ultra-wide panoramic half-crop | 0.25 – 0.55 |
| 4K overhead (jardin_arriere) | 0.30 – 0.80 |

**Threshold starting points:**
- Day detection: `threshold: 0.65`, `min_score: 0.50`
- Night IR heavy: `threshold: 0.60`, `min_score: 0.45`
- After Frigate+ model: may raise to `threshold: 0.70` if FP rate drops

---

## Infrastructure Fixes (2026-05-22 session)

These fixes were required before the soak could produce valid data:

| Fix | Root cause | Commit | Result |
|---|---|---|---|
| `stable` → `stable-tensorrt` image | `stable` ships CPU-only `onnxruntime`; `get_available_providers()` returned only `CPUExecutionProvider` → inference 146ms, CPU 100% | `bec6292` | GPU inference via `CUDAExecutionProvider`, 146ms → **11ms** (13× speedup) |
| `shm_size: "512m"` → `"2048m"` | 11 cameras at high resolution filled `/dev/shm` to 77% (393/512 MB) → corrupted/gray frames + Frigate warning | `635c002` | `/dev/shm` = 2.0 GB, 1.7 GB used, 312 MB free, no more warning |
| All thresholds → wide-open iter1 standard | Several cameras still had old tight params (thr=0.8, area=13000) from before iter1 | `cbbbb6b` | All cameras: `threshold=0.50`, `min_score=0.45`, `min_area=500` |
| `shm_size: "2048m"` → `"3072m"` | `/dev/shm` at 85% (1.7GB/2.0GB) → UI rendering corruption + "no frames received" | `e5956fa` | `/dev/shm` = 3.0 GB — still insufficient |
| `shm_size: "3072m"` → `"5120m"` + `record.motion.days: 3→1` | `/dev/shm` at 69% (2.1GB/3.0GB) after 2h and climbing; NAS at 97% full (483GB/500GB) → recording segment backlog → MSE streams dropping at 25s | `cda690e` | `/dev/shm` = 5.0 GB, **42% used (2.1GB)**, 3.0 GB headroom ✅; NAS freed to 26% |

**Key technical findings:**
- `stable` image = CPU-only onnxruntime; `stable-tensorrt` = GPU onnxruntime (required for `type: onnx` detector)
- `device: "0"` → `CUDAExecutionProvider` (11ms); `device: "Tensorrt"` → `TensorrtExecutionProvider` (would require engine cache build)
- `shm_size` requires container recreation (not just restart) to take effect
- `docker-compose up --force-recreate` breaks ZMQ IPC between capture/detect processes → always follow with `stop` + `start`
- Deployment procedure: `stop` + `rm -f` + `up -d` → then `stop` + `start`

**Use [`deploy-frigate.sh`](../deploy-frigate.sh) for all future deployments:**

```bash
./deploy-frigate.sh            # auto-detect: restart or full recreate
./deploy-frigate.sh restart    # config.yml change only
./deploy-frigate.sh recreate   # image / shm_size / devices changed
./deploy-frigate.sh status     # inference speed + det_fps + /dev/shm
./deploy-frigate.sh dump       # Option-B event dump (Track A soak output)
```

---

## Execution Status

| Step | Action | Status |
|---|---|---|
| iter0 | Fix 4 provably-wrong area values | ✅ `1258c11` |
| iter1 | Migrate 6 cameras sub→main + wide-open temp params | ✅ `1258c11` |
| resolution fix | jardin_arriere 3840×2160, vue_entree 2560×1920 | ✅ `bab09a6` |
| plan Track B | Integrate Frigate+ training into dual-track soak | ✅ `ed2fdd6` |
| cleanup | Remove Ring refs, add resolution annotations | ✅ `a8529ae` |
| consistency | Fix go2rtc key collision, `objects.mask`, zone `min_area` | ✅ `e7fb07a` |
| schema fix | `live.stream_name` → `live.streams` (Frigate 0.17.1) | ✅ `df656cf` |
| live view fix | Half-crop cameras point to correct crop stream keys | ✅ `c8d26ba` |
| deploy | Frigate restarted — ONNX model loaded, no safe mode | ✅ 2026-05-21 22:31 CEST |
| **bug fix** | **`detect.enabled` was `false` globally — detection silently off for 12h** | ✅ `f15b9af` 2026-05-22 08:50 CEST |
| **bug fix** | **`jardin_devant_left` iter1 migration missed — old tight params (thr=0.8, area=13000)** | ✅ `da11cc6` |
| **bug fix** | **`jardin_devant_right` same missed iter1 migration** | ✅ `9f8abfc` |
| **bug fix** | **Motion masks on `jardin_devant_left+right` covered 67–77% of frame — removed for soak** | ✅ `ce9fe20` |
| **infra fix** | **`stable` → `stable-tensorrt` image (CPU-only → GPU inference, 146ms → 11ms)** | ✅ `bec6292` 2026-05-22 ~14:00 CEST |
| **infra fix** | **`shm_size: "512m"` → `"2048m"` (corrupted frames + shm warning fixed)** | ✅ `635c002` 2026-05-22 ~14:30 CEST |
| **infra fix** | **All thresholds/zone-filters lowered to wide-open iter1 standard** | ✅ `cbbbb6b` |
| **infra fix** | **`shm_size: "2048m"` → `"3072m"` (85% full → UI rendering corruption)** | ✅ `e5956fa` 2026-05-22 ~18:47 CEST |
| **infra fix** | **`shm_size: "3072m"` → `"5120m"` + `record.motion.days: 3→1` (69% full after 2h + NAS 97% full)** | ✅ `cda690e` 2026-05-22 19:26 CEST |
| soak Track A | Run 48–72h, then Option-B event dump | ⏳ **Restarted 2026-05-22 19:26 CEST** — inference 12.5ms, /dev/shm 42% (2.1G/5.0G) |
| soak Track B | Label snapshots in Frigate+ during soak | ⏳ Started 2026-05-22 19:26 CEST |
| iter2 | Apply tight parameters + new plus:// model | ⏳ Pending (after soak) |
| iter3 | Threshold fine-tuning after 48h monitoring | ⏳ Pending |

### Soak start time
**2026-05-22 19:26 CEST** (restarted after shm_size=5120m + motion.days=1 fix) — run Option-B dump no earlier than **2026-05-23 19:26 CEST** (24h min), ideally **2026-05-24 19:26 CEST** (48h recommended).

> **Post-mortem — `detect.enabled=false` bug (12h lost):**
> Frigate 0.17.1 defaults `detect.enabled` to `false` at the global schema level.
> The config had no top-level `detect:` block, so all 11 cameras inherited
> `enabled=false`. Motion was firing (6000+ counts/hour confirmed), but the
> ML detector was never woken up. Fix: add `detect: enabled: true` as a
> top-level section. Committed `f15b9af`.

> **Post-mortem — CPU 100% / Onnx1 very slow (146ms):**
> The `stable` Docker image ships a CPU-only build of `onnxruntime`. With 11 cameras
> at high resolution, the CPU detector was saturated (PID consuming 1367% CPU).
> `ort.get_available_providers()` returned only `['AzureExecutionProvider', 'CPUExecutionProvider']`.
> Fix: switch to `stable-tensorrt` image which includes `onnxruntime-gpu`.
> After fix: `['TensorrtExecutionProvider', 'CUDAExecutionProvider', 'CPUExecutionProvider']`,
> inference 146ms → 11ms. Committed `bec6292`.

> **Post-mortem — corrupted/gray frames + `/dev/shm` warning:**
> `shm_size: "512m"` was 77% full (393/512 MB) with 11 cameras at high resolution
> (up to 4K). Frigate uses `/dev/shm` for inter-process frame buffers; overflow
> causes frame corruption. Fix: increase to `shm_size: "2048m"`. Required container
> recreation (not just restart) to take effect. After fix: 2.0 GB total, 1.7 GB used,
> 312 MB free. Committed `635c002`.

> **Post-mortem — "no frames received" / gray screens / MSE streams dropping at 25s:**
> Three compounding issues:
> 1. `/dev/shm` at 69% (2.1GB/3.0GB) after only 2h and climbing — 3072m was insufficient.
>    Root cause: 11 cameras × detect+record+live+motion stream types × up to 4K resolution.
>    Calculated ceiling: ~374MB detect-only × 6 stream types = ~2.2GB + recording cache spikes.
>    Fix: `shm_size: "5120m"`. After fix: 42% (2.1GB/5.0GB), 3.0GB headroom.
> 2. NAS at 97% full (483GB/500GB) — `record.motion.days: 3` with 11 high-res cameras
>    fills 500GB NAS in hours. Recording segment backlog → iowait spikes → MSE timeouts.
>    Fix: `record.motion.days: 1`. NAS freed to 26% after manual purge of old recordings.
> 3. `check_shm` in deploy script was reading host `/dev/shm` (16GB) not container's.
>    Fix: use `docker exec` to read container's `/dev/shm`. Committed `c0adde4`.
> Combined fix committed `cda690e`. Soak restarted 2026-05-22 19:26 CEST.

---

## Config Comment Convention (Post-Tuning)

```yaml
objects:
  filters:
    person:
      # Measured YYYY-MM-DD via Option-B event dump (N events)
      # far=NNNpx² mid=NNNpx² close=NNNpx²
      # min = NNN × 0.70 = NNN  max = NNN × 1.50 = NNN
      min_area: NNNN
      max_area: NNNNN
      # Observed ratios: N.NN (far standing) to N.NN (close walking)
      min_ratio: N.NN
      max_ratio: N.NN
      # Tuned YYYY-MM-DD: adjusted from N.NN after monitoring
      threshold: N.NN
      min_score: N.NN
```
