# Frigate NVR — Test Suite

Three-layer regression test framework for the multi-camera integration
branch ([`feature/multi-camera`](../)). Each per-camera commit on the
integration branch is designed to pass **L1** and **L2** at minimum; the
operator runs **L3** before merging a batch of camera commits into
`main`.

## Layers at a glance

| Layer | Catches | Script | Cost | Requires |
|------:|---------|--------|-----:|----------|
| **L1** | YAML parse + structure: new camera is malformed; required sections missing; typos in keys; `go2rtc.streams` out of sync with `cameras:` references | [`test-config.sh`](test-config.sh) | ≈ 5 s | `python3` + `PyYAML` |
| **L2** | Math derivation: filter values don't match the geometry comment (`min_area ≠ H_px × W_px × margin`); camera added but zones missing; spec-vs-actual drift (operator changed `config.yml` but not the spec, or vice versa) | [`test-math.sh`](test-math.sh) | ≈ 5 s | `python3` + `PyYAML` |
| **L3** | Live bring-up: container starts; `/api/cameras` lists every camera in the spec; detection runs on each; the 14-step pipeline report is HEALTHY/DEGRADED for every camera | [`test-bringup.sh`](test-bringup.sh) | 1-4 min | GPU, container, NAS, network, all 11 cameras on the LAN |

L1 and L2 run on every CI / pre-commit hook. L3 is operator-only
(opt-in via `--with-bringup`) because it requires the full hardware
stack.

## Quick start

```sh
# Fast check (L1 + L2) — safe on any host with python3 + PyYAML
make test

# Full pre-merge gate (L1 + L2 + L3) — must be run on Calypso
make test-bringup

# Individual layers
make test-config
make test-math
make test-bringup-only

# Print the list of cameras the L2 harness will iterate over
make list-cameras
# (equivalent to: ./bring-up.sh --list-cameras)
```

## Adding a new camera (per-camera commit recipe)

A new camera is one commit on the integration branch. The commit touches
**up to 4 files** and is fully self-contained (each commit passes L1 + L2
on its own, no need to rebase earlier cameras).

1. **`config.yml`**
   - Add the camera block under `cameras:`. Match the comment style of
     the existing `allee_sur_le_cote` block: HARDWARE → MOUNT GEOMETRY →
     STREAMS → FPS RATIONALE → PHYSICS-DERIVED PERSON DETECTION (with
     the H_px, W_px, area derivation spelled out) → ZONES.
   - Add the new go2rtc stream entry under `go2rtc.streams:` (one
     per camera; the comment names the hardware, the NUC stream name
     the URL is proxied from, and the resolution).

2. **`tests/camera_spec.py`**
   - Add a `CAMERAS["<name>"]` entry with the geometry (`dist_m`,
     `height_m`, `tilt_deg`, `v_fov_deg`, `h_fov_deg`, `stream_w_px`,
     `stream_h_px`, optional `near_m`).
   - Add the operator-verified filter values (`expected_min_area`,
     `expected_max_area`, `expected_min_ratio`, `expected_max_ratio`,
     `expected_threshold`, `expected_min_score`).
   - List the required `zones` and the `detect_stream` / `live_stream`
     go2rtc stream names.

3. **`tests/test-<name>.sh`** (rare)
   - Only needed if the camera has an unusual detection path
     (custom CUDA crop, multiple stream roles split across two
     `ffmpeg.inputs`, etc.). The default L1 + L2 covers the common
     case.

4. **`.gitignore`** (rare)
   - Only needed if the new camera pulls a new model cache or
     trt-engine entry that isn't already excluded.

The standard 4 cameras from the source commit (jardin_arriere,
vue_entree, jardin_devant, piscine_vue_toit) follow this recipe in
commits 3-6 of the integration branch.

## Why the three-layer split?

