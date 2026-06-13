# Agent Rules: Packaging, CI & Release

Authoritative rules for building, testing, and releasing NetShift. Read this
before touching anything below.

**Scope:** `netshift/Makefile`, `luci-app-netshift/Makefile`,
`Dockerfile-ipk`, `Dockerfile-apk`, `sdk/`, `tests/`, `.github/workflows/`,
`install.sh`.

---

## 1. The packages

Two source packages produce three published artifacts:

- **`netshift`** — the backend (init script, UCI config, `/usr/bin/netshift`,
  shell + jq libs under `/usr/lib/netshift`).
- **`luci-app-netshift`** — the web UI. Its Makefile sets
  `LUCI_LANGUAGES := en ru`, so the build also emits
  **`luci-i18n-netshift-ru`** (the Russian translation) as a third package.

Both packages are `PKGARCH := all` / `LUCI_PKGARCH := all` (architecture-
independent).

---

## 2. `netshift/Makefile` (backend)

- `DEPENDS := +sing-box +curl +jq +kmod-nft-tproxy +coreutils-base64
  +bind-dig`
- `CONFLICTS := https-dns-proxy nextdns luci-app-passwall luci-app-passwall2`
- Version:
  `PKG_VERSION := $(if $(NETSHIFT_VERSION),$(NETSHIFT_VERSION),0.$(shell date +%d%m%Y))`
  — i.e. use `NETSHIFT_VERSION` when set, otherwise a date-stamped fallback.
- `Package/netshift/prerm` removes the `105 netshift` line from
  `/etc/iproute2/rt_tables` (only if present) and runs
  `/etc/init.d/netshift stop`. **Service/system-state teardown lives in the
  package `prerm`, not in `install.sh`.**
- `Package/netshift/conffiles` declares `/etc/config/netshift` (preserved
  across upgrades).
- Version stamp: `Package/netshift/install` runs
  `sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g'
  $(1)/usr/lib/netshift/constants.sh` — **no `|| true`** (this stamp must
  succeed).

`luci-app-netshift/Makefile` stamps the **same** placeholder into the bundled
UI: `sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g'
.../view/netshift/main.js || true` — note the **`|| true`** here (UI stamp is
best-effort). It uses the same `PKG_VERSION` expression and
`LUCI_DEPENDS := +luci-base +netshift`.

> If you ever rename `__COMPILED_VERSION_VARIABLE__`, update **both** Makefile
> `sed`s and `fe-app-netshift/src/constants.ts` together. See
> `frontend-luci.md` §6.

---

## 3. Docker build images

- `Dockerfile-ipk` — `FROM itdoginfo/openwrt-sdk-ipk:24.10.6`.
- `Dockerfile-apk` — `FROM itdoginfo/openwrt-sdk-apk:25.12.3`.
- Both copy `./netshift` → `feeds/utilities/netshift` and
  `./luci-app-netshift` → `feeds/luci/luci-app-netshift`, then run
  `make defconfig` + `make package/<pkg>/compile`.
- `sdk/Dockerfile-sdk-ipk` (`FROM openwrt/sdk:x86_64-v24.10.6`) and
  `sdk/Dockerfile-sdk-apk` (`FROM openwrt/sdk:x86_64-v25.12.3`) are the **base
  SDK images** that the `itdoginfo/openwrt-sdk-*` images derive from (feeds
  updated, `luci-base` installed, feed dirs created; the apk one also runs
  `./setup.sh`).

### Version passing — symmetric, both RAW (no `v` prefix)

Both release Dockerfiles now pass the version **raw**, with no `v` prefix:

- `Dockerfile-ipk`: `ENV NETSHIFT_VERSION=${NETSHIFT_VERSION}` — **raw, no
  `v`**.
- `Dockerfile-apk`: `ENV NETSHIFT_VERSION=${NETSHIFT_VERSION}` — **raw, no
  `v`**.

