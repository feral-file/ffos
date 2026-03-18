#!/bin/bash
printf 'EARLYOOM_NAME=%s\nEARLYOOM_CMDLINE=%s\n' \
    "${EARLYOOM_NAME:-}" "${EARLYOOM_CMDLINE:-}" \
    > /run/earlyoom-hook.env
systemctl start earlyoom-hook.service