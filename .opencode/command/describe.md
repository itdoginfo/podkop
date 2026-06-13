---
description: Write a structured PR title and description for the current NetShift change.
agent: architect-orchestrator
---

Write a PR title and description for the current change. Optional hint:

$ARGUMENTS

Steps:

1. Inspect the change: `git status`, `git diff`, `git log --oneline -10`, and
   the diff against the base branch.
2. Produce a **title**: 5–15 words, imperative, optionally a leading gitmoji.
3. Produce a **description** with this structure:

   ```
   ## Problem
   <what was wrong / why this change exists>

   ## Solution
   <the approach taken>

   ## Changes
   - <bulleted, concrete list of what changed; group by package/layer>

   ## Gates
   - shellcheck: <result>
   - smoke-tests: <result>
   - frontend-ci / main.js rebuild: <result, or N/A>

   ## Notes
   - <migration notes, runtime-contract impact, follow-ups>
   ```

   Put any **Breaking Changes** at the very top of the description.

Rules:
- No filler ("This PR ..."). Be concrete and factual.
- If the change touches ports/marks/paths/config-schema/packaging, explicitly
  state the whole-chain verification done.
- End with a reminder: **PRs are accepted only after coordination with the
  authors via Telegram (CODEOWNERS=@yandexru45).**

Do not commit or push.
