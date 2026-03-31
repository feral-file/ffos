#!/bin/bash
set -euo pipefail

# Recovery Candidate Update Script
# Standalone service that checks for and installs new recovery versions.
# The recovery candidate will be used on next factory reset.

LOCKFILE="/run/feral-recovery-update.lock"

log_info() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [INFO] recovery_update message=\"$message\""
}

log_error() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [ERROR] recovery_update message=\"$message\""
}

handle_err() {
  local exit_code=$?
  log_error "EXCEPTION ERR: LINE=$LINENO CMD=\"$BASH_COMMAND\""
  exit "$exit_code"
}

trap handle_err ERR

# Check if OTA updater is running - don't interfere with normal updates
if /usr/bin/flock -n /run/feral-updater.lock -c "exit 0" 2>/dev/null; then
  # Lock is available (no OTA update running)
  :
else
  # OTA updater is running, skip recovery update
  log_info "OTA update in progress. Skipping recovery update to avoid conflicts."
  exit 0
fi

# Acquire exclusive lock (non-blocking)
exec 8>"$LOCKFILE"
if ! flock -n 8; then
  log_error "Recovery update lock already held by another instance."
  exit 0
fi

# Ensure lock is released on any exit (overridden later by full cleanup trap)
release_lock() {
  flock -u 8 2>/dev/null || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}
trap release_lock EXIT

# Check network connectivity
if ! ping -q -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
  log_info "No network connection. Skipping recovery update check."
  exit 0
fi

CONFIG_FILE="/home/feralfile/ff1-config.json"
RELEASE_PK="/root/.ff1-release-public-key.pem"

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Config file not found: $CONFIG_FILE"
  exit 0
fi

log_info "=== Recovery Update Check Started ==="

branch=$(jq -r '.branch' "$CONFIG_FILE")
ENDPOINT=$(jq -r '.endpoint' "$CONFIG_FILE")

# Fetch latest version info from server
API_URL="$ENDPOINT/api/latest/$branch"
log_info "Fetching version info from: $API_URL"

response=$(curl -s -f -L "$API_URL") || {
  log_error "Failed to fetch version info from API"
  exit 0
}

# Extract recovery version info
RECOVERY_VERSION=$(jq -r '.recovery_version // empty' <<< "$response")
RECOVERY_URL=$(jq -r '.recovery_image_url // empty' <<< "$response")

if [[ -z "$RECOVERY_VERSION" || -z "$RECOVERY_URL" ]]; then
  log_info "No recovery version specified by server. Skipping."
  exit 0
fi

# --- Begin Setup ---

ISO_MOUNT="/mnt/recovery-iso"
SFS_MOUNT="/mnt/recovery-sfs"
TMP_DIR="/var/tmp/recovery-update"
ISO_FILE="$TMP_DIR/recovery.iso"
BOOT_MOUNT="/mnt/recovery-boot"
RECOVERY_ROOT="/mnt/recovery-candidate"
BTRFS_TOP="/mnt/btrfs-top-recovery"

cleanup() {
  trap - ERR

  cd /
  sync
  sleep 2
  umount -Rl "$RECOVERY_ROOT" 2>/dev/null || true
  umount "$BTRFS_TOP" 2>/dev/null || true
  umount "$BOOT_MOUNT" 2>/dev/null || true
  umount -Rl "$SFS_MOUNT" 2>/dev/null || true
  umount -Rl "$ISO_MOUNT" 2>/dev/null || true
  rm -rf "$TMP_DIR"

  # Release lock
  flock -u 8 2>/dev/null || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}
trap cleanup EXIT

# Get root device and mount btrfs top-level
log_info "Finding root device and mounting btrfs top-level..."
ROOT_DEV=$(findmnt / -no SOURCE)
ROOT_DEV="${ROOT_DEV%%\[*}"

mkdir -p "$BTRFS_TOP"
mount -o subvolid=0 "$ROOT_DEV" "$BTRFS_TOP"

# Skip if this version is already the same as factory reset version
# (read directly from @factory_reset snapshot's config)
FACTORY_RESET_CONFIG="$BTRFS_TOP/@snapshots/@factory_reset/home/feralfile/ff1-config.json"
if [[ -f "$FACTORY_RESET_CONFIG" ]]; then
  INSTALLED_FR_VERSION=$(jq -r '.version // empty' "$FACTORY_RESET_CONFIG")
  if [[ -n "$INSTALLED_FR_VERSION" && "$RECOVERY_VERSION" == "$INSTALLED_FR_VERSION" ]]; then
    log_info "Recovery version $RECOVERY_VERSION already installed as factory reset version."
    exit 0
  fi
