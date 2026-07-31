#!/usr/bin/env python3
# ==============================================================================
# tests/phase5-derive-thresholds.py — Phase 5 per-camera threshold re-derivation
# ==============================================================================
# Companion to plans/PLAN-2026-07-31-phase5.md and the iter1→iter2 transition.
#
# Pulls the last N `person` events for each outdoor camera from the live
# Frigate API, computes the per-camera `top_score` percentile distribution,
# and applies a decision matrix to recommend a new (threshold, min_score)
# pair relative to the iter0 contract (currently 0.55 / 0.45).
#
# The recommendation is ADVISORY only — the operator reviews the per-camera
# table, then applies it via `make iter0-revert-y CAM=<name>` after
# updating `expected_threshold` / `expected_min_score` in
# `tests/camera_spec.py`.
#
# Usage:
#   ./tests/phase5-derive-thresholds.py                    # all outdoor cameras
#   ./tests/phase5-derive-thresholds.py vue_entree allee_sur_le_cote
#   FRIGATE_URL=http://frigate:5000 ./tests/phase5-derive-thresholds.py
#   ./tests/phase5-derive-thresholds.py --limit=5000 --json=phase5.json
#   ./tests/phase5-derive-thresholds.py --no-color         # for logs / cron
#
# Output (default):
#   - Per-camera markdown table with n, p5/p25/p50/p75/p95, min, max,
#     false_positive_band rate, recommended (threshold, min_score),
#     and a verdict (KEEP iter0 / TIGHTEN / RELAX / INSUFFICIENT DATA)
#   - Optional JSON dump for downstream tooling (`--json=path`)
#
# Decision matrix (see plans/PLAN-2026-07-31-phase5.md §4 for the rationale):
#
#   n < 20                                                    -> INSUFFICIENT DATA
#   p5 >= 0.55  AND  fp_band_rate < 0.05  AND  median >= 0.70 -> KEEP iter0
#   p5 >= 0.65  AND  fp_band_rate < 0.05  AND  median >= 0.80 -> TIGHTEN to (0.60, 0.50)
#   fp_band_rate > 0.15                                       -> TIGHTEN to (0.60, 0.50)
#   below_threshold_rate > 0.30  AND  p5 >= 0.40              -> RELAX to (0.50, 0.40)
#   p5 < 0.40                                                 -> RELAX to (0.45, 0.35)
#   default                                                   -> KEEP iter0
#
# Exit codes:
#   0  all evaluated cameras produced a recommendation
#   1  at least one camera was INSUFFICIENT DATA
#   2  prerequisite missing (python3, config.yml)
#   3  Frigate API unreachable
# ==============================================================================
from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "config.yml"

# Constants — see PLAN-2026-07-31-phase5.md §4
ITER0_THRESHOLD = 0.55
ITER0_MIN_SCORE = 0.45
FP_BAND_LOW = 0.30   # top_score in [FP_BAND_LOW, FP_BAND_HIGH) is the
FP_BAND_HIGH = 0.55  # "model is on the edge" band — Frigate+ learns from it,
                     # but iter0 wants to reject it as low-confidence.
DEFAULT_LIMIT = 10_000
MIN_EVENTS_FOR_VERDICT = 20

# Camera-list shortlist — the 5 outdoor Reolink cameras that have
# `objects.track: [person]` and produce person events. The 3 indoor
# Tapo cameras have detect.enabled=false and produce no person events.
OUTDOOR_CAMERAS = [
    "allee_sur_le_cote",
    "jardin_arriere",
    "vue_entree",
    "jardin_devant",
    "piscine_vue_toit",
]


