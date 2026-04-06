# Robin's Guide to Free Cloud Servers with OCI

Hey Robin! This guide will walk you through setting up an automated script that keeps trying to grab a free ARM server from Oracle Cloud until it works. These are legitimately powerful machines (4 CPU cores, 24GB RAM) and they're **free forever** on Oracle's Always Free tier.

The catch? Everyone wants one, so they're almost always "out of capacity." Hence the retry script — it tries every 5 minutes until one slips through.

## What You're Getting

```
┌─────────────────────────────────────────┐
│  Oracle Cloud Always Free ARM Instance  │
│                                         │
│  • 4 OCPU (ARM cores) / 24GB RAM       │
│  • 50GB boot disk                       │
│  • Ubuntu 24.04                         │
│  • Public IP address                    │
│  • Actually free. Forever. Not a trial. │
└─────────────────────────────────────────┘
```

## What You'll Need

- A machine that stays on 24/7 (a Raspberry Pi is perfect, but any always-on Linux box works)
- An Oracle Cloud account (free)
- ~30 minutes of setup time
- A cup of tea

---

## Step 1: Create an Oracle Cloud Account

Go to [cloud.oracle.com](https://cloud.oracle.com) and sign up for a free account.

Pick a **Home Region** close to you — this matters because Always Free resources are region-locked. You can't change it later.

> **Pro tip:** Less popular regions (like Melbourne or Sydney) tend to have more capacity than US regions. Pick somewhere not everyone else is picking.

Once you're in, consider upgrading to **Pay As You Go (PAYG)**. This does NOT mean you'll be charged — Always Free resources stay free. But PAYG accounts get priority for capacity, which dramatically improves your chances. Nick's Sydney instance provisioned within minutes of upgrading to PAYG.

---

## Step 2: Install the OCI CLI

On your always-on machine (the Pi, or wherever the retry script will run):

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Follow the prompts. Accept the defaults.

Then verify it works:
```bash
oci --version
```

---

## Step 3: Set Up OCI Authentication

Calm down Robin, lmgtfy — Oracle has a setup wizard that does all the API key stuff for you:

```bash
oci setup config
```

This will ask you a series of questions. Here's where to find the answers:

| Question | Where to find it |
|----------|-----------------|
| **User OCID** | OCI Console → Profile (top right) → My Profile → OCID (copy it) |
| **Tenancy OCID** | OCI Console → Profile → Tenancy → OCID |
| **Region** | The home region you picked at signup (e.g., `ap-sydney-1`) |
| **Generate API key?** | Say **yes** — it creates the key for you |

Calm down Robin, lmgtfy — when it generates the key, it'll print a **public key** block. You need to upload it:

1. Go to OCI Console → Profile → My Profile → API Keys → Add API Key
2. Choose "Paste Public Key"
3. Paste the public key the CLI just printed
4. Click Add

That's it. The CLI handles the private key, the config file, all of it.

> **Multiple accounts?** If you want to try multiple OCI regions/accounts (improves your odds), run `oci setup config` again and give each one a different **profile name**. The config file lives at `~/.oci/config` and looks like:
> ```ini
> [DEFAULT]
> user=ocid1.user.oc1..aaaa...
> fingerprint=ab:cd:ef:...
> tenancy=ocid1.tenancy.oc1..aaaa...
> region=ap-melbourne-1
> key_file=~/.oci/oci_api_key.pem
>
> [sydney]
> user=ocid1.user.oc1..bbbb...
> fingerprint=12:34:56:...
> tenancy=ocid1.tenancy.oc1..bbbb...
> region=ap-sydney-1
> key_file=~/.oci/sydney_api_key.pem
> ```

---

## Step 4: Gather Your OCI Resource IDs

You need a few IDs from the OCI Console. Calm down Robin, lmgtfy — it's just clicking and copying, no key generation involved:

### 4a. Compartment ID

Your tenancy OCID doubles as the root compartment ID. You already have this from Step 3.

### 4b. Create a VCN (Virtual Network)

OCI Console → Networking → Virtual Cloud Networks → Start VCN Wizard → "Create VCN with Internet Connectivity"

- Name it whatever you want (e.g., `robin-vcn`)
- Accept defaults
- Click Create

Once created, go into the VCN → Subnets → click the **Public Subnet** → copy the **Subnet OCID**.

### 4c. Find an ARM Image ID

OCI Console → Compute → Instances → Create Instance (don't actually create it yet!)

- Change the **Shape** to `VM.Standard.A1.Flex` (that's the free ARM one)
- Under **Image**, pick **Ubuntu 24.04** (Canonical)
- Click "Change Image" to see the image details — copy the **Image OCID**
- Cancel out of the create dialog

### 4d. Availability Domain

In that same Create Instance dialog, the **Availability Domain** is shown at the top. It looks like `Xxxx:REGION-AD-1`. Copy it exactly.

---

## Step 5: Set Up an SSH Key

The instance needs an SSH key so you can log in after it's created.

If you don't already have one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

Calm down Robin, lmgtfy — this just creates a key pair. No accounts, no uploads, no API nonsense. The script will pass the public key to Oracle when creating the instance, and then you can SSH in with the private key. That's it.

---

## Step 6: Install Dependencies

On your always-on machine:

```bash
# jq for parsing JSON responses from OCI
sudo apt-get install -y jq bc

# yq for parsing the accounts config file
pip3 install yq
```

---

## Step 7: Create the Accounts Config

Create a directory for the provisioning scripts:

```bash
mkdir -p ~/oci-provision
```

Create `~/oci-provision/accounts.yaml` with your details:

```yaml
# OCI accounts for auto-provisioning
# Paste in the IDs you collected in Step 4

accounts:
  - name: my-server           # whatever you want to call it
    profile: DEFAULT           # matches the profile name in ~/.oci/config
    region: ap-sydney-1        # your OCI region
    compartment_id: "ocid1.tenancy.oc1..paste-yours-here"
    subnet_id: "ocid1.subnet.oc1.ap-sydney-1.paste-yours-here"
    image_id: "ocid1.image.oc1.ap-sydney-1.paste-yours-here"
    availability_domain: "Xxxx:AP-SYDNEY-1-AD-1"
    instance_name: "robin-server"
```

> **Want to double your chances?** Create a second free OCI account in a different region, run `oci setup config` with a new profile name, and add a second entry to this file. The script tries all accounts every cycle.

---

## Step 8: Create the Retry Script

Create `~/oci-provision/retry-provision.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x ~/oci-provision/retry-provision.sh
```

---

## Step 9: Set Up the Cron Job

This is the magic — cron runs the script every 5 minutes, 24/7, until an instance appears:

```bash
# Add the cron job
(crontab -l 2>/dev/null; echo "*/5 * * * * $HOME/oci-provision/retry-provision.sh") | crontab -

# Verify it's installed
crontab -l
```

---

## Step 10: Wait (and Watch)

The script logs everything to `~/oci-provision.log`. Check on it:

```bash
# See recent activity
tail -20 ~/oci-provision.log

# Watch it live
tail -f ~/oci-provision.log
```

You'll see a lot of "Out of capacity" messages. That's normal. It could take hours, days, or (rarely) weeks. PAYG accounts tend to succeed much faster.

When it finally works, you'll see:
```
🎉 Small instance created!
```

Then a few cycles later:
```
🎉 Resize initiated! Instance will reboot with 4 OCPUs.
```

And finally:
```
✅ Full instance running (4 OCPUs) at 123.45.67.89 — nothing to do!
All instances at full capacity! Disabling cron job. 🎊
```

---

## Step 11: Log In to Your New Server

Once the instance is running:

```bash
# SSH in (ubuntu is the default user for Ubuntu images on OCI)
ssh ubuntu@<your-instance-ip>
```

Docker is already installed (cloud-init did that). Your 4-core ARM server with 24GB of RAM is ready to go.

---

## How It Works (The Clever Bits)

### Small-First Strategy
Oracle has limited ARM capacity. Requesting the full 4 OCPU/24GB almost always fails. But requesting 1 OCPU/6GB succeeds much more often. Once you have a small instance, resizing it is easier because you already have a placement — Oracle just needs to allocate more resources on the same host.

### Random Jitter
The script sleeps 0-90 seconds randomly before each attempt. This avoids a perfectly predictable 5-minute request pattern that might look automated (because it is, but let's be polite about it).

### Keep-Alive Cron
Oracle can reclaim idle Always Free instances. The cloud-init script installs a keep-alive job that runs every 6 hours, doing just enough CPU work to not look idle. If you've upgraded to PAYG, this is technically unnecessary — but it doesn't hurt.

### Lock File
The lock file prevents two copies of the script from running at once (which could happen if a cycle takes longer than 5 minutes due to jitter + API latency).

### Auto-Disable
Once all configured instances are at full size, the script removes itself from cron. No need to manually clean up.

---

## Optional: Notifications

Want to get pinged when it succeeds? The original script uses [ntfy.sh](https://ntfy.sh) — a dead simple push notification service. No account needed.

Add these to your script (before the `log()` function):

```bash
NTFY_TOPIC="robin-oci-alerts"  # pick any unique topic name

notify() {
    curl -s -H "Title: $1" -H "Priority: ${3:-default}" \
        -d "$2" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1 || true
}
```

Then install the ntfy app on your phone and subscribe to your topic. Calm down Robin, lmgtfy — no account, no API key, no auth. You just pick a topic name and subscribe. That's literally it.

Sprinkle `notify` calls after the success messages:
```bash
notify "Instance Created!" "Small instance provisioned — resize coming next cycle"
notify "Resize Complete!" "Full 4 OCPU / 24GB instance is running at $IP" "high"
```

---

## Troubleshooting

### "Out of capacity" forever
- Upgrade to PAYG (seriously, this is the biggest factor)
- Try a different region (create another account)
- Be patient — some people wait a week, some get lucky in an hour

### "Authorization failed"
Calm down Robin, lmgtfy — run `oci setup config` again. The wizard handles everything. Just make sure you uploaded the public key to the OCI Console (Step 3).

### "Could not find subnet/image"
Double-check the OCIDs in your `accounts.yaml`. They're long and easy to copy wrong. Make sure the image ID is for your specific region — image IDs are different per region.

### Script isn't running
```bash
# Check if cron is running
systemctl status cron

# Check if the job is registered
crontab -l | grep provision
```

### Rate limited (429)
The script handles this automatically — it backs off for 60 seconds. If it happens a lot, consider increasing the cron interval from 5 to 10 minutes.

---

## Security Notes

- The OCI CLI config (`~/.oci/config`) contains your API key path. Keep it safe.
- Your SSH private key (`~/.ssh/id_ed25519`) is your login credential for the instance. Don't share it.
- The instance's Security List (firewall) is restrictive by default. Only port 22 (SSH) is open. You'll need to add rules for any other ports you want to expose (80, 443, etc.) via OCI Console → Networking → VCN → Security Lists.

---

## Quick Reference

```bash
# Check provisioning status
tail -20 ~/oci-provision.log

# Manually trigger a provisioning attempt
~/oci-provision/retry-provision.sh

# Check cron is active
crontab -l | grep provision

# Remove the cron job (give up / already done)
crontab -l | grep -v "retry-provision" | crontab -

# SSH into your instance once it's running
ssh ubuntu@<ip-address>
```

---

That's it! Go make a cup of tea and let the script do its thing. 🍵
