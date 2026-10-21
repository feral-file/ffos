#!/usr/bin/env bash
# Single-quoted $VARs below are literal script text or are expanded inside
# run_helper's subshell, never by this shell.
# shellcheck disable=SC2016
# PATH is extended inside the (...) runners on purpose, so stubs never leak.
# shellcheck disable=SC2030,SC2031
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
#   - reset tombstone (control.retired) live: carried, controld stopped;
#   - tombstone absent live but present in the candidate: removed;
#   - tombstone plus control.new/ live, control/ gone: all three mirrored;
#   - same size, same mtime, different content: still replaced (--checksum);
#   - a candidate entry that is a symlink to a directory outside: the link is
#     replaced, the target is untouched;
#   - a candidate .state that is a symlink out of the candidate: refused;
#   - the feral-watchdog marker: present (empty, 0644) during the stop,
#     removed on restore (also when the start fails), never created when
#     nothing is live;
#   - a stat error other than ENOENT (stubbed EIO): the carry fails and the
#     candidate copy is NOT treated as stale;
#   - live side: a symlinked live .state is refused before the stop; a
#     symlinked live entry is refused with the restart owed;
#   - the marker cannot be created: logged without [ERROR] (otagate treats
#     any [ERROR] line as the run's failure) and the carry proceeds;
#   - downgrade guard: a candidate without ota-control-state.sh, or whose
#     feral-controld lacks the feral-controld-control-v1 capability (Provides,
#     continuation lines included) or is unreadable, is
#     refused only when live state exists, before anything is stopped; a
#     stat error on the image probe or the live state is refused with its
#     own message;
#   - package rail (feral-service-update.sh): feral-controld is held back
#     when the repository build lacks the capability (or cannot be read) and
#     live state exists; a live
#     stat error installs nothing;
#   - pre-download stop check: refused only when live state exists, the user
#     manager is unreachable and controld still runs; nothing is stopped;
#   - the arming block: a failed bootctl set-oneshot clears the oneshot and
#     leaves the restart owed; a successful one clears it;
# and that feral-system-update.sh wires it in where it must: sourced before
# the EXIT trap, the stop check before the download, the downgrade guard on
# the mounted image before its rsync, the carry after post-extraction and
# right before `bootctl set-oneshot`, restart owed until the candidate is
# armed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT_DIR/archiso-ff1/airootfs/root/scripts"
HELPER="$SCRIPTS/ota-control-state.sh"
UPDATE="$SCRIPTS/feral-system-update.sh"

command -v rsync >/dev/null || { echo "rsync required" >&2; exit 127; }

WORK_TMP="$(mktemp -d)"
[[ -n "$WORK_TMP" && -d "$WORK_TMP" ]] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf -- "$WORK_TMP"' EXIT
# Physical path: the helper requires the live .state to resolve to itself.
WORK="$(cd -- "$WORK_TMP" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stubs. runuser logs its argv; the stop/pgrep outcomes come from files so a
# case can flip them without re-exporting anything.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/runuser" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_DIR/calls"
case "$*" in
  *" stop "*) [ -e "$STUB_DIR/run/feral-controld-ota-stop" ] && echo "marker-at-stop" >> "$STUB_DIR/marker" ;;
esac
case "$*" in
  *" stop "*) exit "$(cat "$STUB_DIR/stop_rc")" ;;
  *" start "*) exit "$(cat "$STUB_DIR/start_rc")" ;;
  *" show "*) exit "$(cat "$STUB_DIR/show_rc")" ;;
esac
exit 0
EOF
cat > "$WORK/bin/pgrep" <<'EOF'
#!/bin/sh
echo "pgrep $*" >> "$STUB_DIR/calls"
exit "$(cat "$STUB_DIR/pgrep_rc")"
EOF
# stat: real stat, except for the one path named in $STUB_DIR/stat_eio,
# which fails the way an I/O error does.
REAL_STAT="$(command -v stat)"
cat > "$WORK/bin/stat" <<EOF
#!/bin/sh
for a in "\$@"; do
  if [ -s "\$STUB_DIR/stat_eio" ] && [ "\$a" = "\$(cat "\$STUB_DIR/stat_eio")" ]; then
    echo "stat: cannot statx '\$a': Input/output error" >&2
    exit 1
  fi
