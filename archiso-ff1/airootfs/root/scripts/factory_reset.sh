#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/factory-reset.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

CURRENT_SUBVOL=$(findmnt / -no FSROOT)
if [[ "$CURRENT_SUBVOL" == "/@snapshots/@factory_reset_new" ]]; then
    log_msg "Already in factory reset process. Abort."
    exit 1
fi

# Get the current root device
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

log_msg "Factory reset snapshot..."

sync

# Mount btrfs top-level
BTRFS_TOP="/mnt/btrfs-top-manager"
mkdir -p "$BTRFS_TOP"
mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

trap 'umount "$BTRFS_TOP" 2>/dev/null; rmdir "$BTRFS_TOP" 2>/dev/null' EXIT

# Step 1: Delete old @factory_reset_new subvolume if it exists
if [[ -d "$BTRFS_TOP/@snapshots/@factory_reset_new" ]]; then
    log_msg "Deleting old @snapshots/@factory_reset_new subvolume..."
    # First, check if @snapshots/@factory_reset_new is not the default subvolume
    DEFAULT_ID=$(btrfs subvolume get-default "$BTRFS_TOP" | awk '{print $2}')
    AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@factory_reset_new" {print $2}')
    
    if [[ "$DEFAULT_ID" == "$AT_ID" ]]; then
        log_msg "Warning: @snapshots/@factory_reset_new is still the default subvolume, changing default first..."
        NEW_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@factory_reset" {print $2}')
        
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

# Ensure the new snapshot is writable (snapshots of RO subvolumes are RO by default)
btrfs property set "$BTRFS_TOP/@snapshots/@factory_reset_new" ro false

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

# Restore Boot Partition
log_msg "Restoring boot partition from factory backup..."

FACTORY_SNAPSHOT_PATH="$BTRFS_TOP/@snapshots/@factory_reset"
BOOT_BACKUP_PATH="$FACTORY_SNAPSHOT_PATH/usr/share/factory-backup/boot"

if [[ -d "$BOOT_BACKUP_PATH" ]]; then
    # Prepare chroot environment
    NEW_ROOT="/mnt/factory_restore_mnt"
    mkdir -p "$NEW_ROOT"
    
    log_msg "Mounting new snapshot to $NEW_ROOT for boot restoration..."
    mount -o subvol=@snapshots/@factory_reset_new "$ROOT_DEV" "$NEW_ROOT"
    
    if ! mountpoint -q /boot; then
        log_msg "Error: /boot is not mounted."
        exit 1
    fi

    # Bind mount /boot to the chroot environment
    mount --bind /boot "$NEW_ROOT/boot"

    log_msg "Syncing boot files..."
    rsync -aAX --delete "$BOOT_BACKUP_PATH/" "$NEW_ROOT/boot/"

    log_msg "Reinstalling systemd-boot (inside chroot)..."
    # This ensures we use the bootctl version from the restored snapshot
    if arch-chroot "$NEW_ROOT" bootctl install; then
        log_msg "bootctl install successful."
    else
        log_msg "Error: bootctl install failed."
        exit 1
    fi
    sync
    # Cleanup chroot mounts
    umount "$NEW_ROOT/boot"
    umount "$NEW_ROOT"
    rmdir "$NEW_ROOT"

    log_msg "Boot partition restored to factory state."
else
    log_msg "Warning: Factory boot backup not found at $BOOT_BACKUP_PATH. Skipping boot restoration."
fi

# Unmount
umount "$BTRFS_TOP"
rmdir "$BTRFS_TOP"

log_msg "Subvolume rotation complete! System should boot from @snapshots/@factory_reset_new on next reboot."

sync

sleep 8
systemctl reboot
