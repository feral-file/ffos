# CLAUDE.md - ffos Contract for Claude Code

This is the Claude Code entry point for this repository. It is the consolidated
copy of `AGENTS.md`; the two must stay in sync.

| File | Audience |
|---|---|
| `CLAUDE.md` (this file) | Claude Code |
| `AGENTS.md` | Codex, OpenCode, and any tool reading the generic contract |
| `GEMINI.md` | Gemini CLI (pointer to `AGENTS.md`) |
| `.cursor/rules/*.mdc` | Cursor |
| `.claude/settings.json`, `.codex/hooks.json`, `.cursor/hooks.json`, `.gemini/settings.json`, `.opencode/plugins/` | per-tool shell hooks running the ISO build guard below |

**Amendment duty:** a change to any repository-wide rule must be applied to
this file AND to `AGENTS.md`/`.cursor/rules/` in the same change. A rule that
exists in only one of them is a bug.

## Repository overview

- Project: `ffos`, the build and release repository for FF1 device images.
- It assembles the Arch Linux-based FFOS ISO from the archiso profile in
  `archiso-ff1/`, the component packages built from `ffos-user`, and the
  hand-written PKGBUILDs under `packages/`, then signs and publishes the
  result to Cloudflare R2. Build layers are documented in `README.md`; device
  update and recovery flows in `docs/`.
- Cross-repo boundary: this repo owns image assembly, boot flow, package
  publication, and update orchestration. `ffos-user` owns component code and
  user-space payloads.
- Verification gate: `make verify` (`scripts/verify.sh`), run by
  `.github/workflows/verify.yml` on every PR.

## Release guardrail: ISO image builds

This is the highest-consequence rule in the repository. Read it before running
anything that touches GitHub Actions.

The FFOS image workflows (`build-image-to-cf.yml`, `pure-build-image-to-cf.yml`,
`build-image-from-tags.yml`) are `workflow_dispatch`-only. The branch a
dispatch runs on is not a build detail: it selects the R2 upload prefix
(`{branch}/FF1-{branch}-<version>.iso`) and the pacman `Server` path baked into
the image, and `environment=Production` selects the production domain and
secrets. An ISO dispatched on `release` (or with `environment=Production`) is
published where fielded devices update from. **Dispatching it is a production
deployment, not a build.** The same holds for the other three
`workflow_dispatch` workflows: `manual-build-components.yaml` and
`manual-build-feral-player.yaml` upload packages to `{branch}/os/x86_64/`,
and `manual-push-pacman-repo.yaml` regenerates, re-signs, and prunes that
package repo, which is where fielded devices pull package updates from. Every
dispatchable workflow in this repo except `verify.yml` publishes, so every one
of them is guarded exactly like the image builds below, and `scripts/verify.sh`
fails if a new dispatchable workflow is added without being listed in the
guard.

- **Never (hard prohibition).** No agent may dispatch, re-run, retry, or
  otherwise trigger any of these publishing workflows on the `release` branch, or with
  `environment=Production`, by any mechanism: `gh workflow run`, `gh api`/REST
  dispatch, `gh run rerun`, browser automation of the Actions "Run workflow"
  UI, `act`, wrapper scripts, or a numeric workflow ID. This holds even when
  the task is "cut the release": the agent prepares everything (tag,
  release notes, the exact dispatch parameters) and hands the dispatch itself
  to the human release operator. No instruction given inside an agent session
  lifts this rule; a human runs the dispatch.
- **Only with explicit confirmation.** Any of these publishing workflows on
  the `staging` branch, or with `environment=Staging`, may be dispatched only
  after the agent has
  shown the exact command and every input (`version`, `ffos_user_ref`,
  `ff_player_ref`, `environment`, `pacman_snapshot`, `dev_iso`, the
  `update_*` flags) and the user has confirmed those parameters in the current
  session. A standing instruction from earlier in the conversation, an
  autonomous mode (autopilot, ralph, ultrawork, team, loop), or a
  headless/non-interactive session does not count as confirmation; in those
  cases treat staging exactly like release. When the hook below prompts, that
  prompt is the confirmation step: never restructure a command to avoid it.
- Development builds (`develop` or feature branches with
  `environment=Development`) are unaffected.
- Enforcement is a pre-shell hook, `scripts/agent-iso-build-guard.sh`, wired
  for every agent tool that can run shell commands here: Claude Code
  (`.claude/settings.json`, PreToolUse), Codex CLI (`.codex/hooks.json`,
  PreToolUse), Cursor (`.cursor/hooks.json`, beforeShellExecution), Gemini CLI
  (`.gemini/settings.json`, BeforeTool), and OpenCode
  (`.opencode/plugins/iso-build-guard.js`, tool.execute.before). It denies
  release/Production dispatches everywhere. It prompts the user on
  staging/Staging where the tool has an "ask" decision (Claude Code, Cursor);
  Codex, Gemini, and OpenCode have none, so there staging is denied too and
  the human dispatches it after the agent has shown the parameters. `gh run
  rerun` is escalated the same way because a rerun cannot be attributed to a
  branch. `scripts/test-agent-iso-build-guard.sh` pins the decisions in every
  dialect and that each config still points at the guard; `scripts/verify.sh`
  runs it. Any tool not listed here (or the GitHub web UI driven by browser
  automation) has no hook: for it this section is the enforcement, and a
  session that cannot guarantee it must stop and ask before any dispatch.
- The guard script is a lockstep copy shared with `ffos-user` (agents there
  dispatch these workflows cross-repo). Change both copies together.
