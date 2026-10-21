#!/bin/bash
# Carries feral-controld's controller-auth state live into the OTA candidate
# (feral-file#3551, fact F9). Sourced by feral-system-update.sh after it
# defines log_info and log_error; it defines functions and nothing runs on
# source.
#
# Why: feral-system-update.sh snapshots the running root into @ota_new BEFORE
# the download, and its rsync then excludes /home/feralfile/.state, so the
# candidate's .state is the copy taken when the OTA began. For most of .state
# that is fine. For /home/feralfile/.state/control (controller grants and
# replay counters, ffos-user docs/ff1-control-v1.md section 8) it is not: a
# revocation made during the download would be undone on promotion (the
# revoked controller comes back), and a replay counter advanced during it
# would roll back (an accepted request becomes replayable).
#
# So, right before the candidate is armed: stop feral-controld (the only
# writer) so nothing can change again, then make the candidate mirror the
# live system for control/, control.new/ and the reset tombstone
# control.retired (see control_state_paths): carried when live, removed from
# the candidate when not. The stop is what serializes the copy;
# /run/feral-updater.lock (held by feral-updater.sh) cannot, because controld
# runs as feralfile and never takes it.
#
# Failure direction: if the script stops controld and then exits without
# arming the candidate, restore_controld_if_stopped (called from the EXIT
# path) starts it again, so an aborted update never leaves the device without
# its control daemon. Once the candidate is armed the caller clears
# CONTROLD_RESTART_PENDING: from then on a restarted controld could accept
# writes that the next boot (into the candidate) would drop, which is the bug
# this file exists to close.
#
# Old firmware and devices that never created control state have none of
# the three paths: nothing is stopped and nothing is copied. controld is
# stopped only if at least one of them exists live.
#
# Cross-repo contract with feral-watchdog (ffos-user): while this script has
# controld stopped it holds the marker FF1_CONTROLD_OTA_STOP_MARKER
# (/run/feral-controld-ota-stop, root-owned, 0644, empty). The watchdog
# suppresses its "controld inactive" report only while that marker exists AND
# /run/feral-updater.lock is held. The marker is created immediately before
# the stop, removed by restore_controld_if_stopped once controld is started
# again, and never removed after arming: the reboot clears /run. Keep the
# path in step with the watchdog.
#
# The knobs take their values from the environment only so that
# scripts/test-ota-control-state.sh can point them at a fake root; nothing on
# a device sets them.
FF1_CONTROL_STATE_DIR="${FF1_CONTROL_STATE_DIR:-/home/feralfile/.state/control}"
FF1_CONTROL_USER="${FF1_CONTROL_USER:-feralfile}"
FF1_CONTROLD_OTA_STOP_MARKER="${FF1_CONTROLD_OTA_STOP_MARKER:-/run/feral-controld-ota-stop}"
# Where this helper lives in an image; its absence in a candidate marks an
# image that predates the carry (see refuse_update_without_carry).
FF1_CONTROL_CARRY_SCRIPT=/root/scripts/ota-control-state.sh

# 1 while this script has stopped feral-controld and owes it a restart.
CONTROLD_RESTART_PENDING=0

# controld_systemctl ARGS...: systemctl --user against feralfile's user
# manager (user@1000), with the same runtime dir and bus the user units and
# feral-kiosk-startup.service use.
controld_systemctl() {
  runuser -u "$FF1_CONTROL_USER" -- env \
    XDG_RUNTIME_DIR=/run/user/1000 \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
    systemctl --user "$@"
}

# control_state_paths: the live paths that make up controld's control state,
# one per line. All three are mirrored, present or absent:
#   control/          identity and grants (docs/ff1-control-v1.md section 8);
#   control.new/      a brand-new identity mid-creation (atomic rename into
#                     control/), part of the state while it exists;
#   control.retired   the factory-reset tombstone: written durably BEFORE
#                     control/ is deleted, and while it exists controld forces
#                     a locked policy. A completed reset boots a root without
#                     it. Carrying it keeps an interrupted reset locked after
#                     the update; dropping it would let the candidate come up
#                     with control/ gone and no lock, i.e. as a fresh device.
control_state_paths() {
  printf '%s\n' "$FF1_CONTROL_STATE_DIR" "$FF1_CONTROL_STATE_DIR.new" "$FF1_CONTROL_STATE_DIR.retired"
}

