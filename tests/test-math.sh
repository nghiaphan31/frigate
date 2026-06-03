#!/usr/bin/env bash
# ==============================================================================
# tests/test-math.sh — L2 test: math derivation + spec-vs-actual filter values
# ==============================================================================
# Catches: filter values don't match the geometry comment (e.g. min_area
# does not match H_px × W_px × margin); camera added but zones missing;
# go2rtc.streams out of sync with cameras: references; spec-vs-actual drift
# (operator changed config.yml but not the spec, or vice versa).
#
# Layer philosophy (see tests/README.md for the full 3-layer model):
#   L1  ≈ 5 s    — fast, no Frigate running, no GPU
#   L2  ≈ 5 s    — math re-derivation, no Frigate running
#   L3  ≈ 1-4 m  — live bring-up via bring-up.sh --all-cameras --status
#
# Exit codes:
#   0  all assertions pass
#   1  one or more math / spec assertions fail
#   2  prerequisite missing (python3, PyYAML, camera_spec.py)
# ==============================================================================
set -euo pipefail

# Always run from the repo root so relative paths to config.yml work
cd "$(dirname "$0")/.."

# --- Colours ---
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; CYN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; CYN=''; DIM=''; NC=''
fi

# --- Counters ---
L2_OK=0
L2_FAIL=0
L2_TOTAL=0

# --- Helpers ---
ok()   { L2_OK=$((L2_OK+1)); L2_TOTAL=$((L2_TOTAL+1)); printf "  %b[ OK ]%b  %s\n"  "$GRN" "$NC" "$1"; }
fail() { L2_FAIL=$((L2_FAIL+1)); L2_TOTAL=$((L2_TOTAL+1)); printf "  %b[FAIL]%b  %s\n"  "$RED" "$NC" "$1"; if [ -n "${2:-}" ]; then printf "              %bFIX:%b %s\n" "$YEL" "$NC" "$2"; fi; }
info() { printf "              %bℹ%s%b  %s\n"  "$DIM" "$NC" "$1"; }

