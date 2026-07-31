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
        evaluate phase5 phase5-syntactic \
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
	@echo "  make phase5              per-camera threshold re-derivation (live, requires Frigate; see plans/PLAN-2026-07-31-phase5.md)"
	@echo "  make phase5-syntactic    fast syntax-check of tests/phase5-derive-thresholds.py (no Frigate)"
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

# phase5-syntactic is a hard prerequisite of `test` so a syntax error
# in the Phase 5 decision-matrix code is caught by CI before the
# operator runs a 24-48h soak.
test: phase5-syntactic test-config test-math

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

# ------------------------------------------------------------------------------
# phase5 — per-camera threshold re-derivation against the new model
# ------------------------------------------------------------------------------
# Companion to plans/PLAN-2026-07-31-phase5.md and the Phase 4 commit
# (post-iter1). Pulls the per-camera top_score distribution from the
# running Frigate API and applies a per-camera decision matrix to
# recommend a new (threshold, min_score) pair relative to the iter0
# contract. Operator reviews, updates tests/camera_spec.py, then runs
# `make iter0-revert-y CAM=<name>` to apply.
#
# Requires the live Frigate stack to be on the iter0 config for at
# least 24-48h (otherwise the script returns INSUFFICIENT DATA).
#
#   make phase5                    # all 5 outdoor cameras, last 10000 events
#   make phase5 CAMS=vue_entree    # one camera
#   make phase5 JSON=out/phase5.json   # also write raw JSON
#   FRIGATE_URL=http://frigate:5000 make phase5
# ------------------------------------------------------------------------------
phase5:
	@tests/phase5-derive-thresholds.py $(CAMS) $(if $(JSON),--json=$(JSON),)

# phase5-syntactic — fast no-Frigate syntax check, suitable for CI
# ------------------------------------------------------------------------------
# Runs python3 -m py_compile on the script so a syntax error in the
# decision-matrix code is caught before the operator pulls the trigger
# on a 24-48h soak.
# ------------------------------------------------------------------------------
phase5-syntactic:
	@python3 -m py_compile tests/phase5-derive-thresholds.py && echo "phase5-derive-thresholds.py: syntax OK"

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