done
exec "$REAL_STAT" "\$@"
EOF
# pacman: -Qi/-Si print a Provides field read from a file (missing or
# empty = not installed / unreadable, exit 1), shaped like real pacman output
# with a wrapped continuation line; -S logs its package list and reports
# nothing to do.
cat > "$WORK/bin/pacman" <<'EOF'
#!/bin/sh
info() {
  [ -s "$STUB_DIR/$1" ] || exit 1
  echo "Name            : feral-controld"
  echo "Version         : 0.0.1-1"
  echo "Description     : mentions feral-controld-control-v1 here only"
  echo "Provides        : $(head -n1 "$STUB_DIR/$1")"
  sed -n '2,$s/^/                  /p' "$STUB_DIR/$1"
  echo "Depends On      : None"
  exit 0
}
case "$*" in
  "--dbpath "*" -Qi feral-controld") info image_prov ;;
  "-Si feral-controld") info repo_prov ;;
  "-Sy --noconfirm") exit 0 ;;
  "-S "*) echo "pacman $*" >> "$STUB_DIR/calls"; echo " there is nothing to do"; exit 0 ;;
esac
echo "pacman stub: unexpected $*" >&2
exit 2
EOF
cat > "$WORK/bin/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$STUB_DIR/calls"
EOF
chmod +x "$WORK/bin/runuser" "$WORK/bin/pgrep" "$WORK/bin/stat" "$WORK/bin/pacman" "$WORK/bin/systemctl"
# The helper uses GNU `realpath -m` / `-e`. On a non-GNU host (macOS) shim it
# so the test runs locally too; CI (Ubuntu) and the image use the real one.
if ! realpath -m -- / >/dev/null 2>&1; then
  cat > "$WORK/bin/realpath" <<'EOF2'
#!/bin/sh
mode=""
case "$1" in -m|-e) mode="$1"; shift ;; esac
[ "$1" = "--" ] && shift
if [ "$mode" = "-e" ] && [ ! -e "$1" ]; then exit 1; fi
exec python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
EOF2
  chmod +x "$WORK/bin/realpath"
fi
export STUB_DIR="$WORK"

LIVE="$WORK/live/home/feralfile/.state/control"
CAND="$WORK/btrfs/@snapshots/@ota_new"
# The helper appends the live path to the candidate root, as on a device.
DEST="$CAND$LIVE"
MARKER="$WORK/run/feral-controld-ota-stop"
TOMB="$LIVE.retired"
DEST_TOMB="$CAND$TOMB"
LIVE_NEW="$LIVE.new"
DEST_NEW="$CAND$LIVE_NEW"

# reset_case: stale candidate copy from the "OTA start", fresh live state.
reset_case() {
  rm -rf "$WORK/live" "$WORK/btrfs" "$WORK/calls" "$WORK/outside" "$WORK/run" "$WORK/marker" "$WORK/elsewhere"
  mkdir -p "$WORK/run"
  : > "$WORK/calls"
  : > "$WORK/stat_eio"
  echo 0 > "$WORK/stop_rc"
  echo 0 > "$WORK/start_rc"
  echo 0 > "$WORK/show_rc"
  echo 1 > "$WORK/pgrep_rc"
  echo feral-controld-control-v1 > "$WORK/image_prov"
  echo feral-controld-control-v1 > "$WORK/repo_prov"
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
    export FF1_CONTROLD_OTA_STOP_MARKER="$MARKER"
    # shellcheck source=/dev/null
    source "$HELPER"
    local fn_rc=0
    "$@" || fn_rc=$?
    echo "PENDING $CONTROLD_RESTART_PENDING"
    exit "$fn_rc"
  ) > "$WORK/out" 2>&1 || RC=$?
}

# line_of TEXT: first line number of TEXT in feral-system-update.sh, or
# empty; never fails, so callers' own diagnostics fire.
line_of() { grep -nF -- "$1" "$UPDATE" | head -n1 | cut -d: -f1 || true; }

