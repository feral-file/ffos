#!/bin/bash
set -eu

STATE_DIR="/var/lib/oom_state"
COUNT_FILE="$STATE_DIR/chromium-oom-kill-count"
LAST_EVENT_FILE="$STATE_DIR/chromium-oom-kill-last-event"
LOCK_FILE="$STATE_DIR/chromium-oom-kill.lock"
EVENT_DEDUP_WINDOW_SEC=3

NAME="${EARLYOOM_NAME:-}"
CMDLINE="${EARLYOOM_CMDLINE:-}"

case "$NAME:$CMDLINE" in
    chromium:*|cage:*|*:chromium*|*:cage*)
        ;;
    *)
        exit 0
        ;;
esac

mkdir -p "$STATE_DIR"

exec 9>"$LOCK_FILE"
flock -x 9

NOW="$(date +%s)"
LAST_EVENT="$(cat "$LAST_EVENT_FILE" 2>/dev/null || echo "0")"

if [ $((NOW - LAST_EVENT)) -lt "$EVENT_DEDUP_WINDOW_SEC" ]; then
    exit 0
fi

COUNT="$(cat "$COUNT_FILE" 2>/dev/null || echo "0")"
COUNT=$((COUNT + 1))

echo "$COUNT" > "$COUNT_FILE"
echo "$NOW" > "$LAST_EVENT_FILE"

logger -t ff1-earlyoom-hook "counted chromium oom kill event: count=$COUNT name=${NAME:-unknown}"
