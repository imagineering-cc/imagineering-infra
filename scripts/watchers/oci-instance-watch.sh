#!/usr/bin/env bash
# OCI instance-RUNNING watcher.
#
# Replaces the quota-based design that died in smoke-testing during
# PR #37 (different free-tier vs PAYG quota semantics, and a region
# misconfig in the ROBIN profile that made the AD-keyed quota query
# unreliable). Monitoring "is the instance RUNNING" sidesteps both:
# Oracle reclaiming capacity and a manual termination both surface as
# the same RUNNING-count drop.
#
# Phase A: any of the 3 expected tenancies has fewer RUNNING instances
#          than expected → 🚨 (names the affected profile + delta).
# Phase B: all back to expected counts → ✅, self-disable.
#
# Expected (probed 2026-05-02):
#   NICK_MEL  → 1 (nick-mel) — Nick's Melbourne instance
#
# Initially monitored 3 tenancies (ROBIN, NICK_MEL, CANDEIRA) — those
# happened to be the OCI profiles on the Sydney box. But ROBIN is Robin
# Langer's tenancy and CANDEIRA is Javier's; only NICK_MEL is Nick's.
# Trimmed to Nick-only on 2026-05-02 to avoid 🚨'ing Nick about other
# people's instances.
#
# This watcher cannot watch Sydney itself (it runs ON Sydney — chicken
# and egg). Sydney's OCI tenancy is undocumented and isn't represented
# in /home/ubuntu/.oci/config. Future work: set up a peer watcher on
# Melbourne (nick-mel) that monitors Sydney from outside. Tracked as a
# follow-up task.
#
# Cron: 13 */2 * * * /home/ubuntu/oci-instance-watch.sh  # oci-instance-watch
# (Every 2 hours, off the hour. Instance state changes infrequently;
# faster polling burns OCI API quota for nothing.)

set -euo pipefail

# shellcheck disable=SC2034
WATCHER_NAME="oci-instance-watch"
# shellcheck disable=SC2034
CRON_TAG="oci-instance-watch"

__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

export PATH="$HOME/bin:$PATH"   # oci CLI lives in ~/bin on Sydney

# Per-tenancy: PROFILE|TENANCY_OCID|EXPECTED_RUNNING_COUNT
TENANCIES=(
    "NICK_MEL|ocid1.tenancy.oc1..aaaaaaaa53sr57ghje45q5lkvqunbxbh45imq4rfblzsqvf7vk7y4sjait2a|1"
)

# Echoes "<profile>:<actual>:<expected>" per tenancy.
# actual is "?" on query failure; the caller treats "?" as "don't know,
# don't fire" so a transient API blip doesn't trigger Phase A.
check_all_tenancies() {
    local entry profile tenancy expected result actual
    for entry in "${TENANCIES[@]}"; do
        IFS='|' read -r profile tenancy expected <<< "$entry"
        result=$(oci compute instance list \
                --compartment-id "$tenancy" \
                --profile "$profile" \
                --lifecycle-state RUNNING 2>&1 | grep -v Warning) || { echo "$profile:?:$expected"; continue; }
        actual=$(echo "$result" | jq -r '.data | length // 0' 2>/dev/null) || actual="?"
        echo "$profile:$actual:$expected"
    done
}

phase_a_check() {
    local lines below
    lines=$(check_all_tenancies)
    log "phase_a: $(tr '\n' ' ' <<< "$lines")"
    # Filter to tenancies where actual is a number AND below expected.
    below=$(awk -F: '$2 ~ /^[0-9]+$/ && $2 < $3 { print }' <<< "$lines")
    if [[ -n "$below" ]]; then
        local pretty
        pretty=$(awk -F: '{ printf "  %s: running=%s expected=%s\n", $1, $2, $3 }' <<< "$below")
        tg "$(printf '🚨 <b>OCI instance(s) not RUNNING</b>\n\n<pre>%s</pre>\nMeans Oracle reclaimed the instance, it crashed, or it was terminated. Check OCI console + try a manual start.' "$pretty")"
        return 0
    fi
    return 1
}

phase_b_check() {
    local lines unrecovered any_known
    lines=$(check_all_tenancies)
    log "phase_b: $(tr '\n' ' ' <<< "$lines")"
    unrecovered=$(awk -F: '$2 ~ /^[0-9]+$/ && $2 < $3 { print }' <<< "$lines")
    # Need at least one valid number to claim recovery — all-failed means we
    # don't know, don't claim.
    any_known=$(awk -F: '$2 ~ /^[0-9]+$/ { print }' <<< "$lines")
    if [[ -z "$unrecovered" && -n "$any_known" ]]; then
        tg "✅ <b>OCI instances all RUNNING again</b> — ${WATCHER_NAME} self-disabling."
        return 0
    fi
    if [[ -z "$any_known" ]]; then
        log "phase_b: all queries returned '?'; not declaring recovery"
        return 2
    fi
    return 1
}

run_watcher
