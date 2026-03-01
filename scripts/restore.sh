#!/bin/bash
# Restore script for all services
# Restores from Google Cloud Storage via rclone
# Usage: ./restore.sh <service> [date]
#   service: kanbn, outline, radicale, pm-bot
#   date: YYYY-MM-DD (optional, defaults to latest)

set -e

SERVICE=$1
DATE=${2:-""}
RESTORE_DIR="/tmp/restore"
RCLONE_REMOTE="gcs"
BUCKET="imagineering-backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service> [date]"
  echo "  service: kanbn, outline, radicale, pm-bot"
  echo "  date: YYYY-MM-DD (optional)"
  echo ""
  echo "Examples:"
  echo "  $0 kanbn              # Restore latest"
  echo "  $0 outline 2024-01-15 # Restore specific date"
  exit 1
fi

mkdir -p "$RESTORE_DIR"

list_backups() {
  local service=$1
  log "Available backups for $service:"
  rclone ls "$RCLONE_REMOTE:$BUCKET/$service/" | sort -r | head -20
}

restore_kanbn() {
  log "Restoring Kan.bn..."

  # Find backup file
  if [ -n "$DATE" ]; then
    BACKUP_FILE="kanbn-$DATE.sql.gz"
  else
    BACKUP_FILE=$(rclone ls "$RCLONE_REMOTE:$BUCKET/kanbn/" | sort -r | head -1 | awk '{print $2}')
  fi

  if [ -z "$BACKUP_FILE" ]; then
    error "No backup found"
    list_backups kanbn
    exit 1
  fi

  log "Restoring from: $BACKUP_FILE"

  # Download backup
  log "Downloading backup from GCS..."
  rclone copy "$RCLONE_REMOTE:$BUCKET/kanbn/$BACKUP_FILE" "$RESTORE_DIR/"

  # Ensure Kan.bn postgres is running
  cd ~/apps/kanbn
  docker compose up -d postgres
  log "Waiting for PostgreSQL to start..."
  sleep 10

  # Drop and recreate database
  log "Dropping existing database..."
  docker exec -i kanbn_postgres bash -c "psql -U kanbn -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'kanbn' AND pid <> pg_backend_pid();\" postgres && dropdb -U kanbn kanbn && createdb -U kanbn kanbn"

  # Restore database
  log "Restoring database..."
  gunzip -c "$RESTORE_DIR/$BACKUP_FILE" | \
    docker exec -i kanbn_postgres psql -U kanbn kanbn

  log "Restarting Kan.bn..."
  docker compose restart

  # Cleanup
  rm -f "$RESTORE_DIR/$BACKUP_FILE"

  log "Kan.bn restore complete!"
}

restore_outline() {
  log "Restoring Outline..."

  # Find backup file
  if [ -n "$DATE" ]; then
    BACKUP_FILE="outline-$DATE.sql.gz"
  else
    BACKUP_FILE=$(rclone ls "$RCLONE_REMOTE:$BUCKET/outline/" | sort -r | head -1 | awk '{print $2}')
  fi

  if [ -z "$BACKUP_FILE" ]; then
    error "No backup found"
    list_backups outline
    exit 1
  fi

  log "Restoring from: $BACKUP_FILE"

  # Download backup
  log "Downloading backup from GCS..."
  rclone copy "$RCLONE_REMOTE:$BUCKET/outline/$BACKUP_FILE" "$RESTORE_DIR/"

  # Ensure Outline postgres is running
  cd ~/apps/outline
  docker compose up -d postgres
  log "Waiting for PostgreSQL to start..."
  sleep 10

  # Drop and recreate database
  log "Dropping existing database..."
  docker exec -i outline_postgres bash -c "psql -U outline -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'outline' AND pid <> pg_backend_pid();\" postgres && dropdb -U outline outline && createdb -U outline outline"

  # Restore database
  log "Restoring database..."
  gunzip -c "$RESTORE_DIR/$BACKUP_FILE" | \
    docker exec -i outline_postgres psql -U outline outline

  log "Restarting Outline..."
  docker compose restart

  # Cleanup
  rm -f "$RESTORE_DIR/$BACKUP_FILE"

  log "Outline restore complete!"
}

restore_pm_bot() {
  log "Restoring imagineering-pm-bot..."

  # Find backup file
  if [ -n "$DATE" ]; then
    BACKUP_FILE="pm-bot-$DATE.db"
  else
    BACKUP_FILE=$(rclone ls "$RCLONE_REMOTE:$BUCKET/pm-bot/" | sort -r | head -1 | awk '{print $2}')
  fi

  if [ -z "$BACKUP_FILE" ]; then
    error "No backup found"
    list_backups pm-bot
    exit 1
  fi

  log "Restoring from: $BACKUP_FILE"

  # Download backup
  log "Downloading backup from GCS..."
  rclone copy "$RCLONE_REMOTE:$BUCKET/pm-bot/$BACKUP_FILE" "$RESTORE_DIR/"

  # Copy SQLite database into container volume
  log "Restoring database..."
  docker cp "$RESTORE_DIR/$BACKUP_FILE" imagineering-pm-bot:/app/data/kan-bot.db

  log "Restarting imagineering-pm-bot..."
  cd ~/apps/imagineering-pm-bot
  docker compose restart

  # Cleanup
  rm -f "$RESTORE_DIR/$BACKUP_FILE"

  log "imagineering-pm-bot restore complete!"
}

restore_radicale() {
  log "Restoring Radicale..."

  # Find backup file
  if [ -n "$DATE" ]; then
    BACKUP_FILE="radicale-$DATE.tar.gz"
  else
    BACKUP_FILE=$(rclone ls "$RCLONE_REMOTE:$BUCKET/radicale/" | sort -r | head -1 | awk '{print $2}')
  fi

  if [ -z "$BACKUP_FILE" ]; then
    error "No backup found"
    list_backups radicale
    exit 1
  fi

  log "Restoring from: $BACKUP_FILE"

  # Download backup
  log "Downloading backup from GCS..."
  rclone copy "$RCLONE_REMOTE:$BUCKET/radicale/$BACKUP_FILE" "$RESTORE_DIR/"

  # Stop Radicale
  log "Stopping Radicale..."
  cd ~/apps/radicale
  docker compose stop radicale

  # Restore collections into the volume
  log "Restoring collections..."
  docker compose run --rm --entrypoint sh -v "$RESTORE_DIR/$BACKUP_FILE:/restore.tar.gz:ro" radicale \
    -c "rm -rf /data/collections && tar xzf /restore.tar.gz -C /"

  # Start Radicale
  log "Starting Radicale..."
  docker compose up -d

  # Cleanup
  rm -f "$RESTORE_DIR/$BACKUP_FILE"

  log "Radicale restore complete!"
}

# Run restore
case $SERVICE in
  kanbn)
    restore_kanbn
    ;;
  outline)
    restore_outline
    ;;
  radicale)
    restore_radicale
    ;;
  pm-bot)
    restore_pm_bot
    ;;
  list)
    list_backups "${DATE:-kanbn}"
    ;;
  *)
    error "Unknown service: $SERVICE"
    echo "Valid services: kanbn, outline, radicale, pm-bot, list"
    exit 1
    ;;
esac
