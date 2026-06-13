# NetShift — Claude Code context (composition root)

This is the Claude Code entry point. It composes the same single-source rules
used by OpenCode (`AGENTS.md`). Read it fully before working.

## What NetShift is

NetShift is a traffic-routing / VPN client for **OpenWRT 24.10+** routers built
on **sing-box**. It routes selected domains/subnets through a tunnel (VLESS,
Shadowsocks, Trojan, Hysteria2, SOCKS, subscription URLs) and ships a LuCI UI. It
is a fork of `itdoginfo/podkop`, rebranded to NetShift at 0.8.0. Beta.
GPL-2.0-or-later with a separate trademark policy (`TRADEMARK.md`).

## Architecture in one sentence

`luci-app-netshift` (LuCI UI: hand-written `.js` + generated `main.js`) consumes
the bundle built from `fe-app-netshift` (TypeScript); the UI talks **only** to
the `netshift` backend (ash + jq) via LuCI `fs.exec` of `/usr/bin/netshift` and
`/etc/init.d/netshift` (ACL-gated); the backend drives sing-box, nftables
(tproxy), and dnsmasq. No layer skips another.

## Rules (single source of truth — shared with OpenCode)

@docs/agent-rules/project-core.md
@docs/agent-rules/backend-shell.md
@docs/agent-rules/frontend-luci.md
@docs/agent-rules/packaging.md

## The sacred runtime contract (never change casually)

TProxy `127.0.0.1:1602` · DNS `127.0.0.42:53` · Clash API `:9090` · FakeIP
`198.18.0.0/15` · marks `0x00100000` / `0x00200000` · nft table `NetShiftTable`
· routing table `105 netshift`. All in `netshift/files/usr/lib/constants.sh`.

## Quality gates

- Backend: ShellCheck (severity error) + smoke tests (`tests/entrypoint.sh all`).
- Frontend: `yarn ci`, and the committed `main.js` must be regenerated (build
  leaves no git diff).
- Packaging: smoke tests; verify both ipk and apk paths.

## The agent team (`.claude/agents/`)

| Agent | Role | Model |
| --- | --- | --- |
| `architect-orchestrator` | Clarify → design → decompose into `docs/tasks/*.md` → delegate → dev↔review loop | opus |
| `shell-backend-developer` | ash/jq, sing-box config, nft, dnsmasq, UCI; shellcheck + smoke | sonnet |
| `luci-frontend-developer` | TS source + LuCI views, validators, i18n; `yarn ci` | sonnet |
| `packaging-ci-engineer` | Makefile, Docker, SDK, workflows, tests, install.sh | sonnet |
| `code-reviewer` | Read-only review → verdict APPROVED / CONDITIONS / CHANGES | haiku |

Each agent reads its memory under `docs/agent-rules/memory/` before working and
appends durable findings there (shared with OpenCode — no duplicate memory).

## Commands (`.claude/commands/`)

- `/task` — full lifecycle. `/review` — process review comments. `/describe` —
  PR title + description.

## Non-negotiables

- Humans commit manually. Agents NEVER auto-commit or push.
- Every change passes a `code-reviewer` verdict before commit.
- Never hand-edit `main.js`. Never use jq regex on OpenWRT.
- Never change ports/marks/paths without verifying the whole chain.
- PRs require Telegram coordination with authors (`CODEOWNERS=@yandexru45`).

## Operator manual

See @docs/README-AGENTS.md (Russian).
