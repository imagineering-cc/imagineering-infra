#!/bin/bash
# Nightly reconciler for downstream-server.
#
# Probes every `available` row in the live SQLite DB against B2/CDN reality
# (DB → CDN 200 → moov-atom presence) and writes a structured report to a
# log file. Report-only — never mutates DB or B2.
#
# Runs the Dart script `bin/reconcile_b2.dart` from the rsynced server source
# tree under a one-shot `dart:stable` container with a persistent pub-cache
# volume so subsequent runs are fast. The DB is snapshotted via
# `sqlite3 .backup` first because the live DB is held open in WAL mode by
# the running container — opening it directly fails with "database is locked".
#
# Exit codes (mirrors bin/reconcile_b2.dart):
#   0  no issues found (or only transient probe failures and not --strict)
#   1  data-integrity issues found
#   2  invalid arguments
#   3  transient probe failures with --strict set
#   other  setup/snapshot failure (logged)
#
# Manual run for ad-hoc verification:
#   /opt/scripts/reconcile-downstream.sh
# Tail the latest run:
#   tail -f /home/nick/logs/reconcile-downstream.log

set -uo pipefail

DB_LIVE="/home/nick/apps/downstream-server/data/downstream.db"
DB_SNAPSHOT="/tmp/downstream-reconcile-$$.db"
SOURCE_DIR="/home/nick/apps/downstream-server/source"
PUB_CACHE_VOLUME="downstream-reconcile-pub-cache"
DART_IMAGE="dart:stable"

# Forwarded to the Dart script. Override at the cron call-site or env.
RECONCILE_ARGS="${RECONCILE_ARGS:-}"

cleanup() {
  rm -f "$DB_SNAPSHOT"
}
trap cleanup EXIT

echo "=== reconcile-downstream $(date -Iseconds) ==="

if [ ! -f "$DB_LIVE" ]; then
  echo "ERROR: live DB not found at $DB_LIVE" >&2
  exit 10
fi

# Snapshot the live DB. `sqlite3 .backup` is safe against a writer holding
# the DB open (WAL-aware); a plain cp is not. The container can hold a brief
# write lock during a transaction, so we retry a few times with a busy
# timeout before giving up.
snapshot_ok=0
for attempt in 1 2 3 4 5; do
  if sqlite3 -cmd ".timeout 5000" "$DB_LIVE" ".backup $DB_SNAPSHOT" 2>/tmp/recon-snap-err.$$; then
    snapshot_ok=1
    break
  fi
  echo "snapshot attempt $attempt failed: $(cat /tmp/recon-snap-err.$$)" >&2
  rm -f "$DB_SNAPSHOT"
  sleep 3
done
rm -f /tmp/recon-snap-err.$$
if [ "$snapshot_ok" -ne 1 ]; then
  echo "ERROR: sqlite3 .backup failed after 5 attempts" >&2
  exit 11
fi

# Run reconcile in a one-shot dart container.
#   - source mounted read-write at /src so `dart pub get` can write the
#     synthetic workspace pubspec and .dart_tool/. The image is ephemeral.
#   - snapshot mounted read-only at the path the script expects by default.
#   - pub cache persisted across runs in a named volume so we don't re-fetch
#     65 packages every night.
#   - libsqlite3-dev installed at runtime (Drift's FFI loader needs the
#     unversioned `libsqlite3.so` symlink, same constraint as the prod image).
docker run --rm \
  -v "$SOURCE_DIR":/src \
  -v "$DB_SNAPSHOT":/data/downstream.db:ro \
  -v "$PUB_CACHE_VOLUME":/root/.pub-cache \
  -w /src \
  "$DART_IMAGE" \
  bash -c '
    set -e
    apt-get update -qq && apt-get install -y -qq libsqlite3-dev > /dev/null
    # Generate the minimal workspace pubspec the Dockerfile uses so
    # `dart pub get` resolves only the server + shared package, not the
    # full monorepo workspace.
    cat > pubspec.yaml <<EOF
name: downstream_workspace
publish_to: none
environment:
  sdk: ^3.5.0
workspace:
  - downstream-server
  - packages/downstream_shared
EOF
    cd downstream-server
    dart pub get
    exec dart run bin/reconcile_b2.dart '"$RECONCILE_ARGS"'
  '
status=$?

echo "=== reconcile-downstream done (exit=$status) ==="
exit $status
