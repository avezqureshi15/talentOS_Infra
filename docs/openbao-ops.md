# talentOS OpenBao — Operations

OpenBao is the central, encrypted secrets manager for talentOS. Real secrets
(JWT, DB, SMTP, Google, MeetMind, LLM keys, …) live **only** on the Linode
server — never in a developer's local `.env`. Local dev machines pull the
scoped app tokens from the server over HTTPS and read the secrets directly
from the server's OpenBao.

- **Server:** `root@172.235.29.16` (Linode)
- **Public OpenBao API:** `https://talentos.webknot-dev.in/v1/*` (IP-restricted)
- **Token bootstrap:** `https://talentos.webknot-dev.in/bao-token/{be,ai}.token`
  (IP-restricted **and** basic-auth protected)

---

## How access works

| Who | What they hold | How they get it |
|-----|----------------|-----------------|
| Server services (`be`, `ai`, workers) | scoped read-only tokens | `bao-shared` volume, docker network |
| Local dev machines | the same scoped tokens | HTTPS download (`/bao-token/*`) |
| Gatekeeper (1 admin, the only one with SSH) | server access + `.env` | root login |

Server services reach OpenBao over the internal docker network
(`http://openbao:8200`) — the public `/v1/*` route exists only for local dev.

Secrets stored:
- `secret/data/talentos/*` — backend + workers (`be.token`)
- `secret/data/ai/*` — AI service (`ai.token`)

Tokens are read-only (ACL policies `be-read` / `ai-read`) and evergreen.

---

## 1. Update a developer's IP

