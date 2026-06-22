#!/usr/bin/env bash
# Notify-container CANARY — Melbourne→Sydney, INDEPENDENT alert path.
#
# ─── The invariant this enforces ───────────────────────────────────────────
#   "Sydney's alerting chain can actually deliver."
#   Every cron + watcher on Sydney funnels its alerts through ONE chain:
#       notify container (127.0.0.1:8090) → Telegram Bot API → Nick.
#   That chain cannot announce its OWN death. If Docker is down, the notify
#   container has crashed, or Sydney's egress to api.telegram.org is broken,
#   the alert is POSTed to the corpse and lost — silently. Nick learns Sydney
#   went dark only when he happens to notice. This canary is the outside
#   witness that closes that hole.
#
# ─── System-shape assumptions ──────────────────────────────────────────────
#   1. Melbourne (nick-mel, 130.162.192.233) is always-on, and its cron is
#      healthy. (It already runs oci-instance-watch-melbourne.sh on the same
#      box; if Melbourne itself dies, Sydney's oci-instance-watch.sh catches
#      Melbourne — mutual peer monitoring. So neither box is its own witness.)
#   2. Melbourne can SSH to Sydney as `ubuntu` (the same key the deploy/peer
#      tooling already uses — Mel→Syd reachability is a standing assumption of
#      the peer-watcher fleet).
#   3. Melbourne holds a Telegram bot token DIRECTLY (via
#      /etc/imagineering-secrets/telegram.env, loaded by lib/telegram.sh).
#      This is the crux: the canary must NOT route its alert through the very
#      Sydney notify service it is checking. It talks to api.telegram.org
#      itself. Spreading the bot token is normally an anti-pattern (that's
#      WHY notify exists) — but the one client that may not depend on notify
#      is the client that watches notify. This is the documented exception.
#
# ─── The probe (why three layers, not one TCP check) ───────────────────────
#   A bare "is :8090 open?" or even a GET /health proves only that the HTTP
#   server process is up — /health returns a static {"ok":true} WITHOUT ever
#   touching Telegram. A green /health with a revoked bot token or blocked
#   egress is a FALSE POSITIVE that defeats the entire canary (we'd report
#   "delivery fine" while every real alert silently vanishes). So the probe,
#   run over a single SSH hop to Sydney, layers:
#
#     L1  notify container is RUNNING & Docker-healthy
#         (`docker inspect` .State.Health.Status == healthy)  → process alive
#     L2  notify answers GET /health on 127.0.0.1:8090 → 200   → HTTP serving
#     L3  Telegram getMe succeeds FROM Sydney's network        → egress + token
#         (proves the delivery chain end-to-end WITHOUT sending Nick a message
#          — getMe is read-only; a test /send would spam Telegram every cycle)
#
#   All three must pass for "delivery-capable". L3 is the one that turns this
#   from a liveness check into a DELIVERY check — it is the boundary the whole
#   canary stands for. If SSH itself fails we can't distinguish "Sydney box
#   down" from "Mel→Syd network blip"; we treat repeated SSH failure as a
#   Phase-A trip too (Sydney unreachable from its witness is itself alarming),
#   but debounce so a single flap doesn't fire.
#
# ─── Shape: recurring threshold-alert (NOT self-disabling) ─────────────────
#   A canary that disabled itself after one recovery would stop guarding. So,
#   like email-health-watch.sh, phase_a_check ALWAYS returns 1 — the state
#   machine never advances to DONE, the cron entry is never removed. Alerts
#   debounce to at most one per failure-episode via a sentinel file, and a
#   recovery ✅ fires once when the probe goes green again, then re-arms.
#
# Cron (Melbourne crontab, as user `ubuntu`):
#   47 */2 * * * /home/ubuntu/notify-canary-melbourne.sh  # notify-canary-melbourne
#   (Every 2 hours, off the hour. Offset to :47 — well clear of the Melbourne
#    oci-watcher's :17 — so the two Mel→Syd probes don't fire simultaneously.)

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="notify-canary-melbourne"
# shellcheck disable=SC2034
CRON_TAG="notify-canary-melbourne"