# ------------------------------------------------------------------------------
# Frigate API client
# ------------------------------------------------------------------------------
def fetch_person_events(frigate_url: str, camera: str, limit: int) -> list[dict]:
    """Pull up to `limit` person events for one camera from Frigate's
    `/api/events` endpoint, paginating with `after` until we have `limit`
    or the API returns fewer than a page.

    Frigate 0.17 returns events as a JSON array. The `top_score` field is
    at the top level for detection events; for audio events it is in
    `data.top_score` and the top-level `top_score` is `null`. We filter
    strictly to `label == "person"` so audio events do not contaminate
    the distribution.
    """
    events: list[dict] = []
    after: float | None = None
    page_size = min(1000, limit)
    headers = {"Accept": "application/json"}

    while len(events) < limit:
        url = f"{frigate_url}/api/events?cameras={camera}&labels=person&limit={page_size}"
        if after is not None:
            url += f"&after={after}"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                page = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError) as exc:
            raise RuntimeError(f"Frigate API unreachable: {exc}") from exc

        if not isinstance(page, list) or len(page) == 0:
            break

        # Frigate returns events newest-first; `after=` is the
        # end_time of the LAST event in the previous page (exclusive).
        for ev in page:
            if ev.get("label") != "person":
                continue
            ts = ev.get("top_score")
            if ts is None:
                # Fall back to data.top_score for events that nest it
                # (e.g. legacy schema, audio-typed events mislabeled)
                data = ev.get("data") or {}
                ts = data.get("top_score")
            if ts is None:
                continue
            events.append({"top_score": float(ts), "start_time": ev.get("start_time")})

        # Advance `after` to the smallest end_time seen on this page
        # (the API contract: `after` is exclusive on end_time, so the
        # next page will return events strictly older than this).
        if len(page) < page_size:
            break  # last page
        after = min(ev.get("end_time", 0) for ev in page)
        if after == 0:
            break

    return events[:limit]


# ------------------------------------------------------------------------------
# Distribution + decision matrix
# ------------------------------------------------------------------------------
def percentile(sorted_vals: list[float], p: float) -> float:
    """Linear-interpolation percentile, matching numpy's default.

    `p` is in [0, 100] (i.e. 5, 25, 50, 75, 95 — the same convention as
    the iter0 spec and the make-evaluate tool's p5/p95 references).
    """
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def analyse_camera(events: list[dict]) -> dict:
    """Return per-camera stats + a recommended (threshold, min_score)."""
    n = len(events)
    scores = sorted(e["top_score"] for e in events)
    if n == 0:
        return {
            "n": 0, "min": None, "max": None,
            "p5": None, "p25": None, "p50": None, "p75": None, "p95": None,
            "fp_band_rate": None, "below_threshold_rate": None,
            "recommended": (ITER0_THRESHOLD, ITER0_MIN_SCORE),
            "verdict": "INSUFFICIENT DATA (n=0)",
            "rationale": "no person events in the last window",
        }

    p5  = percentile(scores, 5)
    p25 = percentile(scores, 25)
    p50 = percentile(scores, 50)
    p75 = percentile(scores, 75)
    p95 = percentile(scores, 95)

    fp_band_count = sum(1 for s in scores if FP_BAND_LOW <= s < FP_BAND_HIGH)
    below_threshold_count = sum(1 for s in scores if s < ITER0_THRESHOLD)
    fp_band_rate = fp_band_count / n
    below_threshold_rate = below_threshold_count / n

    # Decision matrix — see PLAN-2026-07-31-phase5.md §4
    if n < MIN_EVENTS_FOR_VERDICT:
        verdict = "INSUFFICIENT DATA"
        rationale = (f"n={n} < {MIN_EVENTS_FOR_VERDICT}; the iter0 contract "
                     f"decision needs at least 20 person events per camera to "
                     f"distinguish signal from random scoring noise. Wait for "
                     f"a longer soak.")
        recommended = (ITER0_THRESHOLD, ITER0_MIN_SCORE)
    elif p5 >= 0.65 and fp_band_rate < 0.05 and p50 >= 0.80:
        verdict = "TIGHTEN"
        rationale = (f"p5={p5:.3f} >= 0.65, fp_band_rate={fp_band_rate:.1%} < 5%, "
                     f"median={p50:.3f} >= 0.80 — the new model is "
                     f"consistently over-confident on this geometry. Bump "
                     f"threshold 0.55→0.60 and min_score 0.45→0.50 to "
                     f"suppress the residual low-confidence tail without "
                     f"losing real detections.")
        recommended = (0.60, 0.50)
    elif fp_band_rate > 0.15:
        verdict = "TIGHTEN"
        rationale = (f"fp_band_rate={fp_band_rate:.1%} > 15% — too many "
                     f"events in the [0.30, 0.55) low-confidence band are "
                     f"slipping through. Bump threshold 0.55→0.60 to "
                     f"reject them; the new model has enough high-confidence "
                     f"events (p5={p5:.3f}, p50={p50:.3f}) to absorb the "
                     f"loss.")
        recommended = (0.60, 0.50)
    elif p5 < 0.40:
        verdict = "RELAX"
        rationale = (f"p5={p5:.3f} < 0.40 — the new model is consistently "
                     f"under-confident on this geometry (likely a low-light "
                     f"or far-distance case the yolonas training set under-"
                     f"represented). Drop threshold 0.55→0.45 and "
                     f"min_score 0.45→0.35 to catch the long tail.")
        recommended = (0.45, 0.35)
    elif below_threshold_rate > 0.30 and p5 >= 0.40:
        verdict = "RELAX"
        rationale = (f"below_threshold_rate={below_threshold_rate:.1%} > 30% "
                     f"but p5={p5:.3f} >= 0.40 — too many valid events are "
                     f"being rejected by the iter0 threshold while the "
                     f"long tail is real signal. Drop threshold "
                     f"0.55→0.50 and min_score 0.45→0.40.")
        recommended = (0.50, 0.40)
    elif p5 >= 0.55 and fp_band_rate < 0.05:
        verdict = "KEEP iter0"
        rationale = (f"p5={p5:.3f} >= 0.55, fp_band_rate={fp_band_rate:.1%} "
                     f"< 5%, median={p50:.3f} — the new model is well-"
                     f"calibrated for this geometry. The iter0 contract "
                     f"(0.55/0.45) is correct.")
        recommended = (ITER0_THRESHOLD, ITER0_MIN_SCORE)
    else:
        verdict = "KEEP iter0 (borderline)"
        rationale = (f"n={n}, p5={p5:.3f}, p50={p50:.3f}, "
                     f"fp_band_rate={fp_band_rate:.1%} — no strong signal "
                     f"either way; iter0 contract is acceptable. Re-run "
                     f"after another 24h soak for a sharper verdict.")
        recommended = (ITER0_THRESHOLD, ITER0_MIN_SCORE)

    return {
        "n": n,
        "min": scores[0],
        "max": scores[-1],
        "p5": p5, "p25": p25, "p50": p50, "p75": p75, "p95": p95,
        "fp_band_rate": fp_band_rate,
        "below_threshold_rate": below_threshold_rate,
        "recommended": recommended,
        "verdict": verdict,
        "rationale": rationale,
    }


