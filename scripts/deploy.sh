#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# talentOS Deploy Script
# Run this on the Linode to update all services and restart.
# ──────────────────────────────────────────────────────────────────────────────

ROOT_DIR="/opt/talentos"
INFRA_REPO="https://github.com/avezqureshi15/talentOS-infra.git"
SERVICE_REPOS=(
  "talentOS_BE|https://github.com/avezqureshi15/talentOS_BE.git"
  "talentOS_FE|https://github.com/avezqureshi15/talentOS_FE.git"
  "talentOS_AI|https://github.com/punith-webknot/talentOS_AI.git"
  "talentOS_MCP|https://github.com/punith-webknot/talentOS_MCP.git"
)

echo "=== talentOS Deploy ==="

# Ensure root directory exists
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# Clone or pull infra repo
if [ -d "talentOS-infra/.git" ]; then
  echo "[infra] Pulling latest..."
  cd talentOS-infra && git pull && cd ..
else
  echo "[infra] Cloning..."
  git clone "$INFRA_REPO"
fi

# Copy compose file and proxy config to root
cp talentOS-infra/docker-compose.yml .
cp -r talentOS-infra/proxy .
cp -n talentOS-infra/.env.example .env 2>/dev/null || true

# Clone or pull each service repo
for entry in "${SERVICE_REPOS[@]}"; do
  IFS="|" read -r dir repo <<< "$entry"
  if [ -d "$dir/.git" ]; then
    echo "[$dir] Pulling latest..."
    cd "$dir" && git pull && cd ..
  else
    echo "[$dir] Cloning..."
    git clone "$repo" "$dir"
  fi
done

# Pull latest images and rebuild
echo "=== Building & restarting services ==="
docker compose pull
docker compose up -d --build

echo "=== Deploy complete ==="
docker compose ps
