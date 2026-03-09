# imagineering-infra

Infrastructure monorepo for self-hosted services.

## Services

| Service | Description | URL |
|---------|-------------|-----|
| [Kan.bn](./kanbn/) | Kanban boards (Trello alternative) | kan.imagineering.cc |
| [Outline](./outline/) | Team wiki (Notion alternative) | outline.imagineering.cc |
| MinIO | S3-compatible file storage | storage.imagineering.cc |
| [Caddy](./caddy/) | Reverse proxy with automatic HTTPS | - |
| [Radicale](./radicale/) | CalDAV/CardDAV server | dav.imagineering.cc |

## Infrastructure

| Provider | Status | Cost |
|----------|--------|------|
| GCP Compute Engine (e2-medium) | **Active** | ~$24/mo |

## Architecture

```
Internet → Caddy (443/80) → Kan.bn (3003)
                          → Outline (3002)
                          → MinIO (9000)
                          → Radicale (5232)
```

## Quick Start

### Prerequisites

```bash
brew install sops age yq
```

### 1. Set up encryption key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
# Add public key to .sops.yaml
```

### 2. Deploy services

```bash
./scripts/deploy-to.sh 34.40.229.206 all
```

## Repository Structure

```
.
├── caddy/                  # Reverse proxy config
├── kanbn/                  # Kan.bn (Trello alternative)
├── outline/                # Outline wiki
├── radicale/               # CalDAV/CardDAV server
├── dreamfinder/    # Signal PM bot (Dreamfinder)
├── backups/                # Backup configuration
├── scripts/
│   ├── deploy-to.sh        # Deployment script
│   ├── backup.sh           # Backup script
│   └── restore.sh          # Restore script
└── .sops.yaml              # SOPS encryption config
```

## Secrets Management

All secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

```bash
# Edit encrypted secrets
sops kanbn/secrets.yaml
sops outline/secrets.yaml
```
