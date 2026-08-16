#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# talentOS Deploy Script
# Run on the Linode to update services and restart.
#
# Usage:
#   bash scripts/deploy.sh                                          # defaults: uat, all
#   bash scripts/deploy.sh <env> <component> [branch overrides...]
#
#   <env>       = environment name, e.g. uat | prod (branch defaults come from
#                 scripts/branches.<env>.env — add a file to support a new env)
#   <component> = all | frontend | backend | ai | mcp   (default: all)
#
#   Branch overrides (optional, win over the env default file):
#     --be-branch <branch>   --fe-branch <branch>
#     --ai-branch <branch>   --mcp-branch <branch>
#
# Examples:
#   bash scripts/deploy.sh
#   bash scripts/deploy.sh uat frontend --fe-branch my-feature
#   bash scripts/deploy.sh prod all
# ──────────────────────────────────────────────────────────────────────────────

ROOT_DIR="/opt/talentos"
INFRA_REPO="https://github.com/avezqureshi15/talentOS_Infra.git"

SERVICE_REPOS=(
  "talentOS_BE|https://github.com/avezqureshi15/talentOS_BE.git"
  "talentOS_FE|https://github.com/avezqureshi15/talentOS_FE.git"
  "talentOS_AI|https://github.com/punith-webknot/talentOS_AI.git"
  "talentOS_MCP|https://github.com/punith-webknot/talentOS_MCP.git"
)

# ── Parse arguments ───────────────────────────────────────────────────────
ENV_NAME="${1:-uat}"
COMPONENT="${2:-all}"
shift 2 || true

BE_OVERRIDE=""
FE_OVERRIDE=""
AI_OVERRIDE=""
MCP_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --be-branch)   BE_OVERRIDE="${2:?missing value for $1}"; shift 2 ;;
    --fe-branch)   FE_OVERRIDE="${2:?missing value for $1}"; shift 2 ;;
    --ai-branch)   AI_OVERRIDE="${2:?missing value for $1}"; shift 2 ;;
    --mcp-branch)  MCP_OVERRIDE="${2:?missing value for $1}"; shift 2 ;;
    *) echo "[error] unknown argument: $1"; exit 1 ;;
  esac
done

case "$COMPONENT" in
  frontend|backend|all|ai|mcp) ;;
  *) echo "[error] unsupported component '$COMPONENT' (expected: frontend | backend | all | ai | mcp)"; exit 1 ;;
esac

# ── Fail fast on unknown environment ──────────────────────────────────────
# A new environment = create scripts/branches.<env>.env (see branches.uat.env).
BRANCH_ENV="$(dirname "$0")/branches.${ENV_NAME}.env"

if [ ! -f "$BRANCH_ENV" ]; then
  echo "[error] environment '$ENV_NAME' is not configured."
  echo "        Expected '$BRANCH_ENV' — create it (copy branches.uat.env) or fix the env name."
  exit 1
fi

. "$BRANCH_ENV"
INFRA_BRANCH="${INFRA_BRANCH:-main}"

# CLI overrides win over the env defaults
[ -n "$BE_OVERRIDE" ]  && BE_BRANCH="$BE_OVERRIDE"
[ -n "$FE_OVERRIDE" ]  && FE_BRANCH="$FE_OVERRIDE"
[ -n "$AI_OVERRIDE" ]  && AI_BRANCH="$AI_OVERRIDE"
[ -n "$MCP_OVERRIDE" ] && MCP_BRANCH="$MCP_OVERRIDE"

# ── Validate branch names (no shell metacharacters / spaces) ──────────────
validate_branch_name() {
  local name="$1"
  case "$name" in
    *[!A-Za-z0-9._/-]*)
      echo "[error] invalid branch name '$name' (allowed chars: A-Z a-z 0-9 . _ / -)"
      exit 1
      ;;
  esac
}

validate_branch_name "$BE_BRANCH"
validate_branch_name "$FE_BRANCH"
validate_branch_name "$AI_BRANCH"
validate_branch_name "$MCP_BRANCH"
validate_branch_name "$INFRA_BRANCH"

# ── Component → repos + compose services ──────────────────────────────────
case "$COMPONENT" in
  frontend)
    SELECTED_REPOS=("talentOS_FE")
    BUILD_SERVICES=("fe")
    ;;
  backend)
    SELECTED_REPOS=("talentOS_BE" "talentOS_AI" "talentOS_MCP")
    BUILD_SERVICES=("be" "ai" "mcp" "worker-full" "worker-interview-report")
    ;;
  ai)
    SELECTED_REPOS=("talentOS_AI")
    BUILD_SERVICES=("ai")
    ;;
  mcp)
    SELECTED_REPOS=("talentOS_MCP")
    BUILD_SERVICES=("mcp")
    ;;
  all)
    SELECTED_REPOS=("talentOS_BE" "talentOS_FE" "talentOS_AI" "talentOS_MCP")
    BUILD_SERVICES=()   # empty = full stack rebuild
    ;;
esac

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

echo "=== talentOS Deploy (env: $ENV_NAME | component: $COMPONENT) ==="
echo "    branches -> be: $BE_BRANCH | fe: $FE_BRANCH | ai: $AI_BRANCH | mcp: $MCP_BRANCH"

