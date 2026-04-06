#!/bin/bash
# OCI auto-provisioning — keeps trying until it gets an instance
#
# Strategy:
#   1. Try small (1 OCPU/6GB) first — easier to get capacity
#   2. Once small instance exists, resize to full (4 OCPU/24GB)
#   3. Once at full size, disable the cron job (we're done!)
#   4. Random jitter to avoid looking like a bot

LOG=~/oci-provision.log
LOCK=/tmp/oci-provision.lock
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNTS_FILE="$SCRIPT_DIR/accounts.yaml"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"

# What we're aiming for
SMALL_OCPUS=1
SMALL_MEM=6
FULL_OCPUS=4
FULL_MEM=24

log() { echo "$(date): $*" >> "$LOG"; }

# ── Prevent two copies running at once ──
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

export PATH="$HOME/.local/bin:$PATH"

# ── Random jitter: 0-90 seconds ──
# This avoids a predictable request pattern (Oracle might rate-limit you)
JITTER=$((RANDOM % 90))
log "Sleeping ${JITTER}s jitter..."
sleep "$JITTER"

# ── Cloud-init: runs on the instance after first boot ──
CLOUD_INIT=$(cat << 'CLOUDINIT'
#!/bin/bash
apt-get update && apt-get install -y htop curl docker.io docker-compose

# Keep-alive task — prevents Oracle from reclaiming idle free instances
cat > /opt/keep-alive.sh << 'KEEPALIVE'
#!/bin/bash
timeout 30 dd if=/dev/urandom bs=1M count=50 | md5sum > /dev/null 2>&1
echo "$(date): keep-alive ping" >> /var/log/keep-alive.log
KEEPALIVE
chmod +x /opt/keep-alive.sh
echo "0 */6 * * * root /opt/keep-alive.sh" > /etc/cron.d/keep-alive

echo "Cloud-init complete" >> /var/log/cloud-init-output.log
CLOUDINIT
)

# ── Check dependencies ──
if ! command -v yq &> /dev/null; then
    log "ERROR: yq not installed. Run: pip3 install yq"
    exit 1
fi

all_done=true
NUM_ACCOUNTS=$(yq -r '.accounts | length' "$ACCOUNTS_FILE")

