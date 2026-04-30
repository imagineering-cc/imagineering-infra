#!/bin/bash
# Server health check - sends Telegram alerts when thresholds are exceeded
# Runs hourly via cron. Requires env vars: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_THREAD_ID

DISK_THRESHOLD=80
MEMORY_THRESHOLD=90
SWAP_THRESHOLD=50

# downstream-server health: alert if total request rows fall below the previous
# observed total (suggests data loss like the 2026-04-29 incident) or below an
# absolute floor. The "previous total" is persisted between runs.
DOWNSTREAM_HEALTH_URL="https://api.downstream-storage.cc/api/health"
DOWNSTREAM_STATE_DIR="$HOME/.health-state"
DOWNSTREAM_PREV_FILE="$DOWNSTREAM_STATE_DIR/downstream-prev-total"
DOWNSTREAM_MIN_TOTAL=10

issues=()

# Check disk usage (all mounted filesystems, excluding tmpfs/devtmpfs)
while read -r usage mount; do
    pct=${usage%\%}
    if [ "$pct" -gt "$DISK_THRESHOLD" ]; then
        issues+=("Disk ${mount}: ${pct}% used \\(threshold: ${DISK_THRESHOLD}%\\)")
    fi
done < <(df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay | tail -n +2 | awk '{print $1, $2}')

# Check memory usage
mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
if [ "$mem_total" -gt 0 ]; then
    mem_used_pct=$(( (mem_total - mem_available) * 100 / mem_total ))
    if [ "$mem_used_pct" -gt "$MEMORY_THRESHOLD" ]; then
        issues+=("Memory: ${mem_used_pct}% used \\(threshold: ${MEMORY_THRESHOLD}%\\)")
    fi
fi

# Check swap usage
swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
swap_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
if [ "$swap_total" -gt 0 ]; then
    swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    if [ "$swap_used_pct" -gt "$SWAP_THRESHOLD" ]; then
        issues+=("Swap: ${swap_used_pct}% used \\(threshold: ${SWAP_THRESHOLD}%\\)")
    fi
fi

# Check for unhealthy Docker containers
while read -r name status; do
    issues+=("Container *${name}*: ${status}")
done < <(docker ps -a --filter "status=exited" --filter "status=restarting" --format "{{.Names}} {{.Status}}" 2>/dev/null)

# Check downstream-server request count (data-loss canary)
mkdir -p "$DOWNSTREAM_STATE_DIR"
ds_response=$(curl -sS --max-time 10 "$DOWNSTREAM_HEALTH_URL" 2>/dev/null)
ds_curl_rc=$?
if [ "$ds_curl_rc" -ne 0 ] || [ -z "$ds_response" ]; then
    issues+=("downstream-server: /api/health unreachable \\(curl rc=${ds_curl_rc}\\)")
elif ! ds_total=$(echo "$ds_response" | jq -e '.requests.total' 2>/dev/null); then
    issues+=("downstream-server: /api/health returned unexpected JSON")
else
    # Absolute floor
    if [ "$ds_total" -lt "$DOWNSTREAM_MIN_TOTAL" ]; then
        issues+=("downstream-server: requests.total=${ds_total} below floor ${DOWNSTREAM_MIN_TOTAL}")
    fi
    # Drop vs previous snapshot
    if [ -f "$DOWNSTREAM_PREV_FILE" ]; then
        ds_prev=$(cat "$DOWNSTREAM_PREV_FILE" 2>/dev/null)
        if [ -n "$ds_prev" ] && [ "$ds_total" -lt "$ds_prev" ]; then
            issues+=("downstream-server: requests.total dropped ${ds_prev} → ${ds_total}")
        fi
    fi
    # Persist the new high-water mark (only ratchet up, so a transient drop
    # still alerts on the next run rather than silently re-baselining low).
    if [ ! -f "$DOWNSTREAM_PREV_FILE" ] || [ "$ds_total" -gt "$(cat "$DOWNSTREAM_PREV_FILE" 2>/dev/null || echo 0)" ]; then
        echo "$ds_total" > "$DOWNSTREAM_PREV_FILE"
    fi
fi

# Send alert if any issues found
if [ ${#issues[@]} -gt 0 ]; then
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ALERT but missing TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID"
        printf '  - %s\n' "${issues[@]}"
        exit 1
    fi

    body=""
    for issue in "${issues[@]}"; do
        body="${body}\n\\- ${issue}"
    done

    # Tag team members
    tags="@sentientcogs"

    message="*\U0001F6A8 Server Health Alert*${body}\n\n${tags}"

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d message_thread_id="$TELEGRAM_THREAD_ID" \
        -d parse_mode="MarkdownV2" \
        --data-urlencode "text=$(echo -e "$message")" \
        > /dev/null

    echo "$(date '+%Y-%m-%d %H:%M:%S') Alert sent: ${#issues[@]} issue(s)"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') OK - all checks passed"
fi
