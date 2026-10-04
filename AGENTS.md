# NetShift — project context for AI agents

Read this before working in this repository.

## What NetShift is

NetShift is a traffic-routing / VPN client for **OpenWRT 24.10+** routers, built
on top of **sing-box**. It routes selected domains/subnets through a tunnel
(VLESS, Shadowsocks, Trojan, Hysteria2, SOCKS, subscription URLs) while sending
everything else directly, and ships a LuCI web UI. It is a fork of
`itdoginfo/podkop`, rebranded to NetShift at 0.8.0, and it is **beta**.
License: GPL-2.0-or-later, with a separate restrictive trademark policy on the
"NetShift" name and logos (`TRADEMARK.md`).

Upstream is rebranded in this fork (`podkop` → `netshift`), so upstream patches
are ported manually — never merge or cherry-pick blindly.

## Architecture

`luci-app-netshift` (LuCI UI: hand-written `.js` views + the generated
`main.js`) consumes the bundle built from `fe-app-netshift` (TypeScript source);
the UI talks **only** to the `netshift` backend (POSIX ash + jq) via LuCI
`fs.exec` of `/usr/bin/netshift` and `/etc/init.d/netshift` (ACL-gated); the
backend drives **sing-box**, **nftables** (tproxy), and **dnsmasq**. No layer
skips another.

## The sacred runtime contract (never change casually)

TProxy inbound `127.0.0.1:1602` · DNS inbound `127.0.0.42:53` · Clash API
`:9090` · FakeIP `198.18.0.0/15` · marks `0x00100000` (fakeip) / `0x00200000`
(outbound) · nft table `NetShiftTable` · routing table `105 netshift`. All of
them are defined in `netshift/files/usr/lib/constants.sh` — reference the
constants, never hardcode.

## Layout

- `netshift/` — the OpenWRT package: backend (`files/usr/bin/netshift`,
  `files/usr/lib/*.sh`), init script, UCI defaults, `Makefile` (version).
- `luci-app-netshift/` — LuCI app: views, ACL, i18n, and the generated
  `htdocs/luci-static/resources/view/netshift/main.js`. In the source tree the
  views live in `view/netshift/`; the package build (`cache-bust.sh`) installs
  them as `view/netshift_<hash>/` so browsers cannot serve a previous version.
- `fe-app-netshift/` — TypeScript source of the UI bundle.
- `tests/` — OpenWRT rootfs smoke suite (Docker).
- `install.sh` — one-line installer used by the README.
- `.github/workflows/` — CI: shellcheck, smoke tests, frontend CI, package
  builds on tags.

## Quality gates (a change is not "done" until the relevant gate passes)

- **Backend** (`netshift/files/**`) and the build script
  `luci-app-netshift/cache-bust.sh`: ShellCheck at severity error
  (`shellcheck -S error -s sh install.sh netshift/files/usr/bin/netshift
  netshift/files/usr/lib/*.sh luci-app-netshift/cache-bust.sh`); smoke suite —
  `docker compose -f tests/docker-compose.yml run --rm netshift-test all`
  (OpenWRT rootfs container; a run passes only with zero FAILs).
- **Frontend** (`fe-app-netshift/**`): `yarn ci`, and the committed `main.js`
  must be regenerated (the build leaves no git diff).
- **Packaging/CI**: smoke tests at minimum; verify both ipk and apk paths.

## Coding rules

- Backend is POSIX ash + busybox: no bashisms, no `[[ ]]`, and **no jq regex on
  OpenWRT** (jq has no Oniguruma) — build string logic from
  `split`/`startswith`/`endswith`/`contains`.
- `log ... "fatal"` is only a log label — always follow it with `exit 1`.
- Never edit the generated `main.js` by hand.
- Keep the rebrand: no `podkop` names in user-visible strings (legacy migration
  code excepted).
- Touching ports/marks/paths requires verifying the whole chain (nft → ip rule
  → sing-box config → UI).

## Workflow

- Run the gates above; CI runs the same commands.
- **Humans commit manually. Agents never commit or push.**
- PRs are accepted only after coordination with the authors via Telegram
  (`CODEOWNERS=@yandexru45`).

## Releases

`PKG_VERSION` lives in `netshift/Makefile`. Pushing a tag (e.g. `0.9.7`)
triggers `.github/workflows/build.yml`: it runs the smoke suite, builds the ipk
and apk packages and attaches them to the GitHub release. Release notes are
written manually.

## Local AI tooling (untracked by design)

Agent rules, memory files and tool configs are local-only and gitignored:
`.claude/`, `.opencode/`, `opencode.json`, `docs/agent-rules/`,
`docs/README-AGENTS.md`. They may exist in the maintainer's working copy; do
not re-add them to git.
