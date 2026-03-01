#!/bin/bash
# Deploy services to any VPS
# Usage: ./scripts/deploy-to.sh <ip> [service]
# Services: all, caddy, outline, kanbn, radicale, backups, scripts

set -e

# SOPS age key location
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

if [ -z "$1" ]; then
  echo "Usage: $0 <ip> [service]"
  echo "  ip: VPS IP address or hostname"
  echo "  service: all|caddy|outline|kanbn|radicale|backups|scripts (default: all)"
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

    # Set up health check cron
    local PM_BOT_SECRETS="$REPO_ROOT/imagineering-pm-bot/secrets.yaml"
    if [ -f "$PM_BOT_SECRETS" ]; then
        echo "Setting up health check cron..."
        local BOT_TOKEN
        BOT_TOKEN=$(sops -d "$PM_BOT_SECRETS" | yq -r '.telegram_bot_token')
        ssh "$REMOTE" "mkdir -p ~/logs && echo '0 * * * * nick TELEGRAM_BOT_TOKEN=$BOT_TOKEN TELEGRAM_CHAT_ID=PLACEHOLDER_CHAT_ID TELEGRAM_THREAD_ID=PLACEHOLDER_THREAD_ID /opt/scripts/health-check.sh >> /home/nick/logs/health-check.log 2>&1' | sudo tee /etc/cron.d/health-check > /dev/null"
        echo "Health check cron installed (hourly)"
    else
        echo "WARNING: imagineering-pm-bot/secrets.yaml not found, skipping health check cron"
    fi

    echo "Scripts deployed to /opt/scripts/"
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

    local KAN_SRC="$HOME/git/orgs/kanbn/kan"

    # Check for source code
    if [ ! -d "$KAN_SRC" ]; then
        echo "ERROR: kan source not found at $KAN_SRC"
        echo "Clone it with: git clone git@github.com:kanbn/kan.git $KAN_SRC"
        return 1
    fi

    # Deploy .env and compose files (not source code)
    ssh "$REMOTE" "mkdir -p ~/apps/kanbn"
    rsync -avz --delete --exclude 'secrets.yaml' --exclude 'kan-source' "$REPO_ROOT/kanbn/" "$REMOTE":~/apps/kanbn/

    # Clean up local .env
    rm -f "$REPO_ROOT/kanbn/.env"

    # Build Docker image locally for linux/amd64 (VPS is x86_64)
    local IMAGE_TAR="/tmp/kanbn-image.tar"
    echo "Building kanbn image locally for linux/amd64..."
    docker buildx build \
        --platform linux/amd64 \
        --pull \
        -t kanbn:local \
        -f "$KAN_SRC/apps/web/Dockerfile" \
        "$KAN_SRC" \
        --output "type=docker,dest=$IMAGE_TAR"

    # Transfer image to VPS
    echo "Transferring image to VPS..."
    rsync -az --progress "$IMAGE_TAR" "$REMOTE":/tmp/kanbn-image.tar

    # Load image and restart container
    echo "Loading image and restarting container..."
    ssh "$REMOTE" "docker load < /tmp/kanbn-image.tar && rm /tmp/kanbn-image.tar && cd ~/apps/kanbn && docker compose up -d"

    # Clean up local tar
    rm -f "$IMAGE_TAR"

    echo "Kan.bn deployed!"
    echo "  URL: https://kan.imagineering.cc"
    echo "  Note: First user to sign up becomes admin"
}

deploy_pm_bot() {
    echo "Deploying imagineering-pm-bot (Telegram)..."

    local PM_BOT_SECRETS="$REPO_ROOT/imagineering-pm-bot/secrets.yaml"
    local PM_BOT_SRC="$HOME/git/orgs/imagineering/imagineering-pm-bot"

    # Check for secrets file
    if [ ! -f "$PM_BOT_SECRETS" ]; then
        echo "ERROR: imagineering-pm-bot/secrets.yaml not found"
        echo "Create it from secrets.yaml.example and encrypt with: sops -e -i imagineering-pm-bot/secrets.yaml"
        return 1
    fi

    # Check for source code
    if [ ! -d "$PM_BOT_SRC" ]; then
        echo "ERROR: imagineering-pm-bot source not found at $PM_BOT_SRC"
        return 1
    fi

    # Generate .env from encrypted secrets
    echo "Generating .env from encrypted secrets..."
    sops -d "$PM_BOT_SECRETS" | yq -r '"# imagineering-pm-bot Configuration (auto-generated from secrets.yaml)
TELEGRAM_BOT_TOKEN=\(.telegram_bot_token)
KAN_API_KEY=\(.kan_api_key)
CLAUDE_REFRESH_TOKEN=\(.claude_refresh_token)
KAN_BASE_URL=\(.kan_base_url)
OUTLINE_API_KEY=\(.outline_api_key)
OUTLINE_BASE_URL=\(.outline_base_url)
RADICALE_PASSWORD=\(.radicale_password)
SPRINT_START_DATE=\(.sprint_start_date)
REMINDER_INTERVAL_HOURS=\(.reminder_interval_hours)
ADMIN_USER_IDS=\(.admin_user_ids)
PLAYWRIGHT_ENABLED=\(.playwright_enabled)"' > "$REPO_ROOT/imagineering-pm-bot/.env"

    # Deploy files
    ssh "$REMOTE" "mkdir -p ~/apps/imagineering-pm-bot/src"

    # Copy docker compose and .env
    rsync -avz --exclude 'secrets.yaml' "$REPO_ROOT/imagineering-pm-bot/" "$REMOTE":~/apps/imagineering-pm-bot/

    # Copy source code
    rsync -avz --delete --exclude 'node_modules' --exclude 'dist' --exclude '.env' --exclude 'data' "$PM_BOT_SRC/" "$REMOTE":~/apps/imagineering-pm-bot/src/

    # Clean up local .env
    rm -f "$REPO_ROOT/imagineering-pm-bot/.env"

    # Build and start
    ssh "$REMOTE" "cd ~/apps/imagineering-pm-bot && DOCKER_BUILDKIT=1 docker compose build --pull && docker compose up -d"

    echo "imagineering-pm-bot deployed!"
    echo "  Check logs: ssh $REMOTE 'docker logs -f imagineering-pm-bot'"
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

case $SERVICE in
    all)
        deploy_scripts
        deploy_backups
        deploy_service caddy
        deploy_outline
        deploy_kanbn
        deploy_radicale
        deploy_pm_bot
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
    imagineering-pm-bot|pm-bot|telegram)
        deploy_pm_bot
        ;;
    *)
        echo "Unknown service: $SERVICE"
        echo "Usage: $0 <ip> [all|caddy|outline|kanbn|radicale|imagineering-pm-bot|backups|scripts]"
        exit 1
        ;;
esac

echo "Deployment complete!"