> Historical note (task-028): `Dockerfile-ipk` used to **prepend `v`**
> (`RUN export NETSHIFT_VERSION="v${NETSHIFT_VERSION}" && ...`) while the apk
> file passed it raw. That asymmetry stamped a leading `v` into the ipk
> package/control version and the runtime `constants.sh` `NETSHIFT_VERSION`,
> so on OWRT24/ipk the installed version (`v0.8.6`) never matched the no-`v`
> GitHub tag (`0.8.6`) and the LuCI UI falsely reported "outdated". The `v`
> prepend was removed (ipk normalized to the apk shape) after verifying the
> whole release flow (§4) and `install.sh` matching (§6): the `_`→`-` rename,
> the 3-package filter, the i18n `-${VERSION}` naming, and the release tag all
> derive from the git tag, and `install.sh` matches assets by **name prefix**
> (the `v` lived in the version segment, not the name prefix) — so dropping it
> does not affect either. Keep both Dockerfiles passing the version raw.
>
> Residual fragility (out of scope, on record): the UI version-equality check
> in `fe-app-netshift` does **not** normalize a leading `v`. If a future
> release is tagged **with** a `v` (e.g. `v0.8.7`), `netshift_latest_version`
> would carry `v` while the installed (no-`v`) version would not, re-triggering
> the false-"outdated" mismatch. **Tag releases WITHOUT a `v`** to keep
> ipk / apk / tag all consistent.

---

## 4. Release flow (`.github/workflows/build.yml`)

Triggered on **tag push** (`tags: ['*']`). Jobs:

1. **`smoke-tests`** — builds and runs the OpenWRT rootfs smoke suite
   (`docker compose -f tests/docker-compose.yml run --rm netshift-test all`).
   This is a **gate**: `build` `needs` it.
2. **`preparation`** — derives the version:
   `git describe --tags --exact-match || "0.$(date +%d%m%Y)"`.
3. **`build`** (matrix `ipk` + `apk`) — builds via
   `Dockerfile-<type>`, passing `NETSHIFT_VERSION` from `preparation`; then
   `docker create` + `docker cp` the built packages out of
   `/builder/bin/packages/x86_64/{utilities,luci}/`.
4. **ipk-only rename** — for `ipk`, every `*.ipk` filename is rewritten with
   `sed 's/_/-/g'` (underscore → dash).
5. **Filter** — copies exactly the **three** packages into `filtered-bin/`:
   `luci-i18n-netshift-ru-*`, `netshift-*`, `luci-app-netshift-*` (the i18n
   one is renamed to carry `${VERSION}`).
6. **`release`** — downloads both matrices' artifacts and publishes a
   **GitHub Release** (`softprops/action-gh-release`) named/tagged
   `github.ref_name`.

The underscore→dash rename (step 4) is **load-bearing**: `install.sh` matches
release assets by **package-name prefix** (see §6), and the dashed names are
what it expects.

---

## 5. Smoke tests (`tests/`)

- Runs in an **OpenWRT 24.10.6 rootfs** container (`tests/Dockerfile`: pulls
  the official `openwrt-24.10.6-x86-64-rootfs.tar.gz`, `opkg install`s
  `sing-box curl jq coreutils-base64 bind-dig nftables`).
- Source is **bind-mounted read-only**: `../netshift/files` →
  `/netshift/files:ro` (see `tests/docker-compose.yml`). The container has no
  copy of the scripts — it tests the live source tree.
- Requires kernel caps **`NET_ADMIN` + `NET_RAW` + `SYS_ADMIN`** and
  `network_mode: host` (for real nft / DNS operations).
- `entrypoint.sh` `main()` dispatches by category. The `all` target runs, in
  order: `test_deps test_syntax test_config test_helpers test_jq_helpers
  test_config_manager test_sing_box_config test_nft test_diagnostics
  test_subscription`. The usage line lists:
  `all deps syntax config helpers jq cm sb nft diagnostics subscription`.

### How to ADD a smoke test

