# talentOS Architecture

## Overview

talentOS is composed of **4 microservices** and **2 infrastructure dependencies** deployed on a single Linode server using Docker Compose. A reverse proxy (nginx) sits in front of all services, providing a single entry point to the internet.

---

## Services

| Service | Role | Port (internal) | Exposed to Internet |
|---------|------|-----------------|---------------------|
| `fe` | React.js SPA served via nginx | `80` | No (behind proxy) |
| `be` | FastAPI backend (REST API) | `8001` | No (behind proxy) |
| `worker` | Kafka consumer (same image as `be`) | — | No |
| `ai` | LangChain AI service (resume eval, chat) | `8003` | No |
| `mcp` | FastMCP tool server (data bridge for AI) | `8000` | No |
| `proxy` | nginx reverse proxy | `80` | **Yes** — single entry point |
| `redpanda` | Kafka-compatible message broker | `9092`, `9644` | Optional (for external producers) |

### Dependencies

| Dependency | Type | Location |
|-----------|------|----------|
| Supabase | PostgreSQL database + Storage | Cloud (managed) |
| OpenAI | LLM API | Cloud (managed) |

---

## Communication Flow

```
Internet
    │
    ▼
┌──────────────────────────────────────────────────────────┐
│                   nginx (proxy :80)                       │
│                                                          │
│   /api/*  ──────────────────────────────────────────┐    │
│   /*      ──────────────────────┐                   │    │
└─────────────────────────────────│───────────────────│────┘
                                  │                   │
                                  ▼                   ▼
                          ┌─────────────┐    ┌──────────────┐
                          │  fe (nginx) │    │   be (uvicorn)│
                          │  :80        │    │   :8001       │
                          └─────────────┘    └───────┬───────┘
                                                      │
                                          ┌───────────┼───────────┐
                                          ▼           ▼           ▼
                                   ┌──────────┐ ┌────────┐ ┌─────────┐
                                   │  worker  │ │  redpanda│ │ supabase│
                                   │  :8001   │ │  :29092 │ │ (cloud) │
                                   └──────────┘ └─────────┘ └─────────┘
                                                      │
                                                      ▼
                                              ┌──────────────┐
                                              │  ai (uvicorn) │
                                              │  :8003        │
                                              └───────┬───────┘
                                                      │
                                                      ▼
                                              ┌──────────────┐
                                              │  mcp (FastMCP)│
                                              │  :8000        │
                                              └───────┬───────┘
                                                      │
                                                      ▼
                                              ┌──────────────┐
                                              │  be :8001     │
                                              │  (via HTTP)   │
                                              └──────────────┘
```

### Request Paths

#### User loads the web app
```
Browser ──GET http://<linode-ip>/──▶ proxy:80 ──▶ fe:80 ──▶ index.html + JS
```

#### User clicks "View Applications" (API call from JS)
```
Browser ──GET /api/v1/applications ──▶ proxy:80
                                          │
                                          ▼
                                    be:8001/api/v1/applications
                                          │
                                          ▼
                                    Supabase (query)
                                          │
                                          ▼
                                    JSON response ──▶ proxy ──▶ Browser
```

#### Resume evaluation pipeline
```
be:8001 receives resume upload
    │
    ├── publishes to redpanda:29092 (Kafka topic: resume.evaluation.queue)
    │
    ▼
worker:8001 (Kafka consumer) picks up the message
    │
    ├── POST http://ai:8003/api/v1/evaluation/
    │
    ▼
ai:8003 receives evaluation request
    │
    ├── Connects to mcp:8000/mcp (FastMCP over HTTP)
    │   ├── Calls MCP tool: get_job_by_id()
    │   │   └── MCP calls http://be:8001/api/v1/hiring-requests/{id}
    │   ├── Calls MCP tool: get_designation_detail()
    │   │   └── MCP calls http://be:8001/api/v1/designation
    │   │
    │   ▼
    ├── Constructs prompt with job details + resume
    ├── Calls OpenAI API
    │
    ▼
    Returns evaluation result to worker
        │
        ▼
    worker writes result back to be (DB)
```

#### AI Chat (supervisor agent)
```
User sends message → be:8001 → (proxies to) ai:8003/api/v1/chat/
    │
    ├── AI supervisor agent decides which sub-agent to call
    ├── Sub-agent uses MCP tools (via ai→mcp→be)
    │
    ▼
    Response streamed back to user
```

---

## Network Architecture

### Docker Network

All services connect to a single bridge network `talentos-net`. Docker DNS resolves container names to internal IPs automatically.

