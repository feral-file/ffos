#!/bin/bash
set -euo pipefail

log_info() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [INFO] id=$UNIQUE_ID message=\"$message\""
}

log_progress() {
  local percent="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [PROGRESS] id=$UNIQUE_ID progress=$percent message=\"$message\""
}

log_error() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [ERROR] id=$UNIQUE_ID message=\"$message\""
}

trap 'code=$?; log_error "EXCEPTION ERR: LINE=$LINENO CMD=\"$BASH_COMMAND\""; exit $code' ERR

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "ERROR: Usage: $0 2025-06-19T16:00:00"
  exit 1
fi
UNIQUE_ID="$1"

log_progress "0" "Updating Pacman packages..."

packages=(feral-controld feral-sys-monitord feral-watchdog)
pacman -Sy --noconfirm >/dev/null

# feral-file#3551: a device holding controller state must never take an
# older feral-controld (it may ignore .state/control and reopen the device),
# and `pacman -S` installs a lower repository version with only a warning.
# Hold controld back then; the other packages still update. The helper is
# overridable only for scripts/test-ota-control-state.sh.
FF1_CONTROL_HELPER="${FF1_CONTROL_HELPER:-/root/scripts/ota-control-state.sh}"
if [[ -r "$FF1_CONTROL_HELPER" ]]; then
  # shellcheck source=SCRIPTDIR/ota-control-state.sh
  source "$FF1_CONTROL_HELPER"
  live_rc=0
  control_state_any_live || live_rc=$?
  # 2: a control path could not be classified (already logged).
  (( live_rc != 2 )) || exit 1
  if (( live_rc == 0 )); then
    repo_version=$(pacman -Si feral-controld 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}' || true)
    if [[ -z "$repo_version" ]] || controld_would_downgrade "$repo_version"; then
      log_info "Holding feral-controld at $(controld_version): the repository offers ${repo_version:-no version}, older, and this device holds controller state"
      packages=(feral-sys-monitord feral-watchdog)
    fi
  fi
fi

output=$(pacman -S --needed --noconfirm "${packages[@]}")

if ! echo "$output" | grep -q "there is nothing to do"; then
  log_progress "100" "Packages updated. Rebooting system to apply updates..."
  systemctl reboot
else
  log_info "Packages already up to date. No action needed."
  log_progress "100" "Packages already up to date. No action needed."
fi