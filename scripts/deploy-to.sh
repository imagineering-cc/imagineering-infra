#!/bin/bash
# Deploy services to any VPS
# Usage: ./scripts/deploy-to.sh <ip> [service]
# Services: all, caddy, site, outline, kanbn, radicale, matrix, imagineering-contact-us, claudius, backups, scripts

set -e

# SOPS age key location
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

if [ -z "$1" ]; then
  echo "Usage: $0 <ip> [service]"
  echo "  ip: VPS IP address or hostname"
  echo "  service: all|caddy|site|invite|galaxy|outline|kanbn|radicale|matrix|claudius|imagineering-contact-us|backups|scripts (default: all)"
  exit 1
fi

IP=$1
SERVICE=${2:-all}
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="nick@$IP"

# ---------------------------------------------------------------------------
# Secret-safe value quoting helpers (defense-in-depth).
#
# Generated config files interpolate decrypted secrets. A secret containing
# shell- or YAML-significant bytes (quotes, $, #, &, /, \, whitespace,
# newlines) must not corrupt the file or inject into the consumer. Two
# consumers, two quoting regimes:
#
#   shell_env_line  — for envfiles consumed by bash `source`/`.`
#                     (e.g. /etc/imagineering-secrets/telegram.env via
#                     lib/telegram.sh, /etc/imagineering-secrets/matrix.env
#                     via backup.sh). Uses printf %q so the line re-evaluates
#                     to the exact original bytes when sourced.
#
#   dotenv_quote    — for `.env` files consumed by docker compose's compose-go
#                     dotenv parser. Wraps in double quotes and escapes the
#                     four bytes that parser treats specially inside a
#                     double-quoted value: \  "  $  and a literal newline.
#                     Verified to round-trip to the actual container runtime.
#
# Both verified byte-exact against an adversarial value containing
# `" $ # & / \` backtick, whitespace and a newline (see scripts/test-secret-quoting.sh).
# ---------------------------------------------------------------------------

# Emit a `KEY=<quoted-value>` line safe for a bash-sourced envfile.
# Usage: shell_env_line KEY "$value"  -> prints the full line (no trailing newline added by caller's printf needed)
shell_env_line() {
    # %q renders the value in a form that bash re-reads as the identical bytes.
    printf '%s=%q\n' "$1" "$2"
}

