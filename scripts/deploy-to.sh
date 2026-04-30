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
  echo "  service: all|caddy|site|outline|kanbn|radicale|matrix|claudius|imagineering-contact-us|backups|scripts (default: all)"
  exit 1
fi

IP=$1
SERVICE=${2:-all}
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="nick@$IP"

echo "Deploying to $REMOTE..."

deploy_scripts() {
    echo "Deploying scripts..."
    ssh "$REMOTE" "sudo mkdir -p /opt/scripts"
    rsync -avz "$REPO_ROOT/scripts/" "$REMOTE":/tmp/scripts/
    ssh "$REMOTE" "sudo mv /tmp/scripts/* /opt/scripts/ && sudo chmod +x /opt/scripts/*.sh"

    # Set up health check cron (uses Telegram for server alerts)
    # Requires TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_THREAD_ID in backups/secrets.yaml
    local BACKUP_SECRETS="$REPO_ROOT/backups/secrets.yaml"
    if [ -f "$BACKUP_SECRETS" ] && sops -d "$BACKUP_SECRETS" | yq -e '.telegram_bot_token' > /dev/null 2>&1; then
        echo "Setting up health check cron..."
        local BOT_TOKEN CHAT_ID THREAD_ID
        BOT_TOKEN=$(sops -d "$BACKUP_SECRETS" | yq -r '.telegram_bot_token')
        CHAT_ID=$(sops -d "$BACKUP_SECRETS" | yq -r '.telegram_chat_id')
        THREAD_ID=$(sops -d "$BACKUP_SECRETS" | yq -r '.telegram_thread_id')
        ssh "$REMOTE" "mkdir -p ~/logs && echo '0 * * * * nick TELEGRAM_BOT_TOKEN=$BOT_TOKEN TELEGRAM_CHAT_ID=$CHAT_ID TELEGRAM_THREAD_ID=$THREAD_ID /opt/scripts/health-check.sh >> /home/nick/logs/health-check.log 2>&1' | sudo tee /etc/cron.d/health-check > /dev/null"
        echo "Health check cron installed (hourly)"
    else
        echo "NOTE: No Telegram credentials in backups/secrets.yaml, skipping health check cron"
        echo "  Add telegram_bot_token, telegram_chat_id, telegram_thread_id to enable alerts"
    fi

    echo "Scripts deployed to /opt/scripts/"
}

deploy_site() {
    local SITE_SRC="$HOME/git/orgs/imagineering/website"

    if [ ! -d "$SITE_SRC" ]; then
        echo "ERROR: website repo not found at $SITE_SRC"
        return 1
    fi

    echo "Deploying imagineering.cc landing page..."
    ssh "$REMOTE" "mkdir -p /srv/site"
    rsync -avz --delete --exclude '.git' --exclude '.github' --exclude 'README.md' "$SITE_SRC/" "$REMOTE":/srv/site/
    echo "Site deployed to /srv/site"
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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$CONTACT_SECRETS" | yq -r '"# Contact Form Configuration (auto-generated from secrets.yaml)
SMTP_HOST=\(.smtp_host)
SMTP_PORT=\(.smtp_port)
SMTP_USERNAME=\(.smtp_username)
SMTP_PASSWORD=\(.smtp_password)
SMTP_FROM_EMAIL=\(.smtp_from_email)
CONTACT_TO=\(.contact_to)"' > "$REPO_ROOT/imagineering-contact-us/.env"

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
    ssh "$REMOTE" "cd ~/apps/$svc && docker compose pull && docker compose up -d"
}

