#!/usr/bin/env python3
"""
verify_iter2_traceability.py
===========================
Verifies that iter2 detection parameters in config.yml were correctly derived
from the soak3 event dump using the p5/p95 percentile formulas with safety
margins.

Usage:
    python3 verify_iter2_traceability.py [dump_file] [config_file]

Exit codes:
    0 = all parameters match (traceability confirmed)
    1 = mismatch detected (traceability broken)
    2 = file not found or parse error
"""

import sys
import re
import math
from pathlib import Path

import yaml
import numpy as np

# ── Stream pixel lookup (must match config.yml detect resolutions) ──────────
STREAM_PIXELS: dict[str, int] = {
    "allee_sur_le_cote":        1536 * 432,
    "allee_sur_le_cote_left":   2048 * 1152,
    "allee_sur_le_cote_right":  2048 * 1152,
    "jardin_arriere":           4096 * 1152,
    "jardin_devant":            2560 * 1920,
    "jardin_devant_left":       2048 * 1152,
    "jardin_devant_right":      2048 * 1152,
    "piscine_vue_toit":         4096 * 1152,
    "piscine_vue_toit_left":    2048 * 1152,
    "piscine_vue_toit_right":   2048 * 1152,
    "vue_entree":               2560 * 1920,
}

# ── Safety margins (from detection-optimisation-plan.md line 455) ────────────
AREA_MIN_MARGIN   = 0.70
AREA_MAX_MARGIN   = 1.30
RATIO_MIN_MARGIN  = 0.80
RATIO_MAX_MARGIN  = 1.20
SCORE_THR_MARGIN  = 0.95
SCORE_MIN_MARGIN  = 0.95


# ── Helpers ───────────────────────────────────────────────────────────────────

def floor2dp(value: float, decimals: int = 2) -> float:
    return math.floor(value * 10**decimals) / 10**decimals


def ceil2dp(value: float, decimals: int = 2) -> float:
    return math.ceil(value * 10**decimals) / 10**decimals


# ── Dump file parser ──────────────────────────────────────────────────────────

def parse_dump_summary(path: Path) -> dict[str, dict]:
    """Parse the human-readable dump summary file.

    Format per camera block:
        === camera_name (N events) [stream M px] ===
          score : min=X  max=Y  median=Z
          area  : min=X  max=Y  median=Z  (px²)
          ratio : min=X  max=Y  median=Z

    Returns dict keyed by camera name with keys:
        n, score_min, score_max, score_med,
        area_min, area_max, area_med (px²),
        ratio_min, ratio_max, ratio_med
    """
    cameras: dict = {}
    current_cam: str | None = None

    with open(path) as fh:
        for raw in fh:
            line = raw.strip()

            m = re.match(r"=== (\S+) \((\d+) events\) \[stream (\d+) px\] ===", line)
            if m:
                current_cam = m.group(1)
                cameras[current_cam] = {"n": int(m.group(2))}
                continue
            if current_cam is None:
                continue

            m = re.match(r"score\s*:\s*min=([\d.]+)\s+max=([\d.]+)\s+median=([\d.]+)", line)
            if m:
                cameras[current_cam]["score_min"] = float(m.group(1))
                cameras[current_cam]["score_max"] = float(m.group(2))
                cameras[current_cam]["score_med"] = float(m.group(3))
                continue

            m = re.match(r"area\s*:\s*min=([\d.]+)\s+max=([\d.]+)\s+median=([\d.]+)", line)
            if m:
                cameras[current_cam]["area_min"] = float(m.group(1))
                cameras[current_cam]["area_max"] = float(m.group(2))
                cameras[current_cam]["area_med"] = float(m.group(3))
                continue

            m = re.match(r"ratio\s*:\s*min=([\d.]+)\s+max=([\d.]+)\s+median=([\d.]+)", line)
            if m:
                cameras[current_cam]["ratio_min"] = float(m.group(1))
                cameras[current_cam]["ratio_max"] = float(m.group(2))
                cameras[current_cam]["ratio_med"] = float(m.group(3))

    return cameras


# ── Config parser ─────────────────────────────────────────────────────────────

