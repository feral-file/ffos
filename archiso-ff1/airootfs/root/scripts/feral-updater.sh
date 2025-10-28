#!/bin/bash
set -euo pipefail

log_info() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [INFO] id=$UNIQUE_ID message=\"$message\""
}

log_error() {
  local message="$1"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [ERROR] id=$UNIQUE_ID message=\"$message\""
}

trap 'code=$?; log_error "EXCEPTION ERR: LINE=$LINENO CMD=\"$BASH_COMMAND\""; exit $code' ERR

# Accept UNIQUE_ID from argument, or default to current UNIX timestamp
if [[ $# -ge 1 && -n "$1" ]]; then
  UNIQUE_ID="$1"
else
  UNIQUE_ID="$(date +%s)"
fi

if [[ "${FLOCK_ACTIVE:-}" != "1" ]]; then
  if ! /usr/bin/flock -n /run/feral-updater.lock bash -c 'exec env FLOCK_ACTIVE=1 "$0" "$@"' "$0" "$@"; then
    log_error "Exception: either Lock already held by another instance or some error happened."
    exit 0
  fi
fi

if ! ping -q -c 1 -W 2 8.8.8.8 >/dev/null; then
  log_error "No network connection. Aborting update."
  exit 0
fi

ENV_MODE="test"
if [[ -r /home/feralfile/.state/environment ]]; then
  ENV_MODE="$(cat /home/feralfile/.state/environment 2>/dev/null | xargs)"
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
  response=$(curl -s -f "$API_URL")
  latest_version=$(jq -r '.latest_version' <<< "$response")
  image_url=$(jq -r '.image_url' <<< "$response")

  log_info "🆚 Current: $current_version  →  Remote: $latest_version"
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
    exec /root/scripts/feral-system-update.sh "$image_url" "$UNIQUE_ID"
  else
    log_info "✅ Image already up-to-date. Checking for package updates..."
    exec /root/scripts/feral-service-update.sh "$UNIQUE_ID"
  fi
else
  log_info "Aborting update in test mode. No updates will be applied."
fi