| From | To | URL | Resolves To |
|------|----|-----|-------------|
| Browser | proxy | `http://<linode-ip>` | Linode public IP |
| proxy | fe | `http://fe:80` | Docker DNS |
| proxy | be | `http://be:8001` | Docker DNS |
| be | redpanda | `redpanda:29092` | Docker DNS (Kafka) |
| be | ai | `http://ai:8003` | Docker DNS |
| worker | redpanda | `redpanda:29092` | Docker DNS (Kafka) |
| worker | ai | `http://ai:8003` | Docker DNS |
| ai | mcp | `http://mcp:8000/mcp` | Docker DNS (FastMCP) |
| mcp | be | `http://be:8001` | Docker DNS (HTTP) |

No service uses `localhost` or `host.docker.internal` — all communication is through Docker DNS.

### Port Exposure

```
Linode Public IP
    │
    └── :80  ──▶ proxy (nginx)
    │
    └── :9092 ──▶ redpanda (Kafka — optional, for external producers)
```

All other ports (`:8001`, `:8003`, `:8000`, `:29092`, `:9644`) are internal to the Docker network and NOT exposed to the internet.

---

## Why a Single Linode (Single Node)

### Advantages

| Factor | Single Node | Multiple Nodes |
|--------|------------|----------------|
| **Latency** | Sub-millisecond (same Docker network) | Network hop per request (~5-20ms each way) |
| **Cost** | 1 × Linode ($12-24/mo) | 3-4 × Linodes ($36-96/mo) |
| **Complexity** | One `docker-compose up`, one SSH session | Multi-server orchestration, VPN/VPC, TLS between services |
| **Debugging** | `docker logs` on one machine | SSH to multiple machines, correlate logs manually |
| **Deploy** | One script | CI/CD pipeline per service |

### Why This Architecture Specifically Benefits from Single Node

The **circular dependency** between BE → AI → MCP → BE means every resume evaluation makes 3 inter-service hops:

```
be → ai  (HTTP)
ai → mcp (FastMCP over HTTP)
mcp → be (HTTP)
```

On a single node, this roundtrip takes **<5ms total**. Across separate Linodes, it would be **30-100ms+** (3 public network hops + TCP handshakes).

Additionally, Kafka (Redpanda) requires low-latency, reliable connections. Network jitter between machines can cause consumer rebalances, message duplication, or processing delays.

### When to Split to Multiple Nodes

| Trigger | Split Recommendation |
|---------|---------------------|
| AI service consistently uses >80% CPU | Move `ai` + `mcp` to a dedicated compute-optimized Linode |
| FE needs to serve 10k+ concurrent users | Move `fe` behind a CDN (Cloudflare, AWS CloudFront); `proxy` can stay or be replaced by CDN |
| Redpanda requires dedicated IOPS | Move `redpanda` to a storage-optimized Linode |
| Team needs independent deploy cycles | Split by service boundaries (but keep BE + worker + redpanda together) |

---

## Why nginx Reverse Proxy

### Problem: CORS (Cross-Origin Resource Sharing)

Without a reverse proxy, the FE (port 80) and BE (port 8001) are on different origins. When JavaScript running on `http://<linode-ip>:80` makes a request to `http://<linode-ip>:8001`, the browser:

1. Sends an `OPTIONS` preflight request to check allowed origins
2. BE must respond with `Access-Control-Allow-Origin: http://<linode-ip>:80`
3. Only then does the actual request proceed

This adds latency to every API call and requires the BE to manage CORS headers.

### Solution: Same Origin

The reverse proxy makes all traffic appear to come from the same origin (`http://<linode-ip>:80`):

```
Browser sees:  fetch("/api/v1/applications")
                  │
nginx sees:       └── /api/v1/applications → proxy_pass to http://be:8001/api/v1/applications
```

No preflight, no CORS headers needed. The browser never knows BE exists on a different port.

### Additional Benefits

| Concern | Without Proxy | With Proxy |
|---------|--------------|------------|
| Public ports | `:80` (FE) + `:8001` (BE) | Only `:80` |
| SSL/TLS | Need cert on FE + BE | Single cert on proxy |
| BE attack surface | Swagger/docs exposed on `:8001` | BE fully internal, no public route |
| URL changes | Rebuild FE if IP/domain changes | Relative paths (`/api/v1/...`) — no rebuild needed |
| Rate limiting | Per-service implementation | Centralized in nginx |

---

## Environment Variables (`.env`)

### Single Source of Truth

On the Linode, a single `/opt/talentos/.env` file holds ALL environment variables for ALL services.

```
/opt/talentos/
├── docker-compose.yml      ← references .env via env_file: and ${VAR}
├── .env                    ← YOU create this ONCE (never committed to git)
├── talentOS_BE/
├── talentOS_FE/
├── talentOS_MCP/
└── talentOS_AI/
```

### Variable Distribution

