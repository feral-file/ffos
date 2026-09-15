# Boot display and console policy

What a customer sees on the panel from power-on to power-off, and how a
developer still gets a shell. Introduced for ffos#126 (a sudo-capable console
appeared on the TV whenever the kiosk had no picture) and verified on FF1
hardware.

## Rules

1. **Nothing text-mode ever reaches the panel.** The kernel console is
   `tty3` (`console=tty3`), systemd status output is off
   (`systemd.show_status=false`, also `rd.`), udev logs are quiet and the VT
   cursor is hidden. The initramfs btrfs hook's `Scanning for Btrfs
   filesystems` line, kernel messages, `[FAILED]` lines and even the emergency
   shell all land on tty3, which is never the active VT. The options live in
   one place, `/root/scripts/ff1-boot-options.sh` (`FF1_KERNEL_OPTS`), and
   every script that writes a loader entry sources it; `scripts/verify.sh`
   rejects a literal copy.
2. **No login shell on tty1.** `feral-kiosk-startup.service` is a *system*
   unit with `User=feralfile` (it is not itself a user-manager unit). It runs
   `.file_permissions.sh` and `.start-services.sh`, which start the real
   `systemctl --user` units (kiosk, watchdog, controld) inside `user@1000`,
   and replaces the `agetty --autologin feralfile` session and
   `~/.bash_profile` rail. The user manager starts at
   boot because `/var/lib/systemd/linger/feralfile` ships in the image. The
   `getty@tty1` drop-in is conditioned on `archisobasedir` (live ISO only:
   installer and soak test keep their root/soaktest autologin).
3. **cage gets DRM through seatd, not logind.** With no session on tty1,
   libseat's logind backend would attach to whatever session logind elects
   for the user (an SSH login, for instance) and fail. `seatd.service` is
   enabled, `feralfile`/`soaktest` are in the `seat` group and
   `/etc/systemd/user.conf.d/10-ff1-seatd.conf` pins
   `LIBSEAT_BACKEND=seatd` for every user-manager unit. That is where cage
   runs (`chromium-kiosk.service` under `user@1000`); moving cage into the
   system-scope startup unit would silently lose that default. A kiosk stop now leaves a
   black VT, never a prompt.
4. **Plymouth paints every non-kiosk moment.** Theme `ff1` (black, spinner,
   no watermark; `airootfs/usr/share/plymouth/themes/ff1`) is shown by
   `plymouth-start` at boot, `plymouth-reboot/poweroff` at shutdown, and by
   `feral-kiosk-fallback.service`, which `feral-watchdog` starts after its
   Chromium restart budget is exhausted: a stable "Something went wrong..."
   instead of a black screen. `plymouth.ignore-serial-consoles` is required
   because plymouth otherwise treats `console=tty3` as a serial console and
   degrades to text mode. Plymouth is **not** in the initramfs HOOKS: the
   console redirect already hides initramfs text and a broken hook would
   brick boot. Live ISO entries carry `plymouth.enable=0`: the installer
   and soak test want their text console, and a plymouth daemon that never
   answered `quit` blocked a live ISO at "Hold until boot process finishes
   up" (the installer getty is ordered after it). On installed devices the
   two quit units are capped at 30 s by drop-ins for the same reason.
5. **Developers keep an easy way in.** `getty@tty2` is enabled with a normal
   password login: plug a keyboard, press Ctrl+Alt+F2 (cage runs with `-s`,
   which allows VT switching), work, press Alt+F1 to return. `logind.conf.d`
   sets `NAutoVTs=0`/`ReserveVT=0` so no other VT ever spawns a getty.
   `start-kiosk.sh` (ffos-user) refuses to launch cage while tty1 is not the
   active VT, and the watchdog suppresses escalation in that state, so a
   kiosk restart cannot steal the developer's console. SSH via the
   controld dev-ssh flow is unchanged.

## Where each piece lives

| Piece | Path |
|---|---|
| Kernel options | `archiso-ff1/airootfs/root/scripts/ff1-boot-options.sh` |
| Kiosk startup unit | `archiso-ff1/airootfs/etc/systemd/system/feral-kiosk-startup.service` |
| Fallback screen unit | `archiso-ff1/airootfs/etc/systemd/system/feral-kiosk-fallback.service` |
| Live-ISO-only autologin | `archiso-ff1/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf` |
| No autovt | `archiso-ff1/airootfs/etc/systemd/logind.conf.d/10-ff1-no-autovt.conf` |
| seatd for user units | `archiso-ff1/airootfs/etc/systemd/user.conf.d/10-ff1-seatd.conf` |
| Enabled units | `archiso-ff1/airootfs/etc/systemd/system-preset/90-default.preset` |
| Plymouth | `archiso-ff1/airootfs/etc/plymouth/plymouthd.conf`, `archiso-ff1/airootfs/usr/share/plymouth/themes/ff1/` |
| Kiosk side (`cage -s`, VT1 wait, fallback stop, watchdog policy) | ffos-user `users/feralfile/`, `components/feral-watchdog/` |

## Update and reset paths (rehearsed on an FF1)

- **OTA from an older release.** The old `feral-system-update.sh` extracts
  the new image, runs the new `post-extraction.sh` in the chroot (it sources
  the new `ff1-boot-options.sh`, enables `seatd`, `feral-kiosk-startup` and
  `getty@.service tty1 tty2` through `preset-all`, drops `sudoers.d/soaktest`,
  adds `feralfile` to `seat`) and writes the one-shot candidate entry with
  its own, old, options. That single candidate boot therefore runs the new
  system with `systemd.show_status=auto` and no `console=tty3`: systemd's
  `[  OK  ]` lines are briefly visible on tty1 until plymouth/cage take over.
  The kiosk itself starts correctly on that boot (verified), the promotion
  deploys the staged `arch.conf` with the new options, and every later boot
  is clean. Accepted as a one-off cosmetic on the upgrade boot.
- **Factory reset from the new release.** The new `factory_reset.sh` writes
  the candidate entry with the new options; the old recovery snapshot boots
  with them (they are inert for an image without plymouth: `splash` and
  `plymouth.ignore-serial-consoles` are ignored, `console=tty3` just moves
  kernel text), promotes itself and comes up with its own tty1 autologin
  kiosk. After that, an OTA to the new release behaves as above (verified in
  that order: reset to 2.0.1, then OTA-style promotion to this design).
- **Preset syntax.** `enable getty@tty2.service` in a preset file is *not*
  instantiated by `preset-all`; the instance form `enable getty@.service
  tty1 tty2` is. tty1 has to be listed too: `90-default.preset` sorts before
  systemd's `90-systemd.preset` and the first matching rule wins, so a
  tty2-only rule would leave the live ISO without its installer getty. The
  rehearsal caught the first half; review caught the second; `scripts/verify.sh`
  pins both.

## Trade-offs

- The fallback screen is followed by a reboot after the watchdog's hold
  (15 minutes); the restart budget is memory-only (ffos-user#254), so a
  persistently broken kiosk cycles between ~5 minutes of restarts and 15
  minutes of fallback. Bounded, and the customer mostly sees the message.
- `sudoers.d/feralfile` is still `NOPASSWD: ALL` and the polkit
  `manage-units` grant is root-equivalent; narrowing both is a separate
  change. The console that exposed them is gone.
- A keyboard-wielding visitor can reach the tty2 login prompt and read
  kernel messages on tty3. Both are password-free of nothing: tty2 asks for
  a password and tty3 has no shell.
- The systemd-boot factory-reset countdown menu (issue #122) is still a
  text screen by design: it is the one moment where the user must see a
  choice.