fi

# Skip if this version is already installed as a candidate
# (read directly from @recovery_candidate snapshot's config)
RECOVERY_CANDIDATE_CONFIG="$BTRFS_TOP/@snapshots/@recovery_candidate/home/feralfile/ff1-config.json"
if [[ -f "$RECOVERY_CANDIDATE_CONFIG" ]]; then
  INSTALLED_RC_VERSION=$(jq -r '.version // empty' "$RECOVERY_CANDIDATE_CONFIG")
  if [[ -n "$INSTALLED_RC_VERSION" && "$RECOVERY_VERSION" == "$INSTALLED_RC_VERSION" ]]; then
    log_info "Recovery version $RECOVERY_VERSION already installed as candidate."
    exit 0
  fi
fi

# Skip if this version previously failed to boot
# (stored in /home/feralfile/.state/ to survive OTA updates; the failed snapshot is deleted after failure)
FAILED_RECOVERY_VERSION_FILE="/home/feralfile/.state/failed_recovery_version"
if [[ -f "$FAILED_RECOVERY_VERSION_FILE" ]]; then
  FAILED_VERSION=$(cat "$FAILED_RECOVERY_VERSION_FILE")
  if [[ "$RECOVERY_VERSION" == "$FAILED_VERSION" ]]; then
    log_info "Recovery version $FAILED_VERSION previously failed boot. Skipping."
    exit 0
  fi
  # Different version available — clear failed marker and proceed
  log_info "New recovery version $RECOVERY_VERSION available (previous failed version was $FAILED_VERSION). Clearing failed marker."
  rm -f "$FAILED_RECOVERY_VERSION_FILE"
fi

log_info "New recovery version available: $RECOVERY_VERSION"
log_info "Starting recovery candidate installation..."

# Prepare @recovery_candidate_new subvolume (fresh install)
log_info "Preparing @snapshots/@recovery_candidate_new subvolume..."

# Clean up leftovers from previous interrupted runs
if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate_old" ]]; then
  log_info "Cleaning up leftover @snapshots/@recovery_candidate_old from previous run..."
  btrfs subvolume delete "$BTRFS_TOP/@snapshots/@recovery_candidate_old" || true
fi

if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate_new" ]]; then
  log_info "Removing existing @snapshots/@recovery_candidate_new subvolume..."
  btrfs subvolume delete "$BTRFS_TOP/@snapshots/@recovery_candidate_new"
fi

if btrfs subvolume snapshot "$BTRFS_TOP/@snapshots/@factory_reset" "$BTRFS_TOP/@snapshots/@recovery_candidate_new"; then
  log_info "Snapshot '@snapshots/@recovery_candidate_new' created from @factory_reset."
else
  log_error "Failed to create subvolume '@snapshots/@recovery_candidate_new'. Aborting."
  exit 1
fi

mkdir -p "$RECOVERY_ROOT"
mount -o compress=zstd,noatime,subvol=@snapshots/@recovery_candidate_new "$ROOT_DEV" "$RECOVERY_ROOT"

# Download and verify ISO
log_info "Downloading recovery ISO..."
mkdir -p "$TMP_DIR"

curl --silent --show-error -fL "$ENDPOINT$RECOVERY_URL" -o "$ISO_FILE" || {
  log_error "Failed to download recovery ISO from $ENDPOINT$RECOVERY_URL"
  exit 1
}

log_info "Downloading signature file..."
curl --silent --show-error -fL "$ENDPOINT$RECOVERY_URL.sig" -o "$ISO_FILE.sig" || {
  log_error "Failed to download signature file."
  exit 1
}

log_info "Verifying signature..."
if ! openssl dgst -sha256 -verify "$RELEASE_PK" -signature "$ISO_FILE.sig" "$ISO_FILE"; then
  log_error "Signature verification failed for recovery ISO."
  exit 1
fi
log_info "Signature verified successfully."

# Mount and extract ISO
log_info "Mounting ISO..."
mkdir -p "$ISO_MOUNT"
mount -o loop "$ISO_FILE" "$ISO_MOUNT"

SFS_PATH="$ISO_MOUNT/arch/x86_64/airootfs.sfs"
if [[ ! -f "$SFS_PATH" ]]; then
  log_error "airootfs.sfs not found in ISO."
  exit 1
fi

log_info "Mounting SquashFS: $SFS_PATH"
mkdir -p "$SFS_MOUNT"
mount -t squashfs -o loop "$SFS_PATH" "$SFS_MOUNT"

