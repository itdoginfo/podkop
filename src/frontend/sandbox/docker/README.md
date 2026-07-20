# Dev stand for luci-app-podkop

Real OpenWrt 25.12 with real LuCI in a container. The app is mounted from the
host, so the loop is: edit js, hit F5.

## Run

```sh
yarn dev:sandbox          # from src/frontend
./up.sh                   # or directly from here
```

UI: <http://localhost:8080> → **Services → Podkop** (`root`, empty password).
Stop with `docker compose down`.

Use `up.sh`, not `docker compose up`: `openwrt/rootfs` has no multiarch
manifest, and the arm image declares `aarch64_generic` rather than `arm64`.
`up.sh` derives both the tag and the platform from `uname -m`.

## Why a container instead of a browser mock

A JS mock only exercises our own code. Here everything below the app is real:

| mocked in the browser | real here |
| --- | --- |
| `fs.exec` | rpcd + **ACL checks** from `acl.d/luci-app-podkop.json` |
| `uci` | uci over `/etc/config/podkop` |
| `_()` | translations loaded from `.po` |
| theme | `cascade.css` served by LuCI |
| "the file parses" | **LuCI's require loader** |

The last two are the point. An ACL mistake returns 403 only on a router.

## What is not here

**The backend.** It is being rewritten in Go; `/usr/bin/podkop` and
`/etc/init.d/podkop` are shell stubs serving fixtures. The mock boundary is the
binary, not the JS, so the whole frontend above it stays real.

**Traffic interception.** `kmod-nft-tproxy` is built against OpenWrt's kernel
and cannot load in a container. `check_nft_rules` reports some rules missing on
purpose — that is the stand's honest state.

**The luci-app version.** The package Makefile substitutes it at build time;
here the js is mounted as-is, so diagnostics shows
`__COMPILED_VERSION_VARIABLE__`.

## Scenarios

```sh
./scenario.sh           # current
./scenario.sh ok        # everything works
./scenario.sh fail      # commands fail — exercises failed states
./scenario.sh stopped   # services down, Clash unreachable
```

Reload the page afterwards.

## Layout

| | |
| --- | --- |
| `Dockerfile` | OpenWrt 25.12.4 + luci (+ firewall/opkg for menu neighbours) |
| `compose.yml` | `router` (8080) and `clash-mock` (9090) |
| `files/usr/bin/podkop` | backend stub |
| `files/etc/init.d/podkop` | service stub for Start/Stop/Restart |
| `files/etc/config/podkop` | uci fixture, one section per parse branch |
| `files/etc/rc.local` | seeds runtime state after boot |
| `clash-mock/server.mjs` | `/traffic` and `/connections` websockets |

`/etc/config/podkop` is required: `menu.d` declares
`"depends": { "uci": { "podkop": true } }`, so without it LuCI hides the menu
entry entirely.
