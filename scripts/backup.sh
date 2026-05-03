#!/bin/bash
# Unified backup script for all services
# Dumps databases/data, pushes to GitHub (imagineering-cc/imagineering-backups)
# Usage: ./backup.sh [all|kanbn|outline|radicale|pm-bot|claudius|downstream-server]

SERVICE=${1:-all}
BACKUP_DIR="/tmp/backups"
DATE=$(date +%Y-%m-%d)
RETENTION_DAYS=7
FAILED_SERVICES=()

# GitHub backup config
GITHUB_BACKUP_REPO="git@github-imagineering-backups:imagineering-cc/imagineering-backups.git"
GITHUB_BACKUP_DIR="/tmp/imagineering-backups"
GITHUB_REPO_SIZE_ALERT_MB=500

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

# Source shared Telegram helper (defines send_telegram_alert + loads creds
# from /etc/downstream-secrets/telegram.env at deploy targets).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/telegram.sh
. "$SCRIPT_DIR/lib/telegram.sh"

check_repo_size() {
  if [ ! -d "$GITHUB_BACKUP_DIR" ]; then
    return 0
  fi
  local size_mb
  size_mb=$(du -sm "$GITHUB_BACKUP_DIR" --exclude='.git' 2>/dev/null | awk '{print $1}')
  if [ -z "$size_mb" ]; then
    return 0
  fi
  if [ "$size_mb" -gt "$GITHUB_REPO_SIZE_ALERT_MB" ]; then
    log "GitHub backup payload is ${size_mb} MB (threshold: ${GITHUB_REPO_SIZE_ALERT_MB} MB)"
    send_telegram_alert "$(printf '<b>Backup Size Alert</b>\nGitHub backup payload: %s MB (threshold: %s MB)\nConsider pruning old data or increasing the threshold.' "$size_mb" "$GITHUB_REPO_SIZE_ALERT_MB")"
  fi
}

# Create backup directory
mkdir -p "$BACKUP_DIR"

backup_kanbn() {
  log "Backing up Kan.bn..."

  local backup_file="$BACKUP_DIR/kanbn-$DATE.sql.gz"

  # Dump PostgreSQL
  docker exec kanbn_postgres \
    pg_dump -U kanbn kanbn | gzip > "$backup_file"

  log "Kan.bn backup complete: kanbn-$DATE.sql.gz"
}

backup_pm_bot() {
  log "Backing up Dreamfinder..."

  local backup_file="$BACKUP_DIR/pm-bot-$DATE.db"

  # Copy SQLite database from container volume.
  # Path is /app/data/bot.db (was kan-bot.db from an earlier rename;
  # docker cp silently produces an empty/wrong file on path mismatch
  # which is why this bug went undetected — fail loudly instead).
  if ! docker cp dreamfinder:/app/data/bot.db "$backup_file"; then
    error "Dreamfinder docker cp failed — backup file is incomplete or missing"
    rm -f "$backup_file"
    return 1
  fi

  log "Dreamfinder backup complete: pm-bot-$DATE.db"
}

backup_outline() {
  log "Backing up Outline..."

  local backup_file="$BACKUP_DIR/outline-$DATE.sql.gz"

  # Dump PostgreSQL
  docker exec outline_postgres \
    pg_dump -U outline outline | gzip > "$backup_file"

  log "Outline backup complete: outline-$DATE.sql.gz"
}

backup_radicale() {
  log "Backing up Radicale..."

  local backup_file="$BACKUP_DIR/radicale-$DATE.tar.gz"

  # Tar the collections from the Docker volume
  docker exec radicale tar czf - /data/collections > "$backup_file"

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

  log "Claudius backup complete: claudius-$DATE.tar.gz"
}