```
                    ┌──────────────────────┐
                    │    /opt/talentos/.env │
                    │                      │
                    │  DATABASE_URL=...     │
                    │  LLM_PROVIDER=groq    │
                    │  OPENAI_API_KEY=...   │
                    │  GROQ_API_KEY=...     │
                    │  JWT_SECRET=...       │
                    │  GOOGLE_CLIENT_ID=... │
                    │  ...                  │
                    └──────────┬───────────┘
                               │
           ┌───────────────────┼───────────────────┐
           ▼                   ▼                   ▼
    docker-compose.yml    env_file: .env    ${VAR} substitution
           │                   │                   │
           ▼                   ▼                   ▼
    be container          ai container       LINODE_PUBLIC_IP used in:
    (reads DATABASE_URL)  (reads LLM_PROVIDER + API key)  - CORS_ALLOW_ORIGINS
                                                  - FRONTEND_BASE_URL
                                                  - VITE_APP_URL build arg
```

### Variables NOT in `.env` (hardcoded in compose)

| Variable | Value | Reason |
|----------|-------|--------|
| `KAFKA_BOOTSTRAP_SERVERS` | `redpanda:29092` | Internal Docker DNS — never changes |
| `AI_SERVICE_BASE_URL` | `http://ai:8003` | Internal Docker DNS — never changes |
| `MCP_URL` | `http://mcp:8000/mcp` | Internal Docker DNS — never changes |
| `TALENTOS_API_BASE_URL` | `http://be:8001` | Internal Docker DNS — never changes |
| `CORS_ALLOW_ORIGINS` | `http://${LINODE_PUBLIC_IP}` | Derived from `.env` at runtime |
| `FRONTEND_BASE_URL` | `http://${LINODE_PUBLIC_IP}` | Derived from `.env` at runtime |

Individual repo `.env` files (`talentOS_BE/.env`, `talentOS_AI/.env`, etc.) are used **only for local development** outside Docker. They are never read in production.

---

## Startup Order

```
1. redpanda  ── healthy check passes ──▶  2. be + worker
                                              │
3. mcp  ── started ──▶  4. ai  (depends on mcp)
                             │
                           ai gracefully degrades if mcp not ready
                           (logs warning, starts without MCP tools)

5. fe  ── (build-time arg baked in) ──▶  ready immediately

6. proxy  ── depends on fe + be started ──▶  ready
```

### `depends_on` Chain

```yaml
redpanda:   # no dependencies
mcp:        # no dependencies
ai:
  depends_on: [mcp] (condition: service_started)
be:
  depends_on: [redpanda] (condition: service_healthy)
worker:
  depends_on: [redpanda, be] (condition: service_started)
proxy:
  depends_on: [fe, be]
```

---

## Deployment

### Initial Setup (one-time)

```bash
ssh root@<linode-ip>

# Install deps
apt update && apt install -y docker.io docker-compose-v2 git

# Create directory structure
mkdir -p /opt/talentos && cd /opt/talentos

# Clone infra repo
git clone https://github.com/avezqureshi15/talentOS-infra.git

# Copy compose files
cp talentOS-infra/docker-compose.yml .
cp -r talentOS-infra/proxy .

# Create .env with secrets
cp talentOS-infra/.env.example .env
nano .env   # ← fill in LINODE_PUBLIC_IP + secrets

# Deploy
bash talentOS-infra/scripts/deploy.sh
```

### Subsequent Deploys

```bash
ssh root@<linode-ip>
cd /opt/talentos
bash talentOS-infra/scripts/deploy.sh
```

The `deploy.sh` script:
1. `git pull` all 5 repos (infra + 4 services)
2. Copies `docker-compose.yml` and `proxy/` from infra repo
3. Runs `docker compose pull` (latest images)
4. Runs `docker compose up -d --build` (rebuild if Dockerfile changed)

---

## Security

### Attack Surface

Only port 80 (nginx proxy) is exposed to the internet. All backend services (`be`, `ai`, `mcp`, `worker`, `redpanda`) are on an internal Docker network with no public route.

### Secrets Management

- `.env` is in `.gitignore` — never committed to any repo
- Secrets are loaded at container runtime via Docker's `env_file`
- Google service account JSON is baked into the BE Docker image (via `COPY . .`)
- For higher security, replace with Docker secrets or a vault

### CORS

With the reverse proxy, CORS is not needed because all requests originate from the same origin. The BE's `CORS_ALLOW_ORIGINS` is set to `http://<linode-ip>` as a safety net only.

---

## Scaling Considerations

### Vertical Scaling (Single Node)

- Upgrade Linode plan (more CPU, RAM) — no code changes needed
- Increase Kafka partitions for more parallel evaluation workers
- Adjust `KAFKA_EVALUATION_PARTITIONS` + worker replicas

### Horizontal Scaling (Multiple Nodes)

When needed, the cleanest split is:

```
Node 1: proxy + fe          (front-end + CDN)
Node 2: be + worker + redpanda  (API + message queue)
Node 3: ai + mcp            (compute-heavy AI workloads)
```

Each node communicates via HTTPS with the others. Internal Docker DNS is replaced with public/private IPs or a service mesh.