deploy_notify() {
    echo "Deploying notify (Telegram notify proxy)..."

    local NOTIFY_SECRETS="$REPO_ROOT/notify/secrets.yaml"
    if [ ! -f "$NOTIFY_SECRETS" ]; then
        echo "ERROR: notify/secrets.yaml not found"
        echo "Create from notify/secrets.yaml.example and encrypt with: sops -e -i notify/secrets.yaml"
        return 1
    fi

    echo "Generating .env from encrypted secrets..."
    sops -d "$NOTIFY_SECRETS" | yq -r '"TELEGRAM_BOT_TOKEN=\(.telegram_bot_token)
TELEGRAM_CHAT_ID=\(.telegram_chat_id)
NOTIFY_API_KEY=\(.notify_api_key)"' > "$REPO_ROOT/notify/.env"

    ssh "$REMOTE" "mkdir -p ~/apps/notify"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/notify/" "$REMOTE":~/apps/notify/

    rm -f "$REPO_ROOT/notify/.env"

    ssh "$REMOTE" "cd ~/apps/notify && docker compose build && docker compose up -d"

    echo "notify deployed!"
    echo "  Endpoint: https://notify.imagineering.cc"
    echo "  Health:   curl https://notify.imagineering.cc/health"
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

    # Configure SSH to use deploy key for the backup repo
    ssh "$REMOTE" 'mkdir -p ~/.ssh/config.d && cat > ~/.ssh/config.d/imagineering-backups << '\''SSHEOF'\''
Host github-backups
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

    echo "Backup configuration complete!"
    echo "  - GitHub backup: imagineering-cc/imagineering-backups (private repo)"
    echo "  - Deploy key: ~/.ssh/imagineering-backups-deploy"
    echo "  - Scripts: /opt/scripts/backup.sh, /opt/scripts/restore.sh"
    echo "  - Cron: Daily at 4 AM"
    echo ""
    echo "Test with: ssh $REMOTE '/opt/scripts/backup.sh all'"
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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$OUTLINE_SECRETS" | yq -r '"# Outline Configuration (auto-generated from secrets.yaml)
OUTLINE_URL=\(.outline_url)

# Generated secrets
SECRET_KEY=\(.secret_key)
UTILS_SECRET=\(.utils_secret)

# Postgres
POSTGRES_PASSWORD=\(.postgres_password)

# MinIO (S3-compatible storage)
MINIO_ROOT_USER=\(.minio_root_user)
MINIO_ROOT_PASSWORD=\(.minio_root_password)
MINIO_URL=\(.minio_url)

# SMTP
SMTP_HOST=\(.smtp_host)
SMTP_PORT=\(.smtp_port)
SMTP_USERNAME=\(.smtp_username)
SMTP_PASSWORD=\(.smtp_password)
SMTP_FROM_EMAIL=\(.smtp_from_email)
SMTP_SECURE=\(.smtp_secure)"' > "$REPO_ROOT/outline/.env"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$KANBN_SECRETS" | yq -r '"# Kan.bn Configuration (auto-generated from secrets.yaml)
KANBN_URL=\(.kanbn_url)
AUTH_SECRET=\(.auth_secret)
POSTGRES_PASSWORD=\(.postgres_password)
SMTP_HOST=\(.smtp_host)
SMTP_PORT=\(.smtp_port)
SMTP_USERNAME=\(.smtp_username)
SMTP_PASSWORD=\(.smtp_password)
SMTP_FROM_EMAIL=\(.smtp_from_email)
TRELLO_API_KEY=\(.trello_api_key)
TRELLO_API_SECRET=\(.trello_api_secret)
S3_ENDPOINT=\(.s3_endpoint)
S3_ACCESS_KEY_ID=\(.s3_access_key_id)
S3_SECRET_ACCESS_KEY=\(.s3_secret_access_key)
NEXT_PUBLIC_STORAGE_URL=\(.next_public_storage_url)
WEBHOOK_URL=\(.webhook_url)
WEBHOOK_SECRET=\(.webhook_secret)"' > "$REPO_ROOT/kanbn/.env"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$PM_BOT_SECRETS" | yq -r '"# Dreamfinder Configuration (auto-generated from secrets.yaml)
ANTHROPIC_API_KEY=\(.anthropic_api_key)
MATRIX_HOMESERVER=\(.matrix_homeserver)
MATRIX_ACCESS_TOKEN=\(.matrix_access_token)
KAN_BASE_URL=\(.kan_base_url)
KAN_API_KEY=\(.kan_api_key)
OUTLINE_BASE_URL=\(.outline_base_url)
OUTLINE_API_KEY=\(.outline_api_key)
RADICALE_BASE_URL=\(.radicale_base_url)
RADICALE_USERNAME=\(.radicale_username)
RADICALE_PASSWORD=\(.radicale_password)
PLAYWRIGHT_ENABLED=\(.playwright_enabled)
BOT_NAME=\(.bot_name)
LOG_LEVEL=\(.log_level)
API_KEY=\(.api_key)
LIVEKIT_URL=\(.livekit_url)
LIVEKIT_API_KEY=\(.livekit_api_key)
LIVEKIT_API_SECRET=\(.livekit_api_secret)
ADMIN_IDS=\(.admin_ids)
MATRIX_ALWAYS_RESPOND_ROOMS=\(.matrix_always_respond_rooms)
CALENDAR_URL=\(.calendar_url)
EVENT_TIMEZONE=\(.event_timezone)
DEPLOY_ANNOUNCE_GROUP_ID=\(.deploy_announce_group_id)"' > "$REPO_ROOT/dreamfinder/.env"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$EDF_SECRETS" | yq -r '"# Embodied Dreamfinder Configuration (auto-generated from secrets.yaml)
OPENAI_API_KEY=\(.openai_api_key)
KAN_BASE_URL=\(.kan_base_url)
KAN_API_KEY=\(.kan_api_key)
KAN_BOARD_ID=\(.kan_board_id)
OUTLINE_BASE_URL=\(.outline_base_url)
OUTLINE_API_KEY=\(.outline_api_key)
RADICALE_CALENDAR_URL=\(.radicale_calendar_url)
RADICALE_USERNAME=\(.radicale_username)
RADICALE_PASSWORD=\(.radicale_password)
DREAMFINDER_API_URL=\(.dreamfinder_api_url)
DREAMFINDER_API_KEY=\(.dreamfinder_api_key)
LIVEKIT_URL=\(.livekit_url)
LIVEKIT_API_KEY=\(.livekit_api_key)
LIVEKIT_API_SECRET=\(.livekit_api_secret)"' > "$REPO_ROOT/embodied-dreamfinder/.env"

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

    # Build and start
    ssh "$REMOTE" "cd ~/apps/embodied-dreamfinder && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

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

    # Generate livekit.yaml with real credentials and IP
    sed -e "s/LIVEKIT_API_KEY/$API_KEY/" \
        -e "s/LIVEKIT_API_SECRET/$API_SECRET/" \
        "$REPO_ROOT/livekit/livekit.yaml" > "$REPO_ROOT/livekit/livekit-generated.yaml"

    # Inject node_ip if external IP is set
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
        sed -i'' -e "/use_external_ip: true/a\\
  node_ip: $EXTERNAL_IP" "$REPO_ROOT/livekit/livekit-generated.yaml"
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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$TWB_SECRETS" | yq -r '"LIVEKIT_URL=\(.livekit_url)
LIVEKIT_API_KEY=\(.livekit_api_key)
LIVEKIT_API_SECRET=\(.livekit_api_secret)
ANTHROPIC_API_KEY=\(.anthropic_api_key)
OPENAI_API_KEY=\(.openai_api_key)
KAN_BASE_URL=\(.kan_base_url)
KAN_API_KEY=\(.kan_api_key)
KAN_BOARD_ID=\(.kan_board_id)
OUTLINE_BASE_URL=\(.outline_base_url)
OUTLINE_API_KEY=\(.outline_api_key)"' > "$REPO_ROOT/tech-world-bots/.env"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$MATRIX_SECRETS" | yq -r '"# Matrix Configuration (auto-generated from secrets.yaml)
MATRIX_SERVER_NAME=\(.matrix_server_name)
REGISTRATION_TOKEN=\(.registration_token)
RELAY_AS_TOKEN=\(.relay_as_token)
RELAY_HS_TOKEN=\(.relay_hs_token)
PORTAL_ROOMS=\(.portal_rooms)
HUB_ROOM_ID=\(.hub_room_id)
RELAY_DOUBLE_PUPPETS=\(.relay_double_puppets)
RELAY_LOG_LEVEL=\(.relay_log_level)"' > "$REPO_ROOT/matrix/.env"

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

    # Build relay bot and start all services
    ssh "$REMOTE" "cd ~/apps/matrix && docker compose pull && DOCKER_BUILDKIT=1 docker compose build relay-bot && docker compose up -d"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$RAG_SECRETS" | yq -r '"# YouTube RAG Configuration (auto-generated from secrets.yaml)
ANTHROPIC_API_KEY=\(.anthropic_api_key)
YOUTUBE_API_KEY=\(.youtube_api_key)"' > "$REPO_ROOT/youtube-rag/.env"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$CLAUDIUS_SECRETS" | yq -r '"# Claudius Configuration (auto-generated from secrets.yaml)
CLAUDE_CODE_OAUTH_TOKEN=\(.claude_code_oauth_token)
CLAUDE_CREDENTIALS_JSON=\(.claude_credentials_json)
GH_TOKEN=\(.gh_token)
AGENT_NAME=\(.agent_name)
MY_EMAIL=\(.my_email)
PEER_EMAIL=\(.peer_email)
OWNER_EMAIL=\(.owner_email)
CC_EMAIL=\(.cc_email)
IMAP_HOST=\(.imap_host)
IMAP_PORT=\(.imap_port)
IMAP_USER=\(.imap_user)
IMAP_PASS=\(.imap_pass)
SMTP_HOST=\(.smtp_host)
SMTP_PORT=\(.smtp_port)
GIT_USER_NAME=\(.git_user_name)
GIT_USER_EMAIL=\(.git_user_email)
JOURNAL_REPO=\(.journal_repo)
ARCHIVE_REPO=\(.archive_repo)
ALLOWED_SENDERS=\(.allowed_senders)
SEND_FIRST=\(.send_first)
POLL_INTERVAL=\(.poll_interval)
MODEL=\(.model)
MAX_TURNS=\(.max_turns)
WEEKLY_TURN_QUOTA=\(.weekly_turn_quota)
QUOTA_RESET_DAY=\(.quota_reset_day)
QUOTA_RESET_HOUR_UTC=\(.quota_reset_hour_utc)
MAX_RETRIES_PER_MESSAGE=\(.max_retries_per_message)
REPORT_EVERY_N=\(.report_every_n)
EVOLUTION_PROBABILITY=\(.evolution_probability)
EVOLUTION_MAX_TURNS=\(.evolution_max_turns)
INITIATIVE_PROBABILITY=\(.initiative_probability)
INITIATIVE_MAX_TURNS=\(.initiative_max_turns)
INITIATIVE_COOLDOWN_HOURS=\(.initiative_cooldown_hours)"' > "$REPO_ROOT/claudius/.env"

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

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$LUGH_SECRETS" | yq -r '"# Lugh Configuration (auto-generated from secrets.yaml)
CLAUDE_CODE_OAUTH_TOKEN=\(.claude_code_oauth_token)
GH_TOKEN=\(.gh_token)
AGENT_NAME=\(.agent_name)
MY_EMAIL=\(.my_email)
PEER_EMAIL=\(.peer_email)
OWNER_EMAIL=\(.owner_email)
CC_EMAIL=\(.cc_email)
IMAP_HOST=\(.imap_host)
IMAP_PORT=\(.imap_port)
IMAP_USER=\(.imap_user)
IMAP_PASS=\(.imap_pass)
SMTP_HOST=\(.smtp_host)
SMTP_PORT=\(.smtp_port)
GIT_USER_NAME=\(.git_user_name)
GIT_USER_EMAIL=\(.git_user_email)
JOURNAL_REPO=\(.journal_repo)
ARCHIVE_REPO=\(.archive_repo)
ALLOWED_SENDERS=\(.allowed_senders)
SEND_FIRST=\(.send_first)
POLL_INTERVAL=\(.poll_interval)
MODEL=\(.model)
MAX_TURNS=\(.max_turns)
WEEKLY_TURN_QUOTA=\(.weekly_turn_quota)
QUOTA_RESET_DAY=\(.quota_reset_day)
QUOTA_RESET_HOUR_UTC=\(.quota_reset_hour_utc)
MAX_RETRIES_PER_MESSAGE=\(.max_retries_per_message)
REPORT_EVERY_N=\(.report_every_n)
EVOLUTION_PROBABILITY=\(.evolution_probability)
EVOLUTION_MAX_TURNS=\(.evolution_max_turns)
INITIATIVE_PROBABILITY=\(.initiative_probability)
INITIATIVE_MAX_TURNS=\(.initiative_max_turns)
INITIATIVE_COOLDOWN_HOURS=\(.initiative_cooldown_hours)"' > "$REPO_ROOT/lugh/.env"

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
    *)
        echo "Unknown service: $SERVICE"
        echo "Usage: $0 <ip> [all|caddy|outline|kanbn|radicale|dreamfinder|embodied-dreamfinder|livekit|matrix|claudius|lugh|youtube-rag|imagineering-contact-us|backups|scripts|site]"
        exit 1
        ;;
esac

echo "Deployment complete!"
