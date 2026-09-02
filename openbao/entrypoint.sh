#!/bin/sh
set -e

# ──────────────────────────────────────────────────────────────────────────
# OpenBao provisioning entrypoint.
# On first boot: init -> unseal -> enable KV v2 -> write policy -> seed
# secrets (from infra/.env, never hardcoded) -> create scoped app token.
# Idempotent: on restart it re-uses the persisted keys and re-seeds.
#
# Key storage (security):
#   - unseal.key + root.token live in /bao-keys  (root-only HOST dir, 0600).
#   - /shared holds ONLY the scoped app tokens (be.token/ai.token) + the
#     health marker. /shared is mounted read-only into app containers AND is
#     served by nginx (/bao-token/*) — so the root token must never live there.
# ──────────────────────────────────────────────────────────────────────────

export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
export BAO_SKIP_VERIFY=true

SHARED="/shared"
KEYS_DIR="/bao-keys"
mkdir -p "$SHARED"
mkdir -p "$KEYS_DIR"
chmod 700 "$KEYS_DIR"

echo "[openbao] starting server..."
bao server -config=/bao/config.hcl &
SERVER_PID=$!

trap 'echo "[openbao] stopping..."; kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; exit 0' TERM INT

wait_ready() {
  set +e   # `bao status` returns 2 while sealed — must not abort the script
  for i in $(seq 1 60); do
    bao status >/dev/null 2>&1
    code=$?
    # 0 = unsealed, 2 = sealed (server up), 1 = connection refused (not up yet)
    if [ "$code" -eq 0 ] || [ "$code" -eq 2 ]; then
      set -e
      return 0
    fi
    sleep 1
  done
  set -e
  echo "[openbao] ERROR: server did not become ready" >&2
  return 1
}

wait_ready

# ── Migration (first boot after this change) ──────────────────────────────
# Older deployments kept unseal.key + root.token in /shared. Move them to the
# hardened /bao-keys location so the root token is never exposed via /shared
# (which nginx now serves for app tokens). Idempotent.
if [ ! -f "$KEYS_DIR/unseal.key" ] && [ -f "$SHARED/unseal.key" ]; then
  echo "[openbao] migrating legacy keys from /shared to /bao-keys"
  cp "$SHARED/unseal.key" "$KEYS_DIR/unseal.key"
  cp "$SHARED/root.token" "$KEYS_DIR/root.token"
  rm -f "$SHARED/unseal.key" "$SHARED/root.token"
  chmod 600 "$KEYS_DIR/unseal.key" "$KEYS_DIR/root.token"
fi

# ── Initialize (one time — keys persist in the root-only host dir) ────────
if [ -f "$KEYS_DIR/unseal.key" ] && [ -f "$KEYS_DIR/root.token" ]; then
  echo "[openbao] already initialized (keys present in /bao-keys)"
  UNSEAL_KEY="$(cat "$KEYS_DIR/unseal.key")"
  ROOT_TOKEN="$(cat "$KEYS_DIR/root.token")"
elif bao operator init -status >/dev/null 2>&1; then
  echo "[openbao] ERROR: initialized but no unseal key in /bao-keys" >&2
  echo "        (bao-data persisted without ./.bao-keys? wipe both or restore the key)" >&2
  exit 1
else
  echo "[openbao] initializing (1 unseal share / 1 threshold — demo mode)"
  INIT_JSON="$(bao operator init -key-shares=1 -key-threshold=1 -format=json | tr -d '\n ')"
  UNSEAL_KEY="$(echo "$INIT_JSON" | sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)"\].*/\1/p')"
  ROOT_TOKEN="$(echo "$INIT_JSON" | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')"
  printf '%s' "$UNSEAL_KEY" > "$KEYS_DIR/unseal.key"
  printf '%s' "$ROOT_TOKEN" > "$KEYS_DIR/root.token"
  chmod 600 "$KEYS_DIR/unseal.key" "$KEYS_DIR/root.token"
  echo "[openbao] unseal key + root token saved to /bao-keys (root-only)"
fi

[ -n "$UNSEAL_KEY" ] || { echo "[openbao] ERROR: no unseal key found"; exit 1; }
[ -n "$ROOT_TOKEN" ] || { echo "[openbao] ERROR: no root token found"; exit 1; }

# ── Unseal ──────────────────────────────────────────────────────────────────
if bao status >/dev/null 2>&1; then
  echo "[openbao] already unsealed"
else
  echo "[openbao] unsealing..."
  bao operator unseal "$UNSEAL_KEY" >/dev/null
fi

export BAO_TOKEN="$ROOT_TOKEN"

