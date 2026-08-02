# ==============================================================================
# Makefile — Frigate NVR test suite + bring-up shortcuts
# ==============================================================================
# Run the multi-camera test suite (L1 + L2 + optional L3).
#
#   make test            — L1 + L2 only (CI-safe, ~10 s, no Frigate required)
#   make test-bringup    — L1 + L2 + L3 (operator's pre-merge gate, ~1-4 min)
#   make test-config     — L1 only
#   make test-math       — L2 only
#   make test-bringup-only — L3 only (skip L1/L2, useful when re-running a
#                          failed L3 after a manual fix)
#   make list-cameras    — print camera names from config.yml
#   make baseline        — regenerate tests/baselines/snapshot.json
#                          (run this on a known-good multi-camera bring-up)
#
# Iter0 default manager (see tests/iter0.py — the spec in
# tests/camera_spec.py is the single source of truth for the physics-
# derived iter0 values, and this tool writes them back to config.yml):
#
#   make iter0-show CAM=<name>     print the iter0 spec for one camera
#   make iter0-diff CAM=<name>     show config.yml vs iter0 (per key)
#   make iter0-diff-all            show config.yml vs iter0 for ALL cameras
#   make iter0-revert CAM=<name>   rewrite cameras.<cam> from the spec
#                                  (prompts for confirmation)
#   make iter0-revert-all         rewrite ALL cameras from the spec
#                                  (prompts for confirmation)
#   make iter0-revert-y CAM=<name> rewrite one camera, no prompt
#                                  (for scripts)
#
# All targets are thin wrappers around the bash scripts in tests/ and
# the tests/iter0.py tool. The scripts themselves contain the logic;
# the Makefile just exposes the common entry points.
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help test test-bringup test-config test-math test-bringup-only list-cameras baseline \
        evaluate \
        pipeline-report pipeline-report-snapshot pipeline-report-diff \
        walk walk-snapshot \
        iter0-show iter0-diff iter0-diff-all iter0-revert iter0-revert-all iter0-revert-y

help:
	@echo "Frigate NVR — make targets"
	@echo ""
	@echo "  make test                L1 + L2 (fast, no Frigate, no GPU)"
	@echo "  make test-bringup        L1 + L2 + L3 (operator's pre-merge gate)"
	@echo "  make test-config         L1 only (YAML parse + structure)"
	@echo "  make test-math           L2 only (math derivation + spec match)"
	@echo "  make test-bringup-only   L3 only (skip L1/L2)"
	@echo "  make list-cameras        print camera names from config.yml"
	@echo "  make baseline            regenerate tests/baselines/snapshot.json"
	@echo "  make evaluate            per-camera Frigate+ training-need verdict (live, requires Frigate)"
	@echo ""
	@echo "  Pipeline current-state report (per camera, live; see tests/pipeline-report.sh):"
	@echo "  make pipeline-report                       per-camera report, text + JSON to stdout"
	@echo "  make pipeline-report-snapshot SNAPSHOT_PATH=path.json   save JSON to file"
	@echo "  PIPELINE_REPORT_WINDOW_HOURS=48 make pipeline-report    widen the event window"
	@echo "  make pipeline-report-diff BASE=path.json    diff current vs a prior run (exit 1 on drift)"
	@echo ""
	@echo "  Test-walk event log (chronological, sorted by motion-event start_time):"
	@echo "  make walk WALK_MINUTES=30                  chronological event log for the last 30 min"
	@echo "  make walk WALK_START=2026-08-02T15:00:00Z WALK_END=...   exact walk window"
	@echo "  make walk-snapshot WALK_MINUTES=30 OUT=path.json           save JSON to file"
	@echo "  The walk view shows every event that fired in the window, sorted by"
	@echo "  event start_time (= motion detection), with exact epoch + ISO ms timestamps, recording path, and snapshot URL.
	@echo ""
	@echo "  Iter0 default manager (tests/iter0.py, spec = tests/camera_spec.py):"
	@echo "  make iter0-show CAM=<name>     show the iter0 spec for one camera"
	@echo "  make iter0-diff CAM=<name>     diff config.yml vs iter0 for one camera"
	@echo "  make iter0-diff-all            diff config.yml vs iter0 for all cameras"
	@echo "  make iter0-revert CAM=<name>   revert one camera to iter0 (prompts)"
	@echo "  make iter0-revert-all          revert all cameras to iter0 (prompts)"
	@echo "  make iter0-revert-y CAM=<name> revert one camera, no prompt"
	@echo "  make help                      this help"
	@echo ""
	@echo "  Iter0 dependency: pip3 install --user ruamel.yaml"
	@echo ""

