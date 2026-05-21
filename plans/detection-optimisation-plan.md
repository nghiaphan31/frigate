# Detection Parameter Optimisation Plan — Frigate NVR (Calypso RTX 5060 Ti)

> **Status:** Iteration 0 pending approval  
> **Last updated:** 2026-05-20  
> **Config file:** [`config.yml`](../config.yml)

---

## Architecture Decision: Main Stream for Detection

### GPU capacity verdict

The RTX 5060 Ti 16 GB with ONNX Runtime + TensorRT can comfortably handle **10–15 concurrent 1080p inference streams** at 10 fps. 11 camera streams are well within budget.

### Stream resolution map

| Physical camera | Main stream | Sub stream | Main half-crop (go2rtc) |
|---|---|---|---|
| Reolink Duo 3 × 3 | **4096×1152** | 1536×432 | **2048×1152** (left/right) |
| Reolink single-lens (jardin_arriere) | ~2560×1440 | 640×360 | — |
| Reolink Doorbell POE (vue_entree) | ~2048×1536 | 640×480 | — |

> **Rule:** Never use the full 4096×1152 panoramic for detection — the 3.5:1 aspect ratio is incompatible with mobilenet/SSD model inputs. Always use the 2048×1152 half-crops produced by the NUC go2rtc.

### Minimum-edit stream migration table

| Camera block | Detect input: FROM | Detect input: TO | Width | Height |
|---|---|---|---|---|
| `allee_sur_le_cote_left` | `…allee_cote_sub_left` | `…allee_cote_main_left` | 2048 | 1152 |
| `allee_sur_le_cote_right` | `…allee_cote_sub_right` | `…allee_cote_main_right` | 2048 | 1152 |
| `piscine_vue_toit_left` | `…vue_sud_sub_left` | `…vue_sud_main_left` | 2048 | 1152 |
| `piscine_vue_toit_right` | `…vue_sud_sub_right` | `…vue_sud_main_right` | 2048 | 1152 |
| `jardin_arriere` | `…nord_sur_maison_sub` | `…nord_sur_maison_main` | TBD* | TBD* |
| `vue_entree` | `…vue_entree_sub` | `…vue_entree_main` | TBD* | TBD* |

> *TBD = confirm actual main stream resolution via `ffprobe` or go2rtc UI before applying.

`jardin_devant_left` and `jardin_devant_right` are **already on main stream** — no stream change needed.

---

## Iteration 0 — Immediate Fixes (No Snapshots Required)

These values are provably wrong from the resolution alone:

| Camera | Parameter | Old | New | Reason |
|---|---|---|---|---|
| `allee_sur_le_cote` | `max_area` | 12,000 | 40,000 | 1536×432: close person ≈ 80×200 = 16,000 px² |
| `jardin_devant_left` | `max_area` | 52,000 | 300,000 | 2048×1152: close person ≈ 200×600 = 120,000 px² |
| `jardin_devant_right` | `max_area` | 52,000 | 300,000 | Same |
| `piscine_vue_toit_right` | `min_area` | 10,000 | 4,000 | 768×432: distant person ≈ 50×120 = 6,000 px² |

---

## Snapshot Submission Format

For each camera, send measurements in this format:

```
CAMERA: <camera_name>
FRAME_SIZE: <detect_width> x <detect_height>
SNAPSHOTS:
  A (far/entry):  bbox = x1=NNN y1=NNN x2=NNN y2=NNN
  B (mid-zone):   bbox = x1=NNN y1=NNN x2=NNN y2=NNN
  C (close):      bbox = x1=NNN y1=NNN x2=NNN y2=NNN
  D (night/IR):   bbox = x1=NNN y1=NNN x2=NNN y2=NNN
```

Normalised coordinates (0.0–1.0) from the Frigate debug overlay are also accepted:
```
  A (far/entry):  bbox = 0.27,0.18,0.38,0.88   (x_min,y_min,x_max,y_max)
```

Minimum: **2 snapshots** per camera (one far, one close).

### How to capture

**Method A — Frigate debug UI:**
1. Open `http://192.168.50.150:5000/cameras/<camera_name>`
2. Click **"Debug"** tab → enable **"Show bounding boxes"**
3. Have a person walk through the scene
4. Screenshot when bbox is visible; measure bbox corners in any image editor

**Method B — API snapshot:**
```bash
curl "http://192.168.50.150:5000/api/<camera_name>/latest.jpg" -o snap_<camera>.jpg
```

---

## Parameter Derivation Formulas

Given N snapshots with measured areas and ratios:

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

**Threshold starting points:**
- Day detection: `threshold: 0.65`, `min_score: 0.50`
- Night IR heavy: `threshold: 0.60`, `min_score: 0.45`
- Adjust ±0.05 per iteration based on false positive / missed detection counts

---

## Iterative Tuning Loop

```
Iteration N:
  1. You submit snapshots (2–8 per camera)
  2. I compute min_area, max_area, min_ratio, max_ratio
  3. I produce a minimal YAML diff (only changed lines)
  4. You apply diff + docker compose restart frigate
  5. Monitor 48h in Frigate Events tab
  6. Report: false positive count + missed detection count per camera
  7. I adjust threshold / min_score → go to step 3
```

---

## Execution Order

| Priority | Camera(s) | Action | Status |
|---|---|---|---|
| 0 | `allee_sur_le_cote`, `jardin_devant_left/right`, `piscine_vue_toit_right` | Fix provably-wrong area values | ⏳ Pending approval |
| 1 | `jardin_arriere` | Migrate sub→main + snapshot-tune | ⏳ Awaiting snapshots |
| 2 | `vue_entree` | Migrate sub→main + snapshot-tune | ⏳ Awaiting snapshots |
| 3 | `allee_sur_le_cote_left/right` | Migrate sub→main + snapshot-tune | ⏳ Awaiting snapshots |
| 4 | `piscine_vue_toit_left/right` | Migrate sub→main + snapshot-tune | ⏳ Awaiting snapshots |
| 5 | `jardin_devant_left/right` | Snapshot-tune only (already on main) | ⏳ Awaiting snapshots |
| 6 | All cameras | Threshold fine-tuning after 48h monitoring | ⏳ After iteration 1 |

---

## Config Comment Convention (Post-Tuning)

```yaml
objects:
  filters:
    person:
      # Measured YYYY-MM-DD: far=NNNpx² mid=NNNpx² close=NNNpx²
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
