#!/bin/bash
# Unified backup script for all services
# Backs up to Google Cloud Storage via rclone + redundant copies to GitHub
# Usage: ./backup.sh [all|kanbn|outline|radicale|pm-bot|claudius]

SERVICE=${1:-all}
BACKUP_DIR="/tmp/backups"
DATE=$(date +%Y-%m-%d)
RCLONE_REMOTE="gcs"
BUCKET="imagineering-backups"
RETENTION_DAYS=7
FAILED_SERVICES=()

# GitHub backup config
GITHUB_BACKUP_REPO="git@github-backups:imagineering-cc/imagineering-backups.git"
GITHUB_BACKUP_DIR="/tmp/imagineering-backups"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
  echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

# Create backup directory
mkdir -p "$BACKUP_DIR"

backup_kanbn() {
  log "Backing up Kan.bn..."

  local backup_file="$BACKUP_DIR/kanbn-$DATE.sql.gz"

  # Dump PostgreSQL
  docker exec kanbn_postgres \
    pg_dump -U kanbn kanbn | gzip > "$backup_file"

  # Upload to object storage
  rclone copy "$backup_file" "$RCLONE_REMOTE:$BUCKET/kanbn/"

  log "Kan.bn backup complete: kanbn-$DATE.sql.gz"
}

backup_pm_bot() {
  log "Backing up Dreamfinder..."

  local backup_file="$BACKUP_DIR/pm-bot-$DATE.db"

  # Copy SQLite database from container volume
  docker cp dreamfinder:/app/data/kan-bot.db "$backup_file"

  # Upload to object storage
  rclone copy "$backup_file" "$RCLONE_REMOTE:$BUCKET/pm-bot/"

  log "Dreamfinder backup complete: pm-bot-$DATE.db"
}

backup_outline() {
  log "Backing up Outline..."

  local backup_file="$BACKUP_DIR/outline-$DATE.sql.gz"

  # Dump PostgreSQL
  docker exec outline_postgres \
    pg_dump -U outline outline | gzip > "$backup_file"

  # Upload to object storage
  rclone copy "$backup_file" "$RCLONE_REMOTE:$BUCKET/outline/"

  log "Outline backup complete: outline-$DATE.sql.gz"
}

backup_radicale() {
  log "Backing up Radicale..."

  local backup_file="$BACKUP_DIR/radicale-$DATE.tar.gz"

  # Tar the collections from the Docker volume
  docker exec radicale tar czf - /data/collections > "$backup_file"

  # Upload to object storage
  rclone copy "$backup_file" "$RCLONE_REMOTE:$BUCKET/radicale/"

  log "Radicale backup complete: radicale-$DATE.tar.gz"
}

backup_claudius() {
  log "Backing up Claudius..."

  local backup_file="$BACKUP_DIR/claudius-$DATE.tar.gz"

  # Tar critical persistent state from the logs volume
  docker exec claudius tar czf - \
    /workspace/logs/agent-state.json \
    /workspace/logs/persona-evolution.md \
    /workspace/logs/conversation.log \
    /workspace/logs/playwright-storage.json \
    /workspace/logs/initiative-state.json \
    2>/dev/null > "$backup_file"

  # Upload to object storage
  rclone copy "$backup_file" "$RCLONE_REMOTE:$BUCKET/claudius/"

  log "Claudius backup complete: claudius-$DATE.tar.gz"
}

