#!/bin/bash
set -euo pipefail

log_info() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [INFO] id=$UNIQUE_ID message=\"$message\""
}

log_progress() {
  local percent="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [PROGRESS] id=$UNIQUE_ID progress=$percent message=\"$message\""
}

log_error() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [ERROR] id=$UNIQUE_ID message=\"$message\""
}

trap 'code=$?; log_error "EXCEPTION ERR: LINE=$LINENO CMD=\"$BASH_COMMAND\""; exit $code' ERR

if [[ $# -lt 2 || -z "${1:-}" || -z "${2:-}" ]]; then
  echo "ERROR: Usage: $0 /path/to/image.zip 2025-06-19T16:00:00"
  exit 1
fi

IMAGE_URL="$1"
UNIQUE_ID="$2"

CONFIG_FILE="/home/feralfile/ff1-config.json"
RELEASE_PK="/root/.ff1-release-public-key.pem"
ISO_MOUNT="/mnt/ota-iso"
SFS_MOUNT="/mnt/ota-sfs"
TMP_DIR="/var/tmp/ota"
ISO_FILE="$TMP_DIR/image.iso"
BOOT_MOUNT="/mnt/ota-boot"
NEW_ROOT="/mnt/ota-new-root"
BTRFS_TOP="/mnt/btrfs-top"
 
cleanup() {
  trap - ERR
  cd /
  sync
  sleep 2
  umount -Rl "$NEW_ROOT" 2>/dev/null || true
  umount "$BTRFS_TOP" 2>/dev/null || true
  umount "$BOOT_MOUNT" 2>/dev/null || true
  umount -Rl "$SFS_MOUNT" 2>/dev/null || true
  umount -Rl "$ISO_MOUNT" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
 
log_info "=== OTA Update: Snapshot-based Update with Btrfs Default Switching ==="
 
# --- Step 1: Load local config ------------------------------------------------
log_progress "0" "Getting device information..."

log_info "Loading config from $CONFIG_FILE"
ENDPOINT=$(jq -r '.endpoint' "$CONFIG_FILE")
 
log_progress "5" "Preparing update environment..."

# --- Step 2: Get root device and mount btrfs top-level -----------------------
log_info "Finding root device and mounting btrfs top-level..."
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

# Create temporary mount point for btrfs top-level
mkdir -p "$BTRFS_TOP"
mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

# --- Step 3: Create snapshots for update -----------------------------------
log_info "Creating new snapshot @snapshots/@ota_new for update..."

# Remove old @snapshots/@ota_new if exists
if [[ -d "$BTRFS_TOP/@snapshots/@ota_new" ]]; then
  log_info "Removing existing @snapshots/@ota_new snapshot..."
  btrfs subvolume delete "$BTRFS_TOP/@snapshots/@ota_new"
fi

# Create new writable snapshot from current @
if btrfs subvolume snapshot "$BTRFS_TOP/@" "$BTRFS_TOP/@snapshots/@ota_new"; then
  log_info "Snapshot '@snapshots/@ota_new' created successfully."
else
  log_error "Failed to create snapshot '@snapshots/@ota_new'. Aborting."
  exit 1
fi

log_info "Creating backup snapshot of current @ subvolume..."
if [[ -d "$BTRFS_TOP/@snapshots/@ota_prev" ]]; then
  log_info "Deleting old @snapshots/@ota_prev snapshot..."
  btrfs subvolume delete "$BTRFS_TOP/@snapshots/@ota_prev"
fi

if btrfs subvolume snapshot -r "$BTRFS_TOP/@" "$BTRFS_TOP/@snapshots/@ota_prev"; then
  log_info "Snapshot '@snapshots/@ota_prev' created successfully."
else
  log_error "Failed to create snapshot '@snapshots/@ota_prev'. Aborting."
  exit 1
fi
log_info "Backup snapshot @snapshots/@ota_prev created"

# Mount the new snapshot for updating
mkdir -p "$NEW_ROOT"
mount -o compress=zstd,noatime,subvol=@snapshots/@ota_new "$ROOT_DEV" "$NEW_ROOT"

# --- Step 4: Download and extract new iso ------------------------------------
log_progress "10" "Downloading new iso..."
mkdir -p "$TMP_DIR"
 
TOTAL_SIZE=$(curl -sI "$ENDPOINT$IMAGE_URL" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {print $2}')

if [[ -z "$TOTAL_SIZE" ]]; then
  log_error "Failed to retrieve content length for image."
  exit 1
fi

log_info "Total file size to download: $TOTAL_SIZE bytes"

# Background progress loop with speed tracking
(
  LAST_SIZE=0
  LAST_TIME=$(date +%s)

  while sleep 3; do
    if [[ -f "$ISO_FILE" ]]; then
      CUR_SIZE=$(stat -c %s "$ISO_FILE")
      CUR_TIME=$(date +%s)
      ELAPSED=$((CUR_TIME - LAST_TIME))
      DIFF=$((CUR_SIZE - LAST_SIZE))

      SPEED_MBPS=$(awk "BEGIN { printf \"%.3f\", $DIFF / $ELAPSED / 1024 / 1024 }")
      PERCENT=$(awk "BEGIN { printf \"%d\", (70 * $CUR_SIZE / $TOTAL_SIZE) + 10 }")
      [[ $PERCENT -gt 79 ]] && PERCENT=79
 
      log_progress "$PERCENT" "Downloading the update... ($SPEED_MBPS MB/s)"

      LAST_SIZE=$CUR_SIZE
      LAST_TIME=$CUR_TIME
    fi
  done
) &
PROGRESS_PID=$!

# Actual download
curl --silent --show-error -fL "$ENDPOINT$IMAGE_URL" -o "$ISO_FILE"

kill "$PROGRESS_PID" 2>/dev/null || true

# Download signature file
log_progress "80" "Verifying download integrity..."

curl --silent --show-error -fL "$ENDPOINT$IMAGE_URL.sig" -o "$ISO_FILE.sig" || {
  log_error "Error: Failed to download file $ISO_FILE.sig."
  exit 1
}

if [[ -f "$ISO_FILE.sig" ]]; then
  log_info "Signature file downloaded successfully."
  if ! openssl dgst -sha256 -verify "$RELEASE_PK" -signature "$ISO_FILE.sig" "$ISO_FILE"; then
    log_error "Error: Signature verification failed for $ISO_FILE."
    rm -f "$ISO_FILE.sha256"
    exit 1
  fi
  rm -f "$ISO_FILE.sha256"
else
  log_error "Error: Signature file $ISO_FILE.sig not found after download."
  exit 1
fi

log_progress "83" "Extracting update package..."

mkdir -p "$ISO_MOUNT"
mount -o loop "$ISO_FILE" "$ISO_MOUNT"

# --- Step 5: Mount airootfs.sfs ------------------------------------------------
SFS_PATH="$ISO_MOUNT/arch/x86_64/airootfs.sfs"
if [[ ! -f "$SFS_PATH" ]]; then
  log_error "airootfs.sfs not found in image."
  exit 1
fi

log_info "Mounting SquashFS: $SFS_PATH"
mkdir -p "$SFS_MOUNT"
mount -t squashfs -o loop "$SFS_PATH" "$SFS_MOUNT"

log_progress "85" "Installing update to new snapshot..."

# --- Step 6: Rsync selective update to NEW snapshot ---------------------------
log_info "Syncing filesystem into '@snapshots/@ota_new' snapshot..."
rsync -aAX --delete --info=progress2 \
  --exclude={"/dev/*","/.snapshots/*","/proc/*","/boot/*","/sys/*","/tmp/*","/var/tmp/*","/run/*","/mnt/*","/media/*","/live-efi/*","/lost+found","/etc/fstab","/etc/machine-id","/etc/hostname","/etc/ssh/ssh_host_*","/etc/NetworkManager/system-connections/*","/var/lib/systemd/random-seed","/home/feralfile/.config/chromium","/home/feralfile/.logs/*","/home/feralfile/.state/*"} \
  "$SFS_MOUNT"/ "$NEW_ROOT"/

# Clean up unwanted files in new snapshot
rm -f "$NEW_ROOT"/mnt/root/.automated_script.sh
rm -f "$NEW_ROOT"/mnt/root/.bash_profile
rm -rf "$NEW_ROOT"/home/soaktest
rm -f "$NEW_ROOT"/usr/local/bin/websocat

# Remove soaktest user if exists
arch-chroot "$NEW_ROOT" /bin/bash -c "id soaktest &>/dev/null && userdel soaktest || true"

log_progress "90" "Updating boot configuration..."

# --- Step 7: Update boot files -------------------------------------------------
7z e "$ISO_FILE" "[BOOT]/Boot-NoEmul.img" -o"$TMP_DIR"

mkdir -p "$BOOT_MOUNT"
mount -o loop "$TMP_DIR"/Boot-NoEmul.img "$BOOT_MOUNT"

rsync -a "$BOOT_MOUNT"/arch/boot/x86_64/vmlinuz-linux /boot/vmlinuz-linux
rsync -a "$BOOT_MOUNT"/arch/boot/x86_64/initramfs-linux.img /boot/initramfs-linux.img
rsync -a "$BOOT_MOUNT"/arch/boot/intel-ucode.img /boot/intel-ucode.img
rsync -a "$BOOT_MOUNT"/loader /boot
rsync -a "$BOOT_MOUNT"/EFI /boot

sync

umount "$BOOT_MOUNT"

log_info "Detecting root partition PARTUUID..."
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEV")

cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 0
editor no
EOF

cat > /boot/loader/entries/arch.conf <<EOF
title   FF1
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
initrd  /intel-ucode.img
options root=PARTUUID=$PARTUUID root_partuuid=$PARTUUID ipv6.disable=1 rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog
EOF

cat > /boot/loader/entries/factory_reset.conf <<EOF
title   FF1 - Factory Reset
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
initrd  /intel-ucode.img
options rollback=factory root=PARTUUID=$PARTUUID root_partuuid=$PARTUUID ipv6.disable=1 rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog
EOF

cat > /boot/loader/entries/ota_prev.conf <<EOF
title   FF1 - Rollback to previous version
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
initrd  /intel-ucode.img
options rollback=ota root=PARTUUID=$PARTUUID root_partuuid=$PARTUUID ipv6.disable=1 rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog
EOF

# Update mkinitcpio in new snapshot
mount --bind /boot "$NEW_ROOT/boot"
arch-chroot "$NEW_ROOT" /bin/bash <<'CHROOT_EOF'
echo "Overwriting mkinitcpio.conf HOOKS..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev modconf autodetect block keyboard keymap btrfs-rollback btrfs filesystems fsck)/' /etc/mkinitcpio.conf

echo "Generating initramfs..."
mkinitcpio -P

echo "Applying systemd presets..."
systemctl preset-all --preset-mode=enable-only
CHROOT_EOF

log_info "Installing systemd-boot to disk..."
bootctl install

sync
umount "$NEW_ROOT/boot"

systemctl restart NetworkManager
sleep 3

# --- Step 8: Setup pacman in new snapshot --------------------------------------
log_progress "95" "Setting up package manager..."
arch-chroot "$NEW_ROOT" /bin/bash <<'CHROOT_EOF'
pacman-key --init
pacman-key --populate archlinux
pacman-key --add /etc/pacman.d/feralfile-pkg-pubkey.asc
pacman-key --lsign-key AA6B250F2938F3CB
pacman -Syy

usermod -aG tss feralfile
mkdir -p /etc/udev/rules.d
echo 'KERNEL=="tpmrm0", GROUP="tss", MODE="0660"' > /etc/udev/rules.d/99-tpm-feralfile.rules
CHROOT_EOF

# --- Step 9: Set @snapshots/@ota_new as default subvolume --------------------------------
log_progress "98" "Setting new snapshot as default boot target..."
log_info "Getting @snapshots/@ota_new subvolume ID..."
NEW_SUBVOL_ID=$(btrfs subvolume list "$BTRFS_TOP" | awk '$NF=="@snapshots/@ota_new" {print $2}')

if [[ -z "$NEW_SUBVOL_ID" ]]; then
  log_error "Failed to get @snapshots/@ota_new subvolume ID"
  umount -R "$NEW_ROOT"
  umount "$BTRFS_TOP"
  exit 1
fi

log_info "Setting @snapshots/@ota_new (ID: $NEW_SUBVOL_ID) as default subvolume..."
btrfs subvolume set-default "$NEW_SUBVOL_ID" "$BTRFS_TOP"

# --- Step 10: Clean up and reboot ---------------------------------------------
log_progress "99" "Cleaning up..."
log_info "Cleaning up mounts and temporary data..."
cleanup
trap - EXIT

log_progress "100" "Update complete! Restarting device..."
log_info "OTA update complete. System will boot from @snapshots/@ota_new. Rebooting now..."
systemctl reboot --no-wall --no-block