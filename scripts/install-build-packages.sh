#!/usr/bin/env bash
set -euo pipefail

# pacman still selects the version, checks its digest and verifies the package
# signature. An alternate URL is only a mirror for that exact file.
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

# Retry only downloads. An interrupted installation must never be repeated
# blindly. On retry fetch from the filename archive without relying on Range.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
config=/etc/pacman.conf
for attempt in 1 2 3; do
  if (( attempt == 2 )); then
    helper=$(realpath "$0")
    sed "/^\[options\]$/a XferCommand = $helper --fetch %u %o" "$config" > "$work/pacman.conf"
    config="$work/pacman.conf"
  fi
  if timeout 5m pacman --config "$config" -Sw --needed --noconfirm --disable-download-timeout "$@"; then
    pacman --config "$config" -S --needed --noconfirm "$@"
    exit 0
  fi
  if (( attempt < 3 )); then
    echo "Package download failed (attempt $attempt/3); retrying" >&2
    sleep "$((attempt * 5))"
  fi
done
exit 1
