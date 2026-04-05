#!/bin/bash
# Restore script for all services
# Restores from GitHub backup repo (imagineering-cc/imagineering-backups)
# Usage: ./restore.sh <service>
#   service: kanbn, outline, radicale, pm-bot, claudius

set -e

SERVICE=$1
RESTORE_DIR="/tmp/restore"
GITHUB_BACKUP_REPO="git@github-backups:imagineering-cc/imagineering-backups.git"
BACKUP_CLONE_DIR="$RESTORE_DIR/imagineering-backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service>"
  echo "  service: kanbn, outline, radicale, pm-bot, claudius"
  echo ""
  echo "Examples:"
  echo "  $0 kanbn    # Restore latest from GitHub backup"
  echo "  $0 outline  # Restore latest from GitHub backup"
  exit 1
fi

mkdir -p "$RESTORE_DIR"

# Clone the backup repo (shallow) to get latest backups
fetch_backups() {
  log "Fetching backups from GitHub..."
  rm -rf "$BACKUP_CLONE_DIR"
  git clone --depth 1 "$GITHUB_BACKUP_REPO" "$BACKUP_CLONE_DIR"
}

cleanup_backups() {
  rm -rf "$BACKUP_CLONE_DIR"
}

restore_kanbn() {
  log "Restoring Kan.bn..."

  fetch_backups

  # backup.sh stores decompressed SQL for better git deltas
  local BACKUP_FILE="$BACKUP_CLONE_DIR/kanbn.sql"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No kanbn.sql found in backup repo"
    cleanup_backups
    exit 1
  fi

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
  docker exec -i kanbn_postgres psql -U kanbn kanbn < "$BACKUP_FILE"

  log "Restarting Kan.bn..."
  docker compose restart

  cleanup_backups
  log "Kan.bn restore complete!"
}

restore_outline() {
  log "Restoring Outline..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/outline.sql"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No outline.sql found in backup repo"
    cleanup_backups
    exit 1
  fi

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
  docker exec -i outline_postgres psql -U outline outline < "$BACKUP_FILE"

  log "Restarting Outline..."
  docker compose restart

  cleanup_backups
  log "Outline restore complete!"
}

restore_pm_bot() {
  log "Restoring Dreamfinder..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/pm-bot.db"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No pm-bot.db found in backup repo"
    cleanup_backups
    exit 1
  fi

  # Copy SQLite database into container volume
  log "Restoring database..."
  docker cp "$BACKUP_FILE" dreamfinder:/app/data/kan-bot.db

  log "Restarting Dreamfinder..."
  cd ~/apps/dreamfinder
  docker compose restart

  cleanup_backups
  log "Dreamfinder restore complete!"
}

restore_radicale() {
  log "Restoring Radicale..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/radicale.tar"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No radicale.tar found in backup repo"
    cleanup_backups
    exit 1
  fi

  # Stop Radicale
  log "Stopping Radicale..."
  cd ~/apps/radicale
  docker compose stop radicale

  # Restore collections into the volume
  log "Restoring collections..."
  docker compose run --rm --entrypoint sh -v "$BACKUP_FILE:/restore.tar:ro" radicale \
    -c "rm -rf /data/collections && tar xf /restore.tar -C /"

  # Start Radicale
  log "Starting Radicale..."
  docker compose up -d

  cleanup_backups
  log "Radicale restore complete!"
}

restore_claudius() {
  log "Restoring Claudius..."

  fetch_backups

  local BACKUP_FILE="$BACKUP_CLONE_DIR/claudius.tar"
  if [ ! -f "$BACKUP_FILE" ]; then
    error "No claudius.tar found in backup repo"
    cleanup_backups
    exit 1
  fi

  # Restore state files into container
  log "Restoring state..."
  docker cp "$BACKUP_FILE" claudius:/tmp/restore.tar
  docker exec claudius sh -c "tar xf /tmp/restore.tar -C / && rm /tmp/restore.tar"

  log "Restarting Claudius..."
  cd ~/apps/claudius
  docker compose restart

  cleanup_backups
  log "Claudius restore complete!"
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
  claudius)
    restore_claudius
    ;;
  *)
    error "Unknown service: $SERVICE"
    echo "Valid services: kanbn, outline, radicale, pm-bot, claudius"
    exit 1
    ;;
esac
