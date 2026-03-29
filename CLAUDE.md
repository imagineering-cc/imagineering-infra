# Imagineering Infrastructure

Monorepo for Imagineering infrastructure and self-hosted services.

## IMPORTANT: Production Server Safety

**DO NOT run repeated/rapid commands on the production server (149.118.69.221).**

The OCI instance has moderate resources but running many `docker exec`, `docker logs`, or SSH commands in quick succession can still cause issues.

**Instead:**
- Set up a local dev environment to debug issues
- Use `./scripts/deploy-to.sh` for deployments (tested, safe)
- If you must debug production, run commands sparingly with pauses between them
- To recover a crashed server: `oci compute instance action --action RESET --instance-id ocid1.instance.oc1.ap-sydney-1.anzxsljr5jyppsicpdt4ecunqcvoxmvhauzsq5co53joaumapptj3ktxoqhq `

## Structure

```
.
├── backups/            # Backup config (Google Cloud Storage)
├── caddy/              # Reverse proxy (Caddy)
├── kanbn/              # Kanban boards (Trello alternative)
├── outline/            # Team wiki (Notion alternative)
├── radicale/           # CalDAV/CardDAV server
├── scripts/            # Deployment & backup scripts
├── dreamfinder/  # Signal PM bot (Dreamfinder)
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
| Dreamfinder (pm-bot) | - | Signal | AI project management bot |
| Outline | 3002 | outline.imagineering.cc | Team wiki (Notion-like) |
| MinIO | 9000 | storage.imagineering.cc | S3-compatible file storage |
| Radicale | 5232 | dav.imagineering.cc | CalDAV/CardDAV (calendar & contacts) |

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
│  ┌──────────┐    HTTP API     ┌──────────┐   Signal API   ┌──────┐│
│  │  SQLite  │◄───────────────►│  Bot     │◄──────────────►│Users ││
│  │ (local)  │                 │  (Dart)  │  signal-cli    │      ││
│  └──────────┘                 └────┬─────┘                └──────┘│
│                                    │                               │
│                                    ▼                               │
│                        kan.imagineering.cc                         │
│                          (Kan.bn API)                              │
└─────────────────────────────────────────────────────────────────────┘
```

**Network isolation:**
- `outline/` - own network with postgres, redis, minio
- `kanbn/` - own network with postgres; uses shared MinIO via `storage.imagineering.cc`
- `radicale/` - standalone container; file-based storage in Docker volume
- `dreamfinder/` - own network with signal-cli-rest-api; talks to Kan.bn via public API
- `caddy/` - `network_mode: host` to bind 80/443 directly

**Shared resources:**
- MinIO (from Outline stack) serves both Outline and Kan.bn file storage
- Caddy routes all HTTPS traffic to backend services on localhost

## Backups

Daily backups to Google Cloud Storage.

| Service | Schedule | Retention |
|---------|----------|-----------|
| Kan.bn | 4 AM | 7 days |
| Outline | 4 AM | 7 days |
| Radicale | 4 AM | 7 days |
| dreamfinder | 4 AM | 7 days |

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
| OCI (Oracle Cloud) | Active | 149.118.69.221 | Free tier |

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

Signal-based AI project management bot. Uses Claude Sonnet with ~75 MCP tools
across Kan.bn, Outline, Radicale, and Playwright. No slash commands — natural language only.

**Source**: [imagineering-cc/dreamfinder](https://github.com/imagineering-cc/dreamfinder)

## Architecture

- **Dart** application with Claude agent loop
- **Signal** messaging via `signal-cli-rest-api` sidecar container
- **SQLite** for conversation history and bot state
- **MCP** tools for Kan.bn, Outline, Radicale, Playwright

## Config

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Claude API key |
| `SIGNAL_PHONE_NUMBER` | Bot's registered Signal phone number |
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