backup_downstream_server() {
  log "Backing up downstream-server..."

  local db_path="$HOME/apps/downstream-server/data/downstream.db"
  local backup_file="$BACKUP_DIR/downstream-server-$DATE.db"

  if [ ! -f "$db_path" ]; then
    error "downstream-server DB not found at $db_path"
    return 1
  fi

  if ! command -v sqlite3 &> /dev/null; then
    error "sqlite3 not installed, cannot back up downstream-server"
    return 1
  fi

  # Use the SQLite .backup command for a consistent online snapshot
  # (safe to run while the server is writing to the DB).
  #
  # Retry with a 5s busy-timeout because the live container's WAL-mode DB
  # can hold a brief write lock during a transaction — a one-shot call
  # races and fails with "database is locked" intermittently. A silent
  # missed nightly backup is much worse than a noisy retry. Same pattern
  # as scripts/reconcile-downstream.sh.
  local snapshot_ok=0
  local err_file="/tmp/downstream-backup-snap-err.$$"
  local attempt
  for attempt in 1 2 3 4 5; do
    if sqlite3 -cmd ".timeout 5000" "$db_path" ".backup '$backup_file'" 2>"$err_file"; then
      snapshot_ok=1
      break
    fi
    error "downstream-server snapshot attempt $attempt failed: $(cat "$err_file" 2>/dev/null)"
    rm -f "$backup_file"
    sleep 3
  done
  rm -f "$err_file"
  if [ "$snapshot_ok" -ne 1 ]; then
    error "sqlite3 .backup failed for downstream-server after 5 attempts"
    return 1
  fi

  log "downstream-server backup complete: downstream-server-$DATE.db"
}

backup_to_github() {
  local services=("$@")

  # Check prerequisites. Both error returns are 1 (not 0) so the caller's
  # FAILED_SERVICES tracking captures the failure — a missing deploy key
  # silently producing local-only backups for weeks (caught 2026-05-03)
  # is exactly the failure mode this script must surface.
  if ! command -v git &> /dev/null; then
    error "git not installed, GitHub backup failed"
    return 1
  fi
  if [ ! -f "$HOME/.ssh/imagineering-backups-deploy" ]; then
    error "Deploy key not found at ~/.ssh/imagineering-backups-deploy, GitHub backup failed"
    return 1
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

  # Copy each service dump, decompressing so git deltas work
  for svc in "${services[@]}"; do
    local dump
    dump=$(find "$BACKUP_DIR" -name "${svc}-${DATE}.*" -type f 2>/dev/null | head -1)

    if [ -z "$dump" ] || [ ! -f "$dump" ]; then
      error "Dump file not found for $svc (expected ${svc}-${DATE}.*)"
      continue
    fi

    case "$dump" in
      *.sql.gz)
        gunzip -c "$dump" > "$GITHUB_BACKUP_DIR/${svc}.sql"
        log "Decompressed $svc backup → ${svc}.sql"
        ;;
      *.tar.gz)
        gunzip -c "$dump" > "$GITHUB_BACKUP_DIR/${svc}.tar"
        log "Decompressed $svc backup → ${svc}.tar"
        ;;
      *)
        local ext="${dump##*.}"
        cp "$dump" "$GITHUB_BACKUP_DIR/${svc}.${ext}"
        log "Copied $svc backup → ${svc}.${ext}"
        ;;
    esac
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

  check_repo_size
}

cleanup_old_backups() {
  log "Cleaning up local backups older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
  log "Cleanup complete"
}

# Run backups
case $SERVICE in
  all)
    SUCCEEDED=()
    for svc in kanbn outline radicale pm-bot claudius downstream-server; do
      if "backup_${svc//-/_}"; then
        SUCCEEDED+=("$svc")
      else
        error "$svc backup failed"
        FAILED_SERVICES+=("$svc")
      fi
    done
    if [ ${#SUCCEEDED[@]} -gt 0 ]; then
      backup_to_github "${SUCCEEDED[@]}" || FAILED_SERVICES+=("github-upload")
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
  downstream-server)
    backup_downstream_server && backup_to_github downstream-server || FAILED_SERVICES+=(downstream-server)
    ;;
  cleanup)
    cleanup_old_backups
    ;;
  *)
    echo "Usage: $0 [all|kanbn|outline|radicale|pm-bot|claudius|downstream-server|cleanup]"
    exit 1
    ;;
esac

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
  error "Backups failed for: ${FAILED_SERVICES[*]}"
  exit 1
fi

log "Backup complete!"