# --- Preflight ---
[ -f config.yml ] || { echo "config.yml not found in $(pwd)" >&2; exit 2; }
[ -f tests/camera_spec.py ] || { echo "tests/camera_spec.py not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not in PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null \
    || { echo "PyYAML not installed; install with: pip3 install --user pyyaml" >&2; exit 2; }

# --- Pretty banner ---
echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  L2 — MATH DERIVATION + SPEC MATCH"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)"
echo "═══════════════════════════════════════════════════════════════════════"

# Capture all results in a TSV temp file (so counter updates survive
# the subshell boundary; see test-config.sh for the same trick).
L2_OUT=$(mktemp --suffix=.tsv)
trap 'rm -f "$L2_OUT"' EXIT
PYTHONPATH=tests python3 - "$L2_OUT" <<'PY' >/dev/null
import sys, yaml
sys.path.insert(0, "tests")

# --- Load spec and config ---
from camera_spec import (
    CAMERAS, derive_geometry,
    GEOMETRY_MIN_LOWER, GEOMETRY_MIN_UPPER,
    GEOMETRY_MAX_LOWER, GEOMETRY_MAX_UPPER,
    SPEC_TOLERANCE,
)
with open("config.yml") as f:
    cfg = yaml.safe_load(f)

results = []  # list of (status, message, remediation)

def add(status, msg, fix=""):
    results.append((status, msg, fix))

# --- Per-camera assertions ---
for cam_name, spec in CAMERAS.items():
    cam_cfg = (cfg.get("cameras") or {}).get(cam_name)
    if not isinstance(cam_cfg, dict):
        add("FAIL",
            f"camera '{cam_name}' is in tests/camera_spec.py but missing from config.yml cameras:",
            f"add cameras.{cam_name}: block to config.yml, OR remove the entry from tests/camera_spec.py")
        continue

    # --- 1) Spec-vs-actual filter value match (5 % tolerance) ---
    pf = (cam_cfg.get("objects") or {}).get("filters") or {}
    pf = pf.get("person") or {}
    for spec_key, cfg_key, label in [
        ("expected_min_area",  "min_area",  "min_area"),
        ("expected_max_area",  "max_area",  "max_area"),
        ("expected_threshold", "threshold", "threshold"),
        ("expected_min_score", "min_score", "min_score"),
    ]:
        expected = spec.get(spec_key)
        actual   = pf.get(cfg_key)
        if actual is None:
            add("FAIL",
                f"camera '{cam_name}' objects.filters.person.{cfg_key} missing in config.yml",
                f"add {cfg_key}: {expected} under cameras.{cam_name}.objects.filters.person")
            continue
        # Float fields: use relative tolerance; int fields: exact-or-5%-of-expected
        if isinstance(expected, float) or isinstance(actual, float):
            ok_match = abs(actual - expected) <= SPEC_TOLERANCE
        else:
            ok_match = abs(actual - expected) <= max(1, SPEC_TOLERANCE * expected)
        if ok_match:
            add("OK", f"camera '{cam_name}' person.{label}={actual} matches spec ({expected})")
        else:
            add("FAIL",
                f"camera '{cam_name}' person.{label}={actual} does not match spec ({expected})",
                f"set cameras.{cam_name}.objects.filters.person.{cfg_key}: {expected} in config.yml (or update tests/camera_spec.py if the new value is correct)")

    # --- 2) min_ratio / max_ratio match (exact, since they're discrete) ---
    for spec_key, cfg_key, label in [
        ("expected_min_ratio", "min_ratio", "min_ratio"),
        ("expected_max_ratio", "max_ratio", "max_ratio"),
    ]:
        expected = spec.get(spec_key)
        actual   = pf.get(cfg_key)
        if actual is None:
            add("FAIL",
                f"camera '{cam_name}' person.{cfg_key} missing in config.yml",
                f"add {cfg_key}: {expected} under cameras.{cam_name}.objects.filters.person")
            continue
        if abs(actual - expected) <= max(0.01, SPEC_TOLERANCE * expected):
            add("OK", f"camera '{cam_name}' person.{label}={actual} matches spec ({expected})")
        else:
            add("FAIL",
                f"camera '{cam_name}' person.{label}={actual} does not match spec ({expected})",
                f"set cameras.{cam_name}.objects.filters.person.{cfg_key}: {expected} in config.yml")

    # --- 3) Spec self-consistency: the expected_min_area / max_area
    #        must match what you'd get by applying the spec's
    #        min_area_margin / max_area_margin to the derived geometry.
    #        This catches typos in the spec (e.g. a missing digit) and
    #        is permissive about the operator's choice of margin —
    #        min_area_margin < 0.5 is normal for "noise floor" tuning,
    #        max_area_margin < 1.0 is normal for "conservative person"
    #        tuning. The geometry-vs-spec bound check (in the old
    #        version) was too strict and false-positived on legitimate
    #        operator choices. ---
    g = derive_geometry(spec)
    margin_min = spec.get("min_area_margin", 0.5)
    margin_max = spec.get("max_area_margin", 1.5)
    expected_min = spec["expected_min_area"]
    expected_max = spec["expected_max_area"]
    derived_min = round(g["area_far"] * margin_min)
    derived_max = round(g["area_near"] * margin_max)
    margin_min_tol = max(1, SPEC_TOLERANCE * derived_min)
    margin_max_tol = max(1, SPEC_TOLERANCE * derived_max)

    if abs(expected_min - derived_min) <= margin_min_tol:
        add("OK",
            f"camera '{cam_name}' spec min_area={expected_min} = derived "
            f"area_far={g['area_far']}×margin={margin_min} (={derived_min}, "
            f"H_px={g['H_px_far']}, W_px={g['W_px_far']})")
    else:
        add("FAIL",
            f"camera '{cam_name}' spec min_area={expected_min} does not match "
            f"area_far={g['area_far']}×margin={margin_min} = {derived_min} (delta {abs(expected_min - derived_min)})",
            f"either change min_area_margin in tests/camera_spec.py to "
            f"{expected_min / g['area_far']:.4f} (= {expected_min}/{g['area_far']}), "
            f"or correct the geometry (dist/height/tilt/FOV)")

    if abs(expected_max - derived_max) <= margin_max_tol:
        add("OK",
            f"camera '{cam_name}' spec max_area={expected_max} = derived "
            f"area_near={g['area_near']}×margin={margin_max} (={derived_max})")
    else:
        add("FAIL",
            f"camera '{cam_name}' spec max_area={expected_max} does not match "
            f"area_near={g['area_near']}×margin={margin_max} = {derived_max} (delta {abs(expected_max - derived_max)})",
            f"either change max_area_margin in tests/camera_spec.py to "
            f"{expected_max / g['area_near']:.4f} (= {expected_max}/{g['area_near']}), "
            f"or correct the geometry")

    # --- 4) detect.{width,height} match the spec's stream_w/h_px ---
    det = cam_cfg.get("detect") or {}
    if det.get("width")  == spec["stream_w_px"] and det.get("height") == spec["stream_h_px"]:
        add("OK", f"camera '{cam_name}' detect.{det.get('width')}x{det.get('height')} matches spec stream")
    else:
        add("FAIL",
            f"camera '{cam_name}' detect={det.get('width')}x{det.get('height')} but spec says {spec['stream_w_px']}x{spec['stream_h_px']}",
            f"set cameras.{cam_name}.detect.width/height to {spec['stream_w_px']}x{spec['stream_h_px']} "
            f"OR fix tests/camera_spec.py if the spec is wrong")

    # --- 4b) detect.fps matches expected_fps (the physics-derived FPS) ---
    expected_fps = spec.get("expected_fps")
    if expected_fps is not None:
        actual_fps = det.get("fps")
        if actual_fps == expected_fps:
            add("OK", f"camera '{cam_name}' detect.fps={actual_fps} matches spec")
        else:
            add("FAIL",
                f"camera '{cam_name}' detect.fps={actual_fps} but spec says {expected_fps}",
                f"set cameras.{cam_name}.detect.fps: {expected_fps} "
                f"OR update expected_fps in tests/camera_spec.py if the new value is correct "
                f"(use 'make iter0-revert CAM={cam_name}' to apply the spec)")

    # --- 4c) detect.enabled matches detect_enabled (Frigate defaults to true) ---
    expected_en = spec.get("detect_enabled")
    if expected_en is not None:
        actual_en = det.get("enabled")
        if actual_en is None:
            actual_en = True  # Frigate's per-camera default is enabled
        if bool(actual_en) == bool(expected_en):
            add("OK", f"camera '{cam_name}' detect.enabled={actual_en} matches spec")
        else:
            add("FAIL",
                f"camera '{cam_name}' detect.enabled={actual_en} but spec says {expected_en}",
                f"set cameras.{cam_name}.detect.enabled: {str(expected_en).lower()} in config.yml "
                f"(note: iter0.py revert does NOT toggle detect.enabled — that's a manual decision)")

    # --- 5) go2rtc streams: detect_stream + live_stream must be defined ---
    streams = (cfg.get("go2rtc") or {}).get("streams") or {}
    for s in (spec.get("detect_stream"), spec.get("live_stream")):
        if s and s not in streams:
            add("FAIL",
                f"camera '{cam_name}' references go2rtc stream '{s}' but it is not defined in config.yml",
                f"add a '{s}:' entry under go2rtc.streams in config.yml")
        elif s:
            add("OK", f"camera '{cam_name}' go2rtc stream '{s}' is defined")

    # --- 6) Required zones must exist in config.yml ---
    zones_cfg = cam_cfg.get("zones") or {}
    for z in spec.get("zones", []):
        if z in zones_cfg:
            add("OK", f"camera '{cam_name}' zone '{z}' is defined")
        else:
            add("FAIL",
                f"camera '{cam_name}' spec requires zone '{z}' but it is missing in config.yml",
                f"add cameras.{cam_name}.zones.{z}: block to config.yml")

    # --- 6b) Per-zone filter overrides match expected_zones ---
    for zname, zfilt in (spec.get("expected_zones") or {}).items():
        zcfg = zones_cfg.get(zname) or {}
        zpf = ((zcfg.get("filters") or {}).get("person") or {})
        for k, ev in zfilt.items():
            av = zpf.get(k)
            if av is None:
                add("FAIL",
                    f"camera '{cam_name}' zone '{zname}' filters.person.{k} missing in config.yml",
                    f"add {k}: {ev} under cameras.{cam_name}.zones.{zname}.filters.person")
                continue
            # Float fields: relative tolerance; int fields: small absolute
            if isinstance(ev, float) or isinstance(av, float):
                ok_match = abs(av - ev) <= SPEC_TOLERANCE
            else:
                ok_match = abs(av - ev) <= max(0.01, SPEC_TOLERANCE * ev)
            if ok_match:
                add("OK", f"camera '{cam_name}' zone '{zname}' filters.person.{k}={av} matches spec ({ev})")
            else:
                add("FAIL",
                    f"camera '{cam_name}' zone '{zname}' filters.person.{k}={av} does not match spec ({ev})",
                    f"set cameras.{cam_name}.zones.{zname}.filters.person.{k}: {ev} in config.yml "
                    f"(or update expected_zones in tests/camera_spec.py if the new value is correct)")

# --- 7) Cameras in config.yml that are NOT in the spec (warning, not fail) ---
cams_cfg = (cfg.get("cameras") or {})
for c in cams_cfg:
    if c not in CAMERAS:
        add("FAIL",
            f"camera '{c}' is in config.yml but missing from tests/camera_spec.py",
            f"add a CAMERAS['{c}'] entry to tests/camera_spec.py with the geometry + expected filter values, "
            f"OR remove cameras.{c} from config.yml if it shouldn't exist")

# --- Write TSV to out_path ---
with open(sys.argv[1], "w") as out:
    for status, msg, fix in results:
        msg = msg.replace("\t", " ").replace("\n", " ")
        fix = fix.replace("\t", " ").replace("\n", " ")
        out.write(f"{status}\t{msg}\t{fix}\n")
PY

# Read the TSV and update counters
while IFS=$'\t' read -r status msg fix; do
    case "$status" in
        OK)   ok   "$msg" ;;
        FAIL) fail "$msg" "$fix" ;;
    esac
done < "$L2_OUT"

# --- Summary ---
echo "───────────────────────────────────────────────────────────────────────"
if [ "$L2_FAIL" -eq 0 ]; then
    printf "  %bL2 SUMMARY: %d/%d OK%b\n" "$GRN" "$L2_OK" "$L2_TOTAL" "$NC"
    exit 0
else
    printf "  %bL2 SUMMARY: %d OK, %d FAIL%b\n" "$RED" "$L2_OK" "$L2_FAIL" "$NC"
    exit 1
fi
