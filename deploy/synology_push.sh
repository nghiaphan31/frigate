#!/bin/bash
# Push SoT exports (hosts.csv, backups.json, etc.) to the Synology NAS.
# Tries rsync first; if blocked, falls back to SSH+tar (works on all DSM).
set -euo pipefail

SRC_DIR="${1:-out/synology}"
NAS_USER="admin"
NAS_HOST="nas"          # change to your NAS IP/hostname if needed
NAS_PORT="22"
NAS_DEST="/volume1/git-configs/sot"

echo "[INFO] Deploying Synology configs → ${NAS_USER}@${NAS_HOST}:${NAS_DEST}"
[[ -d "${SRC_DIR}" ]] || { echo "[ERROR] ${SRC_DIR} not found"; exit 1; }

# ensure destination exists
ssh -p "${NAS_PORT}" "${NAS_USER}@${NAS_HOST}" "mkdir -p '${NAS_DEST}'"

# try rsync; fallback to ssh+tar if denied
if rsync -avz -e "ssh -p ${NAS_PORT}" "${SRC_DIR}/" "${NAS_USER}@${NAS_HOST}:${NAS_DEST}/" 2>/dev/null; then
  echo "[OK] Files deployed via rsync."
else
  echo "[WARN] rsync failed; using SSH+tar fallback..."
  tar czf - -C "${SRC_DIR}" . | ssh -p "${NAS_PORT}" "${NAS_USER}@${NAS_HOST}" "tar xzf - -C '${NAS_DEST}'"
  echo "[OK] Files deployed via SSH+tar."
fi

# optional NAS-side hook
ssh -p "${NAS_PORT}" "${NAS_USER}@${NAS_HOST}" "[ -x '${NAS_DEST}/post_deploy.sh' ] && '${NAS_DEST}/post_deploy.sh' || true"

echo "[DONE] Synology deploy complete."
