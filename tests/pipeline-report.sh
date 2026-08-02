#!/usr/bin/env bash
# ==============================================================================
# tests/pipeline-report.sh — per-camera CURRENT PIPELINE STATE assessment
# ==============================================================================
# Reads the canonical JSON produced by `tests/pipeline_report.py` and prints
# a human-readable, per-camera report covering the 14 stages of the Frigate
# pipeline (motion detection → object detection → alert firing). Designed to
# be re-runnable: each run is timestamped to the second (UTC + local) and the
# JSON snapshot is the canonical archival record.
#
# Why a thin bash wrapper around a python data collector:
#   - python handles the JSON parsing / API calls / filesystem scans cleanly
#     (consistent with bring-up.sh and the other tests in this directory)
#   - bash handles the banner, colours, summary, file I/O, and CLI surface
#
# Usage:
#   ./tests/pipeline-report.sh                         # all cameras, text report
#   ./tests/pipeline-report.sh --camera=allee_sur_le_cote
#   ./tests/pipeline-report.sh --json=path/to/run.json  # also write JSON
#   ./tests/pipeline-report.sh --json-only              # JSON only, no text
#   ./tests/pipeline-report.sh --diff=path/to/baseline.json  # compare to a prior run
#   ./tests/pipeline-report.sh --window-hours=48        # widen the event window
#
# Exit codes:
#   0  every evaluated camera has verdict OK or DETECTION_DISABLED
#   1  at least one camera has verdict DEGRADED or FAIL
#   2  prerequisite missing (python3, config.yml, /api/stats unreachable)
#   3  invalid CLI argument
#
# See ARCHITECTURE.md §3-4 for the 14 stages this report walks.
# ==============================================================================
set -euo pipefail

# Always run from the repo root so relative paths to config.yml work
cd "$(dirname "$0")/.."

# --- Colours (suppressed when stdout is not a TTY) ---
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'
    CYN=$'\033[0;36m'; DIM=$'\033[2m';     NC=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; CYN=''; DIM=''; NC=''
fi

# --- Defaults (all overridable via env or CLI) ---
FRIGATE_URL="${FRIGATE_URL:-http://localhost:5000}"
GO2RTC_URL="${GO2RTC_URL:-http://localhost:1984}"
MQTT_HOST="${MQTT_HOST:-192.168.50.125}"
MQTT_PORT="${MQTT_PORT:-1883}"
MEDIA_PATH="${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate}"
WINDOW_HOURS="${PIPELINE_REPORT_WINDOW_HOURS:-24}"

# Load .env so FRIGATE_MEDIA_PATH / FRIGATE_PLUS_API_KEY are honoured
if [ -f .env ]; then
    set +u
    # shellcheck disable=SC1091
    . ./.env
    set -u
    MEDIA_PATH="${FRIGATE_MEDIA_PATH:-$MEDIA_PATH}"
fi

CAMERA_FILTER=""
JSON_PATH=""
JSON_ONLY=0
DIFF_PATH=""
WALK_START=""
WALK_END=""
WALK_MINUTES=""

usage() {
    sed -n '2,30p' "$0"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --camera=*)    CAMERA_FILTER="${arg#*=}" ;;
        --json=*)      JSON_PATH="${arg#*=}" ;;
        --json-only)   JSON_ONLY=1 ;;
        --diff=*)      DIFF_PATH="${arg#*=}" ;;
        --window-hours=*) WINDOW_HOURS="${arg#*=}" ;;
        --walk-start=*)    WALK_START="${arg#*=}" ;;
        --walk-end=*)      WALK_END="${arg#*=}" ;;
        --walk-minutes=*)  WALK_MINUTES="${arg#*=}" ;;
        --frigate-url=*)  FRIGATE_URL="${arg#*=}" ;;
        --go2rtc-url=*)   GO2RTC_URL="${arg#*=}" ;;
        --mqtt-host=*)    MQTT_HOST="${arg#*=}" ;;
        --mqtt-port=*)    MQTT_PORT="${arg#*=}" ;;
        --media-path=*)   MEDIA_PATH="${arg#*=}" ;;
        --help|-h)        usage ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 3
            ;;
    esac
done

