# New Snapshot System v2 — Flow Documentation


## Overview

This branch introduces three major changes to the FFOS update and recovery architecture:

1. **V2 root subvolume layout** — The root filesystem moves from `/@` to `/@snapshots/@`.
2. **One-shot candidate boot** — OTA and factory-reset no longer swap the btrfs default subvolume before reboot. Instead, a one-shot candidate boot entry is created with `bootctl set-oneshot`. The candidate gets a single attempt; if it fails, systemd-boot automatically falls back to the known-good `@snapshots/@` on the next boot.
3. **Recovery update service** — A new standalone timer/service that periodically downloads a server-specified recovery image and installs it as `@snapshots/@recovery_candidate`, which is used by factory reset if available.

---

## Changed Files

| File | Change |
|------|--------|
| `auto-install.sh` / `install-to-disk.sh` | Create root subvol at `@snapshots/@` instead of `@` |
| `feral-system-update.sh` | Snapshot from `@snapshots/@`, stage boot files, write candidate boot entry, use `bootctl set-oneshot` |
| `factory_reset.sh` | Prefer `@recovery_candidate` over `@factory_reset` as source; stage boot files + candidate entry |
| `btrfs-subvolume-manager.sh` | Unified case-based handler for candidate promotion and orphan cleanup |
| `btrfs-rollback` (initcpio hook) | Detect v2 layout via marker file; rollback targets `@snapshots/@` |
| `feral-recovery-update.sh` | **New** — downloads, verifies, and installs a recovery candidate snapshot |
| `feral-recovery-update.service/.timer` | **New** — systemd units for the recovery update service |
| `post-extraction.sh` | **New** — unified post-install configuration (boot entries, mkinitcpio, pacman, cleanup) |
| `support_v2_root_snapshot` | **New** — marker file that signals v2 layout support |
| `feral-updater.sh` | Stops recovery update service before starting OTA to avoid conflicts |
| `profiledef.sh` | Registers new scripts with correct permissions |
| `.github/workflows/*.yml` | Adds `update_recovery_version` field to `version-info.json` |

---

## Subvolume Layout

### V1 (old — `develop`)

```
btrfs top-level (subvolid=0)
├── @                          ← default subvol, root filesystem
├── @log                       ← /var/log
├── @pkg                       ← /var/cache/pacman/pkg
└── @snapshots
    ├── @factory_reset         ← factory reset snapshot
    ├── @ota_new               ← (transient) OTA candidate
    └── @factory_reset_new     ← (transient) factory reset candidate
```

### V2 (new — this branch)

```
btrfs top-level (subvolid=0)
├── @log                       ← /var/log
├── @pkg                       ← /var/cache/pacman/pkg
└── @snapshots
    ├── @                      ← default subvol, root filesystem
    ├── @factory_reset         ← factory reset snapshot (from initial install)
    ├── @recovery_candidate    ← (optional) newer recovery image
    ├── @ota_new               ← (transient) OTA candidate
    └── @factory_reset_new     ← (transient) factory reset candidate
```

Key change: root `@` now lives inside `@snapshots/`, simplifying snapshot management and atomic rename operations.

---

## Flow 1: OTA Update (`feral-system-update.sh`)

```
┌─────────────────────────────────────────────────────────────────┐
│                        OTA Update Flow                          │
└─────────────────────────────────────────────────────────────────┘

1. Mount btrfs top-level
2. Delete old @snapshots/@ota_new if it exists
3. Snapshot @snapshots/@ → @snapshots/@ota_new           ← was: @ → @ota_new
4. Download ISO, verify signature
5. Mount ISO → SquashFS
6. Rsync filesystem into @ota_new
7. Stage boot files to @ota_new/var/lib/ota_boot_staging ← NEW: no longer writes to /boot
8. Run post-extraction.sh inside @ota_new (chroot)       ← NEW: unified script
9. Copy staged kernel to /boot/candidate/                ← NEW: side-by-side with current
10. Write /boot/loader/entries/arch-candidate.conf        ← NEW: candidate boot entry
11. bootctl set-oneshot arch-candidate.conf               ← NEW: single-attempt one-shot boot
12. Reboot

 ┌──────────────────────────────────┐
 │   BTRFS DEFAULT NEVER CHANGES    │
 │   during OTA — stays @snapshots/@│
 └──────────────────────────────────┘
```

### What changed from V1

- **No btrfs default swap before reboot** — the candidate is booted via `bootctl set-oneshot` (single attempt)
- **Boot files staged inside snapshot** — not written to live `/boot` until post-promotion
- **`post-extraction.sh`** replaces inline chroot blocks (mkinitcpio, pacman keys, boot entries, cleanup)
- **Candidate kernel at `/boot/candidate/`** — current kernel stays at `/boot/` as automatic fallback if the one-shot fails

