#!/bin/bash
# Single source of the kernel command line options shared by every boot entry
# FF1 writes (post-extraction.sh, install-to-disk.sh, auto-install.sh,
# factory_reset.sh, feral-system-update.sh). Source this file and append
# "$FF1_KERNEL_OPTS" after the entry-specific root=/rootflags=/rollback= words.
#
# Display policy (ffos#126): nothing the kernel, the initramfs or systemd
# prints may reach the panel.
#   console=tty3            kernel console, initramfs hook output (the btrfs
#                           hook's "Scanning for Btrfs filesystems") and the
#                           emergency shell land on an invisible VT
#   systemd.show_status=false / rd.systemd.show_status=false
#                           no "[  OK  ]" / "A start job is running" lines
#   splash plymouth.ignore-serial-consoles
#                           plymouth paints boot/shutdown; without the second
#                           word it treats console=tty3 as a serial console and
#                           degrades to text mode
#   vt.global_cursor_default=0
#                           no blinking cursor on the blank VT behind cage
# Everything else is unchanged from before this policy.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
FF1_KERNEL_OPTS="ipv6.disable=1 rw quiet splash plymouth.ignore-serial-consoles loglevel=3 console=tty3 systemd.show_status=false rd.systemd.show_status=false udev.log_level=3 rd.udev.log_level=3 vt.global_cursor_default=0 nowatchdog"
