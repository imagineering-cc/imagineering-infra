#!/usr/bin/env bash
# Email-health watcher — catches silent Brevo transactional-email failures.
#
# WHY THIS EXISTS (2026-06-20 incident):
#   imagineering.cc transactional email (Outline password resets, Kan magic
#   links/invites, contact-form lead notifications) was silently dead for
#   days. Root cause: the Brevo sending domain `imagineering.cc` was never
#   authenticated, so Brevo accepted every send at SMTP (250 queued) then
#   rejected it at processing ("sender noreply@imagineering.cc is not
#   valid"). The 250-OK made every app think email worked — NO alert fired.
#   This watcher catches that class of silent failure going forward.
#
# RECURRING, NOT SELF-DISABLING. Unlike the two-phase template watchers
# (which wait for a transition then remove their own cron entry), this is a
# permanent threshold monitor — modelled on disk-usage-watch.sh. phase_a_check
# runs all three checks every cycle and ALWAYS returns 1, so run_watcher never
# transitions A→B and never self-disables. phase_b_check is a no-op safety net.
#
# THREE CHECKS (alert on any failing):
#   1. DOMAIN AUTH  — GET /v3/senders/domains: each required domain must be
#                     present with authenticated:true AND verified:true; any
#                     domain missing / not-authenticated / not-verified fails.
#                     THIS is the check that would have caught the incident.
#   2. DAILY VOLUME — GET /v3/smtp/statistics/aggregatedReport?days=1 .requests
#                     vs the daily cap. Alert at >= WARN_PCT% of CAP — early
#                     warning before a flood exhausts the shared cap and starves
#                     auth email (see the 2026-06-08 contact-form flood).
#   3. ERROR SPIKE  — same report .error field. Alert if > ERROR_THRESHOLD —
#                     catches bulk sender-rejection / delivery failure.
#
# DEBOUNCE: a recurring watcher must not re-fire every cycle while a condition
# persists. Each check writes a per-day sentinel under $CONFIG_DIR keyed on
# YYYY-MM-DD; if today's sentinel exists, that check stays quiet. So a
# persistent failure alerts at most once per UTC day per check, not every run.
#
# CREDENTIALS: needs BREVO_API_KEY. Sourced from
# ~/.config/imagineering/brevo-credentials (mode 0600, exports BREVO_API_KEY),
# mirroring the notify-credentials pattern that watcher-base.sh already uses.
# If absent, the watcher logs and exits cleanly (can't check, won't crash cron).
#
# Cron: 23 */4 * * * /home/ubuntu/email-health-watch.sh  # email-health-watch

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="email-health-watch"
# shellcheck disable=SC2034
CRON_TAG="email-health-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090  # dynamic path; resolved at runtime
source "$__lib"
unset __lib

# NOTE: we deliberately do NOT source lib/diagnose.sh. This watcher needs only
# one helper from it (html_escape), so inlining it below keeps the install
# footprint to watcher-base.sh + this file — sourcing diagnose.sh unconditionally
# would otherwise crash at startup (set -e) on any host that doesn't have it.
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# --- Configuration (env-tunable) -------------------------------------------
BREVO_API="${BREVO_API:-https://api.brevo.com/v3}"
# Required sending domains — each must be authenticated + verified in Brevo.
# Space-separated so it can be overridden from the environment if needed.
REQUIRED_DOMAINS="${REQUIRED_DOMAINS:-imagineering.cc xdeca.com}"
CAP="${CAP:-300}"                       # Brevo free-plan daily send cap
WARN_PCT="${WARN_PCT:-70}"              # alert when daily requests >= this % of CAP
ERROR_THRESHOLD="${ERROR_THRESHOLD:-25}" # alert when daily .error exceeds this

# Brevo credentials. Mirror the notify-credentials sourcing in watcher-base.sh:
# a 0600 env file under $CONFIG_DIR that exports BREVO_API_KEY.
BREVO_CRED_FILE="$CONFIG_DIR/brevo-credentials"
# shellcheck source=/dev/null
[[ -r "$BREVO_CRED_FILE" ]] && { set -a; . "$BREVO_CRED_FILE"; set +a; }

# --- Helpers ----------------------------------------------------------------

