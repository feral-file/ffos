# Snapshot System v2 — Technical Reference

This document describes how the FFOS snapshot system v2 works: subvolume layout, OTA updates, factory reset, recovery updates, and boot-time rollback. It is intended for developers and operators who need to understand or modify these flows.

---

## Summary

Snapshot system v2 has three main characteristics:

1. **Root subvolume under `@snapshots/@`** — The live root filesystem is `@snapshots/@` instead of a top-level `@`. All snapshot and candidate subvolumes live under `@snapshots/`, which simplifies atomic renames and keeps a single hierarchy.

2. **One-shot candidate boot** — OTA and factory reset do not change the btrfs default subvolume before reboot. They create a candidate subvolume and a one-shot boot entry (`bootctl set-oneshot`). The next boot uses that entry once; if the candidate fails to boot, the following reboot uses the default entry and the known-good root. The btrfs default is only updated after a successful boot from the candidate (see Post-boot promotion).

3. **Recovery update service** — A background timer runs `feral-recovery-update.sh`, which downloads a server-advertised recovery image and installs it as `@snapshots/@recovery_candidate`. Factory reset prefers this candidate when present, so devices can receive a newer recovery image without a full reinstall.

**V1 vs v2 (high level)** — In v1, the root was a top-level `@`, and OTA/factory reset set the btrfs default to the new subvolume before rebooting (no one-shot, no staged boot files). v2 keeps the default unchanged until the candidate has booted successfully and uses a one-shot boot entry plus staged kernels for safe fallback.

---

## Subvolume Layout (v2)

On a v2 system the btrfs layout is:

```
btrfs top-level (subvolid=0)
├── @log                       # bind-mounted as /var/log
├── @pkg                       # bind-mounted as /var/cache/pacman/pkg
└── @snapshots
    ├── @                      # default subvolume; live root filesystem
    ├── @factory_reset         # factory reset image (from initial install)
    ├── @recovery_candidate    # optional; newer recovery image from recovery update
    ├── @ota_new               # transient; OTA candidate (removed after promotion or cleanup)
    └── @factory_reset_new    # transient; factory reset candidate (removed after promotion or cleanup)
```

- **Default subvolume** is always `@snapshots/@` on v2. Boot loader entries that do not specify `rootflags=subvol=...` use this default.
- **Transient subvolumes** (`@ota_new`, `@factory_reset_new`) exist only while an update or factory reset is in progress; they are either promoted to `@snapshots/@` or deleted during cleanup.

**V1 layout (legacy)** — On v1, the default subvolume was top-level `@`, and `@snapshots/` contained only `@factory_reset`, `@ota_new`, and `@factory_reset_new`. The rollback hook and install scripts detect v1 vs v2 via the marker file `var/lib/factory_reset/support_v2_root_snapshot` (present only in v2 images).

---

## Key Scripts and Components

| Component | Role |
|-----------|------|
| `feral-system-update.sh` | OTA: creates `@ota_new`, stages boot files, sets one-shot candidate boot, reboots |
| `factory_reset.sh` | Factory reset: chooses source (recovery candidate or factory_reset), creates `@factory_reset_new`, one-shot boot, reboots |
| `btrfs-subvolume-manager.sh` | Post-boot: promotes candidate to `@snapshots/@` or cleans orphans and failed recovery state |
| `feral-recovery-update.sh` | Background: downloads recovery image, installs as `@recovery_candidate` |
| `post-extraction.sh` | Shared chroot script: boot entries, mkinitcpio, pacman keys, cleanup (used by OTA and recovery update) |
| `btrfs-rollback` (initcpio) | Boot-time rollback when `rollback=factory` is in kernel cmdline; detects v1 vs v2 and targets the correct root subvolume |
| `support_v2_root_snapshot` | Marker file in the root fs indicating v2 layout; used by rollback and migration logic |

---

## OTA Update Flow

OTA is implemented in `feral-system-update.sh`. High-level sequence:

1. Mount btrfs top-level (subvolid=0).
2. Remove any existing `@snapshots/@ota_new`.
3. Create a writable snapshot: `@snapshots/@` → `@snapshots/@ota_new`.
4. Download the release ISO and verify its signature.
5. Mount the ISO and its SquashFS; rsync the filesystem into `@ota_new` (with standard exclusions).
6. **Stage boot files** into `@ota_new/var/lib/ota_boot_staging` (vmlinuz, initramfs, ucode, loader, EFI). The live `/boot` is not modified yet.
7. Bind-mount that staging directory as `/boot` inside `@ota_new` and run **`post-extraction.sh`** in chroot (boot entries, mkinitcpio, pacman keys, etc.).
8. Copy the staged kernel and initrd into **`/boot/candidate/`** on the live ESP, so the current known-good kernel remains at `/boot/` and the new one sits alongside.
9. Write **`/boot/loader/entries/arch-candidate.conf`** with `rootflags=subvol=@snapshots/@ota_new` (and candidate kernel paths).
10. Run **`bootctl set-oneshot arch-candidate.conf`** so the next boot uses the candidate entry once.
11. Reboot.

