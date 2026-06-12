#!/bin/bash
# Server health check - sends Telegram alerts when thresholds are exceeded.
# Runs hourly via cron. Telegram credentials are loaded from
# /etc/downstream-secrets/telegram.env by the shared helper below — they are
# no longer inlined into the cron entry (avoids leaking the bot token in a
# world-readable /etc/cron.d/ file).

# Source shared Telegram helper (defines send_telegram_alert + loads creds).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/telegram.sh
. "$SCRIPT_DIR/lib/telegram.sh"

DISK_THRESHOLD=80
MEMORY_THRESHOLD=90
SWAP_THRESHOLD=50

# NOTE: the downstream-server /api/health data-loss canary moved to the
# downstream repo (nickmeinhold/downstream
# deploy/oci/scripts/health-check-downstream.sh, cron hourly :05) in the
# #291 Phase B ops-move. This script keeps the shared-host checks below
# (disk/memory/swap/exited containers), which cover img-downstream-server
# as a container on the shared box.

issues=()

# Check disk usage (all mounted filesystems, excluding tmpfs/devtmpfs)
while read -r usage mount; do
    pct=${usage%\%}
    if [ "$pct" -gt "$DISK_THRESHOLD" ]; then
        issues+=("Disk ${mount}: ${pct}% used (threshold: ${DISK_THRESHOLD}%)")
    fi
done < <(df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay | tail -n +2 | awk '{print $1, $2}')

# Check memory usage
mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ "$mem_total" -gt 0 ]; then
    mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
    if [ "$mem_used_pct" -gt "$MEMORY_THRESHOLD" ]; then
        issues+=("Memory: ${mem_used_pct}% used (threshold: ${MEMORY_THRESHOLD}%)")
    fi
fi

# Check swap usage
swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
swap_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
if [ "$swap_total" -gt 0 ]; then
    swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    if [ "$swap_used_pct" -gt "$SWAP_THRESHOLD" ]; then
        issues+=("Swap: ${swap_used_pct}% used (threshold: ${SWAP_THRESHOLD}%)")
    fi
fi

# Check for unhealthy Docker containers. Known one-shot helper containers
# (compose migrate/setup jobs) exit 0 by design and sit in "Exited (0)"
# forever — a clean exit from THESE is not a failure. The skip is an
# explicit name allowlist, NOT a blanket "Exited (0) is fine": a
# long-running service that exits cleanly (docker stop, handled SIGTERM)
# is still down and must alert. Extend the allowlist when adding new
# one-shot jobs. (Without the skip the repo version alert-spams hourly;
# the previously-deployed host copy had drifted and silently ignored
# these containers.)
ONESHOT_HELPERS_RE='^(img-)?(kanbn-migrate|outline[-_]minio_setup)$'
while read -r name status; do
    if [[ "$status" == "Exited (0)"* ]] && [[ "$name" =~ $ONESHOT_HELPERS_RE ]]; then
        continue
    fi
    issues+=("Container <b>${name}</b>: ${status}")
done < <(docker ps -a --filter "status=exited" --filter "status=restarting" --format "{{.Names}} {{.Status}}" 2>/dev/null)

# Send alert if any issues found
if [ ${#issues[@]} -gt 0 ]; then
    if [ -z "$NOTIFY_API_KEY" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ALERT but missing NOTIFY_API_KEY"
        printf '  - %s\n' "${issues[@]}"
        exit 1
    fi

    # Build HTML message body. Issue strings come from `docker ps`, /proc,
    # and curl rc codes — no HTML metacharacters in practice — and the
    # container-name issue deliberately includes literal `<b>...</b>` tags
    # for emphasis. We therefore concatenate as-is rather than passing each
    # issue through telegram_html_escape (which would double-escape the
    # tags). If a future check ingests untrusted text, escape it at the
    # source before pushing into ${issues[@]}.
    body=""
    for issue in "${issues[@]}"; do
        body="${body}
- ${issue}"
    done

    # Tag team members (literal text, no Markdown link)
    tags="@sentientcogs"

    # U+1F6A8 ROTATING LIGHT — written as ANSI-C $'...' so the bytes are
    # explicit and don't depend on bash's printf-format \xNN handling.
    siren=$'\xF0\x9F\x9A\xA8'
    message="<b>${siren} Server Health Alert</b>${body}

${tags}"

    send_telegram_alert "$message"

    echo "$(date '+%Y-%m-%d %H:%M:%S') Alert sent: ${#issues[@]} issue(s)"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') OK - all checks passed"
fi
