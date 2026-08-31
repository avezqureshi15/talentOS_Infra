# talentOS Infra

Deployment configuration for the talentOS stack — a single-node Docker Compose setup running all services behind an nginx reverse proxy.

## Architecture

```
                          ┌──────────┐
                          │  nginx   │  :80
                          │  proxy   │
                          └────┬─────┘
                    ┌──────────┴──────────┐
                    ▼                     ▼
              ┌──────────┐         ┌──────────┐
              │   FE     │         │   BE     │  :8001
              │ (nginx)  │         │ (uvicorn) │
              └──────────┘         └────┬─────┘
                                    ┌───┴────┐
                                    ▼        ▼
                              ┌─────────┐ ┌──────────┐
                              │  MCP    │ │ Worker   │
                              │:8000    │ │ (Kafka   │
                              └─────────┘ │ consumer)│
                                          └──────────┘
                              ┌─────────┐
                              │   AI    │  :8003
                              │(uvicorn)│
                              └─────────┘
                              ┌──────────┐
                              │ Postgres │  :5432
                              │ 17-alpine │
                              └──────────┘
                              ┌──────────┐
                              │ Redpanda │  :9092
                              │ (Kafka)  │
                              └──────────┘
                              ┌──────────┐
                              │ OpenBao  │  :8200
                              │ (secrets)│
                              └──────────┘
```

### Proxy Routing

- `/*` → **FE** (nginx serving static build)
- `/api/*` → **BE** (FastAPI backend)
- `/recruithub/hr` → **Recruithub HR** (minimal stack)
- `/recruithub/candidate` → **Recruithub candidate**
- `/recruithub/api` → **Recruithub API** (browser only; TalentOS BE uses Docker DNS)
- `/health` → **BE** (health check, exact match)

### Services

| Service | Image | Port | Language |
|---------|-------|------|----------|
| **proxy** | nginx:alpine | 80 | nginx config |
| **fe** | talentos-fe (Dockerfile) | 80 | React / Vite |
| **be** | talentos-be (Dockerfile) | 8001 | Python / FastAPI |
| **ai** | talentos-ai (Dockerfile) | 8003 | Python / FastAPI |
| **mcp** | talentos-mcp (Dockerfile) | 8000 | Python / MCP |
| **worker** | talentos-worker (Dockerfile) | — | Python / Kafka |
| **postgres** | postgres:17-alpine | 5432 | PostgreSQL |
| **redpanda** | redpandadata/redpanda:v24.2.7 | 9092 | Kafka-compatible |
| **openbao** | openbao/openbao (openbao/) | 8200 (host-local) | Secrets manager |

## Repositories

The infra repo clones 5 service repos at deploy time:

| Repo | URL |
|------|-----|
| talentOS_BE | https://github.com/avezqureshi15/talentOS_BE.git |
| talentOS_FE | https://github.com/avezqureshi15/talentOS_FE.git |
| talentOS_AI | https://github.com/punith-webknot/talentOS_AI.git |
| talentOS_MCP | https://github.com/punith-webknot/talentOS_MCP.git |
| talentOS_AI_II | https://github.com/avezqureshi15/talentOS_AI_II.git (Recruithub, minimal stack) |

## Recruithub (co-located, minimal)

Recruithub runs as a **second compose project** (`recruithub`) from `/opt/talentos/talentOS_AI_II/docker-compose.minimal.yml`. One of each service, Celery `--autoscale=3,1`. No Recruithub host ports.

**Public (same TalentOS nginx / cert):**

- `https://talentos.webknot-dev.in/` — TalentOS FE
- `https://talentos.webknot-dev.in/recruithub/hr` — Recruithub HR
- `https://talentos.webknot-dev.in/recruithub/candidate` — Recruithub candidate
- `https://talentos.webknot-dev.in/recruithub/api` — Recruithub API for the **browser** only

**Internal Docker DNS (`talentos_talentos-net`):**

