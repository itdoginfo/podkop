---
description: Process PR / review-doc comments for NetShift — fix root cause, re-run gates, hand back for commit.
---

Use the **architect-orchestrator** agent.

You are running `/review` for NetShift. Input (PR URL, review doc path, or pasted
comments):

$ARGUMENTS

Follow this:

1. **Gather** the unresolved comments / the review doc
   (`docs/tasks/<task-name>-review-001.md`). If a PR URL is given, use `gh` (it
   will require confirmation for network/auth).
2. **Triage.** Group comments by root cause. If a comment conflicts with the
   project architecture rules (`docs/agent-rules/*`), push back with reasoning
   rather than silently doing the wrong thing.
3. **Fix.** Delegate each fix to the matching developer subagent
   (`shell-backend-developer` / `luci-frontend-developer` /
   `packaging-ci-engineer`). Fix the root cause, not just the symptom.
4. **Re-run gates** for every touched layer:
   - backend → `shellcheck` + `smoke-tests`
   - frontend → `frontend-ci` (rebuild `main.js`, no git diff)
   - packaging → smoke tests
5. **Re-review** with `code-reviewer` if the change is substantial.
6. **Hand back.** Summarize what was addressed per comment ID. **Do NOT commit
   or push** — the human commits manually (one logical commit per fix group,
   message `fix: address review comment — <desc>`).
