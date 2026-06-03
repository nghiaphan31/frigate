#!/usr/bin/env bash
# Install the patched systemd units to /etc/systemd/system, daemon-reload,
# reset-failed, and restart frigate-stack.service to re-test the boot path
# end-to-end under the new strict SuccessExitStatus=0 policy.
sudo bash -c '
set -e
REPO=/home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/frigate
install -m 0644 $REPO/frigate-stack.service          /etc/systemd/system/frigate-stack.service
install -m 0644 $REPO/frigate-stack-watchdog.service /etc/systemd/system/frigate-stack-watchdog.service
install -m 0644 $REPO/frigate-stack-watchdog.timer   /etc/systemd/system/frigate-stack-watchdog.timer
systemctl daemon-reload
systemctl reset-failed frigate-stack.service         2>/dev/null || true
systemctl reset-failed frigate-stack-watchdog.service 2>/dev/null || true
echo "=== SuccessExitStatus after install ==="
grep -H SuccessExitStatus /etc/systemd/system/frigate-stack.service /etc/systemd/system/frigate-stack-watchdog.service
echo
echo "=== restart frigate-stack.service ==="
systemctl restart frigate-stack.service
sleep 3
echo
echo "=== last 40 journal lines from the bring-up ==="
journalctl -u frigate-stack.service -n 40 --no-pager
echo
echo "=== final state ==="
echo -n "frigate-stack.service         active=";   systemctl is-active frigate-stack.service
echo -n "frigate-stack.service         enabled=";  systemctl is-enabled frigate-stack.service
echo -n "frigate-stack-watchdog.timer  enabled=";  systemctl is-enabled frigate-stack-watchdog.timer
'
