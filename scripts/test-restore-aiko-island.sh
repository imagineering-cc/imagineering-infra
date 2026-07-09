#!/bin/bash
# Real restore test for the aiko-chat-island DB (aiko_chat_gateway#1759).
#
# WHY THIS EXISTS: we could back up the island but had NEVER proven we could
# restore it. Worse, restore.sh hardcoded the pre-cutover volume name — so on
# Sydney a restore would have silently written into an ORPHANED ghost volume
# the live island never mounts, reporting "restore complete!" while the live DB
# stayed empty. "The file exists" is exactly the lie that bit us; this test
# asserts CONTENT (passkey rows the live volume actually holds), not presence.
#
# It drives the REAL restore code — it sources restore.sh (RESTORE_LIB_ONLY=1)
# and calls _restore_island_core + the aiko_island_* discovery lib, against a
# throwaway container + temp volumes. No copy of the logic, so it can't rot out
# of sync with production.
#
# Three assertions:
#   [1] DISCOVERY  — aiko_island_volume() resolves the volume the LIVE container
#                    mounts, never the ghost. This is the exact bug's root.
#   [2] GHOST/RED  — restoring into the ghost volume (old hardcoded behaviour)
#                    leaves the LIVE volume with 0 passkeys: data silently lost.
#   [3] CONTENT    — restoring into the DISCOVERED volume gives the live volume
#                    the passkey row, and the container is running again.
#
# REQUIRE_ALL=1 (set by CI) turns a missing docker into a hard failure rather
# than a vacuous skip, so CI can't go green with the test silently not running.
#
# Exit non-zero on any failure.

set -uo pipefail

REQUIRE_ALL=${REQUIRE_ALL:-0}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ "$REQUIRE_ALL" = "1" ]; then
    echo "  FAIL - docker unavailable (REQUIRE_ALL set — must be present in CI)"
    exit 1
  fi
  echo "  skip - docker unavailable; skipping restore test (set REQUIRE_ALL=1 to force)"
  exit 0
fi

# --- Unique, self-cleaning fixtures -----------------------------------------
SUFFIX="$$-$(date +%s)"
IMG="aiko-chat-island:resttest-$SUFFIX"     # image prefix must match discovery
CTR="aiko-island-resttest-$SUFFIX"
VOL_LIVE="aiko-resttest-live-$SUFFIX"       # the volume the container mounts
VOL_GHOST="aiko-resttest-ghost-$SUFFIX"     # the orphaned pre-cutover name
WORK="$(mktemp -d)"

cleanup() {
  docker rm -f "$CTR" >/dev/null 2>&1 || true
  docker volume rm -f "$VOL_LIVE" "$VOL_GHOST" >/dev/null 2>&1 || true
  docker image rm -f "$IMG" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# alpine+sqlite helper for asserting content inside a volume (built by the
# restore path too; build here so assertions work even if it hasn't run yet).
if ! docker image inspect sqlite-dumper:latest >/dev/null 2>&1; then
  printf 'FROM alpine:3.20\nRUN apk add --no-cache sqlite\n' \
    | docker build -q -t sqlite-dumper:latest - >/dev/null
fi

# A throwaway "island" image whose tag matches the discovery regex
# (^aiko-chat-(island|gateway):). It just sleeps — the restore only needs it
# running so discovery can inspect its /data mount and stop/start it.
docker build -q -t "$IMG" - >/dev/null <<'DOCKERFILE'
FROM alpine:3.20
CMD ["sleep", "3600"]
DOCKERFILE

docker volume create "$VOL_LIVE" >/dev/null
docker volume create "$VOL_GHOST" >/dev/null
docker run -d --name "$CTR" -v "$VOL_LIVE:/data" "$IMG" >/dev/null

# A COMPLETE sqlite .dump (ends in COMMIT;) with a users row + one
# passkey_credentials row — the content restore must land in the live volume.
DUMP="$WORK/aiko-island.sql"
cat > "$DUMP" <<'SQL'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT);
INSERT INTO users VALUES ('u_test','test@example.com');
CREATE TABLE passkey_credentials (
  id TEXT PRIMARY KEY, credential_id TEXT UNIQUE NOT NULL,
  user_id TEXT NOT NULL, public_key TEXT NOT NULL,
  sign_count INTEGER NOT NULL DEFAULT 0);
INSERT INTO passkey_credentials VALUES ('pk_1','cred_abc','u_test','cose_pub',0);
COMMIT;
SQL