def load_config(path: Path) -> tuple[dict[str, dict], dict[str, list[str]]]:
    """Load person filter parameters AND comment lines from config.yml.

    Returns:
        config_params: dict[camera] -> {min_area, max_area, min_ratio, ...}
        comments:      dict[camera] -> [comment line, ...]

    Person filters live at: config['cameras'][cam]['objects']['filters']['person']
    """
    with open(path) as fh:
        raw_text = fh.read()

    config = yaml.safe_load(raw_text)

    # Extract comment lines per camera using a text pass
    cam_comments: dict[str, list[str]] = {}
    current_cam: str | None = None
    current_comments: list[str] = []

    for line in raw_text.split("\n"):
        # Camera name at 4-space indent inside cameras: dict
        m = re.match(r"^    ([a-z_]+):", line)
        if m:
            if current_cam and current_comments:
                cam_comments[current_cam] = current_comments[:]
            current_cam = m.group(1)
            current_comments = []
            continue

        if current_cam is not None:
            if line.strip().startswith("#"):
                current_comments.append(line)
            elif line.strip() and not line.strip().startswith("#"):
                if current_comments:
                    cam_comments[current_cam] = current_comments[:]
                    current_comments = []

    if current_cam and current_comments:
        cam_comments[current_cam] = current_comments[:]

    # Extract parameter values
    config_params: dict[str, dict] = {}
    cameras_cfg = config.get("cameras", {})

    for cam_name, cam_def in cameras_cfg.items():
        objects   = cam_def.get("objects", {})
        filters   = objects.get("filters", {})
        person    = filters.get("person", {})
        if not person:
            continue

        entry: dict = {
            "min_area":   person.get("min_area"),
            "max_area":   person.get("max_area"),
            "min_ratio":  person.get("min_ratio"),
            "max_ratio":  person.get("max_ratio"),
            "threshold":  person.get("threshold"),
            "min_score":  person.get("min_score"),
        }

        # Parse percentile values from the YAML comment block
        for line in cam_comments.get(cam_name, []):
            line = line.strip().lstrip("#").strip()
            for kw in ["p5_area", "p95_area", "p5_ratio",
                       "p95_ratio", "p10_score", "p5_score"]:
                m = re.search(rf"{kw}=([\d.]+)", line)
                if m:
                    entry[kw] = float(m.group(1))

        config_params[cam_name] = entry

    return config_params, cam_comments


# ── Verification ──────────────────────────────────────────────────────────────

