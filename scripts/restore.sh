#!/bin/bash
# Restore script for all services
# Restores from GitHub backup repo (imagineering-cc/imagineering-backups)
# Usage: ./restore.sh <service>
#   service: kanbn, outline, radicale, pm-bot, claudius, aiko-island, matrix, continuwuity
#
# Note: continuwuity requires the age private key path in $AGE_IDENTITY_FILE
# (default: ~/.config/sops/age/keys.txt — same file SOPS uses; age will try
# each key in the file until one matches). Restoring continuwuity replaces
# the live homeserver state — only do it on a fresh instance or after
# confirming the existing state is unrecoverable.

set -e

SERVICE=$1
RESTORE_DIR="/tmp/restore"
GITHUB_BACKUP_REPO="git@github-imagineering-backups:imagineering-cc/imagineering-backups.git"
BACKUP_CLONE_DIR="$RESTORE_DIR/imagineering-backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }

AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}}"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <service>"
  echo "  service: kanbn, outline, radicale, pm-bot, claudius, aiko-island, matrix, continuwuity"
  echo ""
  echo "Examples:"
  echo "  $0 kanbn         # Restore latest from GitHub backup"
  echo "  $0 outline       # Restore latest from GitHub backup"
  echo "  $0 matrix        # Restore all matrix bridges + relay-bots"
  echo "  $0 continuwuity  # Restore homeserver (requires AGE_IDENTITY_FILE)"
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

# Restore the aiko-chat-island SQLite store from the latest .sql dump in the
# backup repo. Mirrors the matrix-bridge sqlite restore: stop the container
# (never replay against a live DB), replace the DB from the dump inside the
# sqlite-dumper image (rw mount), restart. The dump carries the current schema
# (email col, nullable password_hash, social_identities), so the island's boot
# schema guard passes after restore. aiko_chat_gateway#4.
restore_aiko_island() {
  log "Restoring aiko-chat-island..."

  fetch_backups

  local sql_file="$BACKUP_CLONE_DIR/aiko-island.sql"
  # Validate the dump BEFORE touching anything: present, non-empty, and complete
  # (a COMPLETE sqlite .dump ends with COMMIT;). The island DB is the SOLE copy
  # of auth+messages+ACL, so a bad dump must never reach the destructive path.
  if [ ! -s "$sql_file" ]; then
    error "No (non-empty) aiko-island.sql in backup repo"; cleanup_backups; exit 1
  fi
  # End-anchored completeness check (see backup.sh): the LAST non-blank line of a
  # complete sqlite .dump is exactly `COMMIT;`. A whole-file grep could be fooled
  # by `COMMIT;` embedded in multiline data, accepting a truncated dump.
  if [ "$(grep -ve '^[[:space:]]*$' "$sql_file" | tail -n1)" != "COMMIT;" ]; then
    error "aiko-island.sql looks truncated/invalid (last line is not COMMIT;)"; cleanup_backups; exit 1
  fi

  # Irreversible: replacing the sole auth+message store. Require typed consent.
  echo "WARNING: this REPLACES the island's SOLE database (all accounts + messages + ACL)."
  echo "  dump: $sql_file ($(wc -l < "$sql_file") lines, $(du -h "$sql_file" | cut -f1))"
  read -r -p "Type 'restore aiko-island' to proceed: " confirm
  if [ "$confirm" != "restore aiko-island" ]; then
    error "Aborted (no confirmation)"; cleanup_backups; exit 1
  fi

  log "Stopping island..."
  cd ~/apps/aiko-chat-gateway
  docker compose stop

  # Build + validate the candidate in a TEMP file, and only swap it in on
  # success — the live aiko.db is untouched until a valid replacement exists.
  # The old DB is kept as a timestamped rescue copy inside the volume.
  local rescue
  rescue="aiko.db.rescue-$(date +%Y%m%d-%H%M%S)"
  log "Building + validating candidate DB (live DB untouched until it passes)..."
  if ! docker run --rm -i -v "aiko-chat-gateway_aiko_gateway_data:/data" sqlite-dumper:latest sh -c '
        set -e
        rm -f /data/aiko.db.restore /data/aiko.db.restore-wal /data/aiko.db.restore-shm
        sqlite3 /data/aiko.db.restore        # replay dump from stdin
        integ=$(sqlite3 /data/aiko.db.restore "PRAGMA integrity_check;")
        [ "$integ" = "ok" ] || { echo "integrity_check failed: $integ" >&2; exit 1; }
        sqlite3 /data/aiko.db.restore ".tables" | grep -qw users || { echo "no users table in restored DB" >&2; exit 1; }
        rescue="'"$rescue"'"
        # 1. Rescue the COMPLETE old state (db + any WAL/SHM) by full file copy —
        #    no checkpoint dependency, so the rescue is faithful even if the old
        #    DB is too corrupt to checkpoint. Every copy is FATAL under set -e
        #    (the `if` guards make ABSENCE non-fatal without masking cp failure):
        #    we never clobber the sole DB unless a complete copy exists first.
        if [ -f /data/aiko.db ]; then
          cp -p /data/aiko.db "/data/$rescue"
          if [ -f /data/aiko.db-wal ]; then cp -p /data/aiko.db-wal "/data/$rescue-wal"; fi
          if [ -f /data/aiko.db-shm ]; then cp -p /data/aiko.db-shm "/data/$rescue-shm"; fi
        fi
        # 2. Remove the old sidecars BEFORE installing the new DB (they are now
        #    rescued). Ordering matters: a fresh-from-.dump DB must never sit
        #    beside a stale, salt-mismatched WAL (SQLite corruption). Doing this
        #    before the install means there is never a new-db + stale-wal window.
        rm -f /data/aiko.db-wal /data/aiko.db-shm
        # 3. Atomic install LAST: a single rename, always old-or-new, never
        #    neither. If it fails, the live aiko.db is still the old one.
        mv -f /data/aiko.db.restore /data/aiko.db
      ' < "$sql_file"; then
    error "aiko-island restore FAILED. The candidate was rejected before the final install in almost all cases, so the live aiko.db is the original; a complete rescue copy (aiko.db.rescue-*) is also in the volume. Inspect the volume before retrying. Restarting on the current DB."
    docker compose up -d
    cleanup_backups
    exit 1
  fi

  log "Restored OK (previous DB kept in the volume as $rescue). Restarting island..."
  docker compose up -d

  cleanup_backups
  log "aiko-island restore complete!"
}