stop_line="-u feralfile -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user stop feral-controld.service"
start_line="${stop_line/ stop / start --no-block }"

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

echo "== tombstone live (reset in progress)"
reset_case
rm -rf "$LIVE"
printf '{"v":1,"retiredAt":"x"}\n' > "$TOMB"
chmod 600 "$TOMB"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "tomb: rc=$RC"; }
grep -qxF -- "$stop_line" "$WORK/calls" || fail "tomb: controld not stopped for a live tombstone"
cmp -s "$TOMB" "$DEST_TOMB" || fail "tomb: tombstone not carried"
[[ -n "$(find "$DEST_TOMB" -perm 600)" ]] || fail "tomb: tombstone mode not kept"
[[ ! -e "$DEST" ]] || fail "tomb: candidate kept control/ that the reset already deleted"

echo "== tombstone absent live, present in candidate"
reset_case
echo stale-tomb > "$DEST_TOMB"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "stale tomb: rc=$RC"; }
[[ ! -e "$DEST_TOMB" ]] || fail "stale tomb: candidate kept a tombstone the live system no longer has"
diff -r "$LIVE" "$DEST" >/dev/null || fail "stale tomb: control/ not carried"
# Candidate-only leftovers with nothing live: removed without touching controld.
reset_case
rm -rf "$LIVE"
echo stale-tomb > "$DEST_TOMB"
mkdir -p "$DEST_NEW"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || fail "stale only: rc=$RC"
[[ ! -e "$DEST_TOMB" && ! -e "$DEST_NEW" && ! -e "$DEST" ]] || fail "stale only: candidate kept state the live system no longer has"
[[ ! -s "$WORK/calls" ]] || fail "stale only: touched controld with no live state"

echo "== tombstone plus directories"
reset_case
printf 'tomb\n' > "$TOMB"
mkdir -p "$LIVE_NEW"
echo '{"v":1,"gen":2}' > "$LIVE_NEW/identity.json"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "both: rc=$RC"; }
cmp -s "$TOMB" "$DEST_TOMB" || fail "both: tombstone not carried"
diff -r "$LIVE" "$DEST" >/dev/null || fail "both: control/ not carried"
diff -r "$LIVE_NEW" "$DEST_NEW" >/dev/null || fail "both: control.new/ not carried"
[[ "$(grep -cxF -- "$stop_line" "$WORK/calls")" -eq 1 ]] || fail "both: expected exactly one stop"
# Type flip: a candidate directory where the live tombstone is a file.
reset_case
rm -rf "$LIVE"
printf 'tomb\n' > "$TOMB"
mkdir -p "$DEST_TOMB/odd"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "flip: rc=$RC"; }
cmp -s "$TOMB" "$DEST_TOMB" || fail "flip: tombstone not carried over a candidate directory"

echo "== same size and mtime, different content"
reset_case
echo '{"v":1,"gen":1,"controllers":[],"hi":7}' > "$LIVE/grants.json"
echo '{"v":1,"gen":1,"controllers":[],"hi":6}' > "$DEST/grants.json"
touch -r "$LIVE/grants.json" "$DEST/grants.json"
echo tomb-new > "$TOMB"
echo tomb-old > "$DEST_TOMB"
touch -r "$TOMB" "$DEST_TOMB"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "checksum: rc=$RC"; }
cmp -s "$LIVE/grants.json" "$DEST/grants.json" || fail "checksum: same-size same-mtime grants.json skipped (quick check)"
cmp -s "$TOMB" "$DEST_TOMB" || fail "checksum: same-size same-mtime tombstone skipped (quick check)"

