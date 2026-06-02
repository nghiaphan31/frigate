#!/usr/bin/env bash
# ==============================================================================
# install-systemd.sh — install the frigate-stack systemd units
# ==============================================================================
# Copies the 3 unit files to /etc/systemd/system, reloads the daemon, enables
# them, and starts the stack immediately (so you do not have to reboot).
#
# Run from this repo as a normal user — uses sudo internally for the operations
# that need root.
#
# Usage:
#   ./install-systemd.sh           # full install + start + tail the journal
#   ./install-systemd.sh --no-tail # install + start, do not follow the journal
#   ./install-systemd.sh --uninstall
# ==============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="/etc/systemd/system"
UNITS=(
    "frigate-stack.service"
    "frigate-stack-watchdog.service"
    "frigate-stack-watchdog.timer"
)

# ---------- Args ----------
TAIL_JOURNAL=1
ACTION="install"
for arg in "$@"; do
    case "$arg" in
        --no-tail)    TAIL_JOURNAL=0 ;;
        --uninstall)  ACTION="uninstall" ;;
        --help|-h)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ---------- Uninstall ----------
if [ "$ACTION" = "uninstall" ]; then
    echo "Uninstalling frigate-stack systemd units…"
    sudo systemctl disable --now frigate-stack.service            2>/dev/null || true
    sudo systemctl disable --now frigate-stack-watchdog.timer      2>/dev/null || true
    sudo rm -fv "$UNIT_DIR"/frigate-stack{,-watchdog.service,-watchdog.timer}
    sudo systemctl daemon-reload
    sudo systemctl reset-failed frigate-stack.service             2>/dev/null || true
    sudo systemctl reset-failed frigate-stack-watchdog.service    2>/dev/null || true
    echo
    echo "Done. Stack stopped and units removed."
    exit 0
fi

# ---------- Pre-flight ----------
command -v systemctl >/dev/null 2>&1 || { echo "ERROR: systemctl not found" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run as a normal user (uses sudo internally)." >&2; exit 1; }
for u in "${UNITS[@]}"; do
    [ -f "$REPO_DIR/$u" ] || { echo "ERROR: $REPO_DIR/$u not found" >&2; exit 1; }
done
sudo -n true 2>/dev/null || sudo -v || { echo "ERROR: sudo not available" >&2; exit 1; }

# ---------- Install ----------
echo "Installing systemd units to $UNIT_DIR…"
for u in "${UNITS[@]}"; do
    sudo cp -v "$REPO_DIR/$u" "$UNIT_DIR/$u"
done
echo

echo "Reloading systemd daemon…"
sudo systemctl daemon-reload
echo

echo "Enabling frigate-stack.service (runs on every boot)…"
sudo systemctl enable frigate-stack.service
echo

echo "Enabling and starting frigate-stack-watchdog.timer (re-checks every 5 min)…"
sudo systemctl enable --now frigate-stack-watchdog.timer
echo

# If a RECOVER_STRATEGY is set in the environment or in the repo's .env,
# write it into the watchdog unit's drop-in so the auto-recovery path
# uses the operator's preferred strategy (default: restart-container).
# Operators can override per-recovery by passing --recover=STRATEGY on
# the bring-up.sh command line.
RECOVER_STRATEGY_DEFAULT="restart-container"
if [ -f .env ]; then
    # shellcheck disable=SC1091
    RECOVER_FROM_ENV="$(grep -E '^RECOVER_STRATEGY=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [ -n "$RECOVER_FROM_ENV" ]; then
        RECOVER_STRATEGY_DEFAULT="$RECOVER_FROM_ENV"
    fi
fi
if [ "$RECOVER_STRATEGY_DEFAULT" != "restart-container" ]; then
    echo "Setting RECOVER_STRATEGY=$RECOVER_STRATEGY_DEFAULT in watchdog unit…"
    sudo mkdir -p /etc/systemd/system/frigate-stack-watchdog.service.d
    sudo tee /etc/systemd/system/frigate-stack-watchdog.service.d/recover-strategy.conf >/dev/null <<EOF
[Service]
Environment="RECOVER_STRATEGY=$RECOVER_STRATEGY_DEFAULT"
EOF
    sudo systemctl daemon-reload
fi
echo

echo "Starting frigate-stack.service now (so you do not have to reboot)…"
sudo systemctl start frigate-stack.service
echo

echo "Installation complete. Status:"
sudo systemctl status frigate-stack.service --no-pager -l | head -15
echo
echo "Watchdog timer schedule:"
sudo systemctl list-timers frigate-stack-watchdog.timer --no-pager | head -5

# ---------- Tail ----------
if [ "$TAIL_JOURNAL" -eq 1 ]; then
    echo
    echo "==================================================================="
    echo " Following the bring-up journal. Press Ctrl+C to stop watching."
    echo " (The bring-up can take up to 4 min on first run for TRT engine build.)"
    echo "==================================================================="
    sleep 2
    sudo journalctl -u frigate-stack.service -f --no-pager
fi