# ------------------------------------------------------------------------------
# Reporting
# ------------------------------------------------------------------------------
def render_table(results: dict[str, dict], use_color: bool) -> str:
    """Render the per-camera table as a markdown-friendly text block."""
    RED = "\033[0;31m" if use_color else ""
    GRN = "\033[0;32m" if use_color else ""
    YEL = "\033[0;33m" if use_color else ""
    DIM = "\033[2m" if use_color else ""
    NC  = "\033[0m"    if use_color else ""

    header = (f"{'camera':<22} {'n':>5} {'p5':>6} {'p25':>6} {'p50':>6} "
              f"{'p75':>6} {'p95':>6} {'fp%':>6} {'rec':>10} {'verdict'}")
    sep = "-" * len(header)
    lines = [header, sep]

    for cam, r in results.items():
        n = r["n"]
        if n == 0:
            line = (f"{cam:<22} {n:>5} {'-':>6} {'-':>6} {'-':>6} "
                    f"{'-':>6} {'-':>6} {'-':>6} {'-':>10} {YEL}NO DATA{NC}")
        else:
            verdict_color = ""
            if r["verdict"].startswith("KEEP"):
                verdict_color = GRN
            elif r["verdict"].startswith("TIGHTEN"):
                verdict_color = YEL
            elif r["verdict"].startswith("RELAX"):
                verdict_color = RED
            elif r["verdict"].startswith("INSUFFICIENT"):
                verdict_color = DIM
            rec = f"{r['recommended'][0]:.2f}/{r['recommended'][1]:.2f}"
            line = (f"{cam:<22} {n:>5} {r['p5']:>6.3f} {r['p25']:>6.3f} "
                    f"{r['p50']:>6.3f} {r['p75']:>6.3f} {r['p95']:>6.3f} "
                    f"{r['fp_band_rate']*100:>5.1f}% {rec:>10} "
                    f"{verdict_color}{r['verdict']}{NC}")
        lines.append(line)

    return "\n".join(lines)


