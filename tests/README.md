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
