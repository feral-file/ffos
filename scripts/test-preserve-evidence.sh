#!/usr/bin/env bash
# Pins archiso-ff1/airootfs/root/scripts/ff1-preserve-evidence.sh
# (ffos-user#404), the re-flash evidence carry, on plain directories (the
# mount wrapper is exercised on hardware, not here):
#   - both evidence paths round-trip into the new root, contents intact, and
#     the stashed copy wins over what the image shipped at the same path;
#   - nothing outside the evidence paths is copied (Wi-Fi profiles stay put);
#   - a path over the remaining budget is skipped and the rest still kept, and
#     the netlog ring is kept ahead of (and apart from) the rest of ~/.logs;
#   - a partial copy keeps what it read;
#   - a root with no evidence, or no root at all, returns 0 under set -e;
#   - FF1_EVIDENCE_KEEP=0 keeps nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/archiso-ff1/airootfs/root/scripts/ff1-preserve-evidence.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The helper sizes with GNU `du -sb` and copies with `rsync -aAX`. On a
# non-GNU host (macOS) shim both so the test runs locally too; CI (Ubuntu)
# uses the real ones.
mkdir -p "$WORK/bin"
if ! du -sb "$HELPER" >/dev/null 2>&1; then
  cat > "$WORK/bin/du" <<'EOF'
#!/bin/sh
if [ "$1" = "-sb" ]; then
  find "$2" -type f -exec stat -f %z {} + | awk -v p="$2" '{s+=$1} END {print s+0 "\t" p}'
  exit 0
fi
exec /usr/bin/du "$@"
EOF
  chmod +x "$WORK/bin/du"
fi
if ! rsync -aAX "$HELPER" "$WORK/probe" >/dev/null 2>&1; then
  real_rsync="$(command -v rsync)"
  cat > "$WORK/bin/rsync" <<EOF
#!/bin/sh
[ "\$1" = "-aAX" ] && shift && set -- -a "\$@"
exec "$real_rsync" "\$@"
EOF
  chmod +x "$WORK/bin/rsync"
fi
PATH="$WORK/bin:$PATH"

fail() {
  printf 'test-preserve-evidence: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=archiso-ff1/airootfs/root/scripts/ff1-preserve-evidence.sh
source "$HELPER"

old="$WORK/old" new="$WORK/new" stash="$WORK/stash"
mkdir -p "$old/home/feralfile/.logs/netlog" "$old/home/feralfile/.state/vmagent_queue" \
  "$old/etc/NetworkManager/system-connections" "$new/home/feralfile/.logs/netlog"
echo "ring-old" > "$old/home/feralfile/.logs/netlog/ring.0"
echo "controld" > "$old/home/feralfile/.logs/controld.log"
head -c 4096 /dev/zero > "$old/home/feralfile/.state/vmagent_queue/chunk"
echo "psk=secret" > "$old/etc/NetworkManager/system-connections/home.nmconnection"
echo "ring-image" > "$new/home/feralfile/.logs/netlog/ring.0"

ff1_stash_evidence "$old" "$stash" >/dev/null
ff1_restore_evidence "$stash" "$new" >/dev/null
[[ "$(cat "$new/home/feralfile/.logs/netlog/ring.0")" == ring-old ]] || fail "the stashed netlog ring must win over the image's"
[[ "$(cat "$new/home/feralfile/.logs/controld.log")" == controld ]] || fail "the .logs directory was not restored"
cmp -s "$old/home/feralfile/.state/vmagent_queue/chunk" "$new/home/feralfile/.state/vmagent_queue/chunk" || fail "the vmagent spool was not restored intact"
[[ ! -e "$stash/etc" && ! -e "$new/etc" ]] || fail "something outside the evidence paths was copied"

# Budget: the spool (4 KiB) does not fit 1 KiB after ~/.logs; ~/.logs still does.
rm -rf "$stash" "$new"
out="$(FF1_EVIDENCE_MAX_BYTES=1024 ff1_stash_evidence "$old" "$stash")"
[[ -d "$stash/home/feralfile/.logs" ]] || fail "the .logs directory must be kept within the budget"
[[ ! -e "$stash/home/feralfile/.state/vmagent_queue" ]] || fail "an over-budget spool must be skipped"
grep -q "vmagent_queue.*skipping it" <<<"$out" || fail "the skip must be logged: $out"

# Priority (#170 review): ~/.logs ballooned by rotated controld backups is
# over budget, but the netlog ring, kept first and on its own, survives, and
# the skipped ~/.logs is not restored from the directory the stash made for it.
rm -rf "$stash" "$new"
mkdir -p "$old/home/feralfile/.logs/backup/controld" "$new/home/feralfile"
head -c 8192 /dev/zero > "$old/home/feralfile/.logs/backup/controld/controld.log.1"
FF1_EVIDENCE_MAX_BYTES=2048 ff1_stash_evidence "$old" "$stash" >/dev/null
ff1_restore_evidence "$stash" "$new" >/dev/null
[[ "$(cat "$new/home/feralfile/.logs/netlog/ring.0")" == ring-old ]] || fail "the netlog ring must survive an over-budget .logs"
[[ ! -e "$new/home/feralfile/.logs/controld.log" ]] || fail "an over-budget .logs must not be restored"
rm -rf "$old/home/feralfile/.logs/backup"

# A partial copy is kept (one unreadable file must not discard the rest).
# Root reads everything, so this case only runs unprivileged.
if (( EUID != 0 )); then
  rm -rf "$stash" "$new"
  echo "unreadable" > "$old/home/feralfile/.logs/broken.log"
  chmod 000 "$old/home/feralfile/.logs/broken.log"
  out="$(ff1_stash_evidence "$old" "$stash")"
  chmod 644 "$old/home/feralfile/.logs/broken.log"
  rm -f "$old/home/feralfile/.logs/broken.log"
  [[ "$(cat "$stash/home/feralfile/.logs/controld.log")" == controld ]] || fail "a partial copy must keep what it read"
  grep -q "\.logs only in part" <<<"$out" || fail "the partial copy must be logged: $out"
fi

# Nothing to keep, nothing stashed: every call returns 0 and touches nothing.
rm -rf "$stash" "$new"
mkdir -p "$WORK/empty" "$new"
ff1_stash_evidence "$WORK/empty" "$stash" >/dev/null || fail "stash of an empty root must return 0"
ff1_restore_evidence "$stash" "$new" >/dev/null || fail "restore of an empty stash must return 0"
ff1_restore_evidence "$WORK/no-such-stash" "$new" >/dev/null || fail "restore without a stash must return 0"
ff1_stash_evidence_from_disk "$WORK/not-a-block-device" "$stash" >/dev/null || fail "a non-device root must return 0"
[[ -z "$(ls -A "$new")" ]] || fail "an empty stash must not write into the new root"

# The operator's "no" (FF1_EVIDENCE_KEEP=0) stops the stash before it looks at
# the disk at all.
out="$(FF1_EVIDENCE_KEEP=0 ff1_stash_evidence_from_disk "$WORK/not-a-block-device" "$stash")"
grep -q "not keeping" <<<"$out" || fail "FF1_EVIDENCE_KEEP=0 must skip the stash: $out"

echo "test-preserve-evidence: ok"