# Restore matrix bridges + relay-bot SQLite DBs from latest SQL dumps in the
# backup repo. Each .sql file is replayed against a fresh SQLite DB inside
# the bridge's volume. Bridges must be stopped before the replay (writing
# to a live DB while replaying would corrupt it). Continuwuity itself is
# NOT touched here — see restore_continuwuity for the homeserver.
restore_matrix() {
  log "Restoring matrix bridges + relay-bots..."

  fetch_backups

  local entries=(
    "matrix-discord:matrix_discord_data:discord.db"
    "matrix-signal:matrix_signal_data:signal.db"
    "matrix-telegram:matrix_telegram_data:mautrix-telegram.db"
    "matrix-whatsapp:matrix_whatsapp_data:whatsapp.db"
    "matrix-relay:matrix_relay_data:relay.db"
    "matrix-relay-hf:matrix_relay_hf_data:relay.db"
  )

  # Stop the matrix stack first so we don't write to live DBs.
  log "Stopping matrix stack..."
  cd ~/apps/matrix
  docker compose stop

  for entry in "${entries[@]}"; do
    IFS=: read -r name volume dbfile <<< "$entry"
    local sql_file="$BACKUP_CLONE_DIR/${name}.sql"
    if [ ! -f "$sql_file" ]; then
      warn "No ${name}.sql found in backup repo, skipping"
      continue
    fi

    log "  Restoring $name from ${name}.sql..."
    # Replace the existing DB with a fresh one populated from the dump.
    # Pipe SQL through stdin into sqlite3 in the sqlite-dumper container
    # (rw mount). Removing the old WAL/SHM files first prevents stale
    # write-ahead state corrupting the restore.
    docker run --rm -i -v "${volume}:/data" sqlite-dumper:latest sh -c \
      "rm -f /data/${dbfile} /data/${dbfile}-wal /data/${dbfile}-shm && \
       sqlite3 /data/${dbfile}" < "$sql_file" || \
      error "Restore failed for $name (continuing)"
  done

  log "Restarting matrix stack..."
  docker compose up -d

  cleanup_backups
  log "Matrix restore complete!"
}

