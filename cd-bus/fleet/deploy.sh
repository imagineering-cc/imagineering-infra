#!/bin/bash
# Deploy-bus deploy action — FLEET TEMPLATE (claude-tasks #714).
# Installed at /opt/cd-bus/deploy.sh. The ONE deploy action every CD leg runs
# (SSE push via subscribe.sh, and the 5-min poll backstop cd-poll@.timer), so
# legs never overlap (shared flock) and the operation is idempotent.
#
# Generalised from nickmeinhold/downstream deploy/oci's cd-poll.sh.
#
# Failure visibility: docker compose errors exit 1, which the poll unit treats
# as success (SuccessExitStatus=0 1) so a transient error just retries next
# tick. To surface a PERSISTENT outage, consecutive failures are counted in
# $FAIL_STATE; the 3rd consecutive failure (~15 min broken at the 5-min poll
# cadence) exits 2 — a real unit failure, not in SuccessExitStatus — firing
# OnFailure (Telegram). While the outage persists it re-alerts every 36th
# failure (~3 h at 5-min cadence); any success resets the count.
#
# NOTE on the SSE leg: subscribe.sh calls this on an event and treats ANY
# non-zero as deploy failure (it doesn't set SuccessExitStatus), so exit 1 vs 2
# both mean "retry" there — the counter exists for the poll leg's alerting.
set -euo pipefail

SVC="${1:?usage: deploy.sh <service>}"
APP_DIR="${APP_DIR:-/home/nick/apps/$SVC}"
# The compose service name may differ from the bus/instance name; default to
# the same. Override via /etc/cd-bus/$SVC.env if the compose service differs.
COMPOSE_SERVICE="${COMPOSE_SERVICE:-$SVC}"
FAIL_STATE="$APP_DIR/.cd-poll-failcount"

cd "$APP_DIR"
# Lock so a slow pull cannot overlap the next timer tick or an SSE event.
# Per-service lock file: legs of the SAME service serialise; different services
# deploy in parallel.
exec 9>"/tmp/cd-bus-deploy-$SVC.lock"
flock -n 9 || { echo "previous run still holding the lock for $SVC; skipping"; exit 0; }

if docker compose pull "$COMPOSE_SERVICE" && docker compose up -d "$COMPOSE_SERVICE"; then
  rm -f "$FAIL_STATE"
  exit 0
fi

# A corrupt/empty state file would make the arithmetic blow up (exit 1 = the
# SILENT retry path — alerting suppressed exactly when needed), so validate
# before use and treat garbage as a fresh streak.
prev=$(cat "$FAIL_STATE" 2>/dev/null || echo 0)
[[ "$prev" =~ ^[0-9]+$ ]] || prev=0
count=$((10#$prev + 1))  # 10# so a stray leading zero can't trip octal parsing
echo "$count" >"$FAIL_STATE"
echo "docker compose pull/up failed for $SVC (consecutive failure #${count})" >&2
# Threshold (count==3) and every 36 thereafter: exit 2 -> unit failure ->
# OnFailure alert. Everything else: exit 1 -> silent retry.
if [ "$count" -ge 3 ] && [ $(((count - 3) % 36)) -eq 0 ]; then
  exit 2
fi
exit 1