test: test-config test-math

test-bringup: test test-bringup-only

test-config:
	@tests/test-config.sh

test-math:
	@tests/test-math.sh

test-bringup-only:
	@tests/test-bringup.sh

list-cameras:
	@./bring-up.sh --list-cameras

# ------------------------------------------------------------------------------
# evaluate — per-camera Frigate+ training-need evaluator (live, requires Frigate)
# ------------------------------------------------------------------------------
# Pulls recent events from the running Frigate API, computes the per-camera
# top_score distribution, and prints a per-camera verdict (OK / borderline /
# TRAINING NEEDED). Use this to decide which cameras need their iter0 contract
# relaxed to capture more Frigate+ training data. See tests/wait-and-evaluate.sh
# for the verdict rule and tests/camera_spec.py for the training_collection_mode
# flag that suppresses the L2 spec-vs-actual match for cameras in that mode.
#
#   make evaluate                    # all cameras from config.yml
#   make evaluate CAMS=vue_entree    # specific cameras (space-separated)
#   FRIGATE_URL=http://frigate:5000 make evaluate   # remote Frigate
# ------------------------------------------------------------------------------
evaluate:
	@tests/wait-and-evaluate.sh $(CAMS)

baseline:
	@mkdir -p tests/baselines
	@echo "Regenerating tests/baselines/snapshot.json (run a full bring-up first):"
	@echo "  ./bring-up.sh --all-cameras --snapshot-write=tests/baselines/snapshot.json"
	@./bring-up.sh --all-cameras --snapshot-write=tests/baselines/snapshot.json

# ------------------------------------------------------------------------------
# iter0 default manager (tests/iter0.py)
# ------------------------------------------------------------------------------
# The spec in tests/camera_spec.py is the single source of truth for the
# physics-derived iter0 values; these targets let you inspect them, see
# what's drifted in config.yml, and revert one or all cameras.
#
# Dependency: pip3 install --user ruamel.yaml (comment-preserving YAML).

ifndef CAM
iter0-show iter0-diff iter0-revert iter0-revert-y:
	@echo "ERROR: CAM=<name> is required (e.g. CAM=allee_sur_le_cote)" >&2
	@echo "Available cameras:" >&2
	@./bring-up.sh --list-cameras 2>/dev/null | sed 's/^/  /' >&2 || true
	@exit 1
endif

iter0-show:
	@python3 tests/iter0.py show $(CAM)

iter0-diff:
	@python3 tests/iter0.py diff $(CAM)

iter0-diff-all:
	@for c in $$(./bring-up.sh --list-cameras 2>/dev/null || python3 -c "import sys; sys.path.insert(0, 'tests'); from camera_spec import CAMERAS; print('\n'.join(CAMERAS))"); do \
	    python3 tests/iter0.py diff "$$c" || true; \
	done

iter0-revert:
	@python3 tests/iter0.py revert $(CAM)

iter0-revert-all:
	@python3 tests/iter0.py revert --all 2>/dev/null \
		|| python3 tests/iter0.py revert all

iter0-revert-y:
	@python3 tests/iter0.py revert --yes $(CAM)

