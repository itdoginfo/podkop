---
description: Run the full NetShift task lifecycle (clarify → design → decompose → implement → gates → review → hand back for commit).
agent: architect-orchestrator
---

You are running the `/task` lifecycle for NetShift. The operator's task:

$ARGUMENTS

Follow this exactly:

## Step 0 — Clarify
Read `AGENTS.md`, the relevant `docs/agent-rules/*.md`, and your memory. Explore
the relevant code. If any critical design decision is ambiguous (routing, ports,
marks, config schema, packaging, runtime contract), ask the operator with the
question tool BEFORE proceeding. Do not assume.

## Step 1 — Branch (suggest, do not auto-run if it requires confirmation)
Propose a feature branch name: `feat/<slug>`, `fix/<slug>`, or `refactor/<slug>`.
Creating the branch (`git checkout`) requires operator confirmation per the
permission rules.

## Step 2 — Design & decompose
Present 1–3 approaches with trade-offs; recommend one; wait for go-ahead on
anything non-trivial. Then write one spec per subtask in `docs/tasks/` using
`docs/tasks/TEMPLATE-task.md` (`task-NNN-<slug>.md`).

## Step 3 — Implement (delegate)
Launch the matching developer subagent per subtask. Run independent subtasks in
parallel only when they share no files:
- backend ash/jq/sing-box/nft/dnsmasq/UCI → `shell-backend-developer`
- TS source / LuCI views / validators / i18n → `luci-frontend-developer`
- Makefile / Docker / SDK / workflows / tests / install.sh → `packaging-ci-engineer`

## Step 4 — Gates (mandatory)
Ensure the developer ran the relevant gate and it passed:
- backend → `shellcheck` skill + `smoke-tests` skill
- frontend → `frontend-ci` skill (and `main.js` rebuilt, no git diff)
- packaging → smoke tests; verify ipk + apk paths

## Step 5 — Review loop
Launch `code-reviewer`. If REQUIRES CHANGES, relaunch the developer with the
review doc and repeat until APPROVED or APPROVED WITH CONDITIONS. Save the review
doc to `docs/tasks/<task-name>-review-001.md`.

## Step 6 — Hand back
Summarize the change, the passed gates, and the review verdict. **Do NOT commit
or push** — the human commits manually. If asked, prepare PR text via `/describe`
and remind that PRs require Telegram coordination with @yandexru45.
