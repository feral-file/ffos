#!/bin/bash
set -euo pipefail
iso=$1
player_version=$2
component_version=$3
shift 3
# Historical tag builds verify the name in that profile's package manifest.
display=${NATIVE_DISPLAY_PACKAGE:-feral-display}
case "$display" in
  feral-display) other=ff-player-native ;;
  ff-player-native) other=feral-display ;;
  *) echo "Unexpected native display package: $display" >&2; exit 1 ;;
esac
# Check the packaged filesystem from the ISO itself.
xorriso -osirrox on -indev "$iso" -extract /arch/x86_64/airootfs.sfs /build/root.sfs
unsquashfs -d /build/native-check /build/root.sfs etc/pacman.conf var/lib/pacman/local home/feralfile/scripts/start-kiosk.sh home/feralfile/systemd-services "usr/bin/$display" "usr/lib/$display" "usr/share/$display/ffos-worker-packages.lock"
root=/build/native-check
# Legacy kiosks poll the old branch index before they receive a full image.
# Only a booted native image may discover the socket-only daemon packages.
grep -Eq '^Server = https://[^ ]+/native/os/\$arch$' "$root/etc/pacman.conf"
runtime="$root/usr/lib/$display"
test -x "$runtime/$display"
test "$(stat -c %a "$runtime/chrome-sandbox")" = 4755
for retired in ff-egress ff-media-worker ff-cef-views-engine ff-cage-client ff-browser-launch ff-media-launch ff-player-import ff-player-cef-rollback; do
  test -z "$(find "$runtime" -name "$retired" -print -quit)"
done
while read -r package version; do
  test -d "$root/var/lib/pacman/local/$package-$version"
done < "$root/usr/share/$display/ffos-worker-packages.lock"
for component in "$@"; do
  test -d "$root/var/lib/pacman/local/$component-$component_version-1"
done
test -L "$root/usr/bin/$display"
test -f "$runtime/media/libff_decode.so"
test -d "$root/var/lib/pacman/local/$display-$player_version-1"
! compgen -G "$root/var/lib/pacman/local/$other-*" || exit 1
! compgen -G "$root/var/lib/pacman/local/feral-player-*" || exit 1
! compgen -G "$root/var/lib/pacman/local/ff-player-[0-9]*" || exit 1
test ! -e "$root/home/feralfile/systemd-services/feral-player.service"
grep -Fq "/usr/lib/$display/$display" "$root/home/feralfile/scripts/start-kiosk.sh"
