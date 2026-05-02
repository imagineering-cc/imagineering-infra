#!/usr/bin/env bash
# Kanbn upstream release watcher (single-phase).
#
# Phase A: a new release tag has appeared on github.com/kanbn/kan since the
#          baseline we recorded → 🚨, link the release. Single-phase: after
#          alerting, immediately self-disables. Re-install if you want to
#          watch for the *next* release.
#
# Background: we patched a missing migration manually for
# `card_activity.attachmentId` (CLAUDE.md → kanbn → Migration Issue).
# When upstream ships a release that includes that fix, we can drop our
# workaround. This watcher catches "new release shipped, go check."
#
# CAVEAT: first run silently records the *current* latest tag as baseline.
# This watcher only catches *future* releases — releases that already
# shipped before deploy are missed. Deploy promptly after creating, or
# pre-seed $BASELINE_FILE with an older tag if you want to be alerted
# about a release that already happened.
#
# Cron: 41 7 * * * /home/ubuntu/kanbn-upstream-watch.sh  # kanbn-upstream-watch
# (Once daily, off the hour. Releases land infrequently.)

set -euo pipefail

# shellcheck disable=SC2034
WATCHER_NAME="kanbn-upstream-watch"
# shellcheck disable=SC2034
CRON_TAG="kanbn-upstream-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

REPO="kanbn/kan"
BASELINE_FILE="$CONFIG_DIR/$WATCHER_NAME.baseline"

# Returns the most recent tag name from kanbn/kan, or "" on error.
# Uses the tags endpoint rather than releases/latest because kanbn/kan
# publishes tags but doesn't always cut formal GitHub Releases.
latest_release_tag() {
    curl -sS --max-time 10 "https://api.github.com/repos/$REPO/tags?per_page=1" 2>/dev/null \
        | jq -r '.[0].name // ""' 2>/dev/null
}

phase_a_check() {
    local current
    current=$(latest_release_tag)
    if [[ -z "$current" ]]; then
        log "phase_a: GitHub API returned no tag (rate limited? network?)"
        return 2
    fi

    # First run: record baseline silently and wait for changes.
    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "$current" > "$BASELINE_FILE"
        log "phase_a: baseline recorded as $current"
        return 1
    fi

    local baseline
    baseline=$(cat "$BASELINE_FILE")
    log "phase_a: current=$current baseline=$baseline"

    if [[ "$current" != "$baseline" ]]; then
        tg "$(printf '🆕 <b>kanbn/kan released %s</b> (was %s)\n\n<a href="https://github.com/%s/releases/tag/%s">Release notes</a>\n\nCheck if it includes the <code>card_activity.attachmentId</code> migration — if so, we can drop our manual patch.' \
              "$current" "$baseline" "$REPO" "$current")"
        echo "$current" > "$BASELINE_FILE"
        return 0
    fi
    return 1
}

# Single-phase: after Phase A fires, immediately collapse to DONE.
phase_b_check() { return 0; }

run_watcher
