#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/btrfs-subvolume-manager.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_msg "Starting Btrfs Subvolume Manager..."

# Get the current root device
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

# Get the current subvolume name
CURRENT_SUBVOL=$(findmnt / -no FSROOT)
log_msg "Current root subvolume: $CURRENT_SUBVOL"

sync

# Check if we're booted from /@snapshots/@ota_new (not @)
if [[ "$CURRENT_SUBVOL" == "/@snapshots/@ota_new" ]]; then
    log_msg "System booted from @snapshots/@ota_new, performing subvolume rotation..."
    
    # Mount btrfs top-level
    BTRFS_TOP="/mnt/btrfs-top-manager"
    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"
    
    # Step 1: Delete old @ subvolume if it exists
    if [[ -d "$BTRFS_TOP/@" ]]; then
        log_msg "Deleting old @ subvolume..."
        # First, check if @ is not the default subvolume
        DEFAULT_ID=$(btrfs subvolume get-default "$BTRFS_TOP" | awk '{print $2}')
        AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@" {print $2}')
        
        if [[ "$DEFAULT_ID" == "$AT_ID" ]]; then
            log_msg "Warning: @ is still the default subvolume, changing default first..."
            NEW_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@ota_new" {print $2}')
            btrfs subvolume set-default "$NEW_ID" "$BTRFS_TOP"
        fi
        
        if ! btrfs subvolume delete "$BTRFS_TOP/@"; then
            log_msg "Error: Failed to delete @ subvolume"
            umount "$BTRFS_TOP"
            exit 1
        fi
        log_msg "Old @ subvolume deleted successfully"
    fi
    
    # Step 2: Create new @ as a snapshot of @ota_new
    log_msg "Creating new @ subvolume from current @ota_new..."
    if ! btrfs subvolume snapshot "$BTRFS_TOP/@snapshots/@ota_new" "$BTRFS_TOP/@"; then
        log_msg "Error: Failed to create @ snapshot"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "New @ subvolume created successfully"
    
    # Step 3: Set @ as default subvolume
    log_msg "Setting @ as default subvolume..."
    AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@" {print $2}')
    if ! btrfs subvolume set-default "$AT_ID" "$BTRFS_TOP"; then
        log_msg "Error: Failed to set @ as default"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "@ set as default subvolume (ID: $AT_ID)"
    
    # Unmount
    umount "$BTRFS_TOP"
    rmdir "$BTRFS_TOP"
    
    log_msg "Subvolume rotation complete! System should boot from @ on next reboot."
    systemctl reboot
elif [[ "$CURRENT_SUBVOL" == "/@snapshots/@factory_reset_new" ]]; then
    log_msg "System booted from @snapshots/@factory_reset_new, performing subvolume rotation..."
    
    # Mount btrfs top-level
    BTRFS_TOP="/mnt/btrfs-top-manager"
    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"
    
    # Step 1: Delete old @ subvolume if it exists
    if [[ -d "$BTRFS_TOP/@" ]]; then
        log_msg "Deleting old @ subvolume..."
        # First, check if @ is not the default subvolume
        DEFAULT_ID=$(btrfs subvolume get-default "$BTRFS_TOP" | awk '{print $2}')
        AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@" {print $2}')
        
        if [[ "$DEFAULT_ID" == "$AT_ID" ]]; then
            log_msg "Warning: @ is still the default subvolume, changing default first..."
            NEW_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@factory_reset_new" {print $2}')
            btrfs subvolume set-default "$NEW_ID" "$BTRFS_TOP"
        fi
        
        if ! btrfs subvolume delete "$BTRFS_TOP/@"; then
            log_msg "Error: Failed to delete @ subvolume"
            umount "$BTRFS_TOP"
            exit 1
        fi
        log_msg "Old @ subvolume deleted successfully"
    fi
    
    # Step 2: Create new @ as a snapshot of @factory_reset_new
    log_msg "Creating new @ subvolume from current @snapshots/@factory_reset_new..."
    if ! btrfs subvolume snapshot "$BTRFS_TOP/@snapshots/@factory_reset_new" "$BTRFS_TOP/@"; then
        log_msg "Error: Failed to create @ snapshot"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "New @ subvolume created successfully"
    
    # Step 3: Set @ as default subvolume
    log_msg "Setting @ as default subvolume..."
    AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@" {print $2}')
    if ! btrfs subvolume set-default "$AT_ID" "$BTRFS_TOP"; then
        log_msg "Error: Failed to set @ as default"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "@ set as default subvolume (ID: $AT_ID)"
    
    # Unmount
    umount "$BTRFS_TOP"
    rmdir "$BTRFS_TOP"
    
    log_msg "Subvolume rotation complete! System should boot from @ on next reboot."
    systemctl reboot
elif [[ "$CURRENT_SUBVOL" == "/@" ]]; then
    log_msg "System booted from @ subvolume. No action needed."
    
    # Check if there's an orphaned snapshots that needs cleanup
    BTRFS_TOP="/mnt/btrfs-top-manager"
    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"
    
    if [[ -d "$BTRFS_TOP/@snapshots/@ota_new" ]]; then
        log_msg "Found orphaned @snapshots/@ota_new, cleaning up..."
        btrfs subvolume delete "$BTRFS_TOP/@snapshots/@ota_new" || log_msg "Warning: Failed to delete orphaned @snapshots/@ota_new"
    fi

    if [[ -d "$BTRFS_TOP/@snapshots/@factory_reset_new" ]]; then
        log_msg "Found orphaned @snapshots/@factory_reset_new, cleaning up..."
        btrfs subvolume delete "$BTRFS_TOP/@snapshots/@factory_reset_new" || log_msg "Warning: Failed to delete orphaned @snapshots/@factory_reset_new"
    fi
    
    umount "$BTRFS_TOP"
    rmdir "$BTRFS_TOP"

else
    log_msg "System booted from unexpected subvolume: $CURRENT_SUBVOL"
    log_msg "Manual intervention may be required."
fi

sync

log_msg "Btrfs Subvolume Manager finished."