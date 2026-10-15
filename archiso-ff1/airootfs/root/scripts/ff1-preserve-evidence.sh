#!/bin/bash
# Carries the previous install's diagnostic evidence across a re-flash
# (ffos-user#404). Sourced by install-to-disk.sh and auto-install.sh.
#
# A re-flash is the support path for a device that will not come back online,
# and before this it erased the only record of why: the netlog ring and the
# component logs (~/.logs) and the vmagent spool (~/.state/vmagent_queue),
# which holds the metrics the device could not ship while it was offline.
#
#   ff1_stash_evidence_from_disk <root-partition> <stash-dir>
#       before wipefs: mount the old root read-only and copy the evidence out
#   ff1_restore_evidence <stash-dir> <new-root>
#       after the factory-reset snapshot is taken: copy it into the new root
#
# Both are best-effort and always return 0, even under the callers' set -e: a
# missing, foreign, or damaged old root must never stop an install. The stash
# lives in RAM (the live ISO has nothing else), so it is bounded by
# FF1_EVIDENCE_MAX_BYTES; paths are taken in priority order and one that does
# not fit the remaining budget is skipped.
#
# Restoring after the snapshot is deliberate: @factory_reset never contains the
# old evidence, so the first factory reset still clears it. Wi-Fi profiles,
# identity, and keys are never copied (none of them live under these paths).

FF1_EVIDENCE_PATHS=(
  home/feralfile/.logs
  home/feralfile/.state/vmagent_queue
)
FF1_EVIDENCE_MAX_BYTES="${FF1_EVIDENCE_MAX_BYTES:-$((400 * 1024 * 1024))}"

ff1_evidence_log() {
  echo "[evidence] $*"
}

# ff1_stash_evidence <old-root-dir> <stash-dir>: copy each evidence path that
# exists under old-root into stash, keeping its relative path.
ff1_stash_evidence() {
  local old_root="$1" stash="$2" rel size budget
  budget="$FF1_EVIDENCE_MAX_BYTES"
  mkdir -p "$stash" || return 0
  for rel in "${FF1_EVIDENCE_PATHS[@]}"; do
    [[ -d "$old_root/$rel" ]] || continue
    size=$(du -sb "$old_root/$rel" 2>/dev/null | awk '{print $1}') || size=""
    if [[ -z "$size" ]]; then
      ff1_evidence_log "cannot size /$rel; skipping it"
      continue
    fi
    if (( size > budget )); then
      ff1_evidence_log "/$rel is $size bytes, over the remaining $budget; skipping it"
      continue
    fi
    if mkdir -p "$stash/$(dirname "$rel")" &&
      rsync -aAX --numeric-ids "$old_root/$rel" "$stash/$(dirname "$rel")/"; then
      budget=$((budget - size))
      ff1_evidence_log "kept /$rel ($size bytes)"
    else
      rm -rf "${stash:?}/$rel" || true
      ff1_evidence_log "copying /$rel failed; skipping it"
    fi
  done
  return 0
}

# ff1_stash_evidence_from_disk <root-partition> <stash-dir>: mount the old
# install's root (its default subvolume, the one it booted) read-only, stash,
# unmount. A partition that is not btrfs is not an FF1 root and is ignored.
ff1_stash_evidence_from_disk() {
  local part="$1" stash="$2" mnt
  [[ -b "$part" ]] || return 0
  [[ "$(blkid -s TYPE -o value "$part" 2>/dev/null)" == btrfs ]] || return 0
  mnt=$(mktemp -d /run/ff1-old-root.XXXXXX) || return 0
  if ! mount -o ro "$part" "$mnt" 2>/dev/null; then
    ff1_evidence_log "the previous install's root did not mount; nothing kept"
    rmdir "$mnt" || true
    return 0
  fi
  # Its own RAM filesystem, so a large stash cannot fill /run for the rest
  # of the install.
  mkdir -p "$stash" || { umount "$mnt" || true; return 0; }
  mount -t tmpfs -o "size=$((FF1_EVIDENCE_MAX_BYTES + 16 * 1024 * 1024)),mode=0700" ff1-evidence "$stash" 2>/dev/null ||
    ff1_evidence_log "no tmpfs for the stash; using $stash as is"
  ff1_stash_evidence "$mnt" "$stash"
  umount "$mnt" 2>/dev/null || umount -l "$mnt" || true
  rmdir "$mnt" 2>/dev/null || true
  return 0
}

# ff1_restore_evidence <stash-dir> <new-root>: copy everything stashed into
# the new root over whatever the image shipped at the same paths.
ff1_restore_evidence() {
  local stash="$1" new_root="$2" rel
  [[ -d "$stash" ]] || return 0
  for rel in "${FF1_EVIDENCE_PATHS[@]}"; do
    [[ -d "$stash/$rel" ]] || continue
    if mkdir -p "$new_root/$(dirname "$rel")" &&
      rsync -aAX --numeric-ids "$stash/$rel" "$new_root/$(dirname "$rel")/"; then
      ff1_evidence_log "restored /$rel"
    else
      ff1_evidence_log "restoring /$rel failed"
    fi
  done
  if mountpoint -q "$stash" 2>/dev/null; then
    umount "$stash" 2>/dev/null || true
  fi
  return 0
}
