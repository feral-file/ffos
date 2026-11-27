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

# ff1_write_boot_set <boot_dir> <partuuid>: the installed FF1's whole boot set,
# written by install-to-disk.sh, auto-install.sh and post-extraction.sh (every
# full-image OTA runs the new image's copy of this file). One writer, so an
# entry added here reaches every install and every update; verify.sh fails a
# script that writes arch.conf or factory_reset.conf itself.
#
#   loader.conf         default arch.conf, timeout 0 (no menu unless a key is
#                       held at power-on), editor no (no retyping an entry).
#                       random-seed-mode off: the power-cycle reset gesture
#                       (issue #122) invites users to cut power in early boot,
#                       exactly when systemd-boot would rewrite the ESP
#                       random-seed file, a FAT32 write window of the same
#                       corruption class as F-05. With it off, normal boots
#                       leave the ESP read-only; x86 RDRAND covers early-boot
#                       entropy.
#   arch.conf           FF1, the default.
#   factory_reset.conf  rollback=factory (btrfs-rollback hook).
#   ff1_factory_panel.conf, ff1_factory_hardware.conf, ff1_factory_fields.conf
#                       the three factory tests (ffos-user ff1-burnin.sh): each
#                       boots ff1-burnin.target instead of the default target,
#                       so the kiosk, controld, the watchdog and the updaters
#                       never start; ff1.burnin is the word the updater
#                       drop-ins and the service test, ff1.factory= picks the
#                       test. Menu only, like the factory reset.
#                         panel     load until 10 min of power-on, then the
#                                   Panel Check's black/gray loop
#                         hardware  Wi-Fi, Bluetooth, speakers, brightness
#                         fields    the nine-point chart and the white, gray,
#                                   black, red, green, blue fields, one per
#                                   key press
ff1_write_boot_set() {
    local boot=$1 partuuid=$2 root
    root="root=PARTUUID=$partuuid root_partuuid=$partuuid"
    mkdir -p "$boot/loader/entries" || return 1
    rm -rf "$boot"/loader/entries/*
    cat > "$boot/loader/loader.conf" <<LOADER || return 1
default arch.conf
timeout 0
editor no
random-seed-mode off
LOADER
    ff1_write_entry "$boot" arch.conf "FF1" "$root $FF1_KERNEL_OPTS" || return 1
    ff1_write_entry "$boot" factory_reset.conf "FF1 - Factory Reset" "rollback=factory $root $FF1_KERNEL_OPTS" || return 1
    local mode title
    for mode in panel hardware fields; do
        case $mode in
            panel) title="FF1 - Factory: panel check, black/gray (factory use only)" ;;
            hardware) title="FF1 - Factory: hardware test (factory use only)" ;;
            fields) title="FF1 - Factory: nine-point and color fields (factory use only)" ;;
        esac
        ff1_write_entry "$boot" "ff1_factory_$mode.conf" "$title" \
            "systemd.unit=ff1-burnin.target ff1.burnin ff1.factory=$mode $root $FF1_KERNEL_OPTS" || return 1
    done
    chmod 644 "$boot"/loader/entries/*.conf
}

# ff1_write_entry <boot_dir> <file> <title> <options>
ff1_write_entry() {
    cat > "$1/loader/entries/$2" <<ENTRY
title   $3
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
initrd  /intel-ucode.img
options $4
ENTRY
}