| Regression class | Caught by | Why? |
|------------------|-----------|------|
| Typo in `config.yml` (`min_are: 124`) | **L1** | yaml.safe_load + key-presence check |
| Filter values diverged from the geometry comment | **L2** | re-derive H_px × W_px × margin from the geometry in the spec, compare to actual |
| `go2rtc.streams` missing a stream that a camera references | **L1** | cross-reference check between `cameras.*.ffmpeg.inputs[*].path` and `go2rtc.streams` |
| Camera added to spec but not to `config.yml` (or vice versa) | **L2** | cross-reference check between the two |
| Filter values match the spec but are wrong in the spec (e.g. wrong margin) | **L2** | geometry-vs-spec bound check (`min_area ∈ [0.3×, 1.0×] × derived area_far`) |
| Container starts but a camera never reaches `detection_fps >= 1` | **L3** | `bring-up.sh --all-cameras --status` runs the 14-step report per camera |
| Camera passed L1 + L2 but fails at the live bring-up (TRT engine build issue, MQTT ACL, recording path) | **L3** | only L3 exercises the live stack |

## L3 — bringing up the full multi-camera stack

L3 is run with `make test-bringup` (or `tests/test-bringup.sh`
directly). It calls:

```sh
./bring-up.sh --status --all-cameras --no-mqtt
```

The `--all-cameras` flag (added in commit 1 of this branch) makes
`bring-up.sh` loop `status_report()` over every camera in `config.yml`
and return 1 if any camera's report has a FAIL step. `--no-mqtt`
prevents the test from publishing to the production MQTT topics.

If `tests/baselines/snapshot.json` exists, L3 also passes
`--snapshot-compare=tests/baselines/snapshot.json` and fails on any
drift from the last known-good state. Regenerate the baseline with:

```sh
make baseline
# or: ./bring-up.sh --all-cameras --snapshot-write=tests/baselines/snapshot.json
```

## Adding a new test layer

If you need an L4 (e.g. ML accuracy regression test, NAS capacity test):

1. Add `tests/test-<name>.sh` with a similar structure (banner,
   preflight, python or bash assertions, TSV temp file for the
   result loop, summary line, exit code).
2. Add a `test-<name>` target to the `Makefile`.
3. Add the layer to the `run_layer` calls in
   [`run-all.sh`](run-all.sh).
4. Update the table at the top of this README.

The TSV-temp-file + python-prints-status approach in the existing
tests is the pattern to follow; the only constraint is the exit code
mapping (0 = all pass, 1 = at least one fail, 2 = prerequisite
missing).


## Pipeline current-state report (live, per camera)

A separate operator tool that walks the **full Frigate pipeline** for each
camera (motion detection → object detection → alert firing) and produces
a timestamped, machine-readable snapshot of the **current state**. Lives
in [`tests/pipeline_report.py`](pipeline_report.py) (data collector) +
[`tests/pipeline-report.sh`](pipeline-report.sh) (human-readable wrapper).

It is intentionally distinct from the L1/L2/L3 test harness:

| Concern | Handled by |
|---|---|
| Regression on the per-camera config (YAML, filter values, zones) | L1 / L2 (`make test`) |
| Bring-up health (container, API, MQTT) | L3 (`make test-bringup`) |
| **Current runtime state of the pipeline** (capture fps, detection fps, recent events, recordings, MQTT, snapshots, semantic-search counts) | **`make pipeline-report`** |

The 14 stages covered are mapped 1:1 to `ARCHITECTURE.md` §3-4:

```
1. Camera identity            8. Person filter (physics)
2. RTSP source                9. Zone matching
3. go2rtc re-stream          10. Event lifecycle
4. Capture ffmpeg             11. MQTT publication
5. Detect ffmpeg              12. Recording (NAS)
6. Motion pre-filter          13. Snapshots
7. Object detector (TRT)      14. Semantic search
```

### Quick start

