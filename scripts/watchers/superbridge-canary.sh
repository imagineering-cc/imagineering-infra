#!/usr/bin/env bash
# Superbridge fan-out CANARY — watches that River's hub reaches every platform.
#
# ─── The invariant this enforces ───────────────────────────────────────────
#   "A message posted to the #imagineering hub can still fan out to every
#    bridged platform group."
#   River's weekly event reminder (Sat 14:55 Melbourne) posts ONE message to
#   the Matrix hub room (!SNO2v77SDkrFKxUGFw). The `relay-bot` appservice then
#   mirrors it into each configured PORTAL room, and each portal's mautrix
#   bridge delivers it onward to the real platform group (Signal, WhatsApp,
#   …). NOTHING monitors that chain. If relay-bot leaves/gets kicked from a
#   portal, or a platform's bridge bot drops out, the reminder silently
#   reaches FEWER platforms (or zero) and no alert fires — the failure is
#   invisible until a human in that group notices the reminder never came.
#   This canary is the outside witness for that chain.
#
# ─── What it ACTUALLY verifies (boundary honesty — read this) ───────────────
#   This is a LIVENESS check, NOT a true end-to-end PROPAGATION check. It
#   proves every ACTOR in the fan-out chain is present and joined; it does
#   NOT prove that a specific hub message physically arrived in each platform
#   group. Concretely, per portal room it confirms (via the Matrix
#   client-server API, posting NO message):
#
#     L2  @relay-bot is joined to the hub AND to each portal room
#         → the fan-out PRODUCER is in place. If relay-bot left a portal,
#           that platform's fan-out is dead.
#     L3  the portal's platform BRIDGE BOT is joined to that portal room
#         (e.g. @signalbot in the Signal portal, @whatsappbot in the WhatsApp
#         portal) → the last-hop DELIVERER is in place. If the bridge bot
#         dropped out, messages reach the portal room but never the platform.
#
#   The boundary it does NOT cover:
#     • A bridge PROCESS that has crashed but whose bot user is still "joined"
#       in Matrix room state would PASS L3 (membership is sticky; liveness is
#       not). A message dropped at the platform API (rate-limit, session
#       expiry) is also invisible here.
#     • True propagation (did THIS hub event produce a relayed event in each
#       portal?) is recorded only in the relay-bot's SQLite event-map
#       (`/data/relay.db` in the relay_data volume on Sydney) and is NOT
#       exposed over the Matrix API. A DB-backed L4 propagation check is the
#       stronger follow-up — see DEFERRED at the bottom of this file.
#
#   So: this catches the MOST LIKELY silent-death modes (relay-bot or a bridge
#   bot leaving a room) cheaply and non-intrusively, and is explicit that it is
#   a liveness proxy, not a delivery proof.
#
# ─── Why non-intrusive (the design decision, stated) ───────────────────────
#   A canary that posted a visible sentinel to the real hub every cycle would
#   fan out to the REAL Signal/WhatsApp community groups — real humans would
#   see canary spam on every run. That is unacceptable for a frequent check.
#   The membership probe needs NO posted message: it reads room state over the
#   C-S API. So we get a useful, recurring, zero-noise canary. The price is
#   that it's liveness, not propagation (see above) — a named, accepted
#   tradeoff, not a silent one.
#
# ─── Config is DISCOVERED, never hardcoded ─────────────────────────────────
#   The set of portal rooms (and thus which platforms exist) is the relay-bot's
#   RELAY_PORTAL_ROOMS env — currently Signal + WhatsApp ONLY (not Telegram /
#   Discord, despite how the fan-out is often described). Hardcoding a platform
#   list would make the canary lie the moment a portal is added/removed. So the
#   probe reads the LIVE RELAY_PORTAL_ROOMS + RELAY_HUB_ROOM_ID straight off the
#   running relay-bot container (one `docker inspect`), and checks exactly the
#   rooms that are actually configured. If that read fails, it falls back to
#   PORTAL_ROOMS / HUB_ROOM_ID from this script's env/cred file.
#
# ─── Shape: recurring threshold-alert (NOT self-disabling) ─────────────────
#   A canary that disabled itself after one recovery would stop guarding. Like
#   email-health-watch.sh and notify-canary-melbourne.sh, phase_a_check ALWAYS
#   returns 1 — the state machine never advances to DONE, the cron entry is
#   never removed. Alerts debounce to at most one 🚨 per failure-episode via a
#   sentinel file; a recovery ✅ fires once when the probe goes green again,
#   then re-arms. A single transient/UNKNOWN result does not fire; a second
#   consecutive UNKNOWN does (a blip that persisted).
#
# ─── Alert path ────────────────────────────────────────────────────────────
#   Via the normal notify proxy (tg() from watcher-base.sh). Unlike
#   notify-canary-melbourne.sh — which must AVOID notify because it watches
#   notify itself — this canary watches the Matrix fan-out, which is
#   independent of the notify chain, so routing through notify is correct.
#   (If notify itself is down, notify-canary-melbourne.sh is the witness for
#   THAT — separation of concerns: each canary watches a different chain.)
#
# ─── Credentials ───────────────────────────────────────────────────────────
#   Needs a Matrix access token with permission to read room membership of the
#   hub + portal rooms. Sourced as MATRIX_CANARY_TOKEN from
#   ~/.config/imagineering/superbridge-canary-credentials (mode 0600), mirroring
#   the brevo-credentials pattern. See the OPSEC note in the install block:
#   prefer a dedicated read-only bot account over reusing @nick's admin token.
#   If the token is absent, the watcher logs and skips (never crashes cron).
#
# Cron (Sydney crontab, as user `ubuntu`):
#   37 */2 * * * /home/ubuntu/superbridge-canary.sh  # superbridge-canary
#   (Every 2 hours, off the hour. :37 is clear of the other Sydney watchers'
#    slots — cert :00/6h, oci :13, email :23/4h, kanbn :41 — so probes don't
#    bunch up.)

