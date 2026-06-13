# Memory — packaging-ci-engineer

Durable packaging / CI / release knowledge. Read before working; append
findings; keep under ~200 lines.

## Packages

- `netshift` (backend) and `luci-app-netshift` (UI; also yields
  `luci-i18n-netshift-ru` via `LUCI_LANGUAGES=en ru`). Both `PKGARCH=all`.
- `netshift/Makefile`: DEPENDS `+sing-box +curl +jq +kmod-nft-tproxy
  +coreutils-base64 +bind-dig`; CONFLICTS `https-dns-proxy nextdns
  luci-app-passwall luci-app-passwall2`; version
  `PKG_VERSION = $(if $(NETSHIFT_VERSION),$(NETSHIFT_VERSION),0.$(date +%d%m%Y))`;
  `prerm` removes `105 netshift` from `/etc/iproute2/rt_tables` and stops the
  service; conffile `/etc/config/netshift`; stamps
  `__COMPILED_VERSION_VARIABLE__` into `constants.sh` via sed (NO `|| true`, so a
  missing file fails the build).
- `luci-app-netshift/Makefile`: uses `luci.mk`, `LUCI_DEPENDS=+luci-base
  +netshift`; stamps the same placeholder into `main.js` (WITH `|| true`, so a
  missing main.js silently won't stamp). Asymmetric on purpose — note it.

## Docker build images

- `Dockerfile-ipk` FROM `itdoginfo/openwrt-sdk-ipk:24.10.6`;
  `Dockerfile-apk` FROM `itdoginfo/openwrt-sdk-apk:25.12.3`.
- KNOWN INCONSISTENCY (intentional, do NOT "fix" blindly): ipk Dockerfile
  exports `NETSHIFT_VERSION="v${NETSHIFT_VERSION}"` (adds a `v`); apk sets it
  raw (no `v`). Embedded version vs artifact filenames can differ across types.
- `sdk/Dockerfile-sdk-*` are the base SDK images (feeds update + luci-base);
  apk SDK requires running `./setup.sh` first.

## Release flow (build.yml, on tag push)

smoke-tests gate -> `preparation` derives version (`git describe --tags
--exact-match`, fallback `0.<date>`) -> matrix build ipk+apk -> `docker cp`
artifacts out of the container -> **ipk underscore->dash rename**
(`sed 's/_/-/g'`) -> filter to the 3 packages -> GitHub Release.

- The underscore->dash rename is LOAD-BEARING: `install.sh` scrapes the
  latest-release API and matches assets by package-name prefix
  (`netshift*`, `luci-app-netshift*`, `luci-i18n-netshift-ru*`). Breaking the
  rename breaks install.

## Smoke tests (tests/)

- Image = OpenWRT 24.10.6 rootfs; source is **bind-mounted at runtime**
  (`../netshift/files -> /netshift/files:ro`), so editing `netshift/files` is
  picked up without rebuilding the image.
- Needs `NET_ADMIN`/`NET_RAW`/`SYS_ADMIN` + `network_mode: host` for nft/dns;
  nft tests FAIL (not skip) without caps.
- `all` runs: deps syntax config helpers jq cm sb nft diagnostics subscription.
- Add a test: `test_xyz()` (header/pass/fail/skip), add to `main()` `all)` list,
  add `case` alias, update usage line + docker-compose comment. Keep the two
  compose invocations (build.yml smoke vs openwrt-smoke-tests.yml) in sync.
- Smoke baselines drift as tests get added: 81 passed (pre task-016) -> 84
  passed after adding `test_nft_ipv6` (3 v6 assertions). Re-confirm the baseline
  from the actual run, don't trust a stale number in a task spec.
- `test_nft_ipv6` (alias `nftv6`, task-016): real-nft regression guard for the
  B-01 IPv6 tproxy blocker. Builds the v6 tproxy rule from constants
  (`SB_TPROXY_INBOUND_ADDRESS_V6`/`_PORT_V6`) in a throwaway `inet` table, lists
  it back, and asserts it normalizes to bracketed `[::1]:1603` (positive) and
  that no portless bare form (`tproxy ip6 to ::0`) appears (negative guard). The
  unbracketed bug (`::1:1603`) is normalized by nft to a portless bare addr
  (`[::1:1603]` / `[::0.1.22.3]` depending on nft version) — either way the
  `\[::1\]:1603` grep fails, so the guard fires. Capability-gated: an
  ip6-tproxy "not supported"/"operation not supported" kernel `skip`s; a
  successful-but-wrong load `fail`s. SELF-PROVEN: temp scratch with unbracketed
  rule -> 1 failed (guard caught it), reverted.
- Smoke test capability gating pattern: capture `add_err="$(nft add ... 2>&1)"`
  inside the `if`; on success run asserts, on failure `case "$add_err"` for
  *not supported* substrings -> `skip`, else `fail`. Avoids false-fails on
  kernels lacking a feature while still catching real bugs.
- jq `index()` truthiness nit: `index("x") and index("y")` works (jq treats 0 as
  truthy) but prefer `(index("x") != null) and (index("y") != null)` for intent
  + 0-index robustness. Was at entrypoint.sh:688.
- WSL2 kernel (6.6.x-microsoft-standard-WSL2) DOES support ip6 tproxy in the
  smoke container, so the v6 assertions run (not skip) locally.
- nft v6 buggy-form normalization is VERSION-DEPENDENT: the PROOF doc saw
  `[::0.1.22.3]` (nftables v1.1.3), but the OpenWRT 24.10.6 smoke container
  re-prints unbracketed `::1:1603` as `[::1:1603]` (no `]:` port sep). A
  negative guard that greps a single literal (`\[::0`) is therefore a DEAD
  assertion on the smoke env. ROBUST pattern: flag any `tproxy ip6 to [...]`
  line that is NOT the correct `[::1]:1603` ->
  `grep 'tproxy ip6 to \[' | grep -qv '\[::1\]:1603'`. Catches both
  normalizations + future variants. Self-proved: unbracketed scratch -> BOTH
  positive (`bracketed`) and negative (`no-bare`) guards FAIL (2 failed).

## CI gates by path

- `frontend-ci.yml`: PRs touching `fe-app-netshift/**` -> yarn install /
  format(diff) / lint(--max-warnings=0) / test / build(diff).
- `shellcheck.yml`: `install.sh` + `usr/bin/netshift` + `usr/lib/**.sh`,
  severity error (Differential ShellCheck).
- `openwrt-smoke-tests.yml`: `netshift/**`, `luci-app-netshift/**`, `tests/**`,
  `install.sh`, Dockerfiles -> entrypoint `all`.
- `.gitlab-ci.yml` declares a `test` stage but runs no tests — only builds and
  deploys Docker on master. Quality is enforced by the AI review workflow + the
  GitHub Actions above, not GitLab.

## install.sh

- POSIX; apk/opkg abstraction; podkop->netshift migration STOPS the old service
  first (that restores dnsmasq keys + removes PodkopTable + `105 podkop`),
  backs up config to `/etc/config/podkop.bak.pre-netshift`. OpenWRT 23.05
  unsupported; needs >=15 MB on `/overlay`; NO uninstall path (removal lives in
  package `prerm`). GitHub API rate-limit is a known fragility (wget path has no
  guard).
- `pkg_install` opkg branch uses `opkg install --force-downgrade
  --force-reinstall "$pkg_file"` (task-042). Plain `opkg install` silently
  no-op'd (rc=0) when re-run on a router with an older build: the legacy
  v-prefixed version (`v0.8.6-r1`) sorts ABOVE the no-v release (`0.8.7-r1`) so
  opkg "won't downgrade", and equal versions report "up to date". Both force
  flags make opkg remove+reinstall (proven on OWRT 24.10.5 aarch64). apk branch
  unchanged — `apk add --allow-untrusted` overwrites by default. This is the
  install.sh twin of the task-041 `updates_pkg_install_file` updater.sh fix;
  keep both upgrade paths (README script + in-app self-update) aligned.
