#!/usr/bin/env python3
"""
analyze_current_events.py
==========================
Fetches recent person events from Frigate's live API and analyzes them
against the iter2 parameter bounds to detect potential FP/FN patterns.

Usage:
    python3 analyze_current_events.py [minutes] [limit_per_cam]

    minutes        : how far back to query (default: 720 = last 12h)
    limit_per_cam  : max events per camera (default: 200)
"""

import sys
import json
import math
from collections import defaultdict

import yaml
import numpy as np
import urllib.request

# ── Stream pixel lookup ────────────────────────────────────────────────────────
STREAM_PIXELS = {
    "allee_sur_le_cote":        1536 * 432,
    "allee_sur_le_cote_left":   2048 * 1152,
    "allee_sur_le_cote_right":  2048 * 1152,
    "jardin_arriere":           4096 * 1152,
    "jardin_devant":            2560 * 1920,
    "jardin_devant_left":       2048 * 1152,
    "jardin_devant_right":      2048 * 1152,
    "piscine_vue_toit":         4096 * 1152,
    "piscine_vue_toit_left":   2048 * 1152,
    "piscine_vue_toit_right":  2048 * 1152,
    "vue_entree":              2560 * 1920,
}

# ── Load iter2 bounds from config.yml ─────────────────────────────────────────
def load_iter2_bounds():
    with open("config.yml") as fh:
        cfg = yaml.safe_load(fh)
    bounds = {}
    for cam, cam_def in cfg.get("cameras", {}).items():
        person = cam_def.get("objects", {}).get("filters", {}).get("person", {})
        if person:
            bounds[cam] = {
                "min_area":   person.get("min_area", 0),
                "max_area":   person.get("max_area", float("inf")),
                "min_ratio":  person.get("min_ratio", 0),
                "max_ratio":  person.get("max_ratio", float("inf")),
                "threshold":  person.get("threshold", 0),
                "min_score":  person.get("min_score", 0),
            }
    return bounds


# ── Fetch events from Frigate API ─────────────────────────────────────────────
def fetch_events(minutes: int = 720, limit: int = 200) -> list[dict]:
    """Fetch recent person events from the Frigate API.

    Uses the /api/events endpoint. start_time is Unix timestamp in seconds.
    Returns list of event dicts with computed area_px², ratio fields.
    """
    base_url = "http://localhost:5000"
    after_ts = int(__import__("time").time() - minutes * 60)  # Unix seconds

    all_events = []
    for label in ["person"]:
        # Try with after= parameter first (Unix timestamp in seconds)
        url = f"{base_url}/api/events?label={label}&limit={limit}&after={after_ts}&include_thumbnails=0"
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
            if isinstance(data, dict) and "events" in data:
                events = data["events"]
            else:
                events = data
            if events:
                all_events.extend(events)
        except Exception as ex:
            print(f"  ⚠ {label} with after filter failed: {ex}", file=sys.stderr)
            # Fall back: try without time filter
            try:
                url = f"{base_url}/api/events?label={label}&limit={limit}&include_thumbnails=0"
                req = urllib.request.Request(url)
                with urllib.request.urlopen(req, timeout=30) as resp:
                    data = json.loads(resp.read())
                if isinstance(data, dict) and "events" in data:
                    events = data["events"]
                else:
                    events = data
                # Filter client-side
                events = [e for e in events
                          if e.get("start_time", 0) >= after_ts]
                if events:
                    all_events.extend(events)
            except Exception as ex2:
                print(f"  ⚠ {label} fallback also failed: {ex2}", file=sys.stderr)

    # Compute geometric fields
    for e in all_events:
        box = e.get("data", {}).get("box", [])
        if len(box) == 4:
            x1, y1, x2, y2 = box
            w = abs(x2 - x1)
            h = abs(y2 - y1)
            pixels = STREAM_PIXELS.get(e.get("camera", ""), 1)
            e["_w"] = w
            e["_h"] = h
            e["_area_norm"] = w * h
            e["_area_px2"]  = w * h * pixels
            e["_ratio"]     = (w / h) if h > 0 else 0.0
        else:
            e["_w"] = e["_h"] = 0.0
            e["_area_norm"] = e["_area_px2"] = 0.0
            e["_ratio"] = 0.0

    return all_events


