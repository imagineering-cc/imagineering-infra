#!/bin/bash
# Unified backup script for all services
# Dumps databases/data, pushes to GitHub (imagineering-cc/imagineering-backups)
# Usage: ./backup.sh [all|kanbn|outline|radicale|pm-bot|claudius|downstream-server|matrix|continuwuity]

SERVICE=${1:-all}
BACKUP_DIR="/tmp/backups"
DATE=$(date +%Y-%m-%d)
RETENTION_DAYS=7
FAILED_SERVICES=()

# GitHub backup config
GITHUB_BACKUP_REPO="git@github-imagineering-backups:imagineering-cc/imagineering-backups.git"
GITHUB_BACKUP_DIR="/tmp/imagineering-backups"
GITHUB_REPO_SIZE_ALERT_MB=500

# Continuwuity backup config. AGE_RECIPIENT and MATRIX_ADMIN_TOKEN are
# sourced at runtime from MATRIX_ADMIN_SECRETS_FILE (see backup_continuwuity).
# Decryption: `age -d -i <key> continuwuity.tar.gz.age | tar xzf -`.
MATRIX_ADMIN_SECRETS_FILE="/etc/imagineering-secrets/matrix.env"
CONTINUWUITY_ADMIN_ROOM='!L8ZmuakjgpeL1P3Jl8:imagineering.cc'
CONTINUWUITY_HOMESERVER='https://matrix.imagineering.cc'
# Continuwuity tarballs are large + opaque to git deltas. When the repo
# exceeds this size, prune_repo_history_if_needed collapses history to a
# fresh root commit (loses non-essential git history; keeps current files).
RETENTION_PRUNE_THRESHOLD_MB=300

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

# Dumps each mautrix bridge's SQLite DB + both relay-bots' DBs to .sql.gz.
# The bridge container images don't ship sqlite3, so we mount each volume
# read-only into an ephemeral alpine container that installs sqlite3 on the
# fly. Using `.dump` (text SQL) instead of `.backup` (binary checkpoint) so
# the resulting files diff cleanly in git — same pattern as Kan.bn/Outline.
backup_matrix() {
  log "Backing up matrix bridges + relay-bots..."

  # (svc_name, docker_volume, db_filename) — adjust if new bridges added.
  local entries=(
    "matrix-discord:matrix_discord_data:discord.db"
    "matrix-signal:matrix_signal_data:signal.db"
    "matrix-telegram:matrix_telegram_data:mautrix-telegram.db"
    "matrix-whatsapp:matrix_whatsapp_data:whatsapp.db"
    "matrix-relay:matrix_relay_data:relay.db"
    "matrix-relay-hf:matrix_relay_hf_data:relay.db"
  )

  local any_failed=0
  for entry in "${entries[@]}"; do
    IFS=: read -r name volume dbfile <<< "$entry"
    local out="$BACKUP_DIR/${name}-$DATE.sql.gz"

    # Mount volume read-only; install sqlite3 in the alpine container; dump
    # to stdout. apk's quiet flags keep the log clean. The pipe to gzip
    # happens on the host. If the dump fails or produces an empty file we
    # remove the artifact so backup_to_github errors loudly rather than
    # silently committing zero bytes.
    if ! docker run --rm -v "${volume}:/data:ro" alpine sh -c \
      "apk add -q --no-cache sqlite >/dev/null 2>&1 && \
       sqlite3 -cmd '.timeout 5000' /data/${dbfile} .dump" 2>/dev/null \
       | gzip > "$out"; then
      error "${name} sqlite3 .dump failed"
      rm -f "$out"
      any_failed=1
      continue
    fi
    if [ ! -s "$out" ]; then
      error "${name} dump produced empty output"
      rm -f "$out"
      any_failed=1
      continue
    fi
    log "  ${name} → $(basename "$out") ($(du -h "$out" | cut -f1))"
  done

  if [ "$any_failed" -eq 1 ]; then
    return 1
  fi
  log "Matrix backup complete"
}