```sh
# Human-readable report for all cameras (text + JSON on stdout)
make pipeline-report

# One camera
make pipeline-report CAM=allee_sur_le_cote

# Wider event window (default: last 24h)
PIPELINE_REPORT_WINDOW_HOURS=48 make pipeline-report

# Archive the JSON snapshot for later drift analysis
make pipeline-report-snapshot SNAPSHOT_PATH=tests/baselines/pipeline-2026-08-02.json

# Compare against a prior run (exit 1 on drift, 0 on match)
make pipeline-report-diff BASE=tests/baselines/pipeline-2026-08-02.json
```

Or invoke directly (the Makefile is a thin wrapper):

```sh
./tests/pipeline-report.sh                              # text + JSON to stdout
./tests/pipeline-report.sh --camera=vue_entree          # one camera
./tests/pipeline-report.sh --json=path/to/run.json      # also archive
./tests/pipeline-report.sh --json-only                  # JSON only (for piping into jq etc.)
./tests/pipeline-report.sh --diff=path/to/baseline.json # drift against a prior run
./tests/pipeline-report.sh --window-hours=48            # widen the window
./tests/pipeline-report.sh --frigate-url=http://other-host:5000
```

### Output schema (canonical machine-readable)

The bash wrapper always emits the human-readable report. Pass `--json=PATH`
(or `--json-only`) to also archive the structured record:

```json
{
  "schema_version": 1,
  "report_ts_utc": "2026-08-02T15:24:18Z",
  "report_ts_epoch": 1754145858,
  "report_ts_local": "2026-08-02 17:24:18+0200",
  "host": "Calypso",
  "frigate_url": "http://localhost:5000",
  "go2rtc_url":  "http://localhost:1984",
  "mqtt_broker": "192.168.50.125:1883",
  "media_path":  "/mnt/nas/video/frigate_calypso",
  "window_hours": 24,
  "summary": {
    "cameras_total": 8,
    "cameras_ok": 4,
    "cameras_degraded": 1,
    "cameras_fail": 0,
    "cameras_detection_disabled": 3
  },
  "cameras": [
    {
      "camera": "allee_sur_le_cote",
      "verdict": "OK",
      "stages": {
        "1_identity":         { "status": "OK", "ip": "192.168.50.129", ... },
        "2_rtsp_source":      { "status": "OK", "ip": "192.168.50.129", "port": 8554, "rtt_ms": 0.5 },
        "3_go2rtc_restream":  { "status": "OK", "streams": { "allee_sur_le_cote_sub": { "producers": 1, "consumers": 3 } } },
        "4_capture_ffmpeg":   { "status": "OK", "camera_fps": 5.0 },
        "5_detect_process":   { "status": "OK", "detection_fps": 5.0, "process_fps": 5.0 },
        "6_motion_prefilter": { "status": "OK", "threshold": 26, "contour_area": 30, ... },
        "7_object_detection": { "status": "OK", "detectors": { "onnx1": { "inference_speed": 6.8, ... } }, ... },
        "8_person_filter":    { "status": "OK", "values": { "min_area": 124, "max_area": 22500, ... } },
        "9_zone_matching":    { "status": "OK", "zones": [...], "review_alerts_required_zones": ["prive"], ... },
        "10_event_lifecycle": { "status": "OK", "total_in_window": 42, "median_top_score": 0.78, "score_distribution": {...}, "last_event": {...}, "last_5_events": [...] },
        "11_mqtt_publish":    { "status": "OK", "broker": "192.168.50.125:1883", "rtt_ms": 0.4, ... },
        "12_recording":       { "status": "OK", "files_in_window": 12, "size_mb_in_window": 234.5, "oldest_recording_ts": "...", "newest_recording_ts": "..." },
        "13_snapshots":       { "status": "OK", "files_in_window": 42, "newest_snapshot_ts": "..." },
        "14_semantic_search": { "status": "OK", "model": "jinaai/jina-clip-v1", "image_embedding_speed_ms": 50, "image_embedding_total": 1234 }
      }
    }
  ]
}
```

### Status semantics