echo "== candidate entries that are symlinks"
reset_case
mkdir -p "$WORK/outside"
echo keep > "$WORK/outside/victim"
rm -rf "$DEST"
ln -s "$WORK/outside" "$DEST"
echo tomb > "$TOMB"
ln -s "$WORK/outside/victim" "$DEST_TOMB"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "dest link: rc=$RC"; }
[[ -d "$DEST" && ! -L "$DEST" ]] || fail "dest link: control/ still a symlink"
diff -r "$LIVE" "$DEST" >/dev/null || fail "dest link: control/ not carried"
[[ -f "$DEST_TOMB" && ! -L "$DEST_TOMB" ]] || fail "dest link: tombstone still a symlink"
if [[ "$(ls "$WORK/outside")" != victim ]] || ! grep -qx keep "$WORK/outside/victim"; then
  fail "dest link: wrote through a candidate symlink"
fi
# Stale removal through a link removes the link only.
reset_case
mkdir -p "$WORK/outside" && echo keep > "$WORK/outside/victim"
rm -rf "$LIVE" "$DEST"
ln -s "$WORK/outside" "$DEST"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || fail "stale link: rc=$RC"
[[ ! -e "$DEST" && ! -L "$DEST" ]] || fail "stale link: link kept"
grep -qx keep "$WORK/outside/victim" || fail "stale link: followed the link"

echo "== candidate .state is a symlink out of the candidate"
reset_case
rm -rf "$WORK/outside" && mkdir -p "$WORK/outside" && echo keep > "$WORK/outside/victim"
rm -rf "$(dirname "$DEST")"
ln -s "$WORK/outside" "$(dirname "$DEST")"
run_helper carry_control_state "$CAND"
(( RC != 0 )) || fail "state link: wrote through a symlinked .state"
grep -q "^ERROR Update candidate .state resolves outside the candidate root" "$WORK/out" || fail "state link: refusal not logged"
[[ "$(ls "$WORK/outside")" == victim ]] || fail "state link: wrote outside the candidate"
grep -qx "PENDING 1" "$WORK/out" || fail "state link: restart not owed after refusal"

echo "== feral-watchdog stop marker"
reset_case
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "marker: rc=$RC"; }
grep -qx marker-at-stop "$WORK/marker" 2>/dev/null || fail "marker: not present when controld was stopped"
[[ -f "$MARKER" && ! -s "$MARKER" ]] || fail "marker: must stay (empty) after the carry, until restore or reboot"
[[ -n "$(find "$MARKER" -perm 644)" ]] || fail "marker: mode must be 0644"
[[ -z "$(find "$WORK/run" -name 'feral-controld-ota-stop.*')" ]] || fail "marker: temp file left behind"
# Restore after a carry (one shell, as the update script does) removes it.
reset_case
run_helper eval 'carry_control_state "$CAND" && restore_controld_if_stopped'
(( RC == 0 )) || fail "marker restore: rc=$RC"
grep -qxF -- "$start_line" "$WORK/calls" || fail "marker restore: controld not started"
[[ ! -e "$MARKER" ]] || fail "marker: not removed on restore"
# Refused stop: the abort path (EXIT trap -> restore) removes it.
reset_case
echo 1 > "$WORK/stop_rc"
echo 0 > "$WORK/pgrep_rc"
run_helper eval 'carry_control_state "$CAND" || { restore_controld_if_stopped; false; }'
(( RC != 0 )) || fail "marker refuse: carry should have refused"
grep -qx marker-at-stop "$WORK/marker" 2>/dev/null || fail "marker refuse: not present at the stop attempt"
[[ ! -e "$MARKER" ]] || fail "marker: not removed after a refused stop"
# Nothing live: no marker.
reset_case
rm -rf "$LIVE"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || fail "marker absent: rc=$RC"
[[ ! -e "$MARKER" ]] || fail "marker: created with nothing live"

# Marker cannot be created: not an [ERROR] line, and the carry goes on.
reset_case
rm -rf "$WORK/run"
run_helper carry_control_state "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "marker fails: rc=$RC"; }
grep -q "^INFO Warning: failed to create $MARKER" "$WORK/out" || { cat "$WORK/out"; fail "marker fails: not logged"; }
! grep -q "^ERROR" "$WORK/out" || { cat "$WORK/out"; fail "marker fails: logged as an error, which otagate treats as terminal"; }
diff -r "$LIVE" "$DEST" >/dev/null || fail "marker fails: carry did not complete"

