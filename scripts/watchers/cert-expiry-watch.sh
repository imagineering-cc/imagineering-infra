#!/usr/bin/env bash
# Cert-expiry watcher — defense-in-depth for Caddy auto-renewal.
#
# Caddy normally auto-renews at ~30 days before expiry. If renewal silently
# breaks, the first symptom is a service outage. This watcher catches it:
#
# Phase A: any monitored domain's cert is <14 days from expiry → 🚨. Means
#          Caddy auto-renew likely failed for that domain.
# Phase B: all monitored domains >30 days from expiry → ✅, self-disable.
#
# Probes certs externally via `openssl s_client` rather than docker-exec'ing
# into Caddy. Two reasons:
#   1. Tests what real TLS clients see (Caddy could have stale on-disk
#      certs but a healthy fresh one in memory, or vice versa — the public
#      view is what matters for outages).
#   2. No docker group / sudo dependency. Runs cleanly as the ubuntu user
#      from cron without any privilege escalation.
#
# Cron: 17 */6 * * * /home/ubuntu/cert-expiry-watch.sh  # cert-expiry-watch

set -euo pipefail

# shellcheck disable=SC2034
WATCHER_NAME="cert-expiry-watch"
# shellcheck disable=SC2034
CRON_TAG="cert-expiry-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

__diag="$(dirname "$0")/lib/diagnose.sh"
[[ -r "$__diag" ]] || __diag="$HOME/lib/diagnose.sh"
# shellcheck disable=SC1090
source "$__diag"
unset __diag

WARN_DAYS=14
SAFE_DAYS=30

# Domains to probe. The "load-bearing" public surface — outages here are
# user-visible. Add more as new services come online; remove ones that
# are decommissioned or never had Caddy-managed certs.
DOMAINS=(
    imagineering.cc
    kan.imagineering.cc
    outline.imagineering.cc
    matrix.imagineering.cc
    notify.imagineering.cc
    storage.imagineering.cc
    dav.imagineering.cc
    livekit.imagineering.cc
)

# Echoes "<domain>:<days_remaining>" for each probed domain. Skips silently
# (no line emitted) on probe failure — caller treats "no data" specially.
list_certs_with_days() {
    local domain expiry_str expiry_epoch days
    local now_epoch
    now_epoch=$(date +%s)
    for domain in "${DOMAINS[@]}"; do
        expiry_str=$(echo \
            | timeout 8 openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
            | openssl x509 -enddate -noout 2>/dev/null \
            | sed 's/notAfter=//') || continue
        [[ -z "$expiry_str" ]] && continue
        expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null) || continue
        days=$(( (expiry_epoch - now_epoch) / 86400 ))
        echo "$domain:$days"
    done
}

# Counts non-empty lines in $1. Robust against the `<<< ""` adds-a-newline
# trap that breaks `grep -c '' <<< "$x"` when $x is empty.
nlines() {
    if [[ -z "$1" ]]; then echo 0; else awk 'END { print NR }' <<< "$1"; fi
}

phase_a_check() {
    local lines warning probed_count
    lines=$(list_certs_with_days)
    probed_count=$(nlines "$lines")
    if [[ "$probed_count" -eq 0 ]]; then
        log "phase_a: zero successful cert probes — network/openssl issue"
        return 2
    fi
    warning=$(awk -F: -v t="$WARN_DAYS" '$2 < t { print }' <<< "$lines")
    log "phase_a: probed=$probed_count under_${WARN_DAYS}d=$(nlines "$warning")"
    if [[ -n "$warning" ]]; then
        local pretty acme
        pretty=$(awk -F: '{ printf "  %s: %sd\n", $1, $2 }' <<< "$warning")
        # ACME reachability diagnostic: distinguishes "Caddy can't talk
        # to Let's Encrypt" (network/firewall) from "Caddy reaches LE
        # but renewal still fails" (account/cert-config issue). One curl,
        # ~5s budget, included inline.
        acme=$(html_escape "$(acme_probe)")
        tg "$(printf '🚨 <b>Caddy cert(s) near expiry</b> (auto-renew may have stalled)\n\n<pre>%s</pre>\nACME endpoint reachability: <code>%s</code>\n\nCheck <code>docker logs caddy 2&gt;&amp;1 | tail -100</code> on Sydney for renewal errors.' "$pretty" "$acme")"
        return 0
    fi
    return 1
}

phase_b_check() {
    local lines below_safe probed_count
    lines=$(list_certs_with_days)
    probed_count=$(nlines "$lines")
    if [[ "$probed_count" -eq 0 ]]; then
        log "phase_b: zero successful cert probes — won't claim recovery"
        return 2
    fi
    below_safe=$(awk -F: -v t="$SAFE_DAYS" '$2 < t { print }' <<< "$lines")
    if [[ -z "$below_safe" ]]; then
        tg "✅ <b>Caddy certs all healthy</b> — ${probed_count} domains, all &gt;${SAFE_DAYS} days from expiry. ${WATCHER_NAME} self-disabling."
        return 0
    fi
    log "phase_b: still $(nlines "$below_safe") under ${SAFE_DAYS}d"
    return 1
}

run_watcher
