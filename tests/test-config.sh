#!/usr/bin/env bash
# ==============================================================================
# tests/test-config.sh — L1 test: YAML parse + structure
# ==============================================================================
# Catches: new camera is malformed; required sections missing; typos in keys;
# go2rtc.streams out of sync with cameras: references.
#
# Layer philosophy (see tests/README.md for the full 3-layer model):
#   L1  ≈ 5 s    — fast, no Frigate running, no GPU
#   L2  ≈ 5 s    — math re-derivation, no Frigate running
#   L3  ≈ 1-4 m  — live bring-up via bring-up.sh --all-cameras --status
#
# Exit codes:
#   0  all assertions pass
#   1  one or more structural assertions fail
#   2  prerequisite missing (python3, PyYAML, config.yml)
# ==============================================================================
set -euo pipefail

# Always run from the repo root so relative paths to config.yml work
cd "$(dirname "$0")/.."

# --- Colours (suppressed when stdout is not a TTY) ---
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; NC=''
fi

# --- Counters ---
L1_OK=0
L1_FAIL=0
L1_TOTAL=0

# --- Helpers ---
ok()   { L1_OK=$((L1_OK+1)); L1_TOTAL=$((L1_TOTAL+1)); printf "  %b[ OK ]%b  %s\n"  "$GRN" "$NC" "$1"; }
fail() { L1_FAIL=$((L1_FAIL+1)); L1_TOTAL=$((L1_TOTAL+1)); printf "  %b[FAIL]%b  %s\n"  "$RED" "$NC" "$1"; if [ -n "${2:-}" ]; then printf "              %bFIX:%b %s\n" "$YEL" "$NC" "$2"; fi; }

# --- Preflight: python3 + PyYAML + config.yml ---
[ -f config.yml ] || { echo "config.yml not found in $(pwd)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not in PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null \
    || { echo "PyYAML not installed; install with: pip3 install --user pyyaml" >&2; exit 2; }

# --- Pretty banner ---
echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  L1 — YAML PARSE + STRUCTURE"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)"
echo "═══════════════════════════════════════════════════════════════════════"

# --- Run all assertions in a single python invocation (faster, atomic) ---
# Python prints one line per assertion in the format:
#   OK  <message>
#   FAIL <message> | <remediation>
# Capture all assertion lines from python into a temp file (so the
# while-loop's variable updates survive — `| while` would fork a subshell
# and drop the counter increments). Process substitution `done < <(...)`
# also works on bash 4+, but the temp-file approach is more portable
# across the older bash on Debian 11 (Calypso's host OS).
L1_OUT=$(mktemp --suffix=.tsv)
trap 'rm -f "$L1_OUT"' EXIT
python3 - "$L1_OUT" <<'PY' >/dev/null
import sys, yaml

results = []  # list of (status, message, remediation)
out_path = sys.argv[1]

def assert_(cond, msg, fix=""):
    if cond:
        results.append(("OK", msg, ""))
    else:
        results.append(("FAIL", msg, fix))

# --- Load config.yml ---
try:
    with open("config.yml") as f:
        d = yaml.safe_load(f)
    assert_(d is not None, "config.yml parses to a non-None document")
except yaml.YAMLError as e:
    with open(out_path, "w") as out:
        out.write(f"FAIL\tconfig.yml fails YAML parse\tfix syntax error near: {e}\n")
    sys.exit(0)

if d is None:
    with open(out_path, "w") as out:
        out.write("FAIL\tconfig.yml is empty (no YAML document)\t\n")
    sys.exit(0)

# --- Required top-level sections (Frigate 0.17 schema) ---
for section in ("mqtt", "ffmpeg", "record", "snapshots", "objects",
                "detect", "detectors", "model", "motion", "audio",
                "go2rtc", "cameras", "version"):
    assert_(section in d,
            f"top-level section '{section}' present",
            f"add '{section}:' block to config.yml")

# --- cameras: must be a non-empty dict ---
cameras = d.get("cameras") or {}
assert_(isinstance(cameras, dict) and len(cameras) >= 1,
        f"cameras: block has at least 1 entry (found {len(cameras)})",
        "add a camera block under 'cameras:' in config.yml")

# --- Each camera must have the required per-camera sections ---
REQUIRED_CAMERA_KEYS = {"ffmpeg", "detect", "objects", "snapshots"}
for cam_name, cam in cameras.items():
    if not isinstance(cam, dict):
        continue
    for k in REQUIRED_CAMERA_KEYS:
        assert_(k in cam,
                f"camera '{cam_name}' has '{k}' section",
                f"add '{k}:' under cameras.{cam_name} in config.yml")

# --- detect.{width,height,fps} must be positive integers ---
for cam_name, cam in cameras.items():
    if not isinstance(cam, dict):
        continue
    det = cam.get("detect") or {}
    for k in ("width", "height", "fps"):
        v = det.get(k)
        assert_(isinstance(v, int) and v > 0,
                f"camera '{cam_name}' detect.{k}={v} is a positive int",
                f"set cameras.{cam_name}.detect.{k} to a positive integer")

# --- objects.filters.person must have the physics-derived fields ---
PERSON_FILTER_KEYS = ("min_area", "max_area", "min_ratio", "max_ratio",
                      "threshold", "min_score")
for cam_name, cam in cameras.items():
    if not isinstance(cam, dict):
        continue
    pf = (cam.get("objects") or {}).get("filters") or {}
    pf = pf.get("person") or {}
    for k in PERSON_FILTER_KEYS:
        assert_(k in pf,
                f"camera '{cam_name}' objects.filters.person.{k} present",
                f"add '{k}:' under cameras.{cam_name}.objects.filters.person in config.yml")

# --- go2rtc.streams must include every stream referenced by a camera's
#     ffmpeg.inputs[*].path. This is the canonical "out of sync" check
#     that would otherwise cause Frigate to fail to start a camera. ---
streams = (d.get("go2rtc") or {}).get("streams") or {}
stream_keys = set(streams.keys())
referenced = set()
for cam_name, cam in cameras.items():
    if not isinstance(cam, dict):
        continue
    for inp in (cam.get("ffmpeg") or {}).get("inputs") or []:
        path = inp.get("path") or ""
        if path.startswith("rtsp://127.0.0.1:8554/"):
            referenced.add(path.split("/", 4)[-1])
missing = referenced - stream_keys
assert_(not missing,
        f"all {len(referenced)} go2rtc streams referenced by cameras are defined (missing: {sorted(missing) or 'none'})",
        f"add missing stream(s) under go2rtc.streams in config.yml: {sorted(missing)}")

# --- go2rtc streams that are NOT referenced by any camera (informational) ---
orphans = sorted(stream_keys - referenced)
if orphans:
    results.append(("OK",
        f"go2rtc.streams has {len(orphans)} unreferenced stream(s) (informational): {orphans}",
        ""))

# --- Per-camera ffmpeg.inputs must include a 'roles' list with at least one role ---
for cam_name, cam in cameras.items():
    if not isinstance(cam, dict):
        continue
    inputs = (cam.get("ffmpeg") or {}).get("inputs") or []
    assert_(len(inputs) >= 1,
            f"camera '{cam_name}' has at least one ffmpeg input",
            f"add an ffmpeg.inputs entry to cameras.{cam_name}")
    for i, inp in enumerate(inputs):
        assert_(isinstance(inp.get("roles"), list) and len(inp.get("roles")) >= 1,
                f"camera '{cam_name}' ffmpeg.inputs[{i}].roles is a non-empty list",
                f"add 'roles: [detect, record, audio]' (or a subset) to cameras.{cam_name}.ffmpeg.inputs[{i}]")

# --- Detector + model must be defined (otherwise every camera silently fails) ---
detectors = d.get("detectors") or {}
assert_(isinstance(detectors, dict) and len(detectors) >= 1,
        f"detectors: block has at least 1 detector (found {len(detectors)})",
        "add a detector block under 'detectors:' in config.yml")
model = d.get("model") or {}
assert_(isinstance(model.get("path"), str) and model["path"].startswith(("plus://", "/", "./")),
        f"model.path is set to a valid Frigate model URI (got {model.get('path')!r})",
        "set model.path to plus://<hash> or a local file path")

# --- Write TSV to out_path (status\tmessage\tremediation) ---
with open(out_path, "w") as out:
    for status, msg, fix in results:
        msg   = msg.replace("\t", " ").replace("\n", " ")
        fix   = fix.replace("\t", " ").replace("\n", " ")
        out.write(f"{status}\t{msg}\t{fix}\n")
PY

# Read the TSV and update counters
while IFS=$'\t' read -r status msg fix; do
    case "$status" in
        OK)   ok   "$msg" ;;
        FAIL) fail "$msg" "$fix" ;;
    esac
