#!/usr/bin/env bash
# install-build-packages.sh installs build tooling into a CI container from the
# pinned Arch snapshot, surviving the Arch Linux Archive's intermittent stalls.
#
# Usage: install-build-packages.sh <package>...
#
# Why: GitHub-hosted runners repeatedly lose single downloads from
# archive.archlinux.org ("Operation too slow", "Connection timed out"), and a
# bare `pacman -S` fails the whole job on the first one. setup-pacman lists a
# second archive server, so pacman already tries it for a failed file; this
# script adds attempts on top, for when both servers drop the same download.
#
# Invariant: only the download phase (`pacman -Sw`) is retried. Files that
# arrived stay in pacman's cache, so each attempt fetches only what is still
# missing. The signed install transaction then runs exactly once, from the
# cache, so a retry can never half-apply an install.
set -euo pipefail

if (( $# == 0 )); then
  echo "usage: $0 <package>..." >&2
  exit 2
fi

for attempt in 1 2 3; do
  if timeout 5m pacman -Sw --needed --noconfirm --disable-download-timeout "$@"; then
    exec pacman -S --needed --noconfirm "$@"
  fi
  if (( attempt < 3 )); then
    echo "Package download failed (attempt $attempt/3); retrying in $((attempt * 15)) s" >&2
    sleep "$((attempt * 15))"
  fi
done
echo "::error::Package download failed after 3 attempts: $*" >&2
exit 1
