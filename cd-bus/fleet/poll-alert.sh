#!/bin/bash
# OnFailure handler for cd-poll@<svc>.service — FLEET TEMPLATE.
# Installed at /opt/cd-bus/poll-alert.sh; invoked as `poll-alert.sh %i` by
# cd-poll-alert@.service.
#
# Fired when the poll-leg unit *really* fails — exit 2 from deploy.sh after >=3
# consecutive docker compose failures (~15 min broken at the 5-min cadence), or
# unit-level breakage (script missing, perms). Two channels:
#  1. journald `TELEGRAM[crit]:` line (forwarder contract + audit trail).
#  2. direct POST to Telegram via the shared /opt/scripts/lib/telegram.sh.
#
# ALERT_SUFFIX (optional env) is appended; verification runs use it.
set -uo pipefail # deliberately no -e: try every channel even if one fails

SVC="${1:?usage: poll-alert.sh <service>}"

# shellcheck source=/dev/null
. /opt/scripts/lib/telegram.sh

MSG="cd-poll@${SVC} failed on $(hostname) — the CD pull leg has been broken for ~15 min (docker compose pull/up failing). Deploys for ${SVC} are NOT landing on either leg until this clears.${ALERT_SUFFIX:-}"

echo "TELEGRAM[crit]: ${MSG}" | systemd-cat -t "cd-poll-alert@${SVC}" -p crit
send_telegram_alert "CRITICAL: $(telegram_html_escape "${MSG}")"
