#!/usr/bin/env bash
set -euo pipefail
# The download worker recognizes exactly x.y.z and picks the highest ISO.
# Named trial artifacts are downloadable directly and have no OTA metadata.
if [[ ! $IMAGE_VERSION =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    [[ $ENVIRONMENT == Development ]] || exit 1
    echo "Direct-download trial build; keeping OTA metadata"
    exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A listing error must never look like a new branch and reset an established
# floor. The branch already exists because the signed ISO has been uploaded.
listing=$(rclone lsf "$BRANCH_ROOT" --files-only --max-depth 1)
newest=$(sed -nE 's/^(FF1|FF-X1)(-(release|demo|develop|staging|other))?(-dev)?(-qemu)?-([0-9]+[.][0-9]+[.][0-9]+)[.](iso|zip)$/\6/p' <<< "$listing" | sort -V | tail -1)
if [[ $newest != "$IMAGE_VERSION" ]]; then
    echo "Published version $IMAGE_VERSION is not the latest recognized branch image ($newest); keeping OTA metadata"
    [[ -n $newest ]] || exit 1
    exit 0
fi
if grep -Fxq version-info.json <<< "$listing"; then
    rclone copyto "$BRANCH_ROOT/version-info.json" "$work/prior"
else
    echo '{}' > "$work/prior"
fi

floor=$IMAGE_VERSION
if [[ "$ENVIRONMENT" == Development ]]; then
    # The oldest production-to-native hop qualified for this Development rail.
    floor=3.0.1
fi
jq -e --arg version "$IMAGE_VERSION" --arg floor "$floor" \
    --arg required "$UPDATE_REQUIRED" --arg runtime "$UPDATE_RUNTIME" --arg recovery "$UPDATE_RECOVERY" '
    select(type == "object")
    | .latest_version = $version
    | .min_upgradeable_version = (if $required == "true" then $version else (.min_upgradeable_version // $floor) end)
    | .min_runtime_version = (if $runtime == "true" then $version else (.min_runtime_version // $version) end)
    | if $recovery == "true" then .recovery_version = $version else . end
    | select([.latest_version,.min_upgradeable_version,.min_runtime_version] | all(type == "string" and test("^[0-9]+([.][0-9A-Za-z-]+)+$")))
' "$work/prior" > "$work/next"
rclone copyto "$work/next" "$BRANCH_ROOT/version-info.json"