- TalentOS BE → Recruithub: set tenant `RH_SERVICE_URL` to `http://rh-api:8000`
- Recruithub → TalentOS BE: `TALENTOS_BE_URL=http://be:8001` in Recruithub `.env.production`

`frontend` / `backend` / `ai` / `mcp` deploys skip Recruithub. `all` and `recruithub` build it.

### One-time host setup (before the old Recruithub servers are wiped)

Do this on `172.235.29.16` as root. `deploy.sh` will **not** create secrets or copy the database.

1. **Swap** (current 496 MB swap is full):

```bash
fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

2. **Clone the Recruithub repo** (or let the first `recruithub` deploy clone it), then copy secrets from `172.235.26.25`:

```bash
# on the old Recruithub app server
# seed.env and .env.production — scp them to:
#   /opt/talentos/talentOS_AI_II/seed.env
#   /opt/talentos/talentOS_AI_II/.env.production
```

Then rewrite Recruithub **seed.env** (not `.env.production`) so OpenBao has Docker DNS and TalentOS SMTP:

- Copy [seed.env.example](https://github.com/avezqureshi15/talentOS_AI_II/blob/main/seed.env.example). Recruithub apps do **not** load `.env`.
- Set Docker-DNS URLs: `TALENTOS_BE_URL=http://be:8001`, `DATABASE_URL` → `rh-postgres`, `REDIS_URL` → `rh-redis`.
- **SMTP:** copy `SMTP_USERNAME` and `SMTP_PASSWORD` from `/opt/talentos/.env` into Recruithub `seed.env` (same mailbox). `SMTP_HOST=smtp.gmail.com`.
- Confirm `TALENTOS_NETWORK` with `docker network ls` (usually `talentos_talentos-net`).

On TalentOS, add `RH_SERVICE_URL=http://rh-api:8000` to `/opt/talentos/.env` (OpenBao seed only), then restart `openbao` + `be`.

3. **Dump Postgres** from the old app server and restore after the first Recruithub `up`:

```bash
# old server
docker exec ai_recruitment_postgres pg_dump -U postgres -d ai_recruitment -Fc > /tmp/rh.dump

# TalentOS server (after recruithub postgres is healthy)
docker compose --env-file /opt/talentos/talentOS_AI_II/.env.production \
  -f /opt/talentos/talentOS_AI_II/docker-compose.minimal.yml --project-name recruithub \
  exec -T rh-postgres pg_restore -U postgres -d ai_recruitment --clean --if-exists < /tmp/rh.dump
```

4. In TalentOS superadmin, set tenant **RH_SERVICE_URL** to `http://rh-api:8000`.

5. Deploy: GitHub Action component `recruithub` (or `all`), or on the box:

```bash
bash /opt/talentos/talentOS_Infra/scripts/deploy.sh uat recruithub
```

No new DNS or certificates. Recruithub OpenBao is not published on the host (TalentOS already uses `127.0.0.1:8200`).

## Quick Start

### Prerequisites

- Docker + Docker Compose
- Git
- `.env` file with secrets (copy from `.env.example`)

### Local Dev

```bash
# Clone all repos side-by-side with talentOS-infra
git clone <talentOS_BE_URL>
git clone <talentOS_FE_URL>
git clone <talentOS_AI_URL>
git clone <talentOS_MCP_URL>

# Copy infra files to root
cp talentOS-infra/docker-compose.yml .
cp -r talentOS-infra/proxy .
cp -r talentOS-infra/scripts .
cp talentOS-infra/.env.example .env

# Edit .env with your secrets, then
docker compose up -d --build
```

### Production (Linode)

