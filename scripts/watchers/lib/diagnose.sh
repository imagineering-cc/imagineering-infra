#!/usr/bin/env bash
# Diagnostic helpers for watcher alerts. Sourced by individual watchers
# alongside watcher-base.sh — provides shared "what's nearby" probes
# that enrich tg() messages without changing the alerting state machine.
#
# Design rule: every helper here must
#   1. Run as the cron-owning user (typically `ubuntu` on Sydney) without
#      sudo, docker-group membership, or any new privilege.
#   2. Time out promptly on hangs (network probes get --max-time; shell
#      probes use timeout if needed).
#   3. Return a short-ish HTML-safe string suitable for inclusion in a
#      Telegram <pre> block. Telegram's hard cap is 4096 chars per
#      message; helpers here aim for <500 each so callers can compose
#      multiple without truncating the primary alert body.
#   4. Never abort the watcher run. On probe failure, return a placeholder
#      string like "(probe failed: <reason>)" — the watcher should still
#      fire its alert with whatever diagnostic data is available.
#
# Helpers:
#   top_files <dir> [count=3]
#       List the largest single regular files under <dir> (one level deep
#       only — find won't descend, to keep latency bounded). Output is
#       human-readable: "<size> <path>" per line. Useful when "top dirs"
#       isn't enough — e.g. one runaway log file inside a noisy dir.
#
#   acme_probe
#       Quick reachability check for Let's Encrypt's ACME v2 directory.
#       Distinguishes "Caddy can't reach Let's Encrypt" from "Caddy
#       reaching it but failing." Returns first line of the HTTP response
#       (e.g. "HTTP/2 200") or "(unreachable: <reason>)".
#
#   github_release_notes <owner/repo> <tag> [maxlen=500]
#       Fetch the body of a GitHub release and return up to <maxlen>
#       chars, with HTML-safe escaping. Returns "(no release notes)" if
#       the tag isn't tied to a Release (only a tag), and "(API error:
#       <code>)" on HTTP error. Uses unauthenticated GitHub API — caller
#       should be tolerant of rate-limit failures.
#
#   html_escape <text>
#       Replace <, >, & for safe inclusion in Telegram HTML messages.
#       Quotes are intentionally not escaped — Telegram's HTML mode
#       doesn't treat them as special, and escaping them produces ugly
#       &quot; renders.

# Note: this lib intentionally does NOT `set -euo pipefail`. It expects to
# be sourced into a watcher script that already has those set, and helpers
# here use defensive fallbacks rather than letting the watcher die on a
# probe-side failure.

# top_files <dir> [count]
top_files() {
    local dir="$1" count="${2:-3}"
    if [[ ! -d "$dir" ]]; then
        echo "(top_files: $dir not a directory)"
        return 0
    fi
    # find -maxdepth 1 keeps latency bounded; we only want immediately-
    # visible files, not a recursive scan.
    find "$dir" -maxdepth 1 -type f -printf '%s %p\n' 2>/dev/null \
        | sort -rn \
        | head -n "$count" \
        | awk '{ size=$1; $1=""; sub(/^ /,""); printf "  %s  %s\n", human(size), $0 }
               function human(b,   u, i) {
                   u="BKMGT"; i=1
                   while (b >= 1024 && i < length(u)) { b /= 1024; i++ }
                   return sprintf("%6.1f%s", b, substr(u,i,1))
               }'
}

