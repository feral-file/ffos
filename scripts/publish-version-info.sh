#!/usr/bin/env bash
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A listing error must never look like a new branch and reset an established
# floor. The branch already exists because the signed ISO has been uploaded.
existing=$(rclone lsf "$BRANCH_ROOT" --files-only --include /version-info.json)
if [[ "$existing" == version-info.json ]]; then
    rclone copyto "$BRANCH_ROOT/version-info.json" "$work/prior"
elif [[ -z "$existing" ]]; then
    echo '{}' > "$work/prior"
else
    echo "Unexpected version manifest listing" >&2
    exit 1
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
