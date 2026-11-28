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

if [[ ${1:-} == --fetch ]]; then
  url=$2
  output=$3
  fetch=(curl --fail --silent --show-error --location --connect-timeout 15
         --speed-limit 1 --speed-time 60 --max-time 300 --output "$output")
  case "$url" in
    https://archive.archlinux.org/repos/*/*.pkg.tar.*|https://umea.archive.pkgbuild.com/repos/*/*.pkg.tar.*)
      file=${url##*/}
      stem=${file%.pkg.tar.*}
      name=${stem%-*-*-*}
      for host in umea.archive.pkgbuild.com archive.archlinux.org; do
        if "${fetch[@]}" "https://$host/packages/${name:0:1}/$name/$file"; then exit 0; fi
      done
      ;;
  esac
  exec "${fetch[@]}" "$url"
fi

if (( $# == 0 )); then
  echo "usage: $0 <package>..." >&2
  exit 2
fi

lock="$(pacman-conf DBPath)db.lck"
cachedir="$(pacman-conf CacheDir | head -n1)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
config=/etc/pacman.conf
for attempt in 1 2 3; do
  # On the final attempt also try the archive by exact package filename.
  if (( attempt == 3 )); then
    helper=$(realpath "$0")
    sed "/^\\[options\\]$/a XferCommand = $helper --fetch %u %o" "$config" > "$work/pacman.conf"
    config="$work/pacman.conf"
  fi
  # The cap only catches a pacman that stopped making progress without
  # failing; a large set on a slow but moving link must still fit inside it.
  if timeout 20m pacman --config "$config" -Sw --needed --noconfirm "$@"; then
    pacman --config "$config" -S --needed --noconfirm "$@"
    exit 0
  fi
  rm -f "$lock"
  # Partial files of a failed attempt: a .part from one server cannot be
  # resumed on umea ("does not support byte ranges. Cannot resume" in CI
  # logs), and a killed sandboxed download leaves its download-* directory
  # behind. Each attempt starts those files over. Packages a failed attempt
  # completed stay in the cache, except after a timeout kill: pacman never
  # moved them out of download-*, so they are fetched again.
  find "$cachedir" -maxdepth 1 -name '*.part' -delete
  find "$cachedir" -maxdepth 1 -type d -name 'download-*' -exec rm -rf {} +
  if (( attempt < 3 )); then
    echo "Package download failed (attempt $attempt/3); retrying in $((attempt * 15)) s" >&2
    sleep "$((attempt * 15))"
  fi
done
echo "::error::Package download failed after 3 attempts: $*" >&2
exit 1