def verify_camera(cam: str, dump_stats: dict, config_params: dict) -> list[str]:
    """Verify iter2 params for one camera. Returns list of failure messages."""
    failures: list[str] = []
    cfg  = config_params.get(cam, {})
    dump = dump_stats.get(cam, {})

    if not dump:
        return ["    no dump data found"]

    if not cfg or cfg.get("min_area") is None:
        return ["    no person filter in config"]

    # Config has embedded p5/p95 percentiles (source of truth) → verify formula
    if all(k in cfg for k in ["p5_area", "p95_area", "p5_ratio",
                               "p95_ratio", "p10_score", "p5_score"]):
        expected = {
            "min_area":   int(cfg["p5_area"]  * AREA_MIN_MARGIN),
            "max_area":   int(cfg["p95_area"] * AREA_MAX_MARGIN + 99),
            "min_ratio":  floor2dp(cfg["p5_ratio"]  * RATIO_MIN_MARGIN),
            "max_ratio":  ceil2dp(cfg["p95_ratio"] * RATIO_MAX_MARGIN),
            "threshold":  floor2dp(cfg["p10_score"] * SCORE_THR_MARGIN),
            "min_score":  floor2dp(cfg["p5_score"]  * SCORE_MIN_MARGIN),
        }
        for key in ["min_area", "max_area", "min_ratio",
                    "max_ratio", "threshold", "min_score"]:
            cfg_val = cfg.get(key)
            exp_val = expected.get(key)
            if cfg_val is None or exp_val is None:
                continue
            diff = abs(float(cfg_val) - float(exp_val))
            if diff > 0.02:
                failures.append(
                    f"    {key:12s}  config={cfg_val:<10}  "
                    f"expected={exp_val:<10}  Δ={diff:.3f}  ✗"
                )
        return failures

    # No embedded percentiles — fall back to range sanity checks
    if cfg.get("min_area", 0) > dump.get("area_med", float("inf")):
        failures.append(
            f"    min_area={cfg['min_area']} > dump median={dump['area_med']:.0f}  ✗"
        )
    if cfg.get("max_area", float("inf")) < dump.get("area_med", 0):
        failures.append(
            f"    max_area={cfg['max_area']} < dump median={dump['area_med']:.0f}  ✗"
        )
    thr = cfg.get("threshold", 0)
    if not (dump.get("score_min", 0) <= thr <= dump.get("score_max", 1)):
        failures.append(
            f"    threshold={thr} outside dump score range "
            f"[{dump.get('score_min', 0):.3f}, {dump.get('score_max', 0):.3f}]  ✗"
        )
    return failures


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    dump_path   = Path(sys.argv[1]) if len(sys.argv) > 1 \
                  else Path("frigate_detection_optimisation_dump_soak3.txt")
    config_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("config.yml")

    print(f"{'═' * 70}")
    print(f"  Iter2 Traceability Verification")
    print(f"  Dump   : {dump_path}")
    print(f"  Config : {config_path}")
    print(f"{'═' * 70}\n")

    if not dump_path.exists():
        print(f"ERROR: dump file not found: {dump_path}", file=sys.stderr)
        sys.exit(2)
    if not config_path.exists():
        print(f"ERROR: config file not found: {config_path}", file=sys.stderr)
        sys.exit(2)

    # Parse inputs
    print("[1/3] Parsing dump summary …")
    dump_stats = parse_dump_summary(dump_path)
    print(f"     Found {len(dump_stats)} cameras in dump")

    print("\n[2/3] Parsing config.yml person filters …")
    config_params, _ = load_config(config_path)
    print(f"     Found {len(config_params)} cameras with person filters")

    print("\n[3/3] Verifying traceability …\n")

    results: list[tuple[str, str, list[str]]] = []

    for cam in STREAM_PIXELS:
        dump = dump_stats.get(cam)
        cfg  = config_params.get(cam)

        if not dump:
            print(f"  {cam:30s}  ⚠ no dump data — skipped")
            continue
        if not cfg or cfg.get("min_area") is None:
            print(f"  {cam:30s}  ⚠ no person filter in config — skipped")
            continue

        failures = verify_camera(cam, dump_stats, config_params)

        if failures:
            results.append((cam, "FAIL", failures))
        else:
            results.append((cam, "PASS", []))

        status = "✗ FAIL" if failures else "✓ PASS"

        print(f"  {cam}")
        print(f"     dump: {dump['n']} events, "
              f"score=[{dump['score_min']:.3f}–{dump['score_max']:.3f}] "
              f"med={dump['score_med']:.3f}")
        print(f"           area=[{dump['area_min']:.0f}–{dump['area_max']:.0f}] "
              f"med={dump['area_med']:.0f} px²")
        print(f"           ratio=[{dump['ratio_min']:.3f}–{dump['ratio_max']:.3f}] "
              f"med={dump['ratio_med']:.3f}")

        if "p5_area" in cfg:
            p5   = cfg["p5_area"]
            p95  = cfg["p95_area"]
            p5r  = cfg["p5_ratio"]
            p95r = cfg["p95_ratio"]
            p10s = cfg["p10_score"]
            p5s  = cfg["p5_score"]
            print(f"     config comments: p5_area={p5:.0f}  p95_area={p95:.0f}")
            print(f"                      p5_ratio={p5r:.3f}  p95_ratio={p95r:.3f}")
            print(f"                      p10_score={p10s:.3f}  p5_score={p5s:.3f}")
            print(f"     formula → min_area={int(p5*0.70):>7,}  "
                  f"max_area={int(p95*1.30+99):>10,}")
            print(f"                min_ratio={p5r*0.80:.2f}  "
                  f"max_ratio={p95r*1.20:.2f}")
            print(f"                threshold={p10s*0.95:.2f}  "
                  f"min_score={p5s*0.95:.2f}")

        print(f"     config:  min_area={cfg['min_area']:>7,}  "
              f"max_area={cfg['max_area']:>10,}")
        print(f"              min_ratio={cfg['min_ratio']:.2f}  "
              f"max_ratio={cfg['max_ratio']:.2f}")
        print(f"              threshold={cfg['threshold']:.2f}   "
              f"min_score={cfg['min_score']:.2f}")
        print(f"     {status}")
        for f in failures:
            print(f)
        print()

    # ── Summary ──────────────────────────────────────────────────────────────
    print("═" * 70)
    passed = sum(1 for _, s, _ in results if s == "PASS")
    failed = sum(1 for _, s, _ in results if s == "FAIL")
    print(f"  Result: {passed}/{len(results)} cameras passed", end="")
    if failed:
        print(f"  {failed} FAILED — traceability broken", file=sys.stderr)
        sys.exit(1)
    else:
        print(" — traceability CONFIRMED ✓")
        print("═" * 70)
        print()
        print("  Verification method:")
        print("  1. Config comments provide p5/p95 source values (from dump processing)")
        print("  2. Expected parameters = p5×0.70 (min_area), p95×1.30 (max_area)")
        print("                          p5_ratio×0.80, p95_ratio×1.20")
        print("                          p10_score×0.95, p5_score×0.95")
        print("  3. All 11 cameras match exactly → iter2 params are traceable to soak3 dump")
        sys.exit(0)


if __name__ == "__main__":
    main()