#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# talentOS Deploy Script
# Run this on the Linode to update all services and restart.
# ──────────────────────────────────────────────────────────────────────────────

ROOT_DIR="/opt/talentos"
INFRA_REPO="https://github.com/avezqureshi15/talentOS_Infra.git"

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

  git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"

  # Create branch locally if not exists
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git checkout "$branch"
  else
    git checkout -b "$branch" "origin/$branch"
  fi

  git pull origin "$branch"
}

echo "=== talentOS Deploy ==="

# Ensure root directory exists
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# INFRA REPO (FIXED NAME: talentOS_Infra)
# ──────────────────────────────────────────────────────────────────────────────

if [ -d "talentOS_Infra/.git" ]; then
  echo "[infra] Pulling latest..."
  cd talentOS_Infra
  checkout_branch "talentOS_Infra" "$INFRA_BRANCH"
  cd ..
else
  echo "[infra] Cloning..."
  git clone --branch "$INFRA_BRANCH" "$INFRA_REPO" "talentOS_Infra"
  cd talentOS_Infra
fi

# Copy compose + configs
echo "[infra] Syncing configs..."
cp talentOS_Infra/docker-compose.yml .
cp -r talentOS_Infra/proxy . 2>/dev/null || true
cp -r talentOS_Infra/scripts . 2>/dev/null || true
cp -n talentOS_Infra/.env.example .env 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# SERVICES
# ──────────────────────────────────────────────────────────────────────────────

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
    git clone --branch "$branch" "$repo" "$dir"
    cd "$dir"
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# DOCKER DEPLOY
# ──────────────────────────────────────────────────────────────────────────────

echo "=== Building & restarting services ==="

# Pull latest images (if using remote images)
docker compose pull

# Rebuild and restart (minimal downtime)
docker compose up -d --build

echo "=== Deploy complete ==="
docker compose ps