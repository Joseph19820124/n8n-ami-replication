#!/usr/bin/env bash
#
# ami-replicate.sh
# Create an AMI from an Oregon EC2 instance, replicate to multiple regions,
# and copy cross-account.
#
# Usage:
#   ./ami-replicate.sh                     # use defaults from config section
#   ./ami-replicate.sh -i ami-0abcdef1234  # skip creation, replicate existing AMI
#
# Exit codes:
#   0 = success
#   1 = AMI creation failed
#   2 = AMI did not become available (timeout)
#   3 = copy failed
#
set -euo pipefail

# ─────────────────────────────── Config ───────────────────────────────
SOURCE_REGION="us-west-2"
SOURCE_INSTANCE_ID="i-XXXXXXXXXXXXXXXXX"          # ← Oregon instance ID

# Same-account target regions
COPY_REGIONS=("us-east-1" "us-east-2" "us-west-1")

# Cross-account
TARGET_ACCOUNT_ID="123456789012"                   # ← Account B's 12-digit ID
TARGET_PROFILE="account-b"                         # ← AWS CLI profile for account B
TARGET_REGION="us-west-2"                          # region to copy into in account B

# AMI naming
AMI_PREFIX="openclaw"

# Timeouts
POLL_INTERVAL=30          # seconds between status checks
MAX_WAIT=1800             # 30 min max wait for AMI to become available

# Retention (0 = skip cleanup)
KEEP_COUNT=3              # keep latest N AMIs per region, delete older ones

# ─────────────────────────────── Helpers ──────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "ERROR: $*"; exit "${2:-1}"; }

wait_ami_available() {
    local region="$1" ami_id="$2" profile="${3:-}"
    local elapsed=0 state

    local profile_flag=()
    [[ -n "$profile" ]] && profile_flag=(--profile "$profile")

    log "Waiting for $ami_id in $region to become available..."
    while (( elapsed < MAX_WAIT )); do
        state=$(aws ec2 describe-images \
            --region "$region" \
            --image-ids "$ami_id" \
            "${profile_flag[@]}" \
            --query 'Images[0].State' --output text 2>/dev/null || echo "unknown")

        if [[ "$state" == "available" ]]; then
            log "$ami_id is available in $region (${elapsed}s)"
            return 0
        elif [[ "$state" == "failed" ]]; then
            die "$ami_id failed in $region" 2
        fi

        sleep "$POLL_INTERVAL"
        (( elapsed += POLL_INTERVAL ))
    done

    die "$ami_id did not become available in $region within ${MAX_WAIT}s" 2
}

# ─────────────────────────────── Parse args ───────────────────────────
EXISTING_AMI=""
while getopts "i:" opt; do
    case $opt in
        i) EXISTING_AMI="$OPTARG" ;;
        *) echo "Usage: $0 [-i existing-ami-id]"; exit 1 ;;
    esac
done

# ──────────────────────── Step 1: Create AMI ──────────────────────────
if [[ -n "$EXISTING_AMI" ]]; then
    AMI_ID="$EXISTING_AMI"
    log "Using existing AMI: $AMI_ID"
else
    TIMESTAMP=$(date -u '+%Y%m%d-%H%M%S')
    AMI_NAME="${AMI_PREFIX}-${TIMESTAMP}"

    log "Creating AMI '$AMI_NAME' from $SOURCE_INSTANCE_ID in $SOURCE_REGION..."
    AMI_ID=$(aws ec2 create-image \
        --region "$SOURCE_REGION" \
        --instance-id "$SOURCE_INSTANCE_ID" \
        --name "$AMI_NAME" \
        --description "Automated backup ${TIMESTAMP}" \
        --no-reboot \
        --query 'ImageId' --output text) \
        || die "create-image failed" 1

    log "Created AMI: $AMI_ID"
fi

# ──────────────────────── Step 2: Wait for AMI ────────────────────────
wait_ami_available "$SOURCE_REGION" "$AMI_ID"

# ──────────────────── Step 3: Same-account copies ─────────────────────
declare -A COPY_AMI_IDS   # region -> ami-id

log "Starting same-account copies to: ${COPY_REGIONS[*]}"
for region in "${COPY_REGIONS[@]}"; do
    copy_id=$(aws ec2 copy-image \
        --source-region "$SOURCE_REGION" \
        --source-image-id "$AMI_ID" \
        --region "$region" \
        --name "${AMI_PREFIX}-${region}-$(date -u '+%Y%m%d-%H%M%S')" \
        --description "Copy of $AMI_ID from $SOURCE_REGION" \
        --query 'ImageId' --output text) \
        || die "copy-image to $region failed" 3

    COPY_AMI_IDS["$region"]="$copy_id"
    log "  $region → $copy_id (copy started)"
done

