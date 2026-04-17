# Imagineering Infrastructure

Monorepo for Imagineering infrastructure and self-hosted services.

## IMPORTANT: Production Server Safety

**DO NOT run repeated/rapid commands on the production server (149.118.69.221).**

The OCI instance has decent resources (24GB RAM, 4 vCPU) but running many `docker exec`, `docker logs`, or SSH commands in quick succession can still cause issues.

**Instead:**
- Set up a local dev environment to debug issues
- Use `./scripts/deploy-to.sh` for deployments (tested, safe)
- If you must debug production, run commands sparingly with pauses between them
- To recover a crashed server: `oci compute instance action --action RESET --instance-id ocid1.instance.oc1.ap-sydney-1.anzxsljr5jyppsicpdt4ecunqcvoxmvhauzsq5co53joaumapptj3ktxoqhq `

## Structure

```
.
├── backups/            # Backup config (GitHub)
├── caddy/              # Reverse proxy (Caddy)
├── kanbn/              # Kanban boards (Trello alternative)
├── outline/            # Team wiki (Notion alternative)
├── radicale/           # CalDAV/CardDAV server
├── scripts/            # Deployment & backup scripts
├── claudius/            # Headless email agent (Claudius Maximus)
├── dreamfinder/  # Matrix PM bot (Dreamfinder)
└── .sops.yaml          # SOPS encryption config
```

## CI & Branch Protection

**Branch protection on `main`:**
- Requires PR with 1 approving review
- Requires all CI checks to pass
- Dismisses stale reviews on new commits

**CI checks (`.github/workflows/ci.yml`):**
- ShellCheck for all bash scripts
- yamllint for docker-compose and workflow files

## Services

| Service | Port | URL | Description |
|---------|------|-----|-------------|
| Caddy | 80/443 | - | Reverse proxy, auto-TLS |
| Kan.bn | 3003 | kan.imagineering.cc | Kanban boards (Trello-like) |
| Dreamfinder (pm-bot) | - | Matrix | AI project management bot |
| Outline | 3002 | outline.imagineering.cc | Team wiki (Notion-like) |
| MinIO | 9000 | storage.imagineering.cc | S3-compatible file storage |
| Radicale | 5232 | dav.imagineering.cc | CalDAV/CardDAV (calendar & contacts) |
| Claudius | - | - | Headless email-polling Claude Code agent |

## Container Architecture

Each service has its own `docker-compose.yml` and isolated network. Caddy uses `network_mode: host` to bind directly to ports 80/443.

```
                                 Internet
                                     │
                           ┌─────────┴─────────┐
                           │   Caddy (host)    │
                           │   80/443 → TLS    │
                           └─────────┬─────────┘
                                     │
         ┌───────────────┬───────────┼───────────┐
         │               │           │           │
         ▼               ▼           ▼           ▼
┌─────────────┐  ┌─────────────┐ ┌────────┐ ┌────────┐
│outline      │  │kan          │ │storage │ │dav     │
│.imagineering│  │.imagineering│ │.imag-  │ │.imag-  │
│.cc :3002    │  │.cc :3003    │ │ineering│ │ineering│
└──────┬──────┘  └──────┬──────┘ │.cc     │ │.cc     │
       │                │        │:9000   │ │:5232   │
       ▼                ▼        └───┬────┘ └───┬────┘
┌─────────────┐  ┌─────────────┐    │           │
│   Outline   │  │   Kan.bn    │    │           ▼
│ (wiki app)  │  │(kanban app) │    │    ┌───────────┐
└──────┬──────┘  └──────┬──────┘    │    │ Radicale  │
       │                │           │    │ (CalDAV/  │
  ┌────┴────┐      ┌────┴────┐     │    │  CardDAV) │
  ▼         ▼      ▼         │     │    └───────────┘
┌───────┐┌──────┐┌────────┐  │  ┌──┘
│Postgre││Redis ││Postgres│  │  │
└───────┘└──────┘└────────┘  │  ▼
                       ┌─────┴──────────┐
                       │     MinIO      │
                       │(shared storage)│
                       │outline, kanbn-*│
                       └────────────────┘


┌─────────────────────────────────────────────────────────────────────┐
│                 dreamfinder (standalone)                    │
│                                                                    │
│  ┌──────────┐    HTTP API     ┌──────────┐   Matrix C-S API ┌─────┐│
│  │  SQLite  │◄───────────────►│  Bot     │◄───────────────►│Users││
│  │ (local)  │                 │  (Dart)  │  (Continuwuity) │     ││
│  └──────────┘                 └────┬─────┘                 └─────┘│
│                                    │                               │
│                                    ▼                               │
│                        kan.imagineering.cc                         │
│                          (Kan.bn API)                              │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    claudius (standalone)                             │
│                                                                     │
│  ┌──────────┐    IMAP/SMTP     ┌──────────┐   Claude Code   ┌─────┐│
│  │  Volumes │◄───────────────►│  Agent   │◄──────────────►│Email││
│  │(logs,repo│                 │  Loop   │  (headless)     │     ││
│  │,attach)  │                 └──────────┘                 └─────┘│
│                                                                     │
│  No HTTP — headless email worker with Playwright browser            │
└─────────────────────────────────────────────────────────────────────┘
```

