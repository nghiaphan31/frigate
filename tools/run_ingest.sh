#!/bin/bash
set -euo pipefail

TS="$(date +%F_%H%M%S)"
RUN_DIR="/work/runs/${TS}_ingest-01-media"
LOG="/work/logs/ingest-01-media_${TS}.log"
LIST="/work/config/candidates_01-media_2025-10-12.lst"   # master list (unchanged)
CAS_ROOT="/mnt/nas/truth/cas/med"
MOUNT_ROOT="/mnt/nas"
WORKERS="${WORKERS:-2}"

mkdir -p "$RUN_DIR" /work/logs
ln -sfn "$RUN_DIR" /work/runs/current_01-media

# Heartbeat (every 15s)
( while :; do date +%s > "$RUN_DIR/heartbeat"; sleep 15; done ) & HBPID=$!
cleanup(){ kill "$HBPID" 2>/dev/null || true; }
trap cleanup EXIT

# Log to file + console
exec > >(stdbuf -o0 -e0 tee -a "$LOG") 2>&1
echo "[INGEST  ${TS} ]  $(date -Is)"
echo "[CFG] LIST=$LIST"
echo "[CFG] CAS_ROOT=$CAS_ROOT  WORKERS=$WORKERS"

# Deps (first boot is heavier, later runs are fast)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libimage-exiftool-perl ca-certificates >/dev/null
python3 -m pip install --no-cache-dir blake3 >/dev/null || true

# -------- Checkpoint logic (resume from last processed line) --------
CHK_LINES=0
if [ -f "$LIST" ]; then
  LIST_SZ=$(stat -c %s "$LIST"); LIST_MT=$(stat -c %Y "$LIST")
  echo "[CHK] list size=$LIST_SZ mtime=$LIST_MT"
fi

LAST_LOG="$(ls -t /work/logs/ingest-01-media_*.log 2>/dev/null | head -1 || true)"
if [ -n "${LAST_LOG:-}" ] && [ -f "$LAST_LOG" ]; then
  # Expect lines like: [PROGRESS] 212350/573189 ok=... skip=... err=...
  CHK_LINES=$(awk '/^\[PROGRESS\]/ { split($2,a,"/"); n=a[1] } END{ if(n=="") n=0; print n }' "$LAST_LOG")
  # Also sanity: only trust checkpoint if the list file hasn’t obviously changed (size/mtime persisted in last run header if you wish; here we just be conservative)
  # If you want stricter safety, write "[LIST] size=... mtime=..." into the log at start and compare here.
fi
echo "[CHK] last processed lines=$CHK_LINES"

LIST_IN="$LIST"
if [ "${CHK_LINES:-0}" -gt 0 ]; then
  # Build a sliced list that starts at CHK_LINES+1
  LIST_SLICE="$RUN_DIR/candidates.slice.lst"
  tail -n +$((CHK_LINES+1)) "$LIST" > "$LIST_SLICE" || true
  if [ -s "$LIST_SLICE" ]; then
    LIST_IN="$LIST_SLICE"
    echo "[CHK] resuming with sliced list: $(wc -l < "$LIST_IN") remaining entries"
  else
    echo "[CHK] nothing left to process (slice empty); exiting cleanly"
    exit 0
  fi
fi
# -------------------------------------------------------------------

echo "[STEP] ingest_media.py (list=$(basename "$LIST_IN"))"
ionice -c2 -n7 nice -n15 python3 /work/tools/ingest_media.py \
  --list "$LIST_IN" \
  --mount-root "$MOUNT_ROOT" \
  --cas-root "$CAS_ROOT" \
  --run-dir "$RUN_DIR" \
  --workers "$WORKERS" \
  --link-back \
  --git-rev "$(cat /work/git_rev.txt 2>/dev/null || echo '')"

RC=$?
echo "[DONE] rc=$RC"
exit $RC
