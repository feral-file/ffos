#!/usr/bin/env bash
# apply.sh <profile>: turn a copy of the archiso-ff1 profile into the factory
# ISO (build-image-to-cf.yml input factory_check; ffos-user#476).
#
# The factory ISO boots straight into the Factory check entry with no key
# pressed: the line plugs the stick into a bare board and powers it on. Every
# other entry is removed rather than only moved down: the default entry of the
# normal ISO, Auto Install, wipes the NVMe without asking, so a factory stick
# that can install at all could wipe a unit by a stray key. The check itself
# runs in kmscon so its Chinese lines can be drawn (airootfs/ here).
set -euo pipefail

profile=${1:?usage: apply.sh <archiso profile dir>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
entries="$profile/efiboot/loader/entries"
loader="$profile/efiboot/loader/loader.conf"
factory=archiso-x86_64-linux-factory-check.conf

[ -f "$entries/$factory" ] || { echo "apply.sh: no $entries/$factory" >&2; exit 1; }
for entry in "$entries"/*.conf; do
  [ "$(basename "$entry")" = "$factory" ] || rm -f "$entry"
done
sed -i "s/^default .*/default $factory/" "$loader"
grep -qx "default $factory" "$loader" || { echo "apply.sh: $loader does not default to $factory" >&2; exit 1; }
# timeout 0 (from the profile): no menu, the default boots at once.
grep -qx 'timeout 0' "$loader" || { echo "apply.sh: $loader would show a menu" >&2; exit 1; }

cp -a "$here/airootfs/." "$profile/airootfs/"
cat "$here/packages.x86_64" >>"$profile/packages.x86_64"
