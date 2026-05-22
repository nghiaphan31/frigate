# Detection Parameter Optimisation Plan — Frigate NVR (Calypso RTX 5060 Ti)

> **Status:** 🟢 Deployed — 48–72h soak running (Track A + Track B active)
> **Branch:** `detection-optimisation`
> **Last updated:** 2026-05-21
> **Config file:** [`config.yml`](../config.yml)

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
threshold: 0.55-0.60 # reasonable confidence floor
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

## Iteration 2 — Tight Parameters (pending Track A dump)

After receiving the Option-B event dump, I will produce a YAML diff with:
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
| soak Track A | Run 48–72h, then Option-B event dump | ⏳ Started 2026-05-22 08:50 CEST |
| soak Track B | Label snapshots in Frigate+ during soak | ⏳ Started 2026-05-22 08:50 CEST |
| iter2 | Apply tight parameters + new plus:// model | ⏳ Pending (after soak) |
| iter3 | Threshold fine-tuning after 48h monitoring | ⏳ Pending |

### Soak start time
**2026-05-22 08:50 CEST** (restarted after `detect.enabled` fix) — run Option-B dump no earlier than **2026-05-24 08:50 CEST** (48h), ideally **2026-05-25 08:50 CEST** (72h).

> **Post-mortem — `detect.enabled=false` bug (12h lost):**
> Frigate 0.17.1 defaults `detect.enabled` to `false` at the global schema level.
> The config had no top-level `detect:` block, so all 11 cameras inherited
> `enabled=false`. Motion was firing (6000+ counts/hour confirmed), but the
> ML detector was never woken up. Fix: add `detect: enabled: true` as a
> top-level section. Committed `f15b9af`.

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