# ── Source the base lib for log()/run_watcher()/state plumbing ─────────────
# NOTE: we deliberately do NOT use the lib's tg() helper — tg() POSTs through
# notify.imagineering.cc, i.e. through the very Sydney service we're checking.
# Our alert path is send_telegram_alert() from lib/telegram.sh, which hits
# api.telegram.org directly with a bot token held on Melbourne.
__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090
source "$__lib"
unset __lib

# ── Source the DIRECT Telegram helper (independent alert path) ─────────────
__tg="$(dirname "$0")/lib/telegram.sh"
[[ -r "$__tg" ]] || __tg="$HOME/lib/telegram.sh"
# shellcheck disable=SC1090
source "$__tg"
unset __tg

# ── Config (override via env if needed) ────────────────────────────────────
SYDNEY_SSH="${SYDNEY_SSH:-149.118.69.221}"      # Sydney public IP
SYDNEY_SSH_USER="${SYDNEY_SSH_USER:-ubuntu}"    # standing peer-fleet user
NOTIFY_CONTAINER="${NOTIFY_CONTAINER:-notify}"  # docker container name
NOTIFY_PORT="${NOTIFY_PORT:-8090}"              # 127.0.0.1-bound on Sydney
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"                # seconds for the whole probe

# Sentinel: present == we are currently in a fired/alerted state. Used to
# debounce (one 🚨 per failure-episode) and to know when to fire the ✅.
ALERT_SENTINEL="$CONFIG_DIR/$WATCHER_NAME.alerted"

# ── alert <html-message> : INDEPENDENT path, never via notify ──────────────
# DRY_RUN=1 logs instead of sending (smoke-testing without Telegram noise).
# We re-implement the DRY_RUN gate here rather than calling tg(), because
# tg() is the notify-routed path we must avoid even in production.
alert() {
    local msg="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "alert [DRY_RUN]: ${msg//$'\n'/ }"
        return 0
    fi
    # send_telegram_alert is a silent no-op if the bot token is unset (e.g.
    # creds not yet installed on Melbourne); it logs to stderr in that case.
    send_telegram_alert "$msg"
    log "alert: dispatched via direct Telegram API (independent of Sydney notify)"
}

# ── probe : runs the 3-layer check over ONE ssh hop. ───────────────────────
# Echoes "OK" on full delivery-capable, or "FAIL:<reason>" otherwise.
# Echoes "UNKNOWN:<reason>" when we genuinely can't tell (don't fire on these
# alone — they're transient until they persist; debounce handles persistence).
probe() {
    # The remote script runs ON Sydney. It must use only tools we know are
    # present there (docker, curl, the bot token via the same secrets file).
    # We read the token from Sydney's own notify env so we don't ship it over
    # the wire — getMe is run with Sydney's container token, proving THAT
    # token + Sydney's egress, which is exactly the chain real alerts use.
    local remote
    # The remote script is a single-quoted heredoc with $NOTIFY_CONTAINER /
    # $NOTIFY_PORT spliced in via the close-single/open-double quote dance
    # ('"'"'"$VAR"'"'"'). Shellcheck can't see across that concatenation
    # boundary and flags SC2016 ("won't expand") — but they DO expand at
    # string-build time. The '\'' sequences are literal apostrophes in remote
    # comments/strings. Both are intended; suppress the false positive.
    # shellcheck disable=SC2016
    remote='
set -euo pipefail
C="'"$NOTIFY_CONTAINER"'"
P="'"$NOTIFY_PORT"'"
# L1: container running + Docker-healthy.
state=$(docker inspect -f "{{.State.Status}}" "$C" 2>/dev/null) || { echo "FAIL:container-absent"; exit 0; }
[ "$state" = "running" ] || { echo "FAIL:container-not-running($state)"; exit 0; }
health=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$C" 2>/dev/null || echo "none")
# "none" == no healthcheck defined; tolerate it (older compose) but L2 still gates.
case "$health" in healthy|none) : ;; *) echo "FAIL:container-unhealthy($health)"; exit 0 ;; esac
# L2: /health answers 200 on the loopback bind.
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${P}/health" 2>/dev/null) || code="000"
[ "$code" = "200" ] || { echo "FAIL:health-http($code)"; exit 0; }
# L3: Telegram getMe FROM Sydney, using the container'\''s own bot token.
# Read the token out of the running container env (never printed/logged here).
tok=$(docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$C" 2>/dev/null | sed -n "s/^TELEGRAM_BOT_TOKEN=//p")
[ -n "$tok" ] || { echo "UNKNOWN:no-token-in-container-env"; exit 0; }
gm=$(curl -s --max-time 8 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null) || { echo "FAIL:telegram-egress"; exit 0; }
case "$gm" in *'\''"ok":true'\''*) echo "OK" ;; *) echo "FAIL:telegram-getme-rejected" ;; esac
'
    local out
    if ! out=$(ssh \
            -o BatchMode=yes \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
            "${SYDNEY_SSH_USER}@${SYDNEY_SSH}" \
            "bash -s" <<< "$remote" 2>/dev/null); then
        # SSH itself failed: Sydney unreachable from its witness. Alarming, but
        # could be a Mel→Syd network blip — surface as UNKNOWN; debounce +
        # episode-persistence (sentinel) decides whether to escalate.
        echo "UNKNOWN:ssh-unreachable"
        return 0
    fi
    # Guard against an empty echo (e.g. remote bash died before printing).
    [[ -n "$out" ]] && echo "$out" || echo "UNKNOWN:empty-probe-output"
}

