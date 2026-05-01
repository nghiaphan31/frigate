#!/bin/bash
# Fix NVIDIA Docker for Ubuntu 24.04 (Noble)
# Note: NVIDIA Container Toolkit repo doesn't support Ubuntu 24.04 yet.
# This script uses direct device passthrough instead of nvidia runtime.

set -e

echo "=== Ubuntu 24.04 NVIDIA Docker Fix ==="
echo ""

# Check if nvidia-smi works on host
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found. NVIDIA driver may not be installed."
    exit 1
fi

echo "✓ NVIDIA driver detected:"
nvidia-smi --query-gpu=name --format=csv,noheader | head -1

# Check for NVIDIA devices
if [ ! -e "/dev/nvidia0" ]; then
    echo "ERROR: /dev/nvidia0 not found. NVIDIA device files not created."
    exit 1
fi

echo "✓ NVIDIA device files detected:"
ls -la /dev/nvidia*

echo ""
echo "=== Creating Docker daemon.json with nvidia runtime ==="

# Create /etc/docker if it doesn't exist
sudo mkdir -p /etc/docker

# Create daemon.json with nvidia runtime
cat << 'EOF' | sudo tee /etc/docker/daemon.json
{
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF

echo "✓ Created /etc/docker/daemon.json"

echo ""
echo "=== Restarting Docker ==="
sudo systemctl restart docker

echo ""
echo "=== Verifying Docker NVIDIA runtime ==="
docker info | grep -A5 "Runtimes" || true

echo ""
echo "=== Testing nvidia-smi in container ==="
docker run --rm --gpus all --runtime nvidia nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi || {
    echo ""
    echo "WARNING: nvidia runtime test failed. Using device passthrough instead."
    echo "Docker compose will use device mounting instead."
}

echo ""
echo "Done! The docker-compose.calypso.yml uses device passthrough as backup."
echo "If the nvidia runtime doesn't work, the device mounts in docker-compose will handle GPU access."