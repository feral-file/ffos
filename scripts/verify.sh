#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log() {
  printf '==> %s\n' "$1"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 127
  fi
}

require_tool bash
require_tool ruby
require_tool shellcheck

log "Checking shell syntax"
bash -n scripts/verify.sh archiso-ff1/profiledef.sh

log "Running shellcheck"
shellcheck scripts/verify.sh archiso-ff1/profiledef.sh

log "Validating GitHub workflow YAML"
ruby <<'RUBY'
require "yaml"

paths = Dir[".github/workflows/*.{yml,yaml}"].sort
abort "No GitHub workflows found" if paths.empty?

paths.each do |path|
  data = YAML.load(File.read(path))
  unless data.is_a?(Hash)
    abort "#{path}: expected top-level YAML mapping"
  end

  missing = []
  missing << "name" unless data.key?("name")
  missing << "on" unless data.key?("on") || data.key?(true)
  missing << "jobs" unless data.key?("jobs")
  abort "#{path}: missing #{missing.join(", ")}" unless missing.empty?
end

puts "Validated #{paths.length} workflow files."
RUBY

log "Checking verification workflow contract"
grep -q "scripts/verify.sh" .github/workflows/verify.yml
grep -q "^verify:" Makefile
grep -q "make verify" README.md

log "Checking offline-cache OTA persistence contract"
# Two halves of one invariant, both checkable in this repo. Unpinned, a drift
# would silently destroy the offline artwork blob store on every full-image OTA
# — no error and no failing build, just up to 80 GB of re-downloads and headless
# re-captures for the device owner. That silence is why this is pinned here.
# See docs/SNAPSHOT_SYSTEM_V2_FLOW.md, "What survives an OTA".
OTA_UPDATE_SCRIPT="archiso-ff1/airootfs/root/scripts/feral-system-update.sh"
# Anchored to the --exclude= line, not the whole file: the surrounding comment
# block quotes this path several times, so an unanchored grep could be satisfied
# by prose after the entry itself was dropped from the list.
grep -q -- '--exclude=.*"/home/feralfile/\.cache"' "$OTA_UPDATE_SCRIPT" || {
  printf '%s: rsync --exclude list must contain "/home/feralfile/.cache"\n' \
    "$OTA_UPDATE_SCRIPT" >&2
  exit 1
}
# Discovered rather than hardcoded so a new build workflow is covered
# automatically. The emptiness guard is load-bearing: process substitution
# discards grep's exit status, so without it a renamed config key would leave
# the loop with nothing to iterate and this check would pass silently — the
# exact failure mode it exists to catch.
# The `|| true` is required, not defensive: grep exits 1 on zero matches, and
# under `set -euo pipefail` that aborts the script at this assignment — failing
# closed, but with no diagnostic. Swallowing it here lets the explicit check
# below report WHY the build failed.
offline_cache_workflows="$(grep -rl "offlineCache" .github/workflows | sort || true)"
if [[ -z "$offline_cache_workflows" ]]; then
  printf 'no .github/workflows file mentions offlineCache, so the rootDir check cannot run; if the config key was renamed, update this check too\n' >&2
  exit 1
fi
while IFS= read -r workflow; do
  grep -q 'rootDir: "/home/feralfile/\.cache/' "$workflow" || {
    printf '%s: offlineCache.rootDir must live under /home/feralfile/.cache/\n' \
      "$workflow" >&2
    exit 1
  }
done <<< "$offline_cache_workflows"

log "Checking README workflow inventory"
while IFS= read -r workflow; do
  grep -q "$(basename "$workflow")" README.md || {
    printf 'README.md does not mention %s\n' "$workflow" >&2
    exit 1
  }
done < <(find .github/workflows -maxdepth 1 -type f | sort)

log "Verification complete"
