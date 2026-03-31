# AGENTS.md — FFOS Repository Contract

This file defines repository-level constraints for coding agents working in FFOS.
Detailed implementation behavior lives in `.cursor/rules/`, while cross-tool
sub-agent definitions live in `.cursor/agents/`, `.codex/agents/`, and
`opencode.json`.

## Repository overview

- Project: FFOS build and release repository for FF1 devices.
- Core responsibility: build Arch Linux-based FFOS images, stage packages from
  `ffos-user`, publish artifacts, and preserve safe update and recovery flows.
- Primary surfaces in this repo:
  - `.github/workflows/` for build, packaging, and release automation.
  - `.github/actions/` for shared CI primitives.
  - `archiso-ff1/` for ISO profile, boot files, rootfs overlay, and runtime scripts.
  - `docs/` for device lifecycle, snapshot/update flow, and repository context.
- Cross-repo boundary: this repo owns FFOS image assembly and release
  orchestration. `ffos-user` owns component code and user payloads unless a
  workflow or documented integration explicitly says otherwise.

## Non-negotiables

- Prefer deleting or replacing confusing build/release paths over layering more conditional logic onto them.
- Do not preserve legacy build behavior, fallback branches, or compatibility
  shims unless the user explicitly asks for that behavior to remain.
- Keep ownership boundaries explicit:
  - image assembly, boot flow, package publication, and update orchestration belong here;
  - component business logic belongs in `ffos-user` unless this repo already
    owns the runtime script or image-level integration.
- Treat OTA, recovery, rollback, boot entry generation, package signing, and
  publication as safety-critical flows. Any change must preserve rollback and
  known-good boot behavior.
- Prefer deterministic, auditable shell and workflow logic over clever compact scripts.
- For non-obvious logic, prefer more comments than usual. Leave durable context for later agent sessions:
  - why the block exists;
  - what invariants it must preserve;
  - what failure mode or rollback risk it is protecting against;
  - the chosen trade-off and the rejected alternative when that context will matter later.
- Do not add decorative comments that restate syntax. Comments must earn their
  keep as future amendment context.

## Required context before structural changes

Before changing architecture, workflow orchestration, boot/update behavior, or release/publishing behavior:

1. Read `README.md`.
2. Read `docs/DEVICE_LIFECYCLE.md`.
3. Read `docs/SNAPSHOT_SYSTEM_V2_FLOW.md`.
4. Read the relevant `.cursor/rules/*.mdc` files.
5. Summarize the current flow, repository boundary, invariants, and rollback
   expectations before implementing.

Canonical sequence for structural work:
`context -> design -> tasks -> implementation -> verification`

If the work is large or ambiguous, use `PLANS.md` when it exists. If
`PLANS.md` does not exist in this repo, create a short design note in the PR
description or docs instead of silently improvising.

## Architecture and API direction

- `.cursor/rules/10-architecture-direction-tbd.mdc` is intentionally incomplete.
- `.cursor/rules/15-api-design-tbd.mdc` is intentionally incomplete.
- Repository owner action required: `@lpopo0856` should fill these with the
  target architectural direction and API contract posture that future agent
  sessions must aim toward.
- Until those files are completed, agents must not invent new strategic
  architecture or API conventions. If a task depends on that direction, call
  out the gap and keep changes tactical and reversible.

## Required development sequence

1. Start with the smallest repository-owned change that solves the problem.
2. Prefer workflow/script cleanup before additive branching or new flags.
3. Add or expand comments around non-obvious shell/workflow logic when you
   touch it.
4. Run the strict repository guardrails that apply to the changed files.
5. If you changed safety-critical update or boot logic, explain the preserved
   invariants in the PR.

## Guardrails and verification

Run the relevant checks after changes:

- GitHub Actions linting via `actionlint`.
- YAML linting via `yamllint`.
- Markdown/documentation linting via `markdownlint-cli2`.
- Shell linting via `shellcheck` for repository-owned scripts.

If a check cannot run locally, say so explicitly and rely on CI as the next gate.

## Definition of done

A task is complete only when:

1. Repository instructions remain aligned across `AGENTS.md`, Cursor rules,
   Codex/OpenCode config, and reviewer prompts.
2. Changed workflows or scripts are readable, commented where needed, and
   lint-clean or have documented follow-up.
3. Safety-critical flows still preserve the current rollback/update model
   unless the user explicitly requested a design change.
4. Any unresolved architecture or API guidance gaps are called out as TBDs for `@lpopo0856`.

## Review workflow

After implementation, run a review loop before committing or opening a PR:

1. Produce a compact handoff with goal, files changed, key decisions,
   trade-offs, and checks run.
2. Invoke the reviewer sub-agent with fresh context.
3. If the reviewer returns `Verdict: revise`, address the findings and rerun
   the review.
4. Commit, push, and open a PR only after the reviewer returns `Verdict: accept`.

## Commit format

Use Conventional Commits:

- `<type>(<optional-scope>): <description>`
- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `ci`, `build`, `chore`, `perf`, `style`
