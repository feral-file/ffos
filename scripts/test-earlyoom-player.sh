#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
# Redirect only the fixed state directory in a private test copy. Never write
# the machine's actual OOM counters while exercising the production hook.
sed "s|STATE_DIR=\"/var/lib/oom_state\"|STATE_DIR=\"$test_root/state\"|" \
  "$root/archiso-ff1/airootfs/root/scripts/earlyoom-hook.sh" > "$test_root/hook.sh"
grep -Fq "STATE_DIR=\"$test_root/state\"" "$test_root/hook.sh"
mkdir -p "$test_root/bin" "$test_root/state"
printf '#!/bin/sh\nexit 0\n' > "$test_root/bin/logger"
chmod +x "$test_root/bin/logger"
export PATH="$test_root/bin:$PATH"
count=0
for name in chrome chromium ff-media-worker ff-player-nativ feral-display cage; do
  echo 0 > "$test_root/state/chromium-oom-kill-last-event"
  EARLYOOM_NAME="$name" EARLYOOM_CMDLINE="/$name" bash "$test_root/hook.sh"
  count=$((count+1))
  test "$(cat "$test_root/state/chromium-oom-kill-count")" = "$count"
done
EARLYOOM_NAME=unrelated EARLYOOM_CMDLINE=/usr/bin/unrelated bash "$test_root/hook.sh"
test "$(cat "$test_root/state/chromium-oom-kill-count")" = "$count"
EARLYOOM_NAME=chrome EARLYOOM_CMDLINE=/engine/chrome bash "$test_root/hook.sh"
test "$(cat "$test_root/state/chromium-oom-kill-count")" = "$count"
grep -Fq -- "--prefer '^(chrome|chromium|ff-media-worker)$'" "$root/archiso-ff1/airootfs/etc/systemd/system/earlyoom.service.d/override.conf"
grep -Fq -- "--avoid '^(ff-player-nativ|feral-|systemd)'" "$root/archiso-ff1/airootfs/etc/systemd/system/earlyoom.service.d/override.conf"
echo 'Native player/engine OOM accounting, dedup and recovery preference passed'