---

## Flow 2: Post-Boot Promotion (`btrfs-subvolume-manager.sh`)

```
┌─────────────────────────────────────────────────────────────────┐
│               Btrfs Subvolume Manager (boot service)            │
└─────────────────────────────────────────────────────────────────┘

CASE: Booted from @snapshots/@ota_new OR @snapshots/@factory_reset_new
  ─────────────────────────────────────────────────────────────────
  1. (OTA only) touch /etc/FF_OS_OTA_AUTO_TEST
  2. Deploy staged boot files from snapshot to /boot (rsync --delete)
  3. Mount btrfs top-level
  4. Delete old @snapshots/@ subvolume
  5. (Migration) Delete old top-level @ if present
  6. mv @snapshots/@ota_new → @snapshots/@              ← atomic rename, no snapshot copy
  7. Set @snapshots/@ as default subvolume
  8. (Factory reset + recovery candidate) Promote @recovery_candidate → @factory_reset
  9. Clean up arch-candidate.conf from /boot
  10. Done — no reboot needed                            ← was: reboot required

CASE: Booted from @snapshots/@ (normal boot or fallback)
  ─────────────────────────────────────────────────────────────────
  1. Mount btrfs top-level
  2. Delete orphaned @ota_new / @factory_reset_new if found
  3. If recovery candidate boot failed (marker file present):
     a. Record failed version
     b. Delete failed @recovery_candidate
     c. Clean marker
  4. Remove /boot/loader/entries/arch-candidate.conf
  5. Remove /boot/candidate/

CASE: Unexpected subvolume
  ─────────────────────────────────────────────────────────────────
  → Log warning, manual intervention required
```

### What changed from V1

- **Unified handler** — single `case` statement replaces separate if/elif blocks for OTA and factory reset
- **`mv` instead of snapshot+delete** — candidate is atomically renamed to `@snapshots/@` (faster, no data copy)
- **No reboot after promotion** — boot files are deployed, default is set, system continues running
- **Fallback cleanup** — if the one-shot candidate failed and the system fell back to `@snapshots/@`, orphaned candidates and failed recovery markers are cleaned up

---

## Flow 3: Factory Reset (`factory_reset.sh`)

```
┌─────────────────────────────────────────────────────────────────┐
│                      Factory Reset Flow                         │
└─────────────────────────────────────────────────────────────────┘

1. Mount btrfs top-level
2. Delete old @factory_reset_new if it exists
3. Pick source:                                           ← NEW: recovery candidate preferred
   - @snapshots/@recovery_candidate (if exists) → use it
   - @snapshots/@factory_reset       (fallback) → use it
4. Snapshot source → @snapshots/@factory_reset_new
5. (If recovery candidate used) Leave breadcrumb:
   - candidate_used marker in @factory_reset_new/var/lib/recovery_update/
   - attempted marker in /var/lib/recovery_update/
6. Stage boot files to /boot/candidate/                   ← NEW: side-by-side staging
7. Write /boot/loader/entries/arch-candidate.conf
8. bootctl set-oneshot arch-candidate.conf                ← NEW: single-attempt one-shot
9. Reboot

 ┌────────────────────────────────────────────────┐
 │  If recovery candidate was used and boot fails │
 │  → fallback to @snapshots/@                    │
 │  → btrfs-subvolume-manager marks version failed│
 │  → recovery update skips that version next time│
 └────────────────────────────────────────────────┘
```

### What changed from V1

- **Recovery candidate as preferred source** — factory reset uses the latest recovery image if available
- **One-shot boot** — same mechanism as OTA; if the single attempt fails, system falls back automatically
- **Breadcrumb trail** — `candidate_used` and `attempted` markers allow post-boot promotion of recovery candidate to `@factory_reset` and failed version tracking

---

## Flow 4: Recovery Update (`feral-recovery-update.sh`) — NEW

