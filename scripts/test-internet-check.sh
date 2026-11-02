#!/usr/bin/env bash
# Pins archiso-ff1/airootfs/root/scripts/internet-check.sh: the Google
# targets first, the mainland-China resolvers only after both fail, the old
# ping last, the first answer wins, and nothing reachable is a failure. The
# dials are faked (internet_tcp_connects, internet_ping_answers), apart from
# real dials to a local listener and to the same port once it is closed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/archiso-ff1/airootfs/root/scripts/internet-check.sh"
# shellcheck source=/dev/null
source "$HELPER"

fail() {
  printf 'test-internet-check: %s\n' "$1" >&2
  exit 1
}

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 127; }

WORK="$(mktemp -d)"
LISTENER_PID=""
cleanup() {
  if [[ -n "$LISTENER_PID" ]]; then
    kill "$LISTENER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The helper bounds each dial with coreutils `timeout`. On a host without it
# (macOS) shim it, or every real dial below would fail for the wrong reason;
# CI (Ubuntu) and the device use the real one.
if ! command -v timeout >/dev/null; then
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/timeout" <<'SHIM'
#!/usr/bin/perl
my $seconds = shift; alarm $seconds; exec @ARGV or exit 127;
SHIM
  chmod +x "$WORK/bin/timeout"
  PATH="$WORK/bin:$PATH"
fi

# Real dials, in their own shell (below, this shell fakes the dial): a local
# listener connects, and the same port with nothing listening does not.
python3 - "$WORK/port" <<'PY' &
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    s.accept()[0].close()
PY
LISTENER_PID=$!
for _ in $(seq 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
real_dial() {
  INTERNET_CHECK_TIMEOUT=2 INTERNET_CHECK_PORT="$PORT" \
    bash -c 'source "$1" && internet_tcp_connects 127.0.0.1' _ "$HELPER"
}
real_dial || fail "a dial to a local listener must connect"
kill "$LISTENER_PID"
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=""
if real_dial; then
  fail "a dial to a port with nothing listening must fail"
fi

REAL_PRIMARY=("${INTERNET_PRIMARY_TARGETS[@]}")
REAL_FALLBACK=("${INTERNET_FALLBACK_TARGETS[@]}")
[[ "${REAL_PRIMARY[*]}" == "8.8.8.8 8.8.4.4" ]] || fail "primary targets changed: ${REAL_PRIMARY[*]}"
[[ "${REAL_FALLBACK[*]}" == "223.5.5.5 1.12.12.12" ]] || fail "fallback targets changed: ${REAL_FALLBACK[*]}"

# The fake dial: REACHABLE lists the targets that connect; DIALED records
# every dial in order.
REACHABLE=""
DIALED=""
internet_tcp_connects() {
  DIALED="${DIALED:+$DIALED }$1"
  [[ " $REACHABLE " == *" $1 "* ]]
}
internet_ping_answers() {
  DIALED="${DIALED:+$DIALED }ping"
  [[ " $REACHABLE " == *" ping "* ]]
}

check() {
  local name="$1" reachable="$2" want_rc="$3" want_dialed="$4" rc=0
  REACHABLE="$reachable"
  DIALED=""
  internet_reachable || rc=$?
  [[ "$rc" == "$want_rc" ]] || fail "$name: rc $rc, want $want_rc"
  [[ "$DIALED" == "$want_dialed" ]] || fail "$name: dialed '$DIALED', want '$want_dialed'"
}

check "Google up" "8.8.8.8 8.8.4.4 223.5.5.5 1.12.12.12" 0 "8.8.8.8"
check "first Google down" "8.8.4.4 223.5.5.5" 0 "8.8.8.8 8.8.4.4"
check "mainland China" "223.5.5.5 1.12.12.12" 0 "8.8.8.8 8.8.4.4 223.5.5.5"
check "only DNSPod" "1.12.12.12" 0 "8.8.8.8 8.8.4.4 223.5.5.5 1.12.12.12"
check "TCP 443 filtered, ping answers" "ping" 0 "8.8.8.8 8.8.4.4 223.5.5.5 1.12.12.12 ping"
check "offline" "" 1 "8.8.8.8 8.8.4.4 223.5.5.5 1.12.12.12 ping"

echo "test-internet-check: ok"
