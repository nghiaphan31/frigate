#!/bin/bash
# Setup network mount for Frigate media storage
# This script should be run before starting docker-compose

NAS_HOST="192.168.50.232"  # Synology NAS local IP
NAS_SHARE="/volume1/video/frigate"
MOUNT_POINT="/mnt/nas/video/frigate"

echo "Setting up network mount..."
sudo mkdir -p "$MOUNT_POINT"
# Use local IP for NFS mount (same as NUC working config)
sudo mount -t nfs -o vers=4.2,soft,timeo=30 "$NAS_HOST:/volume1" "$MOUNT_POINT"

echo "Mount setup complete. Run 'docker compose up -d' to start Frigate."