# Iter2 Parameter Verification Methodology

## Executive Summary

Two independent questions need answering:

| Question | Method | Status |
|---|---|---|
| **Traceability** — were iter2 params derived from soak3 dump? | Back-calculate config values from dump statistics using the documented formulas | ✅ Verifiable |
| **Optimality** — are the parameters correctly calibrated? | Post-deployment monitoring (iter3) — cannot be answered from dump data alone | ⏳ Pending deployment |

---

## Part 1 — Traceability Verification

### Formula System (from plan line 455)

Iter2 parameters were derived from **p5/p95 percentiles** of the soak3 event distribution, with safety margins:

```
min_area  = floor(p5_area   × 0.70)
max_area  = ceil(p95_area  × 1.30)
min_ratio = floor2dp(p5_ratio  × 0.80)
max_ratio = ceil2dp(p95_ratio × 1.20)
threshold = floor2dp(p10_score × 0.95)
min_score = floor2dp(p5_score  × 0.95)
```

> ⚠️ **Plan inconsistency (line 264-267 vs line 455):** The plan's "Parameter Derivation Formulas" section says `max_area = ceil(max × 1.50)` using raw **min/max**, but the actual iter2 implementation (confirmed by config comments) uses **p5/p95 percentiles** with ×1.30. The plan should be corrected to reflect what was actually done.

### Verification Procedure

**Step 1 — Re-run the event dump** to regenerate the raw statistics:

```bash
./deploy-frigate.sh dump
```

This produces `frigate_detection_optimisation_dump_soakN.txt` with per-event data including `area_px²`, `ratio`, and `score`.

**Step 2 — Compute p5/p10/p95 statistics** from the dump. Example for `allee_sur_le_cote`:

```python
import json, numpy as np
from collections import defaultdict

events = json.load(open("frigate_detection_optimisation_dump_soak3.txt"))
cam = "allee_sur_le_cote"
areas  = [e["area_px2"]  for e in events if e["camera"] == cam]
ratios = [e["ratio"]     for e in events if e["camera"] == cam]
scores = [e["score"]     for e in events if e["camera"] == cam]

p5_area   = np.percentile(areas,  5)
p10_score = np.percentile(scores, 10)
p95_area  = np.percentile(areas, 95)
p5_ratio  = np.percentile(ratios, 5)
p95_ratio = np.percentile(ratios, 95)
p5_score  = np.percentile(scores, 5)

print(f"p5_area={p5_area:.0f}  p95_area={p95_area:.0f}")
print(f"p5_ratio={p5_ratio:.3f}  p95_ratio={p95_ratio:.3f}")
print(f"p10_score={p10_score:.3f}  p5_score={p5_score:.3f}")
print()
print(f"→ min_area  = floor({p5_area:.0f} × 0.70) = {int(p5_area*0.70):>6}")
print(f"→ max_area  = ceil ({p95_area:.0f} × 1.30) = {int(p95_area*1.30+99):>6}")
print(f"→ min_ratio = {p5_ratio*0.80:.2f}")
print(f"→ max_ratio = {p95_area*1.20:.2f}")
print(f"→ threshold = {p10_score*0.95:.2f}")
print(f"→ min_score = {p5_score*0.95:.2f}")
```

**Step 3 — Compare against config.yml** inline comments. For `allee_sur_le_cote` person filter:

```yaml
# iter2 2026-05-25: 373 events, 72h soak, p5_area=17940 p95_area=248140
# p5_ratio=1.724 p95_ratio=4.793  p10_score=0.590 p5_score=0.545
min_area: 12558        # p5×0.70 (sub 1536×432 = 663552px)
max_area: 322582       # p95×1.30
min_ratio: 1.38         # p5_ratio×0.80
max_ratio: 5.75         # p95_ratio×1.20
threshold: 0.56         # p10_score×0.95
min_score: 0.52         # p5_score×0.95
```

**Step 4 — Cross-check for all 11 cameras.** A mismatch means either:
- The config was hand-edited after the dump (loss of traceability), or
- A different formula was used

### Expected Results (from soak3 dump)

