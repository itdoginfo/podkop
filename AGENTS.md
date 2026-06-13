# NetShift — AI agent context (composition root)

This file is auto-loaded by OpenCode (and mirrored for Claude Code in
`.claude/CLAUDE.md`). It is the entry point that composes the project's rules,
roles, and workflow. Read it fully before doing anything in this repository.

## What NetShift is (one paragraph)

NetShift is a traffic-routing / VPN client for **OpenWRT 24.10+** routers, built
on top of **sing-box**. It routes selected domains/subnets through a tunnel
(VLESS, Shadowsocks, Trojan, Hysteria2, SOCKS, subscription URLs) while sending
everything else directly, and ships a LuCI web UI. It is a fork of
`itdoginfo/podkop`, rebranded to NetShift at 0.8.0. It is **beta**.
License: GPL-2.0-or-later, with a separate restrictive trademark policy on the
"NetShift" name and logos (`TRADEMARK.md`).

## Architecture in one sentence

`luci-app-netshift` (LuCI UI: hand-written `.js` views + the generated
`main.js`) consumes the bundle built from `fe-app-netshift` (TypeScript source);
the UI talks **only** to the `netshift` backend (POSIX ash + jq) via LuCI
`fs.exec` of `/usr/bin/netshift` and `/etc/init.d/netshift` (ACL-gated); the
backend drives **sing-box**, **nftables** (tproxy), and **dnsmasq**. No layer
skips another.

## Rules (single source of truth)

Read the rule that matches what you are touching. These are authoritative.

- @docs/agent-rules/project-core.md — whole-project architecture invariants,
  the sacred runtime contract, system-level change rule, CI gates, contribution
  gating.
- @docs/agent-rules/backend-shell.md — `netshift/files/usr/**` (ash + jq,
  sing-box config, nft, dnsmasq, UCI). Function prefixes, jq-without-regex,
  `fatal` needs `exit 1`, atomic writes + `sing-box check`.
- @docs/agent-rules/frontend-luci.md — `fe-app-netshift/src/**` and
  `luci-app-netshift/htdocs/**`. Generated `main.js`, barrel reachability,
  `_()` i18n, `yarn ci`.
- @docs/agent-rules/packaging.md — Makefiles, Docker ipk/apk, SDK, smoke tests,
  `.github/workflows`, `install.sh`, release flow.

## The sacred runtime contract (never change casually)

TProxy inbound `127.0.0.1:1602` · DNS inbound `127.0.0.42:53` · Clash API
`:9090` · FakeIP `198.18.0.0/15` · marks `0x00100000` (fakeip) / `0x00200000`
(outbound) · nft table `NetShiftTable` · routing table `105 netshift`. All
defined in `netshift/files/usr/lib/constants.sh` — reference them, never
hardcode.

## Quality gates (a change is not "done" until the relevant gate passes)

- Backend (`netshift/files/**`): `shellcheck` skill (severity error) +
  `smoke-tests` skill (`tests/entrypoint.sh all`).
- Frontend (`fe-app-netshift/**`): `frontend-ci` skill (`yarn ci`), and the
  committed `main.js` must be regenerated (build leaves no git diff).
- Packaging/CI: smoke tests at minimum; verify both ipk and apk paths.

## The agent team

| Agent | Role | Model |
| --- | --- | --- |
| `architect-orchestrator` | Clarify → design → decompose into `docs/tasks/*.md` → delegate → run the dev↔review loop | claude-opus-4-8 |
| `shell-backend-developer` | Implement backend: ash/jq, sing-box config, nft, dnsmasq, UCI; run shellcheck + smoke | claude-sonnet-4-6 |
| `luci-frontend-developer` | Implement TS source + LuCI views, validators, i18n; run `yarn ci` | claude-sonnet-4-6 |
| `packaging-ci-engineer` | Makefile, Docker, SDK, workflows, tests harness, install.sh | claude-sonnet-4-6 |
| `code-reviewer` | Read-only review of the diff against the rules; verdict APPROVED / APPROVED WITH CONDITIONS / REQUIRES CHANGES | claude-haiku-4-5 |

Each agent reads its own memory file under `docs/agent-rules/memory/` before
working and appends durable findings there.

## Commands

- `/task` — full lifecycle: clarify → branch → implement (parallel subagents
  when independent) → run gates → review → checklist → one commit → PR.
- `/review` — process PR / review-doc comments, fix root cause, re-run gates.
- `/describe` — write a structured PR title + description.

## Non-negotiables

- **Humans commit manually. Agents NEVER auto-commit or push.** Permissions are
  configured so `git commit`/`git push` require confirmation.
- Every change passes a `code-reviewer` verdict before commit.
- Never edit the generated `main.js` by hand. Never use jq regex on OpenWRT.
- Never change ports/marks/paths without verifying the whole chain.
- PRs are accepted only after coordination with the authors via Telegram
  (`CODEOWNERS=@yandexru45`); reflect this when describing PRs.

## Operator manual

Humans: see @docs/README-AGENTS.md (Russian) for how to drive this system.
