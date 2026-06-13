# Code Review — <Title> (task-NNN)

> Authored by `code-reviewer`. File name: `<task-name>-review-001.md`
> (use `-002`, `-003`, ... or append a "Re-review" section for later rounds).

**Review ID:** review-001
**Date:** <YYYY-MM-DD>
**Scope:** <uncommitted working-tree changes | branch X vs base>
**Reviewer:** code-reviewer agent

**Files reviewed:**
- `path/...`

---

## Summary

<Brief, neutral assessment of what the change does and its overall quality. No
flattery.>

## Critical Issues

> Must fix before merge. Architecture violations, broken runtime contract, jq
> regex on OpenWRT, missing `exit 1` after `fatal`, hand-edited `main.js`, traffic
> leaks, etc.

### [C1] <Issue title>
- **File:** `path/to/file` (line X)
- **Problem:** <what is wrong and why it matters>
- **Recommendation:** <concrete fix>

## Significant Issues

### [S1] <Issue title>
- **File:** `path/to/file` (line X)
- **Problem:** ...
- **Recommendation:** ...

## Minor Observations

- **[M1]** `path/to/file`: <short note>

## Test Coverage

<Were the required tests/gates added and run? Backend config-gen/subscription →
smoke test? New pure frontend logic → vitest? Was the relevant gate green? If
frontend tests were explicitly not required, say so and state what was verified
by reasoning + build.>

## Verdict

**APPROVED** | **APPROVED WITH CONDITIONS** | **REQUIRES CHANGES**

<One sentence overall. If conditional, list "Conditions before merge" by issue
ID. If changes required, list "Required before merge" by issue ID.>