# ── KV v2 secrets engine ────────────────────────────────────────────────────
bao secrets enable -path=secret kv-v2 2>/dev/null || echo "[openbao] kv-v2 already enabled at secret/"

# ── ACL policies for the service tokens ────────────────────────────────────
bao policy write be-read /policies/be-read.hcl >/dev/null
bao policy write ai-read /policies/ai-read.hcl >/dev/null
echo "[openbao] policies 'be-read' + 'ai-read' written"

# ── Seed secrets (values injected from infra/.env, never hardcoded) ─────────
# Values are written via the `@file` syntax so arbitrary content (JSON blobs,
# dollar signs, spaces) is stored verbatim.
seed_secret() {
  namespace="$1"
  key="$2"
  envvar="${3:-$key}"          # optional source env var (DEV_* override)
  value="$(eval "printf '%s' \"\${$envvar:-}\"")"
  if [ -z "$value" ] && [ "$envvar" != "$key" ]; then
    # No DEV_* override — fall back to the base (uat) value so the dev
    # namespace keeps its own independent entry with the shared value.
    value="$(eval "printf '%s' \"\${$key:-}\"")"
  fi
  if [ -n "$value" ]; then
    printf '%s' "$value" > /tmp/secret.val
    # `bao kv put` resolves `secret/<ns>/<key>` to the KV v2 API path
    # `secret/data/<ns>/<key>` (it auto-inserts the data/ segment).
    if bao kv put "secret/$namespace/$key" value=@/tmp/secret.val >/dev/null 2>&1; then
      echo "[openbao] seeded $namespace/$key"
    else
      echo "[openbao] WARN: could not seed $namespace/$key"
    fi
  else
    echo "[openbao] skip $namespace/$key (empty)"
  fi
}

# Backend (be + workers) secrets — namespace `talentos` (the UAT/deployed stack).
for key in \
  JWT_SECRET SECRETS_ENCRYPTION_KEY DATABASE_URL \
  RESEND_API_KEY SMTP_USERNAME SMTP_PASSWORD \
  GOOGLE_CLIENT_SECRET GOOGLE_SERVICE_ACCOUNT_JSON GOOGLE_IMPERSONATION_EMAIL \
  MEETMIND_API_TOKEN MEETMIND_WEBHOOK_SECRET \
  SUPABASE_SERVICE_ROLE_KEY SUPABASE_WEBHOOK_SECRET \
  RH_API_KEY SERVICE_API_KEY; do
  seed_secret talentos "$key"
done

# Backend dev namespace — `dev` (local dev). Independent of uat: every key is
# its own entry, sourced from a DEV_<KEY> override (e.g. DEV_DATABASE_URL must
# point at the local Supabase) falling back to the uat value when unset.
for key in \
  JWT_SECRET SECRETS_ENCRYPTION_KEY DATABASE_URL \
  RESEND_API_KEY SMTP_USERNAME SMTP_PASSWORD \
  GOOGLE_CLIENT_SECRET GOOGLE_SERVICE_ACCOUNT_JSON GOOGLE_IMPERSONATION_EMAIL \
  MEETMIND_API_TOKEN MEETMIND_WEBHOOK_SECRET \
  SUPABASE_SERVICE_ROLE_KEY SUPABASE_WEBHOOK_SECRET \
  RH_API_KEY SERVICE_API_KEY; do
  seed_secret dev "$key" "DEV_${key}"
done

# AI-service secrets — namespace `ai` (UAT/deployed; separate token + policy).
for key in OPENAI_API_KEY GROQ_API_KEY DATABASE_URI; do
  seed_secret ai "$key"
done

# AI-service dev namespace — `ai-dev` (local dev), DEV_<KEY> override fallback.
for key in OPENAI_API_KEY GROQ_API_KEY DATABASE_URI; do
  seed_secret ai-dev "$key" "DEV_${key}"
done

# ── Scoped service tokens (evergreen for this demo) ────────────────────────
create_app_token() {
  policy="$1"
  file="$2"
  TOKEN_JSON="$(bao token create -policy="$policy" -ttl=0 -format=json | tr -d '\n ')"
  TOKEN="$(echo "$TOKEN_JSON" | sed -n 's/.*"client_token":"\([^"]*\)".*/\1/p')"
  if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$SHARED/$file"
    echo "[openbao] token '$policy' written to /shared/$file"
  else
    echo "[openbao] ERROR: failed to create token for policy '$policy'" >&2
  fi
}

create_app_token be-read be.token
create_app_token ai-read ai.token

printf '%s' "ready" > "$SHARED/.bao-ready"
echo "[openbao] provisioning complete — ready"

wait "$SERVER_PID"
