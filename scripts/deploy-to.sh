#!/bin/bash
# Deploy services to any VPS
# Usage: ./scripts/deploy-to.sh <ip> [service]
# Services: all, caddy, site, outline, kanbn, radicale, matrix, contact, backups, scripts

set -e

# SOPS age key location
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

if [ -z "$1" ]; then
  echo "Usage: $0 <ip> [service]"
  echo "  ip: VPS IP address or hostname"
  echo "  service: all|caddy|site|outline|kanbn|radicale|matrix|backups|scripts (default: all)"
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
    ssh "$REMOTE" "mkdir -p ~/apps/site"
    rsync -avz --delete --exclude '.git' "$SITE_SRC/" "$REMOTE":~/apps/site/
    echo "Site deployed to ~/apps/site"
}

deploy_contact() {
    echo "Deploying contact form relay..."

    local CONTACT_SECRETS="$REPO_ROOT/contact/secrets.yaml"

    # Check for secrets file
    if [ ! -f "$CONTACT_SECRETS" ]; then
        echo "ERROR: contact/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i contact/secrets.yaml"
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
CONTACT_TO=\(.contact_to)"' > "$REPO_ROOT/contact/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/contact"
    rsync -avz --delete --exclude 'secrets.yaml' "$REPO_ROOT/contact/" "$REMOTE":~/apps/contact/

    # Clean up local .env
    rm -f "$REPO_ROOT/contact/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/contact && docker compose build && docker compose up -d"

    echo "Contact form relay deployed!"
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

deploy_backups() {
    echo "Deploying backup configuration..."

    local BACKUP_SECRETS="$REPO_ROOT/backups/secrets.yaml"

    if [ ! -f "$BACKUP_SECRETS" ]; then
        echo "WARNING: No backups/secrets.yaml found. Skipping backup setup."
        return 0
    fi

    # Decrypt and extract GCS config
    echo "Extracting GCS configuration..."
    local GCS_BUCKET
    local GCS_PROJECT
    GCS_BUCKET=$(sops -d "$BACKUP_SECRETS" | yq -r '.gcs_bucket')
    GCS_PROJECT=$(sops -d "$BACKUP_SECRETS" | yq -r '.gcs_project')

    if [ -z "$GCS_BUCKET" ] || [ "$GCS_BUCKET" = "null" ]; then
        echo "ERROR: Invalid backup secrets. Check backups/secrets.yaml"
        return 1
    fi

    # Generate rclone config for Google Cloud Storage
    # Uses GCE instance service account — no credentials needed
    echo "Generating rclone configuration (GCS)..."
    cat > /tmp/rclone.conf << EOF
[gcs]
type = google cloud storage
project_number = $GCS_PROJECT
bucket_policy_only = true
EOF

    # Deploy rclone config
    ssh "$REMOTE" "mkdir -p ~/.config/rclone"
    scp /tmp/rclone.conf "$REMOTE":~/.config/rclone/rclone.conf
    ssh "$REMOTE" "chmod 600 ~/.config/rclone/rclone.conf"
    rm /tmp/rclone.conf

    # Create GCS bucket if it doesn't exist
    echo "Ensuring GCS bucket exists..."
    ssh "$REMOTE" "rclone mkdir gcs:$GCS_BUCKET 2>/dev/null || true"

    # Deploy backup scripts
    echo "Deploying backup scripts..."
    ssh "$REMOTE" "sudo mkdir -p /opt/scripts"
    scp "$REPO_ROOT/scripts/backup.sh" "$REMOTE":/tmp/backup.sh
    scp "$REPO_ROOT/scripts/restore.sh" "$REMOTE":/tmp/restore.sh
    ssh "$REMOTE" "sudo mv /tmp/backup.sh /tmp/restore.sh /opt/scripts/"
    ssh "$REMOTE" "sudo chmod +x /opt/scripts/backup.sh /opt/scripts/restore.sh"
    ssh "$REMOTE" "sudo chown nick:nick /opt/scripts/*.sh"

    # Test rclone connection
    echo "Testing rclone connection..."
    if ssh "$REMOTE" "rclone lsd gcs: 2>/dev/null"; then
        echo "rclone connection successful!"
    else
        echo "Connection test failed - check GCE service account permissions"
    fi

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
    echo "  - rclone config: ~/.config/rclone/rclone.conf (GCS via service account)"
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
LOG_LEVEL=\(.log_level)"' > "$REPO_ROOT/dreamfinder/.env"

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

    # Build and start (bot + signal-cli-rest-api)
    ssh "$REMOTE" "cd ~/apps/dreamfinder && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "Dreamfinder deployed!"
    echo "  Check logs: ssh $REMOTE 'docker logs -f dreamfinder'"
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
    contact)
        deploy_contact
        ;;
    *)
        echo "Unknown service: $SERVICE"
        echo "Usage: $0 <ip> [all|caddy|outline|kanbn|radicale|dreamfinder|matrix|contact|backups|scripts|site]"
        exit 1
        ;;
esac

echo "Deployment complete!"
