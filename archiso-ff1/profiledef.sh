#!/usr/bin/env bash
# shellcheck disable=SC2034

iso_name="FF1"
iso_label="ARCH_FFOS"
iso_publisher="Feral File <https://feralfile.com>"
iso_application="Feral File Launcher"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/initcpio/hooks/btrfs-rollback"]="0:0:750"
  ["/etc/initcpio/install/btrfs-rollback"]="0:0:750"
  ["/etc/NetworkManager/dispatcher.d/09-timezone"]="0:0:755"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/scripts/install-to-disk.sh"]="0:0:755"
  ["/root/scripts/auto-install.sh"]="0:0:755"
  ["/root/scripts/feral-updater.sh"]="0:0:755"
  ["/root/scripts/feral-service-update.sh"]="0:0:755"
  ["/root/scripts/feral-system-update.sh"]="0:0:755"
  ["/root/scripts/feral-update.sh"]="0:0:755"
  ["/root/scripts/factory_reset.sh"]="0:0:755"
  ["/root/scripts/btrfs-subvolume-manager.sh"]="0:0:755"
)