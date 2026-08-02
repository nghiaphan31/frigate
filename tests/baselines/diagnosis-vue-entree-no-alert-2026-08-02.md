# vue_entree — test-walk diagnosis: "why no alert?"

**Window**: 2026-08-02T18:56:30Z → 18:59:30Z
**Original config change**: `cameras.vue_entree.zones.prive.filters.person.min_ratio = 1.0 → 0.2` (applied by user via API just before walk)
**Walk start**: ~2026-08-02T18:57:00Z
**Walk end**:   ~2026-08-02T18:59:20Z

## What fired (1 vue_entree event + 4 from other cameras, all in `make walk`)

```
[1] 2026-08-02T18:57:37Z  vue_entree  person  top_score=0.977  duration_s=53.34  -> detection (NOT alert)
    event id = 1785697057.942166-sovvjt
    bbox normalized [x,y,w,h] = [0.307, 0.515, 0.149, 0.473]
    bbox pixel      [x,y,w,h] = [785, 988, 382, 908]   (on 2560×1920 detect stream)
    area = 346 856 px²   ratio (W/H) = 0.421   centroid = [0.381, 0.751]
    Stage 4 (person filter):  all 6 checks PASSED  (incl. min_ratio 0.421 ≥ 0.2)
    Stage 5 (zone matching):  no zone hit           <-- ROOT CAUSE
    Stage 6 (review gate):    detection             (event zones {} ⊄ alerts_required_zones ['prive'])
```

## Root cause

Frigate's zone matching uses the **bottom-center of the bounding box** (not the centroid).

| Point | Value | Current prive polygon (21 vertices) | New prive polygon (14 vertices) |
|---|---|---|---|
| bbox centroid `(0.381, 0.751)` | well inside the polygon | INSIDE | INSIDE |
| bbox bottom-center `(0.381, 0.988)` | 0.015 below the bay window | **OUTSIDE** ← failure | **INSIDE** ← fix |
| prive polygon y-range at x=0.381 | — | `[0.000, 0.973]` (capped by bay-window vertex 18) | `[0.000, 0.9995]` (flat bottom at y=1) |

The current 21-vertex prive polygon has a 0.025-tall "bay window" cutout along the bottom edge of the frame (vertices 14→15→16→17→18→19→20→21 dip up to `y≈0.975`). That cutout excludes the area where a close-up person's feet actually land (the bottom-center of a 47%-tall bbox is at `y=0.988`). The geometric centroid at `y=0.751` is well inside, so a centroid-based zone match would have classified the event as an ALERT — but Frigate uses bottom-center.

## Fix (applied via Frigate `PUT /api/config/set`, OpenAPI body schema)

```json
{
  "requires_restart": 0,
  "update_topic": null,
  "config_data": {
    "cameras": {
      "vue_entree": {
        "zones": {
          "prive": {
            "coordinates": "0,0.735,0,0.488,0.304,0.523,0.308,0,0.456,0,0.685,0,0.731,0.154,0.809,0.204,0.823,0.275,0.836,0.361,0.85,0.487,1,0.491,1,1,0,1",
            "filters": { "person": { "min_ratio": 0.2 } }
          }
        }
      }
    }
  }
}
```

- **Coordinates**: 14 vertices (down from 21). Drops the bay-window vertices 15–21, replaces them with a single bottom-left corner `(0, 1)` connecting `(0.73, 1)` → `(0, 1)` → `(0, 0.735)`. Top edge, right edge, and bay window's *upward* shape are unchanged → no public-sidewalk regression.
- **`min_ratio = 0.2`**: re-applied because it reverted between the test walk and now (both `/api/config` and `config.yml` line 900 showed `1.0` again).

## Live state (verified at 2026-08-02T19:18:49Z)

| Key | Live value | Notes |
|---|---|---|
| `cameras.vue_entree.zones.prive.coordinates` | 14 vertices, flat bottom at y=1 | new polygon is live |
| `cameras.vue_entree.zones.prive.filters.person.min_ratio` | `0.2` | both fixes live |
| `cameras.vue_entree.zones.prive.filters.person.{min_area, max_area, max_ratio, threshold, min_score}` | `500, 24000000, 4.0, 0.55, 0.5` | unchanged |
| `cameras.vue_entree.zones.prive.{objects, inertia, loitering_time}` | `[person, face], 3, 0` | unchanged |
| All other cameras and zones | unchanged | full 8-camera list intact |

## Re-projection of the original test-walk bbox against the live config

```
bbox centroid       (0.381, 0.751)  -> INSIDE  (was INSIDE, still INSIDE)
bbox bottom-center  (0.381, 0.988)  -> INSIDE  (was OUTSIDE, now INSIDE)   <-- the fix
bbox top-center     (0.381, 0.515)  -> INSIDE  (was INSIDE, still INSIDE)
```

With the live `min_ratio=0.2`, the bbox ratio of `0.421` will also pass Stage 4 (Person filter).

## Expected outcome of the next test walk

```
Stage 1  Motion pre-filter         [PASS]
Stage 2  Object detector (TRT)     [PASS]
Stage 3  Bounding box              [PASS]
Stage 4  Person filter (physics)   [PASS]  (min_ratio 0.421 >= 0.2, all 6 checks pass)
Stage 5  Zone matching             [hit prive]  <-- was 'no zone hit', now hits
Stage 6  Review gate               [ALERT]      <-- was 'detection', now alert
Stage 7  Snapshot                  [WRITTEN]
Stage 8  Recording                 [WRITTEN]    (if event is long enough to close)
Stage 9  MQTT publish              [PUBLISHED]  (frigate+/events, severity=alert)
```

## Open follow-ups (after the next test walk confirms the fix)

1. Re-run `make walk CAM=vue_entree WALK_START=2026-08-02T19:18:50Z WALK_END=...` and verify Stage 5 hits prive + Stage 6 is ALERT.
2. If confirmed, port the live changes to `config.yml` so the file matches the live state (currently the file still has the old 21-vertex polygon and `min_ratio: 1.0`).
3. Add a comment block in `config.yml` documenting the bay-window footgun so the next operator doesn't reintroduce the cutout.

## Snapshot artifacts (archived for drift analysis)

- `tests/baselines/state-2026-08-02T18-59-vue-entree-min-ratio.json` — pre-fix state report (1h window)
- `tests/baselines/walk-2026-08-02T18-56-vue-entree-min-ratio.json` — pre-fix walk report (180s window, 5 events)