# ──────────────── Step 4: Cross-account share + copy ──────────────────
log "Sharing $AMI_ID with account $TARGET_ACCOUNT_ID..."
aws ec2 modify-image-attribute \
    --region "$SOURCE_REGION" \
    --image-id "$AMI_ID" \
    --launch-permission "Add=[{UserId=$TARGET_ACCOUNT_ID}]" \
    || die "modify-image-attribute failed" 3

# Also share the underlying snapshot(s)
SNAPSHOT_IDS=$(aws ec2 describe-images \
    --region "$SOURCE_REGION" \
    --image-ids "$AMI_ID" \
    --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' --output text)

for snap_id in $SNAPSHOT_IDS; do
    [[ "$snap_id" == "None" ]] && continue
    log "Sharing snapshot $snap_id with account $TARGET_ACCOUNT_ID..."
    aws ec2 modify-snapshot-attribute \
        --region "$SOURCE_REGION" \
        --snapshot-id "$snap_id" \
        --attribute createVolumePermission \
        --operation-type add \
        --user-ids "$TARGET_ACCOUNT_ID" \
        || log "WARNING: failed to share snapshot $snap_id (non-fatal)"
done

log "Copying AMI cross-account into $TARGET_REGION (account B)..."
CROSS_AMI_ID=$(aws ec2 copy-image \
    --profile "$TARGET_PROFILE" \
    --source-region "$SOURCE_REGION" \
    --source-image-id "$AMI_ID" \
    --region "$TARGET_REGION" \
    --name "${AMI_PREFIX}-xaccount-$(date -u '+%Y%m%d-%H%M%S')" \
    --description "Cross-account copy of $AMI_ID" \
    --query 'ImageId' --output text) \
    || die "cross-account copy-image failed" 3

log "  $TARGET_REGION (account B) → $CROSS_AMI_ID (copy started)"

# ──────────────────── Step 5: Wait for all copies ─────────────────────
log "Waiting for all copies to complete..."

for region in "${COPY_REGIONS[@]}"; do
    wait_ami_available "$region" "${COPY_AMI_IDS[$region]}" &
done
wait_ami_available "$TARGET_REGION" "$CROSS_AMI_ID" "$TARGET_PROFILE" &

# Wait for all background waits
wait
log "All copies are available."

# ──────────────────── Step 6: Cleanup old AMIs ────────────────────────
cleanup_old_amis() {
    local region="$1" profile="${2:-}"
    local profile_flag=()
    [[ -n "$profile" ]] && profile_flag=(--profile "$profile")

    local ami_list
    ami_list=$(aws ec2 describe-images \
        --region "$region" \
        "${profile_flag[@]}" \
        --owners self \
        --filters "Name=name,Values=${AMI_PREFIX}*" \
        --query 'sort_by(Images, &CreationDate)[*].[ImageId,CreationDate]' \
        --output text)

    local total
    total=$(echo "$ami_list" | grep -c . || true)

    if (( total <= KEEP_COUNT )); then
        log "  $region: $total AMIs found, nothing to clean (keep=$KEEP_COUNT)"
        return
    fi

    local to_delete=$(( total - KEEP_COUNT ))
    log "  $region: $total AMIs found, deleting oldest $to_delete..."

    echo "$ami_list" | head -n "$to_delete" | while read -r ami_id _date; do
        # Get snapshots before deregistering
        local snaps
        snaps=$(aws ec2 describe-images \
            --region "$region" \
            "${profile_flag[@]}" \
            --image-ids "$ami_id" \
            --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' --output text 2>/dev/null || true)

        log "    Deregistering $ami_id..."
        aws ec2 deregister-image --region "$region" "${profile_flag[@]}" --image-id "$ami_id" 2>/dev/null || true

        for snap in $snaps; do
            [[ "$snap" == "None" ]] && continue
            log "    Deleting snapshot $snap..."
            aws ec2 delete-snapshot --region "$region" "${profile_flag[@]}" --snapshot-id "$snap" 2>/dev/null || true
        done
    done
}

if (( KEEP_COUNT > 0 )); then
    log "Cleaning up old AMIs (keeping latest $KEEP_COUNT)..."

    # Source region
    cleanup_old_amis "$SOURCE_REGION"

    # Copy regions
    for region in "${COPY_REGIONS[@]}"; do
        cleanup_old_amis "$region"
    done

    # Cross-account
    cleanup_old_amis "$TARGET_REGION" "$TARGET_PROFILE"
fi

# ──────────────────────────── Summary ─────────────────────────────────
log "=== DONE ==="
log "Source AMI:       $AMI_ID ($SOURCE_REGION)"
for region in "${COPY_REGIONS[@]}"; do
    log "  Copy:           ${COPY_AMI_IDS[$region]} ($region)"
done
log "  Cross-account:  $CROSS_AMI_ID ($TARGET_REGION, account B)"