# acme_probe
acme_probe() {
    local out
    out=$(curl -sSI --max-time 5 https://acme-v02.api.letsencrypt.org/directory 2>&1) \
        || { echo "(unreachable: ${out:-curl error})"; return 0; }
    head -1 <<< "$out" | tr -d '\r'
}

# github_release_notes <owner/repo> <tag> [maxlen]
github_release_notes() {
    local repo="$1" tag="$2" maxlen="${3:-500}"
    local resp http_code body
    resp=$(curl -sS --max-time 10 -w '\n%{http_code}' \
            "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>&1) \
        || { echo "(release notes fetch failed)"; return 0; }
    http_code=$(tail -n1 <<< "$resp")
    body=$(sed '$d' <<< "$resp")
    case "$http_code" in
        200) ;;
        404) echo "(no release notes — tag exists but no GitHub Release)"; return 0 ;;
        *)   echo "(API error: $http_code)"; return 0 ;;
    esac
    local notes
    notes=$(jq -r '.body // ""' <<< "$body" 2>/dev/null)
    if [[ -z "$notes" ]]; then
        echo "(release has no body)"
        return 0
    fi
    # Truncate to maxlen, append "…" if cut. Then html-escape.
    if [[ "${#notes}" -gt "$maxlen" ]]; then
        notes="${notes:0:$maxlen}…"
    fi
    html_escape "$notes"
}

# html_escape <text>
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# strip_ansi
#   Reads stdin, writes stdout with ANSI color/SGR escape sequences
#   removed. Useful for log files that contain shell color codes
#   (backup.log uses them) before inclusion in a Telegram <pre> block.
strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# --- sudo-wrapper helpers ----------------------------------------------------
# These call read-only wrapper scripts at /usr/local/bin/watcher-diag-*,
# whitelisted via /etc/sudoers.d/watcher-diag for NOPASSWD. The wrappers
# live in scripts/watchers/sudo-helpers/ in the repo. If sudo isn't
# available or the wrapper is missing, helpers fail-soft with a clear
# placeholder so the watcher still fires its primary alert.

# tail_backup_log
#   Last 50 lines of /home/nick/logs/backup.log, ANSI-stripped.
#   Distinguishes "backup ran but failed" from "backup never started" —
#   the most useful single addition to backup-recency alerts.
tail_backup_log() {
    if ! sudo -n -l /usr/local/bin/watcher-diag-backup-tail >/dev/null 2>&1; then
        echo "(no sudoers entry for watcher-diag-backup-tail — see scripts/watchers/sudo-helpers/README.md)"
        return 0
    fi
    sudo -n /usr/local/bin/watcher-diag-backup-tail 2>&1 | strip_ansi | tail -20
}

# docker_df_summary
#   `docker system df` formatted as TYPE/TOTAL/SIZE/RECLAIMABLE table.
#   Surfaces "disk full because of docker bloat" cases, which the
#   filesystem-level top_dirs/top_files probes hide (everything's in
#   /var/lib/docker/overlay2 and looks like one giant blob).
docker_df_summary() {
    if ! sudo -n -l /usr/local/bin/watcher-diag-docker-df >/dev/null 2>&1; then
        echo "(no sudoers entry for watcher-diag-docker-df)"
        return 0
    fi
    sudo -n /usr/local/bin/watcher-diag-docker-df 2>&1 | head -10
}

# caddy_renew_log
#   Last ~10 cert/renewal-related lines from caddy container logs. Tells
#   you whether Caddy thinks renewal is happening (and what failed if
#   anything), without an ssh round-trip.
caddy_renew_log() {
    if ! sudo -n -l /usr/local/bin/watcher-diag-caddy-logs >/dev/null 2>&1; then
        echo "(no sudoers entry for watcher-diag-caddy-logs)"
        return 0
    fi
    # Filter to ACME/cert-related lines specifically. The generic 'error'
    # keyword is intentionally excluded — Caddy logs every 502 to a backend
    # as "error", and those are not cert problems. ACME-related Caddy
    # logs are reliably tagged with cert/renew/acme/issuance/tls.cache.
    local out
    out=$(sudo -n /usr/local/bin/watcher-diag-caddy-logs 2>&1 \
          | grep -iE 'cert|renew|acme|issuance|tls\.cache' \
          | tail -10) || true
    if [[ -z "$out" ]]; then
        echo "(no cert/renew/acme/issuance/tls.cache lines in last 100 caddy log lines)"
    else
        echo "$out"
    fi
}
