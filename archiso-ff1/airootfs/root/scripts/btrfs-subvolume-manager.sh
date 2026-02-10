#!/bin/bash

set -euo pipefail

# Unified Btrfs Subvolume Manager
#
# Handles post-boot promotion for ALL transition types (OTA, factory reset).
# Uses a single mechanism: boot counting in systemd-boot provides automatic
# fallback to @ if the candidate subvolume fails to boot (3 attempts).
#
# Two cases:
#   1. Booted from a candidate (@ota_new or @factory_reset_new):
#      → Deploy staged boot files, rotate candidate → @, reboot
#   2. Booted from @ (normal boot or fallback after failed candidate):
#      → Clean up any orphaned candidates and stale boot entries

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

BTRFS_TOP="/mnt/btrfs-top-manager"

case "$CURRENT_SUBVOL" in

/@snapshots/@ota_new|/@snapshots/@factory_reset_new)
    #
    # === CANDIDATE BOOT SUCCEEDED — PROMOTE ===
    #
    log_msg "System booted from candidate: $CURRENT_SUBVOL. Promoting to @..."

    # OTA-specific: set up auto system test for the next boot
    if [[ "$CURRENT_SUBVOL" == "/@snapshots/@ota_new" ]]; then
        touch /etc/FF_OS_OTA_AUTO_TEST
    fi

    # Step 1: Deploy staged boot files to /boot (proven to work now)
    log_msg "Deploying staged boot files to /boot..."
    BOOT_STAGED=""
    if [[ -d /var/lib/ota_boot_staging ]]; then
        BOOT_STAGED="/var/lib/ota_boot_staging"
    elif [[ -d /var/lib/factory_reset_boot ]]; then
        BOOT_STAGED="/var/lib/factory_reset_boot"
    fi

    if [[ -n "$BOOT_STAGED" ]]; then
        rsync -a --delete "$BOOT_STAGED"/ /boot/
        log_msg "Boot files deployed from $BOOT_STAGED to /boot."
    else
        log_msg "Warning: No staged boot files found. Skipping boot file deployment."
    fi

    # Step 2: Mount btrfs top-level for subvolume rotation
    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

    # Step 3: Delete old @ subvolume if it exists
    if [[ -d "$BTRFS_TOP/@" ]]; then
        log_msg "Deleting old @ subvolume..."
        DEFAULT_ID=$(btrfs subvolume get-default "$BTRFS_TOP" | awk '{print $2}')
        AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@" {print $2}')

        if [[ "$DEFAULT_ID" == "$AT_ID" ]]; then
            log_msg "@ is still the default subvolume, changing default to candidate first..."
            CANDIDATE_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk -v s="${CURRENT_SUBVOL#/}" '$NF==s {print $2}')
            btrfs subvolume set-default "$CANDIDATE_ID" "$BTRFS_TOP"
        fi

        if ! btrfs subvolume delete "$BTRFS_TOP/@"; then
            log_msg "Error: Failed to delete old @ subvolume"
            umount "$BTRFS_TOP"
            exit 1
        fi
        log_msg "Old @ subvolume deleted successfully"
    fi

    # Step 4: Create new @ as a snapshot of the candidate
    log_msg "Creating new @ subvolume from $CURRENT_SUBVOL..."
    if ! btrfs subvolume snapshot "$BTRFS_TOP/${CURRENT_SUBVOL#/}" "$BTRFS_TOP/@"; then
        log_msg "Error: Failed to create @ snapshot from $CURRENT_SUBVOL"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "New @ subvolume created successfully"

    # Step 5: Set @ as default subvolume
    log_msg "Setting @ as default subvolume..."
    AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@" {print $2}')
    if ! btrfs subvolume set-default "$AT_ID" "$BTRFS_TOP"; then
        log_msg "Error: Failed to set @ as default"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "@ set as default subvolume (ID: $AT_ID)"

    # Step 6: If factory reset used recovery candidate, promote it to @factory_reset
    if [[ "$CURRENT_SUBVOL" == "/@snapshots/@factory_reset_new" ]] && \
       [[ -f /var/lib/recovery_update/candidate_used ]]; then
        log_msg "Recovery candidate was used for this factory reset. Promoting to @factory_reset..."

        if [[ -d "$BTRFS_TOP/@snapshots/@factory_reset" ]]; then
            log_msg "Deleting old @factory_reset..."
            btrfs subvolume delete "$BTRFS_TOP/@snapshots/@factory_reset" || \
                log_msg "Warning: Failed to delete old @factory_reset"
        fi

        if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate" ]]; then
            mv "$BTRFS_TOP/@snapshots/@recovery_candidate" "$BTRFS_TOP/@snapshots/@factory_reset"
            log_msg "@recovery_candidate promoted to @factory_reset successfully."
        fi
    fi

    # Unmount
    umount "$BTRFS_TOP"
    rmdir "$BTRFS_TOP"

    log_msg "Subvolume rotation complete! System will boot from @ on next reboot."
    systemctl reboot
    ;;

/@)
    #
    # === NORMAL BOOT (or fallback after failed candidate) — CLEANUP ===
    #
    log_msg "System booted from @ subvolume. Checking for orphans..."

    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

    # Clean up orphaned candidate subvolumes (from failed boot counting or interrupted updates)
    for orphan in @snapshots/@ota_new @snapshots/@factory_reset_new; do
        if [[ -d "$BTRFS_TOP/$orphan" ]]; then
            log_msg "Found orphaned $orphan, cleaning up..."
            btrfs subvolume delete "$BTRFS_TOP/$orphan" || \
                log_msg "Warning: Failed to delete orphaned $orphan"
        fi
    done

    if [[ -f /var/lib/recovery_update/attempted ]]; then
        log_msg "Attempt to do factory reset with recovery candidate detected."
        FAILED_VERSION=$(cat /var/lib/recovery_update/attempted)
        # Fallback: if marker was empty (touch'd), try installed_version
        if [[ -z "$FAILED_VERSION" && -f /var/lib/recovery_update/installed_version ]]; then
            FAILED_VERSION=$(cat /var/lib/recovery_update/installed_version)
        fi
        if [[ -n "$FAILED_VERSION" ]]; then
            echo "$FAILED_VERSION" > /var/lib/recovery_update/failed_version
            log_msg "Marked version $FAILED_VERSION as failed"
        else
            log_msg "Warning: Could not determine failed candidate version"
        fi

        if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate" ]]; then
            if btrfs subvolume delete "$BTRFS_TOP/@snapshots/@recovery_candidate"; then
                log_msg "Deleted failed @recovery_candidate subvolume."
            else
                log_msg "Warning: Failed to delete failed @recovery_candidate"
            fi
        fi
        rm -f /var/lib/recovery_update/attempted
    fi

    umount "$BTRFS_TOP"
    rmdir "$BTRFS_TOP"

    # Clean up candidate boot files from ESP
    rm -f /boot/loader/entries/arch-candidate.conf
    rm -rf /boot/candidate

    log_msg "Cleanup complete."
    ;;

*)
    log_msg "System booted from unexpected subvolume: $CURRENT_SUBVOL"
    log_msg "Manual intervention may be required."
    ;;

esac

sync

log_msg "Btrfs Subvolume Manager finished."
