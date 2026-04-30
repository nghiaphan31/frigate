#!/bin/bash
# Setup network mount for Frigate media storage
# This script should be run before starting docker-compose

NAS_HOST="nas"  # Tailscale hostname
NAS_SHARE="/volume1/frigate"
MOUNT_POINT="/mnt/nas/video/frigate"

echo "Setting up network mount via Tailscale..."
sudo mkdir -p "$MOUNT_POINT"
# Use Tailscale hostname - DNS should resolve via Tailscale
sudo mount -t nfs -o vers=3,soft,timeo=30 "$NAS_HOST:$NAS_SHARE" "$MOUNT_POINT"

echo "Mount setup complete. Run 'docker compose up -d' to start Frigate."