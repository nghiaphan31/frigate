#!/usr/bin/env bash
set -euo pipefail
NASROOT=/mnt/nas/run/nas-pipelines
install -d "$NASROOT/compose/ingest-media" "$NASROOT/tools"
cp -f nas-compose/ingest-media/docker-compose.yml "$NASROOT/compose/ingest-media/docker-compose.yml"
cp -f tools/ingest_media.py tools/run_ingest.sh "$NASROOT/tools/"
chmod +x "$NASROOT/tools/"*.sh
echo "Deployed to $NASROOT"
