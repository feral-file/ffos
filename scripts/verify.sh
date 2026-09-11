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

# Shell files under packages/ (PKGBUILD helpers) join the gate by discovery so
# a new package cannot land an unchecked script.
mapfile -t package_shell_files < <(find packages -type f -name '*.sh' | sort)

log "Checking shell syntax"
bash -n scripts/verify.sh scripts/agent-iso-build-guard.sh scripts/test-agent-iso-build-guard.sh archiso-ff1/profiledef.sh "${package_shell_files[@]}"

log "Running shellcheck"
shellcheck scripts/verify.sh scripts/agent-iso-build-guard.sh scripts/test-agent-iso-build-guard.sh archiso-ff1/profiledef.sh "${package_shell_files[@]}"

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

log "Checking agent ISO build guard"
# AGENTS.md "Release guardrail: ISO image builds": the pre-shell hook that
# blocks release/Production ISO dispatches and escalates staging, wired for
# Claude Code, Codex, Cursor, Gemini CLI, and OpenCode. The test pins its
# decisions and that every tool's config still points at it, since a dropped
# hook entry would fail open with no error anywhere. The doc check pins that
# the rule the hooks enforce is still stated where agents read it.
./scripts/test-agent-iso-build-guard.sh
for cfg in .claude/settings.json .codex/hooks.json .cursor/hooks.json .gemini/settings.json; do
  ruby -rjson -e 'JSON.parse(File.read(ARGV[0]))' "$cfg" || {
    printf '%s is not valid JSON\n' "$cfg" >&2
    exit 1
  }
done
# Every workflow_dispatch workflow in this repo publishes to R2 under the
# dispatch branch's prefix, so every one of them must be named in the guard's
# workflow regex. Discovered, not hardcoded, so a new dispatchable workflow
# cannot land unguarded: adding one means adding it to the guard (both repos)
# and its tests in the same change. verify.yml is the one dispatchable
# workflow that publishes nothing.
guard_regex_line="$(grep -E "^guarded_workflow_re=" scripts/agent-iso-build-guard.sh)"
[[ -n "$guard_regex_line" ]] || {
  printf 'scripts/agent-iso-build-guard.sh no longer defines guarded_workflow_re\n' >&2
  exit 1
}
while IFS= read -r workflow; do
  stem="$(basename "$workflow")"
  stem="${stem%.yml}"; stem="${stem%.yaml}"
  [[ "$stem" == "verify" ]] && continue
  printf '%s' "$guard_regex_line" | grep -Fq "$stem" || {
    printf '%s is workflow_dispatch-triggered but not listed in guarded_workflow_re in scripts/agent-iso-build-guard.sh (and its ffos-user lockstep copy)\n' "$workflow" >&2
    exit 1
  }
done < <(grep -lE '^[[:space:]]+workflow_dispatch:' .github/workflows/*.yml .github/workflows/*.yaml | sort)
for doc in AGENTS.md CLAUDE.md GEMINI.md .cursor/rules/release-iso-build-policy.mdc; do
  grep -q 'Release guardrail: ISO image builds' "$doc" || {
    printf '%s lost the "Release guardrail: ISO image builds" section\n' "$doc" >&2
    exit 1
  }
done

log "Checking README workflow inventory"
while IFS= read -r workflow; do
  grep -q "$(basename "$workflow")" README.md || {
    printf 'README.md does not mention %s\n' "$workflow" >&2
    exit 1
  }
done < <(find .github/workflows -maxdepth 1 -type f | sort)

log "Verification complete"