# passkey_count <volume> — echoes the passkey_credentials row count in that
# volume's aiko.db, or 0 if the DB doesn't exist yet. This is the CONTENT probe:
# presence lied to us, so every assertion goes through real rows.
passkey_count() {
  docker run --rm -v "$1:/data:ro" sqlite-dumper:latest sh -c '
    [ -f /data/aiko.db ] || { echo 0; exit 0; }
    sqlite3 /data/aiko.db "SELECT count(*) FROM passkey_credentials;" 2>/dev/null || echo 0'
}

# cred_id <volume> — the credential_id of the (single) restored row, or "" if the
# DB/row is absent. Asserting the exact identity (not just count>0) is what makes
# the content check falsifiable: a stale row or a wrong dump can't sneak past.
cred_id() {
  docker run --rm -v "$1:/data:ro" sqlite-dumper:latest sh -c '
    [ -f /data/aiko.db ] || { echo ""; exit 0; }
    sqlite3 /data/aiko.db "SELECT credential_id FROM passkey_credentials LIMIT 1;" 2>/dev/null || echo ""'
}

# --- Source the REAL restore code (functions only, no dispatch) -------------
# shellcheck source=restore.sh disable=SC1091
RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh"
set +e   # restore.sh sets -e; we drive control flow explicitly from here.

echo "[1] discovery resolves the LIVE volume, not the ghost"
CID="$(aiko_island_container)"
VOL="$(aiko_island_volume "$CID")"
if [ "$CID" = "$CTR" ]; then ok "container discovered ($CID)"; else bad "discovered '$CID', expected '$CTR'"; fi
if [ "$VOL" = "$VOL_LIVE" ]; then ok "volume resolves to the mounted live volume"; else bad "resolved '$VOL', expected '$VOL_LIVE'"; fi
if [ "$VOL" != "$VOL_GHOST" ]; then ok "discovery never returns the ghost volume"; else bad "discovery returned the ghost volume"; fi

echo "[2] RED: restoring into the ghost volume loses data (the #1759 bug)"
# This is the pre-fix behaviour: install into the hardcoded ghost name. To make
# the RED assertion a real falsifier (not a vacuous one), we must prove the write
# ACTUALLY happened to the ghost — a no-op or a failed install would ALSO leave
# the live volume empty and would otherwise pass. So assert all three:
#   (a) the restore itself succeeded, (b) the GHOST volume received the row,
#   (c) the LIVE volume the island reads stayed empty (the silent data loss).
if _restore_island_core "$DUMP" "$CID" "$VOL_GHOST" >/dev/null 2>&1; then
  ok "ghost restore ran and succeeded (the pre-fix path executed)"
else
  bad "ghost restore itself failed — can't prove data-loss, RED would be vacuous"
fi
GHOST_AFTER="$(passkey_count "$VOL_GHOST")"
LIVE_AFTER_GHOST="$(passkey_count "$VOL_LIVE")"
if [ "$GHOST_AFTER" -gt 0 ]; then
  ok "ghost volume received the write (count=$GHOST_AFTER) — the write really landed somewhere"
else
  bad "ghost volume has 0 passkeys — restore was a no-op, so the RED assertion proves nothing"
fi
if [ "$LIVE_AFTER_GHOST" -eq 0 ]; then
  ok "live volume left empty by ghost restore (the silent data loss the bug caused)"
else
  bad "expected 0 passkeys in live volume after ghost restore, got $LIVE_AFTER_GHOST"
fi

echo "[3] CONTENT: restoring into the DISCOVERED volume lands the EXACT rows live"
_restore_island_core "$DUMP" "$CID" "$VOL"
CORE_RC=$?
LIVE_AFTER="$(passkey_count "$VOL_LIVE")"
LIVE_CRED="$(cred_id "$VOL_LIVE")"
if [ "$CORE_RC" -eq 0 ]; then ok "_restore_island_core succeeded"; else bad "_restore_island_core returned $CORE_RC"; fi
# Exact count, not >0: a stale/duplicate/wrong-dump row must not sneak past.
if [ "$LIVE_AFTER" = "1" ]; then
  ok "live volume holds exactly the one restored row (count=1)"
else
  bad "expected exactly 1 passkey in live volume, got $LIVE_AFTER"
fi
# Exact identity: proves it's OUR dump's row, not just any passkey row.
if [ "$LIVE_CRED" = "cred_abc" ]; then
  ok "restored row identity matches the dump (credential_id=cred_abc)"
else
  bad "expected credential_id 'cred_abc' in live volume, got '$LIVE_CRED'"
fi
# The fix restarts via `docker start <cid>` — the container must be up again.
if [ "$(docker inspect -f '{{.State.Running}}' "$CTR" 2>/dev/null)" = "true" ]; then
  ok "island container is running again after restore"
else
  bad "island container is not running after restore (docker start failed)"
fi

echo ""
echo "restore test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
