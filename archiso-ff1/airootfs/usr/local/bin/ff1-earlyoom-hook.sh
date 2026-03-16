#!/bin/bash
# Trigger wrapper: spawns ff1-earlyoom-hook-impl.sh as a root systemd transient
# service to avoid permission restrictions inside earlyoom's sandbox.
set -eu

systemd-run --no-block \
    --description="FF1 earlyoom OOM kill hook" \
    --service-type=oneshot \
    -E EARLYOOM_NAME="${EARLYOOM_NAME:-}" \
    -E EARLYOOM_CMDLINE="${EARLYOOM_CMDLINE:-}" \
    /usr/local/bin/ff1-earlyoom-hook-impl.sh
