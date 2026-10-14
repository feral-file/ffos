#!/bin/bash
# Shared ISO download for feral-system-update.sh (OTA) and
# feral-recovery-update.sh. Source it after defining log_info and log_error;
# it defines download_file_with_slow_retry and nothing else runs on source.
#
# Slow-download mitigation: Cloudflare occasionally serves an extremely slow
# connection that a fresh connection would fix. Monitor the average download
# speed over SLOW_CHECK_INTERVAL windows; if a window averages below the
# threshold, kill curl and reconnect, resuming from the current offset
# (--continue-at -). After MAX_SLOW_RETRIES reconnects the download is left to
# run at whatever speed it gets. Stall detection (< 1 KB/s for 60 s) still
# aborts a dead transfer on every attempt.
#
# Resume refused (ffos#141): until the distribution Worker (feral-file/
# ffos-distribution) honored Range, every reconnect ended in curl exit 33
# ("server does not seem to support byte ranges") and the download failed, so
# a device whose link stayed under the threshold could never update. Exit 33
# now restarts the download from zero instead, and turns slow-reconnects off
# for the rest of the run: without resume, each reconnect would throw away
# everything downloaded so far, and a slow window late in the download would
# restart a nearly finished one. The cost of a refusal is bounded to the one
# window that triggered it.
#
# Wording is load-bearing: feral-controld's otagate/classify.go (ffos-user)
# matches "Failed to download OTA image." and "Failed to download recovery
# ISO." exactly and treats them as transient. Keep "Failed to download
# $label." with the labels the two callers pass.
#
# The timing knobs take their values from the environment only so that
# scripts/test-ota-download.sh can shrink them; nothing on a device sets them.
SLOW_SPEED_THRESHOLD_KBPS="${SLOW_SPEED_THRESHOLD_KBPS:-1024}"
SLOW_CHECK_INTERVAL="${SLOW_CHECK_INTERVAL:-180}"
SLOW_POLL_INTERVAL="${SLOW_POLL_INTERVAL:-5}"
MAX_SLOW_RETRIES="${MAX_SLOW_RETRIES:-3}"

# curl's exit code when it asked to resume and the server answered 200 with
# the whole body instead of 206.
CURL_RANGE_ERROR=33

download_file_with_slow_retry() {
  local url="$1"
  local output="$2"
  local label="$3"

  local retries=0
  local min_window_bytes=$((SLOW_SPEED_THRESHOLD_KBPS * 1024 * SLOW_CHECK_INTERVAL))
  # Cleared when the server refuses a resume: from then on every attempt
  # starts from zero, so reconnecting would only discard progress.
  local resume=1

  while :; do
    log_info "Downloading $label"

    # The ${a[@]+...} form keeps an empty array legal under `set -u` on
    # every bash version.
    local resume_args=()
    if (( resume )); then
      resume_args=(--continue-at -)
    fi

    curl \
      --silent \
      --show-error \
      --fail \
      --location \
      --connect-timeout 15 \
      --speed-time 60 \
      --speed-limit 1024 \
      ${resume_args[@]+"${resume_args[@]}"} \
      "$url" \
      -o "$output" &
    local curl_pid=$!

    local slow=0
    if (( resume && retries < MAX_SLOW_RETRIES )); then
      local window_start_size window_elapsed cur_size
      window_start_size=$(stat -c %s "$output" 2>/dev/null || echo 0)
      window_elapsed=0

      while kill -0 "$curl_pid" 2>/dev/null; do
        sleep "$SLOW_POLL_INTERVAL"
        window_elapsed=$((window_elapsed + SLOW_POLL_INTERVAL))
        if (( window_elapsed < SLOW_CHECK_INTERVAL )); then
          continue
        fi
        cur_size=$(stat -c %s "$output" 2>/dev/null || echo 0)
        if (( cur_size - window_start_size < min_window_bytes )); then
          slow=1
          break
        fi
        window_start_size=$cur_size
        window_elapsed=0
      done
    fi
    # Otherwise (retry budget spent, or resume refused) this attempt runs to
    # completion, however slow it is.

    if (( slow )); then
      retries=$((retries + 1))
      local avg_kbps=$(( (cur_size - window_start_size) / SLOW_CHECK_INTERVAL / 1024 ))
      log_info "$label download is slow (~${avg_kbps} KB/s avg over ${SLOW_CHECK_INTERVAL}s, threshold ${SLOW_SPEED_THRESHOLD_KBPS} KB/s). Reconnecting and resuming (retry $retries/$MAX_SLOW_RETRIES)..."
      kill "$curl_pid" 2>/dev/null || true
      wait "$curl_pid" 2>/dev/null || true
      continue
    fi

    # curl exited on its own: success, refused resume, or hard failure.
    local rc=0
    wait "$curl_pid" || rc=$?
    if (( rc == 0 )); then
      return 0
    fi
    if (( rc == CURL_RANGE_ERROR && resume )); then
      log_info "Server refused to resume the $label download. Restarting it from the beginning; slow-speed reconnects are off for this run."
      : > "$output"
      resume=0
      continue
    fi
    log_error "Failed to download $label."
    return 1
  done
}