for i in $(seq 0 $((NUM_ACCOUNTS - 1))); do
    NAME=$(yq -r ".accounts[$i].name" "$ACCOUNTS_FILE")
    PROFILE=$(yq -r ".accounts[$i].profile" "$ACCOUNTS_FILE")
    COMPARTMENT_ID=$(yq -r ".accounts[$i].compartment_id" "$ACCOUNTS_FILE")
    SUBNET_ID=$(yq -r ".accounts[$i].subnet_id" "$ACCOUNTS_FILE")
    IMAGE_ID=$(yq -r ".accounts[$i].image_id" "$ACCOUNTS_FILE")
    AVAILABILITY_DOMAIN=$(yq -r ".accounts[$i].availability_domain" "$ACCOUNTS_FILE")
    INSTANCE_NAME=$(yq -r ".accounts[$i].instance_name" "$ACCOUNTS_FILE")

    if [[ "$COMPARTMENT_ID" == *"REPLACE"* ]] || [[ "$COMPARTMENT_ID" == *"paste"* ]]; then
        log "[$NAME] Skipping - not configured yet"
        continue
    fi

    log "[$NAME] Checking for existing instance..."

    # ── Check if we already have an instance ──
    INSTANCE_JSON=$(oci compute instance list \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_ID" \
        --display-name "$INSTANCE_NAME" 2>/dev/null || echo '{"data":[]}')

    RUNNING_ID=$(echo "$INSTANCE_JSON" | jq -r \
        '[.data[] | select(.["lifecycle-state"] == "RUNNING" or .["lifecycle-state"] == "PROVISIONING")] | .[0].id // empty')

    if [ -n "$RUNNING_ID" ]; then
        # ── Instance exists — check if it needs resizing ──
        CURRENT_OCPUS=$(echo "$INSTANCE_JSON" | jq -r \
            "[.data[] | select(.id == \"$RUNNING_ID\")] | .[0][\"shape-config\"].ocpus // 0")

        if [ "$(echo "$CURRENT_OCPUS >= $FULL_OCPUS" | bc -l)" = "1" ]; then
            IP=$(oci compute instance list-vnics \
                --profile "$PROFILE" \
                --instance-id "$RUNNING_ID" 2>/dev/null | jq -r '.data[0]["public-ip"] // "pending"')
            log "[$NAME] ✅ Full instance running ($FULL_OCPUS OCPUs) at $IP — nothing to do!"
            continue
        fi

        # Small instance exists — try to resize it
        LIFECYCLE=$(echo "$INSTANCE_JSON" | jq -r \
            "[.data[] | select(.id == \"$RUNNING_ID\")] | .[0][\"lifecycle-state\"]")

        if [ "$LIFECYCLE" = "RUNNING" ]; then
            log "[$NAME] Small instance found ($CURRENT_OCPUS OCPUs). Resizing to $FULL_OCPUS/$FULL_MEM..."

            RESIZE_OUTPUT=$(oci compute instance update \
                --profile "$PROFILE" \
                --instance-id "$RUNNING_ID" \
                --shape-config "{\"ocpus\": $FULL_OCPUS, \"memoryInGBs\": $FULL_MEM}" \
                --force 2>&1)

            if echo "$RESIZE_OUTPUT" | grep -qi "error\|ServiceError"; then
                log "[$NAME] Resize failed (probably still out of capacity). Will retry next cycle."
                all_done=false
            else
                log "[$NAME] 🎉 Resize initiated! Instance will reboot with $FULL_OCPUS OCPUs."
            fi
        else
            log "[$NAME] Instance in $LIFECYCLE state, waiting..."
            all_done=false
        fi
        continue
    fi

    # ── No instance exists — try to create a small one ──
    all_done=false
    log "[$NAME] No instance found. Trying ${SMALL_OCPUS} OCPU / ${SMALL_MEM}GB..."

    CLOUD_INIT_FILE=$(mktemp)
    echo "$CLOUD_INIT" > "$CLOUD_INIT_FILE"

    OUTPUT=$(SUPPRESS_LABEL_WARNING=True oci compute instance launch \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape "VM.Standard.A1.Flex" \
        --shape-config "{\"ocpus\": $SMALL_OCPUS, \"memoryInGBs\": $SMALL_MEM}" \
        --subnet-id "$SUBNET_ID" \
        --image-id "$IMAGE_ID" \
        --display-name "$INSTANCE_NAME" \
        --assign-public-ip true \
        --ssh-authorized-keys-file "$SSH_KEY_PATH" \
        --user-data-file "$CLOUD_INIT_FILE" \
        --boot-volume-size-in-gbs 50 2>&1)

    rm -f "$CLOUD_INIT_FILE"

    if echo "$OUTPUT" | grep -qi "Out of capacity\|out of host capacity"; then
        log "[$NAME] Out of capacity — will retry in 5 minutes..."
    elif echo "$OUTPUT" | grep -qi "TooManyRequests"; then
        log "[$NAME] Rate limited (429) — backing off 60s..."
        sleep 60
    elif echo "$OUTPUT" | grep -qi "error\|failed\|ServiceError"; then
        ERROR_MSG=$(echo "$OUTPUT" | jq -r '.message // empty' 2>/dev/null || echo "$OUTPUT" | head -2)
        log "[$NAME] Error: $ERROR_MSG"
    else
        INSTANCE_ID=$(echo "$OUTPUT" | jq -r '.data.id // empty')
        log "[$NAME] 🎉 Small instance created! (ID: $INSTANCE_ID) — will resize next cycle."
    fi
done

# ── If everything is at full size, we're done — disable the cron ──
if $all_done; then
    log "All instances at full capacity! Disabling cron job. 🎊"
    crontab -l | grep -v "retry-provision" | crontab -
fi

log "Provisioning cycle complete."
