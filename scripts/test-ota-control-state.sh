#!/usr/bin/env bash
# Single-quoted $VARs below are literal script text or are expanded inside
# run_helper's subshell, never by this shell.
# shellcheck disable=SC2016
# Pins archiso-ff1/airootfs/root/scripts/ota-control-state.sh (feral-file#3551,
# F9) against a fake running root and a fake @ota_new, with runuser and pgrep
# stubbed so no systemd is needed:
#   - live state present: controld is stopped through feralfile's user
#     manager, the candidate's stale copy is replaced by the live directory
#     (stale files deleted, modes kept), and a later restore restarts it once;
#   - live state absent, candidate clean: nothing is stopped or copied;
#   - live state absent, candidate holds a stale copy: the copy is removed;
#   - stop fails while controld still runs: refused, candidate untouched,
#     restart still owed;
#   - stop fails with no controld process: the copy proceeds;
# and that feral-system-update.sh wires it in where it must: sourced before
# the EXIT trap, called after post-extraction and right before
# `bootctl set-oneshot`, restart owed until the candidate is armed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT_DIR/archiso-ff1/airootfs/root/scripts"
HELPER="$SCRIPTS/ota-control-state.sh"
UPDATE="$SCRIPTS/feral-system-update.sh"

command -v rsync >/dev/null || { echo "rsync required" >&2; exit 127; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stubs. runuser logs its argv; the stop/pgrep outcomes come from files so a
# case can flip them without re-exporting anything.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/runuser" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/calls"
case "$*" in
  *" stop "*) exit "$(cat "$STUB_DIR/stop_rc")" ;;
esac
exit 0
EOF
cat > "$WORK/bin/pgrep" <<'EOF'
#!/bin/sh
echo "pgrep $*" >> "$STUB_DIR/calls"
exit "$(cat "$STUB_DIR/pgrep_rc")"
EOF
chmod +x "$WORK/bin/runuser" "$WORK/bin/pgrep"
export STUB_DIR="$WORK"

LIVE="$WORK/live/home/feralfile/.state/control"
CAND="$WORK/btrfs/@snapshots/@ota_new"
# The helper appends the live path to the candidate root, as on a device.
DEST="$CAND$LIVE"

# reset_case: stale candidate copy from the "OTA start", fresh live state.
reset_case() {
  rm -rf "$WORK/live" "$WORK/btrfs" "$WORK/calls"
  : > "$WORK/calls"
  echo 0 > "$WORK/stop_rc"
  echo 1 > "$WORK/pgrep_rc"
  mkdir -p "$DEST"
  echo '{"v":1,"gen":1,"controllers":["revoked-later"]}' > "$DEST/grants.json"
  echo stale > "$DEST/left-over.tmp"
  mkdir -p "$LIVE"
  chmod 700 "$LIVE"
  echo '{"v":1,"gen":1,"controllers":[]}' > "$LIVE/grants.json"
  echo '{"v":1,"gen":1}' > "$LIVE/identity.json"
  chmod 600 "$LIVE/grants.json" "$LIVE/identity.json"
}

# run_helper FN ARGS...: runs FN from a fresh source of the helper; prints
# CONTROLD_RESTART_PENDING after it so cases can check the owed restart.
run_helper() {
  RC=0
  (
    # shellcheck disable=SC2317,SC2329
    log_info() { echo "INFO $1"; }
    # shellcheck disable=SC2317,SC2329
    log_error() { echo "ERROR $1"; }
    export PATH="$WORK/bin:$PATH"
    export FF1_CONTROL_STATE_DIR="$LIVE"
    # shellcheck source=/dev/null
    source "$HELPER"
    local fn_rc=0
    "$@" || fn_rc=$?
    echo "PENDING $CONTROLD_RESTART_PENDING"
    exit "$fn_rc"
  ) > "$WORK/out" 2>&1 || RC=$?
}

stop_line="-u feralfile -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user stop feral-controld.service"
start_line="${stop_line/ stop / start }"