# Restore Continuwuity from the most recent encrypted tarball in the
# backup repo. The tarball is a RocksDB BackupEngine directory (not a
# direct database snapshot) — it has meta/, private/, shared_checksum/
# subdirs and requires a BackupEngine restore step, NOT a simple replace
# of the data dir.
#
# Since Continuwuity has no `restore-database` admin command (only
# `backup-database` and `list-backups`), full restore needs RocksDB's
# `ldb restore` tool. This script extracts the encrypted backup into the
# continuwuity_backups volume and prints next-step guidance — full
# automation pending Continuwuity adding a restore command OR us shipping
# an ldb-based helper.
#
# CRITICAL: full restore REPLACES the live homeserver state — signing
# keys, room state, all messages, user accounts. Only do this on a fresh
# deployment or when the live state is confirmed unrecoverable.
#
# Requires the age private key at $AGE_IDENTITY_FILE (default:
# ~/.config/sops/age/keys.txt — same file SOPS uses). age will iterate
# all private keys in the file until one matches the encrypted recipient.
restore_continuwuity() {
  log "Restoring Continuwuity (partial — see notes at end)..."

  if [ ! -f "$AGE_IDENTITY_FILE" ]; then
    error "Age identity file not found at $AGE_IDENTITY_FILE"
    error "Set AGE_IDENTITY_FILE to the path of your private key."
    exit 1
  fi
  if ! command -v age &>/dev/null; then
    error "age not installed (apt-get install -y age)"
    exit 1
  fi

  fetch_backups

  local enc_file="$BACKUP_CLONE_DIR/continuwuity.tar.gz.age"
  if [ ! -f "$enc_file" ]; then
    error "No continuwuity.tar.gz.age found in backup repo"
    cleanup_backups
    exit 1
  fi

  warn "Backup file: $enc_file (committed $(stat -c %y "$enc_file" 2>/dev/null || echo unknown))"
  warn "This will extract the RocksDB BackupEngine backup into the"
  warn "matrix_continuwuity_backups volume. To actually restore INTO the"
  warn "live database, you'll need to run a BackupEngine restore step"
  warn "manually (see notes printed at the end)."
  read -r -p "Type 'extract-backup' to confirm: " confirm
  if [ "$confirm" != "extract-backup" ]; then
    log "Aborted"
    cleanup_backups
    exit 0
  fi

  # Decrypt + extract into the matrix_continuwuity_backups volume. This
  # does NOT touch the live continuwuity_data volume; the operator must
  # then run a BackupEngine restore as a separate manual step.
  log "Decrypting and extracting backup into matrix_continuwuity_backups..."
  if ! age -d -i "$AGE_IDENTITY_FILE" "$enc_file" \
       | docker run --rm -i -v matrix_continuwuity_backups:/data alpine \
         sh -c "rm -rf /data/* && tar xzf - -C /data"; then
    error "Decrypt/extract failed"
    cleanup_backups
    exit 1
  fi

  cleanup_backups
  log "Backup extracted to matrix_continuwuity_backups volume."
  echo ""
  warn "NEXT STEPS (manual): To restore the database from this backup, you"
  warn "need RocksDB's ldb tool to do a BackupEngine restore. Outline:"
  echo "  1. apt-get install -y rocksdb-tools  # provides 'ldb'"
  echo "  2. cd ~/apps/matrix && docker compose stop continuwuity"
  echo "  3. # Identify backup dir on host:"
  echo "     ls /var/lib/docker/volumes/matrix_continuwuity_backups/_data"
  echo "  4. # Restore into a temp dir then swap with continuwuity_data:"
  echo "     ldb --db=/tmp/restored restore \\"
  echo "         --backup_dir=/var/lib/docker/volumes/matrix_continuwuity_backups/_data"
  echo "  5. # Replace the live data volume contents with /tmp/restored"
  echo "  6. docker compose up -d continuwuity"
  echo ""
  echo "TODO: ship an ldb-based helper or wait for Continuwuity to add a"
  echo "      'restore-database' admin command (file an issue upstream)."
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
  aiko-island)
    restore_aiko_island
    ;;
  matrix)
    restore_matrix
    ;;
  continuwuity)
    restore_continuwuity
    ;;
  *)
    error "Unknown service: $SERVICE"
    echo "Valid services: kanbn, outline, radicale, pm-bot, claudius, aiko-island, matrix, continuwuity"
    exit 1
    ;;
esac