| Status | Meaning | Counts toward verdict? |
|---|---|---|
| `OK` | stage is healthy | no |
| `WARN` | stage is up but a sub-metric is degraded (e.g. `process_fps` instead of `detection_fps`) | yes (DEGRADED) |
| `FAIL` | stage is broken (RTSP unreachable, /api/stats missing, broker unreachable) | yes (FAIL) |
| `SKIP` | stage was skipped because a prior stage failed | implicit (FAIL) |
| `N/A` | stage is intentionally not applicable (e.g. detection-disabled indoor camera for stages 6-9) | no |

Per-camera verdict:

| Verdict | Trigger |
|---|---|
| `OK` | no stage has WARN or FAIL |
| `DEGRADED` | at least one stage has WARN, none have FAIL |
| `FAIL` | at least one stage has FAIL |
| `DETECTION_DISABLED` | per-camera `detect.enabled: false` (the 3 indoor Tapo cameras) |

### Drift detection (--diff)

`--diff=BASELINE.json` (or `make pipeline-report-diff BASE=path.json`) walks
the per-camera, per-stage status fields in the current run and the baseline,
and prints a human-readable diff:

```
~ allee_sur_le_cote.verdict: OK -> DEGRADED
~ allee_sur_le_cote.5_detect_process: OK -> WARN
  allee_sur_le_cote: events in 24h window 42 -> 7
  allee_sur_le_cote: recordings in 24h window 12 -> 2
```

Exit 0 on match, 1 on any drift. Use this for:

