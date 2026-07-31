# Post-iter1 Detection Optimisation (2026-07-31)

## Context

The `feat/frigate-plus-training-collection-vue-entree` branch ran Frigate with
relaxed detection parameters on three outdoor cameras (`vue_entree`,
`jardin_arriere`, `piscine_vue_toit`) for the 8-week period
**2026-06-04 → 2026-07-30** to collect training data for a Frigate+ custom
model. The relaxations were explicitly provisional in the commit messages
(2407a80, 5a291b9, 42a7f67, daf0e85, 1435838):

> "Revert to iter0 once Frigate+ has been retrained on the accumulated data
> and a new plus://<hash> is issued."

Commit `0daaf33` (2026-07-31) issued the new model:
**`plus://c1aa04320f389aa6c7702bf9ddd3fe6d`** — a 46-class yolonas model
trained on 9 camera sub-regions of the 5 outdoor Reolink streams. The
condition for revert is met.

## What this commit does

Reverts the three training-relaxed cameras back to the iter0 physics-derived
contract (their original pre-training values), then keeps only the
deliberate production tightenings that emerged from the training period.

### Cameras affected

| Camera              | Pre-training (iter0)  | Training (committed)         | Post-iter1 (this commit)     |
|---------------------|----------------------|------------------------------|------------------------------|
| allee_sur_le_cote   | 0.55/0.45, fps 5     | unchanged                    | unchanged                    |
| jardin_devant       | 0.55/0.45, fps 5     | unchanged                    | unchanged                    |
| **jardin_arriere**  | 0.55/0.45, fps 5     | 0.4/0.3, fps 10, [person,face] | **0.55/0.45, fps 5, [person]** |
| **piscine_vue_toit**| 0.55/0.45, fps 5     | 0.30/0.25, fps 10, [person,face] | **0.55/0.45, fps 5, [person]** |
| **vue_entree**      | 0.55/0.45, fps 7     | 0.10/0.10 diagnostic, fps 10, [person,face] | **0.55/0.45, fps 7, [person]** |

### Production values kept (not training-only artefacts)

| Camera              | Key              | Value    | Why kept                                                              |
|---------------------|------------------|----------|-----------------------------------------------------------------------|
| jardin_arriere      | motion.threshold | 30       | Night-mode CPU storm fix (1435838). IR noise at 4K @ 5 fps overwhelms 26. |
| jardin_arriere      | motion.mask      | 7 polys  | Long-term FP suppressor (trees / fence reflections).                  |
| jardin_arriere      | detect.width/h   | 1920/1080| CPU fix (4c77d3d) — 4K→1080p detection downscale.                     |
| jardin_arriere      | prive.min_area   | 500      | 2026-06-05 tightening (was iter0 300; suppresses 15-20 m IR FPs).      |
| piscine_vue_toit    | motion.threshold | 15       | Iteratively tuned 5→10→15 (4c77d3d) to fix 45% CPU storm on panoramic sub. |
| piscine_vue_toit    | motion.contour_area | 25    | Same CPU fix.                                                          |
| vue_entree          | motion.mask      | 3 polys  | Long-term FP suppressor (sky / trees / reflected surfaces).           |
| vue_entree          | prive.min_area   | 500      | 2026-06-05 tightening (was iter0 300; suppresses diagnostic-mode FPs). |

### Spec alignment (`tests/camera_spec.py`)

- Removed `training_collection_mode: True` from the 3 cameras
- Restored `expected_fps` to iter0 (5/7/5 — was 10/10/10 during training)
- Updated `jardin_arriere` `min_area_margin` 0.022 → 0.0857 and
  `max_area_margin` 0.61 → 2.45 to re-derive from the 1080p detect
  stream (the 4K→1080p downscale in 4c77d3d left the original 4K
  margin values stale — the L2 geometry assertion now correctly
  validates the operator-chosen noise-floor / generous-upper choices)

## Verification

| Test                       | Result         |
|----------------------------|----------------|
| `make iter0-diff-all`      | 8/8 OK         |
| `tests/test-config.sh` (L1)| 139/139 OK     |
| `tests/test-math.sh`   (L2)| 139/139 OK     |
| `tests/test-bringup.sh` (L3)| 89 OK, 1 WARN, 3 FAIL (3 "no zones" failures on indoor Tapo cameras are pre-existing on parent commit; those cameras have `detect.enabled: false` and intentionally no zones) |

## Phase 5: data-driven re-tuning (not in this commit)

The threshold / min_score / min_area values in this commit are the
**iter0 contract derived from mount geometry**, which assumes the model's
score distribution. The new yolonas model
(`plus://c1aa04320f389aa6c7702bf9ddd3fe6d`) is trained on the relaxed
data and may have a different score band than the generic SSD the iter0
contract was calibrated against. The right next step is:

1. Restart the Frigate container with this commit's config
2. Run `make evaluate` (tests/wait-and-evaluate.sh) over a fresh 24-48h
   soak to capture the per-camera `top_score` percentile distribution
   from the new model
3. If the new model's score band is meaningfully different from the
   iter0 assumptions (e.g. tight p95 ≈ 0.65 vs the iter0 +0.10/+0.05
   delta of 0.55/0.45), update the spec's `expected_threshold` /
   `expected_min_score` and re-derive the per-camera values

This is a **data-driven, not commit-driven** task — it requires live
Frigate events over a 1-2 day window. The current commit is the safe
iter0 baseline to start from.

## What was decided, what was kept, what was dropped

### Dropped (pure training-collection artefacts)

- `objects.track: [person, face]` → `track: [person]` on the 3 cameras
- The permissive `face` filter block on the 3 cameras (was
  `threshold 0.10/0.30, min_area 0, min_ratio 0.0, max_ratio 8-12`)
- The `face` zone filter block on the prive zones
- `detect.fps: 10` → restored to 5/7/5
- `vue_entree` per-camera `motion.threshold: 10` (reverted to global 26)
- The diagnostic-mode threshold (0.10) and min_area (25) on vue_entree

### Kept (deliberate production values)

- `jardin_arriere` night-mode `motion.threshold: 30` (1435838) and motion.mask
- `jardin_arriere` 4K→1080p detect stream downscale (4c77d3d)
- `jardin_arriere` prive zone `min_area: 500` (2026-06-05 tightening)
- `piscine_vue_toit` `motion.threshold: 15, contour_area: 25` (4c77d3d
  iterative tuning)
- `vue_entree` motion.mask (long-term FP suppressor)
- `vue_entree` prive zone `min_area: 500` (2026-06-05 tightening)

### Re-decided (spec vs config)

- `tests/camera_spec.py` `jardin_arriere.min_area_margin` 0.022 → 0.0857
  and `max_area_margin` 0.61 → 2.45 — the original 4K margin values
  were stale after the 4K→1080p downscale; the new values re-derive
  from the 1080p geometry and pass the L2 test.
