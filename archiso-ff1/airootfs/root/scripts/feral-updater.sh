#!/bin/bash
set -euo pipefail

LOCKFILE="/run/feral-updater.lock"

log_info() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [INFO] id=$UNIQUE_ID message=\"$message\""
}

log_error() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [ERROR] id=$UNIQUE_ID message=\"$message\""
}

# Accept UNIQUE_ID from argument, or default to current UNIX timestamp
if [[ $# -ge 1 && -n "$1" ]]; then
  UNIQUE_ID="$1"
else
  UNIQUE_ID="$(date +%s)"
fi

# Acquire exclusive lock (non-blocking)
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log_error "Lock already held by another instance."
  exit 0
fi

# Release lock and clean up on any exit (success, error, or signal)
cleanup() {
  flock -u 9 2>/dev/null || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}

handle_err() {
  local exit_code=$?
  log_error "EXCEPTION ERR: LINE=$LINENO CMD=\"$BASH_COMMAND\""
  exit "$exit_code"
}

trap handle_err ERR
trap cleanup EXIT

# Terminate recovery update if it's running to avoid conflicts
if systemctl is-active --quiet feral-recovery-update.service; then
  log_info "Recovery update service is running. Stopping it to proceed with normal OTA update..."
  systemctl stop feral-recovery-update.service || log_error "Failed to stop recovery update service"
  # Wait a moment for cleanup
  sleep 2
fi

if ! ping -q -c 1 -W 2 8.8.8.8 >/dev/null; then
  log_error "No network connection. Aborting update."
  exit 0
fi

ENV_MODE="test"
if [[ -r /home/feralfile/.state/environment ]]; then
  ENV_MODE="$(xargs < /home/feralfile/.state/environment 2>/dev/null)"
fi

if [[ "$ENV_MODE" == "live" ]]; then
  CONFIG_FILE="/home/feralfile/ff1-config.json"
  VMAGENT_IMPORT_API="http://0.0.0.0:9431/api/v1/import/prometheus"

  log_info "📖 Reading config from $CONFIG_FILE"
  branch=$(jq -r '.branch' "$CONFIG_FILE")
  current_version=$(jq -r '.version' "$CONFIG_FILE")
  ENDPOINT=$(jq -r '.endpoint' "$CONFIG_FILE")

  API_URL="$ENDPOINT/api/latest/$branch"
  log_info "🌐 Fetching latest version info from: $API_URL"
  response=$(curl -s -f -L "$API_URL")
  latest_version=$(jq -r '.latest_version' <<< "$response")
  min_upgradeable_version=$(jq -r '.min_upgradeable_version' <<< "$response")
  image_url=$(jq -r '.image_url' <<< "$response")

  log_info "🆚 Current: $current_version  →  Remote: $latest_version"
  log_info "Minimum upgradeable version: $min_upgradeable_version"

  # if current version is less than min upgradeable version, exit with log warning
  if ! printf '%s\n%s\n' "$min_upgradeable_version" "$current_version" | sort -V -C; then
    log_info "Current version $current_version is less than minimum upgradeable version $min_upgradeable_version. Aborting update."
    exit 0
  fi
  
  if [[ "$latest_version" != "$current_version" ]]; then
    # Send start event to vagent
    if curl -sS --max-time 5 "$VMAGENT_IMPORT_API" -o /dev/null; then
      log_info "VMAGENT reachable at $VMAGENT_IMPORT_API"
      METRIC="ff_ota_update{event=\"start\",target_version=\"$latest_version\"} 1"
      if curl -sS -X POST "$VMAGENT_IMPORT_API" --data-binary "$METRIC" -w "%{http_code}" | grep -q "204"; then
        log_info "Successfully sent OTA update notification to $VMAGENT_IMPORT_API"
      else
        log_error "Failed to send OTA update notification to $VMAGENT_IMPORT_API"
      fi
    else
      log_error "VMAGENT not reachable at $VMAGENT_IMPORT_API, not pushing OTA update notification."
    fi
    log_info "📦 New Image version detected. Running full OTA update..."
    /root/scripts/feral-system-update.sh "$image_url" "$UNIQUE_ID" 9>&-
  else
    log_info "✅ Image already up-to-date. Checking for package updates..."
    /root/scripts/feral-service-update.sh "$UNIQUE_ID" 9>&-
  fi
else
  log_info "Aborting update in test mode. No updates will be applied."
fi