# Quote a single value for a docker-compose dotenv file (double-quoted form).
# Usage: dotenv_quote "$value"  -> prints `"...escaped..."`
dotenv_quote() {
    local v=$1
    v=${v//\\/\\\\}      # backslash first: \  -> \\
    v=${v//\"/\\\"}      # "  -> \"
    v=${v//\$/\\\$}      # $  -> \$   (suppress compose variable interpolation)
    v=${v//$'\n'/\\n}    # literal newline -> \n escape
    printf '"%s"' "$v"
}

echo "Deploying to $REMOTE..."

deploy_scripts() {
    echo "Deploying scripts..."
    ssh "$REMOTE" "sudo mkdir -p /opt/scripts /opt/scripts/lib"
    rsync -avz "$REPO_ROOT/scripts/" "$REMOTE":/tmp/scripts/
    # Move scripts into place. `cp -r` first so the lib/ subdir lands too,
    # then chmod +x only the top-level *.sh (the lib is sourced, not run).
    ssh "$REMOTE" "sudo cp -r /tmp/scripts/. /opt/scripts/ && sudo chmod +x /opt/scripts/*.sh && rm -rf /tmp/scripts"

    # Install the Telegram-secrets envfile (root:nick 0640) so cron scripts
    # running as `nick` can read it but the world cannot. This replaces the
    # previous pattern of inlining TELEGRAM_BOT_TOKEN into world-readable
    # /etc/cron.d/* entries (task #21).
    local BACKUP_SECRETS="$REPO_ROOT/backups/secrets.yaml"
    if [ -f "$BACKUP_SECRETS" ] && sops -d "$BACKUP_SECRETS" | yq -e '.telegram_bot_token' > /dev/null 2>&1; then
        echo "Installing /etc/imagineering-secrets/telegram.env..."
        local BOT_TOKEN CHAT_ID THREAD_ID
        BOT_TOKEN=$(sops -d "$BACKUP_SECRETS" | yq -r '.telegram_bot_token')
        CHAT_ID=$(sops -d "$BACKUP_SECRETS" | yq -r '.telegram_chat_id')
        THREAD_ID=$(sops -d "$BACKUP_SECRETS" | yq -r '.telegram_thread_id')
        # Build locally, scp, install with restrictive perms. Avoid putting
        # the token on a remote shell command line where it would land in
        # ~/.bash_history or `ps` output.
        local SECRETS_TMP
        SECRETS_TMP=$(mktemp)
        # Clean up the 0600 plaintext temp file on ANY exit (incl. set -e
        # aborts mid-scp/ssh) — locally and best-effort on the remote /tmp.
        # ConnectTimeout bounds the remote leg: the abort case is often an
        # unreachable host, and the trap must not hang ~120s on a dead TCP
        # connect. Save any pre-existing EXIT trap and restore it on success
        # rather than clearing unconditionally, so an outer trap (none today)
        # would survive.
        local SECRETS_PREV_TRAP
        SECRETS_PREV_TRAP=$(trap -p EXIT)
        # shellcheck disable=SC2064  # expand SECRETS_TMP now, intentional
        trap "rm -f '$SECRETS_TMP'; ssh -o ConnectTimeout=5 '$REMOTE' 'rm -f /tmp/telegram.env' 2>/dev/null || true" EXIT
        # Strip null/empty values so the envfile is clean (e.g. THREAD_ID
        # is optional and may legitimately be missing). Values are shell-quoted
        # (printf %q via shell_env_line) so a token with shell-significant bytes
        # survives `source` intact and cannot inject.
        {
            shell_env_line TELEGRAM_BOT_TOKEN "$BOT_TOKEN"
            shell_env_line TELEGRAM_CHAT_ID   "$CHAT_ID"
            if [ -n "$THREAD_ID" ] && [ "$THREAD_ID" != "null" ]; then
                shell_env_line TELEGRAM_THREAD_ID "$THREAD_ID"
            fi
        } > "$SECRETS_TMP"
        chmod 0600 "$SECRETS_TMP"
        scp -q "$SECRETS_TMP" "$REMOTE":/tmp/telegram.env
        ssh "$REMOTE" "sudo mkdir -p /etc/imagineering-secrets && \
            sudo install -m 0640 -o root -g nick /tmp/telegram.env /etc/imagineering-secrets/telegram.env && \
            rm -f /tmp/telegram.env"
        rm -f "$SECRETS_TMP"
        # Restore the prior EXIT trap (empty string clears, if none existed).
        eval "${SECRETS_PREV_TRAP:-trap - EXIT}"
        echo "  Telegram envfile installed (mode 0640 root:nick)"
    else
        echo "NOTE: No Telegram credentials in backups/secrets.yaml — alerts disabled"
        echo "  Add telegram_bot_token, telegram_chat_id, telegram_thread_id to enable alerts"
    fi

    # Set up health check cron. Tokens are NOT inlined here any more — the
    # script reads /etc/imagineering-secrets/telegram.env via lib/telegram.sh.
    echo "Installing /etc/cron.d/health-check..."
    ssh "$REMOTE" "mkdir -p ~/logs && printf '%s\n' \
        'SHELL=/bin/bash' \
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        'MAILTO=' \
        '0 * * * * nick /opt/scripts/health-check.sh >> /home/nick/logs/health-check.log 2>&1' \
        | sudo tee /etc/cron.d/health-check > /dev/null && \
        sudo chmod 0644 /etc/cron.d/health-check && sudo chown root:root /etc/cron.d/health-check"
    echo "Health check cron installed (hourly)"

    echo "Scripts deployed to /opt/scripts/"
}

deploy_site() {
    # imagineering.cc landing page. Source: separate website/ repo.
    #
    # Destination is ~/apps/site (NOT /srv/site) — the Caddy container
    # bind-mounts /home/nick/apps/site -> /srv/site:ro at the path the
    # Caddyfile references. See caddy/docker-compose.yml. Same convention as
    # the invite mount. Previously this rsynced to host /srv/site, which is
    # not visible inside the Caddy container's filesystem — the script was
    # writing to dead state for some time, and live deploys must have been
    # happening out of band (manual rsync to ~/apps/site).
    local SITE_SRC="$HOME/git/orgs/imagineering/website"

    if [ ! -d "$SITE_SRC" ]; then
        echo "ERROR: website repo not found at $SITE_SRC"
        return 1
    fi

    echo "Deploying imagineering.cc landing page..."
    ssh "$REMOTE" "mkdir -p ~/apps/site"
    # --exclude '.*' skips ALL dotfile entries (.git, .github, .claude,
    # .playwright-mcp, etc.). Replaces the previous narrow excludes which
    # missed Claude/Playwright artefacts. README.md stays excluded explicitly.
    rsync -avz --delete --exclude '.*' --exclude 'README.md' "$SITE_SRC/" "$REMOTE":apps/site/
    echo "Site deployed to ~/apps/site (mounted into Caddy as /srv/site)"
}

deploy_invite() {
    # Static QR-code slide / shareable join URL served at invite.imagineering.cc.
    # Source lives in this repo (unlike deploy_site which pulls from a separate
    # website/ repo), so we rsync straight from $REPO_ROOT/invite.
    #
    # Destination is ~/apps/invite (NOT /srv/invite) — the Caddy container
    # bind-mounts /home/nick/apps/invite -> /srv/invite:ro at the path the
    # Caddyfile references. See caddy/docker-compose.yml. Same convention as
    # the existing /home/nick/apps/site mount. (deploy_site itself currently
    # writes to /srv/site, which is a pre-existing bug — tracked separately.)
    local INVITE_SRC="$REPO_ROOT/invite"

    if [ ! -d "$INVITE_SRC" ]; then
        echo "ERROR: invite/ not found at $INVITE_SRC"
        return 1
    fi

    echo "Deploying invite.imagineering.cc..."
    ssh "$REMOTE" "mkdir -p ~/apps/invite"
    rsync -avz --delete "$INVITE_SRC/" "$REMOTE":apps/invite/
    echo "Invite deployed to ~/apps/invite (mounted into Caddy as /srv/invite)"
}

deploy_galaxy() {
    # Mautrix Galaxy — a standalone three.js teaching world (spherical gravity,
    # planets = bridge platforms) served at galaxy.imagineering.cc. Self-contained
    # single HTML file; the only runtime dependency is three.js from a CDN.
    # Source lives in this repo (galaxy/index.html), recovered from the retired
    # Bridgekeeper's Primer game so it can be shared on its own.
    #
    # Destination is ~/apps/galaxy — the Caddy container bind-mounts
    # /home/nick/apps/galaxy -> /srv/galaxy:ro (see caddy/docker-compose.yml),
    # same convention as the invite mount.
    local GALAXY_SRC="$REPO_ROOT/galaxy"

    if [ ! -f "$GALAXY_SRC/index.html" ]; then
        echo "ERROR: galaxy/index.html not found at $GALAXY_SRC"
        return 1
    fi

    echo "Deploying galaxy.imagineering.cc..."
    ssh "$REMOTE" "mkdir -p ~/apps/galaxy"
    rsync -avz --delete "$GALAXY_SRC/" "$REMOTE":apps/galaxy/
    echo "Galaxy deployed to ~/apps/galaxy (mounted into Caddy as /srv/galaxy)"
}

deploy_contact() {
    echo "Deploying imagineering-contact-us..."

    local CONTACT_SECRETS="$REPO_ROOT/imagineering-contact-us/secrets.yaml"

    # Check for secrets file
    if [ ! -f "$CONTACT_SECRETS" ]; then
        echo "ERROR: imagineering-contact-us/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i imagineering-contact-us/secrets.yaml"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once into a variable so we
    # can read each field without re-decrypting (and without echoing plaintext).
    # Each value goes through dotenv_quote so a secret with dotenv-significant
    # bytes (", $, \, newline) round-trips through docker compose intact rather
    # than corrupting the file or triggering variable interpolation.
    echo "Generating .env from encrypted secrets..."
    local CONTACT_PLAINTEXT
    CONTACT_PLAINTEXT=$(sops -d "$CONTACT_SECRETS")
    # Read a field from the decrypted YAML; missing keys yq-print as "null",
    # which we map to empty so absent => empty value (matches prior behavior
    # for turnstile_secret, and is harmless for the required SMTP fields).
    contact_field() { echo "$CONTACT_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Contact Form Configuration (auto-generated from secrets.yaml)"
        printf 'SMTP_HOST=%s\n'        "$(dotenv_quote "$(contact_field '.smtp_host')")"
        printf 'SMTP_PORT=%s\n'        "$(dotenv_quote "$(contact_field '.smtp_port')")"
        printf 'SMTP_USERNAME=%s\n'    "$(dotenv_quote "$(contact_field '.smtp_username')")"
        printf 'SMTP_PASSWORD=%s\n'    "$(dotenv_quote "$(contact_field '.smtp_password')")"
        printf 'SMTP_FROM_EMAIL=%s\n'  "$(dotenv_quote "$(contact_field '.smtp_from_email')")"
        printf 'CONTACT_TO=%s\n'       "$(dotenv_quote "$(contact_field '.contact_to')")"
        # Empty when the key is absent => Turnstile verification stays off.
        printf 'TURNSTILE_SECRET=%s\n' "$(dotenv_quote "$(contact_field '.turnstile_secret')")"
    } > "$REPO_ROOT/imagineering-contact-us/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/imagineering-contact-us"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/imagineering-contact-us/" "$REMOTE":~/apps/imagineering-contact-us/

    # Clean up local .env
    rm -f "$REPO_ROOT/imagineering-contact-us/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/imagineering-contact-us && docker compose build && docker compose up -d"

    echo "imagineering-contact-us deployed!"
    echo "  Endpoint: https://imagineering.cc/api/contact"
    echo "  Health: curl localhost:3014/health"
}

deploy_service() {
    local svc=$1
    echo "Deploying $svc..."
    ssh "$REMOTE" "mkdir -p ~/apps/$svc"
    rsync -avz --delete "$REPO_ROOT/$svc/" "$REMOTE":~/apps/"$svc"/
    if [ "$svc" = "caddy" ]; then
        # Caddyfile is bind-mounted as one file; rsync replaces its inode.
        # Recreate the container so its mount follows the newly deployed file.
        ssh "$REMOTE" "cd ~/apps/$svc && docker compose pull && docker compose up -d --force-recreate"
    else
        ssh "$REMOTE" "cd ~/apps/$svc && docker compose pull && docker compose up -d"
    fi
}

deploy_notify() {
    echo "Deploying notify (Telegram notify proxy)..."

    local NOTIFY_SECRETS="$REPO_ROOT/notify/secrets.yaml"
    if [ ! -f "$NOTIFY_SECRETS" ]; then
        echo "ERROR: notify/secrets.yaml not found"
        echo "Create from notify/secrets.yaml.example and encrypt with: sops -e -i notify/secrets.yaml"
        return 1
    fi

    # Decrypt once, then route every value through dotenv_quote so a secret with
    # dotenv-significant bytes survives docker compose's dotenv parser intact
    # (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local NOTIFY_PLAINTEXT
    NOTIFY_PLAINTEXT=$(sops -d "$NOTIFY_SECRETS")
    notify_field() { echo "$NOTIFY_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$(dotenv_quote "$(notify_field '.telegram_bot_token')")"
        printf 'TELEGRAM_CHAT_ID=%s\n'   "$(dotenv_quote "$(notify_field '.telegram_chat_id')")"
        printf 'NOTIFY_API_KEY=%s\n'     "$(dotenv_quote "$(notify_field '.notify_api_key')")"
    } > "$REPO_ROOT/notify/.env"

    ssh "$REMOTE" "mkdir -p ~/apps/notify"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/notify/" "$REMOTE":~/apps/notify/

    rm -f "$REPO_ROOT/notify/.env"

    ssh "$REMOTE" "cd ~/apps/notify && docker compose build && docker compose up -d"

    echo "notify deployed!"
    echo "  Endpoint: https://notify.imagineering.cc"
    echo "  Health:   curl https://notify.imagineering.cc/health"
}

deploy_familiars_server() {
    echo "Deploying familiars-server..."

    local FAM_SECRETS="$REPO_ROOT/familiars-server/secrets.yaml"
    local FAM_SRC="$HOME/git/experiments/familiars"

    # Check for secrets file
    if [ ! -f "$FAM_SECRETS" ]; then
        echo "ERROR: familiars-server/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i familiars-server/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$FAM_SRC" ]; then
        echo "ERROR: familiars repo not found at $FAM_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local FAM_PLAINTEXT
    FAM_PLAINTEXT=$(sops -d "$FAM_SECRETS")
    fam_field() { echo "$FAM_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# familiars-server Configuration (auto-generated from secrets.yaml)"
        printf 'FIREBASE_PROJECT_ID=%s\n'             "$(dotenv_quote "$(fam_field '.firebase_project_id')")"
        printf 'FIREBASE_SERVICE_ACCOUNT_BASE64=%s\n' "$(dotenv_quote "$(fam_field '.firebase_service_account_base64')")"
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n'         "$(dotenv_quote "$(fam_field '.claude_code_oauth_token')")"
    } > "$REPO_ROOT/familiars-server/.env"

    # Deploy compose + .env
    ssh "$REMOTE" "mkdir -p ~/apps/familiars-server/source ~/apps/familiars-server/data"
    rsync -avz --exclude 'secrets.yaml' --exclude 'secrets.yaml.example' --exclude 'source' --exclude 'data' \
        "$REPO_ROOT/familiars-server/" "$REMOTE":~/apps/familiars-server/

    # Rsync familiars source. Excludes design-only artifacts and dart caches.
    rsync -avz --delete \
        --exclude '.git' \
        --exclude '.dart_tool' \
        --exclude 'build' \
        "$FAM_SRC/" "$REMOTE":~/apps/familiars-server/source/

    # Clean up local .env
    rm -f "$REPO_ROOT/familiars-server/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/familiars-server && DOCKER_BUILDKIT=1 docker compose build && docker compose up -d"

    echo "familiars-server deployed!"
    echo "  URL: https://familiars.imagineering.cc"
    echo "  Health: curl https://familiars.imagineering.cc/health"
    echo "  Logs: ssh $REMOTE 'docker logs -f img-familiars-server'"
}

deploy_backups() {
    echo "Deploying backup configuration..."

    # Deploy backup scripts
    echo "Deploying backup scripts..."
    ssh "$REMOTE" "sudo mkdir -p /opt/scripts"
    scp "$REPO_ROOT/scripts/backup.sh" "$REMOTE":/tmp/backup.sh
    scp "$REPO_ROOT/scripts/restore.sh" "$REMOTE":/tmp/restore.sh
    ssh "$REMOTE" "sudo mv /tmp/backup.sh /tmp/restore.sh /opt/scripts/"
    ssh "$REMOTE" "sudo chmod +x /opt/scripts/backup.sh /opt/scripts/restore.sh"
    ssh "$REMOTE" "sudo chown nick:nick /opt/scripts/*.sh"

    # Ensure cron is installed and running
    if ! ssh "$REMOTE" "systemctl is-active cron > /dev/null 2>&1"; then
        echo "Installing and starting cron..."
        ssh "$REMOTE" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron && sudo systemctl enable --now cron"
    fi

    # Set up backup cron job and log directory
    echo "Setting up backup cron job..."
    ssh "$REMOTE" "mkdir -p ~/logs"
    ssh "$REMOTE" "echo '0 4 * * * nick /opt/scripts/backup.sh all >> /home/nick/logs/backup.log 2>&1' | sudo tee /etc/cron.d/backup > /dev/null"

    # --- GitHub backup setup ---
    echo ""
    echo "Setting up GitHub backup..."

    # Generate SSH deploy key if not present
    if ! ssh "$REMOTE" "test -f ~/.ssh/imagineering-backups-deploy"; then
        echo "Generating SSH deploy key for imagineering-backups..."
        ssh "$REMOTE" 'ssh-keygen -t ed25519 -f ~/.ssh/imagineering-backups-deploy -N "" -C "imagineering-backups-deploy"'
    fi

    # Configure SSH to use deploy key for the backup repo.
    # NOTE: host alias is `github-imagineering-backups` (not `github-backups`)
    # to avoid collision with the xdeca-backups deploy config which uses
    # `Host github-backups`. Both files load via ~/.ssh/config's
    # `Include config.d/*`; latest wins on duplicate aliases, breaking the
    # other repo's deploy. Backup script's GITHUB_BACKUP_REPO URL must
    # match this alias.
    ssh "$REMOTE" 'mkdir -p ~/.ssh/config.d && cat > ~/.ssh/config.d/imagineering-backups << '\''SSHEOF'\''
Host github-imagineering-backups
    HostName github.com
    User git
    IdentityFile ~/.ssh/imagineering-backups-deploy
    IdentitiesOnly yes
SSHEOF'
    # Ensure main SSH config includes config.d
    ssh "$REMOTE" 'grep -q "Include config.d/\*" ~/.ssh/config 2>/dev/null || printf "Include config.d/*\n\n" | cat - ~/.ssh/config 2>/dev/null > /tmp/ssh_config_tmp && mv /tmp/ssh_config_tmp ~/.ssh/config || printf "Include config.d/*\n" > ~/.ssh/config'
    ssh "$REMOTE" "chmod 600 ~/.ssh/config ~/.ssh/config.d/imagineering-backups"

    # Ensure GitHub host key is trusted
    ssh "$REMOTE" 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null'

    # Print deploy key for operator
    echo ""
    echo "============================================"
    echo "  GitHub Deploy Key (add to imagineering-cc/imagineering-backups with WRITE access)"
    echo "============================================"
    ssh "$REMOTE" "cat ~/.ssh/imagineering-backups-deploy.pub"
    echo "============================================"
    echo ""

    # --- Continuwuity backup prerequisites ---
    # `backup_continuwuity` needs the `age` binary to encrypt the tarball
    # before pushing. apt is idempotent; reinstall is a no-op if present.
    echo "Ensuring age is installed on $REMOTE..."
    ssh "$REMOTE" "command -v age >/dev/null 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq age"

    # --- Build sqlite-dumper image for backup_matrix / restore_matrix ---
    # Pre-installs sqlite in alpine so the per-bridge `apk add` overhead
    # (~5s × 6 bridges = ~30s) is avoided on every nightly run.
    # Local-only image; no registry push needed.
    echo "Building sqlite-dumper image on $REMOTE..."
    scp -q -r "$REPO_ROOT/scripts/sqlite-dumper" "$REMOTE":/tmp/sqlite-dumper
    ssh "$REMOTE" "docker build -q -t sqlite-dumper:latest /tmp/sqlite-dumper && rm -rf /tmp/sqlite-dumper" | tail -1

    # --- Install matrix admin secrets (admin token + age recipient) ---
    # Source-of-truth is matrix/secrets.yaml (SOPS-encrypted). We decrypt
    # locally, scp a minimal env file to /tmp, then install it under
    # /etc/imagineering-secrets/matrix.env (mode 0640 root:nick). The
    # backup script sources it at runtime; no values touch the cron file.
    local MATRIX_SECRETS="$REPO_ROOT/matrix/secrets.yaml"
    if [ -f "$MATRIX_SECRETS" ] && sops -d "$MATRIX_SECRETS" | yq -e '.matrix_admin_token' > /dev/null 2>&1; then
        echo "Installing /etc/imagineering-secrets/matrix.env..."
        local ADMIN_TOKEN AGE_RECIPIENT
        ADMIN_TOKEN=$(sops -d "$MATRIX_SECRETS" | yq -r '.matrix_admin_token')
        AGE_RECIPIENT=$(sops -d "$MATRIX_SECRETS" | yq -r '.backup_age_recipient')
        if [ "$ADMIN_TOKEN" = "CHANGE_ME" ] || [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
            echo "WARNING: matrix_admin_token is CHANGE_ME/null in $MATRIX_SECRETS"
            echo "  Continuwuity nightly backup will fail until this is set."
        fi
        local MATRIX_SECRETS_TMP
        MATRIX_SECRETS_TMP=$(mktemp)
        # Clean up the 0600 plaintext temp file on ANY exit (incl. set -e
        # aborts mid-scp/ssh) — locally and best-effort on the remote /tmp.
        # ConnectTimeout bounds the remote leg (see deploy_scripts note).
        # Save/restore any pre-existing EXIT trap rather than clearing blindly.
        local MATRIX_PREV_TRAP
        MATRIX_PREV_TRAP=$(trap -p EXIT)
        # shellcheck disable=SC2064  # expand MATRIX_SECRETS_TMP now, intentional
        trap "rm -f '$MATRIX_SECRETS_TMP'; ssh -o ConnectTimeout=5 '$REMOTE' 'rm -f /tmp/matrix.env' 2>/dev/null || true" EXIT
        # Values shell-quoted (printf %q) so an admin token / age recipient
        # with shell-significant bytes survives `source` in backup.sh intact.
        {
            shell_env_line MATRIX_ADMIN_TOKEN "$ADMIN_TOKEN"
            shell_env_line AGE_RECIPIENT      "$AGE_RECIPIENT"
        } > "$MATRIX_SECRETS_TMP"
        chmod 0600 "$MATRIX_SECRETS_TMP"
        scp -q "$MATRIX_SECRETS_TMP" "$REMOTE":/tmp/matrix.env
        ssh "$REMOTE" "sudo mkdir -p /etc/imagineering-secrets && \
            sudo install -m 0640 -o root -g nick /tmp/matrix.env /etc/imagineering-secrets/matrix.env && \
            rm -f /tmp/matrix.env"
        rm -f "$MATRIX_SECRETS_TMP"
        # Restore the prior EXIT trap (empty string clears, if none existed).
        eval "${MATRIX_PREV_TRAP:-trap - EXIT}"
        echo "  Matrix envfile installed (mode 0640 root:nick)"
    else
        echo "NOTE: matrix_admin_token not found in $MATRIX_SECRETS — Continuwuity backup disabled"
        echo "  Add matrix_admin_token + backup_age_recipient to matrix/secrets.yaml to enable"
    fi

    echo "Backup configuration complete!"
    echo "  - GitHub backup: imagineering-cc/imagineering-backups (private repo)"
    echo "  - Deploy key: ~/.ssh/imagineering-backups-deploy"
    echo "  - Scripts: /opt/scripts/backup.sh, /opt/scripts/restore.sh"
    echo "  - Matrix secrets: /etc/imagineering-secrets/matrix.env"
    echo "  - Cron: Daily at 4 AM"
    echo ""
    echo "Test with: ssh $REMOTE '/opt/scripts/backup.sh all'"
    echo "Test individual: ssh $REMOTE '/opt/scripts/backup.sh matrix'"
    echo "Test continuwuity: ssh $REMOTE '/opt/scripts/backup.sh continuwuity'"
}

deploy_outline() {
    echo "Deploying Outline Wiki..."

    local OUTLINE_SECRETS="$REPO_ROOT/outline/secrets.yaml"

    # Check for secrets file
    if [ ! -f "$OUTLINE_SECRETS" ]; then
        echo "ERROR: outline/secrets.yaml not found"
        echo "Create it and encrypt with: sops -e -i outline/secrets.yaml"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once into a variable so we
    # can read each field without re-decrypting, and route every value through
    # dotenv_quote so a secret with dotenv-significant bytes (", $, \, newline)
    # round-trips through docker compose intact rather than corrupting the file
    # or triggering variable interpolation.
    echo "Generating .env from encrypted secrets..."
    local OUTLINE_PLAINTEXT
    OUTLINE_PLAINTEXT=$(sops -d "$OUTLINE_SECRETS")
    outline_field() { echo "$OUTLINE_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Outline Configuration (auto-generated from secrets.yaml)"
        printf 'OUTLINE_URL=%s\n'         "$(dotenv_quote "$(outline_field '.outline_url')")"
        echo ""
        echo "# Generated secrets"
        printf 'SECRET_KEY=%s\n'          "$(dotenv_quote "$(outline_field '.secret_key')")"
        printf 'UTILS_SECRET=%s\n'        "$(dotenv_quote "$(outline_field '.utils_secret')")"
        echo ""
        echo "# Postgres"
        printf 'POSTGRES_PASSWORD=%s\n'   "$(dotenv_quote "$(outline_field '.postgres_password')")"
        echo ""
        echo "# MinIO (S3-compatible storage)"
        printf 'MINIO_ROOT_USER=%s\n'     "$(dotenv_quote "$(outline_field '.minio_root_user')")"
        printf 'MINIO_ROOT_PASSWORD=%s\n' "$(dotenv_quote "$(outline_field '.minio_root_password')")"
        printf 'MINIO_URL=%s\n'           "$(dotenv_quote "$(outline_field '.minio_url')")"
        echo ""
        echo "# SMTP"
        printf 'SMTP_HOST=%s\n'           "$(dotenv_quote "$(outline_field '.smtp_host')")"
        printf 'SMTP_PORT=%s\n'           "$(dotenv_quote "$(outline_field '.smtp_port')")"
        printf 'SMTP_USERNAME=%s\n'       "$(dotenv_quote "$(outline_field '.smtp_username')")"
        printf 'SMTP_PASSWORD=%s\n'       "$(dotenv_quote "$(outline_field '.smtp_password')")"
        printf 'SMTP_FROM_EMAIL=%s\n'     "$(dotenv_quote "$(outline_field '.smtp_from_email')")"
        printf 'SMTP_SECURE=%s\n'         "$(dotenv_quote "$(outline_field '.smtp_secure')")"
    } > "$REPO_ROOT/outline/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/outline"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/outline/" "$REMOTE":~/apps/outline/

    # Clean up local .env
    rm -f "$REPO_ROOT/outline/.env"

    # Start Outline
    ssh "$REMOTE" "cd ~/apps/outline && docker compose pull && docker compose up -d"

    echo "Outline deployed!"
    echo "  URL: https://outline.imagineering.cc"
    echo "  Note: First user to sign in becomes admin"
}

deploy_kanbn() {
    echo "Deploying Kan.bn..."

    local KANBN_SECRETS="$REPO_ROOT/kanbn/secrets.yaml"

    # Check for secrets file
    if [ ! -f "$KANBN_SECRETS" ]; then
        echo "ERROR: kanbn/secrets.yaml not found"
        echo "Create it and encrypt with: sops -e -i kanbn/secrets.yaml"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local KANBN_PLAINTEXT
    KANBN_PLAINTEXT=$(sops -d "$KANBN_SECRETS")
    kanbn_field() { echo "$KANBN_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Kan.bn Configuration (auto-generated from secrets.yaml)"
        printf 'KANBN_URL=%s\n'               "$(dotenv_quote "$(kanbn_field '.kanbn_url')")"
        printf 'AUTH_SECRET=%s\n'             "$(dotenv_quote "$(kanbn_field '.auth_secret')")"
        printf 'POSTGRES_PASSWORD=%s\n'       "$(dotenv_quote "$(kanbn_field '.postgres_password')")"
        printf 'SMTP_HOST=%s\n'               "$(dotenv_quote "$(kanbn_field '.smtp_host')")"
        printf 'SMTP_PORT=%s\n'               "$(dotenv_quote "$(kanbn_field '.smtp_port')")"
        printf 'SMTP_USERNAME=%s\n'           "$(dotenv_quote "$(kanbn_field '.smtp_username')")"
        printf 'SMTP_PASSWORD=%s\n'           "$(dotenv_quote "$(kanbn_field '.smtp_password')")"
        printf 'SMTP_FROM_EMAIL=%s\n'         "$(dotenv_quote "$(kanbn_field '.smtp_from_email')")"
        printf 'TRELLO_API_KEY=%s\n'          "$(dotenv_quote "$(kanbn_field '.trello_api_key')")"
        printf 'TRELLO_API_SECRET=%s\n'       "$(dotenv_quote "$(kanbn_field '.trello_api_secret')")"
        printf 'S3_ENDPOINT=%s\n'             "$(dotenv_quote "$(kanbn_field '.s3_endpoint')")"
        printf 'S3_ACCESS_KEY_ID=%s\n'        "$(dotenv_quote "$(kanbn_field '.s3_access_key_id')")"
        printf 'S3_SECRET_ACCESS_KEY=%s\n'    "$(dotenv_quote "$(kanbn_field '.s3_secret_access_key')")"
        printf 'NEXT_PUBLIC_STORAGE_URL=%s\n' "$(dotenv_quote "$(kanbn_field '.next_public_storage_url')")"
        printf 'WEBHOOK_URL=%s\n'             "$(dotenv_quote "$(kanbn_field '.webhook_url')")"
        printf 'WEBHOOK_SECRET=%s\n'          "$(dotenv_quote "$(kanbn_field '.webhook_secret')")"
    } > "$REPO_ROOT/kanbn/.env"

    # Deploy .env and compose files
    ssh "$REMOTE" "mkdir -p ~/apps/kanbn"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/kanbn/" "$REMOTE":~/apps/kanbn/

    # Clean up local .env
    rm -f "$REPO_ROOT/kanbn/.env"

    # Pull image from ghcr.io and start
    ssh "$REMOTE" "cd ~/apps/kanbn && docker compose pull && docker compose up -d"

    echo "Kan.bn deployed!"
    echo "  URL: https://kan.imagineering.cc"
    echo "  Note: First user to sign up becomes admin"
}

deploy_pm_bot() {
    echo "Deploying Dreamfinder (Signal PM bot)..."

    local PM_BOT_SECRETS="$REPO_ROOT/dreamfinder/secrets.yaml"
    local PM_BOT_SRC="$HOME/git/orgs/imagineering/dreamfinder"

    # Check for secrets file
    if [ ! -f "$PM_BOT_SECRETS" ]; then
        echo "ERROR: dreamfinder/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i dreamfinder/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$PM_BOT_SRC" ]; then
        echo "ERROR: dreamfinder source not found at $PM_BOT_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local PM_BOT_PLAINTEXT
    PM_BOT_PLAINTEXT=$(sops -d "$PM_BOT_SECRETS")
    pm_bot_field() { echo "$PM_BOT_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Dreamfinder Configuration (auto-generated from secrets.yaml)"
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n'           "$(dotenv_quote "$(pm_bot_field '.claude_code_oauth_token')")"
        printf 'MATRIX_HOMESERVER=%s\n'           "$(dotenv_quote "$(pm_bot_field '.matrix_homeserver')")"
        printf 'MATRIX_ACCESS_TOKEN=%s\n'         "$(dotenv_quote "$(pm_bot_field '.matrix_access_token')")"
        printf 'KAN_BASE_URL=%s\n'                "$(dotenv_quote "$(pm_bot_field '.kan_base_url')")"
        printf 'KAN_API_KEY=%s\n'                 "$(dotenv_quote "$(pm_bot_field '.kan_api_key')")"
        printf 'OUTLINE_BASE_URL=%s\n'            "$(dotenv_quote "$(pm_bot_field '.outline_base_url')")"
        printf 'OUTLINE_API_KEY=%s\n'             "$(dotenv_quote "$(pm_bot_field '.outline_api_key')")"
        printf 'RADICALE_BASE_URL=%s\n'           "$(dotenv_quote "$(pm_bot_field '.radicale_base_url')")"
        printf 'RADICALE_USERNAME=%s\n'           "$(dotenv_quote "$(pm_bot_field '.radicale_username')")"
        printf 'RADICALE_PASSWORD=%s\n'           "$(dotenv_quote "$(pm_bot_field '.radicale_password')")"
        printf 'PLAYWRIGHT_ENABLED=%s\n'          "$(dotenv_quote "$(pm_bot_field '.playwright_enabled')")"
        printf 'BOT_NAME=%s\n'                    "$(dotenv_quote "$(pm_bot_field '.bot_name')")"
        printf 'LOG_LEVEL=%s\n'                   "$(dotenv_quote "$(pm_bot_field '.log_level')")"
        printf 'API_KEY=%s\n'                     "$(dotenv_quote "$(pm_bot_field '.api_key')")"
        printf 'LIVEKIT_URL=%s\n'                 "$(dotenv_quote "$(pm_bot_field '.livekit_url')")"
        printf 'LIVEKIT_API_KEY=%s\n'             "$(dotenv_quote "$(pm_bot_field '.livekit_api_key')")"
        printf 'LIVEKIT_API_SECRET=%s\n'          "$(dotenv_quote "$(pm_bot_field '.livekit_api_secret')")"
        printf 'ADMIN_IDS=%s\n'                   "$(dotenv_quote "$(pm_bot_field '.admin_ids')")"
        printf 'MATRIX_ALWAYS_RESPOND_ROOMS=%s\n' "$(dotenv_quote "$(pm_bot_field '.matrix_always_respond_rooms')")"
        printf 'CALENDAR_URL=%s\n'                "$(dotenv_quote "$(pm_bot_field '.calendar_url')")"
        printf 'EVENT_TIMEZONE=%s\n'              "$(dotenv_quote "$(pm_bot_field '.event_timezone')")"
        printf 'DEPLOY_ANNOUNCE_GROUP_ID=%s\n'    "$(dotenv_quote "$(pm_bot_field '.deploy_announce_group_id')")"
    } > "$REPO_ROOT/dreamfinder/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/dreamfinder/src"

    # Copy docker compose and .env
    rsync -avz --exclude 'secrets.yaml' "$REPO_ROOT/dreamfinder/" "$REMOTE":~/apps/dreamfinder/

    # Ensure MCP server submodule is initialized
    (cd "$PM_BOT_SRC" && git submodule update --init)

    # Copy source code (Dart project)
    rsync -avz --delete --exclude '.dart_tool' --exclude '.packages' --exclude 'data' --exclude '.env' --exclude '.git' "$PM_BOT_SRC/" "$REMOTE":~/apps/dreamfinder/src/

    # Clean up local .env
    rm -f "$REPO_ROOT/dreamfinder/.env"

    # Ensure shared network exists (allows text brain to be reachable by voice brain)
    ssh "$REMOTE" "docker network inspect imagineering >/dev/null 2>&1 || docker network create imagineering"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/dreamfinder && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "Dreamfinder deployed!"
    echo "  Check logs: ssh $REMOTE 'docker logs -f dreamfinder'"
}

deploy_embodied_dreamfinder() {
    echo "Deploying Embodied Dreamfinder (voice avatar)..."

    local EDF_SECRETS="$REPO_ROOT/embodied-dreamfinder/secrets.yaml"
    local EDF_SRC="$HOME/git/orgs/imagineering/embodied-dreamfinder"

    # Check for secrets file
    if [ ! -f "$EDF_SECRETS" ]; then
        echo "ERROR: embodied-dreamfinder/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i embodied-dreamfinder/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$EDF_SRC" ]; then
        echo "ERROR: embodied-dreamfinder source not found at $EDF_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    # The per-field yq fallback default keeps absent keys empty — except
    # VOICE_MODE which defaults to "realtime" as before.
    echo "Generating .env from encrypted secrets..."
    local EDF_PLAINTEXT
    EDF_PLAINTEXT=$(sops -d "$EDF_SECRETS")
    # $2 is an optional fallback for a missing/null key (default empty).
    edf_field() { echo "$EDF_PLAINTEXT" | yq -r "$1 // \"${2:-}\""; }
    {
        echo "# Embodied Dreamfinder Configuration (auto-generated from secrets.yaml)"
        printf 'AUTH_PASSWORD=%s\n'         "$(dotenv_quote "$(edf_field '.auth_password')")"
        printf 'AUTH_SECRET=%s\n'           "$(dotenv_quote "$(edf_field '.auth_secret')")"
        printf 'OPENAI_API_KEY=%s\n'        "$(dotenv_quote "$(edf_field '.openai_api_key')")"
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n'     "$(dotenv_quote "$(edf_field '.claude_code_oauth_token')")"
        printf 'VOICE_MODE=%s\n'            "$(dotenv_quote "$(edf_field '.voice_mode' 'realtime')")"
        printf 'OUTLINE_API_KEY=%s\n'       "$(dotenv_quote "$(edf_field '.outline_api_key')")"
        printf 'RADICALE_CALENDAR_URL=%s\n' "$(dotenv_quote "$(edf_field '.radicale_calendar_url')")"
        printf 'RADICALE_USERNAME=%s\n'     "$(dotenv_quote "$(edf_field '.radicale_username')")"
        printf 'RADICALE_PASSWORD=%s\n'     "$(dotenv_quote "$(edf_field '.radicale_password')")"
        printf 'DREAMFINDER_API_URL=%s\n'   "$(dotenv_quote "$(edf_field '.dreamfinder_api_url')")"
        printf 'DREAMFINDER_API_KEY=%s\n'   "$(dotenv_quote "$(edf_field '.dreamfinder_api_key')")"
        printf 'LIVEKIT_URL=%s\n'           "$(dotenv_quote "$(edf_field '.livekit_url')")"
        printf 'LIVEKIT_API_KEY=%s\n'       "$(dotenv_quote "$(edf_field '.livekit_api_key')")"
        printf 'LIVEKIT_API_SECRET=%s\n'    "$(dotenv_quote "$(edf_field '.livekit_api_secret')")"
        # lyra-live fields (merged from feat/lyra-live-voice; routed through the
        # same dotenv_quote hardening as every other secret above).
        printf 'DF_BRAIN=%s\n'              "$(dotenv_quote "$(edf_field '.df_brain' 'api')")"
        printf 'TTS_ENGINE=%s\n'            "$(dotenv_quote "$(edf_field '.tts_engine' 'kokoro')")"
        printf 'LYRA_SSH_KEY=%s\n'          "$(dotenv_quote "$(edf_field '.lyra_ssh_key')")"
        printf 'LYRA_SSH_HOST=%s\n'         "$(dotenv_quote "$(edf_field '.lyra_ssh_host' 'ubuntu@207.211.145.30')")"
        printf 'OPENAI_TTS_VOICE=%s\n'      "$(dotenv_quote "$(edf_field '.openai_tts_voice' 'sage')")"
    } > "$REPO_ROOT/embodied-dreamfinder/.env"

    # Compose-file selection: only apply the lyra-live override (which mounts the
    # ssh deploy key into the container) when the brain is actually lyra-live, so
    # the default api path never carries the key (cage-match #81 finding 1).
    local DF_BRAIN_VAL EDF_COMPOSE_ARGS
    DF_BRAIN_VAL=$(edf_field '.df_brain' 'api')
    if [ "$DF_BRAIN_VAL" = "lyra-live" ]; then
        EDF_COMPOSE_ARGS="-f docker-compose.yml -f docker-compose.lyra.yml"
        echo "DF_BRAIN=lyra-live -> applying docker-compose.lyra.yml (mounts ssh deploy key)"
    else
        EDF_COMPOSE_ARGS="-f docker-compose.yml"
        echo "DF_BRAIN=$DF_BRAIN_VAL -> base compose only (no ssh key mounted)"
    fi

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/embodied-dreamfinder/src"

    # Copy docker compose and .env
    rsync -avz --exclude 'secrets.yaml' "$REPO_ROOT/embodied-dreamfinder/" "$REMOTE":~/apps/embodied-dreamfinder/

    # Copy source code (Node.js project + avatar GLB)
    rsync -avz --delete --exclude 'node_modules' --exclude '.env' --exclude '.git' "$EDF_SRC/" "$REMOTE":~/apps/embodied-dreamfinder/src/

    # Clean up local .env
    rm -f "$REPO_ROOT/embodied-dreamfinder/.env"

    # Ensure shared network exists (allows voice brain to reach text brain)
    ssh "$REMOTE" "docker network inspect imagineering >/dev/null 2>&1 || docker network create imagineering"

    # Build and start (override applied only in lyra-live mode — see above)
    ssh "$REMOTE" "cd ~/apps/embodied-dreamfinder && DOCKER_BUILDKIT=1 docker compose $EDF_COMPOSE_ARGS build --pull && docker compose $EDF_COMPOSE_ARGS up -d"

    echo "Embodied Dreamfinder deployed!"
    echo "  URL: https://df.imagineering.cc"
    echo "  Check logs: ssh $REMOTE 'docker logs -f embodied-dreamfinder'"
}

deploy_livekit() {
    echo "Deploying LiveKit SFU (self-hosted WebRTC)..."

    local LK_SECRETS="$REPO_ROOT/livekit/secrets.yaml"

    if [ ! -f "$LK_SECRETS" ]; then
        echo "ERROR: livekit/secrets.yaml not found"
        echo "Create from secrets.yaml.example and encrypt with: sops -e -i livekit/secrets.yaml"
        return 1
    fi

    # Read secrets
    local API_KEY API_SECRET EXTERNAL_IP
    API_KEY=$(sops -d "$LK_SECRETS" | yq -r '.livekit_api_key')
    API_SECRET=$(sops -d "$LK_SECRETS" | yq -r '.livekit_api_secret')
    EXTERNAL_IP=$(sops -d "$LK_SECRETS" | yq -r '.external_ip')

    # Generate livekit.yaml with real credentials and IP.
    #
    # Use yq strenv templating, NOT sed: a secret containing sed-significant
    # bytes (/, &, \) or YAML-significant bytes (:, #, ", newline) would corrupt
    # the config or inject YAML under the old `sed s/PLACEHOLDER/$secret/`
    # approach. strenv reads the value from the environment (never the command
    # line, so it can't leak via `ps`/history) and yq emits it as a properly
    # quoted YAML scalar. The template `keys:` map has exactly one placeholder
    # entry (LIVEKIT_API_KEY: LIVEKIT_API_SECRET); we replace the whole map with
    # the real key->secret pair, and set rtc.node_ip when an external IP is given.
    LK_KEY="$API_KEY" LK_SECRET="$API_SECRET" yq eval '
        .keys = {} |
        .keys[strenv(LK_KEY)] = strenv(LK_SECRET)
    ' "$REPO_ROOT/livekit/livekit.yaml" > "$REPO_ROOT/livekit/livekit-generated.yaml"

    # Inject node_ip if external IP is set
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
        LK_IP="$EXTERNAL_IP" yq eval -i '.rtc.node_ip = strenv(LK_IP)' \
            "$REPO_ROOT/livekit/livekit-generated.yaml"
    fi

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/livekit"
    rsync -avz "$REPO_ROOT/livekit/docker-compose.yml" "$REMOTE":~/apps/livekit/
    rsync -avz "$REPO_ROOT/livekit/livekit-generated.yaml" "$REMOTE":~/apps/livekit/livekit.yaml

    # Clean up generated config
    rm -f "$REPO_ROOT/livekit/livekit-generated.yaml"

    # Open firewall ports (OCI uses iptables — these may already be open)
    echo "Reminder: Ensure OCI security list allows:"
    echo "  - TCP 7881 (WebRTC TCP fallback)"
    echo "  - UDP 3478 (TURN/STUN)"
    echo "  - TCP 5349 (TURN/TLS)"
    echo "  - UDP 7882-7892 (WebRTC media)"

    # Pull and start
    ssh "$REMOTE" "cd ~/apps/livekit && docker compose pull && docker compose up -d"

    echo "LiveKit SFU deployed!"
    echo "  Signaling: https://livekit.imagineering.cc"
    echo "  TURN: turn.imagineering.cc:5349"
    echo "  Check logs: ssh $REMOTE 'docker logs -f livekit'"
}

deploy_tech_world_bots() {
    echo "Deploying Tech World bots (Clawd, Gremlin, Dreamfinder)..."

    local TWB_SECRETS="$REPO_ROOT/tech-world-bots/secrets.yaml"
    local TWB_SRC="$HOME/git/orgs/enspyrco/adventures-in/tech_world_bot"

    if [ ! -f "$TWB_SECRETS" ]; then
        echo "ERROR: tech-world-bots/secrets.yaml not found"
        echo "Create from secrets.yaml.example and encrypt with: sops -e -i tech-world-bots/secrets.yaml"
        return 1
    fi

    if [ ! -d "$TWB_SRC" ]; then
        echo "ERROR: tech_world_bot source not found at $TWB_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local TWB_PLAINTEXT
    TWB_PLAINTEXT=$(sops -d "$TWB_SECRETS")
    twb_field() { echo "$TWB_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        printf 'LIVEKIT_URL=%s\n'        "$(dotenv_quote "$(twb_field '.livekit_url')")"
        printf 'LIVEKIT_API_KEY=%s\n'    "$(dotenv_quote "$(twb_field '.livekit_api_key')")"
        printf 'LIVEKIT_API_SECRET=%s\n' "$(dotenv_quote "$(twb_field '.livekit_api_secret')")"
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n'  "$(dotenv_quote "$(twb_field '.claude_code_oauth_token')")"
        printf 'OPENAI_API_KEY=%s\n'     "$(dotenv_quote "$(twb_field '.openai_api_key')")"
        printf 'KAN_BASE_URL=%s\n'       "$(dotenv_quote "$(twb_field '.kan_base_url')")"
        printf 'KAN_API_KEY=%s\n'        "$(dotenv_quote "$(twb_field '.kan_api_key')")"
        printf 'KAN_BOARD_ID=%s\n'       "$(dotenv_quote "$(twb_field '.kan_board_id')")"
        printf 'OUTLINE_BASE_URL=%s\n'   "$(dotenv_quote "$(twb_field '.outline_base_url')")"
        printf 'OUTLINE_API_KEY=%s\n'    "$(dotenv_quote "$(twb_field '.outline_api_key')")"
    } > "$REPO_ROOT/tech-world-bots/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/tech-world-bots/src"

    rsync -avz --exclude 'secrets.yaml' "$REPO_ROOT/tech-world-bots/" "$REMOTE":~/apps/tech-world-bots/

    rsync -avz --delete --exclude 'node_modules' --exclude '.env' --exclude '.git' --exclude 'dist' "$TWB_SRC/" "$REMOTE":~/apps/tech-world-bots/src/

    rm -f "$REPO_ROOT/tech-world-bots/.env"

    # Build and start all three bots
    ssh "$REMOTE" "cd ~/apps/tech-world-bots && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "Tech World bots deployed!"
    echo "  Containers: tw-clawd, tw-gremlin, tw-dreamfinder"
    echo "  Check logs: ssh $REMOTE 'docker logs -f tw-dreamfinder'"
}

deploy_radicale() {
    echo "Deploying Radicale (CalDAV/CardDAV)..."

    local RADICALE_SECRETS="$REPO_ROOT/radicale/secrets.yaml"

    # Check for secrets file
    if [ ! -f "$RADICALE_SECRETS" ]; then
        echo "ERROR: radicale/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i radicale/secrets.yaml"
        return 1
    fi

    # Generate htpasswd users file from encrypted secrets
    echo "Generating htpasswd users file from encrypted secrets..."
    sops -d "$RADICALE_SECRETS" | yq -r '.htpasswd_users' > "$REPO_ROOT/radicale/config/users"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/radicale"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/radicale/" "$REMOTE":~/apps/radicale/

    # Clean up local users file
    rm -f "$REPO_ROOT/radicale/config/users"

    # Start Radicale
    ssh "$REMOTE" "cd ~/apps/radicale && docker compose pull && docker compose up -d"

    echo "Radicale deployed!"
    echo "  URL: https://dav.imagineering.cc"
    echo "  Test: curl -u user:pass https://dav.imagineering.cc/.well-known/caldav"
}

deploy_matrix() {
    echo "Deploying Matrix (Continuwuity + bridges + relay bot)..."

    local MATRIX_SECRETS="$REPO_ROOT/matrix/secrets.yaml"
    local MATRIX_SRC="$HOME/git/orgs/imagineering/matrix-chat-superbridge"

    # Check for secrets file
    if [ ! -f "$MATRIX_SECRETS" ]; then
        echo "ERROR: matrix/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i matrix/secrets.yaml"
        return 1
    fi

    # Check for matrix repo (needed for relay bot source)
    if [ ! -d "$MATRIX_SRC/relay" ]; then
        echo "ERROR: matrix repo not found at $MATRIX_SRC (need relay/ source)"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local MATRIX_PLAINTEXT
    MATRIX_PLAINTEXT=$(sops -d "$MATRIX_SECRETS")
    matrix_field() { echo "$MATRIX_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Matrix Configuration (auto-generated from secrets.yaml)"
        printf 'MATRIX_SERVER_NAME=%s\n'   "$(dotenv_quote "$(matrix_field '.matrix_server_name')")"
        printf 'REGISTRATION_TOKEN=%s\n'   "$(dotenv_quote "$(matrix_field '.registration_token')")"
        printf 'RELAY_AS_TOKEN=%s\n'       "$(dotenv_quote "$(matrix_field '.relay_as_token')")"
        printf 'RELAY_HS_TOKEN=%s\n'       "$(dotenv_quote "$(matrix_field '.relay_hs_token')")"
        printf 'PORTAL_ROOMS=%s\n'         "$(dotenv_quote "$(matrix_field '.portal_rooms')")"
        printf 'HUB_ROOM_ID=%s\n'          "$(dotenv_quote "$(matrix_field '.hub_room_id')")"
        printf 'RELAY_DOUBLE_PUPPETS=%s\n' "$(dotenv_quote "$(matrix_field '.relay_double_puppets')")"
        printf 'RELAY_LOG_LEVEL=%s\n'      "$(dotenv_quote "$(matrix_field '.relay_log_level')")"
        printf 'HF_RELAY_AS_TOKEN=%s\n'    "$(dotenv_quote "$(matrix_field '.hf_relay_as_token')")"
        printf 'HF_RELAY_HS_TOKEN=%s\n'    "$(dotenv_quote "$(matrix_field '.hf_relay_hs_token')")"
        printf 'HF_PORTAL_ROOMS=%s\n'      "$(dotenv_quote "$(matrix_field '.hf_portal_rooms')")"
        printf 'HF_HUB_ROOM_ID=%s\n'       "$(dotenv_quote "$(matrix_field '.hf_hub_room_id')")"
    } > "$REPO_ROOT/matrix/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/matrix"
    rsync -avz --delete --exclude 'secrets.yaml' --exclude 'secrets.yaml.example' "$REPO_ROOT/matrix/" "$REMOTE":~/apps/matrix/

    # Copy relay bot source from matrix repo
    rsync -avz --delete \
        --exclude '__pycache__' \
        --exclude '.pytest_cache' \
        --exclude 'tests' \
        --exclude '*.pyc' \
        "$MATRIX_SRC/relay/" "$REMOTE":~/apps/matrix/relay/

    # Clean up local .env
    rm -f "$REPO_ROOT/matrix/.env"

    # Build relay bots and start all services (relay-bot + relay-bot-hf
    # share the ./relay build context, so this does both efficiently)
    ssh "$REMOTE" "cd ~/apps/matrix && docker compose pull && DOCKER_BUILDKIT=1 docker compose build relay-bot relay-bot-hf && docker compose up -d"

    echo "Matrix deployed!"
    echo "  URL: https://matrix.imagineering.cc"
    echo "  Verify: curl https://matrix.imagineering.cc/_matrix/client/versions"
    echo "  Logs: ssh $REMOTE 'cd ~/apps/matrix && docker compose logs --tail 20'"
}

deploy_youtube_rag() {
    echo "Deploying YouTube RAG..."

    local RAG_SECRETS="$REPO_ROOT/youtube-rag/secrets.yaml"
    local RAG_SRC="$HOME/git/experiments/youtube-rag"

    # Check for secrets file
    if [ ! -f "$RAG_SECRETS" ]; then
        echo "ERROR: youtube-rag/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i youtube-rag/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$RAG_SRC" ]; then
        echo "ERROR: YouTube RAG source not found at $RAG_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local RAG_PLAINTEXT
    RAG_PLAINTEXT=$(sops -d "$RAG_SECRETS")
    rag_field() { echo "$RAG_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# YouTube RAG Configuration (auto-generated from secrets.yaml)"
        printf 'ANTHROPIC_API_KEY=%s\n' "$(dotenv_quote "$(rag_field '.anthropic_api_key')")"
        printf 'YOUTUBE_API_KEY=%s\n'   "$(dotenv_quote "$(rag_field '.youtube_api_key')")"
    } > "$REPO_ROOT/youtube-rag/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/youtube-rag/src"

    # Copy docker compose and .env
    rsync -avz --exclude 'secrets.yaml' --exclude 'secrets.yaml.example' "$REPO_ROOT/youtube-rag/" "$REMOTE":~/apps/youtube-rag/

    # Copy backend source
    rsync -avz --delete \
        --exclude '.venv' \
        --exclude '__pycache__' \
        --exclude '.pytest_cache' \
        --exclude '.ruff_cache' \
        --exclude 'data' \
        --exclude '.env' \
        --exclude '.git' \
        "$RAG_SRC/backend/" "$REMOTE":~/apps/youtube-rag/src/

    # Copy frontend source
    rsync -avz --delete \
        --exclude 'node_modules' \
        --exclude '.next' \
        --exclude 'out' \
        --exclude '.git' \
        "$RAG_SRC/frontend/" "$REMOTE":~/apps/youtube-rag/src/frontend/

    # Clean up local .env
    rm -f "$REPO_ROOT/youtube-rag/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/youtube-rag && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "YouTube RAG deployed!"
    echo "  Frontend: https://rag.imagineering.cc"
    echo "  API: https://rag-api.imagineering.cc"
    echo "  Check logs: ssh $REMOTE 'cd ~/apps/youtube-rag && docker compose logs -f'"
    echo "  NOTE: First embedding request will take ~60s (model download + load)"
}

deploy_claudius() {
    echo "Deploying Claudius Maximus (headless email agent)..."

    local CLAUDIUS_SECRETS="$REPO_ROOT/claudius/secrets.yaml"
    local CLAUDIUS_SRC="$HOME/git/experiments/containerized-claude/claudius-maximus-container"

    # Check for secrets file
    if [ ! -f "$CLAUDIUS_SECRETS" ]; then
        echo "ERROR: claudius/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i claudius/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$CLAUDIUS_SRC" ]; then
        echo "ERROR: Claudius source not found at $CLAUDIUS_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    # CLAUDE_CREDENTIALS_JSON in particular is a JSON blob full of " and { } —
    # exactly the kind of value the old bare yq template could mangle.
    echo "Generating .env from encrypted secrets..."
    local CLAUDIUS_PLAINTEXT
    CLAUDIUS_PLAINTEXT=$(sops -d "$CLAUDIUS_SECRETS")
    claudius_field() { echo "$CLAUDIUS_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Claudius Configuration (auto-generated from secrets.yaml)"
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n'   "$(dotenv_quote "$(claudius_field '.claude_code_oauth_token')")"
        printf 'CLAUDE_CREDENTIALS_JSON=%s\n'   "$(dotenv_quote "$(claudius_field '.claude_credentials_json')")"
        printf 'GH_TOKEN=%s\n'                  "$(dotenv_quote "$(claudius_field '.gh_token')")"
        printf 'AGENT_NAME=%s\n'                "$(dotenv_quote "$(claudius_field '.agent_name')")"
        printf 'MY_EMAIL=%s\n'                  "$(dotenv_quote "$(claudius_field '.my_email')")"
        printf 'PEER_EMAIL=%s\n'                "$(dotenv_quote "$(claudius_field '.peer_email')")"
        printf 'OWNER_EMAIL=%s\n'               "$(dotenv_quote "$(claudius_field '.owner_email')")"
        printf 'CC_EMAIL=%s\n'                  "$(dotenv_quote "$(claudius_field '.cc_email')")"
        printf 'IMAP_HOST=%s\n'                 "$(dotenv_quote "$(claudius_field '.imap_host')")"
        printf 'IMAP_PORT=%s\n'                 "$(dotenv_quote "$(claudius_field '.imap_port')")"
        printf 'IMAP_USER=%s\n'                 "$(dotenv_quote "$(claudius_field '.imap_user')")"
        printf 'IMAP_PASS=%s\n'                 "$(dotenv_quote "$(claudius_field '.imap_pass')")"
        printf 'SMTP_HOST=%s\n'                 "$(dotenv_quote "$(claudius_field '.smtp_host')")"
        printf 'SMTP_PORT=%s\n'                 "$(dotenv_quote "$(claudius_field '.smtp_port')")"
        printf 'GIT_USER_NAME=%s\n'             "$(dotenv_quote "$(claudius_field '.git_user_name')")"
        printf 'GIT_USER_EMAIL=%s\n'            "$(dotenv_quote "$(claudius_field '.git_user_email')")"
        printf 'JOURNAL_REPO=%s\n'              "$(dotenv_quote "$(claudius_field '.journal_repo')")"
        printf 'ARCHIVE_REPO=%s\n'              "$(dotenv_quote "$(claudius_field '.archive_repo')")"
        printf 'ALLOWED_SENDERS=%s\n'           "$(dotenv_quote "$(claudius_field '.allowed_senders')")"
        printf 'SEND_FIRST=%s\n'                "$(dotenv_quote "$(claudius_field '.send_first')")"
        printf 'POLL_INTERVAL=%s\n'             "$(dotenv_quote "$(claudius_field '.poll_interval')")"
        printf 'MODEL=%s\n'                     "$(dotenv_quote "$(claudius_field '.model')")"
        printf 'MAX_TURNS=%s\n'                 "$(dotenv_quote "$(claudius_field '.max_turns')")"
        printf 'WEEKLY_TURN_QUOTA=%s\n'         "$(dotenv_quote "$(claudius_field '.weekly_turn_quota')")"
        printf 'QUOTA_RESET_DAY=%s\n'           "$(dotenv_quote "$(claudius_field '.quota_reset_day')")"
        printf 'QUOTA_RESET_HOUR_UTC=%s\n'      "$(dotenv_quote "$(claudius_field '.quota_reset_hour_utc')")"
        printf 'MAX_RETRIES_PER_MESSAGE=%s\n'   "$(dotenv_quote "$(claudius_field '.max_retries_per_message')")"
        printf 'REPORT_EVERY_N=%s\n'            "$(dotenv_quote "$(claudius_field '.report_every_n')")"
        printf 'EVOLUTION_PROBABILITY=%s\n'     "$(dotenv_quote "$(claudius_field '.evolution_probability')")"
        printf 'EVOLUTION_MAX_TURNS=%s\n'       "$(dotenv_quote "$(claudius_field '.evolution_max_turns')")"
        printf 'INITIATIVE_PROBABILITY=%s\n'    "$(dotenv_quote "$(claudius_field '.initiative_probability')")"
        printf 'INITIATIVE_MAX_TURNS=%s\n'      "$(dotenv_quote "$(claudius_field '.initiative_max_turns')")"
        printf 'INITIATIVE_COOLDOWN_HOURS=%s\n' "$(dotenv_quote "$(claudius_field '.initiative_cooldown_hours')")"
    } > "$REPO_ROOT/claudius/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/claudius/src"

    # Copy docker compose and .env
    rsync -avz --exclude 'secrets.yaml' "$REPO_ROOT/claudius/" "$REMOTE":~/apps/claudius/

    # Copy source code
    rsync -avz --delete \
        --exclude '.git' \
        --exclude 'node_modules' \
        --exclude '__pycache__' \
        --exclude '.env' \
        --exclude '.env.example' \
        --exclude 'fly.toml' \
        --exclude 'deploy-fly.sh' \
        --exclude 'msmtprc' \
        --exclude '.claude-credentials.json' \
        --exclude 'playwright-storage.json' \
        "$CLAUDIUS_SRC/" "$REMOTE":~/apps/claudius/src/

    # Clean up local .env
    rm -f "$REPO_ROOT/claudius/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/claudius && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "Claudius deployed!"
    echo "  Check logs: ssh $REMOTE 'docker logs -f claudius'"
}

