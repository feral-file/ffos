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

log "Checking README workflow inventory"
while IFS= read -r workflow; do
  grep -q "$(basename "$workflow")" README.md || {
    printf 'README.md does not mention %s\n' "$workflow" >&2
    exit 1
  }
done < <(find .github/workflows -maxdepth 1 -type f | sort)

log "Verification complete"
