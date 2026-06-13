# NetShift — Project Core Rules (AUTHORITATIVE)

> Single source of truth for AI agents working anywhere in this repo. Read this before touching code. Every rule below is grounded in the actual source — do not invent values.

## 1. Project identity

NetShift is an OpenWRT traffic router built on top of [sing-box](https://github.com/SagerNet/sing-box): it selectively routes chosen domains/subnets through a tunnel and sends everything else directly. It is a fork of [itdoginfo/podkop](https://github.com/itdoginfo/podkop), rebranded to NetShift at version `0.8.0`. The project is **beta** (expect breaking changes). License: **GPL-2.0-or-later** (`LICENSE`), with a **separate trademark policy** — the NetShift name and logos are protected; see `TRADEMARK.md`. Code is GPL-licensed; the brand is not.

Hard requirements (target device):
- OpenWRT **24.10+**
- `sing-box >= 1.12.0` (`SB_REQUIRED_VERSION` in `constants.sh`)
- `jq >= 1.7.1` (`JQ_REQUIRED_VERSION`)
- `coreutils-base64 >= 9.7` (`COREUTILS_BASE64_REQUIRED_VERSION`)
- `>= 25 MB` free space (16 MB flash devices unsupported)

## 2. The three packages and strict dependency direction

Layers point in ONE direction. **No layer skips another.**

```
luci-app-netshift  (TS/LuCI UI, hand-written views + generated main.js)
        │  consumes the generated main.js produced from
        ▼
fe-app-netshift    (TypeScript source, built with tsup)
        │  UI talks ONLY to the backend, never to sing-box/nft/dnsmasq directly
        ▼
netshift backend   via LuCI fs.exec of /usr/bin/netshift and /etc/init.d/netshift (ACL-gated)
        │
        ▼
sing-box / nftables / dnsmasq
```

- `luci-app-netshift` — LuCI web UI. Its `htdocs/.../view/netshift/main.js` is **generated** from `fe-app-netshift`. Hand-written views live alongside it.
- `fe-app-netshift` — the TypeScript source of `main.js` (fetchers, methods, services, tabs). Edit UI logic **here**, not in the generated bundle.
- `netshift` — the backend package (POSIX ash + jq): CLI dispatcher `/usr/bin/netshift`, procd init `/etc/init.d/netshift`, libraries in `/usr/lib/netshift/`, UCI config `/etc/config/netshift`.

The UI never reimplements backend logic; it invokes backend commands. The backend never depends on the UI.

## 3. Runtime contract (sacred — do not change casually)

These values are wired across `constants.sh`, `nft.sh`, the CLI, and the generated sing-box config. Changing one without the rest breaks the whole chain.

| Concept | Value | Source constant |
|---|---|---|
| tproxy inbound | `127.0.0.1:1602` | `SB_TPROXY_INBOUND_ADDRESS` / `SB_TPROXY_INBOUND_PORT` |
| DNS inbound | `127.0.0.42:53` | `SB_DNS_INBOUND_ADDRESS` / `SB_DNS_INBOUND_PORT` |
| Service mixed inbound | `127.0.0.1:4534` | `SB_SERVICE_MIXED_INBOUND_*` |
| Clash API controller | `:9090` | `SB_CLASH_API_CONTROLLER_PORT` |
| FakeIP range | `198.18.0.0/15` | `SB_FAKEIP_INET4_RANGE` |
| nft FakeIP mark | `0x00100000` | `NFT_FAKEIP_MARK` |
| nft outbound mark | `0x00200000` | `NFT_OUTBOUND_MARK` |
| nft table | `NetShiftTable` (family `inet`) | `NFT_TABLE_NAME` |
| routing table | `105 netshift` | `RT_TABLE_NAME` + `/etc/iproute2/rt_tables` |
| state dir | `/etc/netshift` | `NETSHIFT_STATE_DIR` |
| sing-box config | `/etc/sing-box/config.json` (UCI `settings.config_path`) | UCI |

These ports, marks, addresses, the nft table name, and the routing table id are **sacred**. They are referenced in `nft.sh` rules, `route_table_rule_mark`, dnsmasq integration (`127.0.0.42`), diagnostics (`check_sing_box`, `check_nft_rules`, `check_dns_available`), and the generated config. Treat any change to them as a system-level change (§4).

## 4. System-level change rule

A change is **system-level** if it touches any of:
- nft rules / sets / chains, routing rules or tables, fwmarks
- sing-box config schema or generation
- dnsmasq integration (server `127.0.0.42`, `noresolv`, `cachesize`, backup/restore)
- UCI schema (`/etc/config/netshift`)
- ports / marks / tags in `constants.sh`
- packaging (`Makefile`, install, conffiles, dependencies)
- the payment-free subscription flow (download → validate → cache → generate outbounds)

For system-level changes you MUST verify the **whole chain**, not a single file:

```
UCI (config_get) → config generation (sing_box_*) → sing-box -c <file> check → nft rules → running service
```

Validate by running the smoke tests and, where relevant, confirming the generated config still passes `sing-box check` and the nft table/routing still install (see `start_main` in `/usr/bin/netshift`).

## 5. Repo-wide conventions

- **LF line endings everywhere.** `.gitattributes` enforces `* text=auto eol=lf`. Never introduce CRLF.
- **No magic strings.** All ports, IPs, marks, tags, paths, versions, and service lists live in `netshift/files/usr/lib/constants.sh`, grouped as `## Common`, `## nft`, `## sing-box`, `## Lists`. New constants go there.
- Community service list is `COMMUNITY_SERVICES` in `constants.sh`; the UI and `validate_service` both depend on it.

## 6. Mandatory quality gates (CI a contributor must pass)

These gate every PR. Use the matching skills.

1. **ShellCheck** (`.github/workflows/shellcheck.yml`) — severity `error`, over:
   - `install.sh`
   - `netshift/files/usr/bin/netshift`
   - `netshift/files/usr/lib/**.sh`
   - Skill: `shellcheck`.
2. **OpenWRT smoke tests** (`.github/workflows/openwrt-smoke-tests.yml`) — runs `tests/entrypoint.sh` in an OpenWRT rootfs via `tests/docker-compose.yml` (`run --rm netshift-test all`).
   - Skill: `smoke-tests`.
3. **Frontend `yarn ci`** (in `fe-app-netshift`) — defined as:
   `yarn format && yarn lint --max-warnings=0 && yarn test --run && yarn build`
   i.e. prettier (no diff), ESLint with `--max-warnings=0`, vitest, and a build that must produce no diff in the committed `main.js`.
   - Skill: `frontend-ci`.

## 7. Contribution gating

- `CODEOWNERS = @yandexru45`.
- PRs are accepted **only after coordination with the authors via Telegram** (per README; see `t.me/netshift_chat`).
- **Agents NEVER auto-commit.** A human reviews and commits manually. Do not run `git commit`, `git push`, amend, or open PRs unless the human explicitly asks.

## 8. Anti-patterns (do NOT do these)

- Hardcoding ports / IPs / marks / paths instead of using `constants.sh`.
- Duplicating routing/marking logic instead of reusing `nft.sh` / `route_table_rule_mark` / `create_nft_rules`.
- Editing the generated `main.js` by hand — edit `fe-app-netshift` TS source and rebuild.
- Reimplementing backend logic in the UI — the UI must call `/usr/bin/netshift` / `/etc/init.d/netshift`.
- Changing a sacred runtime value in one place while leaving the rest of the chain stale.
