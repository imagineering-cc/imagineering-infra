#!/usr/bin/env bash
# Watcher template — co-locate with watched, two-phase, self-disabling.
#
# What this is:
#   A skeleton for "watch external state on owned infra, notify on transitions,
#   disable yourself when done." Copy this file, fill in the four FILL-IN
#   blocks, install a cron entry tagged with $CRON_TAG, and forget about it.
#
# Shape:
#   Phase A → poll until a *condition flips* → notify (🎉) → transition to B
#   Phase B → poll until a *target materializes* → notify (🚀) → self-disable
#   DONE    → no-op (cron entry should already be removed by self-disable)
#
#   For single-phase watchers (e.g. "alert when disk > 90%"), make
#   phase_b_check a one-liner that returns 0 immediately. The transition
#   A→B→DONE then collapses to "fire once and self-disable."
#
# State lives at:
#   ~/.config/imagineering/<WATCHER_NAME>.state    -- A | B | DONE
#   ~/.config/imagineering/<WATCHER_NAME>.start    -- epoch of first run
#   ~/<WATCHER_NAME>.log                           -- append-only run log
#
# See README.md in this directory for the design principles, the cron-entry
# shape, and a list of candidate watchers worth building from this template.

set -euo pipefail

# ============================================================================
# FILL-IN 1 — identity
# ============================================================================
WATCHER_NAME="example-watcher"   # used for state file names + log file name
CRON_TAG="example-watcher"       # MUST match the trailing comment on the
                                 # crontab entry, e.g.
                                 #   */15 * * * * /path/to/script  # example-watcher
                                 # self_disable() greps for this tag to
                                 # remove the line on success.

# ============================================================================
# FILL-IN 2 — paths (usually leave alone)
# ============================================================================
CONFIG_DIR="$HOME/.config/imagineering"
STATE_FILE="$CONFIG_DIR/$WATCHER_NAME.state"
START_FILE="$CONFIG_DIR/$WATCHER_NAME.start"
LOG_FILE="$HOME/$WATCHER_NAME.log"
CRED_FILE="$CONFIG_DIR/notify-credentials"   # exports NOTIFY_URL + NOTIFY_API_KEY

mkdir -p "$CONFIG_DIR"

# ============================================================================
# Helpers (don't edit unless you know why)
# ============================================================================
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# Source notify creds. Silent no-op if absent — log() still works.
# shellcheck source=/dev/null
[[ -r "$CRED_FILE" ]] && { set -a; . "$CRED_FILE"; set +a; }

# tg <html-message>
#   Fires a notification via notify.imagineering.cc. HTML parse mode by
#   default — escape <, >, & in dynamic content. Failures are logged but
#   never abort the watcher (a failed notify shouldn't flip cron's
#   exit code; the next cycle will retry).
tg() {
    local msg="$1"
    if [[ -z "${NOTIFY_URL:-}" || -z "${NOTIFY_API_KEY:-}" ]]; then
        log "tg: NOTIFY_URL/NOTIFY_API_KEY not set; skipping"
        return 0
    fi
    local payload
    payload=$(jq -n --arg m "$msg" '{message:$m, parse_mode:"HTML"}')
    local result
    if result=$(curl -sS --max-time 10 -X POST "${NOTIFY_URL}/send" \
            -H "Authorization: Bearer ${NOTIFY_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>&1); then
        log "tg: $(echo "$result" | jq -r '"ok=\(.ok) err=\(.description // "-")"' 2>/dev/null || echo "raw=$result")"
    else
        log "tg: curl failed: $result"
    fi
}

# self_disable
#   Removes any crontab line containing $CRON_TAG. Idempotent. Runs against
#   the invoking user's crontab — install the cron entry under the same
#   user that runs this script.
self_disable() {
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        log "self-disabled cron entry tagged: $CRON_TAG"
    else
        log "self_disable: no cron entry found for tag: $CRON_TAG (already removed?)"
    fi
}

# Record first-run epoch for elapsed-time reasoning in checks.
[[ -f "$START_FILE" ]] || date +%s > "$START_FILE"
START_EPOCH=$(cat "$START_FILE")
NOW_EPOCH=$(date +%s)
ELAPSED_HOURS=$(( (NOW_EPOCH - START_EPOCH) / 3600 ))
export ELAPSED_HOURS  # available inside phase_*_check

# ============================================================================
# FILL-IN 3 — phase_a_check: detect "condition flipped"
# ============================================================================
# Contract:
#   return 0  → condition met. Caller transitions to phase B.
#               You SHOULD have called `tg "..."` before returning 0.
#   return 1  → still waiting. Caller exits cleanly; cron retries next cycle.
#   return 2  → transient error (e.g. API timeout). Caller exits cleanly.
#               Use this when you can't tell yet whether the condition is met.
#
# Available globals: $ELAPSED_HOURS, $LOG_FILE, log(), tg().
#
# Optional pattern: 24h heartbeat warning. If your watch may run for days,
# fire a one-shot warning at 24h to flag stuck watchers. Example commented
# at the bottom of this template.
phase_a_check() {
    log "phase_a_check: replace me"
    return 1
}

# ============================================================================
# FILL-IN 4 — phase_b_check: detect "target materialized"
# ============================================================================
# Same contract as phase_a_check. On return 0, the caller notifies (you've
# already called tg in your function), then self-disables cron.
#
# For single-phase watchers, just `return 0` here — A success will fall
# straight through to self-disable on the next cron cycle.
phase_b_check() {
    log "phase_b_check: replace me"
    return 1
}

# ============================================================================
# State machine (don't edit)
# ============================================================================
PHASE=$(cat "$STATE_FILE" 2>/dev/null || echo "A")

case "$PHASE" in
    A)
        log "phase=A"
        rc=0
        phase_a_check || rc=$?
        case "$rc" in
            0) echo "B" > "$STATE_FILE"; log "A → B" ;;
            1) ;;  # still waiting
            2) ;;  # transient error, logged by check
            *) log "phase_a_check returned unexpected rc=$rc; treating as waiting" ;;
        esac
        ;;
    B)
        log "phase=B"
        rc=0
        phase_b_check || rc=$?
        case "$rc" in
            0) echo "DONE" > "$STATE_FILE"; self_disable; log "B → DONE" ;;
            1) ;;
            2) ;;
            *) log "phase_b_check returned unexpected rc=$rc; treating as waiting" ;;
        esac
        ;;
    DONE)
        log "phase=DONE; cron entry should be removed (running anyway means self_disable failed earlier)"
        self_disable  # idempotent retry
        ;;
    *)
        log "unknown phase=$PHASE; resetting to A"
        echo "A" > "$STATE_FILE"
        ;;
esac

# ============================================================================
# Optional: 24h heartbeat warning (paste into phase_a_check if your watch
# may run for days — useful when "condition X" might silently never fire).
# ============================================================================
# WARN_FILE="$CONFIG_DIR/$WATCHER_NAME.warned-24h"
# if [[ "$ELAPSED_HOURS" -ge 24 && ! -f "$WARN_FILE" ]]; then
#     tg "⚠️ <b>$WATCHER_NAME</b>: 24h elapsed, condition still not met. Investigate?"
#     touch "$WARN_FILE"
# fi