Everyone is on an IP allowlist (`/opt/talentos/.bao-allowlist.conf`, built from
`BAO_TOKEN_ALLOWED_IPS` in the server's `.env`). When a dev's public IP changes:

**Dev side** — run and send the result to the gatekeeper:

```bash
curl ifconfig.me
```

**Gatekeeper side (the only one with SSH):**

```bash
ssh root@172.235.29.16
cd /opt/talentos
nano .env          # edit BAO_TOKEN_ALLOWED_IPS, e.g.
                   #   BAO_TOKEN_ALLOWED_IPS="1.2.3.4 203.0.113.0/24 <new-ip>"
```

Apply — **always edit `.env`, never `.bao-allowlist.conf` directly**
(deploy.sh regenerates it from `.env` and would overwrite manual edits):

```bash
bash scripts/deploy.sh            # full deploy, or the light path:
```

Light path (no rebuild, ~seconds):

```bash
: > .bao-allowlist.conf
for ip in $BAO_TOKEN_ALLOWED_IPS; do printf 'allow %s;\n' "$ip" >> .bao-allowlist.conf; done
printf 'deny all;\n' >> .bao-allowlist.conf
docker compose restart proxy
```

Dev can now re-fetch tokens / use the API again. No dev-side change needed.

> Gotcha: dynamic residential IPs rotate often → each change is a ticket to the
> gatekeeper. If it becomes a pain, move to per-dev tokens or a VPN (see
> "Future hardening").

---

## 2. Change / add secrets in `.env`

The server's `/opt/talentos/.env` is the source of truth. OpenBao re-seeds
from it on every `openbao` container start, and consuming services re-read at
startup.

### Rotate an existing secret value

```bash
ssh root@172.235.29.16
cd /opt/talentos
nano .env                  # change e.g. JWT_SECRET / SMTP_PASSWORD / OPENAI_API_KEY
```

Apply:

```bash
docker compose up -d openbao            # re-seeds the changed value
docker compose up -d be ai worker-full worker-interview-report
```

Verify (on the server):

```bash
docker compose ps
curl -s -H "X-Vault-Token: $(cat .bao-keys/root.token)" \
  http://127.0.0.1:8200/v1/secret/data/talentos/JWT_SECRET
```

### Add a brand-new secret

A new secret key is only seeded if OpenBao knows about it:

1. Add `NEW_SECRET=value` to the server `.env`.
2. Add `NEW_SECRET` to the seed list in `openbao/entrypoint.sh`
   (`for key in ...` for the right namespace: `talentos` = backend, `ai` = AI).
3. If the app should read it: add it to the app's `BAO_SECRET_KEYS` /
   `_DEFAULT_BAO_KEYS` config (BE `app/core/config.py`, AI `settings.py`).
4. Commit + push, then deploy (see §4).

Mirror the change in `talentOS_Infra/.env.example` so it's documented.

---

## 3. Onboard a new developer (no SSH, no secrets on their laptop)

Prerequisite: the gatekeeper has added the dev's public IP to
`BAO_TOKEN_ALLOWED_IPS` (see §1) and shared `BAO_TOKEN_USER` / `BAO_TOKEN_PASS`.

### a) Clone the repos

```bash
mkdir talentos && cd talentos
git clone https://github.com/avezqureshi15/talentOS_Infra.git
git clone https://github.com/avezqureshi15/talentOS_BE.git
git clone https://github.com/avezqureshi15/talentOS_FE.git
git clone https://github.com/punith-webknot/talentOS_AI.git
git clone https://github.com/punith-webknot/talentOS_MCP.git
```

### b) Fetch the app tokens (works only from an allowlisted IP)

```bash
mkdir -p ~/.talentos
curl -u "$BAO_TOKEN_USER:$BAO_TOKEN_PASS" \
  https://talentos.webknot-dev.in/bao-token/be.token > ~/.talentos/be.token
curl -u "$BAO_TOKEN_USER:$BAO_TOKEN_PASS" \
  https://talentos.webknot-dev.in/bao-token/ai.token > ~/.talentos/ai.token
chmod 600 ~/.talentos/*.token
```

Sanity-check: wrong password → `401`, non-allowlisted IP → `403`.

### c) Point local services at the server's OpenBao

**talentOS_BE** — `.env`:

```bash
BAO_ADDR=https://talentos.webknot-dev.in
BAO_TOKEN_FILE=/path/to/home/.talentos/be.token
BAO_REQUIRED=true
```

**talentOS_AI** — `.env`:

```bash
BAO_ADDR=https://talentos.webknot-dev.in
BAO_TOKEN_FILE=/path/to/home/.talentos/ai.token
BAO_REQUIRED=true
```

Non-secret config stays local (`APP_ENV`, `LOG_LEVEL`, `LLM_PROVIDER`,
`MODEL_NAME`, `MCP_URL`, …). Real secret values are no longer needed locally.

### d) Verify

```bash
# backend
curl -s http://127.0.0.1:8001/health          # expect "secretsSource": "openbao"
# or directly:
curl -s https://talentos.webknot-dev.in/v1/sys/health
```

If anything fails, `BAO_REQUIRED=true` makes startup fail fast with a clear
message instead of silently falling back to empty env values.

---

## 4. Deploying a change to the server

Only the gatekeeper runs deploys. The server pulls from GitHub, so first push
the repos you changed:

```bash
# from the changed repo(s)
git add -A && git commit -m "..." && git push origin main
```

Then on the server:

```bash
ssh root@172.235.29.16
cd /opt/talentos
bash scripts/deploy.sh            # defaults: uat, all
# or a subset:
bash scripts/deploy.sh uat backend
```

`deploy.sh` pulls the repos, syncs configs, regenerates `.bao-htpasswd`,
`.bao-allowlist.conf`, and ensures `.bao-keys` exists, then rebuilds/restarts.

### Backups

Before touching the server, snapshot the live config:

```bash
TS=$(date +%s) && mkdir -p /root/bao-backup-$TS
cp /opt/talentos/docker-compose.yml /root/bao-backup-$TS/
cp /opt/talentos/proxy/nginx.conf /root/bao-backup-$TS/
cp /opt/talentos/.env /root/bao-backup-$TS/
docker run --rm -v talentos-infra_bao-shared:/shared -v /root/bao-backup-$TS:/bkp \
  alpine sh -c 'cp /shared/* /bkp/ 2>/dev/null || true'
```

---

## 5. Admin access (gatekeeper only)

OpenBao has no public UI. Admin via SSH tunnel:

```bash
ssh -L 8200:127.0.0.1:8200 root@172.235.29.16
# then browse http://127.0.0.1:8200/ui  (root token: /opt/talentos/.bao-keys/root.token)
```

The root token + unseal key live in `/opt/talentos/.bao-keys/` (root-only,
0600). The container auto-unseals at boot from there.

---

## 6. Later: switch to a dedicated subdomain

Once DNS access exists:

1. Add an A record `bao.talentos.webknot-dev.in` → `172.235.29.16`.
2. Issue a cert: `certbot certonly --nginx -d bao.talentos.webknot-dev.in`.
3. Add a dedicated nginx `server` block `server_name bao.talentos.webknot-dev.in;`
   with `location / { proxy_pass http://openbao:8200; }` (+ allowlist).
4. Point local devs at `BAO_ADDR=https://bao.talentos.webknot-dev.in`.
5. Optionally drop the `/v1/` block from the main domain.

No application code changes are needed (clients already use `/v1/*` absolute
paths).

---

## Security notes & future hardening

- App tokens are read-only and scoped, but **evergreen** (`-ttl=0`) and shared
  between devs — current tradeoff for a small team. Follow-ups:
  - per-developer tokens (a `dev-read` policy) with a 30–90 day TTL + revoke
  - OpenBao audit logging
  - `limit_req` on `/v1/*` and `/bao-token/*`
  - separate namespaces/instances per environment once dev != uat creds
- The unseal key lives on the same box as the encrypted data (single-VM design).
  `tls_disable = true` internally is fine — nginx terminates public TLS.
- Never commit `.env`, `.bao-keys/`, `.bao-htpasswd`, `.bao-allowlist.conf`.