# Triggers Continuwuity's online RocksDB checkpoint via the admin API
# (`!admin server backup-database`). Each run wipes the in-volume backup
# dir first, then triggers the admin command which writes a fresh
# checkpoint, then tars+age-encrypts the output. RocksDB BackupEngine
# uses hardlinks back to the live SST files so the operation is fast
# and online — Continuwuity stays available throughout. Encryption is
# critical: this tarball contains the homeserver signing keys
# (irreplaceable identity).
backup_continuwuity() {
  log "Backing up Continuwuity..."

  if ! command -v age &>/dev/null; then
    error "age not installed; run apt-get install -y age"
    return 1
  fi
  if [ ! -f "$MATRIX_ADMIN_SECRETS_FILE" ]; then
    error "Matrix admin secrets file missing at $MATRIX_ADMIN_SECRETS_FILE"
    return 1
  fi
  # Source secrets file FIRST so MATRIX_ADMIN_TOKEN and AGE_RECIPIENT are
  # populated before the checks below.
  # shellcheck source=/dev/null
  . "$MATRIX_ADMIN_SECRETS_FILE"
  if [ -z "${MATRIX_ADMIN_TOKEN:-}" ]; then
    error "MATRIX_ADMIN_TOKEN not set in $MATRIX_ADMIN_SECRETS_FILE"
    return 1
  fi
  if [ -z "${AGE_RECIPIENT:-}" ]; then
    error "AGE_RECIPIENT not set; refusing to back up signing keys in plaintext"
    return 1
  fi

  local backup_volume="matrix_continuwuity_backups"
  local out="$BACKUP_DIR/continuwuity-$DATE.tar.gz.age"

  # Continuwuity uses RocksDB's BackupEngine (not Checkpoint API). Each
  # call adds an incremental backup into the same directory (meta/,
  # private/, shared_checksum/). If left alone, the dir grows over time as
  # incrementals accumulate — meaning each daily tarball grows too.
  #
  # We wipe the dir before each run so every tarball is a fresh, complete
  # snapshot of constant size (~equal to a single full RocksDB backup,
  # which for our scale is ~50MB encrypted). Safe because shared_checksum/
  # only holds hardlinks back to the live data dir's SST files — deleting
  # the hardlinks doesn't touch the live database.

  # 1. Wipe previous backup contents so this run produces a clean snapshot.
  log "  Wiping previous backup contents..."
  docker run --rm -v "${backup_volume}:/data" alpine \
    sh -c "rm -rf /data/* /data/.* 2>/dev/null; true" >/dev/null 2>&1 || true

  # 2. Trigger the online backup via the admin room.
  local txn; txn=$(date +%s%N)
  local trigger_resp
  trigger_resp=$(curl -sf -X PUT \
    -H "Authorization: Bearer $MATRIX_ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    "$CONTINUWUITY_HOMESERVER/_matrix/client/v3/rooms/$CONTINUWUITY_ADMIN_ROOM/send/m.room.message/$txn" \
    -d '{"msgtype":"m.text","body":"!admin server backup-database"}' 2>&1) || {
    error "Failed to send backup-database admin command: $trigger_resp"
    return 1
  }

  # 3. Wait for the backup to appear (meta/ subdir gets created when
  # BackupEngine writes its first backup). 5 min cap is generous for
  # multi-GB databases; typical completion is <10s.
  local meta_exists=0
  for _ in $(seq 1 60); do
    sleep 5
    if docker run --rm -v "${backup_volume}:/data:ro" alpine \
         test -d /data/meta 2>/dev/null; then
      meta_exists=1
      break
    fi
  done
  if [ "$meta_exists" -ne 1 ]; then
    error "Continuwuity backup did not complete within 5 minutes (meta/ never appeared)"
    return 1
  fi
  log "  Backup completed"

  # 4. Tar the whole backups dir through age encryption. Alpine ships
  # busybox tar (not GNU), so we avoid GNU-specific flags. The dir is
  # static at this point (we just produced a fresh snapshot and won't
  # call backup-database again until tomorrow), so no concurrent-write
  # concerns.
  if ! docker run --rm -v "${backup_volume}:/data:ro" alpine \
       tar czf - -C /data . 2>/dev/null \
       | age -r "$AGE_RECIPIENT" > "$out"; then
    error "Continuwuity tar/encrypt failed"
    rm -f "$out"
    return 1
  fi
  if [ ! -s "$out" ]; then
    error "Continuwuity encrypted tarball is empty"
    rm -f "$out"
    return 1
  fi

  log "Continuwuity backup complete: $(basename "$out") ($(du -h "$out" | cut -f1))"
}

