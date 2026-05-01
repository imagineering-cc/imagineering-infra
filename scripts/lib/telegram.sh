#!/bin/bash
# Shared Telegram alert helper, sourced by infra cron scripts.
#
# Provides:
#   telegram_html_escape <string>      -> echoes input with &, <, > escaped for HTML mode
#   send_telegram_alert <html_message> -> POST to Telegram with parse_mode=HTML
#
# Configuration: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_THREAD_ID
# (the last is optional). If not already in the environment, this lib tries
# to source /etc/downstream-secrets/telegram.env (root:nick 0640) so the
# token never has to be inlined into world-readable cron entries.
#
# Silent no-op if creds are missing — a missing-secret deploy shouldn't turn
# every cron into a stderr spammer.
#
# Why HTML, not MarkdownV2: MarkdownV2 requires escaping ~16 punctuation
# characters in *all* text (including dynamic data). One stray dot or paren
# from a stack frame breaks the message and Telegram silently 400s exactly
# when we most need the alert. HTML mode requires escaping only `&`, `<`,
# `>` — much smaller failure surface.

# Source the secrets file if present and the vars aren't already set.
# Done at source-time, not at function-call-time, so each script only pays
# the cost once (and behavior is predictable in `set -u` consumers).
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && [ -r /etc/downstream-secrets/telegram.env ]; then
  # shellcheck disable=SC1091
  . /etc/downstream-secrets/telegram.env
fi

# Default exports so consumers can use `${VAR:-}` or `set -u` safely.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_THREAD_ID="${TELEGRAM_THREAD_ID:-}"

# Escape &, <, > for Telegram HTML mode. Order matters: & must be first so
# the literal ampersands inserted by &lt; / &gt; aren't double-escaped.
# `${1:-}` so the function is safe to call under `set -u`.
telegram_html_escape() {
  local s=${1:-}
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# Send a Telegram alert. Silent no-op if creds are not configured (the
# common dev/test path); but if creds ARE present and curl fails, log to
# stderr — a silent communication failure for a system-critical alert is
# exactly the failure mode we don't want.
# Argument is the message body in Telegram HTML format. Caller is
# responsible for escaping any dynamic content via telegram_html_escape.
send_telegram_alert() {
  local message="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo "Telegram alert skipped (TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set)"
    return 0
  fi
  local -a args=(
    -sS --max-time 10 -X POST
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    -d "chat_id=$TELEGRAM_CHAT_ID"
    -d "parse_mode=HTML"
    --data-urlencode "text=$message"
  )
  if [ -n "$TELEGRAM_THREAD_ID" ]; then
    args+=(-d "message_thread_id=$TELEGRAM_THREAD_ID")
  fi
  # Capture curl output. On non-zero exit, emit a one-line stderr message
  # so the cron job's log carries a breadcrumb for the post-mortem.
  local curl_out curl_rc
  curl_out=$(curl "${args[@]}" 2>&1) || curl_rc=$?
  curl_rc=${curl_rc:-0}
  if [ "$curl_rc" -ne 0 ]; then
    echo "send_telegram_alert: curl failed (rc=$curl_rc): $curl_out" >&2
    return 0  # don't propagate — caller is in an alert path already
  fi
}