# --- Pre-flight: python3 + PyYAML + config.yml ---
command -v python3 >/dev/null 2>&1 || { echo "python3 not in PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null \
    || { echo "PyYAML not installed; install with: pip3 install --user pyyaml" >&2; exit 2; }
[ -f config.yml ] || { echo "config.yml not found in $(pwd)" >&2; exit 2; }
[ -f tests/pipeline_report.py ] \
    || { echo "tests/pipeline_report.py not found" >&2; exit 2; }

# --- Collect the JSON from the python module ---
JSON_TMP=$(mktemp --suffix=.json)
trap 'rm -f "$JSON_TMP"' EXIT
PY_ARGS=(
    --frigate-url  "$FRIGATE_URL"
    --go2rtc-url   "$GO2RTC_URL"
    --mqtt-host     "$MQTT_HOST"
    --mqtt-port     "$MQTT_PORT"
    --media-path    "$MEDIA_PATH"
    --window-hours  "$WINDOW_HOURS"
)
if [ -n "$CAMERA_FILTER" ]; then PY_ARGS+=(--camera "$CAMERA_FILTER"); fi
if [ -n "$WALK_START" ];    then PY_ARGS+=(--walk-start "$WALK_START"); fi
if [ -n "$WALK_END" ];      then PY_ARGS+=(--walk-end "$WALK_END"); fi
if [ -n "$WALK_MINUTES" ];  then PY_ARGS+=(--walk-minutes "$WALK_MINUTES"); fi

if ! python3 tests/pipeline_report.py "${PY_ARGS[@]}" \
        > "$JSON_TMP" 2> /tmp/pipeline-report.stderr
then
    rc=$?
    echo "python3 tests/pipeline_report.py failed (rc=$rc):" >&2
    cat /tmp/pipeline-report.stderr >&2
    exit 2
fi

# Optionally write the JSON to a user-specified path
if [ -n "$JSON_PATH" ]; then
    mkdir -p "$(dirname "$JSON_PATH")"
    cp "$JSON_TMP" "$JSON_PATH"
fi

# JSON-only mode: print the JSON, nothing else
if [ "$JSON_ONLY" -eq 1 ]; then
    cat "$JSON_TMP"
    exit 0
fi

# --- Diff mode: print a human-readable drift view against a baseline ---
if [ -n "$DIFF_PATH" ]; then
    [ -f "$DIFF_PATH" ] || { echo "baseline not found: $DIFF_PATH" >&2; exit 2; }
    python3 - "$DIFF_PATH" "$JSON_TMP" <<'PY'
import json, sys
base_path, curr_path = sys.argv[1], sys.argv[2]
try:
    base = json.load(open(base_path))
except Exception as e:
    print(f"ERROR: cannot read baseline {base_path}: {e}", file=sys.stderr)
    sys.exit(2)
try:
    curr = json.load(open(curr_path))
except Exception as e:
    print(f"ERROR: cannot read current {curr_path}: {e}", file=sys.stderr)
    sys.exit(2)

CYN = "\033[0;36m" if sys.stdout.isatty() else ""
GRN = "\033[0;32m" if sys.stdout.isatty() else ""
YEL = "\033[0;33m" if sys.stdout.isatty() else ""
RED = "\033[0;31m" if sys.stdout.isatty() else ""
DIM = "\033[2m"    if sys.stdout.isatty() else ""
NC  = "\033[0m"    if sys.stdout.isatty() else ""

print()
print("═" * 79)
print(f"  PIPELINE-REPORT DIFF")
print(f"  baseline = {base_path}  ({base.get('report_ts_utc', '?')})")
print(f"  current  = {curr_path}  ({curr.get('report_ts_utc', '?')})")
print("═" * 79)
def get(d, *path, default=None):
    for k in path:
        if not isinstance(d, dict): return default
        d = d.get(k)
    return d if d is not None else default

base_by_cam = {c["camera"]: c for c in base.get("cameras", [])}
curr_by_cam = {c["camera"]: c for c in curr.get("cameras", [])}
all_cams = sorted(set(base_by_cam) | set(curr_by_cam))
drift_n = 0
for cam in all_cams:
    b, c = base_by_cam.get(cam), curr_by_cam.get(cam)
    if b is None:
        print(f"  {YEL}+ NEW CAMERA:{NC} {cam}")
        drift_n += 1
        continue
    if c is None:
        print(f"  {RED}- REMOVED CAMERA:{NC} {cam}")
        drift_n += 1
        continue
    bv, cv = b.get("verdict", "?"), c.get("verdict", "?")
    if bv != cv:
        print(f"  {YEL}~{NC} {cam}: verdict {bv} -> {cv}")
        drift_n += 1
    # stage-level drift
    bs = b.get("stages", {})
    cs = c.get("stages", {})
    for stage_name in sorted(set(bs) | set(cs)):
        bst, cst = (bs.get(stage_name) or {}).get("status"), (cs.get(stage_name) or {}).get("status")
        if bst != cst:
            print(f"  {YEL}~{NC} {cam}.{stage_name}: {bst} -> {cst}")
            drift_n += 1
    # event-count drift (the most operationally interesting)
    be = get(b, "stages", "10_event_lifecycle", "total_in_window")
    ce = get(c, "stages", "10_event_lifecycle", "total_in_window")
    if be is not None and ce is not None and be != ce:
        print(f"  {DIM}  {cam}: events in {c.get('window_hours', '?')}h window {be} -> {ce}{NC}")
    # recording count drift
    br = get(b, "stages", "12_recording", "files_in_window")
    cr = get(c, "stages", "12_recording", "files_in_window")
    if br is not None and cr is not None and br != cr:
        print(f"  {DIM}  {cam}: recordings in {c.get('window_hours', '?')}h window {br} -> {cr}{NC}")
print("═" * 79)
if drift_n == 0:
    print(f"  {GRN}OK: no drift between baseline and current{NC}")
    sys.exit(0)
else:
    print(f"  {YEL}DRIFT: {drift_n} difference(s) above{NC}")
    sys.exit(1)
PY
    # Diff exits with its own rc; don't continue to the text report.
    exit $?
fi

# --- Walk mode renderer ---
# Renders the chronological event log from the "walk" key of the JSON envelope.
# Sorted by event start_time (ascending) — already sorted by the python module,
# but we re-sort here to defend against any future reshuffling.
print_walk_report() {
    python3 - "$JSON_TMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

RED = "\033[0;31m" if sys.stdout.isatty() else ""
GRN = "\033[0;32m" if sys.stdout.isatty() else ""
YEL = "\033[0;33m" if sys.stdout.isatty() else ""
CYN = "\033[0;36m" if sys.stdout.isatty() else ""
DIM = "\033[2m"    if sys.stdout.isatty() else ""
NC  = "\033[0m"    if sys.stdout.isatty() else ""

w = d.get("walk", {})
events = w.get("events") or []
start_utc = w.get("start_utc", "?")
end_utc = w.get("end_utc", "?")
duration_s = w.get("duration_s", 0)
events_per_camera = w.get("events_per_camera") or {}

print()
print("=" * 79)
print(f"  FRIGATE PIPELINE - TEST WALK EVENT LOG")
print(f"  walk window: {start_utc}  ->  {end_utc}  ({duration_s} s)")
print(f"  {d['report_ts_utc']}  /  {d['report_ts_local']}  (host={d['host']})")
print(f"  events: {len(events)}  per-camera: {events_per_camera}")
print(f"  Frigate does not expose the motion-only timestamp; event start_time")
print(f"  is the closest proxy (motion pre-filter typically fires 50-200 ms")
print(f"  before the event is created).")
print("=" * 79)

if not events:
    print()
    print(f"  {YEL}No events fired in the walk window.{NC}")
    print(f"  possible causes:")
    print(f"    - the test walk was outside the cameras' FOV / motion zones")
    print(f"    - the window does not overlap with any activity")
    print(f"    - the per-camera person filter rejected the detections")
    print(f"  suggested next steps:")
    print(f"    1. confirm Frigate was up the whole time: curl -fsS http://localhost:5000/api/stats | jq")
    print(f"    2. widen the window: --walk-minutes=120")
    print(f"    3. check the motion pre-filter threshold: config.yml motion.threshold")
    print("=" * 79)
    print()
    sys.exit(0)

# Header
print()
hdr = f"  {'#':>3}  {'start_utc (ms)':<26}  {'start_local':<26}  {'camera':<22}  {'label':<10}  {'score':>6}  {'dur_s':>6}  {'class':<11}  {'clip':>4}  {'snap':>4}"
print(hdr)
print("  " + "-" * (len(hdr) - 2))

# Body
for i, e in enumerate(events, 1):
    score = e.get("top_score")
    score_s = f"{score:.2f}" if isinstance(score, (int, float)) else "-"
    dur = e.get("duration_s")
    dur_s = f"{dur:.2f}" if isinstance(dur, (int, float)) else "-"
    clip_s = f"{CYN}Y{NC}" if e.get("has_clip") else f"{DIM}.{NC}"
    snap_s = f"{CYN}Y{NC}" if e.get("has_snapshot") else f"{DIM}.{NC}"
    start_local = (e.get("start_local") or "").split("+")[0].split("Z")[0]
    cls = ((e.get("trace") or {}).get("review_gate") or {}).get("classification", "-")
    print(f"  {i:>3}  {e.get('start_utc', '?'):<26}  {start_local:<26}  "
          f"{e.get('camera', '?'):<22}  {e.get('label') or '?':<10}  "
          f"{score_s:>6}  {dur_s:>6}  {cls:<11}  {clip_s:>4}  {snap_s:>4}")

# Per-event pipeline trace: for each event, show the actual value +
# configured bound + PASS/FAIL for every filter / gate the event went
# through. This is the deep view the operator wants: "for THIS event,
# did the bbox pass min_area? did the bbox fall in a required zone?
# did the review gate promote it to alert?"
print()
print("  - per-event pipeline trace (motion -> detection -> alert) -")
for i, e in enumerate(events, 1):
    trace = e.get("trace") or {}
    print()
    # Header row: the event identity
    cls = (trace.get("review_gate") or {}).get("classification", "-")
    cls_color = CYN if "ALERT" in cls else DIM
    print(f"  [{i}] {e.get('start_utc')}  {e.get('camera')}  "
          f"label={e.get('label')}  top_score={e.get('top_score')}  "
          f"duration_s={e.get('duration_s')}  "
          f"-> {cls_color}{cls}{NC}")
    print(f"      event id = {e.get('id')}")

    # STAGE 1: Motion pre-filter
    m = trace.get("motion") or {}
    mv = m.get("verdict", "-")
    mv_color = GRN if mv == "PASS" else (YEL if mv == "WARN" else (RED if mv == "FAIL" else DIM))
    mr_norm = m.get("motion_region_norm")
    mr_s = (f"[{mr_norm[0]:.3f}, {mr_norm[1]:.3f}, {mr_norm[2]:.3f}, {mr_norm[3]:.3f}]"
            if mr_norm and len(mr_norm) == 4 else "-")
    print(f"      |- STAGE 1: Motion pre-filter  [{mv_color}{mv}{NC}]")
    print(f"      |   threshold={m.get('threshold')}  contour_area={m.get('contour_area')}")
    print(f"      |   motion_region (normalized): {mr_s}")
    print(f"      |   {m.get('reason', '')}")

    # STAGE 2: Object detector
    d = trace.get("detector") or {}
    dv = d.get("verdict", "-")
    dv_color = GRN if dv == "PASS" else (RED if dv == "FAIL" else DIM)
    model_path = d.get("model_path")
    model_s = model_path.get("path", "-") if isinstance(model_path, dict) else (model_path or "-")
    print(f"      |- STAGE 2: Object detector (TRT)  [{dv_color}{dv}{NC}]")
    print(f"      |   model = {model_s}")
    print(f"      |   score (frame) = {d.get('score_frame')}   score (event top) = {d.get('score_event')}")
    print(f"      |   {d.get('reason', '')}")

    # STAGE 3: Bbox
    b = trace.get("bbox") or {}
    bv = b.get("verdict", "-")
    bv_color = GRN if bv == "PASS" else DIM
    print(f"      |- STAGE 3: Bounding box  [{bv_color}{bv}{NC}]")
    if b.get("norm"):
        print(f"      |   normalized [x, y, w, h] = {b['norm']}")
        print(f"      |   pixel      [x, y, w, h] = {b.get('px')}")
        print(f"      |   area = {b.get('area_px2')} px^2   ratio (W/H) = {b.get('ratio')}   centroid = {b.get('centroid_norm')}")
        print(f"      |   {b.get('reason', '')}")
    else:
        print(f"      |   (no bbox on this event)")

    # STAGE 4: Person filter
    pf = trace.get("person_filter") or {}
    pfv = pf.get("verdict", "-")
    pfv_color = GRN if pfv == "PASS" else (RED if pfv == "FAIL" else DIM)
    print(f"      |- STAGE 4: Person filter (physics)  [{pfv_color}{pfv}{NC}]   {pf.get('reason', '')}")
    for cname, c in (pf.get("checks") or {}).items():
        cc = c.get("verdict", "-")
        cc_color = GRN if cc == "PASS" else RED
        bound = c.get("bound")
        actual = c.get("actual")
        print(f"      |   [{cc_color}{cc}{NC}] {cname:<11s}  bound={bound!s:>8}  actual={actual!s:>10}  ({c.get('reason', '')})")

    # STAGE 5: Zone matching
    z = trace.get("zones") or {}
    print(f"      |- STAGE 5: Zone matching  [{z.get('verdict', '-')}]")
    print(f"      |   defined: {z.get('defined') or '-'}")
    print(f"      |   bbox centroid (normalized): {z.get('bbox_centroid_norm')}")
    print(f"      |   zones hit: {z.get('hit') or '-'}")

    # STAGE 6: Review gate
    rg = trace.get("review_gate") or {}
    rgv = rg.get("classification", "-")
    rgv_color = CYN if "ALERT" in rgv else DIM
    print(f"      |- STAGE 6: Review gate  [{rgv_color}{rgv}{NC}]")
    print(f"      |   alerts_required_zones     = {rg.get('alerts_required_zones') or '-'}")
    print(f"      |   detections_required_zones = {rg.get('detections_required_zones') or '-'}")
    print(f"      |   event zones               = {rg.get('event_zones') or '-'}")
    print(f"      |   Frigate max_severity      = {rg.get('frigate_max_severity') or '-'}")
    print(f"      |   {rg.get('reason', '')}")

    # STAGE 7: Snapshot
    s = trace.get("snapshot") or {}
    sv = s.get("verdict", "-")
    sv_color = GRN if sv == "WRITTEN" else DIM
    print(f"      |- STAGE 7: Snapshot  [{sv_color}{sv}{NC}]  {s.get('reason', '')}")

    # STAGE 8: Recording
    rc = trace.get("recording") or {}
    rcv = rc.get("verdict", "-")
    rcv_color = GRN if rcv == "WRITTEN" else DIM
    print(f"      |- STAGE 8: Recording  [{rcv_color}{rcv}{NC}]  {rc.get('reason', '')}")

    # STAGE 9: MQTT publish
    mq = trace.get("mqtt") or {}
    mqv = mq.get("verdict", "-")
    print(f"      '- STAGE 9: MQTT publish  [{mqv}]  {mq.get('reason', '')}")

    # Cross-references
    rec = e.get("recording_path")
    if rec:
        size_mb = (e.get("recording_size_bytes") or 0) / 1048576
        print(f"        recording:  {rec}  ({size_mb:.2f} MB)")
    else:
        print(f"        recording:  (not on disk yet - has_clip={e.get('has_clip')})")
    if e.get("snapshot_url"):
        print(f"        snapshot:   {e['snapshot_url']}")

# Per-camera summary
print()
print("  - per-camera summary -")
for cam, n in sorted(events_per_camera.items()):
    cam_events = [e for e in events if e.get("camera") == cam]
    scores = [e.get("top_score") for e in cam_events if isinstance(e.get("top_score"), (int, float))]
    med = sorted(scores)[len(scores) // 2] if scores else None
    n_with_clip = sum(1 for e in cam_events if e.get("has_clip"))
    n_with_snap = sum(1 for e in cam_events if e.get("has_snapshot"))
    med_s = f"{med:.2f}" if med is not None else "-"
    print(f"    {cam:<22}  {n:>3} events   median top_score={med_s}   "
          f"clip={n_with_clip}/{n}   snap={n_with_snap}/{n}")

# Footer
print()
print("=" * 79)
print(f"  SUMMARY: {len(events)} event(s) in {duration_s} s walk window")
if events_per_camera:
    parts = [f"{c}: {n}" for c, n in sorted(events_per_camera.items())]
    print(f"  {', '.join(parts)}")
print(f"  full machine-readable JSON saved to: {d.get('_json_path') or '(stdout, re-run with --json=PATH to archive)'}")
print("=" * 79)
print()
PY
}

# --- Mode dispatch (walk vs state) ---
MODE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('mode','state'))" "$JSON_TMP")
if [ "$MODE" = "walk" ]; then
    print_walk_report
    exit 0
fi

# --- Helpers (state mode) ---
verdict_color() {
    case "$1" in
        OK)                printf "%s" "$GRN" ;;
        DEGRADED)          printf "%s" "$YEL" ;;
        FAIL)              printf "%s" "$RED" ;;
        DETECTION_DISABLED)printf "%s" "$CYN" ;;
        *)                 printf "%s" "$DIM" ;;
    esac
}

