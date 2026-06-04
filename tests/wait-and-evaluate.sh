#!/usr/bin/env bash
# ==============================================================================
# tests/wait-and-evaluate.sh — per-camera Frigate+ training-need evaluator
# ==============================================================================
# Queries the live Frigate instance for recent events on each camera and
# computes the score distribution. Produces a per-camera verdict:
#
#   TRAINING NEEDED            band/n > 30% OR median < 0.55 with n >= 20
#   borderline                 band/n > 15% OR median < 0.70
#   no training needed (OK)    otherwise
#
# Where:
#   band = count of events with 0.30 <= top_score < 0.55
#          (the "model is on the edge" band — exactly what Frigate+ learns from)
#   n    = total events on that camera in the last 10000
#   median = p50 of top_score across the same events
#
# This is a LIVE test (requires Frigate running on localhost:5000). It is
# NOT a CI test — it's an operator tool for the Frigate+ training loop.
# Schedule via cron (or systemd timer) to run weekly. Compare verdicts
# before/after a Frigate+ retrain to confirm the new plus://<hash> is
# actually better calibrated.
#
# Usage:
#   ./tests/wait-and-evaluate.sh                     # all cameras from config.yml
#   ./tests/wait-and-evaluate.sh vue_entree allee_sur_le_cote   # specific cameras
#   FRIGATE_URL=http://frigate.local:5000 ./tests/wait-and-evaluate.sh
#
# Exit codes:
#   0  all evaluated cameras are NO TRAINING NEEDED
#   1  at least one camera is BORDERLINE or TRAINING NEEDED
#   2  prerequisite missing (python3, config.yml)
#   3  Frigate API unreachable
# ==============================================================================
set -euo pipefail

# Always run from the repo root so relative paths to config.yml work
cd "$(dirname "$0")/.."

FRIGATE_URL="${FRIGATE_URL:-http://localhost:5000}"

# --- Colours (suppressed when stdout is not a TTY) ---
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; CYN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; CYN=''; DIM=''; NC=''
fi

# --- Counters ---
EVAL_OK=0
EVAL_BORDER=0
EVAL_NEED=0
EVAL_ERR=0
EVAL_NO_DATA=0
EVAL_TOTAL=0

# --- Helpers ---
verdict_ok()    { EVAL_OK=$((EVAL_OK+1));     EVAL_TOTAL=$((EVAL_TOTAL+1)); printf "  %b[ OK  ]%b  %s\n" "$GRN" "$NC" "$1"; }
verdict_border(){ EVAL_BORDER=$((EVAL_BORDER+1)); EVAL_TOTAL=$((EVAL_TOTAL+1)); printf "  %b[BORDER]%b %s\n" "$YEL" "$NC" "$1"; }
verdict_need()  { EVAL_NEED=$((EVAL_NEED+1));   EVAL_TOTAL=$((EVAL_TOTAL+1)); printf "  %b[NEED ]%b  %s\n" "$RED" "$NC" "$1"; }
verdict_err()   { EVAL_ERR=$((EVAL_ERR+1));     EVAL_TOTAL=$((EVAL_TOTAL+1)); printf "  %b[ERR  ]%b  %s\n" "$RED" "$NC" "$1"; }

