#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export BRANCH_ROOT="$work/branch" IMAGE_VERSION=3.1.4 ENVIRONMENT=Development
export UPDATE_REQUIRED=false UPDATE_RUNTIME=false UPDATE_RECOVERY=false
mkdir "$BRANCH_ROOT"
touch "$BRANCH_ROOT/FF1-dev-3.1.4.iso"
cat > "$work/rclone" <<'EOF'
#!/bin/bash
set -eu
case "$1" in
lsf) ls -1 "$2" ;;
copyto) cp "$2" "$3" ;;
*) exit 1 ;;
esac
EOF
chmod +x "$work/rclone"
export PATH="$work:$PATH"
manifest="$BRANCH_ROOT/version-info.json"
bash "$root/publish-version-info.sh"
jq -e '.latest_version=="3.1.4" and .min_upgradeable_version=="3.0.1"' "$manifest"
echo '{"recovery_version":"3.0.0","min_runtime_version":"3.0.0","min_upgradeable_version":"0.15.0"}' > "$manifest"
bash "$root/publish-version-info.sh"
jq -e '.min_upgradeable_version=="0.15.0" and .min_runtime_version=="3.0.0" and .recovery_version=="3.0.0"' "$manifest"
UPDATE_REQUIRED=true bash "$root/publish-version-info.sh"
jq -e '.min_upgradeable_version=="3.1.4"' "$manifest"
IMAGE_VERSION=3.1.3 bash "$root/publish-version-info.sh"
IMAGE_VERSION=3.1.5.rc1 bash "$root/publish-version-info.sh"
jq -e '.latest_version=="3.1.4"' "$manifest"
echo 'bad' > "$manifest"
if bash "$root/publish-version-info.sh"; then exit 1; fi
[[ $(cat "$manifest") == bad ]]