# Ensure root directory exists
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# ──────────────────────────────────────────────────────────────────────────
# INFRA REPO (FIXED NAME: talentOS_Infra)
# ──────────────────────────────────────────────────────────────────────────

if [ -d "talentOS_Infra/.git" ]; then
  echo "[infra] Pulling latest..."
  cd talentOS_Infra
  checkout_branch "talentOS_Infra" "$INFRA_BRANCH"
  cd ..
else
  echo "[infra] Cloning..."
  git clone --branch "$INFRA_BRANCH" "$INFRA_REPO" "talentOS_Infra"
  cd talentOS_Infra
  cd ..
fi

# Copy compose + configs
echo "[infra] Syncing configs..."
cp talentOS_Infra/docker-compose.yml .
cp -r talentOS_Infra/proxy . 2>/dev/null || true
cp -r talentOS_Infra/scripts . 2>/dev/null || true
cp -r talentOS_Infra/openbao . 2>/dev/null || true
cp -n talentOS_Infra/.env.example .env 2>/dev/null || true

# ── OpenBao runtime artifacts (git-ignored, derived from .env) ──────────────
# .bao-keys  → root-only host dir for the unseal key + root token (openbao only).
# .bao-htpasswd → basic-auth credentials for the /bao-token/* download route.
# .bao-allowlist.conf → nginx allow/deny for /v1/* + /bao-token/* (dev IPs).
# These are regenerated on every deploy so edits to .env are always applied.
mkdir -p .bao-keys && chmod 700 .bao-keys

# The main .env is NOT sourced by this script — read the OpenBao bootstrap
# vars straight from the file (strips optional surrounding double quotes).
get_env() { grep -E "^$1=" .env 2>/dev/null | tail -n 1 | sed -E 's/^[^=]*=//' | sed -E 's/^"(.*)"$/\1/'; }
BAO_TOKEN_USER="${BAO_TOKEN_USER:-$(get_env BAO_TOKEN_USER)}"
BAO_TOKEN_PASS="${BAO_TOKEN_PASS:-$(get_env BAO_TOKEN_PASS)}"
BAO_TOKEN_ALLOWED_IPS="${BAO_TOKEN_ALLOWED_IPS:-$(get_env BAO_TOKEN_ALLOWED_IPS)}"

if [ -n "$BAO_TOKEN_USER" ] && [ -n "$BAO_TOKEN_PASS" ]; then
  printf '%s\n' "$BAO_TOKEN_USER:$(openssl passwd -apr1 "$BAO_TOKEN_PASS")" > .bao-htpasswd
  # 644 (not 600): the nginx WORKER (user nginx) reads this at request time,
  # and bind-mounts don't remap ownership — 600 root-only causes nginx 500.
  chmod 644 .bao-htpasswd
else
  echo "[infra] WARN: BAO_TOKEN_USER / BAO_TOKEN_PASS unset — /bao-token/* will be disabled (nginx 500)."
  : > .bao-htpasswd
fi

: > .bao-allowlist.conf
for ip in $BAO_TOKEN_ALLOWED_IPS; do
  [ -n "$ip" ] && printf 'allow %s;\n' "$ip" >> .bao-allowlist.conf
done
printf 'deny all;\n' >> .bao-allowlist.conf
chmod 600 .bao-allowlist.conf

# ──────────────────────────────────────────────────────────────────────────
# SERVICES (only repos needed for this component)
# ──────────────────────────────────────────────────────────────────────────

for entry in "${SERVICE_REPOS[@]}"; do
  IFS="|" read -r dir repo <<< "$entry"

  case "$dir" in
    talentOS_BE) branch="${BE_BRANCH}" ;;
    talentOS_FE) branch="${FE_BRANCH}" ;;
    talentOS_AI) branch="${AI_BRANCH}" ;;
    talentOS_MCP) branch="${MCP_BRANCH}" ;;
    *) branch="main" ;;
  esac

  # Skip repos not part of this component
  found=0
  for s in "${SELECTED_REPOS[@]}"; do
    [ "$s" = "$dir" ] && found=1
  done
  if [ "$found" != "1" ]; then
    echo "[$dir] skipped (component: $COMPONENT)"
    continue
  fi

  if [ -d "$dir/.git" ]; then
    echo "[$dir] Pulling latest (branch: $branch)..."
    cd "$dir"
    checkout_branch "$dir" "$branch"
    cd ..
  else
    echo "[$dir] Cloning (branch: $branch)..."
    git clone --branch "$branch" "$repo" "$dir"
    cd "$dir"
    cd ..
  fi
done

# ──────────────────────────────────────────────────────────────────────────
# DOCKER DEPLOY
# ──────────────────────────────────────────────────────────────────────────

echo "=== Building & restarting services (component: $COMPONENT) ==="

if [ "${#BUILD_SERVICES[@]}" -eq 0 ]; then
  # Pull latest images (if using remote images)
  docker compose pull

  # Rebuild and restart (minimal downtime)
  docker compose up -d --build
else
  docker compose up -d --build "${BUILD_SERVICES[@]}"
fi

# Restart proxy so nginx re-resolves service hostnames (container IPs change on recreate)
docker compose restart proxy 2>/dev/null || docker restart talentos-proxy-1 || true

echo "=== Deploy complete (env: $ENV_NAME | component: $COMPONENT) ==="
docker compose ps
