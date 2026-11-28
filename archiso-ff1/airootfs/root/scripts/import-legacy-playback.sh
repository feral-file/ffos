#!/usr/bin/env bash
set -euo pipefail
# One-shot candidate boot leaves the previous root as Btrfs default. The
# private read-only mount lives only until this process exits. Nothing here
# can write to the rollback profile or publish new EFI boot files.
previous=$(mktemp -d /run/ff1-previous.XXXXXX)
trap 'umount "$previous" 2>/dev/null || true; rmdir "$previous"' EXIT
mount -o ro "$1" "$previous"
if [[ -d "$previous/usr/lib/feral-display" || -d "$previous/usr/lib/ff-player-native" ]]; then exit 0; fi
ip link set lo up
playback=$(runuser -u feralfile -- env HOME=/home/feralfile python3 \
    /home/feralfile/scripts/migrate-legacy-playback.py "$previous/home/feralfile/.config/chromium/Default")
if [[ $playback =~ ^[0-9a-f]{64}[[:blank:]][0-9]{1,4}[[:blank:]][0-9a-f]{64}$ ]]; then
    printf '%s\n' "$playback" > /etc/FF_OS_OTA_EXPECT_PLAYBACK
    echo "Legacy playback migration: active"
elif [[ $playback == idle || $playback == skip ]]; then
    echo "Legacy playback migration: $playback"
else
    echo "Unrecognized playback migration result" >&2
    exit 1
fi
