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
#   make help            — this help
#
# All targets are thin wrappers around the bash scripts in tests/.  The
# scripts themselves contain the test logic, the Makefile just exposes
# the common entry points.
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

.PHONY: help test test-bringup test-config test-math test-bringup-only list-cameras baseline

help:
	@echo "Frigate NVR — make targets"
	@echo ""
	@echo "  make test              L1 + L2 (fast, no Frigate, no GPU)"
	@echo "  make test-bringup      L1 + L2 + L3 (operator's pre-merge gate)"
	@echo "  make test-config       L1 only (YAML parse + structure)"
	@echo "  make test-math         L2 only (math derivation + spec match)"
	@echo "  make test-bringup-only L3 only (skip L1/L2)"
	@echo "  make list-cameras      print camera names from config.yml"
	@echo "  make baseline          regenerate tests/baselines/snapshot.json"
	@echo "  make help              this help"
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