done < "$L1_OUT"

# --- Splitter port probe (soft WARN; L1 is structural, but the operator
#     benefits from a hint when the splitter is not running) ---
# The 6 new half-cropped cameras (allee_sur_le_cote_left/_right,
# jardin_devant_left/_right, piscine_vue_toit_left/_right) consume RTSP
# streams from the splitter service on port 8556. If the port is not
# responding, the new cameras in config.yml will go into 'disabled' state
# at runtime (L3 catches this). L1 just emits a WARN so the operator sees
# the hint even on a non-bring-up host. ---
if command -v timeout >/dev/null 2>&1; then
    if timeout 2 bash -c '>/dev/tcp/127.0.0.1/8556' 2>/dev/null; then
        printf "  %b[ OK ]%b  splitter RTSP port 8556 is accepting connections\n" "$GRN" "$NC"
        L1_OK=$((L1_OK+1)); L1_TOTAL=$((L1_TOTAL+1))
    else
        printf "  %b[WARN]%b  splitter RTSP port 8556 is NOT reachable\n" "$YEL" "$NC"
        printf "              the 6 new half-cropped cameras (allee_sur_le_cote_left/_right,\n"
        printf "              jardin_devant_left/_right, piscine_vue_toit_left/_right) consume\n"
        printf "              their RTSP streams from the splitter and will be 'disabled'\n"
        printf "              in Frigate until the splitter is up. To start it:\n"
        printf "                docker compose -f splitter/docker-compose.splitter.yml up -d\n"
        # WARN is informational — does NOT increment L1_FAIL. L1 is
        # structural, not runtime; the bring-up watchdog (L3 / bring-up.sh)
        # is the authoritative check for splitter reachability.
        L1_TOTAL=$((L1_TOTAL+1))
    fi
fi

# --- Summary ---
echo "───────────────────────────────────────────────────────────────────────"
if [ "$L1_FAIL" -eq 0 ]; then
    printf "  %bL1 SUMMARY: %d/%d OK%b\n" "$GRN" "$L1_OK" "$L1_TOTAL" "$NC"
    exit 0
else
    printf "  %bL1 SUMMARY: %d OK, %d FAIL%b\n" "$RED" "$L1_OK" "$L1_FAIL" "$NC"
    exit 1
fi
