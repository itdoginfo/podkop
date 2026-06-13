# Memory — architect-orchestrator

Durable project knowledge for designing and decomposing NetShift tasks.
Read this before planning. Append new durable findings; keep under ~200 lines.

## Project shape (verified)

- NetShift = OpenWRT 24.10+ traffic router on top of **sing-box** (>=1.12.0,
  jq>=1.7.1). Fork of `itdoginfo/podkop`, rebranded to NetShift at 0.8.0. Beta.
  GPL-2.0-or-later + separate restrictive trademark policy (`TRADEMARK.md`).
- Three packages, one-way dependency chain:
  `luci-app-netshift` (LuCI UI, hand-written `.js` views + generated `main.js`)
  -> `fe-app-netshift` (TypeScript source of `main.js`, built by tsup)
  -> `netshift` (POSIX ash + jq backend) -> sing-box / nftables / dnsmasq.
  The UI talks to the backend ONLY via LuCI `fs.exec` of `/usr/bin/netshift`
  and `/etc/init.d/netshift` (ACL-gated), plus Clash API on :9090.

## Sacred runtime contract (constants.sh — never change casually)

- TProxy inbound `127.0.0.1:1602`; DNS inbound `127.0.0.42:53`; Clash API `:9090`.
- FakeIP range `198.18.0.0/15`. Marks: FakeIP `0x00100000`, outbound `0x00200000`.
- nft table `NetShiftTable` (inet); routing table `105 netshift`.
- Required versions `SB_REQUIRED_VERSION=1.12.0`, `JQ_REQUIRED_VERSION=1.7.1`.

## Data flow (start_main in usr/bin/netshift)

check_requirements -> migration (currently no-op) -> validate services ->
br_netfilter_disable -> NTP sync -> subscription cache prep -> route table + nft
base -> sing_box_configure_service -> sing_box_init_config (build JSON) ->
save+`sing-box check` -> cron jobs -> start sing-box -> dnsmasq_configure ->
`list_update &` (background heavy list download).

## Quality gates a task must pass before "done"

- Backend (`netshift/files/**`): `shellcheck` skill (severity error) +
  `smoke-tests` skill (tests/entrypoint.sh `all`).
- Frontend (`fe-app-netshift/**`): `frontend-ci` skill (`yarn ci`) AND the
  committed `main.js` must be regenerated (build must leave no git diff).
- Packaging/CI changes: smoke-tests at minimum; verify both ipk and apk paths.

## Decomposition policy

- Map subtasks to the right developer agent:
  backend/shell/jq/sing-box/nft/dnsmasq/UCI -> `shell-backend-developer`;
  TS source / LuCI views / validators / i18n -> `luci-frontend-developer`;
  Makefile / Docker / SDK / workflows / tests harness / install.sh ->
  `packaging-ci-engineer`.
- A change touching the TS source almost always also requires a rebuild of
  `main.js` (frontend dev handles via `yarn build`). Flag this in the spec.
- "System-level" changes (nft, routing, config schema, ports/marks, dnsmasq,
  packaging) must be verified across the whole chain, not one file.
- Never allow a commit without a passed code-reviewer verdict. Never skip the
  relevant gate. Humans commit manually — agents never auto-commit.

## Known latent bugs / landmines (don't reintroduce; fix only if in scope)

- `usr/bin/netshift` dispatches `main)` and `check_sing_box_logs)` but NO such
  functions are defined — dead/broken dispatch.
