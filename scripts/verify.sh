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
# One file per invocation: `bash -n a b` parses only a and treats b as a
# positional parameter, so a multi-file call silently checks the first file.
for f in scripts/verify.sh scripts/agent-iso-build-guard.sh scripts/test-agent-iso-build-guard.sh scripts/verify-agent-hooks-e2e.sh scripts/codex-hook-trust.sh scripts/agent-branch-flow-guard.sh scripts/test-agent-branch-flow-guard.sh archiso-ff1/profiledef.sh "${package_shell_files[@]}"; do
  bash -n "$f"
done

log "Running shellcheck"
shellcheck scripts/verify.sh scripts/agent-iso-build-guard.sh scripts/test-agent-iso-build-guard.sh scripts/verify-agent-hooks-e2e.sh scripts/codex-hook-trust.sh scripts/agent-branch-flow-guard.sh scripts/test-agent-branch-flow-guard.sh archiso-ff1/profiledef.sh "${package_shell_files[@]}"

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

log "Checking FF1 log-stream image configuration"
log_stream_workflows="$(grep -rl 'write_json .*controld\.json' .github/workflows | sort || true)"
if [[ "$(printf '%s\n' "$log_stream_workflows" | grep -c .)" -ne 3 ]]; then
  printf 'expected exactly three image workflows to generate controld.json with log streaming\n' >&2
  exit 1
fi
while IFS= read -r workflow; do
  for required in \
    'del(.sentry)' \
    '.logStreaming = ((.logStreaming // {}) + {' \
    "environment: (\$log_stream_environment | ascii_downcase)" \
    '.logStreaming.sampleRate //= 1' \
    '.logStreaming.playerSampleRate //= 1' \
    "}' 600"; do
    grep -Fq "$required" "$workflow" || {
      printf '%s: missing required FF1 log-stream contract: %s\n' "$workflow" "$required" >&2
      exit 1
    }
  done
  if grep -Fq 'CLOUDFLARE_LOG_STREAM_API_KEY' "$workflow"; then
    printf '%s: log-stream API key must come from FERAL_CONTROLD_CONFIG_JSON\n' \
      "$workflow" >&2
    exit 1
  fi
done <<< "$log_stream_workflows"

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
# The Codex trust helper must keep deriving its identity from the committed
# hook entry: a drift here would print a hash Codex rejects, and Codex would
# then skip the guard silently.
./scripts/codex-hook-trust.sh | grep -q 'trusted_hash = "sha256:[0-9a-f]\{64\}"' || {
  printf 'scripts/codex-hook-trust.sh no longer prints a trust entry for .codex/hooks.json\n' >&2
  exit 1
}
for doc in AGENTS.md CLAUDE.md GEMINI.md .cursor/rules/release-iso-build-policy.mdc; do
  grep -q 'Release guardrail: ISO image builds' "$doc" || {
    printf '%s lost the "Release guardrail: ISO image builds" section\n' "$doc" >&2
    exit 1
  }
done

log "Checking agent branch flow guard"
# AGENTS.md "Branch flow guardrail": agents target develop only. The test
# pins the decisions and that the ISO guard still chains into this guard,
# which is its only wiring.
./scripts/test-agent-branch-flow-guard.sh

log "Checking kiosk console policy"
# docs/BOOT_DISPLAY_AND_CONSOLE.md (ffos#126): no login shell on tty1, every
# boot entry shares one kernel command line, plymouth covers the non-kiosk
# moments. Each line below pins a piece that would fail silently on a device
# (a sudo shell on a customer's TV, or console text leaking back onto the
# panel) rather than in a build.
AIROOTFS="archiso-ff1/airootfs"
BOOT_OPTS="$AIROOTFS/root/scripts/ff1-boot-options.sh"
mapfile -t root_scripts < <(find "$AIROOTFS/root/scripts" -type f -name '*.sh' | sort)
for f in "${root_scripts[@]}"; do
  bash -n "$f"
done
grep -q '^FF1_KERNEL_OPTS="' "$BOOT_OPTS" || {
  printf '%s must define FF1_KERNEL_OPTS\n' "$BOOT_OPTS" >&2
  exit 1
}
for word in console=tty3 systemd.show_status=false rd.systemd.show_status=false splash plymouth.ignore-serial-consoles vt.global_cursor_default=0; do
  grep -q "^FF1_KERNEL_OPTS=.* ${word}[ \"]" "$BOOT_OPTS" || {
    printf '%s: FF1_KERNEL_OPTS lost %s\n' "$BOOT_OPTS" "$word" >&2
    exit 1
  }
done
# Every loader entry heredoc must take its options from the shared file: a
# literal loglevel=/show_status= anywhere else is a second copy drifting.
for script in "${root_scripts[@]}"; do
  [[ "$script" == "$BOOT_OPTS" ]] && continue
  if grep -vE '^[[:space:]]*#' "$script" | grep -qE '(^|[[:space:]])(loglevel=[0-9]|rd\.systemd\.show_status=|systemd\.show_status=|console=tty[0-9])'; then
    printf '%s: kernel options must come from ff1-boot-options.sh (FF1_KERNEL_OPTS), not a literal\n' "$script" >&2
    exit 1
  fi
  if grep -q '^options ' "$script"; then
    if ! grep -q 'source /root/scripts/ff1-boot-options.sh' "$script" || ! grep -qF 'FF1_KERNEL_OPTS' "$script"; then
      printf '%s writes a loader entry but does not source ff1-boot-options.sh and use FF1_KERNEL_OPTS\n' "$script" >&2
      exit 1
    fi
  fi
