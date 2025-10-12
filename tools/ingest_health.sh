#!/usr/bin/env bash
set -euo pipefail
NASROOT=/mnt/nas/run/nas-pipelines
f="$NASROOT/runs/current_01-media/heartbeat"
if [ -f "$f" ]; then
  echo -n "heartbeat age="; echo $(( $(date +%s) - $(stat -c %Y "$f") ))"s"
else
  echo "❌ no heartbeat"
fi
L=$(ls -t "$NASROOT"/logs/ingest-01-media_*.log 2>/dev/null | head -1)
echo "log=${L:-<none>}"
[ -n "$L" ] && { stat -c "size=%s bytes" "$L"; tail -n 40 "$L"; } || true
