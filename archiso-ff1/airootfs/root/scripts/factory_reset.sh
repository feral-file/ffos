#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/factory-reset.log"
CANDIDATE_JSON="/var/lib/recovery_update/candidate.json"
PENDING_PROMOTION_FILE="/var/lib/recovery_update/pending_promotion"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get the current root device
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

log_msg "Factory reset initiated..."

# Check if there's a ready recovery candidate
USE_CANDIDATE=false
if [[ -f "$CANDIDATE_JSON" ]] && jq -e '.ready == true' "$CANDIDATE_JSON" >/dev/null 2>&1; then
    CANDIDATE_VERSION=$(jq -r '.version' "$CANDIDATE_JSON")
    log_msg "Recovery candidate available (version: $CANDIDATE_VERSION), using new recovery version..."
    USE_CANDIDATE=true
else
    log_msg "No recovery candidate available, using original factory_reset..."
fi

sync

# Mount btrfs top-level
BTRFS_TOP="/mnt/btrfs-top-manager"
mkdir -p "$BTRFS_TOP"
mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

# Step 1: Delete old @factory_reset_new subvolume if it exists
if [[ -d "$BTRFS_TOP/@snapshots/@factory_reset_new" ]]; then
    log_msg "Deleting old @snapshots/@factory_reset_new subvolume..."
    # First, check if @snapshots/@factory_reset_new is not the default subvolume
    DEFAULT_ID=$(btrfs subvolume get-default "$BTRFS_TOP" | awk '{print $2}')
    AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@factory_reset_new" {print $2}')
    
    if [[ "$DEFAULT_ID" == "$AT_ID" ]]; then
        log_msg "Warning: @snapshots/@factory_reset_new is still the default subvolume, changing default first..."
        NEW_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@factory_reset" {print $2}')
        btrfs subvolume set-default "$NEW_ID" "$BTRFS_TOP"
    fi
    
    if ! btrfs subvolume delete "$BTRFS_TOP/@snapshots/@factory_reset_new"; then
        log_msg "Error: Failed to delete @snapshots/@factory_reset_new subvolume"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "Old @snapshots/@factory_reset_new subvolume deleted successfully"
fi

# Step 2: Create new @snapshots/@factory_reset_new as a snapshot
if [[ "$USE_CANDIDATE" == true ]]; then
    SOURCE_SNAP="@snapshots/@recovery_candidate"
    log_msg "Creating new @ subvolume from recovery candidate..."
else
    SOURCE_SNAP="@snapshots/@factory_reset"
    log_msg "Creating new @ subvolume from original factory_reset..."
fi

if ! btrfs subvolume snapshot "$BTRFS_TOP/$SOURCE_SNAP" "$BTRFS_TOP/@snapshots/@factory_reset_new"; then
    log_msg "Error: Failed to create @snapshots/@factory_reset_new snapshot from $SOURCE_SNAP"
    umount "$BTRFS_TOP"
    exit 1
fi
log_msg "New @snapshots/@factory_reset_new subvolume created successfully from $SOURCE_SNAP"

# Step 3: Set @snapshots/@factory_reset_new as default subvolume
log_msg "Setting @snapshots/@factory_reset_new as default subvolume..."
AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@factory_reset_new" {print $2}')
if ! btrfs subvolume set-default "$AT_ID" "$BTRFS_TOP"; then
    log_msg "Error: Failed to set @snapshots/@factory_reset_new as default"
    umount "$BTRFS_TOP"
    exit 1
fi
log_msg "@snapshots/@factory_reset_new set as default subvolume (ID: $AT_ID)"

# Step 4: Restore /boot partition from backup
log_msg "Restoring /boot partition to factory state..."

TARGET_BOOT="/boot"
if [[ "$USE_CANDIDATE" == true ]]; then
    # Use boot files from recovery candidate
    SOURCE_BOOT="$BTRFS_TOP/@snapshots/@recovery_candidate/var/lib/factory_reset_boot"
else
    # Use boot files from factory_reset_new (which came from @factory_reset)
    SOURCE_BOOT="$BTRFS_TOP/@snapshots/@factory_reset_new/var/lib/factory_reset_boot"
fi

if [[ -d "$SOURCE_BOOT" ]]; then
    log_msg "Found backup boot files at $SOURCE_BOOT. Syncing to $TARGET_BOOT..."
    rsync -a --delete "$SOURCE_BOOT/" "$TARGET_BOOT/"
    log_msg "/boot restored successfully."
else
    log_msg "Warning: No factory boot backup found in snapshot. Kernel version mismatch may occur!"
fi

# Step 5: If using recovery candidate, set up boot counting for automatic fallback
if [[ "$USE_CANDIDATE" == true ]]; then
    log_msg "Setting up boot counting for recovery candidate validation..."
    
    # Ensure the boot entry with counter exists
    if [[ -f /boot/loader/entries/recovery_candidate+1.conf ]]; then
        log_msg "Using boot entry with counter for automatic fallback on failure."
        # Use bootctl set-oneshot to boot from recovery candidate entry once
        bootctl set-oneshot recovery_candidate+1.conf
        
        # Mark pending promotion - will be executed after successful boot
        mkdir -p "$(dirname "$PENDING_PROMOTION_FILE")"
        touch "$PENDING_PROMOTION_FILE"
        log_msg "Pending promotion marker created. Recovery candidate will be promoted on successful boot."
    else
        log_msg "Warning: recovery_candidate+1.conf not found. Proceeding without boot counting."
    fi
fi

# Unmount
umount "$BTRFS_TOP"
rmdir "$BTRFS_TOP"

log_msg "Subvolume rotation complete! System should boot from @snapshots/@factory_reset_new on next reboot."

sync

sleep 8
systemctl reboot
