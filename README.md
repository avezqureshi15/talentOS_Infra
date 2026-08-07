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
```

### Proxy Routing

- `/*` → **FE** (nginx serving static build)
- `/api/*` → **BE** (FastAPI backend)
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

## Repositories

The infra repo clones 4 service repos at deploy time:

| Repo | URL |
|------|-----|
| talentOS_BE | https://github.com/avezqureshi15/talentOS_BE.git |
| talentOS_FE | https://github.com/avezqureshi15/talentOS_FE.git |
| talentOS_AI | https://github.com/punith-webknot/talentOS_AI.git |
| talentOS_MCP | https://github.com/punith-webknot/talentOS_MCP.git |

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
| `component` | `all`, `frontend`, `backend`, `ai`, `mcp` | Only builds/pulls the repos it needs |
| `be_branch`, `fe_branch`, `ai_branch`, `mcp_branch` | any branch | Optional; blank = that env's default |

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
| `OPENAI_API_KEY` | OpenAI API key for AI agent |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID |
| `JWT_SECRET` | JWT signing secret |
| `LINODE_PUBLIC_IP` | Server IP for CORS (use `localhost` for local dev) |
| `APP_ENV` | `development` or `production` |

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
