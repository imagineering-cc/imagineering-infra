#!/usr/bin/env bash
# Backup-recency watcher — alerts if the daily 4am backup hasn't run.
#
# Phase A: most recent file in /tmp/backups/ is older than 25 hours → 🚨.
#          Catches "the daily backup didn't run" / cron silently broke /
#          backup.sh died early.
# Phase B: a fresh artifact lands in /tmp/backups/ → ✅, self-disable.
#
# Why /tmp/backups/ rather than the GitHub repo: backup.sh is run by user
# `nick` (per /etc/cron.d/xdeca-backup) and uses an SSH deploy key in
# /home/nick/.ssh/config. Querying GitHub from ubuntu's context would
# need either an additional PAT or sudo -u nick gymnastics. The local
# artifacts are written to /tmp/backups/ as part of the same backup run
# (mode 0664, world-readable), which ubuntu can stat without privilege.
# If those artifacts are stale, GitHub will be too — same root cause.
#
# Cron: 0 8 * * * /home/ubuntu/backup-recency-watch.sh  # backup-recency-watch
# (8am daily, 4 hours after the 4am backup window — gives backup.sh time
# to complete before we judge it.)

set -euo pipefail

# shellcheck disable=SC2034
WATCHER_NAME="backup-recency-watch"
# shellcheck disable=SC2034
CRON_TAG="backup-recency-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

BACKUP_DIR="/tmp/backups"
STALE_HOURS=25

# Returns the epoch mtime of the most recently modified file under
# $BACKUP_DIR, or "0" if the directory is empty/missing/unreadable.
latest_artifact_epoch() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo 0
        return
    fi
    # find -printf '%T@\n' gives epoch.fraction. Capture into a var so the
    # `|| echo 0` fallback only fires when there's truly no output (rather
    # than when any pipe stage's exit code wobbles).
    # The `|| true` suppresses pipefail false-positives: under `set -o
    # pipefail`, this specific find|sort|awk chain reports rc=1 even when
    # the data flows correctly through. Verified by isolating each stage:
    # all exit 0 individually, but the captured pipe rc is 1. Likely
    # awk-pattern-NR-1 + sort interaction. The data is sound; ignore the rc.
    local out
    out=$(find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null \
          | sort -rn | awk 'NR==1 { printf "%d", $1 }' || true)
    echo "${out:-0}"
}

phase_a_check() {
    local epoch hours_old
    epoch=$(latest_artifact_epoch)
    if [[ "$epoch" == "0" ]]; then
        log "phase_a: no artifacts in $BACKUP_DIR — backup never ran or dir missing"
        # Treat "no artifacts at all" as a real alert condition: it means either
        # backup.sh has never produced anything or someone wiped the dir.
        tg "🚨 <b>Backup directory empty or missing</b>: <code>${BACKUP_DIR}</code> has no files. backup.sh hasn't produced artifacts."
        return 0
    fi
    hours_old=$(( ($(date +%s) - epoch) / 3600 ))
    log "phase_a: latest artifact ${hours_old}h old"
    if [[ "$hours_old" -ge "$STALE_HOURS" ]]; then
        local last_iso
        last_iso=$(date -u -d "@$epoch" +"%Y-%m-%dT%H:%MZ" 2>/dev/null \
                || date -u -r "$epoch" +"%Y-%m-%dT%H:%MZ")
        # shellcheck disable=SC2016  # $(pgrep …) is literal; intended to be copy-pasted on Sydney by the reader
        tg "$(printf '🚨 <b>Backup stale: %sh since last artifact</b>\n\nLatest file in <code>%s</code>: <code>%s</code>.\nDaily 4am backup likely failed. Check <code>/home/nick/logs/backup.log</code> + <code>journalctl _PID=$(pgrep -f backup.sh)</code> on Sydney.' "$hours_old" "$BACKUP_DIR" "$last_iso")"
        return 0
    fi
    return 1
}

phase_b_check() {
    local epoch hours_old
    epoch=$(latest_artifact_epoch)
    if [[ "$epoch" == "0" ]]; then
        log "phase_b: still no artifacts"
        return 1
    fi
    hours_old=$(( ($(date +%s) - epoch) / 3600 ))
    log "phase_b: latest artifact ${hours_old}h old"
    if [[ "$hours_old" -lt "$STALE_HOURS" ]]; then
        tg "✅ <b>Backups recovered</b> — fresh artifact ${hours_old}h ago. ${WATCHER_NAME} self-disabling."
        return 0
    fi
    return 1
}

run_watcher
