#!/usr/bin/env bash
# Disk-usage watcher for the Sydney box.
#
# Phase A: root partition crosses 85% — fire 🚨 with top dirs (actionable info).
# Phase B: root partition climbs past 95% — fire one extra 🚨🚨 (gated by warn file);
#          drops below 75% — fire ✅, self-disable.
#
# Hysteresis gap (85→75) prevents flap if usage hovers around the threshold.
#
# Cron: */30 * * * * /home/ubuntu/disk-usage-watch.sh  # disk-usage-watch

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="disk-usage-watch"
# shellcheck disable=SC2034
CRON_TAG="disk-usage-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090  # dynamic path; resolved at runtime
source "$__lib"
unset __lib

__diag="$(dirname "$0")/lib/diagnose.sh"
[[ -r "$__diag" ]] || __diag="$HOME/lib/diagnose.sh"
# shellcheck disable=SC1090
source "$__diag"
unset __diag

# Watcher-specific helpers
root_usage_pct() { df / | awk 'NR==2 { gsub("%",""); print $5 }'; }
top_dirs() {
    du -sh /var/log/* /home/* /tmp/* /var/lib/* /opt/* 2>/dev/null | sort -rh | head -5
}
# Top single files anywhere ubuntu can read — adds a "what one file is
# eating the disk" view that top_dirs (sums) can hide. Largest offenders
# are typically log files, journal segments, or stray downloads.
top_single_files() {
    {
        top_files /var/log 5
        top_files /tmp 5
        top_files /home 5
    } | sort -rh -k1,1 | head -5
}

# Warn-file for the "still climbing" tier in Phase B. Gates the second-fire
# so we alert at most once per cycle even if disk hovers in the 95+ band.
WARN_95_FILE="$CONFIG_DIR/$WATCHER_NAME.warned-95"

phase_a_check() {
    local usage
    usage=$(root_usage_pct)
    log "phase_a: usage=${usage}%"
    if [[ "$usage" -ge 85 ]]; then
        local dirs files
        dirs=$(top_dirs)
        files=$(top_single_files)
        local msg
        msg=$(printf '🚨 <b>Sydney disk at %s%%</b>\n\nTop directories visible to %s:\n<pre>%s</pre>\nLargest single files:\n<pre>%s</pre>\n<i>Watcher will notify again on recovery (&lt;75%%) and self-disable.</i>' \
              "$usage" "${USER:-unknown}" "$dirs" "$files")
        tg "$msg"
        return 0
    fi
    return 1
}

phase_b_check() {
    local usage
    usage=$(root_usage_pct)
    log "phase_b: usage=${usage}%"

    # Climbing past the critical band — second-tier alert, fired at most once
    # per watcher lifetime (gated by WARN_95_FILE).
    if [[ "$usage" -ge 95 && ! -f "$WARN_95_FILE" ]]; then
        local dirs
        dirs=$(top_dirs)
        local msg
        msg=$(printf '🚨🚨 <b>Sydney disk CRITICAL: %s%%</b> (climbing past initial alert)\n\n<pre>%s</pre>' \
              "$usage" "$dirs")
        tg "$msg"
        touch "$WARN_95_FILE"
        # Don't return 0 — that would self-disable. Continue polling for recovery below.
    fi

    if [[ "$usage" -lt 75 ]]; then
        tg "✅ <b>Sydney disk recovered:</b> ${usage}% — ${WATCHER_NAME} self-disabling. Re-install if you want continued coverage."
        return 0
    fi
    return 1
}

run_watcher