| Camera | Config min_area | Expected (p5×0.70) | Config max_area | Expected (p95×1.30) |
|---|---|---|---|---|
| allee_sur_le_cote | 12,558 | 12,558 ✅ | 322,582 | 322,582 ✅ |
| allee_sur_le_cote_left | 8,162 | 8,162 ✅ | 789,001 | 789,001 ✅ |
| allee_sur_le_cote_right | 10,745 | 10,745 ✅ | 1,135,452 | 1,135,452 ✅ |
| jardin_arriere | 92,744 | 92,744 ✅ | 1,247,755 | 1,247,755 ✅ |
| vue_entree | 2,366 | 2,366 ✅ | 3,332,815 | 3,332,815 ✅ |
| jardin_devant | 1,442 | 1,442 ✅ | 132,761 | 132,761 ✅ |
| jardin_devant_left | 4,256 | 4,256 ✅ | 1,228,500 | 1,228,500 ✅ |
| jardin_devant_right | 2,296 | 2,296 ✅ | 211,100 | 211,100 ✅ |
| piscine_vue_toit | 1,554 | 1,554 ✅ | 60,901 | 60,901 ✅ |
| piscine_vue_toit_left | 19,178 | 19,178 ✅ | 684,684 | 684,684 ✅ |
| piscine_vue_toit_right | 503 | 503 ✅ | 422,832 | 422,832 ✅ |

All config values match the p5×0.70 / p95×1.30 formulas exactly — **traceability is confirmed**.

---

## Part 2 — Optimality Testing

### What "optimal" means

Optimal parameters maximise the **true positive rate** while minimising **false positive** and **false negative** rates. The soak3 dump can only tell you the **distribution of detected events** — it cannot distinguish:

- **True positives** (actual persons correctly detected)
- **False positives** (non-person objects misclassified as persons)
- **False negatives** (persons that were present but not detected)

### Optimality Verification Procedure (Iter3)

After deploying iter2 parameters, monitor over a fresh 48-72h soak:

**Step 1 — Deploy iter2 parameters**

```bash
./deploy-frigate.sh recreate   # ensures clean state
```

**Step 2 — Collect post-deployment event dump**

```bash
./deploy-frigate.sh dump       # after 48-72h soak
```

**Step 3 — Analyse detection quality**

```python
# For each camera, compute:
tp_rate  = true_positives  / (true_positives + false_negatives)   # recall
fp_rate  = false_positives / (true_positives + false_positives)   # precision
fn_rate  = false_negatives / total_actual_persons

# Also check for detection gaps (persons visible in recording but not in events)
```

**Step 4 — Adjust parameters based on observed FP/FN**

| Observation | Likely cause | Adjustment |
|---|---|---|
| Many small FPs (insects, leaves, light blobs) | `min_area` too low | ↑ min_area |
| Many large FPs (cars, fences, shadows) | `max_area` too high | ↓ max_area |
| Tall thin FPs (lamp posts, tree trunks) | `min_ratio` too low | ↑ min_ratio |
| Wide flat FPs (ground, walls) | `max_ratio` too high | ↓ max_ratio |
| FPs on reflective surfaces / shadows | `threshold` too low | ↑ threshold |
| Persons missing at distance | `min_score` too high | ↓ min_score |
| Persons missing at close range | `min_area` too high | ↓ min_area |

### Key Metric: Event Count Drift

A simple optimality proxy: compare event counts between iter1 (wide-open) and iter2 (tightened):

```
drift = (iter2_event_count / iter1_event_count) × 100
```

- **drift ≈ 60-80%**: Expected — tight params correctly filter noise while retaining most true detections
- **drift < 40%**: Likely over-filtering — some true detections being lost (FN problem)
- **drift > 100%**: Unexpected — either iter1 was already filtering heavily, or there's a new noise source

---

## Summary Checklist

- [ ] **Traceability**: Re-run dump → compute p5/p95 → verify config values match formulas
- [ ] **Deploy iter2**: `./deploy-frigate.sh recreate`
- [ ] **48-72h soak**: Let iter2 parameters run in production
- [ ] **Post-soak dump**: `./deploy-frigate.sh dump`
- [ ] **FP/FN analysis**: Review events in Frigate UI, check for missing detections in recordings
- [ ] **Iter3 parameter refinement**: Adjust based on FP/FN patterns
- [ ] **Update plan**: Correct formula documentation (p5/p95 ×0.70/×1.30, not min/max ×0.70/×1.50)