backup_to_github() {
  local services=("$@")

  # Check prerequisites
  if ! command -v git &> /dev/null; then
    error "git not installed, skipping GitHub backup"
    return 0
  fi
  if [ ! -f "$HOME/.ssh/imagineering-backups-deploy" ]; then
    error "Deploy key not found at ~/.ssh/imagineering-backups-deploy, skipping GitHub backup"
    return 0
  fi

  log "Pushing backups to GitHub..."

  # Clone or pull the backup repo (shallow)
  if [ -d "$GITHUB_BACKUP_DIR/.git" ]; then
    git -C "$GITHUB_BACKUP_DIR" pull --rebase 2>/dev/null || {
      rm -rf "$GITHUB_BACKUP_DIR"
      git clone --depth 1 "$GITHUB_BACKUP_REPO" "$GITHUB_BACKUP_DIR"
    }
  else
    rm -rf "$GITHUB_BACKUP_DIR"
    git clone --depth 1 "$GITHUB_BACKUP_REPO" "$GITHUB_BACKUP_DIR" 2>/dev/null || {
      # First push — repo may be empty
      mkdir -p "$GITHUB_BACKUP_DIR"
      git -C "$GITHUB_BACKUP_DIR" init -b main
      git -C "$GITHUB_BACKUP_DIR" remote add origin "$GITHUB_BACKUP_REPO"
    }
  fi

  # Copy each service dump (auto-detect file extension)
  for svc in "${services[@]}"; do
    # Find the backup file regardless of extension (.sql.gz, .tar.gz, .db, etc.)
    local dump
    dump=$(find "$BACKUP_DIR" -name "${svc}-${DATE}.*" -type f 2>/dev/null | head -1)

    if [ -z "$dump" ] || [ ! -f "$dump" ]; then
      error "Dump file not found for $svc (expected ${svc}-${DATE}.*)"
      continue
    fi

    local ext="${dump#"$BACKUP_DIR/${svc}-${DATE}"}"
    local dest="$GITHUB_BACKUP_DIR/${svc}${ext}"

    cp "$dump" "$dest"
    log "Copied $svc backup → ${svc}${ext}"
  done

  # Commit and push
  git -C "$GITHUB_BACKUP_DIR" add -A
  if git -C "$GITHUB_BACKUP_DIR" diff --cached --quiet; then
    log "No changes to push to GitHub"
  else
    git -C "$GITHUB_BACKUP_DIR" \
      -c user.name="imagineering-backup" \
      -c user.email="backup@imagineering.cc" \
      commit -m "backup $DATE"
    git -C "$GITHUB_BACKUP_DIR" push origin HEAD 2>/dev/null || \
      git -C "$GITHUB_BACKUP_DIR" push --set-upstream origin main
    log "Backups pushed to GitHub"
  fi
}

cleanup_old_backups() {
  log "Cleaning up backups older than $RETENTION_DAYS days..."

  # Clean local temp backups
  find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

  # Clean remote backups (rclone delete with min-age)
  rclone delete "$RCLONE_REMOTE:$BUCKET/kanbn/" \
    --min-age "${RETENTION_DAYS}d" 2>/dev/null || true
  rclone delete "$RCLONE_REMOTE:$BUCKET/outline/" \
    --min-age "${RETENTION_DAYS}d" 2>/dev/null || true
  rclone delete "$RCLONE_REMOTE:$BUCKET/pm-bot/" \
    --min-age "${RETENTION_DAYS}d" 2>/dev/null || true
  rclone delete "$RCLONE_REMOTE:$BUCKET/radicale/" \
    --min-age "${RETENTION_DAYS}d" 2>/dev/null || true
  rclone delete "$RCLONE_REMOTE:$BUCKET/claudius/" \
    --min-age "${RETENTION_DAYS}d" 2>/dev/null || true

  log "Cleanup complete"
}

# Run backups
case $SERVICE in
  all)
    SUCCEEDED=()
    for svc in kanbn outline radicale pm-bot claudius; do
      if "backup_${svc//-/_}"; then
        SUCCEEDED+=("$svc")
      else
        error "$svc backup failed"
        FAILED_SERVICES+=("$svc")
      fi
    done
    if [ ${#SUCCEEDED[@]} -gt 0 ]; then
      backup_to_github "${SUCCEEDED[@]}"
    fi
    cleanup_old_backups
    ;;
  kanbn)
    backup_kanbn && backup_to_github kanbn || FAILED_SERVICES+=(kanbn)
    ;;
  outline)
    backup_outline && backup_to_github outline || FAILED_SERVICES+=(outline)
    ;;
  radicale)
    backup_radicale && backup_to_github radicale || FAILED_SERVICES+=(radicale)
    ;;
  pm-bot)
    backup_pm_bot && backup_to_github pm-bot || FAILED_SERVICES+=(pm-bot)
    ;;
  claudius)
    backup_claudius && backup_to_github claudius || FAILED_SERVICES+=(claudius)
    ;;
  cleanup)
    cleanup_old_backups
    ;;
  *)
    echo "Usage: $0 [all|kanbn|outline|radicale|pm-bot|claudius|cleanup]"
    exit 1
    ;;
esac

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
  error "Backups failed for: ${FAILED_SERVICES[*]}"
  exit 1
fi

log "Backup complete!"