status_color() {
    case "$1" in
        OK)   printf "%s" "$GRN" ;;
        WARN) printf "%s" "$YEL" ;;
        FAIL) printf "%s" "$RED" ;;
        SKIP) printf "%s" "$DIM" ;;
        NA)   printf "%s" "$DIM" ;;
        *)    printf "%s" "$NC" ;;
    esac
}

# All formatting reads the JSON with python (the JSON is large enough that
# hand-parsing it in bash is brittle; this matches the convention used by
# the rest of the test harness).
print_report() {
    python3 - "$JSON_TMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

RED = "\033[0;31m" if sys.stdout.isatty() else ""
GRN = "\033[0;32m" if sys.stdout.isatty() else ""
YEL = "\033[0;33m" if sys.stdout.isatty() else ""
CYN = "\033[0;36m" if sys.stdout.isatty() else ""
DIM = "\033[2m"    if sys.stdout.isatty() else ""
NC  = "\033[0m"    if sys.stdout.isatty() else ""

def color_status(s):
    return {
        "OK":   GRN,
        "WARN": YEL,
        "FAIL": RED,
        "SKIP": DIM,
        "N/A":  DIM,
    }.get(s, "")

def color_verdict(v):
    return {
        "OK":                 GRN,
        "DEGRADED":           YEL,
        "FAIL":               RED,
        "DETECTION_DISABLED": CYN,
    }.get(v, "")

def fmt_list(xs, sep=", "):
    if not xs: return "—"
    return sep.join(str(x) for x in xs)

def fmt_value(v):
    if v is None: return "—"
    if isinstance(v, float): return f"{v:.2f}"
    return str(v)

# ----- Top banner -----
ts_utc   = d["report_ts_utc"]
ts_local = d["report_ts_local"]
host     = d["host"]
sum_     = d["summary"]
stats_ok = d.get("stats_api_status", "?")

print()
print("═" * 79)
print(f"  FRIGATE PIPELINE — CURRENT STATE REPORT")
print(f"  {ts_utc}  /  {ts_local}  (host={host})")
print(f"  window: last {d['window_hours']}h   "
      f"frigate={d['frigate_url']}   go2rtc={d['go2rtc_url']}   mqtt={d['mqtt_broker']}")
print(f"  cameras: {sum_['cameras_total']}  "
      f"({sum_['cameras_ok']} OK, "
      f"{sum_['cameras_degraded']} degraded, "
      f"{sum_['cameras_fail']} fail, "
      f"{sum_['cameras_detection_disabled']} detection-disabled)")
print(f"  /api/stats: {stats_ok}")
print("═" * 79)

# ----- Per-camera block -----
for cam in d["cameras"]:
    name   = cam["camera"]
    verdict = cam["verdict"]
    s       = cam["stages"]
    vc      = color_verdict(verdict)
    print()
    print("─" * 79)
    print(f"  CAMERA: {name}    {vc}verdict={verdict}{NC}")
    print("─" * 79)

    # 1. identity
    st = s["1_identity"]
    sc = color_status(st["status"])
    w, h = st.get("detect_width"), st.get("detect_height")
    res = f"{w}×{h}@{st.get('detect_fps')}fps" if w and h else "—"
    print(f"  {sc}[{st['status']:4s}]{NC} 1. Camera identity")
    print(f"          IP: {st.get('ip') or '—'}")
    print(f"          ffmpeg inputs: {fmt_list(st.get('rtsp_inputs'))}")
    print(f"          input roles:   {fmt_list(st.get('input_roles'))}")
    print(f"          detect: enabled={st.get('detect_enabled')}, {res}")
    print(f"          track:         {fmt_list(st.get('track'))}")
    print(f"          audio/mqtt:   audio={st.get('audio_enabled')}, mqtt={st.get('mqtt_enabled')}, snapshots={st.get('snapshots_enabled')}")
    print(f"          review:       alerts_zones={fmt_list(st.get('review_alerts_zones'))}, detections_zones={fmt_list(st.get('review_detections_zones'))}")

    # 2. RTSP
    st = s["2_rtsp_source"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 2. RTSP source (TCP probe)")
    if "ip" in st:
        print(f"          {st['ip']}:{st.get('port', '?')}  rtt={st.get('rtt_ms', '?')} ms")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 3. go2rtc
    st = s["3_go2rtc_restream"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 3. go2rtc re-stream")
    if "streams" in st:
        for sname, sd in st["streams"].items():
            print(f"          {sname}: producers={sd['producers']}, consumers={sd['consumers']}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 4. capture
    st = s["4_capture_ffmpeg"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 4. Capture ffmpeg (camera_fps)")
    if "camera_fps" in st:
        print(f"          camera_fps={st['camera_fps']}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 5. detect
    st = s["5_detect_process"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 5. Detect process (detection_fps / process_fps)")
    if "detection_fps" in st or "process_fps" in st:
        print(f"          detection_fps={st.get('detection_fps')}, process_fps={st.get('process_fps')}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 6. motion
    st = s["6_motion_prefilter"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 6. Motion pre-filter")
    if "threshold" in st:
        per_cam = " (per-camera override)" if st.get("per_camera_override") else ""
        print(f"          threshold={st.get('threshold')}, contour_area={st.get('contour_area')}, "
              f"frame_alpha={st.get('frame_alpha')}, delta_alpha={st.get('delta_alpha')}, "
              f"improve_contrast={st.get('improve_contrast')}{per_cam}")
    if "reason" in st:
        print(f"          {st['reason']}")

    # 7. object detection
    st = s["7_object_detection"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 7. Object detection (TRT)")
    if "detectors" in st and st["detectors"]:
        for dname, dd in st["detectors"].items():
            print(f"          {dname}: type={dd.get('type')}, device={dd.get('device')}, "
                  f"inference_speed={dd.get('inference_speed')} ms")
        print(f"          model: {st.get('model_path')}")
    if "reason" in st:
        print(f"          {st['reason']}")

    # 8. person filter
    st = s["8_person_filter"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 8. Person filter (physics)")
    if "values" in st:
        v = st["values"]
        print(f"          min_area={v.get('min_area')}, max_area={v.get('max_area')}, "
              f"ratio={v.get('min_ratio')}/{v.get('max_ratio')}, "
              f"threshold={v.get('threshold')}, min_score={v.get('min_score')}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 9. zones
    st = s["9_zone_matching"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 9. Zone matching")
    if "zones" in st:
        for z in st["zones"]:
            print(f"          {z['name']:8s}  loitering={z.get('loitering_time_s')}s  "
                  f"inertia={z.get('inertia')}  objects={fmt_list(z.get('objects'))}")
        print(f"          review.alerts required_zones     = {fmt_list(st.get('review_alerts_required_zones'))}")
        print(f"          review.detections required_zones = {fmt_list(st.get('review_detections_required_zones'))}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 10. events
    st = s["10_event_lifecycle"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 10. Event lifecycle (last {d['window_hours']}h)")
    if st.get("total_in_window") is not None:
        print(f"          events: {st['total_in_window']} total, "
              f"median top_score={st.get('median_top_score')}")
        sd = st.get("score_distribution") or {}
        if sd:
            print(f"          score buckets: "
                  f"<0.30={sd.get('<0.30', 0)}, "
                  f"0.30-0.55={sd.get('0.30-0.55', 0)}, "
                  f"0.55-0.70={sd.get('0.55-0.70', 0)}, "
                  f">=0.70={sd.get('>=0.70', 0)}")
        le = st.get("last_event") or {}
        if le:
            print(f"          last event: id={le.get('id')}  start={le.get('start_ts')}  "
                  f"end={le.get('end_ts')}  label={le.get('label')}  "
                  f"top_score={le.get('top_score')}  zones={fmt_list(le.get('zones'))}  "
                  f"has_clip={le.get('has_clip')}  has_snapshot={le.get('has_snapshot')}")
        for i, e in enumerate(st.get("last_5_events") or [], 1):
            print(f"            {i}. {e.get('start_ts')}  {e.get('label')}  "
                  f"top_score={e.get('top_score')}  zones={fmt_list(e.get('zones'))}  "
                  f"has_clip={e.get('has_clip')}  has_snapshot={e.get('has_snapshot')}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 11. mqtt
    st = s["11_mqtt_publish"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 11. MQTT publication")
    if "broker" in st:
        print(f"          broker={st['broker']}  rtt={st.get('rtt_ms', '?')} ms")
        print(f"          last event for camera at: {st.get('last_event_ts_for_camera') or '—'}")
        if st.get("caveat"):
            print(f"          ({st['caveat']})")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 12. recording
    st = s["12_recording"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 12. Recording (NAS)")
    if "rec_dir" in st or "events_with_clip_in_window" in st:
        print(f"          root: {st.get('rec_dir', '—')}")
        print(f"          events: {st.get('events_with_clip_in_window')}/"
              f"{st.get('events_total_in_window')} with clip in last {d['window_hours']}h")
        print(f"          files matched on disk: {st.get('files_matched_on_disk')}, "
              f"size: {st.get('size_mb_in_window')} MB")
        if st.get("oldest_recording_ts"):
            print(f"          oldest={st['oldest_recording_ts']}  newest={st['newest_recording_ts']}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 13. snapshots
    st = s["13_snapshots"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 13. Snapshots")
    if "events_with_snapshot_in_window" in st:
        print(f"          events: {st['events_with_snapshot_in_window']}/"
              f"{st.get('events_total_in_window')} with snapshot in last {d['window_hours']}h")
        if st.get("newest_snapshot_ts"):
            print(f"          newest snapshot event: id={st.get('newest_event_id')}  "
                  f"start={st['newest_snapshot_ts']}")
    elif "reason" in st:
        print(f"          {st['reason']}")

    # 14. semantic search
    st = s["14_semantic_search"]
    sc = color_status(st["status"])
    print(f"  {sc}[{st['status']:4s}]{NC} 14. Semantic search")
    if st.get("image_embedding_speed_ms") is not None or st.get("model"):
        print(f"          model={st.get('model')}  speed={st.get('image_embedding_speed_ms')} ms/emb  "
              f"total_emb={st.get('image_embedding_total')}  events_for_camera={st.get('events_for_camera')}")
        if st.get("caveat"):
            print(f"          ({st['caveat']})")
    elif "reason" in st:
        print(f"          {st['reason']}")

# ----- Final summary -----
print()
print("═" * 79)
print(f"  SUMMARY  ({sum_['cameras_ok']} OK, "
      f"{sum_['cameras_degraded']} degraded, "
      f"{sum_['cameras_fail']} fail, "
      f"{sum_['cameras_detection_disabled']} detection-disabled "
      f"of {sum_['cameras_total']} total)")
if sum_["cameras_fail"] > 0:
    print(f"  {RED}→ At least one camera has a FAILing pipeline stage. See the per-camera block above.{NC}")
elif sum_["cameras_degraded"] > 0:
    print(f"  {YEL}→ At least one camera is in a DEGRADED state (WARN, no FAIL). See the per-camera block above.{NC}")
else:
    print(f"  {GRN}→ All cameras OK (or detection-disabled by configuration).{NC}")
print(f"  full machine-readable JSON saved to: {d.get('_json_path') or '(stdout, re-run with --json=PATH to archive)'}")
print("═" * 79)
print()
PY
}

print_report

# Exit code: 1 if any camera has DEGRADED or FAIL, else 0.
WORST_RC=$(python3 -c "
import json
d = json.load(open('$JSON_TMP'))
if d.get('mode') == 'walk':
    print(0)  # walk mode handled above
else:
    worst = 0
    for c in d.get('cameras', []):
        v = c.get('verdict', 'OK')
        if v in ('FAIL', 'DEGRADED'):
            worst = 1
            break
    print(worst)
")
exit "$WORST_RC"
