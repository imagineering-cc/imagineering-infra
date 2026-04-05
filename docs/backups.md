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
```

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
