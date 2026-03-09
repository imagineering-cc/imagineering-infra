# Backup & Restore

All services backup to **Google Cloud Storage**.

## Overview

| Service | What's Backed Up | Schedule | Retention |
|---------|------------------|----------|-----------|
| Kan.bn | PostgreSQL database | Daily 4 AM | 7 days |
| Outline | PostgreSQL database | Daily 4 AM | 7 days |
| Radicale | CalDAV/CardDAV collections | Daily 4 AM | 7 days |
| Dreamfinder | SQLite database | Daily 4 AM | 7 days |

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
```

### List Remote Backups

```bash
rclone ls gcs:imagineering-backups/
rclone ls gcs:imagineering-backups/kanbn/
rclone ls gcs:imagineering-backups/outline/
```

### Check Backup Logs

```bash
tail -f /var/log/backup.log
```

## Restore

### Manual Restore

```bash
# Restore latest backup
/opt/scripts/restore.sh kanbn
/opt/scripts/restore.sh outline
/opt/scripts/restore.sh radicale
/opt/scripts/restore.sh pm-bot

# Restore specific date
/opt/scripts/restore.sh kanbn 2024-01-15
/opt/scripts/restore.sh outline 2024-01-15
```

### Restore Process

1. Script downloads backup from GCS
2. Stops the service
3. Drops and recreates database (or restores files)
4. Restores PostgreSQL dump (or tar archive)
5. Restarts the service

## Backup File Locations

| Service | Remote Path | Contents |
|---------|-------------|----------|
| Kan.bn | `imagineering-backups/kanbn/` | `kanbn-YYYY-MM-DD.sql.gz` |
| Outline | `imagineering-backups/outline/` | `outline-YYYY-MM-DD.sql.gz` |
| Radicale | `imagineering-backups/radicale/` | `radicale-YYYY-MM-DD.tar.gz` |
| PM Bot | `imagineering-backups/pm-bot/` | `pm-bot-YYYY-MM-DD.db` |

## Troubleshooting

### Backup not running?

```bash
# Check cron
cat /etc/cron.d/backup

# Check logs
tail -50 /var/log/backup.log
```

### rclone connection issues?

```bash
# Test connection
rclone lsd gcs:

# Check config
cat ~/.config/rclone/rclone.conf
```
