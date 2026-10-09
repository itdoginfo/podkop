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

The release itself, in order:

1. Bump the `PKG_VERSION` fallback in `netshift/Makefile` to the new version and
   commit it. CI passes the tag as `NETSHIFT_VERSION`, so the fallback only
   affects local builds — bump both so they agree.
2. `git tag <version> && git push origin <version>`. `build.yml` then runs the
   smoke suite, builds ipk and apk, and creates the release with six assets:
   `netshift-*`, `luci-app-netshift-*` and `luci-i18n-netshift-ru-*` in both
   formats. The i18n package carries a date-based version of its own
   (`luci-i18n-netshift-ru-0.261004.56489`), which the release step renames to
   the tag — so a filename there is not a version mismatch.
3. **CI does not set the release body** (`softprops/action-gh-release` is called
   without `body`/`body_path`). After the release appears, set the notes with
   `gh release edit <version> --repo yandexru45/netshift --notes-file <file>`.
   The notes must credit the release's contributors by their GitHub handles
   (from `git log <prev-tag>..<tag> --format='%an'` / the merged PRs) - keep the
   list in the README section «Участники» in sync.
4. Verify the assets: `gh release view <version> --json assets` — six files, and
   the `NETSHIFT_VERSION` inside the built `constants.sh` must equal the tag.

When building locally without `--build-arg NETSHIFT_VERSION=...` to check the
fallback, beware: an SDK base image can carry an inherited `ENV
NETSHIFT_VERSION`, which `ENV NETSHIFT_VERSION=${NETSHIFT_VERSION}` does not
clear, and `make` skips an already-built package. Force a real rebuild (remove
`build_dir/target-*/netshift-*`, the `stamp/.netshift_installed` stamp and the
old ipk) before trusting the result.

Frontend gates (`frontend-ci.yml`, including the translation check) run on pull
requests **and** on pushes to `main`/`rc/**`; the backend gates (shellcheck,
smoke tests) are push-only, so a pull-request head from a fork gets no CI run at
all — run the smoke suite locally for those.

Contributors: the repository is a GitHub fork, so GitHub does **not** populate
the sidebar «Contributors» widget on the repo page (it stays «No contributors»)
and `stats/contributors` is not what drives it. Do not try to «fix» it by
rewriting history. Keep the visible credit in three places instead: the README
section «Участники» (with the auto-updating contrib.rocks avatar grid), the
release notes of every tag (see the release steps above), and the contributors
page `graphs/contributors` linked from the README.

## Local AI tooling (untracked by design)

Agent rules, memory files and tool configs are local-only and gitignored:
`.claude/`, `.opencode/`, `opencode.json`, `docs/agent-rules/`,
`docs/README-AGENTS.md`. They may exist in the maintainer's working copy; do
not re-add them to git.
