#!/bin/bash
# ============================================
# LXC post-install: Docker + Compose
# Runs inside the container via `pct exec -- bash -s`
# ============================================

set -e

export DEBIAN_FRONTEND=noninteractive

echo "[post-install] Updating apt index..."
apt-get update -qq

echo "[post-install] Installing base packages..."
apt-get install -y -qq --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    sudo \
    openssh-server

echo "[post-install] Installing Docker via get.docker.com..."
curl -fsSL https://get.docker.com | sh

echo "[post-install] Enabling Docker..."
systemctl enable --now docker

echo "[post-install] Verifying installation..."
docker --version
docker compose version || true

echo "[post-install] Done."