# --- Preflight ---
[ -f config.yml ] || { echo "config.yml not found in $(pwd)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not in PATH" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl not in PATH" >&2; exit 2; }

# Quick reachability check (so we fail fast with a clear message)
if ! curl -s -o /dev/null --max-time 3 "$FRIGATE_URL/api/version"; then
    echo "Frigate API unreachable at $FRIGATE_URL" >&2
    echo "Hint: is the container running?  ./bring-up.sh --status" >&2
    exit 3
fi

# --- Determine cameras to evaluate ---
if [ "$#" -gt 0 ]; then
    CAMS=("$@")
else
    # Read from config.yml's cameras: keys (preserves the operator's
    # order, which is the order they appear in the file)
    CAMS=()
    while IFS= read -r c; do
        CAMS+=("$c")
    done < <(python3 -c '
import yaml, sys
with open("config.yml") as f:
    cfg = yaml.safe_load(f)
for c in (cfg.get("cameras") or {}).keys():
    print(c)
')
fi

# --- Pretty banner ---
echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Frigate+ TRAINING-NEED EVALUATOR"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')    host=$(hostname)  api=$FRIGATE_URL"
echo "═══════════════════════════════════════════════════════════════════════"
echo
printf "  %b%-22s %4s  %5s %5s %5s %5s %5s %5s  %5s %13s  %s%b\n" \
    "$CYN" "camera" "n" "min" "p10" "p25" "p50" "p75" "p90" "<0.55" "0.30-0.55 band" "verdict" "$NC"
echo "  --------------------------------------------------------------------------------------"

# --- Per-camera evaluation ---
EXIT_CODE=0
for cam in "${CAMS[@]}"; do
    # Pull events via python3 (handles the JSON cleanly; curl alone
    # would need a separate jq invocation and we don't want to require jq)
    read -r n min_v p10 p25 p50 p75 p90 n_below n_band < <(python3 - "$cam" "$FRIGATE_URL" <<'PY' || echo "0 0 0 0 0 0 0 0 0"
import json, sys, urllib.request, urllib.error
cam, base = sys.argv[1], sys.argv[2]
try:
    with urllib.request.urlopen(f"{base}/api/events?camera={cam}&limit=10000", timeout=5) as r:
        events = json.loads(r.read())
except urllib.error.URLError as e:
    print(f"ERROR fetching events for {cam}: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(events, list):
    print(f"unexpected payload: {type(events).__name__}", file=sys.stderr)
    sys.exit(1)
scores = sorted(e.get("data", {}).get("top_score", 0) or 0 for e in events)
n = len(scores)
if n == 0:
    print(f"0 0 0 0 0 0 0 0 0")
    sys.exit(0)
def pct(a, p):
    if n == 1: return f"{a[0]:.2f}"
    i = max(0, min(n-1, int(p * n)))
    return f"{a[i]:.2f}"
mn = scores[0]
mx = scores[-1]
p10v = pct(scores, 0.10)
p25v = pct(scores, 0.25)
p50v = pct(scores, 0.50)
p75v = pct(scores, 0.75)
p90v = pct(scores, 0.90)
below = sum(1 for s in scores if s < 0.55)
band  = sum(1 for s in scores if 0.30 <= s < 0.55)
print(f"{n} {mn:.2f} {p10v} {p25v} {p50v} {p75v} {p90v} {below} {band}")
PY
    )

    if [ "$n" = "0" ]; then
        printf "  %-22s %4s  %s\n" "$cam" "0" "(no events yet — re-run after natural activity accumulates)"
        EVAL_NO_DATA=$((EVAL_NO_DATA + 1))
        EVAL_TOTAL=$((EVAL_TOTAL + 1))
        continue
    fi

    # Decide verdict from the band ratio and the median
    python3 - "$cam" "$n_band" "$n" "$p50" <<'PY' >/tmp/eval_verdict.txt
import sys
cam, n_band, n, p50 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
ratio = n_band / n if n else 0
if ratio > 0.30 or (n >= 20 and p50 < 0.55):
    print("TRAINING NEEDED")
elif ratio > 0.15 or p50 < 0.70:
    print("borderline")
else:
    print("OK")
PY
    verdict=$(cat /tmp/eval_verdict.txt)
    rm -f /tmp/eval_verdict.txt

    printf "  %b%-22s%b %4s  %5s %5s %5s %5s %5s %5s  %5s %13s  " \
        "$CYN" "$cam" "$NC" "$n" "$min_v" "$p10" "$p25" "$p50" "$p75" "$p90" "$n_below" "$n_band"

    case "$verdict" in
        "TRAINING NEEDED") verdict_need "$verdict  ← relax iter0 (see config.yml) and submit events to Frigate+"; EXIT_CODE=1 ;;
        "borderline")      verdict_border "$verdict  ← consider mild relaxation (threshold 0.45)"; EXIT_CODE=1 ;;
        "OK")              verdict_ok "$verdict  ← iter0 contract is correct, no action" ;;
        *)                 verdict_err "$cam: unknown verdict '$verdict'"; EXIT_CODE=1 ;;
    esac
done

# --- Summary ---
echo
echo "═══════════════════════════════════════════════════════════════════════"
TOTAL=$((EVAL_OK + EVAL_BORDER + EVAL_NEED + EVAL_ERR + EVAL_NO_DATA))
echo "  EVALUATOR SUMMARY: $EVAL_OK OK, $EVAL_BORDER borderline, $EVAL_NEED need-training, $EVAL_ERR errors, $EVAL_NO_DATA no-data (total $TOTAL cameras)"
if [ $EVAL_NEED -gt 0 ]; then
    printf "  %b→ At least one camera needs Frigate+ training data.%b\n" "$RED" "$NC"
    printf "  %b  For each NEED camera: relax its iter0 contract (track [person,face], threshold 0.4,\n" "$DIM" "$NC"
    printf "  %b  min_score 0.3, expanded area/ratio, drop required_zones on review, mark with\n" "$DIM" "$NC"
    printf "  %b  training_collection_mode: True in tests/camera_spec.py) and submit the events to\n" "$DIM" "$NC"
    printf "  %b  Frigate+ via the web UI. See commit history on branch\n" "$DIM" "$NC"
    printf "  %b  feat/frigate-plus-training-collection-vue-entree for the canonical example.%b\n" "$DIM" "$NC"
elif [ $EVAL_BORDER -gt 0 ]; then
    printf "  %b→ Borderline cameras: re-evaluate in 1-2 weeks. If the borderline persists, mild relaxation is justified.%b\n" "$YEL" "$NC"
elif [ $EVAL_OK -gt 0 ] && [ $EVAL_NEED -eq 0 ] && [ $EVAL_BORDER -eq 0 ]; then
    printf "  %b→ The $EVAL_OK camera(s) with data are within the iter0 contract. No training needed for them.%b\n" "$GRN" "$NC"
fi
if [ $EVAL_NO_DATA -gt 0 ]; then
    printf "  %b→ $EVAL_NO_DATA camera(s) have no events yet — wait for natural activity, then re-run.%b\n" "$DIM" "$NC"
fi
if [ $EVAL_ERR -gt 0 ]; then
    printf "  %b→ $EVAL_ERR camera(s) had an evaluation error — see [ERR] lines above.%b\n" "$RED" "$NC"
fi
echo "═══════════════════════════════════════════════════════════════════════"
echo

exit $EXIT_CODE
