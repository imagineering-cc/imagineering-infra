# Tiny utility image used by /opt/scripts/backup.sh:backup_matrix and
# restore.sh:restore_matrix. Pre-installs sqlite so we don't pay the
# `apk add` startup cost per-bridge on every nightly run (saved ~30s/run
# at 6 bridges).
#
# Build is idempotent and runs once per deploy via deploy_backups.
# Image is local-only — no registry needed.
FROM alpine:latest
RUN apk add --no-cache sqlite