**Network isolation:**
- `outline/` - own network with postgres, redis, minio
- `kanbn/` - own network with postgres; uses shared MinIO via `storage.imagineering.cc`
- `radicale/` - standalone container; file-based storage in Docker volume
- `claudius/` - standalone container; headless email worker, no network dependencies on other services
- `dreamfinder/` - standalone container; talks to Matrix via Continuwuity homeserver, Kan.bn via public API
- `caddy/` - `network_mode: host` to bind 80/443 directly

**Shared resources:**
- MinIO (from Outline stack) serves both Outline and Kan.bn file storage
- Caddy routes all HTTPS traffic to backend services on localhost

## Backups

Daily backups to GitHub (imagineering-cc/imagineering-backups).

| Service | Schedule | Retention |
|---------|----------|-----------|
| Kan.bn | 4 AM | 7 days |
| Outline | 4 AM | 7 days |
| Radicale | 4 AM | 7 days |
| dreamfinder | 4 AM | 7 days |
| Claudius | 4 AM | 7 days |

```bash
# Manual commands (run on VPS)
/opt/scripts/backup.sh all       # Run backup
/opt/scripts/restore.sh kanbn    # Restore Kan.bn
/opt/scripts/restore.sh outline  # Restore Outline
/opt/scripts/restore.sh radicale # Restore Radicale
/opt/scripts/restore.sh pm-bot   # Restore dreamfinder
```

## Cloud Provider

| Provider | Status | IP | Cost |
|----------|--------|-----|------|
| OCI (Oracle Cloud) | Active | 149.118.69.221 | Free tier (200 GB disk, 4 OCPU, 24 GB RAM) |

### OCI Always Free Tier — Full Inventory

Everything runs on Oracle Cloud's Always Free tier — no billing, no trial expiry. All resources must be in the **home region** (ap-sydney-1) to stay free.

**Reference:** [OCI Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)

#### Compute

| Shape | OCPUs | RAM | Instances | Notes |
|-------|-------|-----|-----------|-------|
| VM.Standard.A1.Flex (Arm) | 4 total | 24 GB total | Up to 4 | Ampere Altra 3 GHz. OCPU/RAM ratio is flexible — allocate independently |
| VM.Standard.E2.1.Micro (AMD x86) | 1/8 each (burstable) | 1 GB each | Up to 2 | **Separate CPU budget** — does not eat into A1 allocation. Can burst above baseline |

Total baseline: **4.25 OCPUs + 26 GB RAM** across up to 6 instances.

**Current usage:** 1× A1.Flex (4 OCPU, 24 GB) = imagineering-syd. 0× E2.1.Micro (2 available).

#### Storage

| Resource | Limit | Current |
|----------|-------|---------|
| Boot + block volumes | 200 GB total | 200 GB (1 boot volume) |
| Volume backups | 5 | - |
| Object Storage | 20 GB + 50K API calls/mo | Not used (MinIO self-hosted instead) |

Boot volume can be resized online — grow partition with `growpart` + `resize2fs`, no reboot needed.

#### Databases (managed, not currently used)

