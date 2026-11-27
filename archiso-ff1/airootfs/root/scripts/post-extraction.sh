#!/bin/bash
# post-extraction.sh — version-specific post-extraction configuration
# Called by both OTA updates and recovery updates
# This script travels with the ISO and contains version-specific logic
#
# Usage: post-extraction.sh <root_dev>
#   root_dev: root device path (e.g., /dev/nvme0n1p2)

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "ERROR: Usage: $0 <root_dev>" >&2
    echo "  root_dev: root device path (e.g., /dev/nvme0n1p2)" >&2
    exit 1
fi

ROOT_DEV="$1"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting post-extraction configuration (ROOT_DEV: $ROOT_DEV)..."

# --- Step 1: Clean up unwanted files ---
echo "Cleaning up unwanted files and directories..."

# Remove test/development files that shouldn't be in production
rm -f /root/.automated_script.sh
rm -f /root/.bash_profile

# feral-system-update.sh protects /home/feralfile/.cache wholesale so the
# offline artwork blob store survives a full-image update. That inverts the
# default for the entire XDG cache directory: everything under ~/.cache now
# outlives an OTA unless it is deleted right here.
#
# This list is an ALLOWLIST-BY-EXCEPTION, not an exhaustive account of what
# persists. Add to it whenever a package starts writing cache state that must
# not survive an update.
#
# The two below are regenerable Chromium state that the OTA rsync used to clear
# as a side effect; carrying a browser profile across a Chromium version bump is
# the specific hazard being avoided.
# No-op on the recovery path, whose tree comes from the cache-free
# @factory_reset snapshot, and on a device that has never cached anything.
rm -rf /home/feralfile/.cache/offline-artworks-headless-profile
rm -rf /home/feralfile/.cache/chromium

# No getty autologin is written any more (ffos#126): the image's
# getty@tty1.service.d/autologin.conf only applies to live ISO boots and
# feral-kiosk-startup.service owns tty1 on installed devices.

echo "Cleanup complete."

# --- Step 2: set environment to live ---
echo "Setting environment to 'live' mode..."
mkdir -p /home/feralfile/.state
cat > /home/feralfile/.state/environment <<EOF
live
EOF

# --- Step 3: Write boot entries ---
echo "Detecting root partition PARTUUID..."
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_DEV")

if [[ -z "$PARTUUID" ]]; then
    echo "ERROR: Failed to get PARTUUID for $ROOT_DEV" >&2
    exit 1
fi

echo "Writing boot loader configuration (PARTUUID: $PARTUUID)..."
# The whole boot set: loader.conf and every entry (ff1-boot-options.sh,
# single source shared with both installers).
if [[ ! -r /root/scripts/ff1-boot-options.sh ]]; then
    echo "ERROR: /root/scripts/ff1-boot-options.sh missing; refusing to write a boot entry without the shared kernel options" >&2
    exit 1
fi
source /root/scripts/ff1-boot-options.sh
ff1_write_boot_set /boot "$PARTUUID" || { echo "ERROR: failed to write the boot set" >&2; exit 1; }

# --- Step 4: Configure mkinitcpio hooks ---
echo "Configuring mkinitcpio hooks..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev modconf autodetect block keyboard keymap btrfs btrfs-rollback filesystems fsck)/' /etc/mkinitcpio.conf

# --- Step 5: Generate initramfs ---
echo "Generating initramfs..."
if ! mkinitcpio -P; then
    echo "ERROR: Failed to generate initramfs" >&2
    exit 1
fi
echo "Initramfs generated successfully."

# --- Step 6: Configure pacman keys ---
echo "Configuring pacman keys..."
pacman-key --init
pacman-key --populate archlinux

# Add FeralFile package signing key
if [[ -f /etc/pacman.d/feralfile-pkg-pubkey.asc ]]; then
    pacman-key --add /etc/pacman.d/feralfile-pkg-pubkey.asc
    pacman-key --lsign-key AA6B250F2938F3CB
    echo "FeralFile package key configured."
else
    echo "WARNING: FeralFile package key not found at /etc/pacman.d/feralfile-pkg-pubkey.asc"
fi

# --- Step 7: sync package databases ---
echo "Syncing package databases..."
# Don't make pacman -Syy fatal - network issues shouldn't abort an otherwise successful update
pacman -Syy || echo "Warning: Failed to sync package databases, continuing anyway"

# --- Step 8: Configure tss group and udev rules ---
echo "Configuring TPM access..."
usermod -aG tss feralfile
# seat: cage talks to seatd (ffos#126); /etc/group in the image already lists
# it, this is the belt for a root whose group file predates that.
usermod -aG seat feralfile
# i2c: ddcutil (DDC/CI panel control in feral-controld) needs RW on /dev/i2c-*.
# The buses are root:i2c 0660 (i2c-tools/ddcutil udev rules) and the group is
# created by i2c-tools' sysusers entry, but for the logged-in user ddcutil
# relies on TAG+="uaccess", and since ffos#126 nobody logs in. Membership in
# i2c is the only grant that works without a session. The image's /etc/group
# already has it; this is the belt for a root whose group file predates that
# (groupadd -f is a no-op when the group exists; sysusers may have made it).
groupadd -f --system i2c
usermod -aG i2c feralfile
mkdir -p /etc/udev/rules.d
echo 'KERNEL=="tpmrm0", GROUP="tss", MODE="0660"' > /etc/udev/rules.d/99-tpm-feralfile.rules

# --- Step 9: Apply systemd presets ---
# This ensures services are enabled/disabled according to the new version's preferences
echo "Applying systemd presets..."
systemctl preset-all --preset-mode=enable-only || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-extraction configuration completed successfully."