# Repo size management. Continuwuity tarballs are encrypted opaque binary
# blobs — git cannot delta them, so each daily commit grows the .git pack
# by roughly the tarball size. Rather than try to surgically remove old
# blobs from history (filter-repo with date-conditional callbacks is
# fragile across versions), we collapse the entire repo to a fresh root
# commit when total size exceeds RETENTION_PRUNE_THRESHOLD_MB.
#
# What we lose: git diff history for the bridge SQL files. What we keep:
# every current file (latest backups for all services). For a backup repo
# this is the right trade — history is decorative; the latest state is
# what restore actually uses. Trigger frequency depends on rate of growth:
# at ~50MB/day with a 300MB threshold this is ~weekly.
prune_repo_history_if_needed() {
  local repo=$1
  local threshold_mb=${RETENTION_PRUNE_THRESHOLD_MB:-300}

  local total_mb
  total_mb=$(du -sm "$repo" 2>/dev/null | awk '{print $1}')
  if [ -z "$total_mb" ] || [ "$total_mb" -lt "$threshold_mb" ]; then
    return 0
  fi

  log "Repo size ${total_mb}MB exceeds prune threshold ${threshold_mb}MB; collapsing history..."

  # Create a fresh orphan branch with current files, replace main, push
  # force-with-lease. Only the cron writes here so collision is unlikely;
  # --force-with-lease is the safety belt that aborts if origin shifted.
  if ! git -C "$repo" checkout --orphan _prune_tmp 2>&1 | tail -3; then
    error "checkout --orphan failed; skipping prune"
    return 1
  fi
  git -C "$repo" add -A
  git -C "$repo" \
    -c user.name="imagineering-backup" \
    -c user.email="backup@imagineering.cc" \
    commit -m "backup $DATE (history pruned)"
  git -C "$repo" branch -D main 2>/dev/null || true
  git -C "$repo" branch -m main
  if git -C "$repo" push --force-with-lease origin main 2>&1 | tail -3; then
    log "Repo history pruned to single root commit ($(du -sm "$repo" | awk '{print $1}')MB)"
  else
    error "Failed to force-push pruned history; manual intervention needed"
    return 1
  fi
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
      *.tar.gz.age)
        # Encrypted opaque binary — pass through as-is. Git can't delta
        # these; that's why prune_repo_history_if_needed runs afterwards.
        cp "$dump" "$GITHUB_BACKUP_DIR/${svc}.tar.gz.age"
        log "Copied $svc backup → ${svc}.tar.gz.age"
        ;;
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

  # Cap unbounded git history growth from daily continuwuity tarballs.
  # Cheap to run; only triggers when repo exceeds RETENTION_PRUNE_THRESHOLD_MB.
  prune_repo_history_if_needed "$GITHUB_BACKUP_DIR" || \
    error "repo history prune failed (non-fatal)"
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
    # Matrix produces up to 6 separate files (one per bridge + 2 relay-bots).
    # Each becomes its own "service" entry for backup_to_github so they
    # land as individual files in the repo root (git-diffable SQL). Track
    # successes individually so that a failure of one bridge doesn't drop
    # the backups of the others from the commit.
    backup_matrix || error "matrix backup had partial failures"
    for matrix_svc in matrix-discord matrix-signal matrix-telegram \
                      matrix-whatsapp matrix-relay matrix-relay-hf; do
      if find "$BACKUP_DIR" -name "${matrix_svc}-${DATE}.*" -type f 2>/dev/null | grep -q .; then
        SUCCEEDED+=("$matrix_svc")
      else
        FAILED_SERVICES+=("$matrix_svc")
      fi
    done
    # Continuwuity is a single encrypted tarball. Don't run if matrix
    # bridges failed catastrophically — we'd be wasting time on a single
    # service in a broader-outage situation. But individual matrix-bridge
    # failures are fine; continuwuity is independent of bridge state.
    if backup_continuwuity; then
      SUCCEEDED+=("continuwuity")
    else
      error "continuwuity backup failed"
      FAILED_SERVICES+=("continuwuity")
    fi
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
  matrix)
    if backup_matrix; then
      backup_to_github matrix-discord matrix-signal matrix-telegram \
                       matrix-whatsapp matrix-relay matrix-relay-hf \
        || FAILED_SERVICES+=("github-upload")
    else
      FAILED_SERVICES+=(matrix)
    fi
    ;;
  continuwuity)
    backup_continuwuity && backup_to_github continuwuity || FAILED_SERVICES+=(continuwuity)
    ;;
  cleanup)
    cleanup_old_backups
    ;;
  *)
    echo "Usage: $0 [all|kanbn|outline|radicale|pm-bot|claudius|downstream-server|matrix|continuwuity|cleanup]"
    exit 1
    ;;
esac

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
  error "Backups failed for: ${FAILED_SERVICES[*]}"
  exit 1
fi

log "Backup complete!"