| Service | Limit | Potential use |
|---------|-------|---------------|
| Autonomous Database (Oracle) | 2 instances, 1 OCPU + 20 GB each | Could replace self-managed Postgres — but requires Oracle SQL, no Postgres wire compat |
| MySQL HeatWave | 1 node, 50 GB data + 50 GB backup | Managed MySQL with analytics engine |
| NoSQL Database | 3 tables × 25 GB, 133M reads+writes/mo | High-throughput key-value store |

#### Networking

| Resource | Limit | Notes |
|----------|-------|-------|
| VCNs | 2 | Currently using 1 |
| Flexible Load Balancer | 1 (10 Mbps, 16 listeners/backend sets) | L7 — could front Caddy for health checks |
| Network Load Balancer | 1 (50 listeners, 1024 backends) | L4 — TCP/UDP load balancing |
| Site-to-Site VPN | 50 IPSec connections | Free VPN tunnels to home/other sites |
| Outbound data | 10 TB/month | AWS charges ~$0.09/GB for this |
| VCN Flow Logs | 10 GB/month | Network traffic logging |
| Bastion | Free, no stated limit | Managed SSH jump host — avoids exposing SSH directly |

#### Observability & Messaging

| Resource | Limit | Potential use |
|----------|-------|---------------|
| Email Delivery | 3,000 emails/month | Could replace Brevo for Outline's transactional email |
| Monitoring | 500M ingestion + 1B retrieval data points | Free metrics/alerting (Datadog-lite) |
| Notifications | 1M HTTPS + 1K email per month | Webhook/email alerts on events |
| APM | 1,000 tracing events/mo + 10 synthetic runs/hr | Application performance monitoring |
| Connector Hub | 2 connectors | Pipe events between OCI services |

#### Security

