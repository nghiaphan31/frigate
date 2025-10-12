#!/bin/bash
set -euo pipefail

TS="$(date +%F_%H%M%S)"
RUN_DIR="/work/runs/${TS}_ingest-01-media"
LOG="/work/logs/ingest-01-media_${TS}.log"

mkdir -p "$RUN_DIR" /work/logs
# Symlink RELATIF (pas de /work/ en cible)
( cd /work/runs && ln -sfn "$(basename "$RUN_DIR")" current_01-media )

# Heartbeat immédiat + boucle (écrit dans RUN_DIR et via le symlink)
now="$(date +%s)"
echo "$now" > "$RUN_DIR/heartbeat"
echo "$now" > /work/runs/current_01-media/heartbeat || true
( while :; do
    now="$(date +%s)"
    echo "$now" > "$RUN_DIR/heartbeat"
    echo "$now" > /work/runs/current_01-media/heartbeat 2>/dev/null || true
    sleep 15
  done ) & HBPID=$!
cleanup(){ kill "$HBPID" 2>/dev/null || true; }
trap cleanup EXIT

# Log vers fichier + console
exec > >(stdbuf -o0 -e0 tee -a "$LOG") 2>&1
echo "[INGEST  ${TS} ]  $(date -Is)"

# Dépendances minimales
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libimage-exiftool-perl ca-certificates
python3 -m pip install --no-cache-dir blake3 || true

# Paramètres fixes
LIST="/work/config/candidates_01-media_2025-10-12.lst"
MOUNT_ROOT="/mnt/nas"
CAS_ROOT="/mnt/nas/truth/cas/med"
WORKERS="${WORKERS:-2}"
GIT_REV="$(cat /work/git_rev.txt 2>/dev/null || echo '')"

echo "[STEP] ingest_media.py"
set +e
ionice -c2 -n7 nice -n15 python3 /work/tools/ingest_media.py \
  --list "$LIST" \
  --mount-root "$MOUNT_ROOT" \
  --cas-root "$CAS_ROOT" \
  --run-dir "$RUN_DIR" \
  --workers "$WORKERS" \
  --link-back \
  --git-rev "$GIT_REV"
RC=$?
set -e

echo "[DONE] rc=$RC"
exit $RC