set -euo pipefail

# shellcheck disable=SC2034  # consumed by watcher-base.sh after sourcing
WATCHER_NAME="superbridge-canary"
# shellcheck disable=SC2034
CRON_TAG="superbridge-canary"

# ── Source the base lib (log/tg/run_watcher/state plumbing) ────────────────
__lib="$(dirname "$0")/lib/watcher-base.sh"
[[ -r "$__lib" ]] || __lib="$HOME/lib/watcher-base.sh"
# shellcheck disable=SC1090  # dynamic path; resolved at runtime
source "$__lib"
unset __lib

# html_escape — only escapes &, <, > for HTML-mode notify. Inlined (rather than
# sourcing lib/diagnose.sh) so the install footprint stays watcher-base.sh +
# this file, matching email-health-watch.sh's choice.
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# ── Config (override via env / cred file if needed) ────────────────────────
MATRIX_HS="${MATRIX_HS:-https://matrix.imagineering.cc}"   # public C-S API base
SYDNEY_SSH="${SYDNEY_SSH:-149.118.69.221}"                 # Sydney public IP
SYDNEY_SSH_USER="${SYDNEY_SSH_USER:-ubuntu}"
RELAY_CONTAINER="${RELAY_CONTAINER:-relay-bot}"            # docker container name
SSH_TIMEOUT="${SSH_TIMEOUT:-20}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-10}"

# Fallback hub/portals if live discovery fails (kept in sync with
# matrix/secrets.yaml; the LIVE value from the running container wins).
# Format mirrors RELAY_PORTAL_ROOMS: "!room:domain=Label,!room2:domain=Label2".
HUB_ROOM_ID="${HUB_ROOM_ID:-!SNO2v77SDkrFKxUGFw:imagineering.cc}"
PORTAL_ROOMS="${PORTAL_ROOMS:-!9eXl0FqjRzex8vFTgP:imagineering.cc=Signal,!BsUvdWLywaqtOCfGv7:imagineering.cc=WhatsApp}"

# The relay-bot's own MXID (the fan-out producer we check for in every room).
RELAY_BOT_MXID="${RELAY_BOT_MXID:-@relay-bot:imagineering.cc}"

# Per-platform bridge-bot MXID (the last-hop deliverer). The portal LABEL
# (lowercased) selects the entry, e.g. Signal -> @signalbot, WhatsApp ->
# @whatsappbot. Override the whole map via BRIDGE_BOTS env if MXIDs differ.
#   format: "label=@mxid;label2=@mxid2"
BRIDGE_BOTS="${BRIDGE_BOTS:-signal=@signalbot:imagineering.cc;whatsapp=@whatsappbot:imagineering.cc;telegram=@telegrambot:imagineering.cc;discord=@discordbot:imagineering.cc}"

# Credentials: a 0600 env file exporting MATRIX_CANARY_TOKEN, mirroring the
# notify-credentials / brevo-credentials sourcing convention.
SBC_CRED_FILE="$CONFIG_DIR/superbridge-canary-credentials"
# shellcheck source=/dev/null
[[ -r "$SBC_CRED_FILE" ]] && { set -a; . "$SBC_CRED_FILE"; set +a; }

# Sentinel: present == currently in a fired/alerted state (episode debounce +
# recovery signal). UNKNOWN streak file gates transient-blip escalation.
ALERT_SENTINEL="$CONFIG_DIR/$WATCHER_NAME.alerted"
UNKNOWN_STREAK_FILE="$CONFIG_DIR/$WATCHER_NAME.unknown-streak"

# ── Helpers ────────────────────────────────────────────────────────────────

