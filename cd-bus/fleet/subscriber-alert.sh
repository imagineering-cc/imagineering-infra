#!/bin/bash
# OnFailure handler for cd-bus-subscriber@<svc>.service — FLEET TEMPLATE.
# Installed at /opt/cd-bus/subscriber-alert.sh; invoked as
# `subscriber-alert.sh %i` by cd-bus-subscriber-alert@.service.
#
# Fired when the SSE subscriber unit *really* fails (start-limit exceeded — it
# cannot hold a connection to the relay). The SSE leg being down is NOT a
# deploy outage (the poll backstop converges within 5 min), but it is the
# dead-deployer class that hid for 13 days (claude-tasks #168) — so it must be
# VISIBLE. Two channels, same as the pilot:
#  1. journald line with the `TELEGRAM[crit]:` prefix (forwarder contract +
#     greppable audit trail).
#  2. direct POST to Telegram via the shared /opt/scripts/lib/telegram.sh.
#
# ALERT_SUFFIX (optional env) is appended; verification runs use it.
set -uo pipefail # deliberately no -e: try every channel even if one fails

SVC="${1:?usage: subscriber-alert.sh <service>}"

# shellcheck source=/dev/null
. /opt/scripts/lib/telegram.sh

MSG="cd-bus-subscriber@${SVC} failed on $(hostname) — SSE push leg is down (deploys fall back to the 5-min poll; latency degraded, not broken)${ALERT_SUFFIX:-}"

echo "TELEGRAM[crit]: ${MSG}" | systemd-cat -t "cd-bus-subscriber-alert@${SVC}" -p crit
send_telegram_alert "CRITICAL: $(telegram_html_escape "${MSG}")"