| Resource | Limit | Notes |
|----------|-------|-------|
| Vault (KMS) | Unlimited software keys, 20 HSM keys, 150 secrets | Could replace SOPS for secrets management |
| Certificates | 5 CAs + 150 certs | Free cert management (Caddy already handles Let's Encrypt) |

#### OCIDs

- Instance: `ocid1.instance.oc1.ap-sydney-1.anzxsljr5jyppsicpdt4ecunqcvoxmvhauzsq5co53joaumapptj3ktxoqhq`
- Boot volume: `ocid1.bootvolume.oc1.ap-sydney-1.abzxsljrvp4mpltca5qqqt3qldbs252qlqp35hr6ydsdvew2ch444zmcqakq`

## Secrets Management

Everything is encrypted with SOPS/age. The age key is at the default location: `~/.config/sops/age/keys.txt`

**Local decryption:** The key is available on Nick's machine. To decrypt/edit secrets locally, set the env var:
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

```bash
# Setup age key (one-time)
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Add public key to .sops.yaml

# Edit encrypted secrets
sops kanbn/secrets.yaml
sops outline/secrets.yaml
```

---

# caddy

Reverse proxy with automatic HTTPS via Let's Encrypt.

```
Internet → Caddy (443/80) → Kan.bn (3003)
                          → Outline (3002)
                          → MinIO Storage (9000)
                          → Radicale (5232)
```

---

# outline

Self-hosted team wiki (Notion alternative). Real-time collaboration with edit history.

**URL**: https://outline.imagineering.cc

## Features

- Wiki-style linking between documents
- Real-time collaboration (see cursors, who's editing)
- Edit history with attribution
- Email/password login (via Brevo SMTP)
- Markdown support

## Setup

```bash
# Deploy (secrets auto-decrypted)
./scripts/deploy-to.sh 149.118.69.221 outline
```

First user to sign up becomes admin. Invite team members from Settings → Members.

## Local Development

```bash
cd outline
cp .env.local .env   # Copy local dev template
docker compose up -d # Start all services
```

Access at http://localhost:3002. First signup becomes admin.

**Services:**
- Outline: http://localhost:3002
- MinIO Console: http://localhost:9001 (outline / see .env for password)

**Notes:**
- `.env.local` has pre-generated secrets safe for local dev
- `.env` is gitignored
- Email won't work locally (no SMTP) but signup still works

---

# kanbn

Self-hosted kanban boards (Trello alternative). Using kanbn/kan fork.

**URL**: https://kan.imagineering.cc

## Features

- Trello-like kanban boards
- Drag and drop cards
- Labels and filters
- Trello import (boards, cards, lists)
- File attachments (via shared MinIO storage)
- Email/password login

## Storage

Uses shared MinIO instance from Outline for file attachments:
- Buckets: `kanbn-avatars`, `kanbn-attachments`
- Public URL: https://storage.imagineering.cc

## Trello Migration

Kan.bn has built-in Trello import via OAuth. To import:

1. Go to Settings → Integrations → Connect Trello
2. Authorize the connection
3. Select boards to import

**Note**: Attachments are NOT imported automatically.

## Setup

```bash
# Deploy (builds from source, secrets auto-decrypted)
./scripts/deploy-to.sh 149.118.69.221 kanbn
```

First user to sign up becomes admin.

---

# radicale

Self-hosted CalDAV/CardDAV server for team calendars and contacts.

**URL**: https://dav.imagineering.cc
**Image**: [tomsquest/docker-radicale](https://github.com/tomsquest/docker-radicale)

## Features

- CalDAV (calendars) and CardDAV (contacts)
- htpasswd authentication (bcrypt)
- Owner-only access rights (users see only their own data)
- File-based storage with git-tracked changes
- Compatible with DAVx5, Apple Calendar/Contacts, Thunderbird

## Setup

```bash
# Deploy (secrets auto-decrypted, htpasswd generated)
./scripts/deploy-to.sh 149.118.69.221 radicale

# Also redeploy Caddy to pick up the new route
./scripts/deploy-to.sh 149.118.69.221 caddy

# Test
curl -u nick:password https://dav.imagineering.cc/.well-known/caldav
```

## Client Configuration

Use base URL `https://dav.imagineering.cc` with your username/password in:
- **Android**: DAVx5
- **iOS/macOS**: Settings → Calendar/Contacts → Add Account → Other
- **Thunderbird**: TbSync + DAV provider

---

# Dreamfinder

Matrix-based AI project management bot. Uses Claude Sonnet with ~75 MCP tools
across Kan.bn, Outline, Radicale, and Playwright. No slash commands — natural language only.

**Source**: [imagineering-cc/dreamfinder](https://github.com/imagineering-cc/dreamfinder)

## Architecture

- **Dart** application with Claude agent loop
- **Matrix** messaging via Continuwuity homeserver (matrix.imagineering.cc)
- **SQLite** for conversation history and bot state
- **MCP** tools for Kan.bn, Outline, Radicale, Playwright (from shared `nickmeinhold/mcp-servers` submodule)

## Config

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Claude API key |
| `MATRIX_HOMESERVER` | Matrix homeserver URL (e.g. https://matrix.imagineering.cc) |
| `MATRIX_ACCESS_TOKEN` | Bot's Matrix access token |
| `KAN_BASE_URL` | Kan.bn API URL |
| `KAN_API_KEY` | Kan.bn API key |
| `OUTLINE_BASE_URL` | Outline API URL |
| `OUTLINE_API_KEY` | Outline API key |
| `RADICALE_BASE_URL` | Radicale CalDAV URL |

## Setup

```bash
# Deploy (source from https://github.com/imagineering-cc/dreamfinder)
./scripts/deploy-to.sh 149.118.69.221 pm-bot

# Check logs
ssh 149.118.69.221 'docker logs -f dreamfinder'
```

---

# Claudius Maximus

Headless email-polling Claude Code agent. Polls IMAP inbox, processes emails with Claude, replies via SMTP.
Autonomous AI pen pal with research journal, self-evolution, and proactive outreach.

**Source**: `~/git/experiments/containerized-claude/claudius-maximus-container/`

## Architecture

- **Node.js** base image with Claude Code CLI + Playwright MCP (headless Chromium)
- **IMAP/SMTP** for email communication (Gmail with App Passwords)
- **GitHub** repos for persistent memory (research journal + email archive)
- **Docker volumes** for state (logs, repos, attachments)
- No HTTP service — pure background worker

## Setup

```bash
# Deploy (source rsynced from containerized-claude repo)
./scripts/deploy-to.sh 149.118.69.221 claudius

# Check logs
ssh 149.118.69.221 'docker logs -f claudius'
```

See `claudius-maximus-container/CLAUDE.md` in the source repo for full architecture docs.