# brevo_get <path> — GET the Brevo API, echo the raw JSON body on success.
# Returns non-zero on transport failure or non-2xx HTTP status so callers can
# distinguish "their fault / transient" (skip this cycle) from real data.
brevo_get() {
    local path="$1" body http
    # Append HTTP status as a trailing line so we can split body from code
    # without needing jq on the status. --fail is intentionally NOT used so
    # we can read the status ourselves and log it.
    body=$(curl -sS --max-time 15 -w $'\n%{http_code}' \
        "${BREVO_API}${path}" \
        -H "api-key: ${BREVO_API_KEY}" \
        -H "accept: application/json" 2>/dev/null) || return 1
    http="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "$http" != 2* ]]; then
        log "brevo_get $path: HTTP $http"
        return 1
    fi
    printf '%s' "$body"
}

# alerted_today <check-key> — true if this check already alerted today (UTC).
alerted_today() {
    local key="$1" today
    today=$(date -u +%Y-%m-%d)
    [[ -f "$CONFIG_DIR/$WATCHER_NAME.$key.alerted" ]] \
        && [[ "$(cat "$CONFIG_DIR/$WATCHER_NAME.$key.alerted" 2>/dev/null)" == "$today" ]]
}

# mark_alerted <check-key> — record that this check alerted today.
mark_alerted() {
    date -u +%Y-%m-%d > "$CONFIG_DIR/$WATCHER_NAME.$1.alerted"
}

# clear_alerted <check-key> — reset the debounce so the next failure re-fires.
# Called on recovery so a healthy day doesn't suppress the next real alert.
clear_alerted() {
    rm -f "$CONFIG_DIR/$WATCHER_NAME.$1.alerted"
}