The btrfs default subvolume remains `@snapshots/@` throughout. Only after a successful boot from `@ota_new` does the subvolume manager promote it (see Post-boot promotion).

**V1 difference** — In v1, OTA wrote boot files directly to `/boot`, updated mkinitcpio in chroot, and set the btrfs default to `@ota_new` before rebooting. v2 defers writing to `/boot` until after a successful candidate boot and uses a one-shot entry so a bad update does not change the default.

---

## Post-Boot Promotion (Btrfs Subvolume Manager)

`btrfs-subvolume-manager.sh` runs early in boot. It decides what to do based on the **current root subvolume** (where the system booted from).

### Booted from a candidate (`@ota_new` or `@factory_reset_new`)

Promotion path:

1. **(OTA only)** Create `/etc/FF_OS_OTA_AUTO_TEST` for any post-update checks.
2. **Deploy staged boot files** from the snapshot (`var/lib/ota_boot_staging` or `var/lib/factory_reset_boot`) to the live `/boot` (rsync with delete).
3. Mount btrfs top-level.
4. Delete the existing `@snapshots/@` subvolume (old root).
5. **(Migration)** If an old top-level `@` exists (v1 remnant), delete it.
6. **Rename** the candidate into place: `mv @snapshots/@ota_new` (or `@factory_reset_new`) **→** `@snapshots/@`. This is a metadata-only rename; no data copy.
7. Set `@snapshots/@` as the default subvolume.
8. **(Factory reset only, when recovery candidate was used)** Promote `@recovery_candidate` to `@factory_reset` (rename) and remove the old `@factory_reset` if present.
9. Remove `/boot/loader/entries/arch-candidate.conf` and `/boot/candidate/`.
10. Exit; **no reboot**. The system is now running from the new `@snapshots/@` with the new kernel already in use.

**V1 difference** — In v1, promotion created a new `@` by snapshotting the candidate and then deleting the candidate; the default was switched to that new `@` and a reboot was required. v2 uses a single rename and deploys boot files in place, so no second reboot is needed.

### Booted from `@snapshots/@` (normal boot or fallback)

Cleanup path:

1. Mount btrfs top-level.
2. Delete any orphaned `@ota_new` or `@factory_reset_new` (e.g. after a failed or abandoned update).
3. If a recovery candidate was tried and failed (marker under `/var/lib/recovery_update/`): record the failed version, delete `@recovery_candidate`, clear the marker.
4. Remove `arch-candidate.conf` and `/boot/candidate/`.

This keeps the system in a consistent state after a failed candidate boot (one-shot expired, next boot used default `@snapshots/@`).

### Booted from any other subvolume

The script logs a warning and does nothing; manual intervention may be required.

---

## Factory Reset Flow

Factory reset is implemented in `factory_reset.sh`. Sequence:

1. Mount btrfs top-level.
2. Remove any existing `@snapshots/@factory_reset_new`.
3. **Choose source:** if `@snapshots/@recovery_candidate` exists, use it; otherwise use `@snapshots/@factory_reset`.
4. Create snapshot: source → `@snapshots/@factory_reset_new`.
5. If the source was `@recovery_candidate`, create marker files so post-boot logic can promote `@recovery_candidate` to `@factory_reset` and track failures (see Post-boot promotion and Recovery update).
6. Stage boot files from the source into **`/boot/candidate/`** (same pattern as OTA).
7. Write **`arch-candidate.conf`** with `rootflags=subvol=@snapshots/@factory_reset_new` and candidate kernel paths.
8. **`bootctl set-oneshot arch-candidate.conf`** and reboot.

If the factory reset candidate fails to boot, the next boot uses the default entry (`@snapshots/@`). The subvolume manager then cleans up the failed candidate and records the version so the recovery update service does not reuse it.

**V1 difference** — In v1, factory reset always used `@factory_reset`, wrote boot files directly to `/boot`, and set the btrfs default to `@factory_reset_new` before rebooting. v2 adds recovery candidate as a source and uses the same one-shot + staged boot pattern as OTA.

---

## Recovery Update Flow

The recovery update service (`feral-recovery-update.sh`) runs on a timer. It fetches a **recovery_version** (and optional **recovery_image_url**) from the same API used for OTA (e.g. version-info or latest endpoint) and, when appropriate, installs that image as `@snapshots/@recovery_candidate`. Factory reset then prefers this candidate over the original `@factory_reset`.

Rough sequence:

1. **Preconditions:** OTA updater not running (flock / service check), network up, API returns a recovery version and URL.
2. **Skip if:** recovery version equals the installed factory reset version, equals the installed recovery candidate version, or equals a previously failed version (stored under `/var/lib/recovery_update/`).
3. Mount btrfs top-level; remove any leftover `@recovery_candidate_old` or `@recovery_candidate_new`.
4. Snapshot `@factory_reset` → `@recovery_candidate_new`.
5. Download the recovery ISO and signature; verify signature.
6. Mount ISO and SquashFS; rsync into `@recovery_candidate_new`; extract and store boot files in the snapshot.
7. Bind-mount boot dir and run **`post-extraction.sh`** inside `@recovery_candidate_new`.
8. Write the recovery version into the snapshot (e.g. `var/lib/factory_reset/installed_version`).
9. **Atomic swap:** rename `@recovery_candidate` → `@recovery_candidate_old`, `@recovery_candidate_new` → `@recovery_candidate`, then delete `@recovery_candidate_old`.
10. Record the installed version in `/var/lib/recovery_update/installed_version`.

