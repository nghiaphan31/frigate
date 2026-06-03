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
