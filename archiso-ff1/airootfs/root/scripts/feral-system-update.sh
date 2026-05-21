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

download_with_retry() {
  local url="$1"
  local output="$2"
  local label="$3"
  local max_attempts=5
  local retry_delay=10
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    log_info "Downloading $label, attempt $attempt/$max_attempts"

    if curl \
      --silent \
      --show-error \
      --fail \
      --location \
      --connect-timeout 15 \
      --speed-time 60 \
      --speed-limit 1024 \
      "$url" \
      -o "$output"; then
      return 0
    fi

    log_info "Download attempt $attempt/$max_attempts failed for $label."
    attempt=$((attempt + 1))

    if [[ $attempt -le $max_attempts ]]; then
      log_info "Retrying $label download in $retry_delay seconds..."
      sleep "$retry_delay"
    fi
  done

  log_error "Failed to download $label after $max_attempts attempts."
  return 1
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
  
  # Kill progress monitor if still running
  if [[ -n "${PROGRESS_PID:-}" ]]; then
    kill "$PROGRESS_PID" 2>/dev/null || true
  fi

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
 
log_info "=== OTA Update: Snapshot-based Update with Boot Counting ==="
 
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

# Create new writable snapshot from current @snapshots/@
if btrfs subvolume snapshot "$BTRFS_TOP/@snapshots/@" "$BTRFS_TOP/@snapshots/@ota_new"; then
  log_info "Snapshot '@snapshots/@ota_new' created successfully."
else
  log_error "Failed to create snapshot '@snapshots/@ota_new'. Aborting."
  exit 1
fi

# Mount the new snapshot for updating
mkdir -p "$NEW_ROOT"
mount -o compress=zstd,noatime,subvol=@snapshots/@ota_new "$ROOT_DEV" "$NEW_ROOT"

# --- Step 4: Download and extract new iso ------------------------------------
log_progress "10" "Downloading new iso..."
mkdir -p "$TMP_DIR"
 
TOTAL_SIZE=$(curl -sLI "$ENDPOINT$IMAGE_URL" \
  | tr -d '\r' \
  | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {print $2}' \
  | tail -n1)

if [[ -z "$TOTAL_SIZE" ]]; then
  log_error "Failed to retrieve content length for image."
  exit 1
fi

log_info "Total file size to download: $TOTAL_SIZE bytes"

# Background progress loop with speed tracking
PROGRESS_PID=""
(
  LAST_SIZE=0
  LAST_TIME=$(date +%s)

  while sleep 3; do
    if [[ -f "$ISO_FILE" ]]; then
      CUR_SIZE=$(stat -c %s "$ISO_FILE")
      CUR_TIME=$(date +%s)
      ELAPSED=$((CUR_TIME - LAST_TIME))
      DIFF=$((CUR_SIZE - LAST_SIZE))

      # Avoid division by zero
      if [[ $ELAPSED -gt 0 ]]; then
        SPEED_MBPS=$(awk "BEGIN { printf \"%.3f\", $DIFF / $ELAPSED / 1024 / 1024 }")
      else
        SPEED_MBPS="0.000"
      fi
      PERCENT=$(awk "BEGIN { printf \"%d\", (70 * $CUR_SIZE / $TOTAL_SIZE) + 10 }")
      [[ $PERCENT -gt 79 ]] && PERCENT=79
 
      if [[ $DIFF -eq 0 ]]; then
        log_progress "$PERCENT" "Downloading the update... waiting for network"
      else
        log_progress "$PERCENT" "Downloading the update... ($SPEED_MBPS MB/s)"
      fi

      LAST_SIZE=$CUR_SIZE
      LAST_TIME=$CUR_TIME
    fi
  done
) &
PROGRESS_PID=$!

# Actual download. Retry protects setup from transient Wi-Fi drops during
# first-run OTA.
download_with_retry "$ENDPOINT$IMAGE_URL" "$ISO_FILE" "OTA image"

kill "$PROGRESS_PID" 2>/dev/null || true

# Download signature file
log_progress "80" "Verifying download integrity..."

download_with_retry "$ENDPOINT$IMAGE_URL.sig" "$ISO_FILE.sig" "OTA signature" || {
  log_error "Error: Failed to download file $ISO_FILE.sig."
  exit 1
}

if [[ -f "$ISO_FILE.sig" ]]; then
  log_info "Signature file downloaded successfully."
  if ! openssl dgst -sha256 -verify "$RELEASE_PK" -signature "$ISO_FILE.sig" "$ISO_FILE"; then
    log_error "Error: Signature verification failed for $ISO_FILE."
    exit 1
  fi
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
  --exclude={"/dev/*","/.snapshots/*","/proc/*","/boot/*","/sys/*","/tmp/*","/var/tmp/*","/run/*","/mnt/*","/media/*","/live-efi/*","/lost+found","/etc/fstab","/etc/machine-id","/etc/hostname","/etc/ssh/ssh_host_*","/etc/NetworkManager/system-connections/*","/var/lib/systemd/random-seed","/home/feralfile/.config/chromium","/home/feralfile/.logs","/home/feralfile/.state"} \
  "$SFS_MOUNT"/ "$NEW_ROOT"/

log_progress "90" "Preparing boot files..."

# --- Step 7: Stage boot files (don't touch live /boot yet) --------------------
7z e "$ISO_FILE" "[BOOT]/Boot-NoEmul.img" -o"$TMP_DIR"

mkdir -p "$BOOT_MOUNT"
mount -o loop "$TMP_DIR"/Boot-NoEmul.img "$BOOT_MOUNT"

# Create boot staging directory in the new snapshot
BOOT_STAGING="$NEW_ROOT/var/lib/ota_boot_staging"
mkdir -p "$BOOT_STAGING"

# Copy boot files from ISO to staging directory
log_info "Staging boot files from ISO..."
rsync -a "$BOOT_MOUNT"/arch/boot/x86_64/vmlinuz-linux "$BOOT_STAGING"/vmlinuz-linux
rsync -a "$BOOT_MOUNT"/arch/boot/x86_64/initramfs-linux.img "$BOOT_STAGING"/initramfs-linux.img
rsync -a "$BOOT_MOUNT"/arch/boot/intel-ucode.img "$BOOT_STAGING"/intel-ucode.img
rsync -a "$BOOT_MOUNT"/loader "$BOOT_STAGING"
rsync -a "$BOOT_MOUNT"/EFI "$BOOT_STAGING"

umount "$BOOT_MOUNT"

# --- Step 8: Configure new snapshot using version-specific script -------------
log_progress "95" "Configuring new snapshot..."
POST_EXTRACTION_SCRIPT="$NEW_ROOT/root/scripts/post-extraction.sh"

# Bind-mount staging directory as /boot for the post-extraction script
mount --bind "$BOOT_STAGING" "$NEW_ROOT/boot"

if [[ -f "$POST_EXTRACTION_SCRIPT" && -x "$POST_EXTRACTION_SCRIPT" ]]; then
  log_info "Found post-extraction script in ISO, executing with ISO's logic..."
  arch-chroot "$NEW_ROOT" /bin/bash /root/scripts/post-extraction.sh "$ROOT_DEV"
  log_info "Post-extraction script completed successfully."
else
  log_error "No post-extraction script found in ISO"
  exit 1
fi

umount "$NEW_ROOT/boot"

# --- Step 9: Stage candidate boot files and create boot entry -----------------
# NOTE: We do NOT overwrite /boot or change the btrfs default here.
# The current @ and its kernel remain as automatic fallback via arch.conf.
log_progress "98" "Finalizing update..."

# Deploy new kernel to /boot/candidate/ (side-by-side with current known-good kernel)
log_info "Staging candidate boot files to /boot/candidate/..."
mkdir -p /boot/candidate
rsync -a "$BOOT_STAGING"/vmlinuz-linux /boot/candidate/
rsync -a "$BOOT_STAGING"/initramfs-linux.img /boot/candidate/
rsync -a "$BOOT_STAGING"/intel-ucode.img /boot/candidate/
sync

# Write candidate boot entry
log_info "Creating candidate boot entry with boot counting..."
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEV")

cat > /boot/loader/entries/arch-candidate.conf <<EOF
title   FF1 - Update Candidate
linux   /candidate/vmlinuz-linux
initrd  /candidate/initramfs-linux.img
initrd  /candidate/intel-ucode.img
options rootflags=subvol=@snapshots/@ota_new root=PARTUUID=$PARTUUID root_partuuid=$PARTUUID ipv6.disable=1 rw quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 nowatchdog
EOF

chmod 644 /boot/loader/entries/arch-candidate.conf

bootctl set-oneshot arch-candidate.conf

log_info "Candidate boot entry created. Btrfs default unchanged."
sync

# --- Step 10: Clean up and reboot ---------------------------------------------
log_progress "99" "Cleaning up..."
log_info "Cleaning up mounts and temporary data..."
cleanup
trap - EXIT

log_progress "100" "Update complete! Restarting device..."
log_info "OTA update complete. Candidate boot entry created for @snapshots/@ota_new. Rebooting now..."
sync
systemctl reboot