# ── Analysis ───────────────────────────────────────────────────────────────────
def analyze_events(events: list[dict], bounds: dict[str, dict]):
    """Compute per-camera statistics and flag parameter violations."""

    by_cam: dict = defaultdict(list)
    for e in events:
        by_cam[e["camera"]].append(e)

    print(f"\n{'═' * 70}")
    print(f"  Iter2 Optimality Analysis — Current Event Stream")
    print(f"  Total events: {len(events)}  Cameras: {len(by_cam)}")
    print(f"{'═' * 70}\n")

    warnings = []
    all_cam_stats = []

    for cam in STREAM_PIXELS:
        cam_events = [e for e in events if e["camera"] == cam]
        b = bounds.get(cam, {})
        if not b:
            print(f"  {cam:30s}  ⚠ no iter2 bounds in config — skipped")
            continue

        n = len(cam_events)
        if n == 0:
            print(f"  {cam:30s}  ⚠ no recent events")
            continue

        areas  = np.array([e["_area_px2"]  for e in cam_events])
        ratios = np.array([e["_ratio"]     for e in cam_events])
        scores = np.array([e.get("top_score") or e.get("score", 0) for e in cam_events])

        # Parameter violations
        below_min_area  = int(np.sum(areas < b["min_area"]))
        above_max_area  = int(np.sum(areas > b["max_area"]))
        below_min_ratio = int(np.sum(ratios < b["min_ratio"]))
        above_max_ratio = int(np.sum(ratios > b["max_ratio"]))
        below_thr       = int(np.sum(scores < b["threshold"]))
        below_min_score = int(np.sum(scores < b["min_score"]))

        total_violations = below_min_area + above_max_area + below_min_ratio + above_max_ratio

        # Detection rate: events per hour since last restart
        last_ts = max((e.get("start_time", 0) for e in cam_events)) or 0
        if last_ts > 0:
            age_h = (last_ts / 1e9) / 3600
            rate = n / age_h if age_h > 0 else 0
        else:
            rate = 0

        p5_area   = np.percentile(areas, 5)
        p95_area  = np.percentile(areas, 95)
        p5_ratio  = np.percentile(ratios, 5)
        p95_ratio = np.percentile(ratios, 95)

        status = "⚠ WARN" if total_violations > 0 else "✓ OK"

        print(f"  {cam:30s}  n={n:4d}  rate={rate:.1f}/h  {status}")
        print(f"     iter2 bounds:  area=[{b['min_area']:,}–{b['max_area']:,}]  ratio=[{b['min_ratio']:.2f}–{b['max_ratio']:.2f}]  thr={b['threshold']:.2f}")
        print(f"     observed:      area p5={p5_area:>9,.0f}  p95={p95_area:>10,.0f}  ratio p5={p5_ratio:.2f}  p95={p95_ratio:.2f}")
        print(f"     violations:    below_min_area={below_min_area:3d}  above_max_area={above_max_area:3d}  "
              f"below_min_ratio={below_min_ratio:3d}  above_max_ratio={above_max_ratio:3d}")
        print(f"     scores:        below_threshold={below_thr:3d}  below_min_score={below_min_score:3d}")
        if total_violations > 0:
            pct = total_violations / n * 100
            warnings.append((cam, n, total_violations, pct))
            print(f"     ⚠ {pct:.1f}% of events violate iter2 bounds")
        print()

        all_cam_stats.append({
            "cam": cam, "n": n, "rate": rate,
            "below_min_area": below_min_area, "above_max_area": above_max_area,
            "below_min_ratio": below_min_ratio, "above_max_ratio": above_max_ratio,
            "below_thr": below_thr, "below_min_score": below_min_score,
            "p5_area": p5_area, "p95_area": p95_area,
            "p5_ratio": p5_ratio, "p95_ratio": p95_ratio,
        })

    # ── Summary ─────────────────────────────────────────────────────────────
    print(f"{'═' * 70}")
    print(f"  Summary")
    print(f"{'═' * 70}")
    if warnings:
        print(f"\n  ⚠ {len(warnings)} cameras have events outside iter2 bounds:\n")
        print(f"  {'Camera':30s}  {'Events':>6}  {'Violations':>10}  {'%':>6}  Interpretation")
        print(f"  {'-'*30}  {'-'*6}  {'-'*10}  {'-'*6}  {'-'*30}")
        for cam, n, v, pct in sorted(warnings, key=lambda x: -x[3]):
            # Interpret the pattern
            b = bounds.get(cam, {})
            s = all_cam_stats[next(i for i, s in enumerate(all_cam_stats) if s["cam"] == cam)]
            if s["below_min_area"] > 0:
                cause = "min_area too high — missing small persons"
            elif s["above_max_area"] > 0:
                cause = "max_area too low — truncating large persons"
            elif s["below_min_ratio"] > 0:
                cause = "min_ratio too high — filtering thin objects"
            elif s["above_max_ratio"] > 0:
                cause = "max_ratio too low — filtering wide objects"
            else:
                cause = "unknown pattern"
            print(f"  {cam:30s}  {n:>6}  {v:>10}  {pct:>5.1f}%  {cause}")
    else:
        print(f"\n  ✓ No violations — all events fall within iter2 parameter bounds.")
        print(f"  This is expected since the iter2 params were derived from soak3 data.")

    # ── Event count vs soak3 baseline ────────────────────────────────────────
    print(f"\n  Event rate vs soak3 baseline (iter1 wide-open):")
    print(f"  {'Camera':30s}  {'Current/hr':>10}  {'Soak3/hr':>10}  {'Drift':>7}")
    print(f"  {'-'*30}  {'-'*10}  {'-'*10}  {'-'*7}")
    # Soak3 baseline: 2822 events / 72h = 39.2/h total across 11 cameras
    # We use per-camera counts from the dump (approximate)
    soak3_counts = {
        "allee_sur_le_cote": 373, "allee_sur_le_cote_left": 38,
        "allee_sur_le_cote_right": 267, "jardin_arriere": 1184,
        "jardin_devant": 162, "jardin_devant_left": 56,
        "jardin_devant_right": 152, "piscine_vue_toit": 168,
        "piscine_vue_toit_left": 349, "piscine_vue_toit_right": 16,
        "vue_entree": 57,
    }
    for cam in STREAM_PIXELS:
        stats = next((s for s in all_cam_stats if s["cam"] == cam), None)
        if not stats or stats["rate"] == 0:
            continue
        baseline = soak3_counts.get(cam, 0) / 72
        drift = (stats["rate"] / baseline * 100) if baseline > 0 else float("inf")
        flag = " ⚠ LOW" if drift < 40 else (" ⚠ HIGH" if drift > 150 else "")
        print(f"  {cam:30s}  {stats['rate']:>10.1f}  {baseline:>10.1f}  {drift:>6.0f}%{flag}")

    print(f"\n  Interpretation guide:")
    print(f"  drift < 40%  → possible over-filtering (some true detections lost)")
    print(f"  drift 40-150% → within expected range")
    print(f"  drift > 150%  → possible under-filtering (excess noise)")
    print(f"\n  Note: current data covers ~10.5h; wait 48-72h for stable rate.")
    print(f"{'═' * 70}")


def main():
    minutes      = int(sys.argv[1]) if len(sys.argv) > 1 else 720
    limit_per_cam = int(sys.argv[2]) if len(sys.argv) > 2 else 200

    print(f"Fetching events from last {minutes} minutes (max {limit_per_cam}/camera)…")

    bounds = load_iter2_bounds()
    print(f"Loaded iter2 bounds for {len(bounds)} cameras")

    events = fetch_events(minutes=minutes, limit=limit_per_cam)
    print(f"Fetched {len(events)} person events")

    if not events:
        print("ERROR: No events returned. Is Frigate running with detection enabled?", file=sys.stderr)
        sys.exit(1)

    analyze_events(events, bounds)


if __name__ == "__main__":
    main()