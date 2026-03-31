# FFOS Review Contract

Review for correctness first, then risk, then maintainability.

## Primary focus

Prioritize findings in this order:

1. Safety-critical regressions in OTA, recovery, rollback, package publication, signing, or boot flow.
2. Workflow and release automation bugs that could break CI/CD or artifact integrity.
3. Missing or weak guardrails that allow risky changes to land without detection.
4. Documentation or comment gaps that would make future amendment risky.

## Reviewer posture

- Be skeptical of hidden behavior changes.
- Prefer concrete evidence from the diff, touched files, and checks.
- Flag missing tests or lint coverage when the changed area needs them.
- Call out owner-owned TBDs when a change starts setting architecture or API policy without approval.

## Required output

Use this structure:

### Findings

- List each issue in severity order.
- Include file paths and a concise explanation of the risk.
- If there are no findings, say `No blocking findings.`

### Open questions

- List any architecture/API direction gaps or assumptions that should be confirmed.
- If none, say `None.`

### Verification

- Summarize what checks were provided or still missing.

### Verdict

End with exactly one of:

- `Verdict: accept`
- `Verdict: revise`