```bash
# On a fresh Linode:
git clone git@github.com:avezqureshi15/talentOS_Infra.git
cd talentOS_Infra
cp .env.example .env
# Edit .env with production secrets
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

The `deploy.sh` script:
1. Clones/pulls all service repos (from per-env branches, see below)
2. Copies `docker-compose.yml`, `proxy/`, and `scripts/` to `/opt/talentos/`
3. Runs `docker compose up -d --build`

### Deploying via GitHub Actions

`deploy.sh` is environment- and component-aware, and can be driven manually or
through the CI/CD workflow (`.github/workflows/deploy.yml`):

- **Manual (old way):** `./scripts/deploy.sh` — UAT, all, env-default branches.
- **Manual (new way):** `./scripts/deploy.sh prod frontend --fe-branch my-feature`
- **GitHub Actions:** `Actions` tab → *Deploy talentOS* → pick inputs.

Workflow inputs:

| Input | Options | Notes |
|-------|---------|-------|
| `environment` | `uat`, `prod` (add more in the YAML) | Branch defaults come from `scripts/branches.<env>.env` |
| `component` | `all`, `frontend`, `backend`, `ai`, `mcp`, `recruithub` | Only builds/pulls the repos it needs |
| `be_branch`, `fe_branch`, `ai_branch`, `mcp_branch`, `rh_branch` | any branch | Optional; blank = that env's default |

Every run (and manual scripts) also:
- Fails fast if the env name has no `branches.<env>.env`
- Rejects branch names with spaces/shell metacharacters
- Verifies each chosen branch actually **exists** in its repo (skips the check
  with a warning if the repo is private and no auth is available)

**One-time setup per environment (GitHub → Settings → Environments):**
- Create an environment named `uat` and one named `prod`, each with secrets
  `SSH_HOST`, `SSH_USER`, and either `SSH_PASSWORD` (password auth, default)
  or `SSH_KEY` (private key auth). The SSH user needs docker access (`docker
  compose` works) and must be able to `git pull` in `/opt/talentos/talentOS_Infra`.
- To add a NEW environment later: add a dropdown option in `deploy.yml`,
  create `scripts/branches.<env>.env`, and a GitHub Environment with its secrets.

**Restricting branches (optional, off by default):**
`scripts/branch-policy.json` holds per-env, per-repo allowlists. Empty list =
any branch allowed. To lock a production env later, e.g.:

```jsonc
{ "prod": { "fe": ["main", "release/*"], "be": ["main"] } }
```

### Quick Start

### First-Time Database

On a fresh Postgres volume, `init-db.sh` runs automatically:
- **If `SUPABASE_URL` is set** — dumps all data from Supabase and restores into local Postgres
- **If `SUPABASE_URL` is empty** — skips migration; the BE seed script populates dev data

To re-run migration (wipes data):
```bash
docker compose down
docker volume rm talentos_postgres_data
docker compose up -d
```

## Configuration

### `.env` Key Variables

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | Local Postgres connection string (default: `postgresql://talentos:talentos@postgres:5432/talentos`) |
| `SUPABASE_URL` | Supabase connection string for one-time migration |
| `LLM_PROVIDER` | LLM provider switch for the AI agent: `openai` or `groq` |
| `OPENAI_API_KEY` | OpenAI API key (used when `LLM_PROVIDER=openai`) |
| `GROQ_API_KEY` | Groq API key (used when `LLM_PROVIDER=groq`) |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID |
| `JWT_SECRET` | JWT signing secret |
| `LINODE_PUBLIC_IP` | Server IP for CORS (use `localhost` for local dev) |
| `APP_ENV` | `development` or `production` |

## OpenBao (Secrets Management)

