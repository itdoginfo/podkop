---
description: Run the full NetShift task lifecycle (clarify → design → decompose → implement → gates → review → hand back for commit).
---

Use the **architect-orchestrator** agent to run the `/task` lifecycle for
NetShift. The operator's task:

$ARGUMENTS

Follow this exactly:

## Step 0 — Clarify
Read `.claude/CLAUDE.md`, the relevant `docs/agent-rules/*.md`, and the
architect memory. Explore the relevant code. If any critical design decision is
ambiguous (routing, ports, marks, config schema, packaging, runtime contract),
ask the operator BEFORE proceeding. Do not assume.

## Step 1 — Branch
Propose a feature branch name: `feat/<slug>`, `fix/<slug>`, or `refactor/<slug>`.
Creating it requires operator confirmation.

## Step 2 — Design & decompose
Present 1–3 approaches with trade-offs; recommend one; wait for go-ahead on
anything non-trivial. Write one spec per subtask in `docs/tasks/` using
`docs/tasks/TEMPLATE-task.md` (`task-NNN-<slug>.md`).

## Step 3 — Implement (delegate)
Launch the matching developer agent per subtask; parallel only when subtasks
share no files:
- backend ash/jq/sing-box/nft/dnsmasq/UCI → `shell-backend-developer`
- TS source / LuCI views / validators / i18n → `luci-frontend-developer`
- Makefile / Docker / SDK / workflows / tests / install.sh → `packaging-ci-engineer`

## Step 4 — Gates (mandatory)
- backend → `shellcheck` skill + `smoke-tests` skill
- frontend → `frontend-ci` skill (and `main.js` rebuilt, no git diff)
- packaging → smoke tests; verify ipk + apk paths

## Step 5 — Review loop
Launch `code-reviewer`. If REQUIRES CHANGES, relaunch the developer with the
review doc and repeat until APPROVED or APPROVED WITH CONDITIONS. Save the
review to `docs/tasks/<task-name>-review-001.md`.

## Step 6 — Hand back
Summarize the change, the passed gates, and the verdict. **Do NOT commit or
push** — the human commits manually. PRs require Telegram coordination with
@yandexru45.
