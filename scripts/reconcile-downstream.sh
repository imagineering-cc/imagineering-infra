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
#
# RECONCILE_ARGS is forwarded into a `bash -c` and word-split by the inner
# shell. Flags + integers + URLs without spaces are fine (the current usage).
# Args containing spaces are not supported — pass them through a wrapper if
# you ever need that.

# `set -e` is deliberately omitted so the snapshot retry loop and the final
# `docker run` can return non-zero without aborting the script before we
# capture the exit code into `$status` for the caller.
set -uo pipefail

# Singleton guard: prevent two cron-triggered runs from overlapping (e.g.
# if a long reconcile against a slow CDN bleeds past 24h). The second run
# exits silently with status 0 — overlap is not an error condition, just
# a no-op.
LOCKFILE="/var/lock/reconcile-downstream.lock"
exec 9>"$LOCKFILE" 2>/dev/null || {
  echo "ERROR: cannot open lockfile $LOCKFILE" >&2
  exit 12
}
if ! flock -n 9; then
  echo "$(date -Iseconds): another reconcile run is in progress, skipping"
  exit 0
fi

DB_LIVE="/home/nick/apps/downstream-server/data/downstream.db"
DB_SNAPSHOT="/tmp/downstream-reconcile-$$.db"
SOURCE_DIR="/home/nick/apps/downstream-server/source"
PUB_CACHE_VOLUME="downstream-reconcile-pub-cache"
# Pinned Dart SDK tag (was `dart:stable`). The reconciler script lives outside
# the downstream monorepo, so `:stable` is a silent moving target — a future
# major bump could break the run mid-night with no signal until the Telegram
# alert fires. Pin to a known-good tag matching downstream's
# `environment.sdk: ^3.5.0` constraint. Bump deliberately when the server's
# own Dockerfile bumps.
DART_IMAGE="dart:3.11.5"

# Telegram alert config (optional). Cron call-site exports these env vars
# from sops-encrypted backups/secrets.yaml; if absent, alerts are skipped.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"

# Send a Telegram alert. Mirrors the helper in scripts/backup.sh and
# scripts/health-check.sh. Silent no-op if creds are not configured so a
# missing-secret deploy doesn't turn into a daily cron error spam.
send_telegram_alert() {
  local message="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "Telegram alert skipped (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set)"
    return 0
  fi
  local -a args=(
    -s -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    -d "chat_id=$TELEGRAM_CHAT_ID"
    -d "parse_mode=HTML"
    --data-urlencode "text=$message"
  )
  if [ -n "$TELEGRAM_THREAD_ID" ]; then
    args+=(-d "message_thread_id=$TELEGRAM_THREAD_ID")
  fi
  curl "${args[@]}" > /dev/null 2>&1 || true
}

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

# Alert on data-integrity issues (exit 1 from bin/reconcile_b2.dart). Other
# non-zero exits (snapshot failure, transient probe failure with --strict,
# bad args, container/setup error) also warrant a heads-up — silent failure
# of the only catch-all consistency check is worse than a noisy ping. The
# tail of the log file is included so the alert is actionable from a phone.
if [ $status -ne 0 ]; then
  log_tail=""
  if [ -f /home/nick/logs/reconcile-downstream.log ]; then
    # Escape HTML special chars so Telegram's HTML parser doesn't choke on
    # log content containing <, >, or & (paths, stderr from sub-commands,
    # Dart stack frames). Without this, the alert silently fails to send
    # exactly when we most need it. Order matters: & must be escaped first.
    log_tail=$(tail -n 20 /home/nick/logs/reconcile-downstream.log 2>/dev/null \
      | head -c 2000 \
      | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  fi
  send_telegram_alert "$(printf '<b>downstream reconcile alert</b>\nexit=%s (1=data integrity, 3=strict transient, other=setup)\n<pre>%s</pre>' "$status" "$log_tail")"
fi

exit $status