deploy_lugh() {
    echo "Deploying Lugh (historian pen pal agent)..."

    local LUGH_SECRETS="$REPO_ROOT/lugh/secrets.yaml"
    local LUGH_SRC="$HOME/git/individuals/lowell/lugh"

    # Check for secrets file
    if [ ! -f "$LUGH_SECRETS" ]; then
        echo "ERROR: lugh/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i lugh/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$LUGH_SRC" ]; then
        echo "ERROR: Lugh source not found at $LUGH_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets. Decrypt once, then route every value
    # through dotenv_quote so a secret with dotenv-significant bytes survives
    # docker compose's dotenv parser intact (see deploy_outline for rationale).
    echo "Generating .env from encrypted secrets..."
    local LUGH_PLAINTEXT
    LUGH_PLAINTEXT=$(sops -d "$LUGH_SECRETS")
    lugh_field() { echo "$LUGH_PLAINTEXT" | yq -r "$1 // \"\""; }
    {
        echo "# Lugh Configuration (auto-generated from secrets.yaml)"
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n'   "$(dotenv_quote "$(lugh_field '.claude_code_oauth_token')")"
        printf 'GH_TOKEN=%s\n'                  "$(dotenv_quote "$(lugh_field '.gh_token')")"
        printf 'AGENT_NAME=%s\n'                "$(dotenv_quote "$(lugh_field '.agent_name')")"
        printf 'MY_EMAIL=%s\n'                  "$(dotenv_quote "$(lugh_field '.my_email')")"
        printf 'PEER_EMAIL=%s\n'                "$(dotenv_quote "$(lugh_field '.peer_email')")"
        printf 'OWNER_EMAIL=%s\n'               "$(dotenv_quote "$(lugh_field '.owner_email')")"
        printf 'CC_EMAIL=%s\n'                  "$(dotenv_quote "$(lugh_field '.cc_email')")"
        printf 'IMAP_HOST=%s\n'                 "$(dotenv_quote "$(lugh_field '.imap_host')")"
        printf 'IMAP_PORT=%s\n'                 "$(dotenv_quote "$(lugh_field '.imap_port')")"
        printf 'IMAP_USER=%s\n'                 "$(dotenv_quote "$(lugh_field '.imap_user')")"
        printf 'IMAP_PASS=%s\n'                 "$(dotenv_quote "$(lugh_field '.imap_pass')")"
        printf 'SMTP_HOST=%s\n'                 "$(dotenv_quote "$(lugh_field '.smtp_host')")"
        printf 'SMTP_PORT=%s\n'                 "$(dotenv_quote "$(lugh_field '.smtp_port')")"
        printf 'GIT_USER_NAME=%s\n'             "$(dotenv_quote "$(lugh_field '.git_user_name')")"
        printf 'GIT_USER_EMAIL=%s\n'            "$(dotenv_quote "$(lugh_field '.git_user_email')")"
        printf 'JOURNAL_REPO=%s\n'              "$(dotenv_quote "$(lugh_field '.journal_repo')")"
        printf 'ARCHIVE_REPO=%s\n'              "$(dotenv_quote "$(lugh_field '.archive_repo')")"
        printf 'ALLOWED_SENDERS=%s\n'           "$(dotenv_quote "$(lugh_field '.allowed_senders')")"
        printf 'SEND_FIRST=%s\n'                "$(dotenv_quote "$(lugh_field '.send_first')")"
        printf 'POLL_INTERVAL=%s\n'             "$(dotenv_quote "$(lugh_field '.poll_interval')")"
        printf 'MODEL=%s\n'                     "$(dotenv_quote "$(lugh_field '.model')")"
        printf 'MAX_TURNS=%s\n'                 "$(dotenv_quote "$(lugh_field '.max_turns')")"
        printf 'WEEKLY_TURN_QUOTA=%s\n'         "$(dotenv_quote "$(lugh_field '.weekly_turn_quota')")"
        printf 'QUOTA_RESET_DAY=%s\n'           "$(dotenv_quote "$(lugh_field '.quota_reset_day')")"
        printf 'QUOTA_RESET_HOUR_UTC=%s\n'      "$(dotenv_quote "$(lugh_field '.quota_reset_hour_utc')")"
        printf 'MAX_RETRIES_PER_MESSAGE=%s\n'   "$(dotenv_quote "$(lugh_field '.max_retries_per_message')")"
        printf 'REPORT_EVERY_N=%s\n'            "$(dotenv_quote "$(lugh_field '.report_every_n')")"
        printf 'EVOLUTION_PROBABILITY=%s\n'     "$(dotenv_quote "$(lugh_field '.evolution_probability')")"
        printf 'EVOLUTION_MAX_TURNS=%s\n'       "$(dotenv_quote "$(lugh_field '.evolution_max_turns')")"
        printf 'INITIATIVE_PROBABILITY=%s\n'    "$(dotenv_quote "$(lugh_field '.initiative_probability')")"
        printf 'INITIATIVE_MAX_TURNS=%s\n'      "$(dotenv_quote "$(lugh_field '.initiative_max_turns')")"
        printf 'INITIATIVE_COOLDOWN_HOURS=%s\n' "$(dotenv_quote "$(lugh_field '.initiative_cooldown_hours')")"
    } > "$REPO_ROOT/lugh/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/lugh/src"

    # Copy docker compose and .env
    rsync -avz --exclude 'secrets.yaml' "$REPO_ROOT/lugh/" "$REMOTE":~/apps/lugh/

    # Copy source code
    rsync -avz --delete \
        --exclude '.git' \
        --exclude 'node_modules' \
        --exclude '__pycache__' \
        --exclude '.env' \
        --exclude '.env.example' \
        --exclude 'fly.toml' \
        --exclude 'deploy-fly.sh' \
        --exclude 'msmtprc' \
        --exclude '.claude-credentials.json' \
        --exclude 'playwright-storage.json' \
        "$LUGH_SRC/" "$REMOTE":~/apps/lugh/src/

    # Clean up local .env
    rm -f "$REPO_ROOT/lugh/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/lugh && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "Lugh deployed!"
    echo "  Check logs: ssh $REMOTE 'docker logs -f lugh'"
}