talentOS uses [OpenBao](https://openbao.org) as a central, encrypted secrets
store. The backend (`be` + workers) fetches credentials from OpenBao at
startup instead of trusting `.env` — infra lives in `openbao/`.

### How it works

- The `openbao` container self-provisions on first boot
  (`openbao/entrypoint.sh`): initialize → unseal → enable KV v2 at `secret/`
  → write the `be-read` + `ai-read` ACL policies → seed secrets (injected
  from `infra/.env`) → mint scoped service tokens.
- The unseal key + root token persist in `./.bao-keys/` (root-only host dir,
  `0600`) — **not** in the `bao-shared` volume, because `bao-shared` is mounted
  into app containers and served by nginx. The `bao-shared` volume holds only
  the scoped app tokens. Tokens are **read-only**
  (`openbao/policies/be-read.hcl`, `openbao/policies/ai-read.hcl`) and only
  cover their own namespaces: `secret/data/talentos/*` (backend) and
  `secret/data/ai/*` (AI service).
- `be`, `worker-full`, `worker-interview-report` mount `bao-shared` read-only
  and use `BAO_ADDR=http://openbao:8200` + `BAO_TOKEN_FILE=/shared/be.token`.
  `ai` uses `BAO_TOKEN_FILE=/shared/ai.token` and reads
  `OPENAI_API_KEY` / `GROQ_API_KEY` / `DATABASE_URI` from OpenBao (no secrets
  in its environment). The backend's `app/core/config.py` pulls its secrets at
  startup; `GET /health` reports `"secretsSource": "openbao"` when active.
- OpenBao is reachable on the compose network only; the host sees `:8200` on
  `127.0.0.1:8200` for admin access.

### Local dev (read secrets from the server — no `.env` secrets, no SSH)

Server services use the docker network; **local dev machines** use the public
routes exposed through nginx on the existing `talentos.webknot-dev.in` cert:

- `GET https://talentos.webknot-dev.in/v1/*` — OpenBao API (IP-restricted)
- `GET https://talentos.webknot-dev.in/bao-token/{be,ai}.token` — app tokens
  (IP-restricted **and** basic-auth protected)

Devs fetch their tokens with `curl -u <BAO_TOKEN_USER>:<BAO_TOKEN_PASS> ...`,
then set `BAO_ADDR=https://talentos.webknot-dev.in` +
`BAO_TOKEN_FILE=~/.talentos/{be,ai}.token` (+ `BAO_REQUIRED=true`) in their
service `.env`. Full onboarding, IP-change, and secret-rotation runbooks live
in [docs/openbao-ops.md](docs/openbao-ops.md).

### Rotating a secret

1. Change the value in `infra/.env`.
2. `docker compose up -d openbao be` — openbao re-seeds on restart, `be`
   restarts and fetches the new value.

### Notes / production hardening

- Demo uses a single unseal key (1 share / 1 threshold) stored in the
  root-only host dir — use a real seal mechanism (cloud KMS / Shamir split
  keys) for production.
- The app token is evergreen (`-ttl=0`) — prefer short TTLs + renewal, or
  AppRole / Kubernetes auth for workload identity.
- `tls_disable = true` in `config.hcl` — nginx terminates public TLS; OpenBao
  itself stays on the docker network + `127.0.0.1`.

## Useful Commands

```bash
# All services must be healthy before the app works
docker compose ps

# Tail logs for a specific service
docker compose logs -f be
docker compose logs -f ai
docker compose logs -f postgres

# Rebuild a single service
docker compose up -d --build <service>

# Restart the whole stack
docker compose down
docker compose up -d

# Check health (via proxy)
curl http://localhost/health

# Execute SQL in postgres
docker exec -it talentos-postgres-1 psql -U talentos -d talentos

# Wipe everything (containers + volumes)
docker compose down -v
```

## Troubleshooting

| Problem | Likely Fix |
|---------|------------|
| `502 Bad Gateway` | BE needs more time to start (migrations running). Wait 30s. |
| `relation "forms" does not exist` | Run `init-db.sh` by wiping the postgres volume with `SUPABASE_URL` set. |
| `pg_dump: server version mismatch` | Postgres version must match Supabase (currently PG 17). |
| `CREATE INDEX CONCURRENTLY` error in AI | `AsyncConnectionPool` needs `kwargs={"autocommit": True}` in `main.py`. |
| Kafka topic not available | Auto-created on first produce; harmless startup warning. |
| FE shows blank screen | Check `VITE_BE_API_BASE_URL` in FE build args — must point to `/api/v1`. |
