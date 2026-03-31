# Execution Plans For FFOS

An execution plan in this repository is a living design-and-delivery document
for large features, safety-critical behavior changes, workflow architecture
changes, or vague requests that cannot be implemented safely without first
turning them into a concrete plan.

## When a plan is required

Use a plan when at least one of these is true:

- The request changes OTA, recovery, rollback, boot behavior, package publication, or release orchestration.
- The request is large, vague, or could be satisfied by multiple materially different designs.
- The work changes repo ownership boundaries between `ffos` and `ffos-user`.
- The work touches multiple workflows or both CI and runtime-image behavior.

Do not require a plan for small documentation edits, isolated lint fixes, or narrow readability changes with obvious scope.

## Required planning inputs

Before writing or updating a plan, read:

1. `AGENTS.md`
2. `README.md`
3. `docs/DEVICE_LIFECYCLE.md`
4. `docs/SNAPSHOT_SYSTEM_V2_FLOW.md`
5. `.cursor/rules/01-master-design.mdc`
6. `.cursor/rules/10-architecture-direction-tbd.mdc`
7. `.cursor/rules/15-api-design-tbd.mdc`
8. `.cursor/rules/35-testing-and-guardrails.mdc`

## Planning rules

- Summarize the current relevant flow and invariants first.
- Prefer deletion, simplification, or boundary cleanup before additive designs.
- Explicitly call out when architectural or API direction is blocked on the
  owner-owned TBD files.
- For each viable branch, list:
  - the design goal;
  - trade-offs;
  - rollback or safety implications;
  - required validation and guardrails.
- Recommend the smallest safe first slice.

## Plan template

```md
# <Short action-oriented title>

## Purpose / Big Picture

## Current Context

## Constraints And Invariants

## Open Questions

## Design Branches

## Chosen Direction

## Validation Plan

## Milestones

## Progress

## Decision Log

## Risks And Recovery
```
