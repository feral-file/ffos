#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/factory-reset.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get the current root device
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

log_msg "Factory reset snapshot..."

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

# Step 2: Create new @snapshots/@factory_reset_new as a snapshot of @factory_reset
log_msg "Creating new @ subvolume from current @factory_reset..."
if ! btrfs subvolume snapshot "$BTRFS_TOP/@snapshots/@factory_reset" "$BTRFS_TOP/@snapshots/@factory_reset_new"; then
    log_msg "Error: Failed to create @snapshots/@factory_reset_new snapshot"
    umount "$BTRFS_TOP"
    exit 1
fi
log_msg "New @snapshots/@factory_reset_new subvolume created successfully"

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
SOURCE_BOOT="$BTRFS_TOP/@snapshots/@factory_reset_new/var/lib/factory_reset_boot"

if [[ -d "$SOURCE_BOOT" ]]; then
    log_msg "Found backup boot files. Syncing to $TARGET_BOOT..."
    rsync -a --delete "$SOURCE_BOOT/" "$TARGET_BOOT/"
    log_msg "/boot restored successfully."
else
    log_msg "Warning: No factory boot backup found in snapshot. Kernel version mismatch may occur!"
fi

# Unmount
umount "$BTRFS_TOP"
rmdir "$BTRFS_TOP"

log_msg "Subvolume rotation complete! System should boot from @snapshots/@factory_reset_new on next reboot."

sync

sleep 8
systemctl reboot
