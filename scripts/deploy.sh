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

# ── Source branch configuration ──────────────────────────────────────────
BRANCH_ENV="$(dirname "$0")/branches.env"
if [ -f "$BRANCH_ENV" ]; then
  # shellcheck source=./branches.env
  . "$BRANCH_ENV"
else
  echo "[warn] branches.env not found — using defaults (main)"
  BE_BRANCH=main
  FE_BRANCH=main
  MCP_BRANCH=main
  AI_BRANCH=main
  INFRA_BRANCH=main
fi

# ── Helper: checkout & pull a specific branch ────────────────────────────
checkout_branch() {
  local dir="$1"
  local branch="$2"
  echo "[$dir] Switching to branch '$branch'..."
  git fetch origin
  git checkout "$branch"
  git pull origin "$branch"
}

echo "=== talentOS Deploy ==="

# Ensure root directory exists
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# Clone or pull infra repo
if [ -d "talentOS-infra/.git" ]; then
  echo "[infra] Pulling latest..."
  cd talentOS-infra && checkout_branch "infra" "$INFRA_BRANCH" && cd ..
else
  echo "[infra] Cloning..."
  git clone "$INFRA_REPO"
  cd talentOS-infra && git checkout "$INFRA_BRANCH" 2>/dev/null || true && cd ..
fi

# Copy compose file, proxy config, and scripts to root
cp talentOS-infra/docker-compose.yml .
cp -r talentOS-infra/proxy .
cp -r talentOS-infra/scripts .
cp -n talentOS-infra/.env.example .env 2>/dev/null || true

# Clone or pull each service repo
for entry in "${SERVICE_REPOS[@]}"; do
  IFS="|" read -r dir repo <<< "$entry"

  case "$dir" in
    talentOS_BE) branch="${BE_BRANCH}" ;;
    talentOS_FE) branch="${FE_BRANCH}" ;;
    talentOS_AI) branch="${AI_BRANCH}" ;;
    talentOS_MCP) branch="${MCP_BRANCH}" ;;
    *) branch="main" ;;
  esac

  if [ -d "$dir/.git" ]; then
    echo "[$dir] Pulling latest (branch: $branch)..."
    cd "$dir"
    checkout_branch "$dir" "$branch"
    cd ..
  else
    echo "[$dir] Cloning (branch: $branch)..."
    git clone "$repo" "$dir"
    cd "$dir"
    git checkout "$branch" 2>/dev/null || true
    cd ..
  fi
done

# Pull latest images and rebuild
echo "=== Building & restarting services ==="
docker compose pull
docker compose up -d --build

echo "=== Deploy complete ==="
docker compose ps