# urlenc <string> — percent-encode a Matrix room ID for use in a URL path.
urlenc() {
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# _lc <string> — lowercase, portable to bash 3.2 (macOS' bundled bash lacks
# the ${var,,} expansion; the target box has bash 4+, but tr works on both).
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# bridge_bot_for <label> — echo the bridge-bot MXID for a portal label, or ""
# if the label has no configured bridge bot (then L3 is skipped for it).
bridge_bot_for() {
    local want entry k v
    want=$(_lc "$1")
    local IFS=';'
    for entry in $BRIDGE_BOTS; do
        k="${entry%%=*}"; v="${entry#*=}"
        if [[ "$(_lc "$k")" == "$want" ]]; then
            printf '%s' "$v"
            return 0
        fi
    done
    printf ''
}

# discover_config — read the LIVE RELAY_PORTAL_ROOMS + RELAY_HUB_ROOM_ID off the
# running relay-bot container (source of truth). On any failure, leaves the
# fallback HUB_ROOM_ID / PORTAL_ROOMS untouched and logs that it fell back.
# Sets globals HUB_ROOM_ID and PORTAL_ROOMS.
discover_config() {
    local out hub portals
    # One SSH hop; read the two env vars out of the container config. We never
    # print tokens here — only the room-ID env vars, which are non-secret.
    # shellcheck disable=SC2029  # RELAY_CONTAINER intentionally expands locally
    if ! out=$(ssh \
            -o BatchMode=yes \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
            "${SYDNEY_SSH_USER}@${SYDNEY_SSH}" \
            "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' '$RELAY_CONTAINER' 2>/dev/null" \
            2>/dev/null); then
        log "discover_config: ssh/docker inspect failed; using fallback hub/portals"
        return 0
    fi
    hub=$(sed -n 's/^RELAY_HUB_ROOM_ID=//p' <<< "$out" | head -n1)
    portals=$(sed -n 's/^RELAY_PORTAL_ROOMS=//p' <<< "$out" | head -n1)
    if [[ -n "$hub" ]]; then
        HUB_ROOM_ID="$hub"
    else
        log "discover_config: RELAY_HUB_ROOM_ID empty in container env; keeping fallback"
    fi
    if [[ -n "$portals" ]]; then
        PORTAL_ROOMS="$portals"
        log "discover_config: live portals = $PORTAL_ROOMS"
    else
        log "discover_config: RELAY_PORTAL_ROOMS empty in container env; keeping fallback"
    fi
}

# is_joined <room_id> <mxid> — via C-S API joined_members, echo:
#   "yes"            mxid is joined to the room
#   "no"             mxid is NOT joined (room read OK, member absent)
#   "unknown:<why>"  could not determine (HTTP error, token bad, parse fail)
is_joined() {
    local room="$1" mxid="$2" enc body http
    enc=$(urlenc "$room")
    body=$(curl -sS --max-time "$HTTP_TIMEOUT" -w $'\n%{http_code}' \
        "${MATRIX_HS}/_matrix/client/v3/rooms/${enc}/joined_members" \
        -H "Authorization: Bearer ${MATRIX_CANARY_TOKEN}" 2>/dev/null) \
        || { echo "unknown:http-transport"; return 0; }
    http="${body##*$'\n'}"
    body="${body%$'\n'*}"
    if [[ "$http" != 2* ]]; then
        echo "unknown:http-$http"
        return 0
    fi
    # Membership test in python (robust against missing keys / odd JSON).
    MXID="$mxid" python3 -c '
import json, os, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("unknown:parse"); sys.exit(0)
joined = d.get("joined")
if not isinstance(joined, dict):
    print("unknown:no-joined-key"); sys.exit(0)
print("yes" if os.environ["MXID"] in joined else "no")
' <<< "$body"
}

# ── probe : runs the membership checks over the C-S API (no message posted) ──
# Echoes "OK", or "FAIL:<reason>", or "UNKNOWN:<reason>". Reasons are
# pipe-joined so a single 🚨 can list every dead leg at once.
probe() {
    if [[ -z "${MATRIX_CANARY_TOKEN:-}" ]]; then
        echo "UNKNOWN:no-token (missing $SBC_CRED_FILE?)"
        return 0
    fi

    discover_config

    local fails="" unknowns="" r

    # L2a: relay-bot joined to the HUB room (the fan-out source).
    r=$(is_joined "$HUB_ROOM_ID" "$RELAY_BOT_MXID")
    case "$r" in
        yes) : ;;
        no)  fails="${fails}${fails:+ | }hub:relay-bot-NOT-joined" ;;
        unknown:*) unknowns="${unknowns}${unknowns:+ | }hub:${r#unknown:}" ;;
    esac

    # For each configured portal: L2b relay-bot joined + L3 bridge-bot joined.
    local IFS=','
    local entry rid label bot
    for entry in $PORTAL_ROOMS; do
        entry="${entry// /}"
        [[ -z "$entry" ]] && continue
        rid="${entry%%=*}"
        label="${entry##*=}"
        [[ -z "$rid" || -z "$label" || "$rid" == "$entry" ]] && {
            unknowns="${unknowns}${unknowns:+ | }portal-parse:'$entry'"
            continue
        }

        # L2b: relay-bot present in this portal.
        r=$(is_joined "$rid" "$RELAY_BOT_MXID")
        case "$r" in
            yes) : ;;
            no)  fails="${fails}${fails:+ | }${label}:relay-bot-NOT-joined" ;;
            unknown:*) unknowns="${unknowns}${unknowns:+ | }${label}/relay:${r#unknown:}" ;;
        esac

        # L3: platform bridge bot present in this portal (last-hop deliverer).
        bot=$(bridge_bot_for "$label")
        if [[ -z "$bot" ]]; then
            log "probe: no bridge bot configured for label '$label'; skipping L3"
        else
            r=$(is_joined "$rid" "$bot")
            case "$r" in
                yes) : ;;
                no)  fails="${fails}${fails:+ | }${label}:bridge-bot($bot)-NOT-joined" ;;
                unknown:*) unknowns="${unknowns}${unknowns:+ | }${label}/bridge:${r#unknown:}" ;;
            esac
        fi
    done
    unset IFS

    if [[ -n "$fails" ]]; then
        # A confirmed missing actor is a real failure regardless of any
        # concurrent UNKNOWNs — report the FAILs (the actionable part).
        echo "FAIL:$fails"
    elif [[ -n "$unknowns" ]]; then
        echo "UNKNOWN:$unknowns"
    else
        echo "OK"
    fi
}

