#!/usr/bin/env bash
# OCI instance-RUNNING watcher — Melbourne→Sydney peer.
#
# Counterpart to oci-instance-watch.sh (which runs on Sydney and watches
# Melbourne). Sydney watches Melbourne via its NICK_MEL profile; this
# script watches Sydney via its SYDNEY profile. Each box catches the
# other's silent death — neither tries to monitor itself (chicken-and-
# egg: a watcher on the box it's watching can't notice the box dying).
#
# Sydney's tenancy is owned by gaylejewson@gmail.com (CreatedOn
# 2026-03-18). API access is via a Melbourne-generated key registered
# against Nick's user in that tenancy on 2026-05-03.
#
# Phase A: Sydney's tenancy has fewer RUNNING instances than expected
#          (1) → 🚨 (names the affected profile + delta).
# Phase B: count back to expected → ✅, self-disable.
#
# Cron: 17 */2 * * * /home/ubuntu/oci-instance-watch.sh  # oci-instance-watch
# (Every 2 hours, off the hour. Offset 4 min from Sydney's :13 to spread
#  load and avoid simultaneous fires.)

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

export PATH="$HOME/bin:$PATH"   # oci CLI lives in ~/bin
export SUPPRESS_LABEL_WARNING=True

# Per-tenancy: PROFILE|TENANCY_OCID|EXPECTED_RUNNING_COUNT
TENANCIES=(
    "SYDNEY|ocid1.tenancy.oc1..aaaaaaaaruqlptcngoh3dwzx3nu6ahahh3dbl5hy64o4rojhfmkmbgn3yfaa|1"
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
    below=$(awk -F: '$2 ~ /^[0-9]+$/ && $2 < $3 { print }' <<< "$lines")
    if [[ -n "$below" ]]; then
        local pretty
        pretty=$(awk -F: '{ printf "  %s: running=%s expected=%s\n", $1, $2, $3 }' <<< "$below")
        tg "$(printf '🚨 <b>OCI instance(s) not RUNNING</b> (Melbourne→Sydney peer)\n\n<pre>%s</pre>\nMeans Oracle reclaimed the instance, it crashed, or it was terminated. Check OCI console + try a manual start.' "$pretty")"
        return 0
    fi
    return 1
}

phase_b_check() {
    local lines stillBelow
    lines=$(check_all_tenancies)
    log "phase_b: $(tr '\n' ' ' <<< "$lines")"
    stillBelow=$(awk -F: '$2 ~ /^[0-9]+$/ && $2 < $3 { print }' <<< "$lines")
    if [[ -z "$stillBelow" ]]; then
        tg '✅ <b>OCI instance(s) RUNNING again</b> (Melbourne→Sydney peer) — recovery complete.'
        return 0
    fi
    return 1
}

run_watcher