- After a config change (does detection still fire on every camera?)
- After a Frigate+ retrain (does the new plus:// model reduce the 0.30-0.55 score band?)
- After a host / NAS outage (did the system self-recover?)
- Quarterly / annual regression: keep a known-good baseline and diff against the current run.

### Why a separate tool (vs an L4 test)?

The L1/L2/L3 framework answers "is the config / bring-up correct?". The
pipeline-report answers "is the live runtime working right now?". The two
concerns have different cadences:

- L1/L2 run on every commit (CI).
- L3 runs before merging a batch of camera commits (operator).
- pipeline-report runs on demand, on a schedule, or after any change
  (operator / on-call). It is intentionally a *snapshot* — the JSON is
  designed to be archived and diffed, not pass/fail'd on each run.

### Dependencies

`python3` + `PyYAML` (already a hard dep of the test harness). The script
hits the live Frigate + go2rtc + MQTT APIs; if the stack is not yet up,
per-stage statuses read `N/A` with a `reason` — the script never modifies
any state and never fails hard on a missing stack (it exits 1 only when
a per-camera verdict is `FAIL` or `DEGRADED`).

### Adding a new stage

If you add a new pipeline stage to `ARCHITECTURE.md` (or a new field that
should be tracked per camera):

1. Add a `stage_<name>(...)` function to `tests/pipeline_report.py` returning
   `{ "status": "OK|WARN|FAIL|N/A", ... }`.
2. Wire it into `collect_for_camera()` in the same file, including the
   verdict propagation rules.
3. Add a `print f"  {sc}[{st['status']:4s}]{NC} N. <name>"; ...` block to
   `print_report()` in `tests/pipeline-report.sh`.
4. Bump `schema_version` in the python module's `main()`.

Keep the JSON shape flat: `cameras[i].stages["<n>_<short>"]` so the diff
remains a flat key comparison.


## Test-walk event log (chronological, sorted by motion start_time)

Distinct from the per-camera state report: the state report answers
"is the system healthy right now?", the **walk report** answers
"what happened during my test walk?". The walk report is the
operator's correlation tool — walk in front of the cameras, then
re-run the report and the events that triggered are listed in
strict chronological order with millisecond timestamps.

The walk report is a *time-windowed* view of every event whose
`start_time` falls in `[walk_start, walk_end]`. The walk window
is the operator-supplied test-walk duration. Every event in the
window is shown, sorted by `start_time` ascending. Per event:

| Field | Source | Why it matters |
|---|---|---|
| `start_utc` / `start_local` | Frigate `event.start_time` | The closest proxy Frigate exposes for "motion detection fired". Motion pre-filter typically fires 50-200 ms before the event is created. |
| `start_epoch` | (float) | For scripting: `date -d @<start_epoch>` or any timestamp math. |
| `end_utc` / `duration_s` | Frigate `event.end_time - start_time` | How long the person/object stayed in the FOV. |
| `camera`, `label`, `top_score` | Frigate `/api/events` | What the detector saw. |
| `zones` | Frigate `/api/events` | Which alert/detection zones the bbox overlapped. |
| `has_clip` / `has_snapshot` | Frigate `/api/events` | Whether the recording and snapshot were written. |
| `recording_path` | filesystem scan | The exact path on the NAS so you can `vlc` it directly. |
| `recording_size_bytes` | `Path.stat().st_size` | Sanity check the recording is non-empty. |
| `snapshot_url` | `$FRIGATE_URL/api/events/<id>/snapshot.jpg` | Copy-paste into a browser to see the best-frame snapshot. |

### Quick start

```sh
# Last 10 minutes (most common test-walk workflow)
make walk WALK_MINUTES=10

# Exact walk window (you started walking at 15:00, stopped at 15:05)
make walk WALK_START=2026-08-02T15:00:00+02:00 WALK_END=2026-08-02T15:05:00+02:00

# Just the start, end defaults to now
make walk WALK_START=2026-08-02T15:00:00+02:00

# Walk in front of one camera only
make walk WALK_MINUTES=5 CAM=allee_sur_le_cote

# Archive the JSON for later drift analysis
make walk-snapshot WALK_MINUTES=30 OUT=tests/baselines/walk-2026-08-02.json
```

Or invoke directly (the Makefile is a thin wrapper):

```sh
./tests/pipeline-report.sh --walk-minutes=10
./tests/pipeline-report.sh --walk-start=2026-08-02T15:00:00Z --walk-end=2026-08-02T15:10:00Z
./tests/pipeline-report.sh --walk-start=2026-08-02T15:00:00Z            # end defaults to now
./tests/pipeline-report.sh --walk-start=1754145000 --walk-end=1754145600  # epoch also accepted
./tests/pipeline-report.sh --walk-minutes=5 --json=path/to/walk.json      # archive
```

### Timestamp precision

Walk timestamps are emitted at **millisecond precision** (UTC and local).
The exact epoch float is also exposed as `start_epoch` / `end_epoch` for
scripting (e.g. for joining with the operator's own walk log). The
report's header shows the walk window in both UTC and local time, so the
operator can correlate against their watch / phone / notebook entry.

### Recording + snapshot cross-reference

Every event in the walk list is cross-referenced against the NAS to
confirm whether the recording was actually written (Frigate sets
`has_clip=True` only when the event ends AND the .mp4 is on disk) and
where the recording lives. The recording file path follows the
canonical Frigate 0.17 layout:

```
$MEDIA_PATH/recordings/<YYYY-MM-DD>/<HH>/<event_id>.mp4
```

The snapshot URL is always synthesised (`$FRIGATE_URL/api/events/<id>/snapshot.jpg`)
because Frigate's snapshot endpoint is the canonical way to fetch the
best-frame image for a given event — copy-pasteable into a browser or
passable to `curl -o`.

### When no events fire in the walk window

The walk report explicitly distinguishes "no events fired" from "Frigate
was down" — if the events list is empty, the report prints:

```
  No events fired in the walk window.
  possible causes:
    - the test walk was outside the cameras' FOV / motion zones
    - the window does not overlap with any activity
    - the per-camera person filter rejected the detections
  suggested next steps:
    1. confirm Frigate was up the whole time: curl -fsS http://localhost:5000/api/stats | jq
    2. widen the window: --walk-minutes=120
    3. check the motion pre-filter threshold: config.yml motion.threshold
```

The walk window's start and end timestamps are echoed regardless, so
the operator can see what window was inspected.

### State report vs walk report

| Concern | State report | Walk report |
|---|---|---|
| Question | "Is the pipeline healthy right now?" | "What fired during my test walk?" |
| Output | Per-camera, 14-stage health matrix | Per-event chronological log |
| Time basis | Current snapshot (--window-hours back) | Explicit walk window (--walk-start, --walk-end) |
| Sort | Per camera, stages in pipeline order | Chronological by event start_time |
| Use case | Operational health, alerting | Correlate a physical test walk with events |
| Output JSON `mode` | `state` | `walk` |
| CLI | `make pipeline-report` | `make walk` |

Both reports use the same Frigate / go2rtc / MQTT / NAS APIs and write
the canonical JSON envelope (`schema_version=2`) — the `mode` field
distinguishes them. The diff mode (`make pipeline-report-diff`) works
on any `state`-mode snapshot; the walk mode is its own archival unit.

### Walk + state combined

A common workflow is: do a test walk, then run both reports:

```sh
# 1. run the test walk
make walk WALK_MINUTES=10                            # chronological event log

# 2. archive the state report at the same moment for drift analysis
make pipeline-report-snapshot SNAPSHOT_PATH=tests/baselines/state-2026-08-02T15:10.json
make walk-snapshot         WALK_MINUTES=10 OUT=tests/baselines/walk-2026-08-02T15:10.json
```

The two snapshots, archived at the same wall-clock moment, give a
complete before/after picture: the state report says "all 14 stages
are OK across all cameras", the walk report says "and here are the
3 events that actually fired in the last 10 min, in chronological
order, with their recording paths".


## Per-event pipeline trace (the deep view)

For every event in the walk window, the walk report emits a **9-stage
per-event pipeline trace** that re-derives each filter / gate the event
went through, against the actual event data and the camera's config.
This is the view the operator wants when they ask *"why did this event
fire as an alert and not as a detection?"* or *"why was the motion
filter happy but the person filter rejected the bbox?"*.

The 9 stages of the trace (in pipeline order, mapped to ARCHITECTURE.md §4):

```
1. Motion pre-filter     threshold + contour_area + the motion region
2. Object detector (TRT) model + scores (frame, event-top)
3. Bounding box          normalized + pixel coords + area + ratio + centroid
4. Person filter         the 6 iter0 checks (min_area, max_area,
                         min_ratio, max_ratio, threshold, min_score)
5. Zone matching         defined zones + bbox centroid + zones hit
6. Review gate           alerts_required_zones + Frigate's max_severity
                         -> ALERT / detection classification
7. Snapshot              has_snapshot (best frame captured?)
8. Recording             has_clip (mp4 on disk?)
9. MQTT publish          LIKELY PUBLISHED (event lifecycle was emitted)
```

For each stage the report shows the **actual value**, the **configured
bound**, the **PASS / FAIL verdict**, and a **human-readable reason**
("`7134 >= 124`", "`1.061 in [1.0, 4.0]`", "`max_severity=alert from
Frigate`", etc.). This is exact, not heuristic — the same boolean
the Frigate detector pipeline computed.

### Example

For a person detected at 14:42:02 on `jardin_devant` with `top_score=0.949`:

```
[1] 2026-08-02T14:42:02Z  jardin_devant  label=person  top_score=0.949  duration_s=38.401  -> ALERT
    event id = 1785681722.672431-np7w8e
    |- STAGE 1: Motion pre-filter  [PASS]
    |   threshold=26  contour_area=30
    |   motion_region (normalized): [0.518, 0.012, 0.208, 0.741]
    |   event was created => motion pre-filter fired with a region above threshold
    |- STAGE 2: Object detector (TRT)  [PASS]
    |   model = plus://c1aa04320f389aa6c7702bf9ddd3fe6d
    |   score (frame) = 0.957   score (event top) = 0.949
    |   detector returned a bounding box (data.box present)
    |- STAGE 3: Bounding box  [PASS]
    |   normalized [x, y, w, h] = [0.586, 0.356, 0.057, 0.190]
    |   pixel      [x, y, w, h] = [900, 154, 87, 82]
    |   area = 7134 px^2   ratio (W/H) = 1.061   centroid = [0.614, 0.451]
    |- STAGE 4: Person filter (physics)  [PASS]   all 6 checks passed
    |   [PASS] min_area     bound=      72  actual=      7134  (7134 >= 72)
    |   [PASS] max_area     bound=   13500  actual=      7134  (7134 <= 13500)
    |   [PASS] min_ratio    bound=     1.0  actual=     1.061  (1.061 >= 1.0)
    |   [PASS] max_ratio    bound=     4.0  actual=     1.061  (1.061 <= 4.0)
    |   [PASS] threshold    bound=    0.55  actual=     0.949  (0.949 >= 0.55)
    |   [PASS] min_score    bound=    0.45  actual=     0.949  (0.949 >= 0.45)
    |- STAGE 5: Zone matching  [no zone hit]
    |   defined: ['prive', 'rodage']
    |   bbox centroid (normalized): [0.614, 0.451]
    |   zones hit: -
    |- STAGE 6: Review gate  [ALERT]
    |   alerts_required_zones     = ['prive']
    |   detections_required_zones = ['rodage']
    |   event zones               = -
    |   Frigate max_severity      = alert
    |   event zones (none) is-subset-of alerts_required_zones ['prive'] => ALERT
    |- STAGE 7: Snapshot  [WRITTEN]  has_snapshot=True (best frame captured at peak score)
    |- STAGE 8: Recording  [NOT WRITTEN]  has_clip=False (event in progress, or retention already pruned)
    '- STAGE 9: MQTT publish  [LIKELY PUBLISHED]  event lifecycle start/update/end was published on calypso_frigate/events; classification: ALERT
        recording:  (not on disk yet - has_clip=False)
        snapshot:   http://localhost:5000/api/events/1785681722.672431-np7w8e/snapshot.jpg
```

Notice how the trace lets the operator verify each gate:

- The bbox area (7134 px²) sits comfortably in the iter0 window `[72, 13500]`
  for `jardin_devant` (the iter0 contract for that camera).
- The ratio (1.061) is within the `[1.0, 4.0]` band.
- The top_score (0.949) exceeds both `threshold=0.55` and `min_score=0.45`.
- The bbox centroid is at `[0.614, 0.451]` — outside both `prive` and
  `rodage` polygons (those cover the lower half of the frame), so the
  event is **not** in a required alert zone by geometry.
- Frigate's `max_severity=alert` nevertheless promoted it — this is
  because `vue_entree` and the all-camera default policy
  (`review.detections.required_zones: []`) treats all detections on
  some cameras as alerts. The trace surfaces this discrepancy so the
  operator can decide whether the policy is what they want.

### Summary table column: classification

The walk summary table also has a new `class` column showing the
alert / detection classification for each event at a glance:

```
    #  start_utc (ms)        camera           label   score   dur_s  class         clip  snap
    1  2026-08-02T14:42:02Z  jardin_devant    person  0.95    38.40  ALERT         .     Y
    2  2026-08-02T14:42:03Z  allee_sur_le_cote person  0.83     8.86  ALERT         .     Y
    3  2026-08-02T14:42:36Z  allee_sur_le_cote person  0.94     7.59  ALERT         .     Y
    4  2026-08-02T14:42:45Z  allee_sur_le_cote person  0.96    12.72  ALERT         .     Y
    5  2026-08-02T14:56:01Z  allee_sur_le_cote person  0.97    21.43  ALERT         .     Y
    6  2026-08-02T15:03:45Z  cuisine          speech  0.89    35.01  detection     .     Y
    7  2026-08-02T15:11:33Z  allee_sur_le_cote person  0.97    19.44  ALERT         .     Y
    8  2026-08-02T15:18:20Z  jardin_arriere   person  0.63     2.42  ALERT         .     Y
    9  2026-08-02T16:29:05Z  allee_sur_le_cote person  0.62     9.26  ALERT         .     Y
```

### JSON schema (per event)

```json
{
  "id": "1785681722.672431-np7w8e",
  "camera": "jardin_devant",
  "start_utc": "2026-08-02T14:42:02.672Z",
  "start_epoch": 1785681722.672431,
  "end_utc": "2026-08-02T14:42:41.073Z",
  "duration_s": 38.401,
  "label": "person",
  "top_score": 0.949,
  "zones": [],
  "has_clip": false,
  "has_snapshot": true,
  "recording_path": null,
  "snapshot_url": "http://localhost:5000/api/events/.../snapshot.jpg",
  "trace": {
    "motion":        { "threshold": 26, "contour_area": 30, "motion_region_norm": [0.518, 0.012, 0.208, 0.741], "verdict": "PASS", "reason": "..." },
    "detector":      { "model_path": { "path": "plus://c1aa..." }, "score_frame": 0.957, "score_event": 0.949, "verdict": "PASS", "reason": "..." },
    "bbox":          { "norm": [...], "px": [900, 154, 87, 82], "area_px2": 7134, "ratio": 1.061, "centroid_norm": [...], "verdict": "PASS", "reason": "..." },
    "person_filter": {
      "verdict": "PASS", "reason": "all 6 checks passed",
      "checks": {
        "min_area":  { "bound": 72,    "actual": 7134, "verdict": "PASS", "reason": "7134 >= 72" },
        "max_area":  { "bound": 13500, "actual": 7134, "verdict": "PASS", "reason": "7134 <= 13500" },
        "min_ratio": { "bound": 1.0,   "actual": 1.061, "verdict": "PASS", "reason": "1.061 >= 1.0" },
        "max_ratio": { "bound": 4.0,   "actual": 1.061, "verdict": "PASS", "reason": "1.061 <= 4.0" },
        "threshold": { "bound": 0.55,  "actual": 0.949, "verdict": "PASS", "reason": "0.949 >= 0.55" },
        "min_score": { "bound": 0.45,  "actual": 0.949, "verdict": "PASS", "reason": "0.949 >= 0.45" }
      }
    },
    "zones":         { "defined": ["prive", "rodage"], "bbox_centroid_norm": [0.614, 0.451], "hit": [], "verdict": "no zone hit" },
    "review_gate":   { "alerts_required_zones": ["prive"], "detections_required_zones": ["rodage"], "event_zones": [], "frigate_max_severity": "alert", "classification": "ALERT", "verdict": "ALERT", "reason": "..." },
    "snapshot":      { "written": true,  "verdict": "WRITTEN",    "reason": "has_snapshot=True ..." },
    "recording":     { "written": false, "verdict": "NOT WRITTEN", "reason": "has_clip=False ..." },
    "mqtt":          { "verdict": "LIKELY PUBLISHED", "reason": "..." }
  }
}
```

### When the trace is the most useful

| Question | Where to look |
|---|---|
| "Did the person filter reject anything I expected to detect?" | Stage 4 — each of the 6 checks shows PASS/FAIL with the bound and actual value |
| "Why is this event an ALERT and not a detection?" | Stage 6 — review gate shows the required zones, the event zones, and Frigate's max_severity |
| "Was the recording written to disk for this event?" | Stage 8 — has_clip directly from Frigate + the on-disk path (or "(not on disk yet)") |
| "What's the actual bbox area on the camera's detect frame?" | Stage 3 — normalized + pixel coordinates + area in px² |
| "Did the motion pre-filter fire? Where was the motion?" | Stage 1 — the motion region in normalized coords; the existence of the event is the proof the pre-filter fired |
| "Is the detector returning low-confidence scores?" | Stage 2 — score (frame) vs score (event top); the gap tells you if the model was uncertain |
| "Where exactly did the bbox centroid fall in the FOV?" | Stage 3 (centroid) + Stage 5 (zone hit list) |