# Rsync filesystem to recovery candidate
log_info "Syncing filesystem to @snapshots/@recovery_candidate_new..."
rsync -aAX --delete \
  --exclude={"/dev/*","/.snapshots/*","/proc/*","/boot/*","/sys/*","/tmp/*","/var/tmp/*","/run/*","/mnt/*","/media/*","/live-efi/*","/lost+found","/etc/fstab","/etc/machine-id","/etc/hostname","/etc/ssh/ssh_host_*","/etc/NetworkManager/system-connections/*","/var/lib/systemd/random-seed"} \
  "$SFS_MOUNT"/ "$RECOVERY_ROOT"/

log_info "Filesystem sync complete."

# Extract and backup boot files
log_info "Extracting boot files from ISO..."
7z e "$ISO_FILE" "[BOOT]/Boot-NoEmul.img" -o"$TMP_DIR"

mkdir -p "$BOOT_MOUNT"
mount -o loop "$TMP_DIR"/Boot-NoEmul.img "$BOOT_MOUNT"

log_info "Backing up boot files to recovery candidate..."
mkdir -p "$RECOVERY_ROOT/var/lib/factory_reset_boot"
rsync -a "$BOOT_MOUNT"/arch/boot/x86_64/vmlinuz-linux "$RECOVERY_ROOT/var/lib/factory_reset_boot/"
rsync -a "$BOOT_MOUNT"/arch/boot/x86_64/initramfs-linux.img "$RECOVERY_ROOT/var/lib/factory_reset_boot/"
rsync -a "$BOOT_MOUNT"/arch/boot/intel-ucode.img "$RECOVERY_ROOT/var/lib/factory_reset_boot/"
rsync -a "$BOOT_MOUNT"/loader "$RECOVERY_ROOT/var/lib/factory_reset_boot/"
rsync -a "$BOOT_MOUNT"/EFI "$RECOVERY_ROOT/var/lib/factory_reset_boot/"

umount "$BOOT_MOUNT"

# Setup initramfs in recovery candidate
log_info "Configuring recovery candidate using version-specific script..."

# Try new unified script first, fall back to legacy script
POST_EXTRACTION_SCRIPT="$RECOVERY_ROOT/root/scripts/post-extraction.sh"

mount --bind "$RECOVERY_ROOT/var/lib/factory_reset_boot" "$RECOVERY_ROOT/boot"

if [[ -f "$POST_EXTRACTION_SCRIPT" && -x "$POST_EXTRACTION_SCRIPT" ]]; then
  log_info "Found post-extraction script in ISO, executing with ISO's logic..."
  arch-chroot "$RECOVERY_ROOT" /bin/bash /root/scripts/post-extraction.sh "$ROOT_DEV"
  log_info "Post-extraction script completed successfully."
else
  log_error "No post-extraction script found in ISO"
  exit 1
fi

umount "$RECOVERY_ROOT/boot"

# Atomically replace @recovery_candidate with @recovery_candidate_new
log_info "Replacing @recovery_candidate with @recovery_candidate_new..."

# Unmount recovery root first
umount -Rl "$RECOVERY_ROOT" 2>/dev/null || true
sync

# Step 1: Rename old @recovery_candidate out of the way (fast, metadata-only)
if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate" ]]; then
  log_info "Moving old @snapshots/@recovery_candidate aside..."
  mv "$BTRFS_TOP/@snapshots/@recovery_candidate" "$BTRFS_TOP/@snapshots/@recovery_candidate_old"
fi

# Step 2: Rename new into place (fast, metadata-only)
mv "$BTRFS_TOP/@snapshots/@recovery_candidate_new" "$BTRFS_TOP/@snapshots/@recovery_candidate"
btrfs property set "$BTRFS_TOP/@snapshots/@recovery_candidate" ro true
log_info "Successfully replaced @recovery_candidate."

# Step 3: Delete the old one (slow, but no longer on the critical path)
if [[ -d "$BTRFS_TOP/@snapshots/@recovery_candidate_old" ]]; then
  log_info "Cleaning up old @snapshots/@recovery_candidate_old..."
  btrfs subvolume delete "$BTRFS_TOP/@snapshots/@recovery_candidate_old" || \
    log_error "Warning: Failed to delete old recovery candidate. It can be cleaned up manually."
fi

# Cleanup
log_info "Cleaning up..."
cleanup
trap - EXIT

log_info "=== Recovery candidate version $RECOVERY_VERSION installed successfully ==="
log_info "The new recovery version will be used on next factory reset."