# Escalation policy: a single UNKNOWN (transient blip) does NOT fire; a second
# consecutive UNKNOWN is treated as a real failure (the blip persisted). FAIL
# fires immediately. We track consecutive-unknown count in a tiny state file.
UNKNOWN_STREAK_FILE="$CONFIG_DIR/$WATCHER_NAME.unknown-streak"

phase_a_check() {
    local result reason
    result=$(probe)
    log "probe: $result"

    case "$result" in
        OK)
            rm -f "$UNKNOWN_STREAK_FILE"
            # Recovery: if we had previously alerted, fire ✅ once and re-arm.
            if [[ -f "$ALERT_SENTINEL" ]]; then
                alert '✅ <b>Sydney notify delivery RESTORED</b> (Melbourne canary)

The notify alerting chain (container → Telegram) is delivery-capable again. Sydney crons can alert Nick once more.'
                rm -f "$ALERT_SENTINEL"
            fi
            return 1   # recurring watcher: never advance to DONE
            ;;
        FAIL:*)
            reason="${result#FAIL:}"
            rm -f "$UNKNOWN_STREAK_FILE"
            _fire_failure "$reason"
            return 1
            ;;
        UNKNOWN:*)
            reason="${result#UNKNOWN:}"
            local streak
            streak=$(cat "$UNKNOWN_STREAK_FILE" 2>/dev/null || echo 0)
            streak=$(( streak + 1 ))
            echo "$streak" > "$UNKNOWN_STREAK_FILE"
            if (( streak >= 2 )); then
                _fire_failure "persistent-$reason (x$streak)"
            else
                log "UNKNOWN streak=$streak; one more before escalating ($reason)"
            fi
            return 1
            ;;
        *)
            log "probe returned unrecognized result: $result"
            return 1
            ;;
    esac
}

# _fire_failure <reason> : fire 🚨 ONCE per failure-episode (debounced by the
# sentinel), via the INDEPENDENT Telegram path. Escapes the dynamic reason.
_fire_failure() {
    local reason esc
    reason="$1"
    if [[ -f "$ALERT_SENTINEL" ]]; then
        log "failure persists ($reason); already alerted this episode — debounced"
        return 0
    fi
    esc=$(telegram_html_escape "$reason")
    alert "$(printf '🚨 <b>Sydney notify chain CANNOT DELIVER</b> (Melbourne canary)

Probe result: <code>%s</code>

This is the path EVERY Sydney cron/watcher alert flows through (notify container → Telegram). It is down, so Sydney alerts are being silently lost. This message reached you via Melbourne'\''s INDEPENDENT Telegram path. Check Sydney: <code>ssh %s@%s</code> then <code>docker ps | grep %s</code>.' \
        "$esc" "$SYDNEY_SSH_USER" "$SYDNEY_SSH" "$NOTIFY_CONTAINER")"
    touch "$ALERT_SENTINEL"
}

# Recurring watcher: phase B is never reached (A never returns 0). Present to
# satisfy the run_watcher() contract.
phase_b_check() {
    return 1
}

run_watcher
