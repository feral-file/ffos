#!/usr/bin/env bash
set -euo pipefail

# Archive mirrors sometimes stall on detached signatures. Retry the download
# phase only; let the final signed package transaction run exactly once.
for attempt in 1 2 3; do
  if timeout 5m pacman -Sw --needed --noconfirm --disable-download-timeout "$@"; then
    exec pacman -S --needed --noconfirm "$@"
  fi
  if (( attempt < 3 )); then
    echo "Package download failed (attempt $attempt/3); retrying" >&2
    sleep "$((attempt * 5))"
  fi
done
exit 1