```
┌─────────────────────────────────────────────────────────────────┐
│                    Recovery Update Flow                          │
│           (timer-driven, runs periodically in background)       │
└─────────────────────────────────────────────────────────────────┘

Preconditions:
  - OTA updater not running (checks feral-updater.lock)
  - Network available
  - Server provides recovery_version in version-info.json
  - Version not already installed, not previously failed

1. Check server API for recovery_version
2. Skip if:
   - Same as installed factory reset version
   - Same as installed recovery candidate version
   - Same as previously failed version
3. Mount btrfs top-level
4. Clean up leftover @recovery_candidate_old / @recovery_candidate_new
5. Snapshot @factory_reset → @recovery_candidate_new
6. Download recovery ISO, verify signature
7. Mount ISO → SquashFS
8. Rsync filesystem into @recovery_candidate_new
9. Extract boot files, backup into snapshot
10. Run post-extraction.sh inside @recovery_candidate_new (chroot)
11. Atomic swap:
    a. mv @recovery_candidate → @recovery_candidate_old
    b. mv @recovery_candidate_new → @recovery_candidate
    c. Delete @recovery_candidate_old
12. Record installed version at /var/lib/recovery_update/installed_version
13. Done — candidate used on next factory reset
```

### Conflict avoidance

- `feral-updater.sh` stops recovery update service before starting OTA
- `feral-recovery-update.sh` checks OTA lock before starting
- Both use `flock` for self-exclusion

---

## Flow 5: Initcpio Rollback Hook (`btrfs-rollback`)

```
┌─────────────────────────────────────────────────────────────────┐
│              Boot-time Rollback (initcpio hook)                  │
│         Triggered by: rollback=factory kernel param             │
└─────────────────────────────────────────────────────────────────┘

1. Read rollback= kernel parameter → find source snapshot
2. Mount btrfs top-level at /run/rollback
3. Detect v2 layout:                                      ← NEW
   - Check for support_v2_root_snapshot marker in source snapshot
   - If v2: target_root = "@snapshots/@"
   - If v1: target_root = "@"                             ← backward compatible
4. Delete old target_root subvolume
5. Snapshot source → target_root
6. Set target_root as default subvolume
7. Recover /boot from backup inside target_root
8. Unmount and continue boot
```

### What changed from V1

- **V2 detection** via `support_v2_root_snapshot` marker file
- **Dynamic target** — rollback targets `@snapshots/@` on v2 or `@` on v1
- Backward compatible with devices still on v1 layout

---

## Flow 6: Post-Extraction Script (`post-extraction.sh`) — NEW

```
┌─────────────────────────────────────────────────────────────────┐
│          Unified Post-Extraction Configuration                   │
│      Called by: OTA update, Recovery update (via chroot)         │
└─────────────────────────────────────────────────────────────────┘

1. Clean up test files (automated_script, bash_profile, soaktest user, websocat)
2. Configure autologin for feralfile user
3. Set environment to "live"
4. Write boot entries (arch.conf, factory_reset.conf) with correct PARTUUID
5. Configure mkinitcpio hooks (including btrfs-rollback)
6. Generate initramfs (mkinitcpio -P)
7. Initialize pacman keys + FeralFile signing key
8. Sync package databases
9. Configure TPM access (tss group, udev rules)
10. Apply systemd presets
```

This script replaces the inline chroot blocks that were previously duplicated across `feral-system-update.sh` and `auto-install.sh`.

---

## CI/CD Changes

Both `build-image-to-cf.yml` and `pure-build-image-to-cf.yml` gain:

- New input: `update_recovery_version` (boolean)
- New field in `version-info.json`: `recovery_version`
- Logic to preserve/update the recovery version field across builds

This allows the server API to advertise a `recovery_version`, which `feral-recovery-update.sh` fetches to decide when to update the recovery candidate.

---

## Boot Entry Layout (ESP)

```
/boot/
├── loader/
│   ├── loader.conf                    (default: arch.conf)
│   └── entries/
│       ├── arch.conf                  → boots @snapshots/@ (always present, known-good fallback)
│       ├── factory_reset.conf         → triggers rollback hook
│       └── arch-candidate.conf        → one-shot candidate entry (transient, created by OTA/reset)
├── vmlinuz-linux                      ← current known-good kernel
├── initramfs-linux.img
├── intel-ucode.img
└── candidate/                         ← transient, created during OTA/reset
    ├── vmlinuz-linux
    ├── initramfs-linux.img
    └── intel-ucode.img
```

---

## Safety Model

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
    │  Promote    │                 │  Next boot: │
    │  candidate  │                 │  one-shot   │
    │  → @        │                 │  expired →  │
    └─────────────┘                 │  fallback   │
                                    │  to @       │
                                    └──────┬──────┘
                                           │
                                    ┌──────▼──────┐
                                    │  Cleanup    │
                                    │  orphans    │
                                    └─────────────┘
```

The btrfs default subvolume **never changes** until after the candidate has proven it can boot successfully. Since `bootctl set-oneshot` is used, the candidate entry is consumed on the first boot attempt. If the candidate fails to start the subvolume manager (crash, hang, kernel panic), the next reboot automatically loads the default `arch.conf` entry, which boots the known-good `@snapshots/@`.
