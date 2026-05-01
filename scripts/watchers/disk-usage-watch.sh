#!/usr/bin/env bash
# Disk-usage watcher for the Sydney box.
#
# Phase A: root partition crosses 85% — fire 🚨 with top dirs (actionable info).
# Phase B: root partition drops below 75% — fire ✅, self-disable.
#
# Hysteresis gap (85→75) prevents flap if usage hovers around the threshold.
#
# Cron: */30 * * * * /home/ubuntu/disk-usage-watch.sh  # disk-usage-watch
# Built from scripts/watchers/template.sh; first real consumer of the template.

set -euo pipefail

# ============================================================================
# FILL-IN 1 — identity
# ============================================================================
WATCHER_NAME="disk-usage-watch"
CRON_TAG="disk-usage-watch"

# ============================================================================
# FILL-IN 2 — paths
# ============================================================================
CONFIG_DIR="$HOME/.config/imagineering"
STATE_FILE="$CONFIG_DIR/$WATCHER_NAME.state"
START_FILE="$CONFIG_DIR/$WATCHER_NAME.start"
LOG_FILE="$HOME/$WATCHER_NAME.log"
CRED_FILE="$CONFIG_DIR/notify-credentials"

mkdir -p "$CONFIG_DIR"

# ============================================================================
# Helpers
# ============================================================================
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

# shellcheck source=/dev/null
[[ -r "$CRED_FILE" ]] && { set -a; . "$CRED_FILE"; set +a; }

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

self_disable() {
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        log "self-disabled cron entry tagged: $CRON_TAG"
    else
        log "self_disable: no cron entry found for tag: $CRON_TAG (already removed?)"
    fi
}

[[ -f "$START_FILE" ]] || date +%s > "$START_FILE"

# Read current root partition usage as integer percent (no % sign).
root_usage_pct() {
    df / | awk 'NR==2 { gsub("%",""); print $5 }'
}

# Top-5 largest directories the calling user can read. /var/lib/* often needs
# sudo to fully descend; the 2>/dev/null swallows perm denials so the alert
# still surfaces what's visible. Acceptable: even a partial top-5 tells you
# where to look first.
top_dirs() {
    du -sh /var/log/* /home/* /tmp/* /var/lib/* 2>/dev/null | sort -rh | head -5
}

# ============================================================================
# FILL-IN 3 — phase_a_check: disk crossed 85%
# ============================================================================
phase_a_check() {
    local usage
    usage=$(root_usage_pct)
    log "phase_a: usage=${usage}%"
    if [[ "$usage" -ge 85 ]]; then
        local dirs
        dirs=$(top_dirs)
        local msg
        # <pre> preserves the column alignment from `du -sh | sort -rh`.
        # System paths in /var/log etc. don't contain HTML-meaningful chars,
        # so no escaping needed for the dynamic content.
        msg=$(printf '🚨 <b>Sydney disk at %s%%</b>\n\nTop directories visible to %s:\n<pre>%s</pre>\n\n<i>Watcher will notify again on recovery (&lt;75%%) and self-disable.</i>' \
              "$usage" "${USER:-unknown}" "$dirs")
        tg "$msg"
        return 0
    fi
    return 1
}

# ============================================================================
# FILL-IN 4 — phase_b_check: disk recovered below 75%
# ============================================================================
phase_b_check() {
    local usage
    usage=$(root_usage_pct)
    log "phase_b: usage=${usage}%"
    if [[ "$usage" -lt 75 ]]; then
        tg "✅ <b>Sydney disk recovered:</b> ${usage}% — disk-usage-watch self-disabling. Re-install if you want continued coverage."
        return 0
    fi
    return 1
}

# ============================================================================
# State machine
# ============================================================================
PHASE=$(cat "$STATE_FILE" 2>/dev/null || echo "A")

case "$PHASE" in
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
        log "phase=DONE; cron entry should be removed"
        self_disable
        ;;
    *)
        log "unknown phase=$PHASE; resetting to A"
        echo "A" > "$STATE_FILE"
        ;;
esac