1. Write a `test_xyz()` function using the existing helpers:
   `header`, `pass`, `fail`, `skip` (they drive the `PASS`/`FAIL`/`SKIP`
   counters and `summary`). For sub-shells, emit `name:OK` / `name:FAIL` /
   `name:SKIP` lines and let the `case` parser pick them up (see
   `test_helpers` / `test_subscription`).
2. Add it to the `all)` list in `main()`.
3. Add a short **case alias** (e.g. `xyz) test_xyz ;;`).
4. Update the **usage line** in `main()` (the `Available: ...` echo).
5. Update the **`docker-compose.yml` comment** that documents test names.

---

## 6. CI gates by path

| Workflow | Triggers (paths) | What it does |
|---|---|---|
| `frontend-ci.yml` | `fe-app-netshift/**` (PR) | `yarn install --frozen-lockfile`, `yarn format` (fail on diff), `yarn lint --max-warnings=0`, `yarn test --run`, `yarn build` (fail on diff). See `frontend-luci.md`. |
| `shellcheck.yml` | `install.sh`, `netshift/files/usr/bin/**`, `netshift/files/usr/lib/**` (push/PR to `main`/`rc/**`) | Differential ShellCheck, `severity: error`, include-paths `netshift/files/usr/bin/netshift`, `netshift/files/usr/lib/**.sh`, `install.sh`. |
| `openwrt-smoke-tests.yml` | `netshift/**`, `luci-app-netshift/**`, `tests/**`, `install.sh`, `Dockerfile-ipk`, `Dockerfile-apk`, `.dockerignore` (push/PR to `main`/`rc/**`) | Builds the smoke image and runs `netshift-test all`. |

> **Keep the two smoke invocations in sync.** `build.yml`'s `smoke-tests` job
> runs the suite **only on tag push**; PR/branch coverage comes from the
> separate `openwrt-smoke-tests.yml`. Both call
> `docker compose -f tests/docker-compose.yml ... netshift-test all` — if you
> change one compose command (image name, target, flags), change the other.

---

## 7. `install.sh`

- **POSIX `sh`** (BusyBox `ash` compatible); shellcheck-gated at `error`.
- **Package-manager abstraction:** detects `apk` (`PKG_IS_APK=1`) vs `opkg`
  and wraps install/remove/update/list (`pkg_install`, `pkg_remove`,
  `pkg_is_installed`, etc.). apk install uses `--allow-untrusted`; opkg remove
  uses `--force-depends`.
- **podkop → netshift migration** (`migrate_from_podkop`, triggered by
  `podkop_is_installed` since podkop never reached 0.8.0): **stop the old
  service first** (`/etc/init.d/podkop stop` then `disable`) so dnsmasq/nft
  teardown happens, **back up config** to
  `/etc/config/podkop.bak.pre-netshift`, copy config to
  `/etc/config/netshift`, remove the original `/etc/config/podkop`, clean the
  old `105 podkop` rt_tables line and podkop cron entries, and remove the old
  `luci-i18n-podkop*` / `luci-app-podkop` / `podkop` packages.
- **OpenWRT 23.05 is unsupported** (since NetShift 0.8.0): `check_system`
  exits if `DISTRIB_RELEASE` major == `23`.
- **Space requirement:** needs **≥ 15 MB** free in `/overlay`
  (`REQUIRED_SPACE=15360` KB).
- **Asset matching:** scrapes the latest-release API
  (`https://api.github.com/repos/yandexru45/netshift/releases/latest`),
  greps `.apk`/`.ipk` URLs, then installs by **package-name prefix**
  (loops `for pkg in netshift luci-app-netshift`, plus
  `luci-i18n-netshift-ru*`). This is why the ipk underscore→dash rename in
  `build.yml` (§4) is load-bearing.
- **NO uninstall path.** `install.sh` only installs/migrates; removal lives in
  the package `prerm` (see §2). Do not add an uninstaller here.
- **Known fragility:** GitHub API **rate limiting** — the script detects
  `API rate limit` and exits with a "repeat in five minutes" message.