echo "== live state present"
reset_case
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "present: rc=$RC"; }
grep -qxF -- "$stop_line" "$WORK/calls" || { cat "$WORK/calls"; fail "present: controld not stopped via feralfile's user manager"; }
diff -r "$LIVE" "$DEST" || { cat "$WORK/out" "$WORK/calls"; fail "present: candidate differs from live state"; }
[[ ! -e "$DEST/left-over.tmp" ]] || fail "present: stale file survived (--delete missing)"
[[ -n "$(find "$DEST" -maxdepth 0 -perm 700)" ]] || fail "present: directory mode not kept"
[[ -n "$(find "$DEST/grants.json" -perm 600)" ]] || fail "present: file mode not kept"
grep -qx "PENDING 1" "$WORK/out" || fail "present: restart not owed after stop"
# Restore owes exactly one start; a second call is a no-op.
reset_case
run_helper eval 'carry_control_state "$CAND" && restore_controld_if_stopped && restore_controld_if_stopped'
(( RC == 0 )) || { cat "$WORK/out"; fail "restore: rc=$RC"; }
[[ "$(grep -cxF -- "$start_line" "$WORK/calls")" -eq 1 ]] || { cat "$WORK/calls"; fail "restore: expected exactly one start"; }
grep -qx "PENDING 0" "$WORK/out" || fail "restore: restart still owed after restore"
# Idempotent: a second carry over an already-current candidate is a no-op copy.
run_helper carry_control_state "$CAND"
(( RC == 0 )) || fail "rerun: rc=$RC"
diff -r "$LIVE" "$DEST" >/dev/null || fail "rerun: candidate differs"

echo "== live state absent, candidate clean"
reset_case
rm -rf "$LIVE" "$DEST"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || fail "absent: rc=$RC"
[[ ! -s "$WORK/calls" ]] || { cat "$WORK/calls"; fail "absent: touched controld"; }
grep -qx "PENDING 0" "$WORK/out" || fail "absent: restart owed"
[[ ! -e "$DEST" ]] || fail "absent: created control state in the candidate"

echo "== live state absent, candidate holds a stale copy"
reset_case
rm -rf "$LIVE"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || fail "stale: rc=$RC"
[[ ! -e "$DEST" ]] || fail "stale: candidate kept control state the live system no longer has"
[[ ! -s "$WORK/calls" ]] || fail "stale: touched controld"

echo "== stop fails, controld still running"
reset_case
echo 1 > "$WORK/stop_rc"
echo 0 > "$WORK/pgrep_rc"
run_helper carry_control_state "$CAND"
(( RC != 0 )) || fail "running: carried state while controld still runs"
grep -q "^ERROR Could not stop feral-controld" "$WORK/out" || fail "running: refusal not logged"
grep -qx "stale" "$DEST/left-over.tmp" || fail "running: candidate modified"
grep -qx "PENDING 1" "$WORK/out" || fail "running: restart not owed"
grep -qF "pgrep -u feralfile -x feral-controld" "$WORK/calls" || fail "running: pgrep not consulted"

echo "== stop fails, no controld process"
reset_case
echo 1 > "$WORK/stop_rc"
echo 1 > "$WORK/pgrep_rc"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "gone: rc=$RC"; }
diff -r "$LIVE" "$DEST" >/dev/null || fail "gone: candidate differs from live state"

echo "== feral-system-update.sh wiring"
line_of() { grep -nF -- "$1" "$UPDATE" | head -n1 | cut -d: -f1; }
src=$(line_of 'source /root/scripts/ota-control-state.sh')
trap_line=$(line_of 'trap cleanup EXIT')
restore=$(line_of '  restore_controld_if_stopped')
cleanup_def=$(line_of 'cleanup() {')
postx=$(line_of 'arch-chroot "$NEW_ROOT" /bin/bash /root/scripts/post-extraction.sh')
carry=$(line_of 'carry_control_state "$BTRFS_TOP/@snapshots/@ota_new"')
arm=$(line_of 'bootctl set-oneshot arch-candidate.conf')
clear=$(line_of 'CONTROLD_RESTART_PENDING=0')
reboot=$(line_of 'systemctl reboot')
for v in src trap_line restore cleanup_def postx carry arm clear reboot; do
  [[ -n "${!v}" ]] || fail "wiring: $v not found in feral-system-update.sh"
done
(( src < trap_line )) || fail "wiring: helper must be sourced before the EXIT trap"
(( cleanup_def < restore && restore < trap_line )) || fail "wiring: cleanup must call restore_controld_if_stopped"
(( postx < carry )) || fail "wiring: carry must run after post-extraction"
(( carry < arm )) || fail "wiring: carry must run before bootctl set-oneshot"
# Nothing but comments/blank lines between the carry and the arming.
if sed -n "$((carry + 1)),$((arm - 1))p" "$UPDATE" | grep -vqE '^[[:space:]]*(#|$)'; then
  fail "wiring: carry_control_state must be the last step before bootctl set-oneshot"
fi
(( arm < clear && clear < reboot )) || fail "wiring: restart must stay owed until the candidate is armed"
grep -qF '"/root/scripts/ota-control-state.sh"' "$ROOT_DIR/archiso-ff1/profiledef.sh" \
  || fail "wiring: profiledef.sh must list /root/scripts/ota-control-state.sh"

echo "ota-control-state: all cases passed"
