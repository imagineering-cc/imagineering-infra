#!/usr/bin/env bash
# Brevo transactional-email health watcher — catches the "250-OK then
# silently dropped" class of failure that killed imagineering.cc email
# for days (Outline password resets, Kan magic-links/invites, contact-form
# notifications). Brevo accepted every SMTP send (250 queued) then rejected
# at processing with "sender noreply@imagineering.cc is not valid" because
# the domain was never fully authenticated. The 250-OK hid it; nothing fired.
#
# Two checks, cheapest-first:
#
# Phase A (the alert condition) fires if EITHER:
#   1. SENDER-AUTH (root cause): GET /v3/senders/domains shows a monitored
#      sending domain (imagineering.cc) with authenticated=false or
#      verified=false. This is the cheapest probe and catches the exact
#      incident above — a domain that looks configured but isn't fully
#      authenticated, so every send is queued-then-dropped.
#   2. DELIVERY-EVENTS (symptom): GET /v3/smtp/statistics/events?days=1
#      shows the count of `error` + `blocked` events (the buckets a
#      dropped-at-processing send lands in, esp. reason ~ "sender ... is
#      not valid") exceeding a small threshold. Catches auth issues the
#      domains endpoint might not surface, plus other delivery breakage
#      (IP blocks, recipient-domain blocks).
#
# Phase B (recovery → self-disable): all monitored domains authenticated
#   AND verified, AND error/blocked event count back under threshold → ✅.
#
# This is the same shape as cert-expiry-watch (alert when a health signal
# flips bad, recover-and-self-disable when it's healthy again) — email
# auth "stops mattering" once it's fixed, exactly the watcher contract.
#
# ---------------------------------------------------------------------------
# DEPLOY GATE (not yet done — this watcher is NOT live):
#   1. BREVO_API_KEY must be added to server secrets. There is no
#      brevo-credentials file on Sydney yet. Generate a v3 API key in the
#      Brevo dashboard (Settings → SMTP & API → API Keys → read access is
#      sufficient: the watcher only does GETs) and install it on Sydney as
#      a 0600 file the watcher sources, mirroring notify-credentials:
#        ~/.config/imagineering/brevo-credentials
#      containing the single line:
#        export BREVO_API_KEY=xkeysib-...
#      If you'd rather keep it in SOPS, add it alongside the other
#      transactional-email secrets (the SMTP creds already live in
#      kanbn/secrets.yaml, outline/secrets.yaml,
#      imagineering-contact-us/secrets.yaml). A dedicated
#      watchers/secrets.yaml decrypting to brevo-credentials would match
#      the per-stack SOPS pattern; deploy-to.sh would then place it.
#   2. Add the cron entry on Sydney (every 3 hours — auth state changes
#      rarely, and the events window is 1 day so sub-hourly is wasteful):
#        crontab -l | { cat; echo "23 */3 * * * /home/ubuntu/brevo-email-health-watch.sh  # brevo-email-health-watch"; } | crontab -
#      The trailing comment MUST match $CRON_TAG — self_disable() greps it.
#   3. notify-credentials must already exist on Sydney (it does if any
#      other watcher has run). The watcher fails LOUDLY if BREVO_API_KEY
#      is unset (non-zero exit + stderr) but degrades quietly if notify
#      creds are missing (logs and continues — same as the siblings).
#
# Local dry test (no host, no cron):
#   export BREVO_API_KEY=xkeysib-...
#   DRY_RUN=1 ./scripts/watchers/brevo-email-health-watch.sh
#   tail ~/brevo-email-health-watch.log
# ---------------------------------------------------------------------------

set -euo pipefail

# shellcheck disable=SC2034
WATCHER_NAME="brevo-email-health-watch"
# shellcheck disable=SC2034
CRON_TAG="brevo-email-health-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

# diagnose.sh provides html_escape() for safe inclusion of dynamic Brevo
# strings (domain names, bounce reasons) in HTML-mode Telegram messages.
__diag="$(dirname "$0")/lib/diagnose.sh"
[[ -r "$__diag" ]] || __diag="$HOME/lib/diagnose.sh"
# shellcheck disable=SC1090
source "$__diag"
unset __diag

