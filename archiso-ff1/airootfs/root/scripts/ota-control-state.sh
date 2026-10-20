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
# writer) so the directory cannot change again, then mirror the live
# directory over the candidate's copy. The stop is what serializes the copy;
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
# Old firmware and devices that never created control state have no
# directory: nothing is stopped and nothing is copied.
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

# carry_control_state CANDIDATE_ROOT: freeze and copy the live control state
# into CANDIDATE_ROOT (the @ota_new subvolume). Returns non-zero, after
# logging, on any failure; the caller must not arm the candidate then.
carry_control_state() {
  local candidate_root="$1"
  local dest="$candidate_root$FF1_CONTROL_STATE_DIR"

  if [[ ! -d "$FF1_CONTROL_STATE_DIR" ]]; then
    # The candidate inherited whatever existed when the update began. If the
    # directory is gone now (deleted during the download), a copy left in the
    # candidate would resurrect it, so mirror the absence too.
    if [[ -e "$dest" ]]; then
      log_info "Control state absent on the running system; removing the stale copy from the candidate"
      rm -rf -- "$dest" || {
        log_error "Failed to remove stale control state from the update candidate."
        return 1
      }
      sync
    else
      log_info "No control state to carry into the candidate"
    fi
    return 0
  fi

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

  log_info "Copying live control state into the update candidate..."
  # .state already exists in the candidate (the start snapshot has it, and
  # post-extraction.sh creates it); mkdir -p only covers the impossible case,
  # and feral-kiosk-startup.service chowns /home/feralfile at every boot.
  if ! mkdir -p "$dest" \
    || ! rsync -a --delete "$FF1_CONTROL_STATE_DIR"/ "$dest"/; then
    log_error "Failed to copy control state into the update candidate."
    return 1
  fi
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