- nft proxy chain hardcodes `127.0.0.1:1602` instead of using the constants
  (duplication; changing the constant won't change the rule).
- VPN `domain_resolver` uses `$dns_server` (undefined in scope) instead of
  `$domain_resolver_dns_server`.
- Frontend `runFakeIPCheck` has inverted-looking allGood/atLeastOneGood logic.
- Diagnostic strings contain intentional CP1251 mojibake (emoji/box-drawing) —
  preserve byte sequences when editing.
- `validate_subscription_file` (helpers.sh) only checks `.type` is NOT in
  {selector,urltest,direct,dns,block}. A body whose outbounds lack `.type`
  entirely (e.g. a single Xray-config OBJECT using `.protocol`) passes as
  "valid" → bypasses the fallback normalizer and later fails `sing-box check`.
  An Xray ARRAY is `type=="array"` and correctly falls through to normalize.
  Watch this when adding any pre-normalize validate gate.

## Subscription pipeline facts (verified 2026-06)

- Fallback chain in `download_subscription_into_cache` (usr/bin/netshift):
  validate raw body FIRST, only then `normalize_subscription_to_singbox`
  (base64 / plaintext URI list / Xray-JSON). UA fallback wraps the whole loop:
  it probes `SUBSCRIPTION_USER_AGENT_CANDIDATES` (constants.sh) when no UA is
  configured, caches the winner in `<section>.user_agent` (atomic .tmp.$$+mv).
- New per-section UCI option `subscription_user_agent` is read but NOT yet in
  the UCI schema / LuCI / ACL. Degrades gracefully (empty ⇒ auto). Treat any
  promotion to a real UI knob as a system-level change (schema + LuCI + i18n).
- `xray_json_to_uri_lines` converts Xray client configs (object|array) to share
  URIs; emits ONLY keys the facade reads (type/path/host/mode/serviceName/
  security/sni/alpn/fp/pbk/sid/flow); drops vmess (counted by
  `xray_json_count_unsupported`) and dialerProxy-chained outbounds; dedups on
  the connection part. No-regex jq + busybox-safe sed pre-gate.

## Core-switch (sing-box <-> extended) failure — DIAGNOSED on real hardware 2026-06

- SYMPTOM: switching stock->extended fails; on the router the new ~79MB binary
  sits at /usr/bin/sing-box but with perms `rw-------` (NOT executable), the
  tmpfs backup + downloaded archive remain, sing-box won't run.
- ROOT CAUSE: **rpcd timeout**. rpcd runs with `-t 30` (30s). The UI calls
  `component_action sing_box install_extended` SYNCHRONOUSLY via LuCI fs.exec.
  Download (~29MB over a slow/proxied link) + gzip extract of the 50MB binary
  (measured **13s just for extract** on aarch64 cortex-a53) exceeds 30s, so rpcd
  KILLS the process mid-flight — AFTER `tar -O > /usr/bin/sing-box` (file written
  `rw-------` under the context umask 0077) but BEFORE `chmod 0755` + the
  `LD_LIBRARY_PATH=/usr/lib sing-box version` validation. Hence the un-chmod'd
  binary, leftover backup/archive, no cleanup.
- DISPROVEN earlier guesses: (a) NOT a disk-space issue (repro'd with free
  space). (b) NOT the missing-LD_LIBRARY_PATH theory — the extended binary runs
  `sing-box version` fine WITHOUT LD_LIBRARY_PATH (libcronet only needed at
  runtime for naive); `chmod 0755` itself works under umask 0077. The code's
  chmod/validate is correct; it just never gets to run.
- FIX DIRECTION: make core-switch ASYNCHRONOUS — has `component_action_async` 
  (writes output to a file, forks the work) +
  `component_action_status` (UI polls). NetShift's updater is synchronous and has
  no async/status path. Port that model: fork the install, return immediately,
  poll status; UI shows progress instead of hitting the 30s rpcd wall.
- Secondary hardening to fold in: chmod 0755 BEFORE validation is already there
  but ordering/robustness should survive interruption; also rulesets in
  /tmp/sing-box/rulesets were `rw-------` (umask 0077) — sing-box could still read
  them as root, not the failure cause, but worth normalizing.
- Manual recovery that works: `chmod 0755 /usr/bin/sing-box` (the downloaded
  extended binary is valid), `rm -rf /tmp/netshift-sbext.*`, restart netshift.
- Router access for testing: `ssh root@192.168.1.1` (no password). aarch64,
  OpenWrt 24.10.5, overlay 60.9M (16.5M free), /tmp tmpfs 117M. scp does NOT work
  (no sftp-server) — push scripts via `echo <base64> | base64 -d > f` over ssh.

## Core-switch async fix (task-007) — on-device verified 2026-06; SECOND bug found

- task-007 async model WORKS on real hardware: `component_action_async` returns
  in 0s with a job_id (no more rpcd 30s kill), `component_action_status` polling
  goes running->finished cleanly. The PRIMARY bug (synchronous timeout) is fixed.
- BUT live-testing exposed a SECOND, deeper bug in `updates_install_sing_box_stable`
  (extended->stock): it has NO backup/rollback (unlike the extended path) AND the
  whole switch happens while NetShift's nft tproxy + dnsmasq redirect are STILL
  active. Sequence that bricked the router:
  1. install_stable removes/replaces the extended binary, then `opkg/apk install
     sing-box` needs working internet — but the only internet was THROUGH the now
     -dead VPN. opkg fails with "Operation not permitted" + DNS timeout (the nft
     kill-switch sends marked traffic to a dead sing-box).
  2. Net result: /usr/bin/sing-box GONE, no rollback, router has no working core
     and can't fetch one (extended path also fails: GitHub unreachable w/o VPN).
- This is a CLASSIC kill-switch deadlock: you can't download a new core because
  the old core (that provided connectivity) is gone.
- RESCUE that works: `/etc/init.d/netshift stop` (tears down nft/dnsmasq so direct
  internet returns) -> set a real resolver -> `opkg update && opkg install
  sing-box` -> `/etc/init.d/netshift restart`. Verified: restored stock 1.12.22,
  sing-box running.
- DESIGN IMPLICATION for the stable-rollback path (future task): before
  install_stable, KEEP a backup of the current (extended) binary on tmpfs and
  RESTORE it if the package install fails (so a failed downgrade never leaves the
  router core-less) — mirror the extended path's backup/restore. Also consider
  tearing down the redirect (or a temporary direct route) during a core swap so
  the package manager can reach the feeds. The extended->stock path fundamentally
  needs connectivity that the dead VPN may have been providing.
- Router note: stock sing-box install also drops `/etc/config/sing-box-opkg` and
  `/etc/sing-box/config.json-opkg` (conffile conflicts) — harmless, NetShift owns
  its own config path.

## sing-box-extended capability map (researched 2026-06)

- NetShift ALREADY installs sing-box-extended: `updater.sh` pulls
  `shtorm-7/sing-box-extended`; `is_sing_box_extended` gates features (today only
  xhttp transport in the facade). So the runtime platform for extended protocols
  exists; what's missing is config GENERATION (jq cm_*/cf_*), UCI schema, UI.
- Our facade currently builds only: socks4/4a/5, vless, ss, trojan, hysteria2.
  Transports: ws, grpc, httpupgrade, xhttp. No endpoint/wireguard support at all
  (`sing_box_cm_add_*_outbound` has no wireguard/endpoint).
- Extended (repo `sing-box-extended-extended/option/*.go`) adds many: anytls,
  tuic, shadowtls, wireguard(+Amnezia/AWG), warp(+Amnezia), masque, mieru,
  mtproxy, naive, openvpn, ssh, tor, trusttunnel, sudoku, bond, failover, vpn,
  vmess; transports incl. v2ray kcp/quic, simple-obfs, sip003.
- Amnezia WG schema (sing-box 1.12 `endpoint` model): an `endpoint` with
  `"type":"wireguard"`, `private_key`, `address` (listable prefix), `peers[]`
  (address/port/public_key/pre_shared_key/allowed_ips/persistent_keepalive...),
  plus nested `"amnezia": { jc,jmin,jmax,s1..s4, h1..h4 (ranges), i1..i5, j1..j3,
  itime }`. WARP = same WG core + `amnezia` + Cloudflare `profile`/`reserved`.
- Feasibility tiers for porting to our ash+jq backend:
  * EASY (pure-JSON outbound, no extra daemon, just a new cm_* + cf_* + URI/UCI
    parse): tuic, anytls, shadowtls, vmess, naive, hysteria(v1). These mirror the
    existing vless/trojan/hysteria2 pattern.
  * MEDIUM: wireguard + Amnezia/AWG and WARP — needs the `endpoints[]` array
    (new section in config skeleton, route ties to endpoint tag) + key/peer
    parsing; input format must be decided (awg:// vs wg-conf vs UCI fields).
  * HARD / likely out of scope: openvpn, mieru, masque, mtproxy(outbound),
    trusttunnel, sudoku, tor, ssh, bond/failover/vpn groups — bespoke schemas,
    some need extra config files/daemons; high test surface.
- Hard dependency for ANY of these: the user must be running the extended build;
  gate generation behind `is_sing_box_extended` and fail safe (warn + skip) when
  stock sing-box is installed, exactly like xhttp does today.

## sing-box-extended version diagnostic (task-013 — done 2026-06-05)

- BUG: `check_sing_box` (usr/bin/netshift ~3276) showed "❌ version not compatible"
  on the extended core. TWO coupled defects:
  1. `awk '{print $3}'` on `sing-box version 1.13.12-extended-2.3.2` → patch via
     `cut -d. -f3` = `12-extended-2` (non-numeric) → `[: bad number`.
  2. The compare `if [ A ] || [ B ] && [ C ] || [ D ] && [ E ] && [ F ]` was
     UNGROUPED. POSIX `&&`/`||` are EQUAL-precedence, LEFT-associative, so it
     parses `(((((A||B)&&C)||D)&&E)&&F)` — the trailing E/F gate EVERY branch,
     so 1.13.x AND 2.0.0 evaluate as not-compatible even with a numeric patch.
- FIX (Variant 2, operator-chosen): strip suffix `version=${version%%-*}` (gives
  honest semver; extended author only bumps the trailing `-extended-X.Y.Z`,
  leading major.minor.patch is true upstream sing-box) + regroup each AND-term in
  `{ ...; }`. Kept threshold 1.12.4 + printed text. Did NOT touch check_requirements
  (uses sort -V, already extended-safe). 1-file change, gates green.
- LANDMINE for future tasks: any `[ ] || [ ] && [ ]` chain in this repo without
  `{ ...; }` grouping is suspect — equal precedence means trailing AND-terms leak
  into prior OR-branches. Group every AND-term. (My first decomposition wrongly
  assumed the strip alone fixed it; the dev caught the precedence bug on live
  reasoning — TRUST dev "second defect" flags, re-derive the truth table myself.)
- Extended core real output (operator hardware, captured for the epic): version
  `1.13.12-extended-2.3.2`, Tags include `with_quic,with_wireguard,with_utls,
  with_masque,with_mtproxy,with_openvpn,with_trusttunnel,with_sudoku,
  with_naive_outbound,with_gvisor`. So the shtorm-7 build SHIPS the build-tags for
  nearly all of epic Tiers 1–3 (tuic/hysteria need with_quic ✅, AWG needs
  with_wireguard ✅, sudoku/trusttunnel/openvpn ✅) — CX-4 build-tag uncertainty is
  largely resolved EMPIRICALLY for this build; still gate generation behind
  is_sing_box_extended + tolerate a per-protocol `sing-box check` rejection.
- SECOND hardcode of the version threshold confirmed: check_sing_box hardcodes
  "1.12.4" (major/minor/patch literals + text) while SB_REQUIRED_VERSION=1.12.0 in
  constants.sh. Known rassinkhron; left as-is per operator (out of task-013 scope).

## Subscription keyword filter — Cyrillic case bug (task-010, found on hardware 2026-06)

- REAL bug (not version skew): the keyword filter's "case-insensitive" claim only
  holds for ASCII. `sing_box_cf_prepare_subscription_batch`
  (sing_box_config_facade.sh:542/543/567) uses jq `ascii_downcase`, which does
  NOT lowercase Cyrillic (or any non-ASCII).
- FIX: replace the 3 `ascii_downcase` in prepare_subscription_batch with an inline
  jq `def ucfold` (codepoint arithmetic, NO Oniguruma): ASCII A-Z (65–90)+32,
  Cyrillic А-Я (1040–1071)+32, Ё(1025)->ё(1105). Apply to BOTH the keyword list
  and the node name. `explode`/`map`/`implode`/`index` all work on the device jq.
  (Это inline — этот jq-вызов НЕ импортирует helpers.jq.)
- rejected-hash (`<section>.rejected`, md5 of body) can wedge a retry storm if a
  STUB body once got cached as rejected; it self-clears once a real body downloads
  (return 0 path rm's it). Not the root cause here but amplified the symptom.

## Workflow facts

- Contribution gating: `CODEOWNERS=@yandexru45`; PRs accepted only after Telegram
  coordination with authors (README). Reflect this in `/describe` output.
- **Frontend yarn trap (verified 2026-06):** repo `fe-app-netshift/yarn.lock` is
  CLASSIC yarn v1 format; there is NO `packageManager` pin and NO `.yarnrc.yml`.
  A local corepack yarn 4.x will try to MIGRATE on `yarn install`, polluting the
  tree with a 3000+ line `yarn.lock` rewrite + untracked `.yarn/` and
  `.yarnrc.yml`. These are NOT deliverables — discard before commit
  (`git checkout -- fe-app-netshift/yarn.lock`; rm `.yarn/`/`.yarnrc.yml`). To
  verify the gate independently without polluting, run the tools directly from
  `node_modules/.bin` (prettier/eslint/vitest/tsup) instead of `yarn install`.
  Tell frontend devs to leave yarn.lock alone.
- The frontend-ci `main.js` no-diff check: a TYPE-ONLY change in TS source
  (e.g. adding optional fields to a `types.ts` interface) produces NO main.js
  diff — that is expected/correct, not a missed rebuild.

## Subscription keyword filter (issue #5, task-002/003 — done 2026-06)

- Backend filter lives in `sing_box_cf_prepare_subscription_batch`
  (sing_box_config_facade.sh): one jq pass between candidate-select and the
  static-unsupported filter, BEFORE tag dedup + sing-box check. Covers native +
  all fallback (base64/URI/Xray) bodies and both selector branches automatically.
- UCI options (cross-layer contract, verbatim): `subscription_filter_include_keywords`
  (whitelist) / `subscription_filter_exclude_keywords` (blacklist), both UCI
  `list`. Read in the `subscription)` branch via `config_list_foreach`.
- Semantics: include=OR (empty⇒keep all), exclude=OR(drop), SUBSTRING,
  ASCII-case-insensitive (`ascii_downcase`), byte-exact for emoji/Cyrillic.
  jq: NOTE `include`/`exclude` are RESERVED jq words — devs used `$inc`/`$exc`;
  matching must use `. as $kw` inside any/all to avoid the `.`-after-pipe rebind.
- Empty-after-filter ⇒ existing fail-safe `mark_subscription_outbound_unavailable`
  + warn (NO exit 1). `skipped` stays "statically unsupported" (compute `$total`
  AFTER the keyword filter, not before).
- UI: two `form.DynamicList` in `section.js` after `subscription_group_by_countries`,
  rmempty=true, NO validator (keep emoji/space verbatim); `string[]?` fields on
  `ConfigProxySubscriptionSection` in types.ts; ru/en via locale tooling.

## PR review workflow + PR #11 findings (review-001, 2026-06-06)

- Reviewing an external PR (no `gh` CLI installed): fetch via API
  `curl https://api.github.com/repos/yandexru45/netshift/pulls/N` (meta),
  `.../files` (per-file stats), and `-H "Accept: application/vnd.github.v3.diff"`
  for the raw diff. Then `git fetch origin pull/N/head:pr-N` to get a local ref
  diffable vs `main`. Workspace `.pr-review/` + `*.txt` are gitignored (untracked).
- Decompose review by LAYER (backend / frontend+i18n / tests-packaging) into
  separate diff txt files; launch one `explore` subagent per layer IN PARALLEL
  (layers don't share files), then consolidate with the formal `code-reviewer`.
  Give each subagent an architect "systemic notes" file of HYPOTHESES to verify.
- **nftables landmine (VERIFIED on nft v1.1.3):** `tproxy ip6 to <addr>:<port>`
  REQUIRES bracketed `[addr]:port`. The unbracketed form (e.g. `::1:1603`) PASSES
  `nft -c` AND `sing-box check`, but nft normalizes it to a BARE address with NO
  port (`::1:1603` -> `[::0.1.22.3]`). Only on-device / `unshare -rn nft -f` +
  `nft list ruleset` reveals it. IPv4 `addr:port` is fine unbracketed; v6 is not.
- **Local nft verification trick (no root):** `unshare -rn nft -c -f file` /
  `unshare -rn sh -c 'nft -f f && nft list ruleset'` gives netlink in a private
  netns so you can load+inspect normalized rules. Plain `nft -c` fails with
  "cache initialization failed: Operation not permitted" without it.
- PR #11 ("Синхронизация с netshift", spgsroot, +2314/-1364, 23 files) verdict:
  **REQUIRES CHANGES**. Doc at `.pr-review/REVIEW-pr-11.md` (canonical copy would
  be `docs/tasks/sync-netshift-review-001.md`). Headline = IPv6 + DoH-block +
  global_proxy + sing-box health monitor + check_proxy rework.
  * BLOCKER B-01: unbracketed v6 tproxy rule (above).
  * Majors: nft model shift (mangle now marks ALL interface traffic, split moved
    to sing-box route rules) — `mangle_output` lost router-originated @common/
    fakeip marking (regression); `@netshift_subnets`/@common still populated each
    `list_update` but matched by NO rule (dead import path); 8x `SUBNETS_*_V6`
    dead constants; `start()` spawns `monitor_sing_box` with no pidfile+kill-0
    guard (orphan leak); over-permissive `validateIPV6` regex (accepts `:::`,
    `1::2::3`, etc.) shared by subnet+dns validators, no negative tests; 3 new
    flag descriptions concat'd inside `_()` -> ship untranslated.
  * GOOD: generated `main.js` is a faithful DRIFT-FREE rebuild (CI no-diff should
    pass); NO Oniguruma jq; UTF-8 emoji intact; i18n catalogs machine-consistent.
  * Coverage gap: the nft model shift has NO smoke test (test_global_proxy only
    checks sing-box route-rule SHAPE; test_nft byte-identical to base) — that's
    why B-01 slipped. Any nft-rule PR should add an `nft list ruleset` assertion.

## PR #11 fix-to-perfect cycle (2026-06-06, after operator merged the PR)

- Operator merged PR #11 to main, then asked to fix everything to perfection.
  Decomposed the review-doc issues into 3 task specs (docs/tasks/task-014 backend,
  -015 frontend, -016 packaging) + delegated to the 3 dev subagents, ran the
  dev<->code-reviewer loop per layer until all APPROVED. NOTE: `docs/tasks/` is
  gitignored (line 7 `docs/tasks`), so task specs are session artifacts (like
  .pr-review/), not committed — that's by project design (only TEMPLATE-*.md are
  force-tracked).
- Operator design decisions for the nft model shift: B-02=A (router-originated
  traffic stays DIRECT in the new mark-everything-in-prerouting model; document
  only, don't restore mangle_output marking) and B-03/B-04=A (remove the dead
  @netshift_subnets populate path + dead SUBNETS_*_V6). Rule: dead-code removal
  for a SET requires first PROVING every populated source is carried by a sing-box
  rule_set; the dev produced a coverage map (community->$SRS_MAIN_URL/<svc>.srs,
  user/local/remote subnets->rule_sets). DISCORD set is RETAINED (it has a
  dport-restricted mangle rule `udp dport {19000-20000,50000-65535}` that a
  sing-box route rule cannot express). M1/M2 left as non-blocking follow-ups
  (orphaned rulesets.sh helpers + unused IPv4 SUBNETS_* under SC2034).
- **dnsmasq "we-own-it" guard landmine (B-08):** a guard that infers netshift
  ownership from the PRESENCE of `netshift_*` BACKUP markers is WRONG, because
  `backup_dnsmasq_config_option` only writes a marker when the ORIGINAL value was
  non-empty. On stock/default dnsmasq (empty server/noresolv/cachesize) NO markers
  exist, so on the redundant `dnsmasq_configure force` path (monitor recovery /
  double-start) the guard flips false, re-runs backup, and records netshift's OWN
  live values (noresolv=1/cachesize=0) as the "backup" -> restore later sets
  noresolv=1/cachesize=0 instead of defaults 0/150 -> router DNS broken after stop.
  FIX: an explicit unconditional sentinel `netshift_configured=1` set in
  dnsmasq_configure, gating the short-circuit, cleared in dnsmasq_restore.
- **nft v6 NEGATIVE-guard test landmine:** the buggy unbracketed `::1:1603`
  normalizes DIFFERENTLY per nft build: `[::0.1.22.3]` on nftables v1.1.3 (WSL),
  but `[::1:1603]` on OpenWRT 24.10.6's nft (the smoke container). So a negative
  grep for `::0` OR even `\[::0` is a DEAD always-passing assertion in the smoke
  env. ROBUST pattern: `grep 'tproxy ip6 to \[' | grep -qv '\[::1\]:1603'` (any
  bracketed dest that ISN'T the correct one). Always self-prove a regression guard
  by temporarily reintroducing the bug and confirming the test FAILS.
- Environment (WSL2 Debian 12): Docker daemon socket-activation can leave a
  self-referential symlink (`/var/run/docker.sock -> /run/docker.sock` where
  /var/run IS /run); fix = `sudo rm -f /run/docker.sock; sudo systemctl restart
  docker.socket docker.service`. shellcheck not installed -> grab the static
  binary to ~/.local/bin (koalaman release tar.xz). yarn is classic 1.22.x via
  corepack (safe, no yarn.lock migration); deps install clean with --frozen-lockfile.
- FINAL integrated gates after the cycle: shellcheck (error) clean; yarn ci 439
  tests pass (was 395) + main.js idempotent rebuild (two builds byte-identical);
  smoke `all` = 84 passed / 0 failed (was 81; +3 nft v6 regression assertions);
  whole-chain `unshare -rn` confirms v6 tproxy normalizes to [::1]:1603. All 3
  layers code-reviewer APPROVED. Ready for human commit (agents never auto-commit).

## Component Manager feature (task-017 backend + task-018 frontend, 2026-06-06)

- New LuCI tab "Component Manager" (RU "Менеджер компонентов"): 3 cards
  (NetShift / sing-box stock / sing-box extended) with installed version shown
  immediately + on-demand "Check update" + status badges + update/core-switch/
  self-update actions. Core-switch MOVED out of Diagnostics into here.
- Backend (task-017, updater.sh): two NEW component_action sub-cases (the
  dispatcher is component_action() :1272, a `case "$comp:$action"`; that is the
  ONLY extension point — component_action_async/_status are component-agnostic,
  no dispatcher change for new actions). Added `sing_box:check_update_stable`
  (sync) + `netshift:self_update` (async via component_action_async). Self-update
  = Variant A: targeted pkg upgrade (download release .ipk/.apk + pkg_install),
  NOT install.sh (interactive `read`). MUST mirror the updates_install_sing_box_
  extended epilogue (:878-903): reset UPDATES_HEAL_* -> ensure_connectivity
  "extended" -> _core to /tmp file + rc -> ALWAYS updates_restore_after_swap ->
  re-emit JSON -> return rc. NEVER exit on recoverable fail (echo failure JSON +
  return nonzero). Minimal /etc/config/netshift backup. RU i18n only if installed.
- SELF-REPLACEMENT (critical, verified safe): the netshift pkg replaces the very
  /usr/bin/netshift running the worker. The async fork runs `"$0" component_action
  netshift self_update` in `( trap '' HUP; ... ) &`; busybox ash holds the whole
  script in memory, and updates_write_finished_job_state runs in the SAME subshell
  AFTER the worker returns — both complete from memory despite the on-disk swap.
  RULE: the self_update worker must contain NO exec / NO "$0" / NO re-invoke of
  /usr/bin/netshift / NO updates_restart_netshift after pkg_install. (Only
  /etc/init.d/netshift start via restore, AFTER install, as a fresh process — ok.)
- updater.sh does NOT source install.sh -> re-implement the tiny pkg helpers
  locally with the `updates_` prefix (updates_pkg_is_apk/_install_file/
  _is_installed/_candidate_version). pkg output parsed with cut/awk/grep (no
  Oniguruma). Stock candidate via opkg info/list or apk list; >= compare via
  is_min_package_version (sort -V) on leading semver ${v%%-*}.
- STABLE cross-layer contract: check_update_stable -> {success,current_version,
  latest_version,status:"latest"|"outdated"|"not_installed"}; self_update finished
  -> {success,version,message}; versions from get_system_info (netshift_version,
  netshift_latest_version, sing_box_version "not installed" when absent,
  sing_box_extended 0|1). ACL already allows fs.exec /usr/bin/netshift -> no ACL
  change for component_action.
- FRONTEND landmine caught by review (C1): NetShift's "Check update" has NO
  backend check action (there is no netshift:check_update). NetShift latest comes
  ONLY from get_system_info.netshift_latest_version. A card whose "latest" comes
  from a DIFFERENT source than a sibling MUST use a DISTINCT action kind
  (`check_netshift`, no backendAction) that refreshes systemInfo — never route it
  through the sing-box check method or write a sing-box result into its check
  slice. Generalize: when mirroring a multi-card update pattern, verify EACH
  card's check actually targets ITS OWN backend source.
- Lenient mid-job polling for self_update: the poll's fetchStatus swallows exec/
  parse errors and returns synthetic {running:true} (NOT null) so the mid-job
  binary swap isn't misreported as failure; scoped strictly AFTER a job_id is
  obtained (a failed START still surfaces), bounded by MAX_POLLS; success ->
  warning toast + window.location.reload().
- FINAL gates: shellcheck clean; yarn ci 465 tests; main.js idempotent (two builds
  byte-identical) + no yarn pollution + i18n catalogs byte-identical (fe<->luci);
  smoke all = 101 passed / 0 failed (84 -> +17 new: stablecheck x4 + selfupdate
  x13). Both layers code-reviewer APPROVED (backend 1st pass; frontend after a
  C1/S1 fix round). Ready for human commit.

## Multi-URL subscriptions (task-022 backend + task-023 frontend, 2026-06-07)

- FEATURE: a subscription section may now list MULTIPLE `subscription_url` feeds
  (UI "+"/add-another-field). Backend downloads each independently, merges all
  usable feeds' nodes into ONE node set driving the section's single
  selector/urltest group. Operator decisions (all "recommended"): UCI list +
  NO migration (lone legacy `option` reads as 1-element list via
  config_list_foreach, same as community_lists); per-URL hashed cache key
  `${section}.<md5(url)>.{json,url,rejected,user_agent}`; best-effort merge
  (section available if >=1 feed yields outbounds, unavailable only if ALL fail);
  reuse the existing facade global tag-dedup (-2/-3) for same-named nodes across
  feeds; keyword filter + country grouping apply to the MERGED set.
- BACKEND approach that WON: build ONE merged subscription JSON (concat each
  usable cache's proxy `.outbounds[]` via --slurpfile, no Oniguruma) and call
  `sing_box_cf_add_subscription_outbounds` ONCE on it. This reuses the facade's
  keyword-filter + global dedup + per-batch `sing-box check` bisection +
  selector/urltest/country-group builder UNCHANGED. The facade RESETS its public
  globals (SUBSCRIPTION_OUTBOUND_TAGS_JSON etc.) every call, so a per-feed loop
  would force hand-accumulation of the tag union — strictly more code, same
  result. Always-hash (even single URL) + `reap_legacy_subscription_cache_files`
  for the stale bare `${section}.<ext>` files = uniform path, no single-vs-multi
  branch bug. Rejected-hash kept PER-URL so one bad feed can't poison another.
- FRONTEND: trivial — `subscription_url` form.Value -> form.DynamicList modelled
  byte-for-byte on `remote_domain_lists` (per-row main.validateUrl, rmempty=true);
  types.ts string->string[]; locales actualized (fe<->luci byte-identical, ru
  filled). NOTHING in the FE reads subscription_url back, so the TS type is erased
  at runtime -> `yarn build` produces NO main.js diff (correct, not a missed
  rebuild). FE code-reviewer APPROVED first pass.
- GATES: shellcheck (error) clean; smoke `all` = 110 passed / 0 failed (was 101;
  +9 net from the new mu-case1..6 subscription assertions — see M1 below for the
  counter quirk); vitest 471 passed; tsup build idempotent, main.js no diff; no
  yarn pollution. Backend APPROVED WITH CONDITIONS (the sole condition = run full
  smoke `all`, which I did = the §4 whole-chain check). Frontend APPROVED.
- LANDMINE (verifying FE lint myself): the repo `yarn lint` script is
  `eslint src --ext .ts,.tsx` — SCOPED TO src/. Running a bare `eslint .` from
  fe-app-netshift lints the ROOT locale scripts (distribute-locales.js,
  extract-calls.js, generate-po.js/pot.js) which have pre-existing no-undef
  (console/process) errors and are NOT in the gate scope and NOT touched by FE
  tasks. Always verify FE lint with `eslint src --ext .ts,.tsx --max-warnings=0`,
  never `eslint .` — the latter is a false-alarm generator.

## UI redesign "huge dump" -> card/tab (task-024..026, 2026-06-07, IN PROGRESS)

- PROBLEM: operator says the UI is "one huge dump". Recon (2 explore agents)
  localized it to the TWO CBI forms: Sections form (section.js, 36 flat options,
  WORST = ~22 on screen for proxy/subscription) and Settings (settings.js, 27
  flat options). The 3 custom-rendered tabs (Dashboard/Diagnostic/Manager) are
  already card/grid; MANAGER is the best-designed (cards+badges+descriptor
  actions+overflow-safe CSS, pure cards.ts unit-tested) = the model to follow.
- DECISIVE RESEARCH (upstream LuCI form.js/ui.js, verified): CBI natively
  supports intra-section option-group tabs via `section.tab(name,title,descr)` +
  `section.taboption(tab, ...)`. HARD RULE: once a section has .tab(), EVERY
  option must use taboption() — plain option() renders NOTHING (silent drop).
  `depends()` works across tabs; a tab whose every option is depends-hidden
  AUTO-HIDES from the strip (feature, exploit it). Tabs-inside-a-tabbed-Map is
  supported: Map-level `.cbi-map-tabbed` and section-level
  `.cbi-section-node-tabbed` are INDEPENDENT tab groups (ui.js initTabGroup runs
  per group). Precedent: luci-app-firewall zones.js uses s.tab('general'/
  'advanced'/'conntrack'/'extra') heavily.
- SectionValue(map,section,option,subsection_class,...args): embeds a whole
  nested section inside an option slot (for card clusters). A SectionValue-
  embedded subsection has parentoption!=null so it does NOT emit data-tab (won't
  pollute the Map tab strip) — intended. For 025/026 the simpler/lower-risk
  grouping is native section.tab() (used by firewall); reserve SectionValue for
  inner card clusters only.
- STABLE CSS HOOKS for styling CBI as cards (target in styles.ts): .cbi-map-tabbed,
  .cbi-section, .cbi-section-descr, .cbi-section-node[-tabbed], .cbi-value,
  .cbi-value-title/-field/-description/-last, ul.cbi-tabmenu, li.cbi-tab /
  li.cbi-tab-disabled, .cbi-tab-descr; ids #cbi-<config>-<sid>-<option>,
  #container.<config>.<sid>.<tab>; attrs [data-section-id],[data-tab],
  [data-field="cbid…"],[data-errors]. Tab STRIP DOM is generated by ui.js
  (.cbi-tabmenu/.cbi-tab), pane/section DOM by form.js — style both.
- OPERATOR DECISIONS: Approach B-HYBRID (CBI stays the engine for load/save/
  depends/validation — zero loss; cards via CSS + section.tab grouping). Sections
  form = 4 tabs (Connection/Subscription/Routing/Advanced) + unify the two
  list-or-text triples into a smart list KEEPING all 4 UCI keys + the *_list_type
  selectors. Fix subscription_group_by_countries RU-hardcode via _(). Dashboard
  becomes FIRST tab. Mode = "all at once but ITERATE TO PERFECTION" (dev->review
  ->fix->review until flawless; no rush). 3 staged task specs: 024 design-system
  (.card + --ns-* tokens + warning/info toasts + Dashboard-first + renderButton
  everywhere) FIRST because 025/026 reuse .card; then 025 (Sections) + 026
  (Settings) in PARALLEL (different files: section.js vs settings.js).
- task-024 DONE + code-reviewer APPROVED: .card on `:root,.cbi-map` with --ns-*
  tokens (card-border/radius=4px/gap=10px/border-width=2px, success/warning/
  error/info layered over LuCI theme vars w/ hex fallbacks); MUST sit BEFORE the
  per-tab style interpolations so colored-border modifiers win the cascade. The
  four duplicated card boxes refactored to .card. showToast union now
  success|error|warning|info. Dashboard=first (order: Dashboard·Sections·
  Settings·Component Manager·Diagnostics). main.js rebuilt = big diff but PURELY
  cosmetic esbuild module-reorder (new barrel import), export symbol set
  byte-identical to HEAD, idempotent build — VERIFY export set unchanged when a
  big-but-cosmetic main.js diff appears. yarn ci green (471 tests).
- REUSABLE VERIFICATION (reviewer): LuCI custom-tab lifecycle (TabService/
  coreService) keys off el.dataset.tab section NAME, never registration order —
  reordering netshiftMap.section() calls is safe as long as section names are
  unchanged.
- LANDMINE: NO browser / NO live LuCI backend in this env (Playwright "chrome not
  found"; and LuCI needs a running rootfs anyway). VISUAL verification of the UI
  is NOT possible here — devs+reviewer establish correctness STRUCTURALLY (CSS
  cascade order, DOM-class analysis, taboption completeness, depends preserved).
  Always flag "needs human eyeball before merge" for card/tab visual changes.
- task-025 (Sections, 36 opts->4 tabs Connection/Subscription/Routing/Advanced)
  + task-026 (Settings, 27 opts->5 tabs DNS/Network/Lists&Updates/Dashboard-YACD/
  Advanced) BOTH DONE + code-reviewer APPROVED. Smart-list "unification" = VISUAL
  grouping only (re-worded the *_list_type selector titles into group headings;
  kept all 4 UCI keys + selectors) — a deeper single-widget merge was deferred as
  risky (would touch UCI keys/validators). block_doh 4-paragraph help trimmed to
  1 sentence + caveat moved to the Advanced tab DESCRIPTION (section.tab 3rd arg).
  subscription_group_by_countries RU-hardcode fixed to _() English msgids.
- REVIEW METHOD for tabbed-CBI conversions (reusable): grep `section.tab(`==N,
  `section.taboption(`==total-opts, functional `section.option(`==0 (comment hits
  ok); diff base-vs-current UCI-name SET (must be identical); diff full `.depends(`
  text (must be identical); check validate/cfgvalue/load/filter/onchange counts ==
  base. This catches the silent-drop failure mode + any rename/depends regression.
- INTEGRATION (combined 024+025+026 tree): prettier(src) clean, eslint(src
  --max-warnings=0) clean, vitest 471, main.js idempotent (md5 identical across 2
  tsup builds) + banner + `return baseclass.extend` intact, fe↔luci ru.po & pot
  BYTE-IDENTICAL, no yarn pollution. Cosmetic double-blank-line inside the CSS
  template literal is Prettier-IMMUNE (prettier doesn't format CSS-in-template) ->
  collapse by hand if operator wants perfection, then REBUILD main.js (styles.ts
  changed). Footprint ~21 files, main.js diff huge but cosmetic esbuild reorder.
  Ready for human commit (agents never auto-commit). NEEDS HUMAN EYEBALL of the
  rendered tabs before merge (no browser/LuCI in env).
- M1 (smoke harness, confirmed by reviewer): the `subscription` category parses
  `mu-*`/token results in a `sh "$x" | while read; do pass/fail; done` PIPE, so
  pass/fail run in a SUBSHELL and DON'T propagate to summary()'s PASS/FAIL globals
  -> the per-✓ marks are truth, but a `:FAIL` token prints red WITHOUT failing the
  suite count. Pre-existing project-wide convention (cm/sb/jobstate/selfheal/...),
  NOT a task-022 defect. When a smoke category uses this pattern, trust the ✓/✗
  marks, not just the "Results: N passed" line; a real gating test needs
  `done < tmpfile`.

## FIRST apk / OpenWrt 25 HARDWARE TEST (2026-06-07, router 192.168.1.101)

- TEST BOX: ssh root@192.168.1.101 (blank pw), OpenWrt **25.12.4**, target
  sunxi/cortexa7 (arm_cortex-a7_neon-vfpv4, armv7l), **apk-tools 3.0.5**, Orange
  Pi One, small overlay (98.8M total, ~60M free baseline). It is a SPARE box
  BEHIND the main gw (its default route = 192.168.1.1, 0 dhcp leases), reached
  DIRECTLY over LAN — so netshift kill-switch can't lock me out; rescue
  `/etc/init.d/netshift stop` always reachable. NO base64/openssl/xxd/od on a
  bare box -> push files with raw `cat > /tmp/f` over ssh (ssh stdin is 8-bit
  clean); base64-over-ssh FAILS (busybox base64 absent until coreutils-base64
  dep installs). sha256sum to verify transfer.
- BUILD: `docker build -f Dockerfile-apk --build-arg NETSHIFT_VERSION=<v> -t
  netshift-apk:test .`; extract via `docker create`+`docker cp
  /builder/bin/packages/x86_64/{utilities,luci}/.`. Packages are PKGARCH=all
  (noarch) so x86_64 SDK output installs on armv7 fine.
- **BUG #1 (REAL, apk-only, HIGH): apk `mkpkg` REJECTS version strings with a
  dash in the upstream part.** `apk version --check` rejects `0.8.5-rc1-r1` and
  `0.8.5-test-904fd64-r1` (rc=1) but accepts `0.8.5-r1`, `0.07062026-r1`,
  `0.8.5_rc1-r1`. apk treats `-` as the `-rN` release separator. So a
  NETSHIFT_VERSION with a dash (an RC tag `0.8.5-rc1`, or a `git describe`
  `0.8.5-11-gHASH`) makes the apk build DIE at `package/.../netshift failed to
  build` while the IPK build tolerates it (why it never showed on the 24.10/ipk
  main router). build.yml's normal `git describe --tags --exact-match ||
  0.$(date)` gives clean numerics so prod releases are usually safe — but ANY
  dashed tag breaks apk-only. FIX direction (packaging task): sanitize dashes in
  the apk Dockerfile/Makefile version (`-`→`_` or `.`) OR document the
  no-dash-tag constraint. Dockerfile-apk passes version RAW (the known ipk-vs-apk
  v-prefix asymmetry is nearby).
- INSTALL + RUNTIME CHAIN ON OWRT25/apk = WORKS. `apk update` then `apk add
  --allow-untrusted /tmp/.../netshift-*.apk` pulled all deps (sing-box 1.12.17,
  jq 1.8.1, bind-dig, coreutils-base64, kmod-nft-tproxy). Version stamp applied
  in BOTH constants.sh (0.8.5) and luci main.js. Fresh install with EMPTY
  proxy_string correctly ABORTS ("Outbound section not found") — expected, not a
  bug. After setting a valid test SS proxy
  (`ss://<b64userinfo>@192.0.2.10:8388#test`) + restart: sing-box running, nft
  `NetShiftTable` with correct marks (0x00100000/0x00200000 -> tproxy
  127.0.0.1:1602), rt_tables `105 netshift`, dnsmasq -> 127.0.0.42, Clash API
  :9090 listening, `sing-box check` rc=0, `global_check` renders perfectly
  (UTF-8 emoji intact — apk packaging preserves encoding). get_system_info JSON
  correct, fetched `latest: 0.8.6` from GitHub.
- ASYNC CORE-SWITCH path WORKS on apk: `component_action_async sing_box
  install_extended` returns instantly with job_id (no rpcd 30s brick — task-007
  fix holds on apk). NOTE: `component_action_status` JSON has keys
  success/running/exit_code/message — NO "status" key (don't poll-grep for
  "status").
- **BUG #2 (minor, cosmetic): check_update_stable shows apk `-r` suffix.**
  returns current_version "1.12.17" vs latest_version "1.12.17-r1" (status
  correctly "latest" — the ${v%%-*} semver compare works, only the DISPLAY
  string carries apk's -r1). UI would show "latest: 1.12.17-r1". Polish for apk.
- **FINDING #3 (GOOD — graceful failure validated): extended install FAILED
  SAFELY on the small overlay.** Download (armv7 v1.13.12-extended-2.4.0) ok to
  tmpfs, but extraction ran out of overlay space; updater rolled back cleanly:
  stock core stayed executable & running, no leftover /tmp/netshift-sbext.*, no
  brick. The extract logic (updater.sh ~1016-1027) already rm's the live binary
  then streams the new member straight onto the final path (never 2 binaries on
  overlay) + tmpfs backup/restore — well-designed. The HISTORIC brick did NOT
  recur. Real limitation: the EXTENDED binary (~50MB+) simply can't fit a
  ~12-60M overlay (Orange Pi One class) — matches the documented ≥25MB
  requirement; extended is not installable on small-flash devices. Failure msg
  even guesses the cause correctly.
- **FINDING #5 (the one to chase): after the FAILED extended-install rollback,
  stock `sing-box version/help/check` SEGFAULT (rc 139)** while the already-
  RUNNING daemon kept working. ROOT: the rollback `mv backup -> /usr/bin/sing-box`
  restored a binary, but the on-disk file ended up being a PRE-EXISTING stale
  `Jun-4` binary (the box had an old sing-box before my test); the live daemon's
  /proc/PID/exe showed `-> /usr/bin/sing-box (deleted)`. So the segfault is an
  ARTIFACT of (failed extended rollback) × (pre-existing stale binary) × (100%-
  full overlay during the op), NOT a clean repro of our code. BUT worth a guarded
  re-test on a CLEAN box with adequate overlay: confirm a normal apk
  install/reinstall of stock sing-box 1.12.17 on armv7/OWRT25 does NOT segfault
  on `version`/`check` (if it does, that breaks sing_box_save_config validation).
- OVERLAY 100% during the failed extract caused transient `uci: I/O error` +
  `crontab: can't create root.new` on the first stop; `du` of overlay upper was
  only 21M while `df` said 100% (loop/squashfs accounting + fs fragmentation).
  Stopping netshift freed it back to 61%, then clean.
- CLEANUP (always do this): `/etc/init.d/netshift stop` -> `apk del
  luci-i18n-netshift-ru luci-app-netshift` then `apk del netshift` (apk
  reverse-dep purge also removed sing-box/jq/kmods, 146->128 pkgs). prerm
  correctly removed `105 netshift` from rt_tables. /etc/config/netshift is a
  conffile (survives removal — rm by hand if you want a pristine box). Final
  state restored: no pkgs/table/rt/proc, internet OK, overlay 40%, dnsmasq
  noresolv=0. Box returned to baseline.
- Minor: a fresh-box `restart` logs `crontab: can't open 'root'` (no root
  crontab spool yet) — cosmetic, cron line still created later.

## Finding #5 RESOLVED + task-027 backup-integrity fix (2026-06-07)

- RE-VERIFIED #5 on a CLEAN box: freshly apk-installed stock sing-box 1.12.17
  (the REAL 40119352-byte / 40MB armv7 binary) runs version/check/help all rc=0,
  NO segfault. So #5 (segfault) was NOT our bug — it was a corrupt-restore
  ARTIFACT: last session's failed extended-install rollback had `mv`'d a
  TRUNCATED 12.7MB backup onto /usr/bin/sing-box (real binary is 40MB) under a
  100%-full overlay, and that truncated file segfaulted. KEY TELL: binary SIZE
  mismatch (12.7M vs 40M) + the live daemon's /proc/PID/exe showed "(deleted)".
- BUT re-reading updater.sh exposed a REAL latent bug behind the artifact: the
  core-swap backup `cp -p <bin> <tmpfs-backup> 2>/dev/null` checked only cp's exit
  code, with NO size/integrity check. busybox cp can truncate under tmpfs ENOSPC
  and silently pass the guard, so the rollback `mv backup -> /usr/bin/sing-box`
  could restore a CORRUPT (segfaulting) binary — the safety net handing the router
  a broken core. Same pattern in BOTH the extended path (~997-1014, rollbacks
  ~1019-1060) AND the stable path (~1138-1155 + updates_stable_rollback).
- FIX = task-027 (shell-backend-developer, code-reviewer APPROVED, gates green):
  two busybox-safe helpers `updates_verify_copy src dst` (0 iff dst size == src
  size via `wc -c < file`) and `updates_backup_is_complete backup expected_size`
  (vs a size STASHED at backup time, NOT the live path which a half-written
  extract may have clobbered). Gate all 4 backup-cp sites (abort BEFORE touching
  the live binary -> working core intact); guard all 4 restore sites (extended
  x3 + updates_stable_rollback, now takes $3/$4 sizes, both call sites threaded)
  to REFUSE restoring a truncated/missing backup (honest failure JSON + error log
  instead of installing a broken core). NO exit 1 (async worker -> would skip JSON
  + epilogue); used the updates_log+echo+return 1 pattern. +test_backup_integrity
  (alias backupguard, 10 assertions). shellcheck clean; smoke all = 120 passed/0
  (110 -> +10).
- BUSYBOX SIZE-COMPARE IDIOM (reusable, reviewer-flagged): end size guards with
  `[ -n "$x" ] && [ "$x" = "$y" ]` — the `-n` short-circuit makes an empty `wc -c`
  output fail SAFE (refuse restore) instead of `[: arg`. Use `wc -c < file`
  (redirect, no leading-whitespace) NOT `wc -c file` (arg form has whitespace).
- ON-HARDWARE PROOF (router 192.168.1.101): pushed the fixed updater.sh, sourced
  the real functions, made a real 40MB source + a head-c-truncated 12.7MB backup
  (the exact size that originally segfaulted) -> all 7 assertions PASS incl.
  rollback-refuses-truncated (live NOT clobbered) and rollback-restores-complete.
  PERF note: `dd bs=1 count=12M` to truncate is GLACIAL on armv7 (timed out);
  use `head -c N` instead. Box cleaned to baseline after (apk del sing-box; no
  pkgs/table/binary, internet OK, overlay 40%).

## task-028 (drop v from ipk) + task-029/030 (on-demand NetShift update check) (2026-06-07)

- task-028 DONE+APPROVED+COMMITTED by operator (76ac754): removed the `v`-prepend
  from Dockerfile-ipk (line 7 `export NETSHIFT_VERSION="v${...}"` -> raw
  `ENV NETSHIFT_VERSION=${...}`, mirroring apk). Verified: ipk build 0.8.6 ->
  `netshift_0.8.6-r1_all.ipk`, control `Version: 0.8.6-r1`, stamped
  `NETSHIFT_VERSION="0.8.6"` (no v anywhere); apk regression ok; install.sh
  matches by NAME prefix (not version) so unaffected; build.yml version from git
  tag not the Dockerfile v; smoke 120/0. packaging.md §3 updated. This was the
  operator's chosen fix for the OWRT24/ipk "falsely outdated" UI symptom.
- THEN operator pivoted: the REAL fix wanted = make NetShift update check
  ON-DEMAND (button only), like the sing-box cores, instead of auto-fetching on
  every UI mount. Root cause: get_system_info did a `curl .../releases/latest`
  on EVERY call (netshift:3604), and the UI calls get_system_info on mount
  (manager/initController.ts:382, diagnostic:523) -> entering a tab = a GitHub
  request.
- task-029 (backend, APPROVED, smoke 127/0): get_system_info now does ZERO
  network I/O — `netshift_latest_version="unknown"` constant (KEY KEPT as the
  sentinel the UI understands). New `updates_check_netshift` worker in updater.sh
  + `netshift:check_update)` in the component_action() router (~1792, next to
  netshift:self_update — NO ACL change, component_action already allowed). It
  reuses the PRE-EXISTING `updates_netshift_latest_tag` + `NETSHIFT_RELEASE_API_URL`
  (task-017), NORMALIZES a leading `v` on BOTH sides (${x#v}) + `%%-*` semver +
  the existing `is_min_package_version` -> echoes the SAME JSON as
  updates_check_sing_box_stable (success/current_version/latest_version/status).
  NO exit (component_action worker -> echo {json}; return N). global_check now
  fetches latest ITSELF (one-shot SSH diag, network ok there). dev build
  (*COMPILED* placeholder) -> status latest. This ALSO fixes the v-compare bug at
  the backend.
- task-030 (frontend, APPROVED, 472 tests, main.js idempotent): new
  NetShiftShellMethods.netshiftCheckUpdate() -> fs.exec ['component_action',
  'netshift','check_update'], parsed by the EXISTING parseComponentCheckUpdate
  (same shape as cores). runNetshiftCheck REWRITTEN to mirror runSingBoxCheck —
  NO LONGER calls fetchSystemInfo as the check (that was the trap: it'd re-read
  "unknown" forever). cards.ts netshiftStatus now derives from
  managerChecks.netshift.status (null->neutral until checked); REMOVED the
  fragile `installed === latest` string compare + systemInfo-latest dependency;
  KEPT the dev guard. Diagnostic getNetshiftVersionRow already treats unknown
  latest as neutral -> no code change, no auto-"outdated". Orphaned
  `'Latest version is unknown'` msgid removed; fe<->luci catalogs byte-identical.
- PATTERN (on-demand component check, reusable): backend worker via
  component_action MUST `echo {json}; return N` (NEVER exit — kills dispatcher);
  JSON keys MUST mirror updates_check_sing_box_stable so the FE
  parseComponentCheckUpdate works unchanged; FE check fn mirrors runSingBoxCheck
  and writes managerChecks.<component>; the card derives status from
  managerChecks (null=neutral), NOT from systemInfo. Canonical regression:
  installed v0.8.6 vs latest 0.8.6 -> latest (not outdated).
- INTEGRATION VERIFIED (source-level, no live LuCI): get_system_info no curl;
  router has netshift:check_update; FE method args
  ['component_action','netshift','check_update']; runNetshiftCheck has 0
  fetchSystemInfo calls. All gates green. Ready for manual commit (operator
  commits; agents never auto-commit).

## task-031/032 subscription format/UA preference (try Xray-JSON first) (2026-06-07)

- PROBLEM (from a user, Иван): a panel returns a sing-box config (missing
  xhttp/hysteria2 outbounds) under the default `singbox/<ver>` UA, but returns an
  Xray JSON (which HAS xhttp) under a Happ-like UA. Manual paste of the link
  works (xray-json parsed), via subscription it doesn't.
- ROOT CAUSE (explore-verified): download_subscription_into_cache UA-probe loop
  BREAKS on the FIRST UA whose body is usable (bin/netshift:566-585). UA order
  (auto) = singbox/<ver> ALWAYS FIRST -> cached winner -> whitelist (v2rayN Happ
  Hiddify Clash.Meta ClashMetaForAndroid). So a valid sing-box JSON under the
  first UA terminates the probe and the Happ/Xray UA is never tried.
- SECOND GAP (on record, OUT OF SCOPE): xray_json_to_uri_lines emits xhttp
  (helpers.sh:1208-1211) but NOT hysteria2 (protocol gate only vless/trojan/
  shadowsocks — hysteria2 isn't an Xray protocol). hysteria2 works via the
  URI-list path, not the xray-json converter. If a user reports missing
  hysteria2-from-xray-json, need a sample of their subscription FIRST (likely
  it's in clash-yaml or uri-list, not xray-json) before any converter fix.
- OPERATOR DECISION: Variant A — a per-section UCI option
  `subscription_format_preference` (auto|xray|singbox, default auto) that REORDERS
  the UA candidates (NOT changing the break-on-first-usable loop). dropdown
  values auto/xray/singbox; explicit user choice OUTRANKS the cached UA-winner.
- task-031 (backend, APPROVED W/ CONDITIONS->met, smoke 127/0): new 3rd arg
  `format_preference` to build_subscription_user_agent_candidates (helpers.sh);
  xray -> SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES="v2rayN Happ" (new constant)
  FIRST, then default, then cached winner, then rest; singbox/auto/empty/unknown
  -> today's exact order (unknown==auto, forward-compatible); configured-UA
  short-circuit unchanged (explicit UA still emits ONLY itself). The dedup `seen`
  loop is reused so the front-loaded xray UAs outrank the cached winner.
  download_subscription_into_cache reads the option (default auto) + passes 3rd
  arg. UCI example documents BOTH the new option AND the previously-undocumented
  subscription_user_agent. CASE I = 9 assertions, all OK in smoke.
- task-032 (frontend, APPROVED): form.ListValue subscription_format_preference in
  the `subscription` tab modelled on subscription_update_interval; values
  auto/xray/singbox, default auto, same depends; type union added to
  ConfigProxySubscriptionSection (optional). section.js+type-only -> main.js NO
  diff (correct). 4 new msgids, ru filled, fe<->luci byte-identical. Contract
  verified end-to-end: bin reads name, helpers branches on xray, FE writes exactly
  those values.
- REUSABLE (reviewer): for backend-coupled UI enum dropdowns the safe-match
  criterion is "every UI value is handled + unknown/empty -> sane default", NOT a
  strict 1:1 set match (here auto/singbox/unknown all fold to the default
  ordering, only xray is distinct).
- TECH-DEBT FOLLOW-UP (found by reviewer, pre-existing, harness-wide, NOT a
  task-031 defect): the smoke `fb-case*`/`rh-case*` tests parse tokens via
  `cmd | while read ... pass/fail` — the `while` runs in a PIPE SUBSHELL so
  PASS/FAIL increments are LOST; a `:FAIL` prints red but does NOT fail CI
  (pipeline rc = while rc = 0, set -e doesn't trip). The COUNTED pattern is
  `while read ... done < "$out"` (redirect, current shell) used by
  test_backup_integrity. Worth a dedicated task to migrate fb/rh parsers so these
  assertions are truly gated. Until then, trust the per-token ✓/✗ marks, not just
  "Results: N passed".

## task-033 CRITICAL multi-section regression 0.8.5->0.8.6 (2026-06-10)

- USER REPORTS: after 0.8.5->0.8.6 upgrade, creating ANY extra connection section
  (even URL-only / unreachable endpoint) black-holes ALL networking: sing-box
  stays up but every flow -> `outbound/direct[direct-out]: i/o timeout`, DNS-over-
  proxy n/a on all servers, some report sing-box won't come up. Rollback to 0.8.5
  fixes it.
- DIAGNOSIS METHOD (reusable): bisected 0.8.5..0.8.6 with an explore agent, then
  PROVED config-gen is NOT the bug by generating a 2-section (ss+hysteria2) config
  in the OWRT smoke container with a DEVICE-FAITHFUL uci (real /etc/config/netshift
  + config_load via /lib/functions.sh) -> valid, both outbounds, sing-box check
  PASS. LANDMINE I hit: a harness that points NETSHIFT_CONFIG at a RAW uci FILE and
  calls config_load on it returns ALL-EMPTY config_get (incl. the first section) ->
  looks like "hysteria2 wipes config" but it's a HARNESS ARTIFACT, not a bug.
  ALWAYS repro device-faithfully (real `uci`/`/etc/config`), never a raw-file
  config_load. I distrusted the artifact and re-verified -> correct call.
- ROOT CAUSE: the nft marking-model rewrite (commit 03806d7 "ipv6+doh-block",
  finalized d391e32 which deleted @netshift_subnets/NFT_COMMON_SET_NAME). 0.8.5
  marked ONLY traffic destined to @netshift_subnets + FakeIP range into sing-box
  (destination-selective = fail-open by construction). 0.8.6 marks ALL LAN tcp/udp
  into sing-box (FAKEIP_MARK 0x00100000) with route.final=direct-out and lets
  sing-box decide via FakeIP DNS. THE BUG (confirmed on a LIVE kernel by the
  backend dev): sing-box's OWN egress (direct-out, proxy-server dials, DNS upstream)
  inherits the tproxy SO_MARK 0x00100000, gets re-caught by
  `ip rule fwmark 0x100000/0x100000 table 105` (-> local default dev lo -> tproxy)
  -> LOOPS -> i/o timeout. And nothing ever APPLIED NFT_OUTBOUND_MARK (0x00200000)
  to sing-box egress (it was referenced ONLY in the dead `mangle_output meta mark
  0x00200000 return` rule). 0.8.5 masked this because unrelated traffic never
  entered sing-box. So one not-ready section poisons the WHOLE shared pipeline.
- FIX (task-033, APPROVED, smoke 131/0): emit sing-box `route.default_mark =
  NFT_OUTBOUND_MARK` so ALL sing-box egress is stamped 0x00200000. The ip rules
  match ONLY 0x00100000 (FAKEIP) and the two marks are DISJOINT BITS (bit20 vs
  bit21), so 0x00200000 egress escapes to the main table + the existing
  mangle_output return rule fires -> fail-open restored. 2-line surgical change:
  sing_box_cm_configure_route gained an OPTIONAL 6th arg default_mark (emitted as a
  jq NUMBER via tonumber; empty arg = byte-identical to legacy 5-arg); bin/netshift
  sing_box_configure_route computes `$(( NFT_OUTBOUND_MARK ))` (ash hex->decimal
  2097152 because jq tonumber can't parse hex) and passes it to BOTH route branches
  (auto-detect + explicit) -> covers v4+v6. NO sacred VALUE changed (only APPLIES
  the existing constant). Features preserved (IPv6/DoH-block/per-section/DNS-over-
  proxy untouched). New test_section_isolation (alias isolation) incl. a LIVE-kernel
  proof: si-live-loop-fakeip-blackholes (reproduces bug) + si-live-loop-outbound-
  escapes (proves fix). Whole-chain verified: device-faithful 2-section config has
  route.default_mark:2097152, sing-box check PASS.
- REUSABLE: nft `ip rule fwmark X/X` is a MASKED match -> egress stamped with a
  DISJOINT-bit mark escapes. The standard sing-box tproxy "mark everything" model
  REQUIRES route.default_mark (or per-outbound routing_mark) on sing-box egress, or
  its own connections loop back into tproxy. When reviewing "mark everything"
  tproxy designs, always check that sing-box egress carries the escape mark.
- READY for manual commit (agents never auto-commit). NOT yet tested on real
  hardware with multiple sections — the live-kernel loop/escape proof is in the
  smoke container (egress mark chain + real ip rule); a real LAN-client end-to-end
  path needs a device (container busybox ip lacks netns/veth).

## task-034 selective marking (CPU regression) + hardware test (2026-06-10)

- SECOND facet of the 0.8.6 nft "mark everything" regression (sibling of
  task-033): users (Oleg etc.) report ALL traffic goes through sing-box even when
  only selected lists are proxied -> torrent/4K pins sing-box at 100% CPU on weak
  routers (Orange Pi R1 Plus LTS / RK3328). 0.8.5 marked selectively (proxied
  subnets + FakeIP range) so direct traffic bypassed sing-box. task-033's
  default_mark fixed the egress LOOP, NOT the ingress VOLUME — different bug.
- FIX (Option 1, operator-chosen): restore destination-selective nft marking —
  mark (union of proxied subnets) + FakeIP 198.18/15 + DoH-CIDRs (+IPv6 mirror);
  mark-EVERYTHING only when global_proxy active. Re-added NFT_COMMON_SET_NAME
  (+_V6) set, restored the subnet-population path deleted in d391e32 (feeding the
  nft set ALONGSIDE the sing-box ip_cidr rule_set from ONE centralized point so
  they can't drift). KEY INSIGHT: nft only decides ENTER-or-not; per-section
  outbound selection stays inside sing-box route rules -> a single union set is
  correct for multi-section. router-origin stays direct (task-033 default_mark +
  mangle_output untouched). global_proxy read in nft layer via
  get_global_proxy_section (UCI-only, no side effects).
- RE-OPEN: smoke 143/0 + code-review APPROVED, but ON HARDWARE the live nft chain
  was STILL mark-all + netshift_subnets set absent, despite the installed binary
  containing the selective code. ROOT: create_nft_rules was NOT IDEMPOTENT —
  `nft add chain/rule` only APPEND, the table was never flushed. On the
  respawn/upgrade path (no clean stop) a STALE mark-all rule from the prior build
  sat ATOP the prerouting chain and marked everything before the selective rules.
  clean stop->start was fine (stop_main deletes the table); apk reinstall / procd
  respawn / crash was not. FIX: `nft_delete_table` (new nft.sh helper) as the
  FIRST action in create_nft_rules -> idempotent rebuild. Strengthened smoke test
  Scenario 6 PRESEEDS a stale mark-all table + runs create_nft_rules with NO
  external delete -> proves flush clears it (revert flush => 16/1; with => 17/17).
  smoke all 148/0. code-review-002 APPROVED.
- HARDWARE VERIFIED (router 192.168.1.101, OWRT25/apk): after the flush fix, a
  real `create_nft_rules` (direct + via init restart) produces SELECTIVE rules
  (`daddr @netshift_subnets` + `daddr 198.18.0.0/15`, NO `l4proto tcp/udp meta
  mark set` mark-all) and CREATES netshift_subnets. Final live chain: 0 mark-all /
  2 selective, sing-box up, internet+DNS OK. The CPU regression is fixed (direct
  traffic no longer enters sing-box). Counters 0 on the subnet set only because
  that subscription has domain lists (FakeIP), no subnet lists — normal.
- LANDMINE #A (apk equal-version no-overwrite): `apk add --force-reinstall
  <pkg>` with the SAME version (0.8.6-r1 over 0.8.6-r1) does NOT reliably
  overwrite the on-disk files on OWRT25/apk — I chased a ghost for several steps
  thinking the new code was installed when nft.sh was still the old build. To
  force a real file refresh, BUMP THE VERSION (built 0.8.7) so apk does a true
  upgrade. Always verify a fix landed on-disk by grepping the installed file
  (e.g. `grep -c nft_delete_table /usr/lib/netshift/nft.sh`), not by trusting
  apk's "force-reinstall".
- LANDMINE #B (apk post-install/upgrade trigger HANGS on OWRT25): the netshift
  post-upgrade trigger (which runs the service start/restart) BLOCKS apk
  indefinitely (start waits on network/subscription), leaving the apk DB on the
  OLD version + holding /lib/apk/db/lock, while the FILES are already unpacked
  correctly. Symptom: `apk add` "stuck", `ERROR: Unable to lock database:
  Resource temporarily unavailable` on the next call, a zombie `apk add` in
  `ps`. Recovery: `pkill -9 apk; rm -f /lib/apk/db/lock`. This is a REAL apk-path
  bug worth a packaging fix (post-install must not synchronously block on a
  network-dependent service start — enable/start should be detached/non-blocking
  or deferred). Functionally the files install fine; only the DB version record
  and the trigger hang. Flag to packaging.
- LANDMINE #C (router teardown drops the SSH session): `/etc/init.d/netshift
  stop`/`restart` rebuilds DNS/nft and frequently kills the ssh control session
  mid-command; run teardown/restart with `&` + a generous sleep, then RE-CONNECT
  in a fresh session to read results. Don't trust a truncated command as failure.
- LANDMINE #D (procd respawn contaminates manual nft tests): killing sing-box /
  deleting the nft table for an isolated test is instantly undone by procd
  respawn / the monitor re-applying the service ruleset; to test create_nft_rules
  in isolation you must disable the service (shutdown_correctly=1 + kill monitor)
  or do it in the smoke container, not on a live procd-managed router.

## task-035 + task-036: monitor procd-lock hang + monitor leak (2026-06-11)

- USER (Oleg): changing subscription settings does nothing — dashboard frozen,
  no new logs. CONFIRMED ON HARDWARE (clean reboot, not a session artifact): 1st
  reload after boot completes, 2nd+ reload HANG forever → settings never applied.
- ROOT (task-035): start_main launches the health monitor as a bare
  `monitor_sing_box &`. procd runs init actions holding the service lock on
  fd 1000 (/tmp/lock/procd_<name>.lock — confirmed canonical via
  openwrt/packages#12807). The bare `&` inherits fd 1000; the monitor is an
  infinite loop so it holds the procd lock FOREVER → next reload/restart blocks
  on `flock 1000` indefinitely. Hardware proof: the process holding
  procd_netshift.lock == netshift_monitor.pid, child `sleep 10`; subsequent
  reload wrappers stacked on `flock 1000`.
- FIX (task-035, APPROVED review-001): launch the monitor detached —
  `setsid /bin/sh -c 'exec 1000>&- 2>/dev/null; exec /usr/bin/netshift __monitor'
  </dev/null >/dev/null 2>&1 &` + a hidden `__monitor` CLI dispatch case +
  monitor self-writes $$ to MONITOR_PIDFILE (new constant). CRITICAL: `setsid`
  ALONE does NOT close fd 1000 (busybox sets no CLOEXEC) — the explicit
  `exec 1000>&-` is load-bearing (the fd-hygiene test must fail the setsid-only
  variant too, and it does). smoke 152/0.
- task-035 INTRODUCED A LEAK (caught on hardware): each detached monitor
  self-writes $$ to the pidfile, so the pidfile only remembers the LATEST
  monitor; stop()/reload kills only that one; monitors from prior reloads
  (orphaned to init by setsid) survive → accumulate.
- FIX (task-036, APPROVED review-002): `_kill_stale_sing_box_monitors()` reaps
  ALL detached monitors by the unique `__monitor` argv marker
  (`pgrep -f "/usr/bin/netshift __monitor"`), with numeric `$$`/`${PPID:-0}`
  self/parent exclusion, called from BOTH stop() and start_sing_box_monitor
  (which now reaps + rm pidfile + ALWAYS spawns one fresh, replacing the old
  "return 0 if alive" guard). Reachable ONLY from start()/stop(), NOT from
  monitor recovery (which uses stop_main/start_main) → can't self-kill. smoke
  155/0, discriminator real (old guard → 2/7 FAIL).
- HARDWARE-MEASUREMENT LANDMINE (cost me ~10 probes of false "2-3 monitors"):
  counting monitors on a slow armv7 router via `pgrep -f netshift __monitor` or
  per-pid `ls /proc + cat /proc/$p/cmdline` is UNRELIABLE — (a) `pgrep -f`
  substring-matches YOUR OWN diagnostic `ash -c '...__monitor...'` shell, and
  (b) iterating `ls /proc` then reading each `/stat` races transient child
  processes of your own command that die mid-read (show as alive in `kill -0`
  then "no such file"). USE A SINGLE ATOMIC SNAPSHOT: `ps w > /tmp/s.txt` then
  `grep "ash /usr/bin/netshift __monitor" /tmp/s.txt | grep -v grep`. That gave
  the truth: exactly ONE real monitor after reboot AND after 3 reloads. Always
  verify process counts on-device with an atomic `ps` snapshot, never live
  pgrep/proc-walk.
- FINAL HARDWARE STATE (0.8.8, atomic ps): sing-box 1, monitors 1, stuck reloads
  0, procd-lock holders 0, nft mark-all 0 / selective 2 (task-034),
  route.default_mark 2097152 (task-033), internet OK, reloads no longer hang.
  ALL of task-033/034/035/036 verified working together on OWRT25/apk hardware.
- apk INSTALL on OWRT25 (reconfirmed): to land new files use `apk add
  --no-scripts` (skips the post-install/upgrade trigger that hangs on the
  network-blocking service start — landmine #B) + bump the version (equal-version
  no-overwrite — landmine #A), then start the service manually. `--no-scripts`
  is the clean workaround for the hanging trigger.
- OUTSTANDING FOLLOW-UP (review-001 M1 / review-002 M3, NOT fixed):
  `start_subscription_startup_retry_worker` (~netshift:770-808) backgrounds an
  infinite `( … ) &` from start_main with NO setsid / NO `exec 1000>&-` → SAME
  fd-1000 inheritance class; can re-introduce a reload hang when a subscription
  is unreachable at reload time. Also its `pid` (~:774) is not local. Worth a
  task to apply the same detach (ideally a shared launcher helper to avoid a 3rd
  copy of the setsid pattern).

## task-037 + task-038: hype-protocol coverage (hysteria2 from Xray + graceful-skip + splithttp) (2026-06-11)

- USER asked: are hysteria2 + xhttp supported EVERYWHERE (url / subscription /
  urltest / outbound_json)? Audit (explore) produced a full matrix. Key findings:
  url == urltest == selector (all route through sing_box_cf_add_proxy_outbound —
  identical support); vless/trojan/ss/hysteria2 + ws/grpc/xhttp covered on those +
  uri-list subscription + outbound_json; xhttp gated on is_sing_box_extended.
- OPERATOR CORRECTION (important): I initially concluded "hysteria2 can't be in
  Xray JSON". WRONG. Real subscriptions (a private.json = 49-element ARRAY of Xray
  configs, Hiddify/v2rayN-style) carry Hysteria2 as protocol:"hysteria" +
  streamSettings.hysteriaSettings.{version:2,auth} + settings.address/port +
  tlsSettings. ALWAYS check a real sample before declaring a protocol absent.
- PRIVACY: private.json is local-only with real keys/servers. I extracted ONLY
  structure (field names/types) + aggregate counts via python/jq, redacting all
  values. Devs/tests used synthetic placeholders only. NEVER leak its values.
- task-037 (APPROVED, smoke 155/0): added a hysteria branch to
  xray_json_to_uri_lines — select protocol=="hysteria", gate
  (hysteriaSettings.version // 0)==2 (v1/missing skipped, no fatal), peer from
  settings.address/port (not vnext/servers), cred from hysteriaSettings.auth,
  scheme hysteria->hysteria2, emit hysteria2://auth@host:port?sni&insecure&alpn&obfs
  (NO type=), all via the existing safe()/kv() no-Oniguruma helpers. REUSED the
  existing generic $conn dedup (no 2nd dedup/no sort) — collapses the heavy
  real-world duplication. NO facade change needed (facade already parses
  hysteria2:// and reads sni/insecure/alpn/obfs/obfs-password).
- task-038 (APPROVED, smoke 155/0): (a) the `*)` default arm of
  sing_box_cf_add_proxy_outbound was `log fatal; exit 1` — one unsupported link
  (tuic/wireguard/etc.) in a url/selector/urltest input ABORTED THE WHOLE CONFIG.
  Changed to `log warn; echo "$config"; return 1` (graceful skip). CONFIG-WIPE
  SAFETY pattern (reused from task-033 lesson): every caller does `local _new` on
  its own line + `if _new=$(...) && [ -n "$_new" ]; then config=$_new`; group
  member tag added ONLY on success (no dangling urltest/selector member);
  all-unsupported section -> mark_section_outbound_unavailable (append-only to
  SUBSCRIPTION_UNAVAILABLE_SECTIONS) -> reject route rule. (b) splithttp (pre-rename
  name of xhttp) now an alias in the facade transport builder AND
  xray_json_to_uri_lines (network splithttp->xhttp, xhttpSettings // splithttpSettings,
  emit type=xhttp; never a literal splithttp downstream). Fixed the false
  facade comment claiming tuic/hysteria1/anytls/shadowtls were handled.
- HARDWARE-DATA PROOF on the REAL private.json (in smoke container, aggregates
  only): xray_json_to_uri_lines emits 363 URIs after dedup (from 3669 outbounds ~
  10x collapse), of which hysteria2=19 (was 0 before — proves task-037 works on
  real data), vless 339, trojan 5; type= distribution tcp 29 / ws 301 / grpc 10 /
  xhttp 4; literal "splithttp" = 0 (normalization works). Facade on clean single
  calls: vless+tcp -> NO transport (correct), vless+ws -> transport.type=ws.
- HARNESS LANDMINE (don't repeat): driving sing_box_cf_add_proxy_outbound in a
  loop over ALL 363 nodes into ONE reused `config`/section var gave a bogus
  "all 363 transport=ws" + a sing-box-check FAIL — an ARTIFACT of reusing one
  section/config across hundreds of heterogeneous nodes, NOT a code bug (proven by
  the clean per-node check above). The REAL subscription path goes through
  normalize_subscription_to_singbox + the batch builder, which the SHIPPED smoke
  test (fb-caseO end-to-end + sing-box check, green) exercises correctly. Don't
  hand-roll a 363-node-into-one-section e2e; trust the smoke harness for config
  integrity, use the real path or per-node checks.
- jq-in-shell-string landmines (recorded for backend): an apostrophe inside a jq
  comment within `jq -er '...'` CLOSES the shell string (SC1073/etc + runtime
  break) — keep jq comments apostrophe-free; `((` at a jq pipe-element start trips
  shellcheck as arithmetic — split into single-paren `as` bindings.
- STILL TODO before/with release: these (task-027..038) are all UNCOMMITTED in the
  tree, stacked; operator commits manually. The 0.8.6 regressions (033/034) +
  reload-hang (035/036) + protocol coverage (037/038) are all
  APPROVED+gated+(033/034/035/036 hardware-verified). task-037/038 verified via
  smoke 155/0 + real-private.json extraction; full-config sing-box check on the
  real sub is covered by the shipped smoke (fb-caseO), not my hand harness.

## task-039 + task-040: "Clear subscription cache" button in Diagnostics (2026-06-11)

- USER: a Diagnostics-tab button that wipes ALL subscription caches and
  re-downloads fresh ("частенько нужно"). OPERATOR DECISIONS: async
  (component_action_async + poll, like core-switch/self-update); FULL reset
  (delete all 4 per-feed files .json/.url/.rejected/.user_agent — the whole
  SUBSCRIPTION_CACHE_FOLDER contents).
- KEY REUSE: there is a GENERIC async component-action mechanism already —
  `component_action()` router in updater.sh (case "$component:$action"),
  `component_action_async <c> <a>` (forks worker, echoes job_id),
  `component_action_status <job_id>` (JSON result). Adding a new long-running
  async backend op = ONE case arm + ONE worker (echo {json}; return N, NEVER exit
  — the fork at updater.sh:429-433 captures one JSON line then writes finished
  state from $?). NO new async framework, NO ACL change (/usr/bin/netshift exec
  already granted, not per-arg). Frontend reuses the existing
  pollSingBoxComponentAction helper — no new poll loop.
- task-039 (backend, APPROVED W/ COND→met, smoke 166/0): worker
  subscription_clear_cache_and_redownload (bin/netshift, where subscription_update
  + path builders + SUBSCRIPTION_CACHE_FOLDER are in scope) guard-deletes the cache
  dir CONTENTS then runs subscription_update verbatim (redownload+restart-on-change).
  RM-SAFETY (make-or-break): dual guard `[ -n "$SUBSCRIPTION_CACHE_FOLDER" ] && [ -d
  ... ]` before `for f in "$DIR"/*; do [ -e ]||continue; rm -f "$f"`, never rm -rf
  the dir, never a path where empty/unset constant → rm /*. Router arm
  `subscription:clear_cache)` in updater.sh. Action string EXACTLY
  subscription/clear_cache.
- task-040 (frontend, APPROVED): "Clear subscription cache" button in the
  Diagnostics Available-actions card; NetShiftShellMethods.clearSubscriptionCache
  starts component_action_async subscription clear_cache + REUSES
  pollSingBoxComponentAction; handleClearSubscriptionCache mirrors handleRestart
  (loading→info toast→success/error toast→finally: fetchServicesInfo +
  loading:false + store.reset(['diagnosticsChecks'])); rotate-ccw icon; store slice
  in services/store.service.ts + diagnostic.store.ts; 4 new i18n msgids (en+ru),
  fe↔luci byte-identical. main.js rebuilt idempotent, export block unchanged
  (clearSubscriptionCache is a property, no barrel leak).
- INTEGRATION VERIFIED: backend router arm ↔ frontend
  ["component_action_async","subscription","clear_cache"] in built main.js match;
  smoke all 166/0 (11 new cc-case all green); 472 vitest; no yarn pollution. All
  UNCOMMITTED, stacked with tasks 027..038 — operator commits manually.

## DIAGNOSED: self-update silently no-ops on opkg/ipk routers with a v-prefixed installed build (2026-06-11)

- USER (main router ssh root@192.168.1.1, OWRT 24.10.5 mediatek/filogic aarch64,
  OPKG/ipk, Xiaomi AX3000T): NetShift self-update from the web UI reports
  "updated to 0.8.7" but the installed version stays v0.8.6. Logs show the whole
  self_update worker succeeding ("installing netshift-0.8.7-r1-all.ipk" ...
  "NetShift updated to 0.8.7").
- ROOT CAUSE (empirically proven on the router): the installed build is the OLD
  ipk that carried a leading `v` (constants `NETSHIFT_VERSION="v0.8.6"`, opkg
  pkg version `v0.8.6-r1`). The new release is `0.8.7-r1` (no v, post task-028).
  `opkg install <file.ipk>` REFUSES to "downgrade": it prints
  `Not downgrading package ... from v0.8.6-r1 to 0.8.7-r1.` and RETURNS rc=0
  (NOT an error for opkg). So updates_pkg_install_file (updater.sh:1410,
  `opkg install "$f" >/dev/null 2>&1`) sees rc=0 -> the worker logs success and
  emits {"success":true,...} while NOTHING was installed.
- WHY opkg thinks it's a downgrade: `opkg compare-versions "v0.8.6-r1" ">>"
  "0.8.7-r1"` => rc=0 (TRUE). The leading `v` sorts ABOVE the digit, so
  v0.8.6 > 0.8.7 in opkg's dpkg-style compare. Without the v,
  `0.8.6-r1 << 0.8.7-r1` => true (correct). This is the packaging.md §3 / task-028
  fragility realized: routers still running a pre-028 v-build can never self-update
  to a no-v release.
- TWO distinct bugs to fix in updater.sh:
  1. PRIMARY (silent success): `updates_pkg_install_file` swallows opkg's
     "Not downgrading" no-op as rc=0. The install path never VERIFIES the
     post-install version actually changed. FIX directions:
     (a) opkg path add `--force-downgrade` (and/or `--force-reinstall`) so a
         v->no-v transition actually installs; AND/OR
     (b) post-install VERIFY: after install, re-read the installed pkg version
         and compare to the target; if unchanged, treat as failure (honest JSON
         {"success":false}) instead of reporting success. Verify-after-install is
         the robust belt — opkg "already installed"/"not downgrading"/"up to date"
         all return rc=0, so rc alone is NOT a reliable success signal on opkg.
  2. CONTRIBUTING: the v-prefix legacy build. The compare in
     _updates_self_update_netshift_core ALREADY v-strips both sides
     (`${installed#v}` = `${latest#v}`, :1679) so it correctly decides "need
     update"; the failure is purely at the opkg install step.
- MANUAL FIX applied on the router (recovery, verified): downloaded all 3 ipks
  from the latest release and `opkg install --force-downgrade <file>` each ->
  netshift + luci-app-netshift now 0.8.7-r1, constants NETSHIFT_VERSION="0.8.7"
  (no v), get_system_info netshift_version 0.8.7. Future 0.8.7->0.8.8 upgrades
  will work normally (both sides no-v). Note: install drops
  /etc/config/netshift-opkg conffile-diff artifact (harmless; rm'd).
- apk SIDE NOTE (not the user's box but same helper): apk uses `-r` for release,
  treats a dashed UPSTREAM version specially (task-034 landmine #A: equal-version
  no-overwrite). The same verify-after-install belt would harden apk too. Whatever
  fix is chosen must be tested on BOTH opkg and apk paths (packaging gate).
- LANDMINE for the fix: `updates_pkg_install_file` redirects stdout+stderr to
  /dev/null, so the "Not downgrading" message is invisible — never rely on opkg
  text; rely on rc PLUS an explicit post-install version re-check. opkg
  compare-versions is available on-device for a robust numeric compare if needed
  (but the installer should not need the leading v at all once verify is added).

## task-043 Xray subscription UA — versioned UAs (2026-06-11)

- USER reported: with subscription_format_preference=xray, the panel returns 502
  and NetShift falls back to singbox/<ver> (sing-box JSON WITHOUT xhttp/hysteria2
  — the original task-031 complaint). PRIVACY: operator required NO
  subscription-identifying data anywhere (no panel host/IP/URL/path/query/server/
  keys) in code/tests/comments/memory — only generic client UA strings are safe.
  Diagnosis lived in the ephemeral SSH session only; never committed.
- ROOT CAUSE (reproduced on a live panel, abstractly): the Xray-probe constant
  SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES was bare/version-less ("v2rayN Happ").
  That panel UA-gates its Xray branch on a <client>/<version> shape: a BARE Happ
  (and v2rayN in any form) → 502 Bad Gateway; a VERSIONED Happ/<x.y.z> → 200 with
  the wanted Xray-JSON ARRAY (multi-profile). The download path/headers
  (_wget_subscription_request, helpers.sh:803) are correct & unchanged — only the
  UA VALUE decides 502-vs-200.
- DIAGNOSIS METHOD (reusable, privacy-safe): on the router, replay the exact
  request per UA with `curl -A "$UA" -H <same X-* headers netshift sends> -w
  "HTTP %{http_code}"` to isolate UA-vs-headers; the headers were identical for
  all UAs, so the UA alone is the variable. Sniff the 200 body's FORMAT (first
  char `[`/`{`, jq top-keys) to confirm it's the Xray-JSON array
  (dns,inbounds,log,outbounds,remarks,routing per element) — NOT to read values.
  Clean up /tmp on the router after.
- FIX (task-043, APPROVED W/ CONDITIONS, smoke 170/0): constants-only —
  SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES -> versioned ("Happ/1.0.0 v2rayN/7.0.0
  v2rayNG/1.9.0", versioned Happ FIRST). The xray-mode probe order in
  build_subscription_user_agent_candidates (helpers.sh:765-771) front-loads these
  before default+cached+whitelist, dedup whole-entry, so the working versioned
  Happ wins first; non-working UAs just fall through. Coupled smoke
  fb-caseI-xraypref-* updated to DERIVE expected first/second/third from the
  constant (won't rot) + a generic guard that the first candidate contains "/"
  (bare-UA regression catch). Operator REJECTED making it a UI option (overkill /
  system-level) and rejected touching headers / auto-mode list.
- DEDUP NOTE: versioned "Happ/1.0.0" is DISTINCT from the bare "Happ" still in the
  main auto-mode SUBSCRIPTION_USER_AGENT_CANDIDATES whitelist, so neither is
  dropped by the whole-entry dedup. The bare v2rayN/Happ in the MAIN list still
  502 on this panel but are only reached AFTER the versioned UAs already win, so
  no wasted probes in practice. Did NOT change the main list (broader/auto-mode).
- The CONDITION (M1) is commit-hygiene only: keep the pre-existing unrelated
  .opencode/agent/*.md churn (model rename + bash permission) OUT of the task-043
  commit — not a code issue. Those were already in the tree at session start.

## task-044/045 Universal subscription grouper (2026-06-12)

- FEATURE: generalize the country-flag subscription grouper into modes
  off/country/prefix. Operator wanted "group by first N chars of the remark, N
  configurable, default 2"; chose Variant A (single mode dropdown off/country/
  prefix + length, count by Unicode CODEPOINTS), full backend+frontend.
- ARCHITECTURE SEAM (reusable insight): the urltest-per-group + main-selector
  tree builder in bin/netshift `subscription)` branch is mode-agnostic — only the
  KEY EXTRACTOR + the on/off decision needed generalizing.
  `sing_box_build_subscription_country_groups` -> `sing_box_build_subscription_
  groups <tags_json> <mode> <prefix_len>` returning {group_order,groups,ungrouped}.
  prefix key = `(.|explode)|.[0:$n]|implode` (codepoint slice, Unicode-safe, no
  Oniguruma). country path kept byte-identical (regional-indicator gate). N=2
  over a flag tag == the flag, so country is a consistent special case.
- LANDMINE CAUGHT IN REVIEW LOOP (architect spotted, not the dev): the inherited
  group loop `for k in $(jq -r '.group_order[]')` WORD-SPLITS on IFS. Safe for
  country flags (no spaces) but BREAKS prefix mode whose keys can contain spaces
  (e.g. tag "A 1" prefix-2 -> key "A "). Fix: mktemp + `while IFS= read -r k ...
  done < "$tmp"` in the CURRENT shell (NOT `cmd | while read` — that subshell
  would lose the `config=`/`selector_outbounds_json=` mutations; same landmine
  class as the smoke `cmd|while read` trap). Mirror the existing
  `subscription_urls_tmp` mktemp+read<file pattern already in that branch. mktemp
  failure must fatal+exit 1. ALWAYS audit reused loops when the key domain widens.
- prefix_len hardening: jq side `try tonumber catch default | <1 -> default |
  floor`; shell side `case '' | *[!0-9]* -> default ;; *) [ x -ge 1 ] 2>/dev/null`.
  short tag (<N) keys by whole self (NOT ungrouped); empty tag -> ungrouped.
- LEGACY MIGRATION done BACKEND-side (no JS migration): subscription_group_mode
  present OUTRANKS legacy; absent -> read subscription_group_by_countries (then
  alias group_by_countries) truthy->country else off. Frontend just writes the
  new options. New constant SUBSCRIPTION_GROUP_DEFAULT_PREFIX_LEN=2.
- FRONTEND: form.Flag -> form.ListValue subscription_group_mode (off/country/
  prefix) + form.Value subscription_group_prefix_len (datatype and(uinteger,
  min(1)), depends subscription_group_mode:"prefix"); both taboption() in the
  `subscription` tab (tabbed-CBI completeness). types.ts old key removed (no TS
  reader). 7 i18n msgids + RU, fe<->luci byte-identical. main.js NO diff
  (type-only change + hand-written view) — so the rendered tab needs a HUMAN
  visual check (carried as APPROVED-WITH-CONDITIONS [M1]).
- GATES: shellcheck error clean; smoke 170->174/0 (country regression kept +
  prefix len-2/consistency/bad-len/space-key); whole-chain sing-box check PASS
  for mode=prefix; yarn ci green (472 vitest), main.js no-diff. Both APPROVED
  (045 with the human-eyeball condition). PRIVACY: synthetic tags only, full
  diff privacy-scan clean. Subagents truncated their final messages TWICE this
  session (frontend stopped before section.js; reviewer stopped mid-analysis) —
  ALWAYS verify on-disk state + run/inspect gates yourself rather than trusting
  a truncated "done".

## task-046 gzip subscription bodies — issue #13 (2026-06-12)

- ISSUE #13: a subscription panel sometimes returns a gzip-compressed body;
  NetShift parsed the binary as text -> all nodes skipped -> "No subscription
  User-Agent candidate produced valid outbounds". Reporter's workaround
  gzip-decompressed only inside normalize_subscription_to_singbox — INSUFFICIENT
  because validate_subscription_file runs BEFORE normalize and also chokes on a
  gzipped sing-box JSON. Correct seam = DOWNLOAD path (decompress once, both
  consumers see text).
- DEVICE FACTS (verified, OWRT 24.10 + 25.12): gzip/gunzip/zcat present
  (busybox); zstd/unzstd ABSENT (would need a new DEPENDS pkg). wget sends NO
  Accept-Encoding and does NOT transparently decompress, so gzip = server
  unconditionally compressing. gzip magic 1f 8b; `gzip -dc` on non-gzip rc=1.
  NO od/hexdump/xxd on device.
- OPERATOR DECISIONS: gzip ONLY (not zstd/deflate — separate future task if
  panels actually send them); detect at download time; + NUL-byte guard (reject
  still-binary body to next UA). Full backend+smoke.
- FIX (task-046, APPROVED W/ CONDITIONS, smoke 174/0): two helpers.sh helpers
  (modeled on convert_crlf_to_lf, mktemp+mv, all local, best-effort return 0):
  * maybe_gunzip_subscription_file <f>: ATTEMPT-DECOMPRESS detector (NO od) —
    `gzip -dc f > tmp` accept ONLY if rc=0 AND non-empty AND NUL-free, else leave
    original byte-identical (plain text makes gzip -dc rc!=0 -> untouched, can
    never corrupt text). This doubles as the gzip detector, avoids byte-fiddling.
  * subscription_body_is_binary <f>: NUL detector via `wc -c < f` vs
    `tr -d '\000' < f | wc -c` (counts differ -> NUL). Portable, no special grep
    flag, no od.
  Wired into download_subscription_into_cache per-UA while-read loop AFTER
  download_subscription, BEFORE validate (netshift:585-594): gunzip then if
  binary -> warn + continue to next UA (same control flow as a validation fail).
  file_size/debug log MOVED to after decompress so size reflects decompressed
  body. NO wget/Accept-Encoding change, NO Makefile DEPENDS change.
- REUSABLE PATTERNS: file-transform helper = mktemp+transform+mv-on-success/
  rm-on-fail (convert_crlf_to_lf is the template). NUL/binary detect without od =
  wc-vs-tr-d-NUL byte-count. attempt-decompress is a clean od-free magic detector.
- CONDITION (M1) is commit-hygiene only: keep the pre-existing unrelated
  .opencode/agent/*.md churn (model rename + `bash "*": ask`->`allow`) OUT of the
  commit; the permission loosening is a separate human decision.

## task-047 false-"Outdated" — minified-JSON tag parse (2026-06-12)

- ISSUE (user, AX3000T, OWRT 25.12.2 apk, NetShift 0.8.8): "check for updates"
  always says Outdated; "update" -> error; reinstall via Putty doesn't help. OCR
  of the UI showed the "latest version" as a URL
  `https://api.github.com/repos/yandexru45/netshift/releases/<id>` instead of a
  version number.
- ROOT CAUSE (PROVEN by reproduction): updates_netshift_latest_tag
  (updater.sh) parsed the tag with `grep '"tag_name":' | head -n1 |
  cut -d'"' -f4`. That ONLY works on PRETTY-PRINTED JSON. GitHub API/CDN/proxies
  often return MINIFIED JSON (whole object on one line) -> grep matches the
  entire line, `cut -d'"' -f4` returns the FIRST key's value = the release
  "url". So latest="<url>", `0.8.8 != <url>` -> false "outdated"; and the
  self-update worker (same fn for $latest) logged "downloading NetShift <url>
  release packages" then failed. Reinstall is useless: bug is in PARSING.
  Repro: `printf '{"url":".../releases/338202209","id":...,"tag_name":"0.8.8",...}'
  | grep '"tag_name":'|head -1|cut -d'"' -f4` => the url.
- WHY ONLY THIS FN: sing-box-extended path already uses jq (.tag_name); asset
  download uses `grep -o "https://...\.(ipk|apk)"` (newline-agnostic, robust);
  install.sh only rate-limit-greps + asset grep -o. All unaffected. jq is a hard
  dep used 23x in updater.sh.
- FIX (task-047, APPROVED W/ CONDITIONS): replace the body with
  `tag="$(printf '%s' "$response" | jq -r '.tag_name // empty' 2>/dev/null)";
  [ -n "$tag" ] || return 1; printf '%s' "$tag"`. Format-independent; `.tag_name
  // empty` -> empty on rate-limit/error object (callers already handle
  "could not determine latest"). Fixes BOTH check_update and self-update (shared
  fn). Callers untouched. No Oniguruma.
- TEST (smoke `latesttag`, registered main all)+case+usage): stub the network
  boundary `updates_http_get_once` (NOT the fn under test), run the REAL
  updates_netshift_latest_tag. Cases: MINIFIED (exact bug shape, url before
  tag_name) -> 0.8.8 not url (regression guard); pretty -> 0.8.8; rate-limit ->
  empty+nonzero; e2e minified through updates_check_netshift -> status latest.
  set -e rc capture via `&& printf 0 || printf %s "$?"`. Guard self-proven.
- LESSON (reusable): NEVER field-position-parse JSON (`grep KEY|head|cut -d'"'
  -fN`) — it silently breaks on minified responses by grabbing the first key's
  value. Use jq (already a dep) for any tag/scalar extraction; reserve `grep -o
  <url-regex>` for URL-list extraction (that IS newline-agnostic and fine).
- WHOLE-CHAIN verified on the user's class of box earlier: get_system_info keeps
  latest="unknown" (no net); check_update is the on-demand fetch; the diagnostic
  row + manager card flag outdated when installed != latest, so a bad latest
  poisons BOTH UI spots — fixing the parse fixes all consumers.
- CONDITION [S1] is commit-hygiene: keep the pre-existing unrelated
  .opencode/agent/*.md churn (model rename + `bash "*": ask`->`allow`) OUT of the
  commit; the bash-permission widening is security-relevant and needs a separate
  explicit human decision. (Recurring across tasks 043/046/047 — these 5 files
  were already dirty at session start.)

## task-048 scalar option subscription_url — sing-box won't start (2026-06-12)

- ISSUE (Nick, Cudy WR3000E, OWRT 25.12.4, 0.8.9): urltest section works; switch
  to subscription -> whole chain dead (sing-box not running, no nft table,
  FakeIP 127.0.0.42:53 refused). Startup log: "Outbound section not found.
  Aborted." despite config having a subscription_url.
- DIAGNOSIS METHOD: user sent 2x3 diagnostic txt (global_check/show_sing_box_config/
  view_logs) for working vs broken. The view_logs filenames were SWAPPED (the
  tiny 435B file was the broken run, the big one was the working urltest run) —
  read by CONTENT not filename. Broken view_logs: single "Outbound section not
  found. Aborted." line. global_check(broken): proxy_config_type 'subscription'
  with `option subscription_url '...'` (scalar, NOT list).
- ROOT CAUSE (PROVEN on hardware): get_subscription_urls_for_section reads
  subscription_url ONLY via config_list_foreach, which iterates ONLY UCI `list`
  values and returns EMPTY for a scalar `option`. Proven: config_list_foreach
  over option => []; config_get => the value; over list => works. The UI writes
  `list` (form.DynamicList) so new configs are fine; legacy/CLI/podkop-migrated
  configs use `option` and broke. Every subscription consumer funnels through
  this ONE helper -> fixing it fixes the whole chain.
- FIX (task-048, APPROVED round 2): (1) load-bearing read-fallback in
  get_subscription_urls_for_section: if the list read is empty, config_get the
  scalar and feed it through _collect_subscription_url_handler. (2) one-time
  idempotent option->list migration at top of start_main (after config_load,
  before check_requirements), only on the broken shape, never exits.
- REVIEW LOOP (2 rounds, important): round 1 REQUIRES CHANGES — BLOCKER [B1]
  data loss: the migration used `uci add_list "key=value"` which SPLITS ON THE
  FIRST `=` and loses query-string URLs (?token=abc&x=1) — reproduced on hardware
  (rc=1, list empty, scalar already deleted => URL gone on disk). Fix: use the
  `uci_add_list <cfg> <sec> <opt> "<val>"` SHELL HELPER (separate-arg, preserves
  =/&), delete-then-add with scalar RESTORE on add failure, flag gates the
  commit. Plus [S1] the new test ran assertions on the RHS of a pipe (subshell
  counter loss) so it didn't gate CI -> fixed to `while read < tmpfile`. Round 2
  APPROVED.
- LESSONS (reusable): (a) NEVER trust user-supplied filenames for which-is-which —
  read by content. (b) `config_list_foreach` does NOT read scalar options; any
  list-option reader needs a scalar config_get fallback for back-compat with
  legacy/CLI/migrated configs. (c) `uci add_list "k=v"` CLI form is unsafe for
  values containing `=` — use the uci_add_list shell helper. (d) a smoke test
  that pipes into `while read; pass/fail` does NOT gate CI (subshell) — the count
  jump (178->190) when fixed is the tell. (e) RE-check the dev's memory note on a
  fix round — it's often pre-fix and re-seeds the anti-pattern.
- PRIVACY: Nick's dump contained a real subscription URL; moved all 6 txt to
  /tmp/opencode/nick-diag (out of git); code/tests/specs/memory use ONLY synthetic
  https://example.com/sub. Final whole-tree sweep for the real host => clean.
- GATES: shellcheck -S error clean; smoke `all` 178->190/0 (the +12 are the now-
  gating suburlopt tokens incl. 4 =-URL guards); whole-chain verified (option
  config -> has_outbound_section TRUE -> gen -> sing-box check). Runtime contract
  intact (UCI schema = back-compat repr normalization only).

## GitHub API rate-limit — research + task-049 (2026-06-12)

- HOW IT WORKS (official docs, verified): anonymous api.github.com = 60 req/HOUR
  per IP (authed=5000). On 403/429 the body is {"message":"API rate limit
  exceeded for <IP>..."} and headers x-ratelimit-remaining:0 + x-ratelimit-reset
  (UTC epoch). GET /rate_limit shows budget and does NOT cost primary quota.
- WHY users hit it a lot: limit is PER IP. Routers behind CGNAT / shared ISP
  IPs / shared-VPN egress share ONE IP's 60/hour with many strangers -> the
  budget is often already drained by others. Not the user's fault; we're
  anonymous so we can't raise it without a token.
- KEY LEVER (PROVEN on hardware, curl): github.com/<repo>/releases/latest is
  served by the github.com FRONTEND, NOT the rate-limited API. It 302-redirects
  to /releases/tag/<tag>. `curl -sI -o /dev/null -w '%{redirect_url}'` returns
  `.../releases/tag/0.8.9` -> tag extracted WITHOUT touching api.github.com.
  And github.com/<repo>/releases/download/<tag>/<asset> 302s to the CDN
  (release-assets.githubusercontent.com) -> direct asset download, no API.
  (We already use this redirect path for SRS_MAIN_URL = releases/latest/download.)
- BUSYBOX wget on-device is STRIPPED: no -S, no --max-redirect, can't read
  Location/headers. So tag extraction MUST use curl (a hard DEPENDS: +curl),
  via %{redirect_url} (or -w %{url_effective} with -L). updates_http_get_once
  already prefers curl.
- ASSET NAMING is deterministic from the tag: ipk = netshift-<ver>-r1-all.ipk,
  luci-app-netshift-<ver>-r1-all.ipk, luci-i18n-netshift-ru-<ver>.ipk; apk =
  netshift-<ver>-r1.apk, luci-app-netshift-<ver>-r1.apk,
  luci-i18n-netshift-ru-<ver>.apk. (<ver> = tag.) All 302 on the direct path.
- SCOPE DECISION (task-049): migrate the 3 NETSHIFT-repo touchpoints off
  api.github.com -> redirect path: version check (updater.sh:1638
  updates_netshift_latest_tag), self-update asset download
  (updater.sh:1657 _updates_self_update_download_assets), and install.sh:259.
  KEEP the sing-box-EXTENDED path (updater.sh:553 releases?per_page=30) on the
  API + proxy-fallback: it genuinely needs the releases LIST (draft/prerelease
  flags + per-arch asset selection) which a redirect can't give; it's also a
  rarer, on-demand action. Proxy-fallback stays as the safety net there.
- ALSO: honor x-ratelimit-reset / show honest "GitHub limit, retry after HH:MM"
  instead of generic error; optionally TTL-cache the latest tag. (Secondary.)
- itdoginfo's podkop historically had the SAME complaint class; this redirect
  approach is the standard fix.

## task-049 CLOSED — APPROVED (2026-06-12)
- Implemented: redirect-first tag fetch (updates_github_resolve_redirect +
  updates_netshift_latest_tag), deterministic asset-URL download
  (updates_netshift_asset_filename + _updates_self_update_download_assets), and
  install.sh redirect path (+ shared download_release_asset helper). API path
  kept as graceful fallback everywhere; sing-box-extended path untouched.
- Gates: shellcheck -S error clean; smoke 190->196/0 (+6 ghredirect, gating);
  self-proved. Tag is rejected if empty/`/`-containing (injection/traversal
  guard) and only used quoted in URL strings (no eval) — reviewed safe.
- Review: 1 round, APPROVED. Only finding [M1] = a comment typo
  (updates_http_get_once -> updates_download_to_file); fixed during review,
  shellcheck re-clean, ghredirect re-run 6/0.
- Net result for the user complaint: the normal version-check/self-update/install
  path no longer touches the 60/hr-per-IP api.github.com, so CGNAT/shared-IP
  rate-limit errors should largely disappear; API remains the fallback.

## task-050 "Fastest" urltest-of-urltests — CLOSED, APPROVED (2026-06-13)
- RESEARCH (confirmed): sing-box urltest.outbounds = "list of outbound tags to
  test" with NO type restriction -> a urltest CAN nest other urltest tags. At
  runtime it probes each member THROUGH that member's dial path, so a nested
  group-urltest member is measured via that group's currently-selected (fastest)
  node => "fastest country/group" emerges correctly. Maintainer confirms nested
  urltest runs (SagerNet/sing-box #2130; the failover caveat there is unrelated).
  `sing-box check` accepts a urltest referencing urltest tags (PROVEN by the
  smoke's real in-container check).
- FEATURE: when subscription grouping is ON (country/prefix) AND there are >=2
  groups, build a top-level urltest "⚡ Fastest" (SB_SUBSCRIPTION_FASTEST_GROUP_TAG)
  over the per-group urltests, PREPEND it to the main selector, make it the
  selector DEFAULT. Specific groups + ungrouped stay selectable. ==1 group ->
  skip the redundant nested layer (default = lone group). ==0 -> no fastest
  urltest. OFF mode unchanged. Operator: this becomes the default-on-grouping.
- KEY IMPL DETAIL: capture group_tags_json from selector_outbounds_json BEFORE
  ungrouped is appended, so the nested urltest nests ONLY group urltests (not raw
  ungrouped nodes). Reuse the section's urltest knobs (interval/tolerance) — no
  hardcoded aggressive cadence; documented that it adds one probe layer.
- NO FRONTEND CHANGE: the dashboard (getDashboardSections.ts) renders selector
  members live from the Clash structure and shows each member's name verbatim
  (only legacy `<section>-urltest-out` maps to _('Fastest')). The new deduped
  "⚡ Fastest" tag (code==tag, not -urltest-out) renders raw like per-group
  "🇷🇺 Fastest", urltests sort first so it leads + is selectable. main.js untouched.
- GATES: shellcheck -S error clean; smoke 196->202/0 (+6 fastest tokens, gating;
  test calls pass/fail directly in the fn body, not a pipe-subshell). Real
  `sing-box -c check` on the nested config passes (skips cleanly when sing-box
  absent). Self-proved. Review 1 round APPROVED, no conditions.
- This is a natural extension of task-044/045 (universal grouper). Performance
  caveat on record: nested probing = extra load; tunable via the section's
  urltest_check_interval/tolerance.
