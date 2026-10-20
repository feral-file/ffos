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
# The two knobs take their values from the environment only so that
# scripts/test-ota-control-state.sh can point them at a fake root; nothing on
# a device sets them.
FF1_CONTROL_STATE_DIR="${FF1_CONTROL_STATE_DIR:-/home/feralfile/.state/control}"
FF1_CONTROL_USER="${FF1_CONTROL_USER:-feralfile}"

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

# carry_control_state CANDIDATE_ROOT: freeze the live control state and make
# CANDIDATE_ROOT (the @ota_new subvolume) mirror it, path by path (see
# control_state_paths). Returns non-zero, after logging, on any failure; the
# caller must not arm the candidate then.
carry_control_state() {
  local candidate_root="$1"
  local path dest any_live=0 any_candidate=0
  local -a paths
  mapfile -t paths < <(control_state_paths)

  for path in "${paths[@]}"; do
    [[ -e "$path" || -L "$path" ]] && any_live=1
    [[ -e "$candidate_root$path" || -L "$candidate_root$path" ]] && any_candidate=1
  done
  if (( !any_live && !any_candidate )); then
    log_info "No control state to carry into the candidate"
    return 0
  fi

  if (( any_live )); then
    log_info "Stopping feral-controld to freeze control state..."
    # Set before the stop: a stop that half-succeeds still owes a restart.
    CONTROLD_RESTART_PENDING=1
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

  for path in "${paths[@]}"; do
    dest="$candidate_root$path"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
      # The candidate inherited whatever existed when the update began; a copy
      # of something gone now would resurrect it (a deleted grant store, or a
      # finished reset's tombstone).
      if [[ -e "$dest" || -L "$dest" ]]; then
        log_info "Removing stale $path from the update candidate (absent on the running system)"
        rm -rf -- "$dest" || {
          log_error "Failed to remove stale control state from the update candidate."
          return 1
        }
      fi
      continue
    fi
    log_info "Copying live $path into the update candidate..."
    # A directory replacing a file (or the reverse) is not something rsync
    # will do in place, so clear a mismatched candidate entry first.
    if [[ -d "$path" && ! -L "$path" ]]; then
      if [[ -e "$dest" || -L "$dest" ]] && [[ ! -d "$dest" || -L "$dest" ]]; then
        rm -f -- "$dest" || { log_error "Failed to copy control state into the update candidate."; return 1; }
      fi
      # .state already exists in the candidate (the start snapshot has it,
      # and post-extraction.sh creates it); mkdir -p only covers the
      # impossible case, and feral-kiosk-startup.service chowns
      # /home/feralfile at every boot.
      if ! mkdir -p "$dest" \
        || ! rsync -a --delete "$path"/ "$dest"/; then
        log_error "Failed to copy control state into the update candidate."
        return 1
      fi
    else
      if [[ -d "$dest" && ! -L "$dest" ]]; then
        rm -rf -- "$dest" || { log_error "Failed to copy control state into the update candidate."; return 1; }
      fi
      if ! mkdir -p "$(dirname "$dest")" \
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

# restore_controld_if_stopped: start feral-controld again if this script
# stopped it and still owes the restart. Safe to call more than once.
restore_controld_if_stopped() {
  [[ "${CONTROLD_RESTART_PENDING:-0}" == 1 ]] || return 0
  CONTROLD_RESTART_PENDING=0
  log_info "Update did not arm the candidate; restarting feral-controld"
  controld_systemctl start feral-controld.service \
    || log_error "Failed to restart feral-controld."
  return 0
}