done
# The only autologin left is the live-ISO getty drop-in, and it must stay
# gated on the ISO cmdline so an installed device never runs it.
if grep -rn -- '--autologin' "$AIROOTFS" | grep -v 'etc/systemd/system/getty@tty1.service.d/autologin.conf'; then
  printf 'an autologin getty outside the live-ISO drop-in was added; see docs/BOOT_DISPLAY_AND_CONSOLE.md\n' >&2
  exit 1
fi
grep -q '^ConditionKernelCommandLine=archisobasedir$' "$AIROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" || {
  printf 'getty@tty1 drop-in lost its live-ISO-only condition\n' >&2
  exit 1
}
grep -q '^ConditionKernelCommandLine=!archisobasedir$' "$AIROOTFS/etc/systemd/system/feral-kiosk-startup.service" || {
  printf 'feral-kiosk-startup.service lost its installed-system-only condition\n' >&2
  exit 1
}
# Conflicts= is resolved in the boot transaction before conditions run: with
# Conflicts=getty@tty1.service the live ISO dropped the installer getty's
# start job even though this unit was condition-skipped (observed on a built
# ISO). The getty drop-in's condition is the only tty1 mechanism.
if grep -q '^Conflicts=' "$AIROOTFS/etc/systemd/system/feral-kiosk-startup.service"; then
  printf 'feral-kiosk-startup.service must not declare Conflicts= (it would drop the live-ISO installer getty job)\n' >&2
  exit 1
fi
# getty@.service must list tty1 as well: this file sorts before systemd's own
# 90-systemd.preset and the first matching rule wins, so omitting tty1 would
# leave the live ISO without its installer getty.
for unit in "seatd.service" "feral-kiosk-startup.service" "getty@.service tty1 tty2"; do
  grep -q "^enable $unit$" "$AIROOTFS/etc/systemd/system-preset/90-default.preset" || {
    printf '90-default.preset must contain "enable %s" (template instances use the two-token form, see the timer comment there)\n' "$unit" >&2
    exit 1
  }
done
for pkg in seatd plymouth; do
  grep -q "^$pkg$" archiso-ff1/packages.x86_64 || {
    printf 'packages.x86_64 must list %s\n' "$pkg" >&2
    exit 1
  }
done
grep -q '^DefaultEnvironment=LIBSEAT_BACKEND=seatd$' "$AIROOTFS/etc/systemd/user.conf.d/10-ff1-seatd.conf" || {
  printf 'user.conf.d/10-ff1-seatd.conf must pin LIBSEAT_BACKEND=seatd\n' >&2
  exit 1
}
grep -q '^seat:x:[0-9]*:.*feralfile' "$AIROOTFS/etc/group" || {
  printf '/etc/group must put feralfile in the seat group\n' >&2
  exit 1
}
[[ -f "$AIROOTFS/var/lib/systemd/linger/feralfile" ]] || {
  printf 'missing linger file for feralfile (user manager must start without a login)\n' >&2
  exit 1
}
[[ -f "$AIROOTFS/usr/share/plymouth/themes/ff1/ff1.plymouth" ]] || {
  printf 'missing plymouth theme ff1\n' >&2
  exit 1
}
# The two-step plugin hard-fails (and plymouth degrades to text on the panel)
# without the dialog assets, even though no dialog is ever shown.
for asset in lock.png entry.png bullet.png throbber-0001.png; do
  [[ -f "$AIROOTFS/usr/share/plymouth/themes/ff1/$asset" ]] || {
    printf 'themes/ff1/%s missing: the two-step plugin refuses to load without it\n' "$asset" >&2
    exit 1
  }
done
[[ ! -e "$AIROOTFS/usr/share/plymouth/themes/ff1/watermark.png" ]] || {
  printf 'themes/ff1/watermark.png would put a logo under the spinner; the theme is deliberately unbranded\n' >&2
  exit 1
}
grep -q '^Theme=ff1$' "$AIROOTFS/etc/plymouth/plymouthd.conf" || {
  printf 'plymouthd.conf must select Theme=ff1\n' >&2
  exit 1
}
# Live ISO boots (installer, soak test) must not run plymouth at all: every
# plymouth unit carries ConditionKernelCommandLine=!plymouth.enable=0, and
# the installer getty is ordered after plymouth-quit-wait, so a splash daemon
# that never quits (observed on a live ISO build) would block the install.
for entry in archiso-ff1/efiboot/loader/entries/*.conf; do
  grep -qE '^options .*\bplymouth\.enable=0\b' "$entry" || {
    printf '%s: live ISO entries must carry plymouth.enable=0\n' "$entry" >&2
    exit 1
  }
done
for unit in plymouth-quit-wait plymouth-quit; do
  grep -q '^TimeoutStartSec=' "$AIROOTFS/etc/systemd/system/$unit.service.d/10-ff1-timeout.conf" || {
    printf '%s must keep its start timeout drop-in (boot must never hang on plymouth)\n' "$unit" >&2
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
