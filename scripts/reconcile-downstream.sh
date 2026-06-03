#!/bin/bash
# Nightly reconciler for downstream-server.
#
# Probes every `available` row in the live SQLite DB against B2/CDN reality
# (DB → CDN 200 → moov-atom presence) and writes a structured report to a
# log file. Report-only by default — never mutates DB or B2.
#
# Runs the `reconcile` binary that ships *inside* the downstream-server image
# (/app/bin/reconcile, baked alongside /app/bin/server). The DB is snapshotted
# via `sqlite3 .backup` first because the live DB is held open in WAL mode by
# the running container — opening it directly fails with "database is locked".
#
# Why the image binary, not a source checkout + runtime codegen: the previous
# design rsynced the server source to ~/apps/downstream-server/source and ran
# `dart pub get` + Drift `build_runner` + `dart run` every night. That rsync
# (from the retired pre-GHCR deploy) silently froze at a non-compiling commit
# and the cron exited 254 nightly for ~a month, blinding the only consistency
# canary (imagineering #349/#360). Shipping the binary in the image means the
# reconciler is always in lockstep with the running server's schema by
# construction — no source tree to go stale, no SDK pin to drift, no codegen
# in cron. The image referenced here is the same locally-present :latest the
# host CD poll keeps current, so the reconciler matches the running server.
#
# Exit codes (mirror /app/bin/reconcile, i.e. bin/reconcile_b2.dart):
#   0  no issues found (or only transient probe failures and not --strict)
#   1  data-integrity issues found
#   2  invalid arguments / missing B2 creds when --apply needs them
#   3  transient probe failures with --strict set
#   other  setup/snapshot/container failure (logged)
#
# Manual run for ad-hoc verification:
#   /opt/scripts/reconcile-downstream.sh
# Tail the latest run:
#   tail -f /home/nick/logs/reconcile-downstream.log
#
# RECONCILE_ARGS is word-split (unquoted) into the container command. Flags +
# integers + URLs without spaces are fine (the current usage). Args containing
# spaces are not supported. For `--apply` runs that need to mutate the B2
# manifest, also pass B2 creds, e.g. via `RECONCILE_DOCKER_ARGS="--env-file
# /home/nick/apps/downstream-server/.env"`.

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
# The downstream-server image. Same tag the host CD poll keeps current, so the
# baked /app/bin/reconcile matches the running server's schema. Referenced by
# tag (not pulled here) so the reconciler uses the exact local image the
# running container does; CD owns image freshness.
IMAGE="ghcr.io/nickmeinhold/downstream-server:latest"

# Telegram alert config — credentials and the send_telegram_alert helper
# come from the shared lib, which sources /etc/downstream-secrets/telegram.env
# at deploy targets so this script never has to see the bot token in its
# environment from a world-readable cron entry.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/telegram.sh
. "$SCRIPT_DIR/lib/telegram.sh"

# Forwarded to the reconcile binary (word-split). Override at the cron
# call-site or env. Empty = report-only default.
RECONCILE_ARGS="${RECONCILE_ARGS:-}"
# Extra `docker run` args (word-split), e.g. an --env-file for --apply runs
# that need B2 creds. Empty by default — report-only needs no creds.
RECONCILE_DOCKER_ARGS="${RECONCILE_DOCKER_ARGS:-}"

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

# Run the baked reconcile binary in a one-shot container.
#   - snapshot mounted read-only at /data/downstream.db, the path the binary
#     defaults to (the image sets ENV DB_PATH=/data/downstream.db).
#   - the image has no ENTRYPOINT (CMD is /app/bin/server), so naming
#     /app/bin/reconcile as the command overrides CMD to run the reconciler.
#   - libsqlite3 for Drift's FFI loader is already in the image (same dep the
#     server needs), so nothing to install at runtime.
#   - report-only needs no env; --apply runs add creds via RECONCILE_DOCKER_ARGS.
# shellcheck disable=SC2086  # intentional word-splitting of the *_ARGS vars
docker run --rm \
  -v "$DB_SNAPSHOT":/data/downstream.db:ro \
  $RECONCILE_DOCKER_ARGS \
  "$IMAGE" \
  /app/bin/reconcile $RECONCILE_ARGS
status=$?

echo "=== reconcile-downstream done (exit=$status) ==="

# Alert on data-integrity issues (exit 1 from the reconciler). Other non-zero
# exits (snapshot failure, transient probe failure with --strict, bad args,
# container/setup error) also warrant a heads-up — silent failure of the only
# catch-all consistency check is worse than a noisy ping. The tail of the log
# file is included so the alert is actionable from a phone.
if [ $status -ne 0 ]; then
  log_tail=""
  if [ -f /home/nick/logs/reconcile-downstream.log ]; then
    # Escape HTML special chars so Telegram's HTML parser doesn't choke on
    # log content containing <, >, or & (paths, stderr from sub-commands,
    # Dart stack frames). Without this, the alert silently fails to send
    # exactly when we most need it.
    raw_tail=$(tail -n 20 /home/nick/logs/reconcile-downstream.log 2>/dev/null | head -c 2000)
    log_tail=$(telegram_html_escape "$raw_tail")
  fi
  send_telegram_alert "$(printf '<b>downstream reconcile alert</b>\nexit=%s (1=data integrity, 3=strict transient, other=setup)\n<pre>%s</pre>' "$status" "$log_tail")"
fi

exit $status
