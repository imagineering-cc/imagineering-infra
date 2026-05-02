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
# FILL-IN 1 — identity (must come BEFORE sourcing the lib)
# ============================================================================
# shellcheck disable=SC2034  # both consumed by watcher-base.sh after sourcing
WATCHER_NAME="CHANGE_ME"         # used for state file names + log file name
# shellcheck disable=SC2034
CRON_TAG="CHANGE_ME"             # MUST match the trailing comment on the
                                 # crontab entry, e.g.
                                 #   */15 * * * * /path/to/script  # cert-expiry-watch
                                 # self_disable() greps for this tag.

# ============================================================================
# Source shared lib — provides log(), tg(), self_disable(), run_watcher(),
# and sets CONFIG_DIR / STATE_FILE / LOG_FILE / ELAPSED_HOURS.
# ============================================================================
__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090  # dynamic path; resolved at runtime
source "$__lib"
unset __lib
# (First path resolves when running from the repo checkout; second path
# resolves on Sydney when the lib is deployed alongside the watcher.)

# ============================================================================
# FILL-IN 2 — phase_a_check: detect "condition flipped"
# ============================================================================
# Contract:
#   return 0  → condition met. Caller transitions to phase B.
#               You SHOULD have called `tg "..."` before returning 0.
#   return 1  → still waiting. Cron retries next cycle.
#   return 2  → transient error (e.g. API timeout). Cron retries next cycle.
#
# Available globals: $ELAPSED_HOURS, $LOG_FILE, $CONFIG_DIR; functions log(), tg().
phase_a_check() {
    log "phase_a_check: replace me"
    return 1
}

# ============================================================================
# FILL-IN 3 — phase_b_check: detect "target materialized"
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
# Run the state machine (don't edit)
# ============================================================================
run_watcher

# ============================================================================
# Optional: 24h heartbeat warning (paste into phase_a_check if your watch
# may run for days — useful when "condition X" might silently never fire).
# ============================================================================
# WARN_FILE="$CONFIG_DIR/$WATCHER_NAME.warned-24h"
# if [[ "$ELAPSED_HOURS" -ge 24 && ! -f "$WARN_FILE" ]]; then
#     # Plain text — no HTML interpolation of $WATCHER_NAME, since names
#     # may contain characters that would need escaping for parse_mode=HTML.
#     tg "⚠️ $WATCHER_NAME: 24h elapsed, condition still not met. Investigate?"
#     touch "$WARN_FILE"
# fi