echo "== restart fails"
reset_case
echo 1 > "$WORK/start_rc"
run_helper eval 'carry_control_state "$CAND" && restore_controld_if_stopped'
(( RC == 0 )) || { cat "$WORK/out"; fail "start fails: rc=$RC"; }
grep -qxF -- "$start_line" "$WORK/calls" || fail "start fails: start not attempted"
grep -q "^ERROR Failed to restart feral-controld" "$WORK/out" || fail "start fails: not logged"
[[ ! -e "$MARKER" ]] || fail "start fails: marker kept, would hide a real outage"

echo "== stat error other than ENOENT"
reset_case
echo stale-tomb > "$DEST_TOMB"
printf '%s\n' "$TOMB" > "$WORK/stat_eio"
run_helper carry_control_state "$CAND"
(( RC != 0 )) || fail "eio: unreadable live tombstone treated as absent"
grep -q "^ERROR Cannot stat control state path $TOMB" "$WORK/out" || { cat "$WORK/out"; fail "eio: not logged"; }
grep -qx stale-tomb "$DEST_TOMB" || fail "eio: candidate tombstone removed on a stat error"
[[ ! -s "$WORK/calls" ]] || fail "eio: stopped controld before classifying"
grep -qx "PENDING 0" "$WORK/out" || fail "eio: restart owed without a stop"
# Same for the candidate side.
reset_case
echo stale-tomb > "$DEST_TOMB"
printf '%s\n' "$DEST_TOMB" > "$WORK/stat_eio"
run_helper carry_control_state "$CAND"
(( RC != 0 )) || fail "eio cand: candidate stat error ignored"
grep -qx stale-tomb "$DEST_TOMB" || fail "eio cand: candidate tombstone touched"

echo "== live side symlinks"
reset_case
mkdir -p "$WORK/elsewhere"
mv "$WORK/live/home/feralfile/.state" "$WORK/elsewhere/.state"
ln -s "$WORK/elsewhere/.state" "$WORK/live/home/feralfile/.state"
run_helper carry_control_state "$CAND"
(( RC != 0 )) || fail "live link: carried through a symlinked live .state"
grep -q "^ERROR Live control state parent" "$WORK/out" || { cat "$WORK/out"; fail "live link: refusal not logged"; }
[[ ! -s "$WORK/calls" ]] || fail "live link: stopped controld before refusing"
grep -qx stale "$DEST/left-over.tmp" || fail "live link: candidate modified"
reset_case
mkdir -p "$WORK/elsewhere"
echo secret > "$WORK/elsewhere/secret"
ln -s "$WORK/elsewhere/secret" "$TOMB"
run_helper carry_control_state "$CAND"
(( RC != 0 )) || fail "live entry link: carried a symlinked live entry"
grep -q "^ERROR Live control state $TOMB is a symlink" "$WORK/out" || { cat "$WORK/out"; fail "live entry link: refusal not logged"; }
grep -qx "PENDING 1" "$WORK/out" || fail "live entry link: restart not owed after the stop"
[[ ! -e "$DEST_TOMB" ]] || fail "live entry link: tombstone written to the candidate"

