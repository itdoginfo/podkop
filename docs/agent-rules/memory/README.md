# Agent memory

This folder is the **single source of truth** for per-agent persistent memory,
shared by both AI toolchains (OpenCode and Claude Code).

OpenCode has no built-in `memory: project` mechanism, so memory here is a plain
convention: **every agent's prompt instructs it to read its own
`<agent>.md` file before starting work, and to append durable findings to it
when it learns something that future runs must not re-discover.**

## Rules for memory files

- One file per agent, named exactly after the agent
  (`architect-orchestrator.md`, `shell-backend-developer.md`,
  `luci-frontend-developer.md`, `packaging-ci-engineer.md`,
  `code-reviewer.md`).
- Keep each file **under ~200 lines**. It is loaded into the agent's context
  on every run; bloat costs tokens and dilutes signal.
- Record only **durable, reusable knowledge**: gotchas, fragile areas,
  non-obvious conventions, decisions already made, recurring review findings.
  Do **not** record task-specific narration.
- These files are **committed to git** so the whole team (and other
  contributors using AI) benefit.
- When a fact here is proven wrong or stale, fix it in the same edit — do not
  let memory drift from reality.

## How the two toolchains share this

Both `.opencode/agent/*.md` and `.claude/agents/*.md` point their agents at
these files by relative path (`docs/agent-rules/memory/<agent>.md`). There is
no duplication of memory content — only this one copy.
