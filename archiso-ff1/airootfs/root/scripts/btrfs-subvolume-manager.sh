#!/bin/bash

set -euo pipefail

# Unified Btrfs Subvolume Manager
#
# Handles post-boot promotion for ALL transition types (OTA, factory reset).
# The candidate is booted exactly ONCE via `bootctl set-oneshot` (see
# feral-system-update.sh / factory_reset.sh). If the candidate KERNEL fails to
# boot, the next power cycle lands back on @ automatically: the one-shot entry
# is already consumed and the btrfs default subvolume was never changed. There
# is NO systemd-boot boot counting and NO retry — one attempt only — and NO
# userspace health gating before promotion: reaching this script on a
# candidate subvolume is the only success signal, so a release that boots the
# kernel but breaks userspace is promoted anyway and the old @ is deleted.
# That trade-off is accepted (issue #122); the recovery path for it is the
# power-cycle factory-reset gesture in the btrfs-rollback initramfs hook.
#
# Two cases:
#   1. Booted from a candidate (@ota_new or @factory_reset_new):
#      → Deploy staged boot files, rotate candidate → @ (no reboot — the
#        running system already IS the promoted version)
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
        # The ESP is FAT32 with no journal, mounted without sync/flush: dirty
        # metadata from this rsync is not guaranteed to be flushed before the
        # final sync at the end of this script, so a power cut anywhere across
        # the subvolume rotation below can corrupt the filesystem that also
        # carries the factory-reset rescue entry (F-05). Bracket the overwrite
        # with syncs so the vulnerable window is only the rsync itself, not
        # the entire promotion. Trade-offs accepted: the pre-sync is nearly
        # free (the sync at the top of this script already flushed; it exists
        # so a future edit adding ESP writes above cannot silently reopen the
        # gap); the post-sync serializes ESP writeback into this early-boot
        # path, adding seconds to the promotion boot's black screen; and the
        # window is narrowed, NOT removed — removal needs staging to
        # /boot/new/ plus rename + `bootctl set-default` (deferred). Plain
        # `sync` (not `sync -f /boot`) is deliberate: syncfs() can fail with
        # EIO and, under set -e, would abort AFTER the ESP is overwritten but
        # BEFORE the rotation below — stranding a new kernel over the old
        # rootfs — while argless sync cannot fail and also triggers the
        # device-level cache flush syncfs lacks.
        # Keep --delete: dropping it does not protect the fallback kernel
        # (same-name files are overwritten in place regardless) and would
        # accumulate stale loader entries.
        sync
        rsync -a --delete "$BOOT_STAGED"/ /boot/
        sync
        log_msg "Boot files deployed from $BOOT_STAGED to /boot."
    else
        log_msg "Warning: No staged boot files found. Skipping boot file deployment."
    fi

    # Step 2: Mount btrfs top-level for subvolume rotation
    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

    # Step 3: Delete old @snapshots/@ subvolume if it exists
    if [[ -d "$BTRFS_TOP/@snapshots/@" ]]; then
        log_msg "Deleting old @snapshots/@ subvolume..."
        DEFAULT_ID=$(btrfs subvolume get-default "$BTRFS_TOP" | awk '{print $2}')
        AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@" {print $2}')

        if [[ "$DEFAULT_ID" == "$AT_ID" ]]; then
            log_msg "@snapshots/@ is still the default subvolume, changing default to candidate first..."
            CANDIDATE_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk -v s="${CURRENT_SUBVOL#/}" '$NF==s {print $2}')
            btrfs subvolume set-default "$CANDIDATE_ID" "$BTRFS_TOP"
        fi

        if ! btrfs subvolume delete "$BTRFS_TOP/@snapshots/@"; then
            log_msg "Error: Failed to delete old @snapshots/@ subvolume"
            umount "$BTRFS_TOP"
            exit 1
        fi
        log_msg "Old @snapshots/@ subvolume deleted successfully"
    fi

    # Migration from old structure to new structure
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

    # Step 4: Rename current subvolume to @snapshots/@
    log_msg "Renaming $CURRENT_SUBVOL to @snapshots/@..."
    mv "$BTRFS_TOP$CURRENT_SUBVOL" "$BTRFS_TOP/@snapshots/@"

    # Step 5: Set @snapshots/@ as default subvolume
    log_msg "Setting @snapshots/@ as default subvolume..."
    AT_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@" {print $2}')
    if ! btrfs subvolume set-default "$AT_ID" "$BTRFS_TOP"; then
        log_msg "Error: Failed to set @snapshots/@ as default"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "@snapshots/@ set as default subvolume (ID: $AT_ID)"

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

    rm -f /boot/loader/entries/arch-candidate.conf
    log_msg "Cleanup complete."

    log_msg "Promotion complete. No reboot required."
    ;;

/@snapshots/@)
    #
    # === NORMAL BOOT (or fallback after failed candidate) — CLEANUP ===
    #
    log_msg "System booted from @snapshots/@ subvolume. Checking for orphans..."

    mkdir -p "$BTRFS_TOP"
    mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

    # Clean up orphaned candidate subvolumes (from a failed one-shot candidate boot or interrupted updates)
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
        # Fallback: if marker was empty (touch'd), try reading from @recovery_candidate snapshot's config
        if [[ -z "$FAILED_VERSION" ]]; then
            RC_CONFIG="$BTRFS_TOP/@snapshots/@recovery_candidate/home/feralfile/ff1-config.json"
            if [[ -f "$RC_CONFIG" ]]; then
                FAILED_VERSION=$(jq -r '.version // empty' "$RC_CONFIG")
            fi
        fi
        if [[ -n "$FAILED_VERSION" ]]; then
            mkdir -p /home/feralfile/.state
            echo "$FAILED_VERSION" > /home/feralfile/.state/failed_recovery_version
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