echo "== downgrade guard"
refusal="ERROR Refusing update: target image cannot carry controller state (no /root/scripts/ota-control-state.sh); a downgrade below secure-control support would lose or resurrect controller grants."
reset_case
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: candidate without the carry accepted while state is live"
grep -qxF -- "$refusal" "$WORK/out" || { cat "$WORK/out"; fail "downgrade: classify.go message changed"; }
[[ ! -s "$WORK/calls" ]] || fail "downgrade: touched controld"
grep -qx "PENDING 0" "$WORK/out" || fail "downgrade: restart owed without a stop"
# Tombstone alone counts as live state.
reset_case
rm -rf "$LIVE"
echo tomb > "$TOMB"
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: tombstone-only device accepted"
# Candidate that carries: accepted.
reset_case
mkdir -p "$CAND/root/scripts"
: > "$CAND/root/scripts/ota-control-state.sh"
run_helper refuse_update_without_carry "$CAND"
(( RC == 0 )) || fail "downgrade: candidate with the carry refused"
# No live state: any image is fine.
reset_case
rm -rf "$LIVE"
run_helper refuse_update_without_carry "$CAND"
(( RC == 0 )) || fail "downgrade: refused with no live state"
# Carry present but the image's controld lacks the marker: refused, same
# prefix (the version field is irrelevant, and the Description mention of the
# marker must not count).
reset_case
mkdir -p "$CAND/root/scripts"
: > "$CAND/root/scripts/ota-control-state.sh"
echo None > "$WORK/image_prov"
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: image controld without the marker accepted while state is live"
grep -qxF -- "ERROR Refusing update: target image cannot carry controller state (its feral-controld does not provide feral-controld-control-v1); a controld without the protocol would reopen this device." "$WORK/out" || { cat "$WORK/out"; fail "downgrade: marker refusal message"; }
[[ ! -s "$WORK/calls" ]] || fail "downgrade: marker refusal touched controld"
# A similar but different capability does not count.
echo feral-controld-control-v10 > "$WORK/image_prov"
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: a different capability accepted as the marker"
# The marker on a wrapped continuation line counts.
printf '%s\n%s\n' other-thing feral-controld-control-v1 > "$WORK/image_prov"
run_helper refuse_update_without_carry "$CAND"
(( RC == 0 )) || { cat "$WORK/out"; fail "downgrade: marker on a continuation line refused"; }
# Unreadable image controld: refused.
: > "$WORK/image_prov"
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: unreadable image controld accepted"
grep -q "^ERROR Refusing update: target image cannot carry controller state (its feral-controld does not provide" "$WORK/out" || { cat "$WORK/out"; fail "downgrade: unreadable controld message"; }
# No marker with no live state: fine.
reset_case
rm -rf "$LIVE"
mkdir -p "$CAND/root/scripts"
: > "$CAND/root/scripts/ota-control-state.sh"
echo None > "$WORK/image_prov"
run_helper refuse_update_without_carry "$CAND"
(( RC == 0 )) || fail "downgrade: controld without the marker refused with no live state"
# Stat error on the image probe: its own message, not the control-state one.
reset_case
echo "$CAND/root/scripts/ota-control-state.sh" > "$WORK/stat_eio"
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: image stat error accepted"
grep -q "^ERROR Cannot stat target image path $CAND/root/scripts/ota-control-state.sh" "$WORK/out" || { cat "$WORK/out"; fail "downgrade: image stat error message"; }
# Stat error on the live state: refused.
reset_case
mkdir -p "$CAND/root/scripts"
: > "$CAND/root/scripts/ota-control-state.sh"
echo "$LIVE" > "$WORK/stat_eio"
run_helper refuse_update_without_carry "$CAND"
(( RC != 0 )) || fail "downgrade: live stat error accepted"
grep -q "^ERROR Cannot stat control state path $LIVE" "$WORK/out" || { cat "$WORK/out"; fail "downgrade: live stat error message"; }

echo "== pre-download stop check"
reset_case
run_helper check_controld_stoppable
(( RC == 0 )) || { cat "$WORK/out"; fail "stoppable: refused with a reachable user manager"; }
grep -q "show -p ActiveState feral-controld.service" "$WORK/calls" || fail "stoppable: user manager not probed"
! grep -q " stop " "$WORK/calls" || fail "stoppable: stopped controld"
reset_case
echo 1 > "$WORK/show_rc"
echo 0 > "$WORK/pgrep_rc"
run_helper check_controld_stoppable
(( RC != 0 )) || fail "stoppable: accepted an unreachable manager with controld running"
grep -q "^ERROR Could not stop feral-controld" "$WORK/out" || { cat "$WORK/out"; fail "stoppable: classify.go prefix changed"; }
grep -qx "PENDING 0" "$WORK/out" || fail "stoppable: restart owed without a stop"
# Unreachable manager but no controld process: the carry would continue too.
reset_case
echo 1 > "$WORK/show_rc"
run_helper check_controld_stoppable
(( RC == 0 )) || fail "stoppable: refused with no controld running"
# No live state: nothing to stop, no probe.
reset_case
rm -rf "$LIVE"
echo 1 > "$WORK/show_rc"
echo 0 > "$WORK/pgrep_rc"
run_helper check_controld_stoppable
(( RC == 0 )) || fail "stoppable: refused with no live state"
[[ ! -s "$WORK/calls" ]] || fail "stoppable: probed with no live state"
# Stat error on the live state: refused before any probe.
reset_case
echo "$LIVE" > "$WORK/stat_eio"
run_helper check_controld_stoppable
(( RC != 0 )) || fail "stoppable: live stat error accepted"
grep -q "^ERROR Cannot stat control state path $LIVE" "$WORK/out" || { cat "$WORK/out"; fail "stoppable: live stat error message"; }
[[ ! -s "$WORK/calls" ]] || fail "stoppable: probed after a stat error"

