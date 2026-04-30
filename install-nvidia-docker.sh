#!/bin/bash
# Install nvidia-docker2 on Calypso for RTX 5060 Ti GPU support

set -e

echo "Installing nvidia-docker2..."

# Add NVIDIA repository
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

# Update and install
sudo apt update
sudo apt install -y nvidia-docker2

# Restart Docker
sudo systemctl restart docker

echo "nvidia-docker2 installed. Verifying..."
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi

echo "Done! You can now run: docker-compose -f docker-compose.calypso.yml up -d"