# domain_dns_detail <domain> — ENRICHMENT (not detection). Only called on the
# unhealthy path to NAME which DNS record is broken. GET /senders/domains/{d}
# returns a `dns_records` object whose entries each carry a `status` boolean
# (true = verified, false/null = not). The 2026-06-20 incident was a missing
# DMARC `rua` record — the cheap LIST endpoint can't see that granularity, this
# can. Echoes one "  - <record>: not verified (status=<v>)" line per broken
# record, or nothing if all records verify / detail is unavailable.
#
# DEFENSIVE: any API failure or unexpected shape returns empty (the caller then
# falls back to the existing generic alert) — enrichment must never crash the
# watcher or block the alert it decorates. Record keys are read generically
# (Brevo mixes camelCase `dkim1Record` and snake_case `dmarc_record`), and a
# `null` status is treated as not-verified but reported distinctly from `false`.
domain_dns_detail() {
    local domain="$1" json detail
    json=$(brevo_get "/senders/domains/$domain") || return 0
    detail=$(python3 -c '
import json, sys
try:
    recs = json.loads(sys.stdin.read()).get("dns_records") or {}
except Exception:
    sys.exit(0)
if not isinstance(recs, dict):
    sys.exit(0)
lines = []
for name in sorted(recs):
    entry = recs[name]
    status = entry.get("status") if isinstance(entry, dict) else None
    if status is not True:
        shown = "null" if status is None else str(status).lower()
        lines.append(f"  - {name}: not verified (status={shown})")
print("\n".join(lines))
' <<< "$json" 2>/dev/null) || return 0
    printf '%s' "$detail"
}

# --- Checks -----------------------------------------------------------------
# Each check fires tg() at most once/day (debounced) and clears its sentinel on
# recovery. None of them transition the state machine — phase_a_check returns 1.

# CHECK 1: domain authentication. The incident-catching check.
check_domain_auth() {
    local json bad
    json=$(brevo_get "/senders/domains") || { log "check_domain_auth: API unavailable, skipping"; return; }

    # Python parse: for each required domain, report failures. Emits one human
    # line per problem; empty output means all required domains are healthy.
    bad=$(REQUIRED_DOMAINS="$REQUIRED_DOMAINS" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read())
domains = {d.get("domain_name"): d for d in data.get("domains", [])}
problems = []
for name in os.environ["REQUIRED_DOMAINS"].split():
    d = domains.get(name)
    if d is None:
        problems.append(f"{name}: MISSING from Brevo account")
    elif not d.get("authenticated", False):
        problems.append(f"{name}: authenticated=false")
    elif not d.get("verified", False):
        problems.append(f"{name}: verified=false")
print("\n".join(problems))
' <<< "$json") || { log "check_domain_auth: parse failed"; return; }

    if [[ -n "$bad" ]]; then
        log "check_domain_auth: PROBLEMS: ${bad//$'\n'/ | }"
        if ! alerted_today domain_auth; then
            # ENRICHMENT: for each flagged domain, pull the per-domain DNS-record
            # detail so the alert can name the broken record (DKIM/DMARC/brevo
            # code) rather than just "domain unauthenticated". Only the unhealthy
            # path pays this extra call — healthy cycles stay one cheap LIST call.
            local detail_block="" dom dom_detail
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                dom="${line%%:*}"          # "<domain>: <reason>" → "<domain>"
                dom_detail=$(domain_dns_detail "$dom")
                if [[ -n "$dom_detail" ]]; then
                    detail_block+="${dom} DNS records:"$'\n'"${dom_detail}"$'\n'
                fi
            done <<< "$bad"

            local pretty extra=""
            pretty=$(html_escape "$bad")
            if [[ -n "$detail_block" ]]; then
                extra=$(printf '\n<b>Broken DNS records:</b>\n<pre>%s</pre>' "$(html_escape "${detail_block%$'\n'}")")
            fi
            tg "$(printf '🚨 <b>Brevo sending-domain auth FAILING</b>\n\nTransactional email (Outline resets, Kan magic links/invites, contact-form leads) will be silently dropped — Brevo accepts sends (250 OK) then rejects at processing.\n\n<pre>%s</pre>%s\nFix in Brevo → Senders, Domains &amp; IPs. <i>(2026-06-20 incident class.)</i>' "$pretty" "$extra")"
            mark_alerted domain_auth
        fi
    else
        log "check_domain_auth: all required domains authenticated+verified"
        clear_alerted domain_auth
    fi
}

# CHECK 2 & 3 share one aggregatedReport call (volume + error).
check_volume_and_errors() {
    local json requests error warn_at
    json=$(brevo_get "/smtp/statistics/aggregatedReport?days=1") \
        || { log "check_volume_and_errors: API unavailable, skipping"; return; }

    # Pull the two integer fields with python (robust against missing keys).
    requests=$(python3 -c 'import json,sys; print(int(json.loads(sys.stdin.read()).get("requests",0)))' <<< "$json") \
        || { log "check_volume_and_errors: parse failed (requests)"; return; }
    error=$(python3 -c 'import json,sys; print(int(json.loads(sys.stdin.read()).get("error",0)))' <<< "$json") \
        || { log "check_volume_and_errors: parse failed (error)"; return; }

    warn_at=$(( CAP * WARN_PCT / 100 ))
    log "check_volume_and_errors: requests=$requests (warn>=$warn_at of cap $CAP) error=$error (threshold=$ERROR_THRESHOLD)"

    # CHECK 2: volume vs cap.
    if [[ "$requests" -ge "$warn_at" ]]; then
        if ! alerted_today volume; then
            tg "$(printf '🚨 <b>Brevo daily send volume high: %s / %s</b> (&ge;%s%% of cap)\n\nThe daily send cap is shared across imagineering + xdeca. Exhausting it starves password-reset / magic-link email. Check for a flood (scanner bot, runaway loop) before the cap is hit.' \
            "$requests" "$CAP" "$WARN_PCT")"
            mark_alerted volume
        fi
    else
        clear_alerted volume
    fi

    # CHECK 3: error spike.
    if [[ "$error" -gt "$ERROR_THRESHOLD" ]]; then
        if ! alerted_today errors; then
            tg "$(printf '🚨 <b>Brevo delivery errors elevated: %s today</b> (threshold %s)\n\nBulk send-failures — possible sender rejection, hard bounces, or a misconfigured sender. Check Brevo → Statistics for the breakdown.' \
            "$error" "$ERROR_THRESHOLD")"
            mark_alerted errors
        fi
    else
        clear_alerted errors
    fi
}

# --- State-machine glue -----------------------------------------------------
# Recurring watcher: do all the work in phase A and never advance. Returning 1
# keeps run_watcher in phase A every cycle (no A→B, no self-disable).
phase_a_check() {
    if [[ -z "${BREVO_API_KEY:-}" ]]; then
        log "phase_a: BREVO_API_KEY not set (missing $BREVO_CRED_FILE?); cannot check"
        return 1
    fi
    check_domain_auth
    check_volume_and_errors
    return 1
}

# Never reached (phase_a_check always returns 1), but the lib contract requires
# it to exist. Return 1 so that even if state were forced to B, it would not
# self-disable.
phase_b_check() {
    return 1
}

run_watcher
