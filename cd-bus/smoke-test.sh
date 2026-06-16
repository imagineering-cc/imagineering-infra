#!/bin/bash
# Smoke test for the CD Bus relay. Run against a local `wrangler dev`
# (default http://localhost:8787) or a deployed URL via BASE=...
#
#   Terminal A:  wrangler dev
#   Terminal B:  ./smoke-test.sh
#
# Covers: health, auth rejection, live fan-out (subscribe-then-publish),
# and replay-on-connect (publish-then-subscribe gets the retained event).
set -uo pipefail

BASE="${BASE:-http://localhost:8787}"
TOKEN="${PUBLISH_TOKEN:-dev-local-token}"
# Subscribe auth is enforced by the worker ONLY when SUBSCRIBE_TOKEN is bound.
# Mirror that here: when SUBSCRIBE_TOKEN is set in the env, send it on /events
# requests (and assert unauthenticated reads are rejected); when unset, /events
# is public (pilot mode) and the auth checks below are skipped.
SUB_TOKEN="${SUBSCRIBE_TOKEN:-}"
sub_auth=()
[ -n "$SUB_TOKEN" ] && sub_auth=(-H "authorization: Bearer $SUB_TOKEN")
SVC="smoke-$$"
pass=0; fail=0
ok(){ echo "  ✓ $1"; pass=$((pass+1)); }
no(){ echo "  ✗ $1"; fail=$((fail+1)); }

echo "== CD Bus smoke test against $BASE (service=$SVC) =="

# 1. health
[ "$(curl -fsS "$BASE/health" | jq -r .ok)" = "true" ] && ok "health" || no "health"

# 2. auth: publish without the token must be rejected
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/publish" \
  -H 'content-type: application/json' -d "{\"service\":\"$SVC\"}")
[ "$code" = "401" ] && ok "unauthorized publish rejected (401)" || no "auth: got $code, want 401"

# 2b. service grammar: a service name that can't be subscribed to must be
# rejected at publish time (no events into unreachable channels).
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/publish" \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"service":"bad/name"}')
[ "$code" = "400" ] && ok "malformed service name rejected (400)" || no "service grammar: got $code, want 400"

# 2c. subscribe auth (only meaningful when SUBSCRIBE_TOKEN is bound): an
# unauthenticated /events read must be rejected with 401.
if [ -n "$SUB_TOKEN" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$BASE/events/$SVC")
  [ "$code" = "401" ] && ok "unauthorized subscribe rejected (401)" || no "subscribe auth: got $code, want 401"
fi

# 3. live fan-out: subscribe in the background, then publish, expect the event
sse_out=$(mktemp)
( curl -sN --max-time 4 "${sub_auth[@]+"${sub_auth[@]}"}" "$BASE/events/$SVC" > "$sse_out" ) &
sub_pid=$!
sleep 1   # let the subscription establish
curl -fsS -X POST "$BASE/publish" \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d "{\"event\":\"image.published\",\"service\":\"$SVC\",\"digest\":\"sha256:live\"}" >/dev/null
wait $sub_pid 2>/dev/null
grep -q '"digest":"sha256:live"' "$sse_out" && ok "live fan-out delivered" || { no "live fan-out"; echo "    --- got: ---"; sed 's/^/    /' "$sse_out"; }

# 4. replay-on-connect: a NEW subscriber gets the last retained event immediately
replay_out=$(mktemp)
curl -sN --max-time 3 "${sub_auth[@]+"${sub_auth[@]}"}" "$BASE/events/$SVC" > "$replay_out" &
wait $! 2>/dev/null
grep -q '"digest":"sha256:live"' "$replay_out" && ok "replay-on-connect delivered retained event" || { no "replay-on-connect"; echo "    --- got: ---"; sed 's/^/    /' "$replay_out"; }

rm -f "$sse_out" "$replay_out"
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
