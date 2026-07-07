#!/bin/bash
# Standalone aiko-chat-island DB backup for a SINGLE-SERVICE island box
# (e.g. the enspyr / Melbourne OCI box), which does NOT run the full fleet
# backup.sh. Dumps the island's SQLite DB and pushes it to the shared backup
# repo (imagineering-cc/imagineering-backups) under a per-island slug so two
# islands never clobber one file.
#
# Usage:  backup-aiko-island-standalone.sh <slug>
#   e.g.  backup-aiko-island-standalone.sh aiko-island-enspyr
#
# Requires: docker (run as root or a docker-group user), git, and a deploy key
# with WRITE on the backup repo at ~/.ssh/imagineering-backups-deploy plus the
# ssh host alias `github-imagineering-backups` (see the deploy notes / #1577).
#
# Mirrors the fleet backup.sh's aiko-island logic: auto-detect the live volume
# (survives the island cutover), .dump to text SQL (git-diffable), validate the
# dump ends in COMMIT; (a truncated dump is worse than none — restore replays it
# over the SOLE live DB), then pull --rebase + push (staggered from the Sydney
# 4am cron to avoid a push race on the shared repo).
set -euo pipefail

SLUG="${1:?usage: $0 <slug>  e.g. aiko-island-enspyr}"
DATE=$(date +%Y-%m-%d)
BACKUP_DIR="/tmp/backups"
GITHUB_BACKUP_REPO="git@github-imagineering-backups:imagineering-cc/imagineering-backups.git"
GITHUB_BACKUP_DIR="/tmp/imagineering-backups"
mkdir -p "$BACKUP_DIR"

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
fail()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2; exit 1; }

# --- Locate the LIVE island volume from the running container -----------------
# Hardcoding the volume name silently backs up a ghost after a compose/project
# cutover renames it (that bug bit Sydney — see fleet backup.sh). Derive it.
GW_CID=$(docker ps --format '{{.Names}}\t{{.Image}}' \
  | awk -F'\t' '$2 ~ /^aiko-chat-(island|gateway):/ {print $1; exit}')
[ -n "$GW_CID" ] || fail "no running island container (image aiko-chat-island|gateway:*)"
GW_VOL=$(docker inspect "$GW_CID" \
  --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
[ -n "$GW_VOL" ] || fail "container $GW_CID has no /data volume mount"
log "live island volume: $GW_VOL (container $GW_CID)"

# --- Dump (online-safe: read-only mount, .dump reads a consistent snapshot) ----
# The island image ships no sqlite3, so mount the volume read-only into a small
# alpine+sqlite image. Build it once if absent (idempotent).
if ! docker image inspect sqlite-dumper:latest >/dev/null 2>&1; then
  log "building sqlite-dumper:latest (alpine + sqlite3)"
  printf 'FROM alpine:3.20\nRUN apk add --no-cache sqlite\n' \
    | docker build -q -t sqlite-dumper:latest - >/dev/null
fi

TMP="$BACKUP_DIR/${SLUG}-${DATE}.sql"
ERR="$BACKUP_DIR/${SLUG}-${DATE}.err"
if ! docker run --rm -v "${GW_VOL}:/data:ro" sqlite-dumper:latest \
     sqlite3 -cmd '.timeout 5000' /data/aiko.db .dump > "$TMP" 2>"$ERR"; then
  fail "sqlite3 .dump failed: $(tr '\n' ' ' < "$ERR")"
fi
# A COMPLETE .dump's LAST non-blank line is exactly COMMIT; (end-anchored — app
# data can embed a line starting 'COMMIT;', which a whole-file grep would accept).
LAST=$(grep -ve '^[[:space:]]*$' "$TMP" | tail -n1)
[ "$LAST" = "COMMIT;" ] || fail "dump invalid (last line '$LAST', not COMMIT; — truncated): $(tr '\n' ' ' < "$ERR")"
rm -f "$ERR"
log "dump OK ($(wc -l < "$TMP") lines)"

# --- Push to the shared backup repo (git-diffable plaintext SQL) ---------------
[ -f "$HOME/.ssh/imagineering-backups-deploy" ] || fail "deploy key missing at ~/.ssh/imagineering-backups-deploy"
if [ -d "$GITHUB_BACKUP_DIR/.git" ]; then
  git -C "$GITHUB_BACKUP_DIR" pull --rebase 2>/dev/null || {
    rm -rf "$GITHUB_BACKUP_DIR"; git clone --depth 1 "$GITHUB_BACKUP_REPO" "$GITHUB_BACKUP_DIR"; }
else
  rm -rf "$GITHUB_BACKUP_DIR"
  git clone --depth 1 "$GITHUB_BACKUP_REPO" "$GITHUB_BACKUP_DIR"
fi
cp "$TMP" "$GITHUB_BACKUP_DIR/${SLUG}.sql"
git -C "$GITHUB_BACKUP_DIR" add -A
if git -C "$GITHUB_BACKUP_DIR" diff --cached --quiet; then
  log "no changes to push"
else
  git -C "$GITHUB_BACKUP_DIR" -c user.name="imagineering-backup" -c user.email="backup@imagineering.cc" \
    commit -q -m "backup ${SLUG} ${DATE}"
  # One rebase-retry on a race with the Sydney cron pushing concurrently.
  git -C "$GITHUB_BACKUP_DIR" push origin HEAD 2>/dev/null || {
    git -C "$GITHUB_BACKUP_DIR" pull --rebase && git -C "$GITHUB_BACKUP_DIR" push origin HEAD; }
  log "pushed ${SLUG}.sql to GitHub"
fi

# Local retention: keep 7 days of dated dumps.
find "$BACKUP_DIR" -name "${SLUG}-*.sql" -mtime +7 -delete 2>/dev/null || true
log "backup complete: ${SLUG}"