echo "== package rail"
# run_service_update: the real feral-service-update.sh against the stubs.
run_service_update() {
  RC=0
  (
    export PATH="$WORK/bin:$PATH"
    export FF1_CONTROL_HELPER="$HELPER"
    export FF1_CONTROL_STATE_DIR="$LIVE"
    bash "$SCRIPTS/feral-service-update.sh" test-id
  ) > "$WORK/out" 2>&1 || RC=$?
}
all_pkgs="pacman -S --needed --noconfirm feral-controld feral-sys-monitord feral-watchdog"
reset_case
echo None > "$WORK/repo_prov"
run_service_update
(( RC == 0 )) || { cat "$WORK/out"; fail "rail: rc=$RC"; }
grep -qxF -- "pacman -S --needed --noconfirm feral-sys-monitord feral-watchdog" "$WORK/calls" || { cat "$WORK/calls"; fail "rail: controld without the marker not held back with live state"; }
grep -q "Holding feral-controld: the repository build does not provide feral-controld-control-v1" "$WORK/out" || { cat "$WORK/out"; fail "rail: hold not logged"; }
! grep -q "\[ERROR\]" "$WORK/out" || fail "rail: hold logged as an error"
reset_case
: > "$WORK/repo_prov"
run_service_update
grep -qxF -- "pacman -S --needed --noconfirm feral-sys-monitord feral-watchdog" "$WORK/calls" || { cat "$WORK/calls"; fail "rail: unreadable repo controld not held back"; }
reset_case
run_service_update
grep -qxF -- "$all_pkgs" "$WORK/calls" || { cat "$WORK/out" "$WORK/calls"; fail "rail: marker-carrying controld held back"; }
reset_case
rm -rf "$LIVE"
echo None > "$WORK/repo_prov"
run_service_update
grep -qxF -- "$all_pkgs" "$WORK/calls" || { cat "$WORK/out" "$WORK/calls"; fail "rail: controld held back with no live state"; }
reset_case
echo "$LIVE" > "$WORK/stat_eio"
run_service_update
(( RC != 0 )) || fail "rail: live stat error accepted"
! grep -q "^pacman -S" "$WORK/calls" || fail "rail: installed packages after a stat error"

