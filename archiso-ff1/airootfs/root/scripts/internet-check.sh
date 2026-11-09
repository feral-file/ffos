#!/bin/bash
# Shared "is the internet up?" check for feral-updater.sh (OTA) and
# feral-recovery-update.sh. Source it; it defines internet_reachable and
# nothing runs on source.
#
# Same targets and staging as feral-sys-monitord's probe (ffos-user
# components/feral-sys-monitord/connectivity.go): a TCP connect to port 443
# of the Google resolvers first, and only when both fail, of the AliDNS and
# DNSPod resolvers. The Google prefixes are blocked on every mainland-China
# network (feral-file#3539, #3453), so a check that dials only them (the
# `ping 8.8.8.8` these scripts used) skipped every OTA and recovery update
# there, and left the reset-target gauge `unknown` (ffos-user
# docs/ff1-control-v1.md §15.4 Gate B). The mainland resolvers are a
# fallback, not peers: dialing Chinese infrastructure from every device
# worldwide is what enterprise and venue IDS/GeoIP policies flag, so it
# happens only where Google already failed. TCP, not ICMP, also passes
# networks that drop ping. The old ping of 8.8.8.8 stays as the last try, so
# a network that blocks TCP 443 to public resolvers (DoH filtering) but
# answers ping still counts as online, as it did before: this check may only
# turn a false "offline" into "online", never the reverse.
#
# INTERNET_CHECK_TIMEOUT (seconds per dial) and INTERNET_CHECK_PORT come
# from the environment only so that scripts/test-internet-check.sh can shrink
# the one and dial a local listener with the other; nothing on a device sets
# them.

INTERNET_PRIMARY_TARGETS=(8.8.8.8 8.8.4.4)
INTERNET_FALLBACK_TARGETS=(223.5.5.5 1.12.12.12)

# internet_tcp_connects reports whether a TCP connect to $1:443 completes
# within INTERNET_CHECK_TIMEOUT seconds. Nothing is sent.
internet_tcp_connects() {
  timeout "${INTERNET_CHECK_TIMEOUT:-3}" bash -c "exec 3<>/dev/tcp/$1/${INTERNET_CHECK_PORT:-443}" 2>/dev/null
}

# internet_reachable succeeds when any target accepts a TCP connect.
internet_reachable() {
  local target
  for target in "${INTERNET_PRIMARY_TARGETS[@]}"; do
    internet_tcp_connects "$target" && return 0
  done
  for target in "${INTERNET_FALLBACK_TARGETS[@]}"; do
    internet_tcp_connects "$target" && return 0
  done
  internet_ping_answers
}

# internet_ping_answers is the check these scripts made before (ICMP to
# 8.8.8.8, 2 s).
internet_ping_answers() {
  ping -q -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
}
