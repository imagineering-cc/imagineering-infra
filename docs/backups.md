# Backup & Restore

All services backup to **GitHub** (imagineering-cc/imagineering-backups).

## Overview

| Service | What's Backed Up | Schedule | Retention |
|---------|------------------|----------|-----------|
| Kan.bn | PostgreSQL database | Daily 4 AM | 7 days |
| Outline | PostgreSQL database | Daily 4 AM | 7 days |
| Radicale | CalDAV/CardDAV collections | Daily 4 AM | 7 days |
| Dreamfinder | SQLite database | Daily 4 AM | 7 days |
| Claudius | Agent state files | Daily 4 AM | 7 days |
| aiko-chat-gateway (Sydney / imagineering) | SQLite (messages + auth + ACL — the sole copy) | Daily 4 AM | 7 days |
| aiko-chat-gateway (Melbourne / enspyr) | SQLite (`aiko-gateway-enspyr.sql`) | Daily 4:20 AM | 7 days |

> **Two islands, one repo.** Each island's gateway backs up its own DB under a
> distinct slug so they never clobber one file: Sydney → `aiko-gateway.sql`
> (fleet `backup.sh` on the imagineering box), Melbourne → `aiko-gateway-enspyr.sql`
> (standalone `backup-aiko-gateway-standalone.sh` on nick-mel, own on-box deploy
> key, root cron 4:20 AM staggered from Sydney's 4 AM to avoid a push race).
> Both auto-detect the live gateway volume from the running container — a
> hardcoded name silently backs up an orphaned volume after an island cutover
> (fixed 2026-07-07; see PR #124). **Follow-up:** Melbourne has no backup-recency
> watcher yet (Sydney does) — a silent failure there would go unnoticed.

## Manual Operations

### Run Backup Now

```bash
# All services
/opt/scripts/backup.sh all

# Single service
/opt/scripts/backup.sh kanbn
/opt/scripts/backup.sh outline
/opt/scripts/backup.sh radicale
/opt/scripts/backup.sh pm-bot
/opt/scripts/backup.sh claudius
/opt/scripts/backup.sh aiko-gateway
```

### Check Backup Logs

```bash
tail -f /var/log/backup.log
```

## Restore

### Manual Restore

```bash
# Restore latest backup (pulls from GitHub)
/opt/scripts/restore.sh kanbn
/opt/scripts/restore.sh outline
/opt/scripts/restore.sh radicale
/opt/scripts/restore.sh pm-bot
/opt/scripts/restore.sh claudius
/opt/scripts/restore.sh aiko-gateway
```

> ⚠️ **`aiko-gateway` restore replaces the SOLE store** of all gateway accounts,
> messages, and the ACL overlay. It prompts for typed confirmation, validates the
> dump into a temp DB (`PRAGMA integrity_check` + a `users`-table check) before
> swapping, and keeps the previous DB as a timestamped `aiko.db.rescue-*` inside
> the volume. If validation fails, the live DB is left untouched.

### Restore Process

1. Script clones backup repo from GitHub (shallow)
2. Stops the service
3. Drops and recreates database (or restores files)
4. Restores PostgreSQL dump (or tar archive)
5. Restarts the service

## Backup Files in GitHub Repo

| Service | File | Contents |
|---------|------|----------|
| Kan.bn | `kanbn.sql` | Decompressed PostgreSQL dump |
| Outline | `outline.sql` | Decompressed PostgreSQL dump |
| Radicale | `radicale.tar` | Decompressed collections archive |
| Dreamfinder | `pm-bot.db` | SQLite database |
| Claudius | `claudius.tar` | Decompressed state archive |
| aiko-chat-gateway | `aiko-gateway.sql` | Decompressed SQLite dump |

Files are stored decompressed so git deltas work efficiently.

## Troubleshooting

### Backup not running?

```bash
# Check cron
cat /etc/cron.d/backup

# Check logs
tail -50 /var/log/backup.log
```

### GitHub push failing?

```bash
# Test deploy key
ssh -T git@github-backups

# Check key exists
ls -la ~/.ssh/imagineering-backups-deploy
```
