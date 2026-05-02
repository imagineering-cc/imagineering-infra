#!/usr/bin/env bash
# Watcher base library — shared helpers + state machine for cron-on-Sydney
# watchers. Source this from each watcher; provides:
#
#   ts()           – ISO8601 UTC timestamp
#   log <msg>      – append timestamped line to $LOG_FILE
#   tg <html-msg>  – fire HTML-mode notification via notify.imagineering.cc
#   self_disable   – remove this watcher's crontab entry (idempotent)
#   run_watcher    – execute the two-phase state machine, dispatching to
#                    phase_a_check / phase_b_check that the watcher defines
#
# Required globals (the watcher must set BEFORE sourcing):
#   WATCHER_NAME   – used for state + log file names
#   CRON_TAG       – trailing comment on the crontab entry to grep for
#
# Provided globals (set by this lib after init):
#   CONFIG_DIR, STATE_FILE, START_FILE, LOG_FILE, CRED_FILE, ELAPSED_HOURS
#
# Conventions:
#   - Watchers run as the user that owns the cron entry (typically `ubuntu`
#     on Sydney). All paths default to that user's $HOME.
#   - Notifications fail silently (logged, never abort the run).
#   - Transient errors should `return 2` from a phase check; the run still
#     exits 0 so cron doesn't treat it as a failure.

set -euo pipefail

# ---------------------------------------------------------------------------
# Init — runs at source-time. The watcher must have set WATCHER_NAME by now.
# ---------------------------------------------------------------------------
: "${WATCHER_NAME:?watcher must set WATCHER_NAME before sourcing watcher-base.sh}"
: "${CRON_TAG:?watcher must set CRON_TAG before sourcing watcher-base.sh}"

CONFIG_DIR="$HOME/.config/imagineering"
STATE_FILE="$CONFIG_DIR/$WATCHER_NAME.state"
START_FILE="$CONFIG_DIR/$WATCHER_NAME.start"
LOG_FILE="$HOME/$WATCHER_NAME.log"
CRED_FILE="$CONFIG_DIR/notify-credentials"

mkdir -p "$CONFIG_DIR"

# Source notify creds if present. Silent no-op if absent — log() still works.
# shellcheck source=/dev/null
[[ -r "$CRED_FILE" ]] && { set -a; . "$CRED_FILE"; set +a; }

# Record first-run epoch for elapsed-time reasoning in checks.
[[ -f "$START_FILE" ]] || date +%s > "$START_FILE"
__START_EPOCH=$(cat "$START_FILE")
__NOW_EPOCH=$(date +%s)
# shellcheck disable=SC2034  # consumed by watcher's phase_*_check functions
ELAPSED_HOURS=$(( (__NOW_EPOCH - __START_EPOCH) / 3600 ))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# tg <html-message>
#   Fires a notification via notify.imagineering.cc. HTML parse mode by
#   default — caller is responsible for escaping <, >, & in dynamic text.
#   Set DRY_RUN=1 to log the message instead of POSTing — useful while
#   developing/smoke-testing a watcher to avoid Telegram noise.
tg() {
    local msg="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "tg [DRY_RUN]: ${msg//$'\n'/ }"
        return 0
    fi
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
#   Removes any crontab line containing $CRON_TAG (the trailing-comment tag).
#   Idempotent. Operates on the invoking user's crontab.
self_disable() {
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        log "self-disabled cron entry tagged: $CRON_TAG"
    else
        log "self_disable: no cron entry found for tag: $CRON_TAG (already removed?)"
    fi
}

# run_watcher
#   Drives the two-phase state machine. Calls phase_a_check / phase_b_check
#   that the watcher script defines. Phase functions follow this contract:
#     return 0  → condition met (caller should already have called tg)
#                 → state transitions A→B or B→DONE+self-disable
#     return 1  → still waiting; cron retries next cycle
#     return 2  → transient error (logged); cron retries next cycle
run_watcher() {
    local phase rc
    phase=$(cat "$STATE_FILE" 2>/dev/null || echo "A")

    case "$phase" in
        A)
            log "phase=A"
            rc=0
            phase_a_check || rc=$?
            case "$rc" in
                0) echo "B" > "$STATE_FILE"; log "A → B" ;;
                1) ;;
                2) ;;
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
            self_disable
            ;;
        *)
            log "unknown phase=$phase; resetting to A"
            echo "A" > "$STATE_FILE"
            ;;
    esac
}