**Conflict avoidance** — The OTA updater stops the recovery update service before running. The recovery script also checks the OTA lock and skips if an OTA is in progress. Both use flock to prevent concurrent runs of the same script.

---

## Boot-Time Rollback (initcpio hook)

The `btrfs-rollback` initcpio hook runs when the kernel command line contains **`rollback=factory`** (typically from the factory reset boot menu entry). It restores the root filesystem from the factory reset snapshot and restores `/boot` from the snapshot’s backup.

Sequence:

1. Parse `rollback=` to determine the source snapshot (e.g. factory reset snapshot).
2. Mount the btrfs top-level at `/run/rollback`.
3. **Detect v1 vs v2:** look for `support_v2_root_snapshot` inside the source snapshot. If present, **target_root** is `@snapshots/@`; otherwise **target_root** is `@` (v1).
4. Delete the existing target_root subvolume.
5. Snapshot the source snapshot into target_root.
6. Set target_root as the default subvolume.
7. Restore `/boot` from the backup stored inside the target_root (e.g. `var/lib/factory_reset_boot`).
8. Unmount and continue boot.

This keeps v1 devices (root at `@`) and v2 devices (root at `@snapshots/@`) working with the same hook.

---

## Post-Extraction Script

`post-extraction.sh` is the shared script run inside a newly populated root (OTA snapshot or recovery candidate). It is invoked by `feral-system-update.sh` and `feral-recovery-update.sh` with the root device as an argument. It:

- Removes test/development files and the soaktest user
- Configures getty autologin and environment (e.g. "live")
- Writes `/boot/loader/loader.conf` and entries (`arch.conf`, `factory_reset.conf`) with the correct PARTUUID
- Configures mkinitcpio (including the btrfs-rollback hook) and runs `mkinitcpio -P`
- Initializes pacman keys and FeralFile package key; runs `pacman -Syy`
- Sets TPM udev rules and group membership
- Applies systemd presets

The caller is responsible for bind-mounting the correct boot or staging directory as `/boot` before chrooting.

---

## Boot Loader Layout (ESP)

Typical layout under the ESP mount (`/boot`):

- **loader/loader.conf** — default entry `arch.conf`, timeout 0.
- **loader/entries/arch.conf** — main entry; boots the default subvolume `@snapshots/@` (known-good root and kernel).
- **loader/entries/factory_reset.conf** — adds `rollback=factory` and boots the default subvolume so the initcpio hook can perform rollback.
- **loader/entries/arch-candidate.conf** — created by OTA or factory reset; points to the candidate subvolume and **/candidate/** kernel/initrd. Present only transiently; removed by the subvolume manager after promotion or cleanup.
- **vmlinuz-linux**, **initramfs-linux.img**, **intel-ucode.img** — current deployed (known-good) kernel.
- **candidate/** — directory created during OTA or factory reset; holds the new kernel/initrd until promotion or cleanup.

The one-shot mechanism uses `bootctl set-oneshot arch-candidate.conf`, so the next boot uses the candidate once; after that, the default entry is used again unless another one-shot is set.

---

## Safety Model

- The **btrfs default subvolume** is only changed **after** a successful boot from a candidate, when the subvolume manager renames the candidate to `@snapshots/@` and sets it as default.
- Until then, the default remains `@snapshots/@`. The candidate is booted only via the **one-shot** entry. If that boot fails (panic, hang, or failure before the manager runs), the next reboot uses the default entry and the known-good root; the subvolume manager then cleans up the orphaned candidate and any recovery failure state.

```
                    ┌──────────────┐
                    │  OTA / Reset │
                    │  prepares    │
                    │  candidate   │
                    └──────┬───────┘
                           │
                  bootctl set-oneshot
                           │
                    ┌──────▼───────┐
                    │   Reboot     │
                    └──────┬───────┘
                           │
              ┌────────────▼────────────┐
              │  Boot candidate (once)  │
              └────────────┬────────────┘
                           │
                 ┌─────────▼─────────┐
           ┌─YES─┤  Boot successful? ├─NO──┐
           │     └───────────────────┘     │
           │                               │
    ┌──────▼──────┐                 ┌──────▼──────┐
    │  Promote    │                 │  Next boot:  │
    │  candidate  │                 │  one-shot   │
    │  → @        │                 │  expired →   │
    └─────────────┘                 │  fallback to │
                                    │  @snapshots/@│
                                    └──────┬──────┘
                                           │
                                    ┌──────▼──────┐
                                    │  Cleanup    │
                                    │  orphans    │
                                    └─────────────┘
```