# control_path_state PATH [WHAT]: print "present" or "absent" for PATH,
# without following a final symlink. Only ENOENT counts as absent: any other
# stat failure (EIO, EACCES, ENOTDIR, ...) is logged and returns 1, because
# treating an unreadable grant store or tombstone as "gone" would delete the
# candidate's copy and boot the update unlocked. WHAT names the path in that
# log line (default "control state path"); otagate classifies neither
# wording, so both are permanent.
control_path_state() {
  local err
  if err=$(LC_ALL=C stat -- "$1" 2>&1 >/dev/null); then
    echo present
    return 0
  fi
  case "$err" in
    *"No such file or directory"*) echo absent; return 0 ;;
  esac
  # To stderr: callers capture stdout. The updater units append both
  # streams to the same log.
  log_error "Cannot stat ${2:-control state path} $1: $err" >&2
  return 1
}

# control_state_any_live: 0 if any live control-state path exists, 1 if
# none does, 2 (after logging) if one cannot be classified.
control_state_any_live() {
  local path st any=1
  while IFS= read -r path; do
    st=$(control_path_state "$path") || return 2
    [[ "$st" == present ]] && any=0
  done < <(control_state_paths)
  return "$any"
}

# controld_version [DBPATH]: the feral-controld version (pkgver-pkgrel)
# recorded in the pacman database at DBPATH (default: the running system's),
# or nothing if it is not installed there or the database cannot be read.
controld_version() {
  if [[ -n "${1:-}" ]]; then
    pacman --dbpath "$1" -Q feral-controld 2>/dev/null | awk '{print $2}' || true
  else
    pacman -Q feral-controld 2>/dev/null | awk '{print $2}' || true
  fi
}

# controld_would_downgrade VERSION: 0 if VERSION is older than the installed
# feral-controld, 1 otherwise (also when nothing is installed to compare).
# An older controld ignores .state/control, so on a device holding control
# state it reopens the device; neither the package rail nor an OTA may
# install one there.
controld_would_downgrade() {
  local installed
  installed=$(controld_version)
  [[ -n "$1" && -n "$installed" ]] || return 1
  (( $(vercmp "$1" "$installed") < 0 ))
}

# refuse_update_without_carry CANDIDATE_ROOT: 0 if the update may proceed,
# 1 (after logging) if it must be refused. Whenever live control state
# exists the candidate image must:
#   - contain this helper: an image without it (a downgrade to a pre-#3551
#     release) runs the OLD feral-system-update.sh on its next OTA, which
#     drops control state written during that OTA;
#   - ship a feral-controld no older than the installed one: an older
#     controld may predate the protocol and ignore .state/control, which
#     reopens the device (and resurrects its grants on a later upgrade). An
#     image whose controld version cannot be read is refused too.
# Called with the mounted image's SquashFS root, before it is rsynced into
# the candidate (a refusal then skips the rsync) and BEFORE
# carry_control_state, so controld has not been stopped and no restart is
# owed.
#
# Wording is load-bearing: feral-controld's otagate/classify.go (ffos-user)
# matches the prefix "Refusing update: target image cannot carry controller
# state" and treats it as permanent. No double quotes in it: the runner's
# message= regex stops at one.
refuse_update_without_carry() {
  local candidate_root="$1" st target rc=0
  local refusal="Refusing update: target image cannot carry controller state"
  st=$(control_path_state "$candidate_root$FF1_CONTROL_CARRY_SCRIPT" "target image path") || return 1
  control_state_any_live || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) ;;
    *) return 1 ;;
  esac
  if [[ "$st" != present ]]; then
    log_error "$refusal (no $FF1_CONTROL_CARRY_SCRIPT); a downgrade below secure-control support would lose or resurrect controller grants."
    return 1
  fi
  target=$(controld_version "$candidate_root/var/lib/pacman")
  if [[ -z "$target" ]]; then
    log_error "$refusal (its feral-controld version cannot be read)."
    return 1
  fi
  if controld_would_downgrade "$target"; then
    log_error "$refusal (its feral-controld $target is older than the installed $(controld_version)); an older controld would reopen this device."
    return 1
  fi
  return 0
}