# ---------------------------------------------------------------------------
# Brevo API key — sourced the same way the lib sources notify-credentials.
# Honour an already-set env var first (local dry test), then fall back to
# the credentials file. Fail LOUDLY if neither yields a key: a watcher that
# silently no-ops on a missing key is exactly the kind of silent failure
# this watcher exists to catch.
# ---------------------------------------------------------------------------
BREVO_CRED_FILE="$CONFIG_DIR/brevo-credentials"
if [[ -z "${BREVO_API_KEY:-}" && -r "$BREVO_CRED_FILE" ]]; then
    # shellcheck source=/dev/null
    { set -a; . "$BREVO_CRED_FILE"; set +a; }
fi
if [[ -z "${BREVO_API_KEY:-}" ]]; then
    echo "brevo-email-health-watch: BREVO_API_KEY is unset and no readable ${BREVO_CRED_FILE}; cannot run." >&2
    log "FATAL: BREVO_API_KEY unset and no readable $BREVO_CRED_FILE — aborting"
    exit 1
fi

# Sending domains whose authentication we care about. These are the From:
# domains imagineering.cc transactional email actually uses. Add more as
# new sending identities come online.
MONITORED_DOMAINS=(
    imagineering.cc
)

# Alert if error+blocked events over the last day exceed this. A couple of
# stray bounces/blocks are normal background; a real auth break produces a
# burst (every send dropped). Tune up if legitimate volume is high.
EVENT_THRESHOLD=5
EVENT_WINDOW_DAYS=1

BREVO_API="https://api.brevo.com/v3"

# brevo_get <path>
#   GET against the Brevo API with the api-key header. Echoes the response
#   body on HTTP 2xx; on any non-2xx or transport failure, echoes nothing
#   and returns non-zero so callers can treat it as "don't know" (return 2,
#   transient) rather than "healthy" — a failed probe must never look like
#   a passing check.
brevo_get() {
    local path="$1" resp http_code body
    resp=$(curl -sS --max-time 15 -w '\n%{http_code}' \
            -H "api-key: ${BREVO_API_KEY}" \
            -H "Accept: application/json" \
            "${BREVO_API}${path}" 2>&1) || { log "brevo_get $path: curl failed: ${resp}"; return 1; }
    http_code=$(tail -n1 <<< "$resp")
    body=$(sed '$d' <<< "$resp")
    if [[ "$http_code" != 2* ]]; then
        log "brevo_get $path: HTTP $http_code body=$(head -c 200 <<< "$body" | tr '\n' ' ')"
        return 1
    fi
    printf '%s' "$body"
}

