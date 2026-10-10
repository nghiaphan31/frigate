#!/usr/bin/env bash
# ==============================================================================
# install-gpu-calypso.sh — one-shot installer for Calypso GPU isolation & management stack
# ==============================================================================
# Run with sudo (asks password ONCE, then everything is unattended):
#   sudo bash install-gpu-calypso.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_DIR="$SCRIPT_DIR/gpu"
SUDOERS_SRC="$SCRIPT_DIR/sudoers/nghia-phan-gpu"
SUDOERS_DST="/etc/sudoers.d/nghia-phan-gpu"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use: sudo bash $0)"; exit 1; }
[ -d "$GPU_DIR" ] || { echo "ERROR: $GPU_DIR missing"; exit 1; }
[ -f "$SUDOERS_SRC" ] || { echo "ERROR: $SUDOERS_SRC missing"; exit 1; }

echo "=== Installing Calypso GPU Isolation & Management Stack ==="

# 1. Deploy sudoers file first
echo "=== Step 1/7: Deploy updated sudoers ==="
install -m 0440 -o root -g root "$SUDOERS_SRC" "$SUDOERS_DST"
visudo -c -f "$SUDOERS_DST"
echo "  -> $SUDOERS_DST (syntax OK)"

# 2. Shared environment file
echo "=== Step 2/7: Deploy /etc/calypso-gpu.env ==="
install -m 0644 -o root -g root "$GPU_DIR/calypso-gpu.env" /etc/calypso-gpu.env
echo "  -> /etc/calypso-gpu.env"

# 3. Executable scripts in /usr/local/bin
echo "=== Step 3/7: Install scripts in /usr/local/bin ==="
install -m 0755 -o root -g root "$GPU_DIR/gpu-recovery.sh" /usr/local/bin/gpu-recovery.sh
install -m 0755 -o root -g root "$GPU_DIR/gpu-watchdog.sh" /usr/local/bin/gpu-watchdog.sh
install -m 0755 -o root -g root "$GPU_DIR/gpu-usage-logger.sh" /usr/local/bin/gpu-usage-logger.sh
install -m 0755 -o root -g root "$GPU_DIR/gpu-throttle.sh" /usr/local/bin/gpu-throttle.sh
echo "  -> scripts installed in /usr/local/bin"

# 4. Systemd units
echo "=== Step 4/7: Install systemd units in /etc/systemd/system ==="
install -m 0644 -o root -g root "$GPU_DIR/systemd/gpu-watchdog.service" /etc/systemd/system/gpu-watchdog.service
install -m 0644 -o root -g root "$GPU_DIR/systemd/gpu-watchdog.timer" /etc/systemd/system/gpu-watchdog.timer
install -m 0644 -o root -g root "$GPU_DIR/systemd/cas-immich-ml.service" /etc/systemd/system/cas-immich-ml.service
install -m 0644 -o root -g root "$GPU_DIR/systemd/cas-immich-ml.timer" /etc/systemd/system/cas-immich-ml.timer
install -m 0644 -o root -g root "$GPU_DIR/systemd/cas-core.service" /etc/systemd/system/cas-core.service
install -m 0644 -o root -g root "$GPU_DIR/systemd/cas-core.timer" /etc/systemd/system/cas-core.timer
install -m 0644 -o root -g root "$GPU_DIR/systemd/demucs.service" /etc/systemd/system/demucs.service
echo "  -> systemd units installed"

# 5. Logrotate & log files
echo "=== Step 5/7: Install logrotate & initialize logs ==="
install -m 0644 -o root -g root "$GPU_DIR/logrotate/gpu-audit" /etc/logrotate.d/gpu-audit
touch /var/log/gpu-audit.jsonl /var/log/gpu-recovery.log
chmod 0666 /var/log/gpu-audit.jsonl /var/log/gpu-recovery.log
echo "  -> logrotate and logs ready"

# 6. Default target (disable permanent GNOME GPU rendering)
echo "=== Step 6/7: Set default systemd target to multi-user.target ==="
systemctl set-default multi-user.target
echo "  -> default target is now $(systemctl get-default)"

# 7. Reload systemd & start watchdog timer
echo "=== Step 7/7: Reload systemd and enable gpu-watchdog.timer ==="
systemctl daemon-reload
systemctl enable --now gpu-watchdog.timer
echo "  -> gpu-watchdog.timer enabled and started"

echo
echo "=== INSTALL COMPLETE ==="
echo "Watchdog timer status:"
systemctl status gpu-watchdog.timer --no-pager
echo
echo "To trigger manual recovery if GPU is currently wedged:"
echo "  sudo /usr/local/bin/gpu-recovery.sh --apply"
