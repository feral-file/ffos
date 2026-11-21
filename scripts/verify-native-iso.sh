#!/bin/bash
set -euo pipefail
iso=$1
player_version=$2
component_version=$3
shift 3
# Check the packaged filesystem from the ISO itself.
xorriso -osirrox on -indev "$iso" -extract /arch/x86_64/airootfs.sfs /build/root.sfs
unsquashfs -d /build/native-check /build/root.sfs var/lib/pacman/local home/feralfile/scripts/start-kiosk.sh home/feralfile/systemd-services usr/bin/ff-player-native usr/lib/ff-player-native usr/share/ff-player-native/ffos-worker-packages.lock
root=/build/native-check
runtime="$root/usr/lib/ff-player-native"
test -x "$runtime/ff-player-native"
test "$(stat -c %a "$runtime/chrome-sandbox")" = 4755
for retired in ff-egress ff-media-worker ff-cef-views-engine ff-cage-client ff-browser-launch ff-media-launch ff-player-import ff-player-cef-rollback; do
  test -z "$(find "$runtime" -name "$retired" -print -quit)"
done
while read -r package version; do
  test -d "$root/var/lib/pacman/local/$package-$version"
done < "$root/usr/share/ff-player-native/ffos-worker-packages.lock"
for component in "$@"; do
  test -d "$root/var/lib/pacman/local/$component-$component_version-1"
done
test -L "$root/usr/bin/ff-player-native"
test -f "$runtime/media/libff_decode.so"
test -d "$root/var/lib/pacman/local/ff-player-native-$player_version-1"
! compgen -G "$root/var/lib/pacman/local/feral-player-*" || exit 1
! compgen -G "$root/var/lib/pacman/local/ff-player-[0-9]*" || exit 1
test ! -e "$root/home/feralfile/systemd-services/feral-player.service"
grep -q '/usr/lib/ff-player-native/ff-player-native' "$root/home/feralfile/scripts/start-kiosk.sh"
