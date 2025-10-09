#!/bin/bash
#
# deploy/asus_merlin.sh
# Copy dnsmasq.conf.add to an Asus-Merlin router and reload dnsmasq.
#
# Usage:
#   ./deploy/asus_merlin.sh out/asus-merlin
#   make deploy-asus
#
# Requirements:
#   - SSH access to router (port 1970 on LAN).
#   - /jffs/configs writable.

set -euo pipefail

ROUTER_IP="192.168.50.1"
USER="admin"
PORT="1970"
SRC_DIR="${1:-out/asus-merlin}"
CONF_FILE="${SRC_DIR}/dnsmasq.conf.add"
DST_DIR="/jffs/configs"
DST_FILE="${DST_DIR}/dnsmasq.conf.add"
BACKUP="${DST_DIR}/dnsmasq.conf.add.$(date +%Y%m%d-%H%M%S).bak"

echo "[INFO] Deploying ${CONF_FILE} → ${USER}@${ROUTER_IP}:${DST_FILE}"

[[ -f "${CONF_FILE}" ]] || { echo "[ERROR] File not found: ${CONF_FILE}"; exit 1; }

# Backup remote file if exists
ssh -p ${PORT} ${USER}@${ROUTER_IP} "test -f ${DST_FILE} && cp ${DST_FILE} ${BACKUP} || true"

# Try SCP first
if scp -P ${PORT} "${CONF_FILE}" ${USER}@${ROUTER_IP}:${DST_FILE} 2>/dev/null; then
  echo "[OK] File copied via SCP."
else
  echo "[WARN] SCP failed; falling back to SSH cat method..."
  ssh -p ${PORT} ${USER}@${ROUTER_IP} "cat > ${DST_FILE}" < "${CONF_FILE}"
  echo "[OK] File copied via SSH fallback."
fi

# Restart dnsmasq gracefully
if ssh -p ${PORT} ${USER}@${ROUTER_IP} "service restart_dnsmasq" 2>/dev/null; then
  echo "[OK] dnsmasq restarted via service command."
else
  echo "[WARN] service restart_dnsmasq failed, using killall -HUP dnsmasq"
  ssh -p ${PORT} ${USER}@${ROUTER_IP} "killall -HUP dnsmasq"
fi

echo "[DONE] Deployment successful."
