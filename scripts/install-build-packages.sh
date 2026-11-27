#!/usr/bin/env bash
# install-build-packages.sh installs build tooling into a CI container from the
# pinned Arch snapshot, surviving the Arch Linux Archive's intermittent stalls.
#
# Usage: install-build-packages.sh <package>...
#
# Why: GitHub-hosted runners repeatedly lose single downloads from
# archive.archlinux.org ("Operation too slow", "Connection timed out"), and a
# bare `pacman -S` fails the whole job on the first one. setup-pacman lists a
# second archive server; pacman's own 10 s connect and stall checks move a
# failing file to it. This script adds whole attempts on top, for when both
# servers drop the same download.
#
# Do NOT call this from build-image-from-tags.yml: that workflow checks ffos out
# at an older tag, where this file does not exist (scripts/verify.sh pins it).
#
# Invariants:
# - Never pass --disable-download-timeout. It turns off pacman's stall check,
#   and with it the failover to the second server for "Operation too slow".
# - Only the download phase (`pacman -Sw`) is retried. The signed install
#   transaction then runs exactly once, from the cache.
# - `timeout` kills pacman with SIGTERM, which pacman does not handle, so its
#   database lock survives the kill; it is removed before the next attempt.
#   Safe because this script is the only pacman running in the job's container.
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 <package>..." >&2
  exit 2
fi

lock="$(pacman-conf DBPath)db.lck"
cachedir="$(pacman-conf CacheDir | head -n1)"

for attempt in 1 2 3; do
  # The cap only catches a pacman that stopped making progress without
  # failing; a large set on a slow but moving link must still fit inside it.
  if timeout 20m pacman -Sw --needed --noconfirm "$@"; then
    exec pacman -S --needed --noconfirm "$@"
  fi
  rm -f "$lock"
  # Partial files of a failed attempt: a .part from one server cannot be
  # resumed on umea (no byte ranges), and a killed sandboxed download leaves
  # its download-* directory behind. Each attempt starts those files over;
  # completed packages stay in the cache.
  find "$cachedir" -maxdepth 1 -name '*.part' -delete
  find "$cachedir" -maxdepth 1 -type d -name 'download-*' -exec rm -rf {} +
  if (( attempt < 3 )); then
    echo "Package download failed (attempt $attempt/3); retrying in $((attempt * 15)) s" >&2
    sleep "$((attempt * 15))"
  fi
done
echo "::error::Package download failed after 3 attempts: $*" >&2
exit 1
