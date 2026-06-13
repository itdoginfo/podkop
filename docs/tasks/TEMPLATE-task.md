# Task: <imperative title>

> Authored by `architect-orchestrator`. One self-contained spec per subtask.
> File name: `task-NNN-<kebab-slug>.md`.

## Context

<Narrative: what the user wants and why. Link any relevant prior tasks.>

### Root cause / research basis (authoritative)

<What investigation established. Cite `file:line`. State facts, not guesses.>

### Operator decisions (already made — do NOT re-ask)

- <Design choice the operator already approved, e.g. "Variant 2".>

## Goal

<One paragraph describing the desired end state.>

## Scope

- Layer(s): <backend ash/jq | TS/LuCI frontend | packaging/CI>.
- Files to modify (exact paths):
  - `path/one`
  - `path/two`
- Do NOT touch: <explicit out-of-scope files/areas>.

## Requirements

### 1. <numbered requirement>

<Be specific. Include exact target `file:line` and fenced code blocks of the
intended change where helpful.>

### 2. <numbered requirement>

## Architecture Notes

- Applicable rules: <e.g. `docs/agent-rules/backend-shell.md` (no jq regex;
  `fatal` needs `exit 1`)>.
- Runtime-contract impact: <none | which ports/marks/paths and the whole-chain
  verification required>.
- Single-source-of-truth constraints: <constants.sh; barrel→main.*; etc.>.

## Tests Required

- Backend: <which `test_*` to add/extend in `tests/entrypoint.sh`, or "covered
  by existing X">. Run the `shellcheck` and `smoke-tests` skills.
- Frontend: <vitest `.test.js` to add, or "verify by reasoning + build">. Run
  the `frontend-ci` skill; ensure `main.js` rebuild leaves no git diff.
- Packaging: <smoke tests; verify ipk + apk paths>.

## Definition of Done

- [ ] All requirements implemented in scope; nothing out-of-scope changed.
- [ ] Relevant gate(s) pass (shellcheck / smoke-tests / yarn ci).
- [ ] (Frontend) `main.js` regenerated; `git diff` clean after build.
- [ ] Runtime contract intact (or whole chain verified if changed).
- [ ] New user-facing strings wrapped in `_()` (frontend).
- [ ] `code-reviewer` verdict: APPROVED or APPROVED WITH CONDITIONS.
