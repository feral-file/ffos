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
# FF1_EVIDENCE_KEEP=0 turns the stash off: the interactive installer sets it
# when the operator says the device is going to someone else.
#
# Restoring after the snapshot is deliberate: @factory_reset never contains the
# old evidence, so the first factory reset still clears it. Wi-Fi profiles,
# identity, and keys are never copied (none of them live under these paths).

# Priority order. The netlog ring (capped at 8 MiB by netlog) comes first and
# on its own: a flapping device balloons controld.log and its rotated backups,
# and budgeting ~/.logs as one unit would drop the ring along with them. A
# later path that contains an earlier kept one copies and counts only the rest.
FF1_EVIDENCE_PATHS=(
  home/feralfile/.logs/netlog
  home/feralfile/.logs
  home/feralfile/.state/vmagent_queue
)
FF1_EVIDENCE_MAX_BYTES="${FF1_EVIDENCE_MAX_BYTES:-$((400 * 1024 * 1024))}"
# Lists the paths actually kept, one per line, so the restore never mistakes a
# parent directory the stash created for a kept path.
FF1_EVIDENCE_MANIFEST=.ff1-evidence-kept

ff1_evidence_log() {
  echo "[evidence] $*"
}

# ff1_evidence_size <dir>: apparent size in bytes, empty on failure.
ff1_evidence_size() {
  du -sb "$1" 2>/dev/null | awk '{print $1}' || true
}

# ff1_stash_evidence <old-root-dir> <stash-dir>: copy each evidence path that
# exists under old-root into stash, keeping its relative path.
ff1_stash_evidence() {
  local old_root="$1" stash="$2" rel size budget kept_rel kept_size rc
  local -a kept=() excludes=()
  budget="$FF1_EVIDENCE_MAX_BYTES"
  mkdir -p "$stash" || return 0
  for rel in "${FF1_EVIDENCE_PATHS[@]}"; do
    [[ -d "$old_root/$rel" ]] || continue
    size=$(ff1_evidence_size "$old_root/$rel")
    if [[ -z "$size" ]]; then
      ff1_evidence_log "cannot size /$rel; skipping it"
      continue
    fi
    excludes=()
    for kept_rel in ${kept[@]+"${kept[@]}"}; do
      [[ "$kept_rel" == "$rel"/* ]] || continue
      excludes+=("--exclude=/${kept_rel#"$rel"/}")
      kept_size=$(ff1_evidence_size "$old_root/$kept_rel")
      size=$((size - ${kept_size:-0}))
    done
    if (( size > budget )); then
      ff1_evidence_log "/$rel is $size bytes, over the remaining $budget; skipping it"
      continue
    fi
    # A partial copy (one unreadable file on a damaged filesystem) is kept:
    # some evidence beats none, and the stash tmpfs bounds it either way.
    rc=0
    mkdir -p "$stash/$rel" &&
      rsync -aAX --numeric-ids ${excludes[@]+"${excludes[@]}"} "$old_root/$rel/" "$stash/$rel/" || rc=$?
    budget=$((budget - size))
    kept+=("$rel")
    echo "$rel" >>"$stash/$FF1_EVIDENCE_MANIFEST" || true
    if (( rc == 0 )); then
      ff1_evidence_log "kept /$rel ($size bytes)"
    else
      ff1_evidence_log "kept /$rel only in part (copy exited $rc)"
    fi
  done
  return 0
}

# ff1_stash_evidence_from_disk <root-partition> <stash-dir>: mount the old
# install's root (its default subvolume, the one it booted) read-only, stash,
# unmount. A partition that is not btrfs is not an FF1 root and is ignored.
ff1_stash_evidence_from_disk() {
  local part="$1" stash="$2" mnt
  if [[ "${FF1_EVIDENCE_KEEP:-1}" == 0 ]]; then
    ff1_evidence_log "not keeping the previous install's logs, as asked"
    return 0
  fi
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

# ff1_evidence_mkdirs <root> <rel>: create root/rel's missing directories,
# each owned like its parent. A plain mkdir -p would leave, say, a missing
# ~/.logs root-owned when only ~/.logs/netlog was kept, and feralfile could
# no longer write its logs.
ff1_evidence_mkdirs() {
  local dir="$1" part owner
  local -a parts
  IFS=/ read -r -a parts <<<"$2"
  for part in "${parts[@]}"; do
    if [[ ! -d "$dir/$part" ]]; then
      mkdir "$dir/$part" || return 1
      owner=$(stat -c %u:%g "$dir" 2>/dev/null) && chown "$owner" "$dir/$part" 2>/dev/null || true
    fi
    dir="$dir/$part"
  done
}

# ff1_restore_evidence <stash-dir> <new-root>: copy everything stashed into
# the new root over whatever the image shipped at the same paths.
ff1_restore_evidence() {
  local stash="$1" new_root="$2" rel
  [[ -r "$stash/$FF1_EVIDENCE_MANIFEST" ]] || return 0
  while IFS= read -r rel; do
    [[ -n "$rel" && -d "$stash/$rel" ]] || continue
    if ff1_evidence_mkdirs "$new_root" "$rel" &&
      rsync -aAX --numeric-ids "$stash/$rel/" "$new_root/$rel/"; then
      ff1_evidence_log "restored /$rel"
    else
      ff1_evidence_log "restoring /$rel failed"
    fi
  done <"$stash/$FF1_EVIDENCE_MANIFEST"
  if mountpoint -q "$stash" 2>/dev/null; then
    umount "$stash" 2>/dev/null || true
  fi
  return 0
}
