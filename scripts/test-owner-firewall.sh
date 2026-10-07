#!/usr/bin/env bash
# Run only in an isolated user/network namespace; create packet paths there.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(readlink /proc/self/ns/net) != $(readlink /proc/1/ns/net) ]] || {
    echo 'Run with: unshare -Urn -- scripts/test-owner-firewall.sh' >&2
    exit 1
}
ROOT=$(pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=archiso-ff1/airootfs/usr/local/bin/feral-tailscale
source "$ROOT/archiso-ff1/airootfs/usr/local/bin/feral-tailscale"
STATE_DIR="$TEST_DIR/state"
ROOT_MARKER="$TEST_DIR/root-marker"
mkdir -p "$STATE_DIR"
touch "$ROOT_MARKER" "$STATE_DIR/enabled"
printf '100.100.1.2\n' > "$STATE_DIR/owner-ip"

# Representative unrelated tables must survive every FF reload/stop operation.
nft add table inet tailscale_test
nft add table ip nm_shared_test
guard
nft -f archiso-ff1/airootfs/etc/nftables.conf
nft -f archiso-ff1/airootfs/etc/nftables.conf
guard
nft delete table ip feral_captive
nft list table inet tailscale_test >/dev/null
nft list table ip nm_shared_test >/dev/null
nft list table inet feral_owner >/dev/null
nft -f archiso-ff1/airootfs/etc/nftables.conf

# A TUN device injects actual IPv4 TCP SYN packets into the input hook without
# any external network or a real Tailscale connection. Counters after our early
# guard show which packets reached a later chain (including an earlier ACCEPT).
ip link set lo up
ip tuntap add dev tailscale0 mode tun
ip addr add 100.100.1.3/32 dev tailscale0
ip link set tailscale0 up
ip route add 100.64.0.0/10 dev tailscale0
nft 'add table inet observer'
nft 'add chain inet observer input { type filter hook input priority 10; policy accept; }'
nft 'add rule inet observer input iifname "tailscale0" tcp dport 1111 counter'
nft 'add rule inet observer input iifname "tailscale0" tcp dport 2222 counter'
nft 'add rule inet observer input iifname "tailscale0" tcp dport 22 counter'
# Prove an earlier ACCEPT cannot override our later DROP.
nft 'add table inet permissive'
nft 'add chain inet permissive input { type filter hook input priority -20; policy accept; }'
nft 'add rule inet permissive input accept'
python3 - <<'PY'
import fcntl, os, socket, struct, subprocess, time
fd = os.open('/dev/net/tun', os.O_RDWR)
fcntl.ioctl(fd, 0x400454ca, struct.pack('16sH', b'tailscale0', 0x0001 | 0x1000))
def checksum(data):
    values = struct.unpack('!%dH' % (len(data)//2), data)
    total = sum(values)
    while total >> 16: total = (total & 0xffff) + (total >> 16)
    return (~total) & 0xffff

def inject(source, port):
    src, dst = socket.inet_aton(source), socket.inet_aton('100.100.1.3')
    tcp = struct.pack('!HHLLBBHHH', 45000, port, 1, 0, 80, 2, 1024, 0, 0)
    pseudo = src + dst + struct.pack('!BBH', 0, 6, len(tcp))
    tcp = tcp[:16] + struct.pack('!H', checksum(pseudo + tcp)) + tcp[18:]
    ip = struct.pack('!BBHHHBBH4s4s', 69, 0, 40, 1, 0, 64, 6, 0, src, dst)
    ip = ip[:10] + struct.pack('!H', checksum(ip)) + ip[12:]
    os.write(fd, ip + tcp)
for address in ['100.100.1.2', '100.100.1.9']:
    for port in [1111, 2222, 22]: inject(address, port)
time.sleep(.1)
import json
rules = json.loads(subprocess.check_output(['nft', '-j', 'list', 'chain', 'inet', 'observer', 'input']))
counts = [e['counter']['packets'] for item in rules['nftables'] if 'rule' in item for e in item['rule']['expr'] if 'counter' in e]
assert counts == [1, 1, 0], counts
os.close(fd)
PY
rm "$STATE_DIR/enabled"
guard
# Revocation removes the allow rule without destroying any unrelated table.
if nft list table inet feral_owner | grep -q 'ip saddr'; then
    echo 'Revoked owner still has an allow rule' >&2
    exit 1
fi
nft list table inet tailscale_test >/dev/null
nft list table ip nm_shared_test >/dev/null
printf 'Firewall reload, service-stop and packet-filter checks passed.\n'
