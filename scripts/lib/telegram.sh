#!/bin/bash
# Shared alert helper, sourced by infra cron scripts.
#
# Provides:
#   telegram_html_escape <string>      -> echoes input with &, <, > escaped for HTML mode
#   send_telegram_alert <html_message> -> POST to the notify proxy with parse_mode=HTML
#
# Alerts are delivered via the local notify service (the `notify` container
# on 127.0.0.1:8090, publicly notify.imagineering.cc), which forwards to
# Telegram with its own bot token. This replaced direct Telegram Bot API
# calls as gremlin_xdeca_bot: that bot is muted in its target group (status
# "restricted", can_send_messages=false), so every alert was silently
# dropped (claude-tasks#441). Routing through notify gives crons the same
# alert path the watcher fleet already uses, landing in Nick's personal
# chat.
#
# The default NOTIFY_URL is deliberately the LOCAL listener, not the public
# Caddy-fronted hostname: health-check alerts fire precisely when Caddy or
# containers are down, so the alert path must not depend on Caddy.
#
# Configuration: NOTIFY_API_KEY (required), NOTIFY_URL (optional, defaults
# to the local listener). If not already in the environment, this lib tries
# to source /etc/downstream-secrets/notify.env (root:nick 0640) so the key
# never has to be inlined into world-readable cron entries.
#
# Silent no-op if creds are missing — a missing-secret deploy shouldn't turn
# every cron into a stderr spammer.
#
# Why HTML, not MarkdownV2: MarkdownV2 requires escaping ~16 punctuation
# characters in *all* text (including dynamic data). One stray dot or paren
# from a stack frame breaks the message and Telegram silently 400s exactly
# when we most need the alert. HTML mode requires escaping only `&`, `<`,
# `>` — much smaller failure surface.

# Source the secrets file if present and the key isn't already set.
# Done at source-time, not at function-call-time, so each script only pays
# the cost once (and behavior is predictable in `set -u` consumers).
if [ -z "${NOTIFY_API_KEY:-}" ] && [ -r /etc/downstream-secrets/notify.env ]; then
  # shellcheck disable=SC1091
  . /etc/downstream-secrets/notify.env
fi

# Default exports so consumers can use `${VAR:-}` or `set -u` safely.
NOTIFY_API_KEY="${NOTIFY_API_KEY:-}"
NOTIFY_URL="${NOTIFY_URL:-http://127.0.0.1:8090}"

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

# Escape a string for embedding inside a JSON string literal. Pure bash +
# tr (no jq dependency — this runs from cron, where a missing binary would
# silently kill the alert path). Handles the characters that realistically
# appear in alert text: backslash, double-quote, newline, carriage return,
# tab. Any remaining ASCII control chars (rare — e.g. from a binary log
# tail) are stripped rather than \u-encoded: losing an unprintable byte
# from an alert is fine; breaking the JSON is not.
notify_json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Send an alert via the notify proxy. Silent no-op if creds are not
# configured (the common dev/test path); but if creds ARE present and the
# send fails, log to stderr — a silent communication failure for a
# system-critical alert is exactly the failure mode we don't want.
# Argument is the message body in Telegram HTML format. Caller is
# responsible for escaping any dynamic content via telegram_html_escape.
send_telegram_alert() {
  local message="$1"
  if [ -z "$NOTIFY_API_KEY" ]; then
    echo "Telegram alert skipped (NOTIFY_API_KEY not set)"
    return 0
  fi
  local payload
  payload=$(printf '{"message": "%s", "parse_mode": "HTML"}' \
    "$(notify_json_escape "$message")")
  # Capture curl output. On non-zero exit, emit a one-line stderr message
  # so the cron job's log carries a breadcrumb for the post-mortem.
  local curl_out curl_rc
  curl_out=$(curl -sS --max-time 10 -X POST "$NOTIFY_URL/send" \
    -H "Authorization: Bearer $NOTIFY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1) || curl_rc=$?
  curl_rc=${curl_rc:-0}
  if [ "$curl_rc" -ne 0 ]; then
    echo "send_telegram_alert: curl failed (rc=$curl_rc): $curl_out" >&2
    return 0  # don't propagate — caller is in an alert path already
  fi
  # curl exits 0 for an HTTP 4xx/5xx too (it got *a* response), so a
  # rejection — bad API key, or a Telegram-side refusal relayed by notify —
  # comes back with rc=0 and would otherwise pass silently. That is the
  # exact silent-drop failure mode this alert path exists to avoid, so
  # inspect the response body. notify relays Telegram's response verbatim
  # on success, and Python's json.dumps puts a space after the colon, so
  # match both spellings. (Plain glob, no jq dependency.)
  case "$curl_out" in
    *'"ok": true'* | *'"ok":true'*) : ;;  # delivered to Telegram
    *)
      echo "send_telegram_alert: notify rejected the message (rc=0): $curl_out" >&2
      return 0  # still don't propagate — caller is already in an alert path
      ;;
  esac
}