# check_controld_stoppable: 0 if carry_control_state will be able to stop
# feral-controld (or there is no live state, so it will not need to), 1 after
# logging otherwise. Run before the download: carry_control_state hits the
# same condition only after the full download and rsync, and otagate retries
# that message (transient) by re-running this whole script. Mirrors the
# carry's stop handling: an unreachable user manager matters only while a
# feral-controld process still runs.
#
# Wording: the message keeps the "Could not stop feral-controld" prefix that
# otagate/classify.go matches. No double quotes in it.
check_controld_stoppable() {
  local rc=0
  control_state_any_live || rc=$?
  case "$rc" in
    1) return 0 ;;
    0) ;;
    *) return 1 ;;
  esac
  controld_systemctl show -p ActiveState feral-controld.service >/dev/null && return 0
  if pgrep -u "$FF1_CONTROL_USER" -x feral-controld >/dev/null; then
    log_error "Could not stop feral-controld: its user manager is unreachable while it runs; not downloading an update that could not be armed."
    return 1
  fi
  return 0
}

# carry_control_state CANDIDATE_ROOT: freeze the live control state and make
# CANDIDATE_ROOT (the @ota_new subvolume) mirror it, path by path (see
# control_state_paths). Returns non-zero, after logging, on any failure; the
# caller must not arm the candidate then (the EXIT path then restores
# controld if it was stopped).
carry_control_state() {
  local candidate_root="$1"
  local path dest st dst any_live=0 any_candidate=0
  local -a paths
  mapfile -t paths < <(control_state_paths)

  for path in "${paths[@]}"; do
    st=$(control_path_state "$path") || return 1
    [[ "$st" == present ]] && any_live=1
    st=$(control_path_state "$candidate_root$path") || return 1
    [[ "$st" == present ]] && any_candidate=1
  done
  if (( !any_live && !any_candidate )); then
    log_info "No control state to carry into the candidate"
    return 0
  fi

  # Live side: the source must be the real .state, not a symlink feralfile
  # pointed elsewhere (root would otherwise copy whatever it names into the
  # candidate). Checked before the stop, so a refusal here owes no restart.
  local live_parent live_real
  live_parent=$(dirname -- "$FF1_CONTROL_STATE_DIR")
  if (( any_live )); then
    if ! live_real=$(realpath -e -- "$live_parent") || [[ "$live_real" != "$live_parent" ]]; then
      log_error "Live control state parent $live_parent does not resolve to itself; refusing to carry control state."
      return 1
    fi
  fi

  if (( any_live )); then
    log_info "Stopping feral-controld to freeze control state..."
    # Set before the stop: a stop that half-succeeds still owes a restart.
    CONTROLD_RESTART_PENDING=1
    set_controld_stop_marker
    if ! controld_systemctl stop feral-controld.service; then
      # The user manager can be unreachable while controld is already gone
      # (e.g. it crashed); only a still-running writer makes the copy unsafe.
      if pgrep -u "$FF1_CONTROL_USER" -x feral-controld >/dev/null; then
        log_error "Could not stop feral-controld; refusing to arm the update with control state that may still change."
        return 1
      fi
      log_info "feral-controld stop reported failure but no feral-controld process is running; continuing"
    fi
  fi

  # Candidate side: every write and rm below lands under the candidate's
  # .state, which feralfile owns, so a symlink in it (planted, or left by a
  # bug) would aim root's rm -rf / rsync elsewhere. Resolve the parent once
  # and refuse unless it stays inside the candidate root. realpath -m
  # resolves the components that exist, so a symlinked ancestor of a missing
  # .state is caught too. Entries themselves: a stale entry is removed with
  # rm (which never follows a link), the tombstone is always removed before
  # it is copied, and a directory entry is removed first when it is a
  # symlink or not a directory; a real directory is updated in place by
  # rsync --delete, which does not follow symlinks inside it.
  local root_real state_real
  if ! root_real=$(realpath -m -- "$candidate_root") \
    || ! state_real=$(realpath -m -- "$candidate_root$live_parent"); then
    log_error "Could not resolve the update candidate .state directory."
    return 1
  fi
  if [[ "$state_real" != "$root_real"/* ]]; then
    log_error "Update candidate .state resolves outside the candidate root; refusing to write control state."
    return 1
  fi

  for path in "${paths[@]}"; do
    dest="$candidate_root$path"
    st=$(control_path_state "$path") || return 1
    if [[ "$st" == absent ]]; then
      # The candidate inherited whatever existed when the update began; a copy
      # of something gone now would resurrect it (a deleted grant store, or a
      # finished reset's tombstone).
      dst=$(control_path_state "$dest") || return 1
      if [[ "$dst" == present ]]; then
        log_info "Removing stale $path from the update candidate (absent on the running system)"
        rm -rf -- "$dest" || {
          log_error "Failed to remove stale control state from the update candidate."
          return 1
        }
      fi
      continue
    fi
    # Re-checked right before the copy: controld never creates symlinks
    # here, so one is tampering, and rsync would carry or follow it.
    if [[ -L "$path" ]]; then
      log_error "Live control state $path is a symlink; refusing to carry it."
      return 1
    fi
    log_info "Copying live $path into the update candidate..."
    if [[ -d "$path" ]]; then
      if [[ -e "$dest" || -L "$dest" ]] && [[ ! -d "$dest" || -L "$dest" ]]; then
        rm -f -- "$dest" || { log_error "Failed to copy control state into the update candidate."; return 1; }
      fi
      # --checksum, not rsync's size+mtime quick check: grants.json is
      # rewritten at the same size on every request, with 1 s mtime
      # resolution, so a write in the same second as the start snapshot
      # would otherwise be skipped and the candidate keep the stale counter.
      #
      # .state already exists in the candidate (the start snapshot has it,
      # and post-extraction.sh creates it); mkdir -p only covers the
      # impossible case, and feral-kiosk-startup.service chowns
      # /home/feralfile at every boot.
      if [[ -L "$path" ]] || ! mkdir -p "$dest" \
        || ! rsync -a --checksum --delete "$path"/ "$dest"/; then
        log_error "Failed to copy control state into the update candidate."
        return 1
      fi
    else
      # Removed first, so the copy is always fresh (no quick check to fool)
      # and never lands through a symlink.
      rm -rf -- "$dest" || { log_error "Failed to copy control state into the update candidate."; return 1; }
      if [[ -L "$path" ]] || ! mkdir -p "$(dirname "$dest")" \
        || ! rsync -a "$path" "$dest"; then
        log_error "Failed to copy control state into the update candidate."
        return 1
      fi
    fi
  done
  sync
  log_info "Control state carried into the update candidate."
  return 0
}

# set_controld_stop_marker: create the watchdog marker atomically (temp file
# in the same directory, then rename), empty and 0644. Best-effort: without
# it the watchdog reports controld inactive during the stop window, which is
# noise, not a reason to fail the update.
set_controld_stop_marker() {
  local tmp
  if tmp=$(mktemp "$FF1_CONTROLD_OTA_STOP_MARKER.XXXXXX") \
    && chmod 0644 "$tmp" \
    && mv -f -- "$tmp" "$FF1_CONTROLD_OTA_STOP_MARKER"; then
    return 0
  fi
  [[ -n "${tmp:-}" ]] && rm -f -- "$tmp"
  # log_info, not log_error: otagate (ffos-user) fails the run on the first
  # [ERROR] line, and this one does not stop the update.
  log_info "Warning: failed to create $FF1_CONTROLD_OTA_STOP_MARKER; feral-watchdog may report controld inactive during the update."
  return 0
}

# restore_controld_if_stopped: start feral-controld again if this script
# stopped it and still owes the restart. Safe to call more than once.
restore_controld_if_stopped() {
  [[ "${CONTROLD_RESTART_PENDING:-0}" == 1 ]] || return 0
  CONTROLD_RESTART_PENDING=0
  log_info "Update did not arm the candidate; restarting feral-controld"
  # --no-block, as ffos-user's .start-services.sh does: controld is
  # Type=notify and can fail before READY; this exit path must not hang on it.
  if controld_systemctl start --no-block feral-controld.service; then
    rm -f -- "$FF1_CONTROLD_OTA_STOP_MARKER"
  else
    # controld really is down now: drop the marker too, so the watchdog
    # reports it instead of suppressing a genuine failure.
    log_error "Failed to restart feral-controld."
    rm -f -- "$FF1_CONTROLD_OTA_STOP_MARKER"
  fi
  return 0
}