# unauthenticated_domains
#   Echoes "<domain> auth=<bool> verified=<bool>" for each MONITORED_DOMAINS
#   entry that is present in the account but NOT (authenticated AND verified).
#   Returns 0 with output on findings, 0 with empty output if all healthy,
#   and 2 if the probe itself failed (so the caller treats it as transient,
#   not as "all clear").
unauthenticated_domains() {
    local body
    body=$(brevo_get "/senders/domains") || return 2
    local d row
    for d in "${MONITORED_DOMAINS[@]}"; do
        # Select the matching domain object; emit a flag line only if it
        # exists AND is not fully (authenticated && verified). A monitored
        # domain that's entirely absent from the account is itself a problem
        # (nothing can send from it) — surface that too.
        row=$(jq -r --arg d "$d" '
            (.domains // [])
            | map(select(.domain_name == $d))
            | if length == 0 then
                "\($d) MISSING-from-account"
              elif (.[0].authenticated == true and .[0].verified == true) then
                empty
              else
                "\($d) auth=\(.[0].authenticated) verified=\(.[0].verified)"
              end
        ' <<< "$body" 2>/dev/null) || { log "unauthenticated_domains: jq parse failed"; return 2; }
        [[ -n "$row" ]] && echo "$row"
    done
    return 0
}

# bad_event_count
#   Echoes the number of `error` + `blocked` events in the last
#   $EVENT_WINDOW_DAYS, or "?" on probe failure (caller treats "?" as
#   transient). The two event filters are separate API calls because the
#   endpoint's `event` param takes a single value.
bad_event_count() {
    local total=0 ev body n
    for ev in error blocked; do
        body=$(brevo_get "/smtp/statistics/events?days=${EVENT_WINDOW_DAYS}&event=${ev}&limit=2500") || { echo "?"; return; }
        n=$(jq -r '(.events // []) | length' <<< "$body" 2>/dev/null) || { echo "?"; return; }
        [[ "$n" =~ ^[0-9]+$ ]] || { echo "?"; return; }
        total=$(( total + n ))
    done
    echo "$total"
}

# bad_event_reasons
#   A short, de-duplicated, HTML-safe summary of the distinct reasons behind
#   recent error/blocked events — surfaces the "sender ... is not valid"
#   string that pinpoints the auth root cause. Best-effort: empty string on
#   any probe/parse failure (the alert still fires with the count).
bad_event_reasons() {
    local ev body reasons=""
    for ev in error blocked; do
        body=$(brevo_get "/smtp/statistics/events?days=${EVENT_WINDOW_DAYS}&event=${ev}&limit=2500") || continue
        local r
        r=$(jq -r '(.events // []) | map(.reason // "(no reason)") | unique | .[]' <<< "$body" 2>/dev/null) || continue
        [[ -n "$r" ]] && reasons+="${r}"$'\n'
    done
    # Collapse duplicates across both event types, cap at 5 distinct reasons.
    printf '%s' "$reasons" | awk 'NF' | sort -u | head -5
}

phase_a_check() {
    local unauth events reasons fired=1

    unauth=$(unauthenticated_domains) || {
        # return 2 from unauthenticated_domains → probe failed. Don't alert
        # off a failed probe; let cron retry.
        log "phase_a: domains probe transient-failed"
        return 2
    }

    events=$(bad_event_count)
    log "phase_a: unauth=[$(tr '\n' ';' <<< "$unauth")] bad_events=${events} (threshold ${EVENT_THRESHOLD})"

    local alert=""
    if [[ -n "$unauth" ]]; then
        local pretty
        pretty=$(html_escape "$unauth")
        alert+="$(printf '<b>Sender domain(s) not fully authenticated:</b>\n<pre>%s</pre>\n' "$pretty")"
        fired=0
    fi
    if [[ "$events" != "?" && "$events" -ge "$EVENT_THRESHOLD" ]]; then
        reasons=$(bad_event_reasons)
        local reasons_html
        reasons_html=$(html_escape "${reasons:-(reasons unavailable)}")
        alert+="$(printf '<b>%s error/blocked events in last %sd</b> (threshold %s). Distinct reasons:\n<pre>%s</pre>\n' \
                  "$events" "$EVENT_WINDOW_DAYS" "$EVENT_THRESHOLD" "$reasons_html")"
        fired=0
    fi

    if [[ "$fired" -eq 0 ]]; then
        tg "$(printf '🚨 <b>Brevo transactional email unhealthy</b>\n\n%s\nThis is the silent-drop class: Brevo returns 250-OK at SMTP then drops at processing. Outline resets / Kan magic-links / contact-form mail may be dead. Check Brevo → Senders & IP → Domains and the email events log.' "$alert")"
        return 0
    fi
    return 1
}

phase_b_check() {
    local unauth events
    unauth=$(unauthenticated_domains) || {
        log "phase_b: domains probe transient-failed; won't claim recovery"
        return 2
    }
    events=$(bad_event_count)
    if [[ "$events" == "?" ]]; then
        log "phase_b: events probe transient-failed; won't claim recovery"
        return 2
    fi
    log "phase_b: unauth=[$(tr '\n' ';' <<< "$unauth")] bad_events=${events}"
    if [[ -z "$unauth" && "$events" -lt "$EVENT_THRESHOLD" ]]; then
        tg "$(printf '✅ <b>Brevo email recovered</b> — all monitored domains authenticated &amp; verified, error/blocked events back under threshold (%s in last %sd). %s self-disabling.' \
              "$events" "$EVENT_WINDOW_DAYS" "$WATCHER_NAME")"
        return 0
    fi
    return 1
}

run_watcher