echo "== arming block"
# Run the real block from feral-system-update.sh (from the signal trap to the
# flag clear) with bootctl stubbed, the way the script runs it.
arm_block() {
  local from to
  from=$(line_of "trap '' TERM INT HUP")
  to=$(line_of 'CONTROLD_RESTART_PENDING=0')
  [[ -n "$from" && -n "$to" ]] || fail "arming: block markers not found"
  sed -n "${from},${to}p" "$UPDATE"
}
cat > "$WORK/bin/bootctl" <<'EOF'
#!/bin/sh
echo "bootctl [$*]" >> "$STUB_DIR/calls"
[ "$2" = "arch-candidate.conf" ] && exit "$(cat "$STUB_DIR/bootctl_rc")"
exit 0
EOF
chmod +x "$WORK/bin/bootctl"
run_arm() {
  : > "$WORK/calls"
  RC=0
  (
    # shellcheck disable=SC2317,SC2329
    log_error() { echo "ERROR $1"; }
    export PATH="$WORK/bin:$PATH"
    CONTROLD_RESTART_PENDING=1
    trap 'echo "PENDING $CONTROLD_RESTART_PENDING"' EXIT
    eval "$(arm_block)"
  ) > "$WORK/out" 2>&1 || RC=$?
}
echo 1 > "$WORK/bootctl_rc"
run_arm
(( RC != 0 )) || fail "arming: a failed set-oneshot did not abort"
grep -qx "PENDING 1" "$WORK/out" || { cat "$WORK/out"; fail "arming: restart not owed after a failed set-oneshot"; }
grep -qxF "bootctl [set-oneshot ]" "$WORK/calls" || { cat "$WORK/calls"; fail "arming: oneshot not cleared after failure"; }
echo 0 > "$WORK/bootctl_rc"
run_arm
(( RC == 0 )) || { cat "$WORK/out"; fail "arming: rc=$RC on success"; }
grep -qx "PENDING 0" "$WORK/out" || fail "arming: restart still owed after arming"
! grep -qxF "bootctl [set-oneshot ]" "$WORK/calls" || fail "arming: oneshot cleared after success"
grep -qxF "trap '' TERM INT HUP" <(arm_block) || fail "arming: signals not ignored around set-oneshot"

echo "== feral-system-update.sh wiring"
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
sigs=$(line_of "trap '' TERM INT HUP")
rsync_main=$(line_of '"$SFS_MOUNT"/ "$NEW_ROOT"/')
guard=$(line_of 'if ! refuse_update_without_carry "$SFS_MOUNT"; then')
sfs_mount=$(line_of 'mount -t squashfs -o loop "$SFS_PATH" "$SFS_MOUNT"')
stoppable=$(line_of 'if ! check_controld_stoppable; then')
download=$(line_of 'download_file_with_slow_retry "$ENDPOINT$IMAGE_URL" "$ISO_FILE" "OTA image"')
for v in sigs rsync_main guard sfs_mount stoppable download; do
  [[ -n "${!v}" ]] || fail "wiring: $v not found in feral-system-update.sh"
done
(( trap_line < stoppable && stoppable < download )) || fail "wiring: stop check must run before the download, under the EXIT trap"
(( sfs_mount < guard && guard < rsync_main && guard < carry )) || fail "wiring: downgrade guard must check the mounted image before its rsync and precede the carry"
(( carry < sigs && sigs < arm )) || fail "wiring: carry, then ignore signals, then bootctl set-oneshot"
# Nothing but comments/blank lines between the carry and the arming block.
if sed -n "$((carry + 1)),$((sigs - 1))p" "$UPDATE" | grep -vqE '^[[:space:]]*(#|$)'; then
  fail "wiring: carry_control_state must be the last step before arming"
fi
(( arm == sigs + 1 )) || fail "wiring: bootctl set-oneshot must directly follow the signal trap"
(( arm < clear && clear < reboot )) || fail "wiring: restart must stay owed until the candidate is armed"
# After arming nothing may abort: errexit and the ERR trap go off right
# after the flag is cleared, and the reboot has forced fallbacks.
[[ "$(sed -n "$((clear + 1)),$((clear + 6))p" "$UPDATE" | grep -cxE 'set \+e|trap - ERR')" -eq 2 ]] \
  || fail "wiring: set +e and trap - ERR must follow the post-arm flag clear"
grep -qxF 'cleanup || true' "$UPDATE" || fail "wiring: post-arm cleanup must be non-fatal"
force=$(line_of 'systemctl reboot --force || reboot -f')
if [[ -z "$force" ]] || (( force < clear )); then
  fail "wiring: reboot must fall back to --force and reboot -f"
fi
grep -qF '"/root/scripts/ota-control-state.sh"' "$ROOT_DIR/archiso-ff1/profiledef.sh" \
  || fail "wiring: profiledef.sh must list /root/scripts/ota-control-state.sh"

echo "ota-control-state: all cases passed"