def render_rationale(results: dict[str, dict]) -> str:
    """One paragraph per camera explaining the verdict."""
    out = []
    for cam, r in results.items():
        out.append(f"### {cam}\n")
        out.append(f"  - verdict: **{r['verdict']}**")
        out.append(f"  - recommendation: `threshold={r['recommended'][0]:.2f}, "
                   f"min_score={r['recommended'][1]:.2f}` (iter0: "
                   f"0.55/0.45)")
        if r["n"] > 0:
            out.append(f"  - distribution: min={r['min']:.3f} "
                       f"p5={r['p5']:.3f} p25={r['p25']:.3f} "
                       f"p50={r['p50']:.3f} p75={r['p75']:.3f} "
                       f"p95={r['p95']:.3f} max={r['max']:.3f}")
            out.append(f"  - false-positive band [0.30, 0.55): "
                       f"{r['fp_band_rate']*100:.1f}% of events")
            out.append(f"  - below iter0 threshold (0.55): "
                       f"{r['below_threshold_rate']*100:.1f}% of events")
        out.append(f"  - rationale: {r['rationale']}\n")
    return "\n".join(out)


# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description=(
        "Phase 5: per-camera threshold re-derivation against the new "
        "yolonas model. See plans/PLAN-2026-07-31-phase5.md for the "
        "decision-matrix rationale."
    ))
    p.add_argument("cameras", nargs="*", help="cameras to evaluate (default: all 5 outdoor)")
    p.add_argument("--limit", type=int, default=DEFAULT_LIMIT,
                   help=f"max events per camera (default: {DEFAULT_LIMIT})")
    p.add_argument("--frigate-url", default=os.environ.get("FRIGATE_URL", "http://localhost:5000"),
                   help="Frigate base URL (default: $FRIGATE_URL or http://localhost:5000)")
    p.add_argument("--json", metavar="PATH", help="also write raw per-camera results to PATH as JSON")
    p.add_argument("--no-color", action="store_true", help="suppress ANSI colours (for logs / cron)")
    args = p.parse_args()

    use_color = sys.stdout.isatty() and not args.no_color

    cameras = args.cameras or OUTDOOR_CAMERAS

    # Preflight: config + reachability
    if not CONFIG_PATH.exists():
        print(f"config.yml not found at {CONFIG_PATH}", file=sys.stderr)
        return 2
    try:
        req = urllib.request.Request(f"{args.frigate_url}/api/version")
        with urllib.request.urlopen(req, timeout=3) as resp:
            # Frigate 0.17's /api/version returns the version string
            # as plain text (e.g. "0.17.1-416a9b7"), not as JSON.
            # The mere fact that urlopen() succeeded is enough.
            resp.read()
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"Frigate API unreachable at {args.frigate_url}: {exc}", file=sys.stderr)
        return 3

    # Pull + analyse
    results: dict[str, dict] = {}
    print(f"# Phase 5: per-camera threshold re-derivation")
    print(f"# Frigate URL: {args.frigate_url}")
    print(f"# Event limit per camera: {args.limit}")
    print(f"# Cameras: {', '.join(cameras)}\n")

    for cam in cameras:
        try:
            events = fetch_person_events(args.frigate_url, cam, args.limit)
        except RuntimeError as exc:
            print(f"  [ERR ] {cam}: {exc}", file=sys.stderr)
            results[cam] = {
                "n": 0, "min": None, "max": None,
                "p5": None, "p25": None, "p50": None, "p75": None, "p95": None,
                "fp_band_rate": None, "below_threshold_rate": None,
                "recommended": (ITER0_THRESHOLD, ITER0_MIN_SCORE),
                "verdict": "ERROR",
                "rationale": str(exc),
            }
            continue
        results[cam] = analyse_camera(events)
        print(f"  pulled {len(events)} person events from {cam}")

    print()
    print(render_table(results, use_color))
    print()
    print(render_rationale(results))

    # JSON dump (if requested)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2, default=str)
        print(f"\nJSON dump: {args.json}")

    # Exit code: 1 if any camera was INSUFFICIENT DATA
    if any(r["verdict"].startswith("INSUFFICIENT") for r in results.values()):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
