#!/bin/bash
# Deploy-bus SSE subscriber — FLEET TEMPLATE (claude-tasks #714).
# Installed at /opt/cd-bus/subscribe.sh; driven by cd-bus-subscriber@.service.
#
# Generalised from nickmeinhold/downstream deploy/oci's cd-bus-subscribe.sh
# (the proven pilot). One copy serves every bus-managed service: the service
# name is $1 (the systemd instance %i), and all paths/config derive from it,
# overridable via /etc/cd-bus/{common,$SVC}.env.
#
# Holds an outbound-only SSE connection to the cd-bus relay and invokes the
# shared deploy action on each image.published event. The deploy action takes
# the flock all CD legs share (SSE push here, the 5-min poll backstop), so legs
# never overlap and `docker compose up -d` is idempotent.
#
# Replay: the relay retains the last event per service and replays it on
# (re)connect unless our Last-Event-ID proves we saw it. An UNSEEN id deploys
# (catch-up after host downtime); a SEEN id is skipped via $STATE.
#
# Failure visibility: a stream that ends after a HEALTHY hold is a normal
# Cloudflare-Worker connection recycle (Workers cap streaming lifetime), NOT a
# failure — exit 0, systemd (Restart=always) reconnects silently. Only two
# things exit non-zero (-> start-limit -> failed -> OnFailure alert): a deploy
# that fails, or a connection that dies almost immediately (relay unreachable).
set -uo pipefail

SVC="${1:?usage: subscribe.sh <service> (the systemd instance %i)}"
# Per-service config, all overridable via the EnvironmentFiles:
#   BUS_URL          relay base (shared; default = the custom domain)
#   SUBSCRIBE_TOKEN  relay /events bearer (shared; empty => public-pilot no-op)
#   APP_DIR          the service's compose dir on the host
#   HEALTHY_MIN_SECS hold >= this before a relay-closed stream counts healthy
BUS_URL="${BUS_URL:-https://cd-bus.imagineering.cc}"
SUBSCRIBE_TOKEN="${SUBSCRIBE_TOKEN:-}"
APP_DIR="${APP_DIR:-/home/nick/apps/$SVC}"
STATE="$APP_DIR/.cd-bus-last-event-id"
DEPLOY="${DEPLOY:-/opt/cd-bus/deploy.sh}"
HEALTHY_MIN_SECS="${HEALTHY_MIN_SECS:-60}"

# Dispatch one complete SSE event. Returns non-zero only on deploy failure.
handle_event() {
  local ev_id="$1" ev_data="$2" digest seen
  digest=$(printf '%s' "$ev_data" | jq -r '.digest // empty' 2>/dev/null)
  [ -z "$digest" ] && return 0 # not an image.published payload; ignore
  seen=$(cat "$STATE" 2>/dev/null || true)
  if [ -n "$ev_id" ] && [ "$ev_id" = "$seen" ]; then
    echo "event id=$ev_id already deployed; skipping (replay)"
    return 0
  fi
  echo "image.published id=${ev_id:-?} digest=$digest -> deploying $SVC"
  # KNOWN BENIGN RACE: if another CD leg holds the flock now, deploy.sh exits 0
  # ("skipping") and we mark the id seen without having deployed THIS event
  # ourselves. The concurrent holder runs the same idempotent pull/up; worst
  # case is corrected by the next poll tick. Exit-0-on-lock-skip is success by
  # design — do not "fix" this by parsing output.
  if "$DEPLOY" "$SVC"; then
    [ -n "$ev_id" ] && echo "$ev_id" >"$STATE"
    echo "deploy ok (id=${ev_id:-?})"
    return 0
  fi
  echo "deploy FAILED (id=${ev_id:-?}); exiting for restart+replay retry" >&2
  return 1
}

echo "subscribing to $BUS_URL/events/$SVC"

# Last-Event-ID on (re)connect so the relay can skip replaying an event we
# already deployed (standard SSE resumption).
hdr=()
seen_at_start=$(cat "$STATE" 2>/dev/null || true)
[ -n "$seen_at_start" ] && hdr=(-H "Last-Event-ID: $seen_at_start")

# Subscribe auth (claude-tasks #20): pass the bearer via a 0600 header FILE
# (curl -H @file), NEVER a -H "Bearer ..." ARG — an arg is world-readable in
# the process table (ps -ef, /proc/<pid>/cmdline), which on a multi-tenant host
# leaks the token to other service users. The file is removed on exit. No-op
# while SUBSCRIBE_TOKEN is empty (relay /events still public, header omitted).
hdrfile=""
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() { [ -n "$hdrfile" ] && rm -f "$hdrfile"; }
trap cleanup EXIT
if [ -n "$SUBSCRIBE_TOKEN" ]; then
  hdrfile=$(umask 077; mktemp "${TMPDIR:-/tmp}/cd-bus-hdr-$SVC.XXXXXX") || exit 1
  printf 'Authorization: Bearer %s\n' "$SUBSCRIBE_TOKEN" >"$hdrfile"
  hdr+=(-H "@$hdrfile")
fi

# SSE parsing per spec: an event is a block of fields terminated by a blank
# line; `data:` may span multiple lines. Accumulate, dispatch on the boundary,
# reset. Comment lines (": ping" heartbeats) match no field and are ignored.
ev_id=""
ev_data=""
CONNECT_EPOCH=$(date +%s)
curl -sN --no-buffer ${hdr[@]+"${hdr[@]}"} "$BUS_URL/events/$SVC" |
while IFS= read -r line; do
  case "$line" in
    id:*)
      ev_id="${line#id:}"
      ev_id="${ev_id# }"
      ;;
    data:*)
      d="${line#data:}"
      d="${d# }"
      ev_data="${ev_data:+$ev_data
}$d"
      ;;
    "")
      # Blank line = event boundary. exit 3 (not 1) so the deploy-failure case
      # is distinguishable from a plain stream-end after the pipe.
      if [ -n "$ev_data" ]; then
        handle_event "$ev_id" "$ev_data" || exit 3
      fi
      ev_id=""
      ev_data=""
      ;;
  esac
done
# Capture the while-subshell's status FIRST — the next command clobbers
# PIPESTATUS. [1] is the while; [0] would be curl.
WHILE_RC=${PIPESTATUS[1]:-0}
DURATION=$(( $(date +%s) - CONNECT_EPOCH ))

# Deploy failure (exit 3) is a genuine failure regardless of hold time: exit
# non-zero so the alert fires and the relay replays the retained event.
if [ "$WHILE_RC" -eq 3 ]; then
  echo "deploy failed; exiting non-zero for restart+replay+alert" >&2
  exit 1
fi

# Otherwise the stream ended (EOF). A healthy hold = the relay recycled the
# connection — exit 0, quiet reconnect. A near-instant end = relay
# unreachable/flapping — exit 1 so a sustained outage trips the alert.
if [ "$DURATION" -ge "$HEALTHY_MIN_SECS" ]; then
  echo "stream ended after ${DURATION}s (healthy hold; normal relay recycle) — quiet reconnect"
  exit 0
fi
echo "stream ended after only ${DURATION}s (relay unreachable/flapping) — failing for restart+alert" >&2
exit 1
