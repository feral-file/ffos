#!/usr/bin/env bash
# Pins archiso-ff1/airootfs/root/scripts/ota-download.sh (ffos#141) against a
# local HTTP server that can throttle and can refuse byte ranges, the way the
# distribution Worker did before it honored Range:
#   - fast link: one request, no reconnects;
#   - slow link, Range honored: reconnects resume (206) and the file is intact;
#   - slow link, Range refused: one refused resume, then a single fresh
#     download runs to completion (no further reconnects);
#   - missing file: "Failed to download <label>." and a non-zero return.
# Timing knobs are shrunk through the environment so a run takes seconds.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/archiso-ff1/airootfs/root/scripts/ota-download.sh"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 127; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 127; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The helper measures progress with GNU `stat -c %s`. On a non-GNU host
# (macOS) shim it so the test runs locally too; CI (Ubuntu) uses the real one.
if ! stat -c %s "$HELPER" >/dev/null 2>&1; then
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/stat" <<'EOF'
#!/bin/sh
[ "$1" = "-c" ] && [ "$2" = "%s" ] && exec /usr/bin/stat -f %z "$3"
exec /usr/bin/stat "$@"
EOF
  chmod +x "$WORK/bin/stat"
  PATH="$WORK/bin:$PATH"
fi

# 600 KiB payload. The server logs one line per GET: "<range-header> <status>".
head -c 614400 /dev/urandom > "$WORK/image.iso"
cat > "$WORK/server.py" <<'EOF'
import http.server, os, re, sys, time

root, log_path, port_path = sys.argv[1], sys.argv[2], sys.argv[3]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        # Path shape: /<mode>/<rate_kib_per_s>/<file>; mode "range" honors
        # Range, "norange" always answers 200 with the whole body.
        _, mode, rate, name = self.path.split("/", 3)
        path = os.path.join(root, name)
        rng = self.headers.get("Range")
        if not os.path.exists(path):
            self.send_response(404); self.end_headers()
            with open(log_path, "a") as f: f.write(f"{rng} 404\n")
            return
        data = open(path, "rb").read()
        status, start = 200, 0
        m = re.fullmatch(r"bytes=(\d+)-", rng or "")
        if mode == "range" and m:
            status, start = 206, int(m.group(1))
        with open(log_path, "a") as f: f.write(f"{rng} {status}\n")
        body = data[start:]
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{len(data)-1}/{len(data)}")
        self.end_headers()
        chunk = int(rate) * 1024 // 10
        try:
            for i in range(0, len(body), chunk):
                self.wfile.write(body[i:i + chunk]); self.wfile.flush()
                time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            pass

s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(port_path, "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
python3 "$WORK/server.py" "$WORK" "$WORK/requests.log" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$WORK/port")"

# A window of 2 s at a 200 KiB/s threshold: a 100 KiB/s link is "slow".
export SLOW_SPEED_THRESHOLD_KBPS=200 SLOW_CHECK_INTERVAL=2 SLOW_POLL_INTERVAL=1 MAX_SLOW_RETRIES=3

fail() { echo "FAIL: $*" >&2; exit 1; }

# run_case <name> <url> -> sets RC; output in $WORK/<name>.{out,log}
run_case() {
  local name="$1" url="$2"
  : > "$WORK/requests.log"
  rm -f "$WORK/$name.out"
  RC=0
  (
    # Called by the sourced helper, which shellcheck does not follow.
    # shellcheck disable=SC2329
    log_info() { echo "INFO $1"; }
    # shellcheck disable=SC2329
    log_error() { echo "ERROR $1"; }
    # shellcheck source=/dev/null
    source "$HELPER"
    download_file_with_slow_retry "$url" "$WORK/$name.out" "OTA image"
  ) > "$WORK/$name.log" 2>&1 || RC=$?
  cp "$WORK/requests.log" "$WORK/$name.requests"
}

same_file() { cmp -s "$WORK/image.iso" "$1"; }

echo "== fast link"
run_case fast "$BASE/range/4096/image.iso"
(( RC == 0 )) || fail "fast: rc=$RC"; same_file "$WORK/fast.out" || fail "fast: corrupt"
[[ "$(wc -l < "$WORK/fast.requests")" -eq 1 ]] || fail "fast: expected one request"
! grep -q "slow" "$WORK/fast.log" || fail "fast: reconnected"

echo "== slow link, Range honored"
run_case slow_range "$BASE/range/100/image.iso"
(( RC == 0 )) || { cat "$WORK/slow_range.log"; fail "slow_range: rc=$RC"; }
same_file "$WORK/slow_range.out" || fail "slow_range: corrupt"
grep -q "retry 1/3" "$WORK/slow_range.log" || fail "slow_range: never reconnected"
grep -q " 206$" "$WORK/slow_range.requests" || fail "slow_range: no resumed request"
! grep -q "Restarting" "$WORK/slow_range.log" || fail "slow_range: restarted from zero"

echo "== slow link, Range refused"
run_case slow_norange "$BASE/norange/100/image.iso"
(( RC == 0 )) || { cat "$WORK/slow_norange.log"; fail "slow_norange: rc=$RC"; }
same_file "$WORK/slow_norange.out" || fail "slow_norange: corrupt"
[[ "$(grep -c "retry " "$WORK/slow_norange.log")" -eq 1 ]] || fail "slow_norange: expected exactly one reconnect"
grep -q "Server refused to resume the OTA image download" "$WORK/slow_norange.log" || fail "slow_norange: refusal not logged"
# initial (no Range) + refused resume + fresh restart (no Range).
[[ "$(wc -l < "$WORK/slow_norange.requests")" -eq 3 ]] || { cat "$WORK/slow_norange.requests"; fail "slow_norange: expected 3 requests"; }
[[ "$(tail -n1 "$WORK/slow_norange.requests")" == "None 200" ]] || fail "slow_norange: restart still sent Range"

echo "== missing file"
run_case missing "$BASE/range/4096/nope.iso"
(( RC == 1 )) || fail "missing: rc=$RC"
grep -qx "ERROR Failed to download OTA image." "$WORK/missing.log" || fail "missing: classify.go message changed"

echo "ota-download: all cases passed"