# ── State-machine glue (recurring; never advances to DONE) ─────────────────
phase_a_check() {
    local result reason
    result=$(probe)
    log "probe: $result"

    case "$result" in
        OK)
            rm -f "$UNKNOWN_STREAK_FILE"
            if [[ -f "$ALERT_SENTINEL" ]]; then
                tg '✅ <b>Superbridge fan-out RESTORED</b> (Sydney canary)

Every relay-bot + bridge-bot is joined to the hub and all portal rooms again. River&#39;s hub posts can fan out to every platform.'
                rm -f "$ALERT_SENTINEL"
            fi
            return 1
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
                _fire_failure "persistent — $reason (x$streak)"
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

# _fire_failure <reason> — fire 🚨 ONCE per failure-episode (sentinel-debounced),
# via the notify proxy. Escapes the dynamic reason for HTML mode.
_fire_failure() {
    local reason esc
    reason="$1"
    if [[ -f "$ALERT_SENTINEL" ]]; then
        log "failure persists ($reason); already alerted this episode — debounced"
        return 0
    fi
    esc=$(html_escape "$reason")
    tg "$(printf '🚨 <b>Superbridge fan-out DEGRADED</b> (Sydney canary)

A relay-bot or platform bridge bot has left the hub or a portal room, so River&#39;s weekly event reminder will reach FEWER platforms (or none) — silently.

Dead leg(s):
<pre>%s</pre>
This is a LIVENESS check (membership), not a delivery proof. Investigate on Sydney: <code>ssh %s@%s</code> then <code>docker logs --tail 100 %s</code> and check the bridge containers.' \
        "$esc" "$SYDNEY_SSH_USER" "$SYDNEY_SSH" "$RELAY_CONTAINER")"
    touch "$ALERT_SENTINEL"
}

# Recurring watcher: phase B is never reached (A never returns 0). Present to
# satisfy the run_watcher() contract.
phase_b_check() {
    return 1
}

run_watcher

# ─── DEFERRED: true end-to-end propagation check (L4) ───────────────────────
# This canary proves LIVENESS (actors joined), not PROPAGATION (a specific hub
# message reached each platform). The stronger check needs the relay-bot's
# event-map DB, which records (source_event_id -> target_event_id) per portal
# ONLY when the relay's portal post succeeded:
#
#   ssh ubuntu@149.118.69.221 \
#     'docker exec relay-bot sqlite3 /data/relay.db \
#        "SELECT room_id, COUNT(*) FROM event_group_events
#           WHERE created_at > strftime(%s,\"now\",\"-1 day\")
#         GROUP BY room_id;"'
#
# After River's Saturday reminder, every configured portal room should show a
# fresh row for that event group. Absence of a portal row == fan-out to that
# platform failed at relay time. This still does NOT cover the portal->bridge->
# platform last hop (not observable from Matrix or the relay DB). A complete
# e2e check would post a clearly-labelled sentinel to a DEDICATED canary room
# bridged to throwaway test groups (no human audience) and confirm arrival on
# each platform — built only if liveness proves insufficient in practice.