case $SERVICE in
    all)
        deploy_scripts
        deploy_backups
        deploy_service caddy
        deploy_site
        deploy_invite
        deploy_galaxy
        deploy_outline
        deploy_kanbn
        deploy_radicale
        deploy_pm_bot
        deploy_matrix
        deploy_contact
        deploy_claudius
        ;;
    scripts)
        deploy_scripts
        ;;
    backups)
        deploy_backups
        ;;
    caddy)
        deploy_service caddy
        ;;
    outline|wiki)
        deploy_outline
        ;;
    kanbn|tasks)
        deploy_kanbn
        ;;
    radicale|dav)
        deploy_radicale
        ;;
    dreamfinder|pm-bot|signal)
        deploy_pm_bot
        ;;
    matrix)
        deploy_matrix
        ;;
    site)
        deploy_site
        ;;
    invite)
        deploy_invite
        ;;
    galaxy)
        deploy_galaxy
        ;;
    imagineering-contact-us|contact)
        deploy_contact
        ;;
    claudius)
        deploy_claudius
        ;;
    lugh)
        deploy_lugh
        ;;
    youtube-rag|rag)
        deploy_youtube_rag
        ;;
    embodied-dreamfinder|edf|avatar)
        deploy_embodied_dreamfinder
        ;;
    livekit)
        deploy_livekit
        ;;
    tech-world-bots|twb)
        deploy_tech_world_bots
        ;;
    notify)
        deploy_notify
        ;;
    familiars-server|familiars)
        deploy_familiars_server
        ;;
    *)
        echo "Unknown service: $SERVICE"
        echo "Usage: $0 <ip> [all|caddy|outline|kanbn|radicale|dreamfinder|embodied-dreamfinder|livekit|matrix|claudius|lugh|youtube-rag|imagineering-contact-us|backups|scripts|site|invite|galaxy]"
        exit 1
        ;;
esac

echo "Deployment complete!"
