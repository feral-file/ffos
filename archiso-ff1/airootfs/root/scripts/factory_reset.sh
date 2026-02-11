#!/bin/bash

set -euo pipefail

LOG_FILE="/var/log/factory-reset.log"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get the current root device
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

log_msg "Factory reset initiated..."

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
        NEW_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@" {print $2}')
        btrfs subvolume set-default "$NEW_ID" "$BTRFS_TOP"
    fi

    if ! btrfs subvolume delete "$BTRFS_TOP/@snapshots/@factory_reset_new"; then
        log_msg "Error: Failed to delete @snapshots/@factory_reset_new subvolume"
        umount "$BTRFS_TOP"
        exit 1
    fi
    log_msg "Old @snapshots/@factory_reset_new subvolume deleted successfully"
fi

# Step 2: Pick source — recovery candidate if it exists, otherwise factory_reset
if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate" ]]; then
    SOURCE_SNAP="@snapshots/@recovery_candidate"
    log_msg "Recovery candidate snapshot found, using it for factory reset..."
else
    SOURCE_SNAP="@snapshots/@factory_reset"
    log_msg "No recovery candidate, using original factory_reset..."
fi

# Step 3: Create @factory_reset_new snapshot from source
if ! btrfs subvolume snapshot "$BTRFS_TOP/$SOURCE_SNAP" "$BTRFS_TOP/@snapshots/@factory_reset_new"; then
    log_msg "Error: Failed to create @snapshots/@factory_reset_new snapshot from $SOURCE_SNAP"
    umount "$BTRFS_TOP"
    exit 1
fi
log_msg "New @snapshots/@factory_reset_new subvolume created successfully from $SOURCE_SNAP"

# Step 4: Leave breadcrumb if recovery candidate was used (for post-boot promotion)
if [[ "$SOURCE_SNAP" == "@snapshots/@recovery_candidate" ]]; then
    mkdir -p "$BTRFS_TOP/@snapshots/@factory_reset_new/var/lib/recovery_update"
    touch "$BTRFS_TOP/@snapshots/@factory_reset_new/var/lib/recovery_update/candidate_used"
    log_msg "Marked factory_reset_new as sourced from recovery candidate."
fi

# Step 5: Stage boot files to /boot/candidate/ for boot counting
log_msg "Staging boot files for candidate boot entry..."
SOURCE_BOOT="$BTRFS_TOP/$SOURCE_SNAP/var/lib/factory_reset_boot"

if [[ -d "$SOURCE_BOOT" ]]; then
    mkdir -p /boot/candidate
    rsync -a "$SOURCE_BOOT"/vmlinuz-linux /boot/candidate/
    rsync -a "$SOURCE_BOOT"/initramfs-linux.img /boot/candidate/
    rsync -a "$SOURCE_BOOT"/intel-ucode.img /boot/candidate/
    CANDIDATE_KERNEL_PREFIX="/candidate"
    log_msg "Boot files staged to /boot/candidate/ successfully."
else
    log_msg "Warning: No boot backup found in $SOURCE_SNAP. Using current kernel for candidate boot."
    CANDIDATE_KERNEL_PREFIX=""
fi

# Step 6: Write candidate boot entry
log_msg "Creating candidate boot entry with boot counting..."
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEV")

cat > /boot/loader/entries/arch-candidate.conf <<EOF
title   FF1 - Factory Reset Candidate
linux   $CANDIDATE_KERNEL_PREFIX/vmlinuz-linux
initrd  $CANDIDATE_KERNEL_PREFIX/initramfs-linux.img
initrd  $CANDIDATE_KERNEL_PREFIX/intel-ucode.img
options rootflags=subvol=@snapshots/@factory_reset_new root=PARTUUID=$PARTUUID root_partuuid=$PARTUUID ipv6.disable=1 rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog
EOF

chmod 644 /boot/loader/entries/arch-candidate.conf
log_msg "Candidate boot entry created. Btrfs default unchanged."

bootctl set-oneshot arch-candidate.conf

# Step 7: If recovery candidate was used, mark it as attempted for tracking in btrfs-rollback hook
if [[ "$SOURCE_SNAP" == "@snapshots/@recovery_candidate" ]]; then
    mkdir -p /var/lib/recovery_update
    if [[ -f "$BTRFS_TOP/@snapshots/@factory_reset_new/var/lib/factory_reset/installed_version" ]]; then
        cp "$BTRFS_TOP/@snapshots/@factory_reset_new/var/lib/factory_reset/installed_version" \
        /var/lib/recovery_update/attempted
    else
        touch /var/lib/recovery_update/attempted
        log_msg "Warning: installed_version file not found in factory_reset_new snapshot. Using empty version for tracking."
    fi
fi

# Unmount
umount "$BTRFS_TOP"
rmdir "$BTRFS_TOP"

log_msg "Factory reset prepared. System will try booting from @snapshots/@factory_reset_new on next reboot."

sync

sleep 8
systemctl reboot