# ------------------------------------------------------------------------------
# pipeline-report — per-camera CURRENT PIPELINE STATE assessment (live)
# ------------------------------------------------------------------------------
# For each camera in config.yml, walks the 14-stage Frigate pipeline (see
# ARCHITECTURE.md §3-4) from physical RTSP source through to MQTT event
# publication, and produces a timestamped, human-readable report + a
# machine-readable JSON snapshot.
#
#   make pipeline-report                                  # text + JSON to stdout
#   make pipeline-report-snapshot SNAPSHOT_PATH=path.json # text + JSON to file
#   make pipeline-report-diff BASE=path.json              # diff vs prior run
#                                                          (exit 0 on match, 1 on drift)
#   PIPELINE_REPORT_WINDOW_HOURS=48 make pipeline-report  # widen the window
#   make pipeline-report CAM=allee_sur_le_cote            # one camera
#
# Dependencies: python3 + PyYAML (same as the rest of the test harness).
# The script hits the live Frigate API; for a stack that is not yet up,
# the per-stage status reads NA with a reason — the script does NOT
# modify any state.  See tests/pipeline-report.sh --help for the full CLI.
# ------------------------------------------------------------------------------
CAM_OPT ?= $(if $(CAM),--camera=$(CAM),)

pipeline-report:
	@tests/pipeline-report.sh --window-hours=$(PIPELINE_REPORT_WINDOW_HOURS) $(CAM_OPT)

pipeline-report-snapshot:
	@if [ -z "$(SNAPSHOT_PATH)" ]; then \
	    echo "ERROR: SNAPSHOT_PATH=<path> is required (e.g. make pipeline-report-snapshot SNAPSHOT_PATH=tests/baselines/pipeline-run.json)"; \
	    exit 2; \
	fi
	@mkdir -p $$(dirname "$(SNAPSHOT_PATH)")
	@tests/pipeline-report.sh --window-hours=$(PIPELINE_REPORT_WINDOW_HOURS) $(CAM_OPT) --json="$(SNAPSHOT_PATH)"

pipeline-report-diff:
	@if [ -z "$(BASE)" ]; then \
	    echo "ERROR: BASE=<path.json> is required (e.g. make pipeline-report-diff BASE=tests/baselines/pipeline-run.json)"; \
	    exit 2; \
	fi
	@tests/pipeline-report.sh --window-hours=$(PIPELINE_REPORT_WINDOW_HOURS) $(CAM_OPT) --diff="$(BASE)"

# ------------------------------------------------------------------------------
# walk / walk-snapshot — chronological TEST WALK event log (live, live-sorted)
# ------------------------------------------------------------------------------
# Use case: do a physical test walk in front of one or more cameras, then run
#   make walk WALK_MINUTES=10
# to get a chronological table of every event that fired in the last 10
# minutes — sorted by event start_time (the closest proxy for motion
# detection that Frigate exposes), with exact epoch + ISO millisecond
# timestamps, the recording file path on the NAS, and a snapshot URL.
#
# Variables:
#   WALK_START      ISO 8601 or epoch; start of the walk window
#   WALK_END        ISO 8601 or epoch; end of the walk window (default: now)
#   WALK_MINUTES    end - start; convenience when WALK_START is omitted
#   CAM             restrict to a single camera (default: all)
#   OUT             JSON output path (walk-snapshot only)
#
#   make walk WALK_MINUTES=30
#   make walk WALK_START=2026-08-02T15:00:00Z WALK_END=2026-08-02T15:10:00Z
#   make walk WALK_START=2026-08-02T15:00:00Z
#   make walk-snapshot WALK_MINUTES=30 OUT=tests/baselines/walk-2026-08-02.json
#
# The walk view is a DIFFERENT report from `make pipeline-report`: the state
# report answers "is the system healthy right now?"; the walk report
# answers "what happened during my test walk?". See tests/README.md
# "Test-walk event log" for the full schema.
# ------------------------------------------------------------------------------
WALK_PY_ARGS := $(if $(WALK_START),--walk-start=$(WALK_START)) $(if $(WALK_END),--walk-end=$(WALK_END)) $(if $(WALK_MINUTES),--walk-minutes=$(WALK_MINUTES)) $(if $(CAM),--camera=$(CAM))

walk:
	@tests/pipeline-report.sh $(WALK_PY_ARGS)

walk-snapshot:
	@if [ -z "$(OUT)" ]; then \
	    echo "ERROR: OUT=<path.json> is required (e.g. make walk-snapshot WALK_MINUTES=30 OUT=tests/baselines/walk.json)"; \
	    exit 2; \
	fi
	@mkdir -p $$(dirname "$(OUT)")
	@tests/pipeline-report.sh $(WALK_PY_ARGS) --json="$(OUT)"

