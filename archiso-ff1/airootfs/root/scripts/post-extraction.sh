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

# --- Step 1: Clean up unwanted files and test users ---
echo "Cleaning up unwanted files and directories..."

# Remove test/development files that shouldn't be in production
rm -f /root/.automated_script.sh
rm -f /root/.bash_profile
rm -rf /home/soaktest
rm -f /usr/local/bin/websocat

cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --noclear --autologin feralfile %I $TERM
EOF

echo "Cleaning up test users..."
if id soaktest &>/dev/null; then
    userdel -r soaktest 2>/dev/null || true
    echo "Removed soaktest user."
fi

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
mkdir -p /etc/udev/rules.d
echo 'KERNEL=="tpmrm0", GROUP="tss", MODE="0660"' > /etc/udev/rules.d/99-tpm-feralfile.rules

# --- Step 9: Apply systemd presets ---
# This ensures services are enabled/disabled according to the new version's preferences
echo "Applying systemd presets..."
systemctl preset-all --preset-mode=enable-only || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-extraction configuration completed successfully."
