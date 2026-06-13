# Memory — shell-backend-developer

Durable backend (ash + jq) knowledge. Read before implementing; append
findings; keep under ~200 lines.

## Hard constraints (proven)

- **OpenWRT jq has NO Oniguruma** — `test()`, `match()`, `sub()`, `gsub()` and
  any regex are unavailable. The updater (`updater.sh`) documents workarounds.
  Build string logic with `split`/`startswith`/`endswith`/`contains`/`ascii`
  instead.
- **`fatal` is only a log label** — `log "..." "fatal"` does NOT exit. You must
  follow it with `exit 1` yourself. Missing the `exit 1` continues with a
  half-built config.
- **busybox sed lacks `\x` escapes** — use printf-octal workarounds (see
  `helpers.sh` `convert_crlf_to_lf` and BOM stripping). Don't assume GNU sed.
- **Diagnostic strings are UTF-8, NOT mojibake** (corrected by task-004). The
  emoji/box-drawing in `usr/bin/netshift` (`global_check`, `list_update`,
  `subscription_update`, `check_nft`: `📡 🛠️ ✅ ❌ ⚠️ ➡️ 🧱 🥸 📄 ━`) are valid
  UTF-8 and must STAY valid UTF-8. They were once double-encoded (UTF-8 read as
  CP1251, re-saved as UTF-8 → printed `рџ…`/`в”…`/`вЂ…`). Never open/save that file
  in a non-UTF-8 editor or pass it through CP1251 — it re-corrupts. The earlier
  "preserve the corrupted bytes" note here was the WRONG guidance that protected
  the bug.

## Conventions (follow exactly)

- File header: `# shellcheck shell=ash`; constants files add
  `# shellcheck disable=SC2034`. Declare every variable `local`.
- Function prefixes: `sing_box_cm_*` = one jq mutation each (dumb primitive);
  `sing_box_cf_*` = facade (parse + several cm_* calls); `url_*` = pure URL
  parsing; `is_*` = predicate returning 0/1; `nft_*` = nft wrapper; `updates_*`
  = updater; `get_*_tag` = deterministic tag builder; `configure_*`/`import_*`/
  `_*_handler` = config_foreach callbacks; leading `_` = private helper.
- Config threading: `$config` is a shell STRING; cm/cf take it as `$1`, echo
  mutated JSON; caller does `config=$(sing_box_cm_... "$config" ...)`.
- jq optional keys: `+ (if $x != "" then {k:$x} else {} end)`. Custom helpers
  in `helpers.jq`, imported `import "helpers" as h {"search":"/usr/lib/netshift"}`.
- Validation is mandatory: write to `*.tmp.$$`, run `sing-box -c <file> check`
  (fatal on fail), `jq -e` for shape, md5sum-compare, then `mv`. Atomic only.
- New constants -> `constants.sh` (grouped Common/nft/sing-box/Lists). Never
  hardcode ports/IPs/marks/paths.
- The service-tag pattern: cm_* functions stamp a transient `__service_tag`
  (`SERVICE_TAG`) on rules; `sing_box_cm_save_config_to_file` strips every
  `__service_tag` via `walk(...)` before writing. Don't leave tags in output.

## Subscription / unavailable-outbound flow (don't leak traffic)

- Many code paths branch on `subscription_outbound_is_unavailable` to emit
  **reject** route rules instead of routes when a subscription is down. Any new
  routing code MUST respect this or it leaks traffic when a sub is unavailable.

## Testing

- Smoke suite is `tests/entrypoint.sh` (run via `smoke-tests` skill). Categories:
  deps syntax config helpers jq cm sb nft diagnostics subscription.
- To add a test: write `test_xyz()` using the `header`/`pass`/`fail`/`skip`
  helpers; add it to `main()`'s `all)` list; add a `case` alias; update the
  usage line and the docker-compose comment. Config-gen and subscription
  parsing changes SHOULD get a smoke test.
- Pre-commit-equivalent: always run the `shellcheck` skill (severity error) on
  touched shell files before handing back.

## jq gotchas (proven by task-002)

- **`include` / `exclude` are RESERVED jq keywords** — you cannot name a jq
  variable `$include` (jq tries to parse the `include` directive). Use `$inc`/
  `$exc` etc. for keyword-filter lists.
- **`any(gen; cond)` / `all(gen; cond)` binding trap**: inside the condition,
  `.` is the generator element ONLY at the top of `cond`. If you write
  `($name | index(.))` the `.` becomes `$name` (the pipe rebinds `.`), so the
  match silently always succeeds. Bind first: `any($kw[]; . as $k | ($name |
  index($k)) != null)`.
- Subscription keyword filter lives in `sing_box_cf_prepare_subscription_batch`
  (facade), runs BEFORE static-unsupported filter + tag dedup, threaded from the
  `subscription)` branch via two UCI **list** options
  `subscription_filter_include_keywords` / `subscription_filter_exclude_keywords`
  (the cross-layer contract names for task-003 — do NOT rename). Keywords are
  opaque user text: collect with a `config_list_foreach` handler that jq
  `--arg`-appends each item into a JSON array (commas/emoji survive; never use
  `comma_string_to_json_array` for them). Empty result reuses the existing
  `mark_subscription_outbound_unavailable` fail-safe (no `exit 1`).

## Known landmines

- nft proxy chain hardcodes `127.0.0.1:1602` (duplicates the constants).
- VPN `domain_resolver` uses wrong variable `$dns_server`.
- `check_nft` references stale set names (`netshift_domains`) / UCI options that
  don't exist elsewhere — likely copied diagnostic cruft.

## task-004: double-encode repair recipe (reusable)

- To reverse a UTF-8→CP1251 double-encode losslessly: `text =
  bytes.decode("utf-8"); fixed = text.encode("cp1251").decode("utf-8")` then
  write `fixed.encode("utf-8")`. ASCII bytes pass through; verify 0
  cp1251-unmappable chars and that ASCII-stripped lines are byte-identical
  before/after (proves no code moved). Result was exactly 114 lines, all
  non-ASCII-only. LF/no-BOM preserved.
- On Windows here, `python3.exe` is the MS Store stub — use `python` (Python
  3.11 at `...\Programs\Python\Python311`). Don't `print()` emoji to the
  PowerShell console (cp1251 codepage mangles it / raises); write results to a
  UTF-8 file and read it back.
## task-005 review-001: vmess base64 + url_decode landmine (proven)

- `sing_box_cf_add_proxy_outbound` runs `url=$(url_decode "$url")` BEFORE the
  scheme `case`, and `url_decode` does `s/+/ /g`. Any scheme that base64-decodes
  the WHOLE payload (vmess `vmess://base64(JSON)`; future tuic/etc.) MUST decode
  from the RAW link, not the url_decode'd one — standard base64's alphabet
  includes `+`, so `+`→space corrupts ~1-in-64 real keys. Fix pattern: capture
  `local raw_url="$3"` at the top (before url_decode) and pass `$raw_url` to the
  whole-payload decoder. Other scheme cases keep using the url_decode'd `$url`.
- **busybox `tr` does NOT support POSIX char classes** — `tr -d '[:space:]'`
  deletes the LITERAL chars `[ : s p a c e ]` (silently corrupts base64!). Use
  explicit bytes: `tr -d ' \011\012\015'` (space/tab/LF/CR octal). Verified
  in-container: input `aZ:[]cept123` → `Zt123` with `[:space:]`. This was a real
  regression I introduced and caught via the `sb` smoke run.
- base64 padding normalization for unpadded links: right-pad payload length to a
  multiple of 4 with `=` using `pad=$(( ${#p} % 4 ))` then a `while` append loop.
  POSIX-safe, busybox-safe.
- To craft a base64 body that DELIBERATELY contains `+`: a `ps`/label value of
  `node>>` (bytes 0x3E 0x3E) forces a 6-bit group = 62 → `+`. Realistic ASCII
  host/word values rarely hit it; `>>` is reliable.
- Probing helpers in-container without fighting PowerShell quoting: write a tiny
  `.sh` into `netshift/files/usr/lib/` (it's bind-mounted into the smoke
  container at `/netshift/files`), run via
  `docker compose ... run --rm --entrypoint sh netshift-test /netshift/files/usr/lib/_tmp.sh`,
  then delete it. Inline `-c "..."` one-liners get mangled by PowerShell.

- `test_syntax` in `tests/entrypoint.sh` now also `ash -n`'s `usr/bin/netshift`
  and asserts no residual `рџ`/`в”`/`вЂ` markers (built via `printf` octal, since
  busybox grep lacks `\x`). Guards against re-introducing the mojibake.

## task-007: async component-action job state (rpcd 30s wall fix)

- Root cause of "core switch fails": the UI called `component_action sing_box
  install_extended` SYNCHRONOUSLY via rpcd `fs.exec`; rpcd has `-t 30` and kills
  the worker mid-extract (after `tar -O > /usr/bin/sing-box`, before
  `chmod 0755`). The JS-side `timeout: 600000` does NOT help (server-side limit).
  Fix = fork the worker detached; return a job_id in <<30s; poll status.
- Job-state machinery lives in `updater.sh` (jq, no ucode). State dir `/var/run/netshift/
  component-actions` (tmpfs). Constants: `UPDATES_JOB_DIR`,
  `UPDATES_JOB_FINISHED_TTL_MINUTES=60`, `UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES=60`,
  `UPDATES_JOB_STALE_GRACE_SECONDS=15`.
- **State object contract (STABLE — frontend task-008 depends on these field
  names):** `{ success, running, component, action, message, pid, started_at,
  updated_at, exit_code, version, latest_version }`. running:
  `running:true,success:true,exit_code:null`. finished: `running:false`,
  success/version/message parsed from the worker stdout JSON, exit_code from `$?`.
- HUP-proof fork: `( trap '' HUP; "$0" component_action "$c" "$a" >"$out" 2>&1;
  updates_write_finished_job_state ... "$?" "$out" ) >/dev/null 2>&1 &`; record
  `$!` into the running state via `updates_update_running_job_pid`. `trap '' HUP`
  is what survives the rpcd session close. The async wrapper NEVER `exit 1`s on a
  worker failure — the failure is recorded in the finished state.
- finished-state stdout parser (`updates_extract_worker_json`): `updates_log`/
  `echolog` can pollute the worker's stdout, so: (1) if the WHOLE file is valid
  JSON (`jq -e .`) use it; else (2) `sed -n 's/^[^{]*\({.*\)$/\1/p' | tail -n 1`
  then `jq -e` validate. sed is busybox-safe; NO Oniguruma. success derives from
  `$w.success // ($exit_code == 0)`; version from `$w.version // $w.current_version`.
- Path-traversal guard: `updates_job_state_path` rejects ids matching
  `*[!A-Za-z0-9._-]*` or empty/`.`/`..` → return 1. The id comes straight from
  the (ACL-gated) UI, so this is the security boundary. `component_action_status`
  returns a safe self-contained `{success:false,running:false,...}` (via
  `updates_job_status_response`, non-zero rc) for invalid id / missing file.
- Stale detection (`updates_refresh_running_job_state`): running:true but pid not
  `kill -0` alive AND past `started_at + STALE_GRACE` → rewrite as finished/stale
  (`success:false`). Prevents the UI polling a crashed worker forever.
- Idempotent install (Req 4): at the START of `updates_install_sing_box_extended`,
  if `/usr/bin/sing-box` exists but is not `-x` OR fails a `version` probe, `rm`
  it up front (don't back up a broken partial artifact). `chmod 0755` stays
  IMMEDIATELY after stream-extract and BEFORE validation — keep that order.
- **`set -e` + command substitution landmine (smoke harness):** under `set -e`,
  `x="$(cmd-that-returns-nonzero)"` ABORTS the whole script. When a test
  deliberately invokes a failing command (e.g. invalid-id status returns rc 1),
  run it as `cmd > tmpfile 2>/dev/null || rc=$?` then read tmpfile — do NOT
  capture via `$(...)` in an assignment, and do NOT use `|| true` (that clobbers
  `$?` so you can't assert the non-zero rc). This cost me one debug cycle.
- **Brace-in-default-param landmine (busybox ash):** `${VAR:-{json...}}` emits an
  EXTRA literal `}` even when VAR is set (the inner `{...}` confuses the `}`
  matching), corrupting JSON. Use `[ -z "$VAR" ] && VAR='{...}'` then print `$VAR`.
- New top-level smoke test `test_jobstate` (alias `jobstate`): stubs the worker
  via a tiny generated CLI whose `$0` IS the stub (because `component_action_async`
  forks `"$0" component_action ...`); controls the worker with `STUB_JSON`/
  `STUB_SLEEP`/`STUB_RC` env; isolates state under `JOBSTUB_DIR`. Registered in
  `all)`, case alias, usage line, and the docker-compose comment.
- Dispatcher (`bin/netshift`): `component_action_async) component_action_async
  "$2" "$3" ;;` and `component_action_status) component_action_status "$2" ;;`
  replaced the old naive `"$0" component_action ... > /tmp/...json &` hack. ACL
  needs NO change (`/usr/bin/netshift` is exec-allowed wholesale).

## task-009: core-switch connectivity self-heal + rollback (anti-brick)

- Root cause of the on-hardware brick: `updates_install_sing_box_stable`
  removed/replaced /usr/bin/sing-box via opkg/apk with NO backup, while the
  kill-switch (nft tproxy + dnsmasq->127.0.0.42->dead sing-box) blocked feed
  access. Binary GONE, no rollback. Extended path already had a tmpfs backup.
- Fix shape (variant B): both install paths are now thin PUBLIC wrappers
  (`updates_install_sing_box_extended`/`_stable`) that run
  `updates_ensure_connectivity <dir>` (preflight; if fail -> selfheal) then call
  the renamed private core (`_updates_install_sing_box_*_core`), then ALWAYS
  `updates_restore_after_swap`. **Epilogue guarantee = single cleanup call**:
  core echoes JSON to a `/tmp/...result.$$` capture file + returns rc; wrapper
  runs restore once, re-emits the JSON, returns rc. No early return skips it (no
  trap needed — the wrapper has exactly one core call).
- `updates_preflight_connectivity <stable|extended>` is direction-aware: stable
  probes `UPDATES_FEED_PROBE_HOST` (downloads.openwrt.org), extended probes
  `UPDATES_GITHUB_PROBE_HOST` (api.github.com). Probe = DNS resolve (dig
  `+short`, nslookup fallback; bind-dig is a dep) AND a curl `-fsSI`/wget
  `--spider` HEAD with `--connect-timeout 5`. No jq/regex.
- `updates_selfheal_connectivity`: (1) backup `/etc/resolv.conf` to tmpfs
  (`UPDATES_RESOLV_BACKUP`), write temp resolver (`UPDATES_HEAL_RESOLVERS`
  1.1.1.1+9.9.9.9) atomically, recheck; (2) if still failing, tear down redirect
  via the EXISTING `/etc/init.d/netshift stop` (dnsmasq_restore + stop_main),
  recheck. Records `UPDATES_HEAL_RESOLV_REPLACED`/`UPDATES_HEAL_REDIRECT_DOWN`
  module-level flags so the epilogue restores EXACTLY what changed (restore
  resolv.conf via mv-back, bring redirect up via `/etc/init.d/netshift start`).
  Reused stop/start so dnsmasq UCI + shutdown_correctly bookkeeping stays right;
  NO hand-rolled nft flush, NO sacred-constant change.
- Stable core gained tmpfs backup/rollback (`updates_stable_rollback`) mirroring
  the extended path: backup binary+libcronet BEFORE package install; restore on
  install-fail OR still-extended validation. CRITICAL ordering: connectivity is
  confirmed (preflight/heal in the wrapper) BEFORE the core touches the binary —
  if heal fails the wrapper aborts and nothing is removed.
- **Testability indirection**: added `UPDATES_SING_BOX_BIN`/`UPDATES_LIBCRONET_LIB`
  constants (default the real /usr/bin/sing-box, /usr/lib/libcronet.so) and used
  them in the STABLE core+rollback only, so the smoke test can point them at
  /tmp mocks without clobbering the container's real binary. Extended path still
  uses the literals (spec said mirror, not refactor).
- New top-level smoke test `test_selfheal` (alias `selfheal`): a generated
  driver sources updater.sh, re-pins RESOLV_CONF/probe-hosts/bin paths, stubs
  dig/nslookup/curl/opkg via a PATH-prepended bin dir whose behaviour is keyed
  off marker files, and installs a fake `/etc/init.d/netshift` that logs
  stop/start/restart (absolute path can't be PATH-overridden — write+restore the
  real one). 5 scenarios: preflight-pass, dns-heal, teardown-heal, heal-fail
  (abort, binary intact), stable-install-fail (backup restored). Registered in
  `all)`, case alias, usage line, docker-compose comment.
- **`set -e` landmine (again)**: the worker returns non-zero on recoverable
  failures (success:false). Calling it directly inside a test under `set -e`
  aborts the WHOLE suite mid-run (only the passes before it print, summary never
  runs, rc=1 with no FAIL line). Wrap the invocation `... || true` — assertions
  read JSON/file-state, not rc. (Distinct from the task-007 `$(...)`-capture
  variant.)

## task-010: keyword filter case-fold is ASCII+Cyrillic (not just ASCII)

- **`ascii_downcase` only folds ASCII A-Z** — Cyrillic server tags (e.g.
  `Германия`) stayed mixed-case, so a Cyrillic include keyword in any other
  case matched 0 nodes → kept=0 → blocked outbound (hardware-confirmed: include
  `[ГеРма,пОЛЬш,рос]` over 316 outbounds gave 0 before, 28 after).
- Fix lives in `sing_box_cf_prepare_subscription_batch`
  (`sing_box_config_facade.sh`). That jq call does NOT `import` helpers.jq, so the
  fold is defined **inline** at the top of the program as `def ucfold:` using only
  `explode`/`map`/`implode` (NO Oniguruma): ASCII `65-90`→`+32`, Cyrillic
  `1040-1071` (А-Я)→`+32`, and the single out-of-block `Ё` `1025`→`1105` (ё).
  Everything else (emoji/other scripts) passes through unchanged → still matches
  as exact codepoint substrings. Replaced the 3 `ascii_downcase` uses (the two
  `$inc`/`$exc` list normalizers + the `$name | ucfold` in the select). The
  `index()`-based `name_passes_keywords` substring logic is unchanged.
- Cyrillic codepoints: А-Я = 1040-1071, а-я = 1072-1103 (so +32), Ё = 1025
  sits BEFORE the block, ё = 1105 sits AFTER it — hence the special-case branch.
- Smoke: extended the existing FBEOF block in `test_subscription` with CASE K
  (Cyrillic). No new top-level test / registration needed — it rides the existing
  `subscription` category. Synthetic names with literal UTF-8 (`Германия`,
  `Орёл`, etc.) in the heredoc are fine; assert via `.count`/`.names`. Used a
  `case "$x" in *Польша*)` membership check rather than exact-name compare for the
  exclude case (order-independent). All ran green in-container.

## task-011: keyword filter must not poison the subscription rejected-hash

- Root cause of the hardware re-download loop: `mark_subscription_outbound_unavailable`
  (`bin/netshift`) md5'd the VALID `<section>.json` and wrote it to `.rejected`
  even when `kept=0` was caused purely by the user's keyword filter (a setting,
  not a bad feed). Then `subscription_cache_is_usable` — which had already passed
  `validate_subscription_file` — still returned 1 on the hash match, forcing a
  re-download; `download_subscription_into_cache` saw tmp_hash==rejected_hash and
  `return 14` (unchanged+rejected) → infinite retry. The poison also survived
  loosening the filter (lived only in `.rejected`).
- Fix A: 2nd arg `keyword_filter_active="${2:-0}"`. When 1: NEVER compute/write
  the hash, `rm -f` the `.rejected` (self-heals a previously poisoned hash), still
  set unavailable state + `subscription_startup_blocked=1`, warn that the FILTER
  (not the feed) emptied the set. When 0: unchanged (genuine outbound-less body
  still recorded → flash-loop guard kept). Caller at the `subscription)` branch
  passes `$subscription_keyword_filter_active` (set 0/1 just above from the two
  UCI keyword lists).
- Fix B: in `subscription_cache_is_usable`, after `validate_subscription_file`,
  run a jq -e "has >=1 proxy outbound" check (same predicate as the batch:
  `[.outbounds[]? | select(.type != "selector" and ... != "block")] | length > 0`,
  NO Oniguruma) → if true `return 0` (usable) regardless of `.rejected`. The
  rejected-hash veto now only fires on a validated-but-outbound-less body. NB:
  `validate_subscription_file` ALREADY requires length>0, so a 0-proxy body fails
  validation first — B is belt-and-suspenders + self-documenting, and robust if
  validation ever loosens. Did NOT touch `download_subscription_into_cache`'s own
  rejected logic (spec: once A/B stop writing+vetoing, a valid body has no
  `.rejected` so return 14 can't fire for it).
- **Testing functions that live in `bin/netshift` (not a lib):** can't source the
  file (it runs the dispatcher + needs LuCI `/lib/functions.sh`). Pattern that
  works: a generated driver that (1) stubs the few helpers the target calls
  (`log`, the `get_subscription_*_path` builders), (2) sources `helpers.sh` for
  the real `validate_subscription_file`, (3) extracts JUST the target functions
  verbatim with awk and `eval`s them:
  `eval "$(awk '/^fname\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"`. Relies on
  top-level functions closing with a column-0 `}` and having no nested column-0
  `}` (case/if/while bodies don't). Keeps the test against shipped code, not a copy.
- New top-level smoke test `test_rejected_hash` (alias `rejected`): 6 cases
  (A-no-write+clear, A-recovery, B-not-vetoed, A-protected-no-proxy-still-vetoed,
  regression-usable, A-arg0-genuine-recorded). Registered in `all)`, case alias,
  usage "Available:" line, docker-compose comment. Same name:OK/FAIL parse + the
  subshell-pipe PASS-counter quirk as test_subscription (suite `Results:` total
  omits piped-while passes; the per-test ✓ marks are the source of truth).

## task-012: vmess:// '#fragment' strip before base64 decode

- Root cause: the `vmess)` case in `sing_box_config_facade.sh` passes the RAW
  pre-url_decode link (`$raw_url`, kept that way by task-005 S1 to preserve `+`),
  which STILL carries the `#fragment` (server display name, e.g. `#🇳🇱Ne`).
  `vmess_link_to_json` only did `payload="${url#vmess://}"`, so the `#`/emoji/
  Cyrillic bytes corrupted the base64 → decode failed → fatal. facade:72's
  `url_strip_fragment` only touched the separate `$url`, NOT `$raw_url`, so the
  strip MUST live inside `vmess_link_to_json`.
- Fix (helpers.sh, ONE line): right after `payload="${url#vmess://}"` add
  `payload="${payload%%#*}"` (POSIX longest-`#…`-suffix strip). Safe because the
  base64 body never contains `#`; fragment-less payload = no-op. Existing
  whitespace-strip (`tr -d ' \011\012\015'`, NOT `[:space:]`) + `=` pad loop +
  `base64_decode` run unchanged on the fragment-free payload. Did NOT touch the
  facade / reintroduce url_decode. VMess canonical name still comes from JSON
  `ps`; we only drop the fragment, do not adopt it as the name.
- Smoke: extended the existing vmess facade block in `test_sing_box_config` (`sb`
  category — no new top-level test/registration) with a `vmess-frag-*` case:
  `vmess://<base64(JSON)>#🇳🇱Ne`, sanity-check the link has `#`, then assert
  server/uuid/transport/tls on the generated outbound. The existing ws/tcp/plus
  cases (no `#`) double as the no-fragment regression. shellcheck -S error clean;
  `all` = 76 passed / 0 failed.

## task-013: sing-box-extended version diagnostic (build-suffix strip)

- Root cause: `check_sing_box()` (`bin/netshift`, ~:3276) does
  `version=$(sing-box version | awk '{print $3}')` then `patch=$(... cut -d. -f3)`.
  Extended core prints `1.13.12-extended-2.3.2`, so `patch` became
  `12-extended-2` → non-numeric → `[ "$patch" -ge 4 ]` errors `bad number` →
  `❌ not compatible`. Stock cores have numeric patch so they passed.
- Fix (Variant A′, ONE line + comment): right after the existing
  `version=$(echo "$version" | sed 's/^v//')`, add `version=${version%%-*}`
  (POSIX longest-`-…`-suffix strip; no fork/jq/regex). `1.13.12-extended-2.3.2`
  → `1.13.12`; stock `1.12.0` has no `-` so unchanged; also tolerates future
  `-beta`/`-rc`. `major`/`minor`/`patch` are already `local`; no new vars.
- **OUT-OF-SCOPE PRE-EXISTING BUG (left untouched per spec, but flag it):** the
  comparison chain `if [ "$major" -gt 1 ] || [ "$major" -eq 1 ] && [ "$minor"
  -gt 12 ] || ... && [ "$patch" -ge 4 ]` has wrong precedence — POSIX `[]`
  `&&`/`||` are equal-precedence left-associative, so it evaluates as
  `(...) && [ "$patch" -ge 4 ]`, making the final patch test gate EVERY branch.
  Result: `1.13.12` and even `2.0.0` evaluate to version_ok=0 (only `1.12.x>=4`
  passes). The spec (task-013) explicitly says do NOT rewrite the chain — it
  only fixes the non-numeric `bad number` crash. So the extended diagnostic no
  longer errors, but a TRUE fix of "newer than 1.12.4 ⇒ compatible" needs a
  follow-up task to correct the chain (e.g. parenthesize each branch in a
  single `[ ]` per term or use `sort -V` like `check_requirements` does).
- Smoke: NO new test (pure string strip, no new control flow — per spec). Reran
  `shellcheck -S error` clean on `bin/netshift`; `smoke-tests all` = 76 passed /
  0 failed.

## task-014: route the MAIN DNS server through a proxy outbound (detour)

- The cm/cf DNS primitives ALREADY accept `detour` as the last arg and merge it
  conditionally (`+ (if $detour != "" then {detour:$detour} else {} end)`):
  `sing_box_cf_add_dns_server` $6, `sing_box_cm_add_udp/tls_dns_server` $6,
  `_add_https_dns_server` $8. So an EMPTY detour tag => byte-identical to the
  pre-feature output (proven in smoke via `jq -cS` object compare of the
  empty-tag main server vs a no-detour-arg call). Do NOT touch cm/cf for this.
- New helper `_get_dns_detour_tag()` (bin/netshift, next to
  `_determine_first_outbound_section`/`get_first_outbound_section`) echoes the
  tag or "" = direct. NEVER `exit`; every fallback logs `warn` and degrades to
  direct. Cascade: (1) `dns_via_outbound`!=1 -> "" silent; (2) explicit
  `dns_outbound_section` valid + `section_has_configured_outbound` -> it, else
  warn(if non-empty) + `get_first_outbound_section`; (3) no candidate -> warn+"";
  (4) candidate connection_type block/exclusion -> warn+""; (5)
  `subscription_outbound_is_unavailable` -> warn+"" (self-heal on fresh boot /
  failed sub); (6) else `get_outbound_tag_by_section "$candidate"`. Mirrors
  `get_subscription_download_proxy_address` (toggle + section + fail-safe).
- Wired ONLY into the main `SB_DNS_SERVER_TAG` server in `sing_box_configure_dns`
  (6th arg). Bootstrap (`SB_BOOTSTRAP_SERVER_TAG`) + FakeIP stay direct on
  purpose (chicken-and-egg: bootstrap resolves the DoH/DoT host before the tunnel
  is up; it's also the `domain_resolver` for a hostname main DNS). Two new UCI
  opts documented (commented) in `etc/config/netshift`: `dns_via_outbound`(bool,
  default 0) + `dns_outbound_section`. Read with `config_get_bool`/`config_get`
  + safe defaults — never required live.
- Did Req 4 (low-risk, observable): `check_dns_available` JSON gains
  `"dns_via_outbound_tag"` (via `_get_dns_detour_tag`); `global_check` prints
  `ℹ️ Main DNS via outbound: <tag>` or `ℹ️ Main DNS: direct` (valid-UTF-8 emoji).
- **LuCI `config_get` always returns 0** (assign-and-succeed even when the option
  is unset, leaving the var empty). So step-2's `config_get ... && [ -n "$var" ]`
  detects a non-existent section purely via the EMPTY connection_type, not via rc.
  Test stubs must mimic this (assign-then-`return 0`).
- New top-level smoke test `test_dns_via_outbound` (alias `dnsdetour`): builds
  on/off configs through the real cf/cm path (asserts main-has-detour,
  bootstrap/fakeip no-detour, off no-detour, off byte-parity, both pass live
  `sing-box check`), then awk-extracts `_get_dns_detour_tag` VERBATIM from the bin
  and runs the 8-case cascade table with stubbed UCI + reused helpers. Registered
  in `all)` + case alias + usage "Available:" line + docker-compose comment.
  shellcheck -S error clean on bin + libs + install.sh; `smoke-tests all` = 76
  passed / 0 failed (suite total unchanged because the per-line `pass` runs in a
  piped `while` subshell — same counter quirk as test_subscription; the per-test
  ✓ marks are the source of truth, here 15 green for dnsdetour).

## task-014 (PR#11 backend fixes): nft v6 bracket + dead-code removal

- **nft IPv6 `tproxy ... to` MUST bracket the address** — `tproxy ip6 to
  "$ADDR_V6:$PORT_V6"` expands to `::1:1603`, which nftables v1.1.3 parses as a
  BARE IPv6 address (`[::0.1.22.3]`, port 1603 read as 0x1603 hextet) with NO
  port. `nft -c` PASSES and `sing-box check` is unrelated — neither gate catches
  it; only on-device IPv6 breaks. Fix: `tproxy ip6 to "[$ADDR_V6]:$PORT_V6"`.
  Verify with the no-root trick: write the rule to /tmp/t.nft and
  `unshare -rn sh -c 'nft -f /tmp/t.nft && nft list ruleset' | grep tproxy` —
  bracketed form normalizes to `tproxy ip6 to [::1]:1603` (correct). The IPv4
  `tproxy ip to "$ADDR:$PORT"` is fine (IPv4 has no `:` ambiguity). sing-box
  inbounds (`sing_box_cm_add_*_inbound` address+port as SEPARATE jq args ->
  JSON `listen`/`listen_port`) have NO bracket defect — don't "fix" them.
- **Router-originated traffic is DIRECT by design** (operator decision A). The
  PR's model marks only LAN/forwarded traffic in `mangle` (prerouting) and
  splits proxy/direct in sing-box; `mangle_output` only carries local/loopback
  daddr returns + the `NFT_OUTBOUND_MARK` return (so sing-box-originated packets
  don't loop back into tproxy). Documented with a comment; no behavior change.
- **The `@netshift_subnets` (`NFT_COMMON_SET_NAME`) nft set was fully dead** —
  created + populated at 6 sites but matched by NO nft rule after PR#11. SAFE to
  remove because every subnet source is independently carried into a sing-box
  rule_set: user_subnets -> `patch_source_ruleset_rules ip_cidr` + local source
  ruleset; local_subnet_lists -> `import_plain_subnet_list_to_local_source_ruleset_chunked`;
  community_lists -> `configure_community_list_handler` (`$SRS_MAIN_URL/<svc>.srs`
  remote ruleset); remote json/srs subnets -> `configure_remote_domain_or_subnet_list_handler`
  (`sing_box_cm_add_remote_ruleset`); remote plain -> `prepare_source_ruleset` +
  plain import. DISCORD is the ONE exception that still needs an nft set
  (`NFT_DISCORD_SET_NAME`) — it has a live dport-restricted mangle rule
  (`@netshift_discord_subnets udp dport {19000-20000,50000-65535}`) that a
  sing-box route rule can't express. Removed: set creation (~972), all 6
  `nft_add_set_elements*` populate calls, the now-orphaned
  `import_subnets_from_remote_json_file`/`_srs_file` (json/srs now log
  "sing-box manages updates" like the domains path), `netshift_subnets` from the
  diagnostics `sets` list, and the `NFT_COMMON_SET_NAME` constant. Left the 9
  IPv4 `SUBNETS_*` constants (only `SUBNETS_DISCORD` used) in place — constants.sh
  is `# shellcheck disable=SC2034` so unused-looking vars don't fail lint, and
  trimming them was out of declared scope.
- **8 `SUBNETS_*_V6` constants had zero consumers** (`git grep` only matched
  definitions + a memory doc) — removed.
- **B-09 dead predicates**: `is_ip`/`is_ipv6_cidr`/`is_ipv6` in helpers.sh were
  all unused (`is_ipv6` only called by the other two; tests use only `is_ipv4`/
  `url_is_ipv6_literal`/`is_ipv4_ip_or_ipv4_cidr`). Removed all three.
- **Monitor spawn guard (B-05)**: extracted `start_sing_box_monitor` mirroring
  the `start_subscription_startup_retry_worker` pidfile-guard — if
  `/var/run/netshift_monitor.pid` exists and `kill -0 "$pid"` succeeds, skip the
  spawn (else `rm` stale pidfile then spawn). Prevents a procd double-start from
  orphaning a monitor that `stop()` can no longer kill.
- **B-08 dnsmasq guard (review-001 FIX — sentinel, not markers)**: my first B-08
  attempt gated `dnsmasq_is_configured_for_netshift` on the presence of a private
  backup marker (`netshift_server`/`netshift_noresolv`/`netshift_cachesize`).
  That was WRONG and regressed STOCK dnsmasq: on a default box with no original
  server/noresolv/cachesize, `dnsmasq_configure` writes NO markers
  (`backup_dnsmasq_config_option` only writes when the original value is
  non-empty; the server-backup loop is skipped when current servers are empty).
  So the guard returned false, and the redundant `dnsmasq_configure force` path
  (monitor recovery restart, double-start) re-ran "backup" — but the LIVE values
  were now netshift's OWN (noresolv=1, cachesize=0), so it captured those as the
  backup -> `dnsmasq_restore` later restored 1/0 instead of the OpenWRT defaults
  (0/150) -> router DNS broken after stop/uninstall.
  CORRECT fix = an explicit netshift-owned SENTINEL: `dnsmasq_configure` does
  `uci_set "dhcp" "@dnsmasq[0]" "netshift_configured" 1` UNCONDITIONALLY right
  after applying our config (before the commit); `dnsmasq_is_configured_for_netshift`
  short-circuits iff `netshift_configured == 1` (authoritative ownership flag, no
  value/marker inference); `dnsmasq_restore` clears it with `uci_remove_quiet`
  before its commit so a fresh future configure re-establishes ownership. The
  sentinel is a distinct option name (not in the `server` list), so it never
  leaks into the server/backup iteration. Verified all 3 scenarios via an
  awk-extracted-functions harness (use an EXACT-match UCI stub — `awk -F'\t'
  $1==k`, NOT grep/sed, because the literal `@dnsmasq[0]` key contains `[0]`
  which a regex reads as a char class and silently mis-reads every lookup):
  (A) stock -> sentinel set, no spurious backup, force-again short-circuits,
  restore=0/150, sentinel cleared; (B) admin-had-config -> real values backed up
  & restored intact; (C) coincidental admin match w/o sentinel -> NOT treated as
  owned. shellcheck clean; smoke 81/0.
- shellcheck -S error clean (bin + libs + install.sh); `smoke-tests all` = 81
  passed / 0 failed (unchanged baseline). No new smoke test (separate packaging
  task owns nft/v6 coverage per spec). No sacred constant VALUES changed.

## task-017: Component Manager backend (stock latest, NetShift self-update)

- **Two new component_action() cases** (`updater.sh` ~:1612): `sing_box:
  check_update_stable) updates_check_sing_box_stable` (SYNC) and
  `netshift:self_update) updates_self_update_netshift` (async via the existing
  `component_action_async`). NO dispatcher (bin/netshift) change — both are
  sub-cases of the already-routed `component_action`; `component_action_async`/
  `_status` are component-agnostic. NO ACL change.
- **pkg-manager abstraction re-implemented locally** (updater.sh does NOT source
  install.sh): `updates_pkg_is_apk` (`command -v apk`), `updates_pkg_install_file`
  (apk add --allow-untrusted / opkg install, `</dev/null` non-interactive),
  `updates_pkg_is_installed` (apk/opkg list grep), `updates_pkg_candidate_version`
  (FEED version). Candidate parse, busybox-safe, NO Oniguruma: opkg `list <pkg>`
  → `"<name> - <ver>"`, `awk -F' - ' '{print $2}'`; apk `list <pkg>` → first
  token `<name>-<ver>`, strip `"<pkg>-"` prefix via `${line#"$pkg"-}`.
- **Stock check `updates_check_sing_box_stable`**: mirrors the extended-check JSON
  shape. Runs `opkg/apk update` best-effort first (`|| true`). status: candidate
  empty → `success:false` (feed unreachable, return 1); sing-box absent
  (`command -v`) → `not_installed`; else compare on LEADING semver `${v%%-*}`
  (drops `-r1`/`-extended-…`) via `is_min_package_version` (sort -V) →
  `latest`/`outdated`. NEVER exits. STABLE JSON: `{success,current_version,
  latest_version,status:"latest"|"outdated"|"not_installed"}`.
- **NetShift self-update = Variant A** (targeted pkg upgrade, NOT install.sh).
  `updates_self_update_netshift` (public wrapper) COPIES the
  `updates_install_sing_box_extended` epilogue EXACTLY: reset UPDATES_HEAL_*,
  `updates_ensure_connectivity "extended"` (GitHub dir) else restore+fail JSON,
  run `_updates_self_update_netshift_core >"$out"`, capture rc+json, rm, ALWAYS
  `updates_restore_after_swap`, re-emit, `return $rc`. Single cleanup path; no
  trap. Core is NON-interactive, all `local`, NEVER `exit`: idempotent guard
  (`${installed#v}` == `${latest#v}` → "Already up to date"); minimal
  `/etc/config/netshift` tmpfs backup; download assets matching pkg-name prefixes
  (`netshift`,`luci-app-netshift`, RU i18n ONLY if `updates_pkg_is_installed`)
  filtered to `.ipk`/`.apk` by pkg-mgr via `grep -o 'https://[^"[:space:]]*\.ext'`
  (mirrors install.sh:269-274, busybox-safe); install core→luci→ru; core-install
  fail is fatal-to-the-op (success:false + restore config), luci/ru fail is
  non-critical (warn+continue); defensive config restore if live file empty.
- **Self-replacement CONFIRMED safe**: the `netshift` pkg overwrites
  `/usr/bin/netshift` (this very script). busybox ash reads the whole script into
  memory before pkg_install; the async fork (`( trap '' HUP; "$0" component_action
  netshift self_update >out; updates_write_finished_job_state ... )`) + the
  finished-state write complete from memory. The self-update core has ZERO live
  re-exec after install: NO `updates_restart_netshift`, NO `"$0"`, NO `exec`, NO
  direct `/usr/bin/netshift` or `/etc/init.d/netshift` call. (Only path that runs
  the init script is `updates_restore_after_swap`'s `/etc/init.d/netshift start`,
  which fires ONLY if the heal tore the redirect down, AFTER install completes,
  as a fresh subprocess that safely loads the on-disk binary.) UI (task-018)
  reloads the page after success. Verified via `grep` of the core's line range.
- **New constants** (constants.sh, NO ports/marks): `NETSHIFT_RELEASE_API_URL`
  (= install.sh REPO / get_system_info :3347 endpoint),
  `UPDATES_NETSHIFT_DOWNLOAD_DIR=/tmp/netshift/selfupdate`,
  `UPDATES_NETSHIFT_CONFIG_BACKUP=/tmp/netshift/config.bak`,
  `UPDATES_NETSHIFT_PKG_CORE/LUCI/I18N_RU`. `get_system_info` UNCHANGED (UI gets
  versions there; stock check is a separate action — no missing field).
- **Subshell-piped `while read url` loop can't set parent vars** (task-007
  variant): `_updates_self_update_download_assets` re-checks the dir
  (`ls "$dir/netshift"*`) AFTER the loop to decide success, not a flag set inside.
- **Smoke tests `test_check_update_stable` (alias `stablecheck`, 4 cases) +
  `test_self_update_netshift` (alias `selfupdate`, 13 assertions)**. Both source
  the REAL updater.sh + helpers.sh, re-pin paths/constants, stub via markers.
  `test_check_update_stable` KEY GOTCHA: `command -v sing-box` finds the real
  `/usr/bin/sing-box`; to test `not_installed` I built an ISOLATED PATH dir of
  symlinks to just the needed coreutils (NO /usr/bin in PATH) and linked the fake
  sing-box in/out per scenario. `test_self_update_netshift` overrides
  `updates_http_get_once` (GitHub JSON) + `updates_download_to_file` in the driver
  + stubs opkg `install`/`list-installed` (logs installs) + fake `/etc/init.d/
  netshift` (absolute write+restore). Registered all 5 points (all)/case/usage/
  compose). Used task-009 `... || true` set -e guard. shellcheck -S error clean;
  `smoke-tests all` = 101 passed / 0 failed (was 84 baseline; +17 new).

## task-019: extended-check false "outdated" — v-prefix mismatch (Variant A)

- Root cause: `updates_check_sing_box_extended` (updater.sh ~:1245) compared
  installed `get_sing_box_version` (`1.13.12-extended-2.3.2`, NO v) against the
  GitHub `.tag_name` (`v1.13.12-extended-2.3.2`, WITH v) via `case
  "$current_version" in *"$tag"*)`. The `v` prefix means the substring never
  matched → fell through to `outdated` for a user ALREADY on the latest. (Stock
  check + self-update were already correct: stock candidates have no v;
  `_updates_self_update_netshift_core` already does `${installed#v}` ==
  `${latest#v}`.)
- Fix (Variant A, ONLY this function): strip a single leading v off BOTH sides
  (`cur_norm="${current_version#v}"; tag_norm="${tag#v}"`; `${x#v}` removes one
  leading v if present, no-op otherwise), then EXACT-compare `[ "$cur_norm" =
  "$tag_norm" ]` (the extended version is the full token — exact-after-v-strip is
  correct and avoids the partial matches the old `case *"$tag"*` allowed). Emit
  BOTH `current_version` and `latest_version` v-stripped so the UI shows a
  consistent string. JSON shape/keys/order unchanged (STABLE for task-018);
  `success:false` branches (fetch fail, no tag) untouched. New vars `local`,
  POSIX ash, never exits.
- CRITICAL isolation: the install/asset path is a SEPARATE function
  (`_updates_install_sing_box_extended_core`, ~:942-957) that re-derives its OWN
  `tag` from `updates_extended_release_tag` (raw, WITH v) and feeds it to
  `updates_extended_release_object` (`.tag_name == $t`) + `updates_extended_asset_url`.
  In the check, `tag` (raw) is NO LONGER fed anywhere downstream — only `cur_norm`/
  `tag_norm`. Did NOT touch `_release_tag`/`_release_object`/`_asset_url`/wrappers.
- Smoke: NEW top-level `test_check_update_extended` (alias `extcheck`, 3 cases).
  updater.sh is a sourceable lib, so the driver sources updater.sh + helpers.sh,
  silences log/echolog/nolog, then OVERRIDES the 3 deps AFTER sourcing
  (`get_sing_box_version`, `updates_fetch_sing_box_extended_releases`,
  `updates_extended_release_tag`) reading marker env (`STUBEXT_INSTALLED/RELEASES/TAG`)
  — simpler than awk-extract since it's not in bin/netshift. Cases: (1) installed
  == latest, only tag has v → latest + both v-stripped+equal (THE regression);
  (2) installed older → outdated; (3) empty releases → success:false. Registered
   all 5 points (all)/case/usage/docker-compose comment). shellcheck -S error clean
   (bin+libs+install.sh); `smoke-tests all` = 104 passed / 0 failed (101 baseline
   + 3 new). `extcheck` alone = 3/0.

## task-020a: drop stale "mangle output counters" diagnostic (PR#11 B-02 align)

- The diagnostic function the spec calls `check_nft` is actually named
  **`check_nft_rules`** in bin/netshift. After PR#11 (router-originated traffic
  intentionally DIRECT) the `mangle_output` chain's only counter rule
  (`meta mark 0x00200000 counter return`) is essentially never hit → counter
  legitimately 0 → the old non-zero-counter assertion produced a FALSE ⚠️.
  Operator decision Variant A = REMOVE the "mangle output counters" check
  entirely; KEEP "mangle output exist".
- Backend fix (bin/netshift ONLY, 6 deletions): in `check_nft_rules` removed the
  `rules_mangle_output_counters` local, the inner `grep -qv "packets 0 bytes 0"`
  block that set it, and the key from the emitted JSON echo. In `global_check`
  removed it from the `local` decl, its `jq -r '.rules_mangle_output_counters //
  0'` read, and the `if ... ✅/⚠️ Rules mangle output counters` print block.
  KEPT the existence check (`grep -q "counter" → rules_mangle_output_exist=1`)
  and its ✅/❌ print. Did NOT touch mangle(prerouting)/proxy/other_mark or
  `create_nft_rules`.
- **STABLE check_nft_rules JSON shape (cross-layer contract for frontend 020b),
  exactly ONE key removed, order otherwise unchanged:** `{table_exist,
  rules_mangle_exist, rules_mangle_counters, rules_mangle_output_exist,
  rules_proxy_exist, rules_proxy_counters, rules_other_mark_exist}`.
- **No smoke test referenced the field** — `tests/entrypoint.sh` has no
  `test_diagnostics`/nft-check assertion on the check_nft_rules JSON at all (the
  `nft` category tests rule installation, not the diagnostic JSON keys). So no
  smoke change and no registration change. Diagnostics-only edit (read-only
  checks), NOT a routing/config change — nft model unchanged. shellcheck -S error
  clean; `smoke-tests all` = 104 passed / 0 failed (unchanged baseline); UTF-8
  intact (iconv round-trip OK, 0 рџ/в”/вЂ mojibake).

## task-021b: opt-in insecure subscription fetch (--no-check-certificate)

- Cross-layer UCI contract (STABLE, shared with 021a frontend):
  `option subscription_insecure '0'` (0|1), per `config section`. Default OFF =
  unchanged secure behavior. On device wget=uclient-fetch supports
  `--no-check-certificate` (confirmed) — for IP-host panels with invalid/
  self-signed/missing-SAN HTTPS certs.
- `download_subscription` (helpers.sh) had SIX identical wget invocations (4 in
  the main loop: ipv4/normal × proxy/no-proxy + 2 in the IPv4 retry), each with
  the same 7 `--header` set. Refactored ALL six through a new private helper
  `_wget_subscription_request "$cert_flag" UA HWID MODEL KERNEL OUT ERR URL --
  <leading flags>`: it runs `wget $cert_flag "$@" -O "$out" <headers> "$url"
  2>"$err"`. The `$cert_flag` is the ONE intentional unquoted expansion
  (`# shellcheck disable=SC2086` on that line): empty string word-splits to ZERO
  args (byte-identical secure default), `--no-check-certificate` adds exactly
  one. NO eval. Per-branch `-4`/`-T <timeout>` are passed as the trailing
  `"$@"` flags; proxy env (`http_proxy=`/`https_proxy=`) still set on the call
  line. Retry/fallback/rc/mv/errfile logic untouched.
- 8th positional `insecure="${8:-0}"`; `cert_flag` derived once at top
  (`[ "$insecure" = "1" ]`).
- bin/netshift `download_subscription_into_cache`: read
  `subscription_insecure="$(uci -q get "netshift.${section}.subscription_insecure"
  2>/dev/null)"`, default 0, log ONE redacted `warn`
  (`...uses --no-check-certificate (TLS verification disabled): url=$(redact_url_for_log ...)`)
  when =1, pass as the NEW 8th arg after the existing
  `... 3 2 10 "$effective_user_agent"`. Declared `local subscription_insecure`.
- UCI example: added commented `#option subscription_insecure '0'` + 3-line
  comment near the `subscription_url` example in `etc/config/netshift`.
- Smoke: NEW top-level `test_insecure_fetch` (alias `insecure`, 6 cases). A
  PATH-prepended fake `wget` records full argv (`printf '%s\n' "$*"`) and writes
  a dummy body to its `-O` target so attempt-1 succeeds (no retry). Driver
  sources REAL helpers.sh, stubs log/metadata helpers + `should_force_wget_ipv4`
  (per-scenario normal vs ipv4) + inert `has_ipv4_default_route`/
  `wget_supports_ipv4_flag`. Asserts `--no-check-certificate` ABSENT@insecure=0 /
  PRESENT@insecure=1 across normal+proxy+ipv4 branches (`-4` co-present on ipv4).
  Registered all 5 points (all)/case alias/usage line/docker-compose comment).
  shellcheck -S error clean; `smoke-tests all` = 110 passed / 0 failed (104
  baseline + 6 new); UTF-8/LF intact. Additive, NO runtime-contract change.

## task-022: multiple subscription_url feeds per section (merge pipeline)

- **subscription_url is now a UCI list.** Back-compat verified: a lone legacy
  `option subscription_url` is read by `config_list_foreach` as a 1-element list
  (same as community_lists) — NO migration code. New collector
  `get_subscription_urls_for_section` resets global `SUBSCRIPTION_URLS_COLLECTED`,
  runs `config_list_foreach "$section" "subscription_url" _collect_..._handler`,
  prints newline-delimited URLs. URLs are opaque user text → ALWAYS
  newline-delimited + `while IFS= read -r` from a temp file, NEVER word-split.
- **Per-URL cache keying = ALWAYS hash (recommendation ii).** `get_subscription_url_hash`
  = `printf '%s' "$url" | md5sum | awk '{print $1}'`. The 4 cache-path builders
  gained an OPTIONAL 2nd arg `urlhash`: `${section}${urlhash:+.$urlhash}.<ext>`
  — present = hashed `${section}.<hash>.<ext>`, absent = legacy bare path (kept
  only for the tmp-migration source + the reaper). New
  `reap_legacy_subscription_cache_files "$section"` rm's the 4 bare files; called
  at the top of startup/refresh/config-gen so a stale bare body is never read.
  `subscription_cache_is_usable` derives rejected via `${json%.json}.rejected`
  which maps correctly onto the hashed path (no change needed there).
- **download_subscription_into_cache gained a 6th positional `urlhash`** used for
  the UA + rejected cache paths (json/url paths are already passed in as $3/$4).
- **Merge-file approach (primary, chosen — NOT the per-feed-loop fallback).** In
  the config-gen `subscription)` branch: (1) per-feed best-effort download loop
  (one dead feed never aborts others); (2) concat every `subscription_cache_is_usable`
  feed's PROXY `.outbounds[]` into one temp `{"outbounds":[...]}` under
  `TMP_SUBSCRIPTION_MERGE_FOLDER` (new constant) via
  `jq -c --slurpfile feed '... .outbounds += [ $feed[0].outbounds[]? | select(not selector/urltest/direct/dns/block) ]'`
  (NO Oniguruma — pure array concat); (3) call
  `sing_box_cf_add_subscription_outbounds` ONCE on the merged file. WHY merge-file:
  the facade RESETS its public globals every call (`:757-760`) AND seeds the
  dedup `used`-set from tags already in `$config`, so a single call over the
  union reuses the keyword filter + GLOBAL tag-dedup (auto `-1`/`-2`…) + per-batch
  `sing-box check` bisection + the country-group/selector builder UNCHANGED. The
  per-feed-loop fallback would force me to re-accumulate SUBSCRIPTION_OUTBOUND_TAGS_JSON
  by hand (facade resets it each call) — strictly more code for the same result.
- **Dedup suffix is `-1` then `-2`** (facade loops `range(1; ...)` →
  `$base + "-" + n`), so two same-named nodes become `X` and `X-1` (NOT `X-2`).
  Assert base + any `startswith("X-")`, not a specific number.
- **Best-effort semantics:** section "available" iff merged set has ≥1 proxy
  (`usable_feed_count>0 && merged_node_count>0`); else
  `mark_subscription_outbound_unavailable "$section" "$kw_filter_active"` as
  before. Startup/refresh: section "changed"→restart if ANY feed changed (rc 0);
  section "failed" only if NO feed usable AND none changed. Per-feed rc 2
  (unchanged) counts as usable, not failed.
- **mark_subscription_outbound_unavailable is now per-URL** (memory landmine:
  keep rejected-hash PER-URL so one bad feed can't poison another). It iterates
  the section's URLs: keyword-filter case → `rm` each per-URL `.rejected`
  (self-heal); genuine case → write each usable cached feed's md5 to its per-URL
  `.rejected`. The section-level unavailable LIST + `subscription_startup_blocked`
  stay section-level.
- **section_has_usable_subscription_cache** (new) returns 0 if ANY per-URL cache
  is usable; replaces the single-json `subscription_cache_is_usable` checks in
  `get_subscription_download_proxy_address`. Uses temp-file + `while read` (NOT a
  pipe) so the `found` flag survives.
- **migrate_subscription_cache_from_tmp** now maps a bare tmp `<section>.json`
  onto the hashed dest of the URL in its `.url` sidecar (else the section's first
  configured URL) so a legacy single-feed upgrade keeps working w/o re-download.
- **Smoke landmine (test stub):** the REAL LuCI `config_list_foreach` iterates in
  the CURRENT shell (no pipe) so the callback mutates accumulator globals. A test
  stub that pipes `printf | while` subshell-traps the mutation → collector
  returns empty. Stub MUST use temp-file + `while read`. Likewise the facade sets
  globals (SUBSCRIPTION_OUTBOUND_TAGS*) — call it `>/dev/null` (like the real
  bin) and read `$SING_BOX_CF_LAST_CONFIG`, NOT `out=$(facade ...)` (the `$()`
  subshell drops the globals). Both cost a debug cycle.
- Extended `test_subscription` with the 6 spec cases (no registration change —
  `subscription` already in `all)`): mu-case1 multi-URL merge (count+both feeds+
  tags-json), mu-case2 same-name dedup (no dup tags + suffix present), mu-case3
  partial best-effort (A usable/B invalid → still available, not unavailable),
  mu-case4 all-fail→unavailable, mu-case5 cache-key isolation (distinct
  `${section}.<hash>.json` + per-URL `.rejected`), mu-case6 single-option
  back-compat (1-elem list + working config). Driver awk-extracts the shipped
  path/hash/collector/cache-usable/mark-unavailable fns + mirrors the inline
  merge jq; feeds are stock shadowsocks so the live `sing-box check` accepts them.
- shellcheck -S error clean (bin+libs+install.sh); `smoke-tests all` = 110 passed
  / 0 failed (per-test ✓ marks are truth: 12 green mu-case marks; suite total
  unchanged due to the documented piped-while subshell counter quirk). UTF-8
  intact. New constant `TMP_SUBSCRIPTION_MERGE_FOLDER`; UCI example documents the
  `list subscription_url` form. NO sacred constant/port/mark/path changed.

## task-027: core-swap backup integrity (truncated-rollback anti-segfault)

- Root cause (hardware, OpenWrt 25, armv7, tiny overlay): the tmpfs core backup
  used `cp -p ... 2>/dev/null` checking ONLY cp's rc. busybox `cp` can TRUNCATE
  under tmpfs ENOSPC and still return 0, so a partial backup passed the "Failed
  to backup current sing-box binary" guard; then the rollback `mv backup ->
  /usr/bin/sing-box` restored a 12.7 MB stub in place of the real ~40 MB core →
  segfault (rc 139) on every invocation. The rollback IS the safety net, so a
  corrupt backup is strictly worse than not rolling back.
- Two new helpers at the top of `updater.sh` (next to `updates_log`):
  `updates_verify_copy src dst` (0 iff dst exists and `wc -c < dst` == `wc -c <
  src`; absent src → 0 = nothing to back up) and `updates_backup_is_complete
  backup expected_size` (0 iff backup exists and `wc -c` == the stashed size).
  Size-match only — guarding TRUNCATION not bit-rot; do NOT md5/sha a 40 MB
  binary on slow armv7. busybox-safe `wc -c < file` (NOT GNU stat).
- **Stash the expected size at backup time.** After each backup `cp` succeeds +
  verifies, record `backup_binary_size="$(wc -c < "$backup_binary")"` (and
  `backup_cronet_size`) into NEW locals. Rollbacks compare the backup's current
  size against that stash (not against the live `/usr/bin/sing-box`, which the
  half-written extract may have already clobbered). For `updates_stable_rollback`
  the sizes are passed as NEW args $3/$4 — both call sites updated.
- Backup-cp gates (4): extended binary, extended libcronet, stable binary,
  stable libcronet — each `if ! cp -p ... || ! updates_verify_copy ...; then`
  inside the EXISTING abort path that fires BEFORE the live binary is touched →
  healthy box = no-op pass, working core left intact on failure.
- Rollback restore guards (4 sites): extended extract-fail, extended cronet-fail,
  extended validation-fail, and shared `updates_stable_rollback`. Pattern: `if
  updates_backup_is_complete "$backup" "$size"; then mv -f ...; else updates_log
  "...backup is corrupt/incomplete; NOT restoring to avoid installing a broken
  core" "error"; fi`. NEVER overwrite live from a truncated backup.
- CRITICAL: this runs inside the `component_action` async worker → NO `exit 1`
  (would kill the worker, skip JSON emission + restore epilogue). The corrupt-
  backup branches just `updates_log "..." "error"` and fall through to the
  existing `echo "{...success:false...}"; return 1` honest-failure path. Did NOT
  touch download/extract streaming (rm-then-stream), connectivity self-heal,
  async machinery, or any constant.
- Smoke: NEW top-level `test_backup_integrity` (alias `backupguard`, 10
  assertions). Driver sources REAL updater.sh, silences log, re-pins
  `UPDATES_SING_BOX_BIN`/`UPDATES_LIBCRONET_LIB` to /tmp temp files (so the
  container's real binary is untouched), builds 64-byte src + complete + 10-byte
  truncated fixtures via `dd`, then drives the 3 helpers + `updates_stable_rollback`
  with truncated vs complete backups (asserts live marker survives the truncated
  rollback AND the complete one overwrites it). Parsed in the CURRENT shell
  (`while read < "$out"`, no pipe) so PASS counts are EXACT (avoids the
  piped-while subshell counter quirk). Registered all 5 points (all)/case alias/
  usage line/docker-compose comment). shellcheck -S error clean (bin+libs+
  install.sh); `smoke-tests all` = 120 passed / 0 failed (110 baseline + 10 new).

## task-029: NetShift latest-version check on-demand (stop auto-fetch in get_system_info)

- Root cause: `get_system_info` (bin/netshift) did `curl -m 3 ... releases/latest`
  on EVERY call, and the UI calls it on Manager/Diagnostic mount → a GitHub hit
  on every page load. Cores do it right via on-demand `component_action`.
- Fix 1 (get_system_info): REMOVED the curl + the `[ -z ] && unknown` line;
  replaced with the constant `netshift_latest_version="unknown"`. The KEY stays
  (frontend type + global_check jq read it; "unknown" is the zero-network
  sentinel the UI understands). Function now does ZERO network I/O.
- Fix 2 (new worker `updates_check_netshift`, updater.sh, right after
  `updates_check_sing_box_stable`): SYNC component_action worker, NEVER exits
  (echo JSON; return N). Reused the EXISTING shared helper
  `updates_netshift_latest_tag` (already there from task-017: `updates_http_get_once
  "$NETSHIFT_RELEASE_API_URL"` then `grep '"tag_name":' | head -n1 | cut -d'"' -f4`)
  — did NOT add a new helper or a new curl. Empty tag → `{"success":false,
  "message":"..."}` return 1 (mirrors stable "feed unreachable"). v-normalization:
  `cur_norm="${current_version#v}"; latest_norm="${latest#v}"` then leading-semver
  `${x%%-*}`, compared via `is_min_package_version` (sort -V `>=`) → latest/outdated.
  JSON shape IDENTICAL to `updates_check_sing_box_stable`
  (`success/current_version/latest_version/status`) so frontend
  `parseComponentCheckUpdate` is unchanged.
- DEV-BUILD decision: if `$NETSHIFT_VERSION` is the unstamped placeholder
  (`*COMPILED*` — it's `__COMPILED_VERSION_VARIABLE__`), report `status:"latest"`
  (a dev build is never "outdated"; UI also guards dev separately). It STILL
  fetches the real tag for display, and STILL returns success:false on an
  unreachable feed (honest failure even for dev).
- Router: added `netshift:check_update) updates_check_netshift ;;` next to the
  existing `netshift:self_update` in `component_action()`. NO ACL change
  (component_action is wholesale exec-allowed); NO new top-level command.
- Fix 3 (global_check, bin/netshift): since get_system_info no longer carries the
  real latest, global_check now calls `updates_netshift_latest_tag` itself
  (`netshift_latest_version=$(updates_netshift_latest_tag); [ -z ] && ="unknown"`)
  so the `🕳️ NetShift: <ver> (latest: <latest>)` line still shows the true latest.
  A network call here is fine — one-shot SSH diagnostic, not the UI mount path.
  updater.sh is sourced by bin/netshift so the helper is in scope.
- Constant: `NETSHIFT_RELEASE_API_URL` already existed (task-017) — reused, none
  added.
- Smoke: NEW top-level `test_check_update_netshift` (alias `netshiftcheck`, 7
  assertions). Part A = STATIC awk-extract of `get_system_info` body + assert NO
  `releases/latest` and `netshift_latest_version="unknown"` present. Part B =
  driver sources updater.sh+helpers.sh, silences log, OVERRIDES
  `updates_netshift_latest_tag` + sets `NETSHIFT_VERSION` (mirrors the
  test_check_update_extended stub style), runs the worker. Cases: v0.8.6 vs 0.8.6
  →latest; 0.8.5 vs 0.8.6→outdated; v0.8.6 vs v0.8.6→latest; JSON-shape has-keys;
  empty tag→success:false; placeholder dev-build→latest. Registered all 5 points
  (all)/case alias/usage line/docker-compose comment). shellcheck -S error clean
  (bin+libs+install.sh); `smoke-tests all` = 127 passed / 0 failed (120 baseline
  + 7 new). NO sacred constant/port/mark/path/ACL/frontend change.

## task-031 — subscription_format_preference (UA probe reorder)

- Per-section UCI option `subscription_format_preference` (auto|xray|singbox,
  default auto) REORDERS the UA candidate probe so xray-yielding UAs can be
  tried FIRST. Root cause it fixes: the download probe loop in
  `download_subscription_into_cache` (bin/netshift) breaks on the first usable
  body, so the always-first `singbox/<ver>` UA wins and the Happ/v2rayN UA
  (which some panels answer with Xray JSON carrying xhttp nodes) is never tried.
  We ONLY reorder — first-usable-still-wins loop is untouched.
- `build_subscription_user_agent_candidates` (helpers.sh ~746) now takes a 3rd
  arg `format_preference`. Configured-UA short-circuit (arg1 set → emit only it)
  is UNCHANGED and still outranks preference. For auto-mode ordering I switched
  from a fixed `for candidate in ...` list to `set -- <list>; for candidate in
  "$@"` so I could pick the list by preference in an `if`:
  - xray: `set -- $SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES "$default" "$pref" $SUBSCRIPTION_USER_AGENT_CANDIDATES`
  - else (auto/empty/singbox/unknown): `set -- "$default" "$pref" $SUBSCRIPTION_USER_AGENT_CANDIDATES` (today's exact order).
  The EXISTING newline `seen` dedup loop is reused unchanged → xray UAs precede
  the cached winner AND default, and nothing is emitted twice. Unknown values
  fall through `else` = auto (forward-compatible). Keep the
  `# shellcheck disable=SC2086` intentional-word-split comment on EACH `set --`
  line that splices a `$LIST`.
- New constant: `SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES="v2rayN Happ"` in
  constants.sh next to `SUBSCRIPTION_USER_AGENT_CANDIDATES` (the xray subset;
  no inline magic strings per project-core §5).
- bin/netshift `download_subscription_into_cache` (~530): added local
  `subscription_format_preference`, read via
  `uci -q get netshift.${section}.subscription_format_preference`, default
  "auto" when empty, passed as 3rd arg to the builder (~539). Per-URL cache +
  UA-winner caching unchanged.
- UCI example (etc/config/netshift) documents BOTH the new option AND the
  previously-read-but-undocumented `subscription_user_agent` (schema honesty).
- Tests: extended existing CASE I in `test_subscription`'s `fb` sub-script
  (which sources real constants.sh+helpers.sh under ash). Added cases c2–h:
  empty/auto/singbox→default first; xray→v2rayN,Happ first + outrank
  default&cached pref + dedup; unknown→auto; configured+xray→only configured.
  The `fb` parser is generic `*:OK`/`*:FAIL`, so new `fb-caseI-*` lines need NO
  case alias. shellcheck -S error clean; `smoke-tests all` = 127 passed /
  0 failed (+8 new CASE-I assertions, same 127 total since they're sub-tokens).
- GOTCHA: `test_rejected_hash` emits `rh-case1/2/6:FAIL` sub-tokens that print
  red but are NOT counted by the global tally (suite still EXIT=0, 127/0) — this
  is PRE-EXISTING on the clean tree (verified by git stash), not a regression.

## task-033: multi-section direct-out i/o timeout — egress mark gap (route.default_mark)

- ROOT CAUSE (confirmed on a LIVE kernel in the smoke container): the 0.8.6
  "mark everything" nft model marks ALL LAN tcp/udp with NFT_FAKEIP_MARK
  (0x00100000) in `mangle` prerouting, and `ip rule fwmark 0x00100000 lookup
  netshift` (table `netshift` = `local default dev lo`) redirects it to tproxy.
  But NOTHING stamped a mark on sing-box's OWN egress. So sing-box's outbound
  sockets — especially `direct-out`, which under route.final=direct-out now
  carries ALL unmatched + proxy-server-dial + DNS-upstream traffic — inherited
  the tproxy SO_MARK (0x00100000), and the SAME `ip rule` re-captured them into
  `local lo` -> looped back into tproxy -> never reached the internet. That is
  the exact `outbound/direct[direct-out]: i/o timeout` triad (+ DNS n/a, since
  the DNS upstream egress looped too). 0.8.5 masked it: destination-selective
  marking meant unrelated traffic never entered sing-box.
- LIVE PROOF (decisive, reproducible with only busybox curl+nft+ip in the
  container — NO netns/veth needed): install the real `ip rule fwmark
  0x00100000 lookup netshift` + a tiny `type route hook output` nft chain that
  sets a chosen mark on egress to a test IP, then `curl -m`:
  * egress UNMARKED  -> rc=301 ~0.1s (control, reaches internet)
  * egress mark 0x00100000 (FAKEIP) -> rc=28 timeout 5s = LOOP/BLACKHOLE (bug)
  * egress mark 0x00200000 (OUTBOUND) -> rc=301 ~0.15s = ESCAPES (fix)
  Because `ip rule 105` matches ONLY 0x00100000, a 0x00200000-marked egress
  falls through to the main table and egresses normally.
- FIX (minimal, fail-open, B-variant per spec — keep mark-everything but make it
  fail OPEN): emit `route.default_mark = NFT_OUTBOUND_MARK` so every sing-box
  egress connection is stamped 0x00200000. Per sing-box docs, route.default_mark
  is "Set routing mark by default" (Linux), overridden by outbound.routing_mark.
  This makes ALL egress (direct-out, proxy-server dials, DNS upstream) escape
  the `ip rule`, and the EXISTING `mangle_output meta mark 0x00200000 return`
  rule (previously dead — nothing set it) now actually fires to keep that egress
  out of the proxy chain. NO sacred VALUE changed — only newly APPLYING the
  existing NFT_OUTBOUND_MARK constant to egress (explicitly allowed by the spec).
- IMPL: `sing_box_cm_configure_route` gained optional 6th arg `default_mark`
  (sing_box_config_manager.sh) merged conditionally
  (`+ (if $default_mark != "" then {default_mark: ($default_mark|tonumber)}
  else {} end)`) — EMPTY arg is byte-identical to the legacy 5-arg call
  (back-compat asserted in smoke). Caller `sing_box_configure_route`
  (bin/netshift) derives `default_egress_mark=$(( NFT_OUTBOUND_MARK ))` (ash
  arithmetic converts the hex `0x00200000` -> decimal `2097152`; sing-box
  default_mark is an INTEGER, jq `tonumber` does NOT parse hex so pass decimal)
  and passes it to BOTH branches (auto-detect "" iface + explicit iface).
- FEATURES PRESERVED: default_mark is route-global -> applies to v4 AND v6 egress
  (both ip rules match only FAKEIP_MARK, so both escape). DoH-block / per-section
  route rules / DNS-over-proxy are route.rules / dns.servers — untouched. IPv6
  inbounds/sets/rules untouched. Verified v6 + explicit-interface variants both
  carry default_mark=2097152 and `sing-box check` passes.
- SMOKE: new top-level `test_section_isolation` (alias `isolation`, after
  test_nft_ipv6). 8 asserts: (a) config-gen contract — default_mark present as a
  NUMBER == decimal NFT_OUTBOUND_MARK, distinct from FAKEIP mark, empty-arg
  byte-parity + key-omitted; (b) 2-section config (section 2 hysteria2
  UNREACHABLE) with the REAL generated route passes `sing-box check` + carries
  default_mark; (c) LIVE-kernel fail-open proof (gated on nft+curl+net+!SKIP):
  fakeip-marked egress black-holes, outbound-marked egress escapes. Registered
  all 5 points (all)/case alias/usage line/docker-compose comment).
- GOTCHA repeats bitten: (1) `$$` inside a heredoc driver expands to the
  DRIVER's pid, not the entrypoint's — pass output paths in via sed
  placeholder, don't rely on `$$` matching across the two shells. (2) The
  generic `*:OK)` case pattern does NOT match a line with trailing text like
  `si-...:OK (2097152, number)` — use `*:OK*`/`*:FAIL*` (FAIL first). (3)
  Under the suite's `set -e`, bare `ip -4 rule del ... 2>/dev/null` /
  `nft delete ...` abort the whole function when the object is absent — guard
  EACH with `|| true`. (4) Driver-extracted route needs
  `del(.route.rules[]?.__service_tag)` before `sing-box check` (the strip
  normally happens in sing_box_cm_save_config_to_file's walk()).
- shellcheck -S error clean (bin + sing_box_config_manager.sh + install.sh);
  `smoke-tests all` = 131 passed / 0 failed (was 127 baseline; `isolation`'s 4
  direct pass calls counted, its 8 piped-while ✓ marks are the source of truth,
  all green). The pre-existing `rh-case1/2/6:FAIL` red marks persist (documented
  task-031 quirk, suite still EXIT=0).

## task-034 — Destination-selective nft marking (CPU regression fix)

- ROOT: 0.8.6 marked ALL LAN tcp/udp into tproxy (mangle prerouting), so every
  forwarded flow entered sing-box (sniff + full route-rule walk per conn) →
  100% CPU on weak routers. 0.8.5 marked SELECTIVELY: only `@netshift_subnets`
  (proxied dest subnets) + FakeIP range `198.18.0.0/15` (proxied domains).
  Commit 03806d7 went mark-all; d391e32 then deleted NFT_COMMON_SET_NAME + its
  population. Restored Option-1 selective marking.
- KEY INSIGHT: nft only decides ENTER-or-not. Inside sing-box, per-section
  ip_cidr/domain route rules still pick `<section>-out`. So ONE union nft set
  (all sections' proxied subnets) + FakeIP range gates ingress; multi-section
  outbound selection is unaffected. No per-section nft sets needed.
- Re-added `NFT_COMMON_SET_NAME="netshift_subnets"` + v6 mirror
  `NFT_COMMON_SET_NAME_V6` to constants.sh (NEW SET, not a changed sacred
  value). Created in create_nft_rules (v4 always, v6 only if
  netshift_ipv6_enabled).
- New prerouting mangle (DEFAULT, no global_proxy): `ip daddr @localv4 return`
  (kept) → `ip daddr @netshift_subnets mark set FAKEIP_MARK` → `ip daddr
  198.18.0.0/15 mark set` → (ipv6: `@netshift_subnets_v6` + `fd00:ec3a::/32`) →
  DoH-block CIDRs inline when block_doh=1. NO unconditional mark-all.
- GLOBAL_PROXY OVERRIDE: `get_global_proxy_section` is a standalone UCI-only
  helper (reads config_foreach, NOT the `$config` string) so create_nft_rules
  can call it directly (it runs separately from sing_box_configure_route). When
  non-empty → keep mark-EVERYTHING tcp/udp (global proxy wants all traffic in).
- fully_routed_ips are SOURCE clients (source_ip_cidr) — selective dest marking
  would bypass them for direct dests. Added `nft_mark_fully_routed_source_ips`
  (config_foreach over proxy/vpn sections) emitting `ip[6] saddr <ip> mark set`
  rules in the default branch only (global_proxy already marks all).
- ONE centralized population point (no drift): `populate_netshift_subnets_from_file`
  / `_from_string` feed the nft union set (v4 via nft_add_set_elements_from_file_chunked,
  v6 via NEW `nft_add_set_elements_from_file_chunked_v6` in nft.sh — splits by
  presence of `:`; there is NO is_ipv6 helper). Called ALONGSIDE every sing-box
  ip_cidr rule_set population: configure_user_subnet_list (string),
  import_local_subnets_list_handler (file), import_community_service_subnet_list_handler
  (restored twitter/meta/telegram/cloudflare/hetzner/ovh/digitalocean/cloudfront/
  roblox/discord URLs; discord ALSO keeps its dport set), import_subnets_from_remote_*
  (restored json/srs extract via extract_ip_cidr_from_json_ruleset_to_file +
  decompile_binary_ruleset; plain too).
- TIMING: user/local subnets populate at config-gen (sing_box_init_config, after
  create_nft_rules → set exists). community/remote populate in background
  list_update (set exists; ensure_nft_ready_for_list_update recreates table if
  missing). reload/restart = stop+start so both regenerate. Matches 0.8.5.
- PRESERVED: dns-in (127.0.0.42:53) is a separate inbound, not via marked
  tproxy — localv4 return (127.0.0.0/8) doesn't break DNS steering. Domain
  routing via FakeIP range mark. task-033 route.default_mark + mangle_output
  router-origin direct UNTOUCHED. discord dport rule + general @set rule both
  just set the same mark (idempotent, no shadow/double-mark harm).
- TEST: new `test_selective_marking` (alias `selmark`) awk-extracts the SHIPPED
  create_nft_rules + helpers VERBATIM, stubs UCI/predicates via SCN_* env,
  builds the REAL ruleset on a real nft table (override NFT_TABLE_NAME), dumps
  `nft list chain ... mangle` and asserts: (1) @set+FakeIP present & NO mark-all
  (structural: `meta mark set` + `l4proto` line WITHOUT daddr/saddr = mark-all),
  (2) direct-IP bypass = that mark-all absent, (3) global_proxy → mark-all
  present + @set absent, (4) ipv6 mirror present + no mark-all + FakeIP v6,
  (5) fully_routed saddr rule + sing-box check on a 2-section config. 12 asserts
  all green on real nft. Registered all)/alias/usage/compose comment.
- GATES: shellcheck -S error clean (bin + nft.sh + constants.sh + install.sh +
  tests). `smoke-tests all` = 143 passed / 0 failed.

## task-034 RE-OPEN: create_nft_rules was NOT idempotent (stale mark-all survived)

- HARDWARE BUG the first pass + smoke missed: on a real router the LIVE mangle
  chain was STILL mark-all + the `netshift_subnets` set was absent, even though
  the installed bin had the selective code and `get_global_proxy_section`
  returned empty. CONTRADICTION: stubbed-nft trace = selective; real-nft service
  start = mark-all.
- HYPOTHESIS VERDICT: **H1 FALSE, H2-variant TRUE.** Faithful container repro
  (REAL get_global_proxy_section / _determine_global_proxy_section /
  section_has_configured_outbound / get_subscription_urls_for_section via a real
  `config_load` of a hardware-shaped config: one subscription proxy section,
  global_proxy=0) confirmed `get_global_proxy_section` correctly returns EMPTY →
  selective branch taken (H1 false; the mark-all branch is NOT wrongly entered).
  The mark-all rules came from a LEFTOVER table (H2): `create_nft_rules` is NOT
  idempotent — `nft add chain`/`nft add rule` only ever APPEND, and the function
  did `nft add table` (idempotent, no flush) but never deleted the existing
  table. So a `NetShiftTable` left behind by a previous start that was not
  cleanly stopped — **procd respawn (`command /usr/bin/netshift start` re-run
  with no `stop`), in-place package upgrade, or a crash** — keeps its stale
  rules and the new selective rules pile on TOP. A stale mark-EVERYTHING rule
  (from a prior global_proxy run or the 0.8.6 mark-all build) sits at the TOP of
  the prerouting chain and marks ALL traffic before the new destination-selective
  rules ever evaluate → "everything proxied / 100% CPU" even though the selective
  code is present. Reproduced in-container: two consecutive create_nft_rules
  (1st global_proxy, 2nd selective, NO stop between) → final chain had BOTH the
  mark-all rules (first) AND the selective rules (dead). `stop_main` DOES delete
  the table, so the clean stop→start path was always fine; the bug only bit the
  no-stop respawn/upgrade path. `ensure_nft_ready_for_list_update` only calls
  create_nft_rules when the table is MISSING, so it was never the rebuild path.
- FIX (minimal, deterministic): new `nft_delete_table` helper in nft.sh (delete
  inet table iff it exists, fail-open `2>/dev/null`) called at the TOP of
  create_nft_rules (`log "Flush stale nft table before rebuild"; nft_delete_table
  "$NFT_TABLE_NAME"`) BEFORE `nft_create_table`. create_nft_rules rebuilds the
  whole table (sets+chains+rules) from scratch, so flush-first is safe and makes
  it idempotent: the FINAL live chain is always exactly the intended ruleset
  regardless of prior state. No sacred VALUE changed; ensure_nft_ready no-op
  (table already absent when it calls). task-033 default_mark + mangle_output
  untouched.
- WHY THE OLD TEST MISSED IT: `test_selective_marking` (1) STUBBED
  `get_global_proxy_section`, so it never ran the real UCI helper, and (2) always
  did `nft delete table` first (clean slate) and called create_nft_rules ONCE —
  so it never exercised the stale-table/respawn path that is the actual service
  reality.
- STRENGTHENED TEST (5 new asserts, now 17 total for selmark, suite 143→148):
  * Scenario 6 (THE regression repro): env `SCN_PRESEED=1` makes the driver
    leave a STALE mark-all table (full localv4/interface sets + ct/return +
    mark-all tcp/udp) then run create_nft_rules ON TOP with REAL nft and NO
    delete — faithfully reproducing the respawn/upgrade path. Asserts the FINAL
    live chain has NO mark-all (`meta mark set`+`l4proto` line w/o daddr/saddr),
    the @set rule IS present, the union set exists, and EXACTLY ONE @set rule
    (proves rebuild, not append).
  * Scenario 7 (`selective:realgp`): sources real /lib/functions.sh +
    /lib/config/uci.sh, awk-extracts the SHIPPED get_global_proxy_section chain,
    `config_load`s a real hardware-shaped config (subscription proxy,
    global_proxy=0), asserts `GP=[]` → selective branch (kills the stub blind
    spot). Skips if LuCI/uci absent.
  * PROVEN to catch the bug: reverting the flush makes `selective:respawn —
    stale mark-all rule SURVIVED the rebuild` FAIL (16/1); with the fix 17/0.
- GATES: shellcheck -S error clean (bin + nft.sh + constants.sh + install.sh +
  tests/entrypoint.sh). `smoke-tests all` = 148 passed / 0 failed (143 + 5).
  Pre-existing `rh-case1/2/6:FAIL` red marks persist (documented task-031 quirk;
  suite still EXIT=0). No registration change needed (selmark already in
  all)/alias/usage/compose).

## task-035: health monitor held the procd lock fd (1000) → reload/restart hang

- ROOT CAUSE (hardware-confirmed to the exact process): `start_sing_box_monitor`
  launched the long-lived monitor with a bare `monitor_sing_box &`. procd runs
  every init action while holding its exclusive service lock on **fd 1000**
  (`/tmp/lock/procd_<name>.lock`) — confirmed canonical (openwrt/packages#12807:
  "fd 1000 holds the exclusive concurrency lock for init script execution").
  The bare `&` inherits ALL open fds incl. 1000, so the never-exiting monitor
  held the procd lock FOREVER → the NEXT `reload`/`restart` blocked on
  `flock 1000` indefinitely → settings never re-applied (dashboard frozen). The
  1st reload "worked" only because it WAS the lock holder.
- FIX (chosen: hidden `__monitor` subcommand + setsid + fd-close, most robust):
  `start_sing_box_monitor` now launches
  `setsid /bin/sh -c 'exec 1000>&- 2>/dev/null; exec /usr/bin/netshift __monitor'
  </dev/null >/dev/null 2>&1 &`. Three independent detachments: (1) `setsid` →
  own session, out of procd's process group; (2) `exec 1000>&-` closes the
  inherited lock fd in the child BEFORE the re-exec (exec does NOT close
  non-CLOEXEC fds — that IS the bug — so the close is mandatory; harmless no-op
  on the plain `start`/boot path where fd 1000 isn't open); (3)
  `</dev/null >/dev/null 2>&1` drops procd's inherited stdout/stderr pipes. The
  hidden `__monitor) monitor_sing_box ;;` dispatch case (bottom of bin/netshift,
  NOT in help) runs the UNCHANGED detection/recovery loop.
- WHY re-exec instead of just `{ exec 1000>&-; monitor_sing_box; } &`: re-exec
  via setsid is more thorough (new session + fresh process, drops EVERYTHING
  inherited), and is robust even if procd ever changes the lock fd number — but
  I still close 1000 explicitly as the belt. The detached monitor's recovery
  path (`stop_main`/`start_main`) is safe: `start_main` does NOT spawn a monitor
  (only `start()` does, via `start_sing_box_monitor`), so a recovery restart
  can't re-introduce a lock-held child; and the monitor itself has no fd 1000.
- PID TRACKING through setsid/exec: the launcher can't reliably capture the
  final pid of the setsid→sh→exec chain, so the monitor writes its OWN `$$` to
  the pidfile at the TOP of `monitor_sing_box` (`echo $$ > "$MONITOR_PIDFILE"`).
  `start_sing_box_monitor` then waits briefly (`while [ ! -s pidfile ]`, ~2s cap,
  `sleep 0.1 2>/dev/null || sleep 1` busybox-safe) for it to appear, for
  diagnostics. `stop()` reads the pidfile + `kill` — unchanged behaviour, still
  kills exactly the detached monitor. Single-instance pidfile guard at the top
  of `start_sing_box_monitor` (kill-prior / skip-if-alive) is UNCHANGED → still
  exactly one monitor after N reloads. `shutdown_correctly` honoring + pidfile
  cleanup on monitor exit (`rm -f "$MONITOR_PIDFILE"`) unchanged.
- New constant `MONITOR_PIDFILE="/var/run/netshift_monitor.pid"` (constants.sh,
  Common) replaced the 4 inlined literals (start/stop/monitor + launcher) — was
  the one repeated magic path. NO sacred value / nft / default_mark touched.
- KNOWN RELATED RISK (out of task-035 scope, flagged): the deferred subscription
  retry worker (`start_subscription_startup_retry_worker`) ALSO backgrounds a
  `while true` loop with a bare `( ... ) &` and so inherits fd 1000 the same
  way. It usually exits after the first successful `subscription_update`
  (self-restarts), so it's not the confirmed culprit, but on a box where the sub
  stays unreachable it could hold the lock too. Candidate for the same setsid
  detach in a follow-up.
- TEST: new top-level `test_monitor_fd_hygiene` (alias `monfd`, 4 asserts),
  placed after `test_section_isolation`. awk-extracts the SHIPPED
  `start_sing_box_monitor` verbatim, re-pins `MONITOR_PIDFILE`, installs a stub
  `/usr/bin/netshift` (back-up/restore the real one) whose `__monitor` writes
  `$$` + sleep-loops. Driver opens fd 1000 on a sentinel lock file + `flock -x`
  it (exactly like procd), runs the launcher, then asserts: (1) monitor alive +
  pidfile correct; (2) NO `/proc/<pid>/fd/*` symlink points at the sentinel lock
  (THE direct fd-hygiene proof — spec test #1); (3) fd 1000 specifically isn't
  the lock; (4) repeated-reload-no-hang proxy — CLOSE the parent's fd 1000
  (modeling procd ENDING the action; must NOT `flock -u`, which releases the
  per-OFD lock for all and masks the bug) then a separate subshell's
  `flock -n -x` on the same file must acquire immediately. PROVEN discriminator:
  reverting to `/usr/bin/netshift __monitor &` makes asserts 2/3/4 FAIL (1/3),
  fix → 4/0. Parsed in the CURRENT shell (`while read < "$out"`, no pipe) so
  counts are EXACT. Registered all 5 points (all)/case alias/usage/compose).
- FLOCK SEMANTICS LANDMINE: an advisory flock lives on the open-file-description
  (OFD), not the fd. A child that inherits the fd shares the SAME OFD, so the
  lock persists until ALL fds to that OFD close. `flock -u` on ANY of them
  releases it for everyone — so a test must model procd by CLOSING the fd, never
  by `flock -u`, or it can't tell the bug from the fix. busybox `flock` supports
  both `flock -sxun FD` and `flock FILE -c CMD`; I used the FD form in a subshell
  (`( exec 9>file; flock -n -x 9 )`) for portability.
- GATES: shellcheck -S error clean (bin/netshift + lib/*.sh + install.sh +
  tests/entrypoint.sh). `smoke-tests all` = 152 passed / 0 failed (148 baseline
  + 4 new monfd). Pre-existing `rh-case1/2/6:FAIL` red marks persist (task-031
  piped-while quirk; suite still EXIT=0). Verified in the NET_ADMIN smoke
  container that the detached monitor child holds NO sentinel/lock fd.

## task-036: monitor PROCESS LEAK after the task-035 detach (2-3 live monitors)

- ROOT CAUSE (hardware-confirmed): the task-035 setsid detach is correct, but it
  introduced a leak. Each monitor self-writes its OWN `$$` to MONITOR_PIDFILE at
  the top of `monitor_sing_box`, so the pidfile only ever remembers the LATEST
  monitor. `start_sing_box_monitor`'s old replace-guard only `return 0`'d if the
  pidfile pid was alive (else `rm`'d it) — it NEVER killed the old monitor.
  reload = `stop(); start()`; `stop()` kills only the pidfile pid. A monitor from
  a PRIOR reload whose pid was overwritten in the pidfile is invisible to stop()
  → and because it's detached (setsid → own session, reparented to init) it
  survives forever → monitors accumulate (pid=X ppid=1 orphan AND newer one both
  alive; pidfile names only one).
- FIX (chosen Option 1, robust kill-all by unique marker): new private helper
  `_kill_stale_sing_box_monitors` kills ALL detached monitors via
  `pgrep -f "/usr/bin/netshift __monitor"` (the hidden `__monitor` subcommand is
  the unique marker — re-exec'd argv is `/bin/ash /usr/bin/netshift __monitor`;
  matches ONLY the monitor, never the main netshift process). EXCLUDES `$$` and
  `${PPID:-0}` (numeric-guarded), so it can never self-kill. Wired into TWO
  paths: (1) `start_sing_box_monitor` runs it + `rm -f pidfile` then ALWAYS
  spawns one fresh monitor (replaced the old return-0-if-alive guard — a stale
  monitor from a prior config is not a valid substitute for one bound to the new
  sing-box run); (2) `stop()` runs it after the pidfile-pid kill so a clean stop
  leaves ZERO monitors. Result: exactly ONE monitor after N reloads/restarts.
- SELF-KILL SAFETY during recovery: `monitor_sing_box` recovery calls
  `stop_main`/`start_main` — NOT `stop()`/`start_sing_box_monitor` — so the
  kill-all helper is NEVER reached from inside a running monitor. The `$$`/`$PPID`
  exclusion is the belt-and-suspenders guarantee regardless.
- KEEP INTACT (re-verified by smoke): task-035 detach (setsid + `exec 1000>&-` +
  hidden `__monitor` + monitor self-writes pid), monitor holds NO lock fd
  (re-proven on the RESPAWNED monitor too), reload no-hang, recovery via
  stop_main/start_main. No sacred value / nft / default_mark touched.
- `pgrep -f` IS available on busybox target (already used at bin:3974
  `pgrep -f "sing-box"` in get_system_info, and bin:1062 `pgrep "sing-box"`); I
  still added a `ps w | grep | grep -v grep | awk` fallback guarded by
  `command -v pgrep`. Capture pgrep output into a var, iterate with a `for`
  (word-split is fine — pids are numeric), not a pipe, so the `killed` counter
  survives.
- TEST: extended `test_monitor_fd_hygiene` (monfd) with 3 new asserts (now 7
  total, no new registration — monfd already in all)). awk-extracts BOTH the
  shipped `_kill_stale_sing_box_monitors` AND `start_sing_box_monitor`. Models
  the REAL leak precondition before the 2nd launch: monitor A still alive but
  pidfile pointed at a DEAD pid (`echo 999999 > pidfile`) — exactly the
  overwritten-then-cleared pidfile state. New asserts: `monfd-prior-monitor-killed`
  (old pid dead), `monfd-exactly-one-monitor` (pgrep -f count == 1, into file +
  counted `while read`, no pipe), `monfd-respawn-no-lock-fd` (the NEW monitor
  also holds no sentinel fd). PROVEN DISCRIMINATOR: reverting to the old guard
  (return-0-if-alive + neutered selector) makes the buggy code show "found 2 live
  monitors" + "old pid still alive" (2/7 FAIL); fix → 7/0. The naive
  "launch twice with the SAME live pidfile" does NOT discriminate (old guard
  `return 0`s, never respawns, so count stays 1) — you MUST simulate the lost
  pidfile pointer to expose the leak.
- GATES: shellcheck -S error clean (bin + lib/*.sh + install.sh +
  tests/entrypoint.sh). `smoke-tests all` = 155 passed / 0 failed (152 task-035
  baseline + 3 new monfd asserts). Pre-existing `rh-case1/2/6:FAIL` red marks
  persist (task-031 piped-while quirk; suite EXIT=0).

## task-038: graceful-skip unsupported scheme (fatal→warn) + splithttp→xhttp alias

- DEFECT 1: `sing_box_cf_add_proxy_outbound`'s `*)` default arm did `log fatal;
  exit 1`. That dispatcher is SHARED by url(single)/selector-loop/urltest-loop
  callers (bin/netshift) + the subscription fallback parser
  (`normalize_subscription_to_singbox` in helpers.sh). One unsupported link
  (tuic/wireguard/anytls/shadowtls/http/typo) in a urltest/selector list aborted
  the WHOLE config — and worse, `exit 1` inside the caller's `config=$(facade
  ...)` only exits the SUBSHELL, so config became EMPTY (the task-033 wipe class),
  not a clean abort.
- FIX: `*)` arm now `log "...skipping..." "warn"; echo "$config"; return 1`
  (config echoed UNCHANGED, never empty; non-zero = "skipped"). Supported arms
  keep their genuine `exit 1` paths (ss base64 fail, vmess decode fail) — those
  STILL only exit the subshell, which the callers now treat as skip too (defense:
  see the `[ -n "$_new_config" ]` guard below). Did NOT touch supported parsing.
- SKIP CONTRACT (callers): non-zero return + unchanged echo. Caller pattern is
  `if _new_config="$(facade ...)" && [ -n "$_new_config" ]; then config="$_new_config"; <use it> else <skip>`.
  The `[ -n ]` guard is belt-and-suspenders so a genuine supported-arm `exit 1`
  (empty echo) ALSO degrades to skip rather than wiping `config`.
- CALLER AUDIT (all 4):
  * url single (bin ~2151): on skip → `echolog ... error` + `mark_section_outbound_unavailable`
    so the route emits a REJECT rule (section degrades to unavailable). No exit.
  * selector loop (bin ~2182): add the member tag ONLY on facade success → no
    dangling selector member. All-skipped → empty `outbound_tags` → mark
    unavailable, don't build the selector.
  * urltest loop (bin ~2228): same as selector (urltest+selector members clean).
  * subscription normalize (helpers ~1489): ALREADY graceful — pre-filters
    schemes to `vless|trojan|ss|hysteria2|hy2|socks*` (the `*)` arm is never even
    reached there) AND tolerates non-zero via `|| { continue }` + JSON/count
    guards. No change needed; my facade change is compatible.
- SINGLE-URL DEGRADE MECHANISM: new tiny helper `mark_section_outbound_unavailable`
  (next to `mark_subscription_outbound_unavailable`) just appends the section to
  `SUBSCRIPTION_UNAVAILABLE_SECTIONS` (the SAME flag `subscription_outbound_is_unavailable`
  reads), so `sing_box_configure_route` emits `sing_box_cm_add_reject_route_rule`
  for it (bin ~2818). Does NOT touch any per-URL subscription rejected-hash cache
  (that is subscription-only). Reuses the existing unavailable-section plumbing.
- PROVEN: `sing-box check` does NOT reject a route rule whose `outbound` points
  at a MISSING outbound, NOR a selector/urltest with a missing member (both rc=0
  in-container). So a dangling tag wouldn't fail `check` — but it would blackhole
  traffic at runtime, hence we still keep selector members clean + mark unavailable.
- DEFECT 2 (splithttp = pre-rename xhttp): facade `_add_outbound_transport` now
  matches `xhttp | splithttp` (same `sing_box_cm_set_xhttp_transport_for_outbound`,
  same `is_sing_box_extended` gate); `_add_outbound_security` ALPN-default branch
  also accepts `type=splithttp`. `xray_json_to_uri_lines` (helpers.sh): normalize
  `$net` `splithttp`→`xhttp` and read settings from `($ss.xhttpSettings //
  $ss.splithttpSettings // {})`. Emitted URI always carries the modern `type=xhttp`.
- **JQ-IN-SHELL-STRING APOSTROPHE LANDMINE (cost a debug cycle):** an apostrophe
  in a jq COMMENT inside a `jq -er '...'` single-quoted shell string CLOSES the
  shell string. I wrote `# ... the facade's xhttp branch ...` and shellcheck
  reported SC1073/SC1056/SC1072 brace errors on the FUNCTION line, not the
  comment — because everything after the `'` was parsed as shell. It would ALSO
  break the real jq at runtime. NEVER put `'` in a jq comment (or any char that
  closes the surrounding shell quote). Rewrote the comments apostrophe-free.
- **`((` at a jq pipe-element start trips shellcheck** (reads it as arithmetic
  `$((...))` context → SC1056/1072): `| (($x // "y") | if ...)` failed; split it
  into `| ($x // "y") as $tmp | (if $tmp ...) as $net` (single leading `(`).
- TEST: new top-level `test_unsupported_skip` (alias `unsupported`, after
  test_monitor_fd_hygiene). awk-extracts the SHIPPED `configure_outbound_handler`
  + `mark_section_outbound_unavailable` verbatim, sources real
  facade/manager/helpers/constants (symlink to /usr/lib/netshift), table-driven
  `config_get` stub via `US_<section>_<opt>` vars, log stub recording level|msg.
  Cases: (1) urltest + (1b) selector mix supported(vless/hysteria2)+unsupported
  (tuic/wireguard/garbage) → no-abort, supported present, unsupported absent,
  members clean, warning logged, config not wiped, live `sing-box check`; (2)
  single-URL only-tuic → no crash, no outbound, direct-out survives, section
  marked unavailable, error logged; (3a) vless `?type=splithttp` → transport.type
  xhttp + path + extended-gate-off respected; (3b) Xray-JSON
  network:"splithttp"/splithttpSettings → URI carries `type=xhttp`,`path=/xj`, no
  literal `splithttp`. The xhttp `sing-box check` SKIPs on the container's STOCK
  core (rejects xhttp) — assert-only-when-accepted, else SKIP. Registered all 5
  points (all)/alias/usage/docker-compose comment).
- GATES: shellcheck -S error clean (install.sh + bin + lib/*.sh + tests). All
  files UTF-8 intact (syntax test mojibake guard green). `smoke-tests all` = 155
  passed / 0 failed (same suite total — the new test's per-line passes run in the
  documented piped-while subshell, so the ✓ marks are truth: 23 green + 1 SKIP).
  task-037's hysteria2 marks (fb-caseL/N/O) all still green. Pre-existing
  `rh-case1/2/6:FAIL` red marks persist (task-031 quirk; suite EXIT=0). No sacred
  value/port/mark/path/ACL changed.

## task-039: `component_action subscription clear_cache` (wipe caches + redownload)

- NEW worker `subscription_clear_cache_and_redownload` in **bin/netshift** (placed
  right after `subscription_update`, where the cache-path builders +
  `SUBSCRIPTION_CACHE_FOLDER` + `subscription_update` are in scope). Wired into
  `updater.sh component_action()` via a new arm `subscription:clear_cache)
  subscription_clear_cache_and_redownload ;;` beside sing_box:*/netshift:*. Works
  via BOTH sync `component_action subscription clear_cache` AND async
  `component_action_async subscription clear_cache`→job_id +
  `component_action_status <job_id>` — NO new plumbing. Help line added in
  show_help. NO ACL change (component_action is wholesale exec-allowed).
- **Cross-package reachability proof**: updater.sh is SOURCED by bin/netshift, and
  the async fork does `"$0" component_action "$c" "$a"` (re-execs bin/netshift), so
  a worker DEFINED in bin/netshift is always in scope when the `component_action`
  arm (FROM updater.sh) dispatches it. A worker can live in either file as long as
  it's reachable at dispatch time.
- **Guarded full-reset delete (the only new logic)**: `[ -n
  "$SUBSCRIPTION_CACHE_FOLDER" ] && [ -d "$SUBSCRIPTION_CACHE_FOLDER" ]` BEFORE any
  glob, then a `for cache_file in "$SUBSCRIPTION_CACHE_FOLDER"/*; do [ -e ] || continue;
  rm -f ...; done` (counts removed files, logs the count at info). The two guards
  make a mistyped/empty constant → `rm -f /*` IMPOSSIBLE. Only ever removes dir
  CONTENTS, never `rm -rf` the dir. No error on empty/missing dir (the `[ -e ]`
  continue handles the literal-glob-when-empty case). Deleting `.json` defeats the
  unchanged guard, deleting `.rejected` defeats the rejected-hash veto → genuine
  full re-download.
- **Reused subscription_update VERBATIM** for redownload+revalidate+restart — the
  ONLY new code is the deletion + the JSON wrapper. Echo+return discipline (NEVER
  `exit` — runs inside the async fork; an exit would kill it before the finished
  state is written, same rule as updates_*): success → `{"success":true,
  "message":"..."}` return 0; redownload fail → `{"success":false,"message":"..."}`
  return $rc. No subscription sections configured → graceful
  `{"success":true,"message":"No subscriptions configured;..."}` return 0 (detected
  via a `config_foreach` callback identical to subscription_update's own
  has_subscription probe). Action string is EXACTLY `subscription` / `clear_cache`
  (frontend task-040 must match).
- TEST: extended `test_subscription` (NO registration change — already in all)) with
  a `Clear Subscription Cache` driver block (11 cc-case assertions). awk-extracts
  the SHIPPED worker VERBATIM + the SHIPPED `component_action` from updater.sh,
  stubs `subscription_update` to a no-op (records call count + controllable rc),
  table-driven `config_foreach`/`config_get` via `CC_SECTIONS`
  ("sec|ct|pct" rows). Cases: 1 ≥2-feeds-all-deleted+dir-preserved+success:true+
  redownload-invoked, 2 empty-dir-graceful, 2b missing-dir-graceful, 3 no-subs→
  success+no-redownload+files-cleared, 4 redownload-fail→success:false+message,
  5 guard scoped to cache dir (unrelated sentinel survives) + empty-constant no-op,
  6 router `component_action subscription clear_cache` dispatches to the worker.
- **CAPTURE LANDMINE (bit me once, the documented `$()`-subshell variant)**:
  `cc_json="$(worker)"` runs the worker in a SUBSHELL, so a stub's call-counter
  (`SUB_UPDATE_CALLS`) or `ROUTER_HIT` flag mutation is TRAPPED and never reaches
  the parent → the assertion reads the parent's stale reset value (false pass/fail).
  When a test asserts on a side-effect VARIABLE set inside the worker, run it
  WITHOUT `$()`: `worker > "$out"; json="$(cat "$out")"`. Cases that assert only on
  the echoed JSON can use `$()` safely. CASE 6's `component_action()` is awk-extracted
  function-only — its other arms reference undefined `updates_*` fns but those are
  just `case` branches (never executed), so no need to source the whole updater.sh.
- GATES: shellcheck -S error clean (bin/netshift + updater.sh + lib/*.sh + install.sh).
  `smoke-tests all` = 166 passed / 0 failed (155 baseline + 11 new cc-case, suite
  total reflects them as the driver parses in the CURRENT shell `while read <
  "$out"` so counts are EXACT). Pre-existing `rh-case1/2/6:FAIL` red marks persist
  (task-031 piped-while quirk; suite EXIT=0). No sacred value/port/mark/path/ACL/
  frontend/async-machinery/download-guard change.

## task-041: self-update verify-after-install (opkg silent no-op fix)

- **Root cause (proven on router):** opkg returns rc=0 for "Not downgrading"/
  "already installed"/"up to date". A legacy v-prefixed build (`v0.8.6-r1`) sorts
  ABOVE the no-v target (`0.8.7-r1`) in opkg's dpkg-style compare, so a plain
  `opkg install` refuses AND returns rc=0. The self-update worker trusted rc and
  emitted `{"success":true}` while NOTHING installed. **opkg install rc is NOT a
  reliable success signal** — the only robust check is to RE-READ the installed
  version after the call.
- Fix #1 (`updates_pkg_install_file` opkg branch): `opkg install
  --force-downgrade --force-reinstall "$pkg_file"`. `--force-downgrade` lands the
  v→no-v transition; `--force-reinstall` covers the same-exact-version no-op. apk
  branch unchanged (`apk add --allow-untrusted`; apk overwrites by default).
- Fix #2 new helper `updates_pkg_installed_version <pkg>` (mirrors
  `updates_pkg_is_installed`/`_candidate_version` but reads INSTALLED not feed):
  opkg `list-installed | grep "^<pkg> " | head -n1 | awk -F' - ' '{print $2}'`;
  apk `list --installed <pkg> | awk '{print $1}' | head -n1` then strip `<pkg>-`
  prefix via `${line#"$pkg"-}`. grep/awk only, NO Oniguruma.
- Fix #3 verify-after-install belt in `_updates_self_update_netshift_core` (after
  the install loop, BEFORE the defensive restore + success cleanup): re-read the
  CORE installed version, normalize with the SAME rules the version-decision uses
  (`${x#v}` then `${x%%-*}` to drop `-rN`), and gate on
  `[ "$inst_semver" != "$latest_semver" ] && ! is_min_package_version
  "$inst_semver" "$latest_semver"` (i.e. fail unless installed == target OR
  installed >= target). On fail: `_updates_self_update_restore_config
  "$backup_made"` + `rm -rf "$UPDATES_NETSHIFT_DOWNLOAD_DIR"` + `updates_log ...
  "error"` + `echo '{"success":false,"message":"NetShift core package did not
  upgrade ...; configuration preserved"}'` + **`return 1` (NEVER exit** — async
  worker; exit skips the wrapper's `updates_restore_after_swap` epilogue + the
  finished-job-state write). Only a verified change reaches the existing success
  JSON. Gates the CORE pkg only (luci/ru stay non-critical).
- `is_min_package_version current required` returns 0 when `current >= required`
  (it's a `sort -V | head -1 == required` test) — so call it as
  `is_min_package_version "$installed" "$target"`.
- All new vars declared at the TOP of the core fn (`core_installed
  core_installed_semver latest_semver`) — shellcheck `-S error` clean.
- **Smoke (test_self_update_netshift, alias `selfupdate`, no new top-level test):**
  extended the fake opkg stub: `install` arm now skips leading `--*` flags
  (`while ...; case --*) shift;; *) break;; esac`) so `$1` is the file path even
  with the new force flags; on a REAL success it rewrites the `netshift -` line in
  `$SU_INSTALLED_LIST` to `$SU_TARGET_INSTALLED_VER` (so verify passes) UNLESS
  `$SU_NOOP` is set (then list keeps the OLD version → simulates "Not
  downgrading"). luci-* files excluded from the rewrite via nested case. Each
  scenario now seeds `installed.list` with `netshift - 0.8.0-r1` (the install arm
  mutates it, so reset per-scenario). New Scenario 6 (`SU_NOOP=1`, all other
  markers ok): asserts `selfupdate-noop-detected-successfalse` (success:false),
  `-noop-install-attempted`, `-noop-config-intact`, `-noop-download-dir-cleaned`.
  Happy path Scenario 3 still `success:true version 0.8.1` (verify passes because
  the stub reports the target post-install). SELF-PROVED the guard: temporarily
  prefixed the verify `if` with `false &&` → `selfupdate-noop-detected-successfalse`
  FAILED (worker falsely reported success on the no-op), then restored → passes.
- shellcheck -S error clean (bin+libs+install.sh); `smoke-tests all` = 170 passed
  / 0 failed (166 baseline + 4 new no-op assertions; selfupdate category 13→17).
  No constants.sh / frontend / async-machinery / version-decision(:1679) /
  sing-box-install-path / sacred-value change. apk path: the same verify belt
  covers apk's equal-version no-overwrite quirk (reasoned; opkg covered in smoke).

## task-043 — versioned Xray-JSON probe User-Agents (constants-only)

- Finding (abstract, no identifiers): some panels gate their Xray-JSON branch on
  a `<client>/<version>` UA SHAPE. A bare/version-less UA can be rejected (server
  502); a VERSIONED UA of the same client yields the wanted Xray-JSON array body
  (the multi-profile format `xray_json_to_uri_lines` parses, carrying
  xhttp/hysteria2). Fix = make the probe send versioned UAs first.
- `SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES` (constants.sh) is the ordered set
  probed FIRST in `xray` format-preference mode by
  `build_subscription_user_agent_candidates` (helpers.sh:765-771;
  order = XRAY_CANDIDATES → default(singbox/<ver>) → cached-winner → main
  whitelist, deduped). Changed it from bare `"v2rayN Happ"` to versioned
  `"Happ/1.0.0 v2rayN/7.0.0 v2rayNG/1.9.0"` (versioned client first). The
  separate auto-mode `SUBSCRIPTION_USER_AGENT_CANDIDATES` (still has bare names)
  and the request headers in `_wget_subscription_request` were untouched — only
  the UA VALUE decides the 502-vs-200 outcome, no header change needed.
- Coupled smoke test: `fb-caseI-xraypref-*` (tests/entrypoint.sh CASE I, run via
  the `subscription` category) hardcoded the old bare literals. Rewrote them to
  DERIVE the expected first/second/third candidates from
  `$SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES` (sourced in the CASE-I subshell via
  `set -- $SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES`) so a future version bump
  won't rot the test. Added one generic guard `fb-caseI-xraypref-first-versioned`
  (`case "$first" in */*)`) so we never regress to a bare UA. The auto-mode
  `fb-caseI-auto-has-v2rayN` assertion is unrelated (tests the auto whitelist).
- shellcheck -S error clean (entrypoint.sh is OUT of the lint scope — only
  bin/lib/install.sh). `smoke-tests all` = 170 passed / 0 failed (same total
  before+after; the standalone `subscription` category went 86→87 from the +1
  guard, but the aggregate `all` "Results:" counter reported 170 either way — a
  harness counting quirk, not a regression; all four `fb-caseI-xraypref-*` lines
  print :OK in both runs). No ports/marks/paths/schema touched; runtime contract
  intact.

## task-046 — gzip subscription body decompress + NUL guard (issue #13)

- Some panels return a gzip-compressed HTTP body unconditionally; busybox wget
  does NOT transparently decompress and NetShift sends no Accept-Encoding, so the
  raw bytes are binary and validate/normalize choke ("No subscription User-Agent
  candidate produced valid outbounds").
- Added two best-effort helpers to `helpers.sh` (next to `convert_crlf_to_lf`):
  - `maybe_gunzip_subscription_file <f>`: attempt-based detection (no
    od/hexdump/xxd — none on device). `gzip -dc` (busybox built-in) into a
    mktemp; accept ONLY if rc=0 AND result non-empty AND NUL-free, then `mv` into
    place (else `rm`). `gzip -dc` on plain text returns rc!=0 cleanly, so plain
    text is left byte-for-byte untouched — never corrupts text. Always returns 0.
  - `subscription_body_is_binary <f>`: returns 0 (true) if file has a NUL byte.
    Busybox-safe, no od: compare `wc -c < f` to `tr -d '\000' < f | wc -c` (differ
    ⇒ had NUL). All vars local.
- Wired in `bin/netshift` `download_subscription_into_cache` right after a
  successful `download_subscription` (now ~:590-591), BEFORE
  `validate_subscription_file`: call `maybe_gunzip_subscription_file`, then if
  `subscription_body_is_binary` log a warn and `continue` (inside the per-UA
  `while read` loop → falls to next UA, same flow as a validation failure). The
  file_size/debug log stays AFTER so the logged size reflects the decompressed
  body. mv/cache-persist below unchanged.
- NO Accept-Encoding/wget change, NO Makefile DEPENDS change (gzip/gunzip/zcat
  are busybox built-ins), NO schema/ports/marks/frontend. zstd/unzstd are NOT on
  device — gzip-only by design; deflate/zstd are a future task if panels send
  them.
- Smoke: extended the `test_subscription` fb harness (sources helpers via the
  facade) with synthetic-only fixtures: caseP gzip→text (cmp byte-equal),
  text-passthrough (cmp unchanged), gzip→validate (validate_subscription_file
  passes); caseQ `printf 'abc\000def'`→binary true, plain text→false. The smoke
  container has gzip (tests/Dockerfile apk add gzip). No new test_* fn — folded
  into existing test_subscription, so no main()/case/usage registration needed.
- Gates: shellcheck -S error clean on bin + all libs + install.sh; `smoke-tests
  all` 174 passed / 0 failed (aggregate counter folds the 5 new tokens into the
  test_subscription header group — count unchanged, the 5 fb-caseP/Q :OK lines
  print explicitly in the `subscription` run).

## task-047 — latest-tag jq parse (false "Outdated" fix)

- `updates_netshift_latest_tag` (`updater.sh:~1635`) used
  `grep '"tag_name":' | head -n1 | cut -d'"' -f4`. That ONLY works on
  pretty-printed JSON. On MINIFIED GitHub JSON (whole object on one line, `"url"`
  before `"tag_name"`), grep matches the whole line and `cut -f4` returns the
  FIRST key's value = the release `"url"` → false "outdated" + self-update
  downloads a garbage "version". Fix: `jq -r '.tag_name // empty'`
  (format-independent; `// empty` → empty on rate-limit/error objects; no
  Oniguruma). jq is a hard dep (used 23× in updater.sh) and the sibling
  sing-box-extended path already used `.tag_name`.
- LESSON (whitespace-fragile grep|cut on JSON): never field-position-`cut` JSON
  that may be minified. Prefer jq when it's already a dep.
- New smoke test `test_netshift_latest_tag` (token `latesttag`): driver sources
  updater.sh, stubs ONLY the network boundary `updates_http_get_once` (NOT the
  parse fn), runs the REAL `updates_netshift_latest_tag`. 4 cases: minified→tag
  (regression guard), pretty→tag, rate-limit→empty+nonzero, e2e via
  `updates_check_netshift`→status "latest". Registered in main() all)+case+usage
  +docker-compose.yml comment.
- GOTCHA: under harness `set -e`, a stub-driver `ash "$drv"` that returns
  non-zero (the rate-limit case) aborts the whole suite — guard rc capture with
  `ash ... && printf 0 >rc || printf $? >rc`.
- Guard self-proven: restoring the old grep|cut line made
  `latesttag-minified-returns-tag-not-url` FAIL (returned the .../releases/<id>
  url), then restored jq. Gates: shellcheck -S error clean (bin + libs +
  install.sh); `smoke-tests all` 174→178 passed / 0 failed (+4 latesttag).

## task-048: scalar `option subscription_url` read-fallback + option->list migration

- Root cause (PROVEN on hardware, Cudy WR3000E / OWRt 25.12.4 / NetShift 0.8.9):
  a section storing `option subscription_url '<url>'` (legacy / CLI /
  podkop-migrated configs) made `get_subscription_urls_for_section`
  (`bin/netshift`) return EMPTY → `has_outbound_section` false → "Outbound
  section not found. Aborted." → sing-box never starts → whole chain down (no nft
  table, FakeIP 127.0.0.42:53 refused). `config_list_foreach` iterates ONLY UCI
  `list` values; over a scalar `option` it iterates NOTHING. `config_get` reads
  the scalar. Regression from task-022 (multi-URL feature made subscription_url a
  list / form.DynamicList); the task-022 memory note "a lone legacy option reads
  as a 1-element list — NO migration code" was the FALSE assumption that shipped
  the bug. EVERY subscription-URL reader funnels through this one helper.
- Fix 1 (load-bearing, single source): in `get_subscription_urls_for_section`,
  AFTER the `config_list_foreach`, if `SUBSCRIPTION_URLS_COLLECTED` is still
  empty, `config_get scalar_url "$section" "subscription_url"` and (if non-empty)
  `_collect_subscription_url_handler "$scalar_url"` (reuse the handler so
  dedup/format stays identical). All new vars `local`. Must stand alone on
  read-only fs / when migration is skipped. Corrected the false comment at
  `section_has_configured_outbound` (subscription branch) and the collector
  header.
- Fix 2 (hygiene, idempotent): `migrate_legacy_subscription_url_option` +
  `_migrate_legacy_subscription_url_option_handler` (config_foreach callback).
  Detects the broken shape robustly: LIST read empty AND scalar config_get
  non-empty (an already-correct list is never touched). Rewrites via
  `uci -q delete netshift.<sec>.subscription_url` then the `uci_add_list netshift
  "$sec" subscription_url "$url"` SHELL HELPER (from /lib/functions.sh) — NOT the
  `uci add_list "key=value"` CLI form, which splits on the first `=` and SILENTLY
  LOSES query-string URLs (`?token=abc&x=1`) [code-review BLOCKER B1, reproduced
  on hardware: CLI add_list rc=1, list empty, scalar already deleted => URL lost
  on disk]. On add_list FAILURE the else branch `uci_set`s the scalar back so a
  failed migration never leaves the section with NO url (and the flag stays 0 =>
  no commit => uncommitted in-memory delete never persists; on-disk URL survives).
  sets a module-level flag `SUBSCRIPTION_URL_OPTION_MIGRATED`; a SINGLE `uci commit netshift` +
  `config_load "$NETSHIFT_CONFIG"` only if anything changed (mirrors the
  :956/:1099 commit+reload). NEVER exits — uci failures log `warn` and continue
  (the read-fallback covers correctness). Invoked ONCE at the TOP of `start_main`
  BEFORE `check_requirements` (which reads URLs via has_outbound_section), AFTER
  the file-scope `config_load`.
- Smoke landmine confirmed (again): the multi-url `test_subscription` harness
  STUBS `config_list_foreach` (feeds MU_URLS) and does NOT touch real UCI / does
  NOT stub `config_get` — so it can NEVER catch this bug (it bypasses the broken
  primitive). The regression guard MUST be a REAL-UCI test that `config_load`s a
  fixture and runs the SHIPPED (awk-extracted) functions.
- New top-level smoke test `test_sub_url_option` (alias `suburlopt`). 12 tokens:
  `suburlopt:scalar-read` (regression guard — empty before fix),
  `:scalar-hasoutbound`, `:list-read` (no-regression), `:migrate-flag`,
  `:migrate-value`, `:migrate-islist`, `:migrate-idempotent`,
  `:migrate-idempotent-value`, PLUS the `=`-URL [B1] guards
  `:migrate-equrl-preserved`, `:migrate-equrl-islist`, `:migrate-equrl-single`
  (asserts exactly 1 list element), `:migrate-idempotent-equrl` — fixture URL
  `https://example.com/sub?token=abc&x=1`. The driver output is parsed in the
  CURRENT shell (temp file + `while read < "$out"`, NO pipe) so the tokens
  ACTUALLY GATE CI (fixed the harness-wide piped-while counter-quirk for this
  test). Migration is tested against a throwaway
  `/etc/config/netshift` (the function hardcodes the `netshift` config name) with
  NETSHIFT_CONFIG=netshift; the caller backs up + restores any real one. Skips
  cleanly if /lib/functions.sh or uci unavailable. Registered in all)+case alias+
  "Available:" usage line + docker-compose.yml comment. Synthetic
  `https://example.com/sub` ONLY (operator privacy rule: a user dump leaked a
  real URL — never write a real subscription URL/host/id anywhere).
- Self-prove DONE: removing the read-fallback block made `suburlopt:scalar-read`
  go empty (its `:OK` disappeared) and `suburlopt:scalar-hasoutbound:FAIL`
  appeared; restored and all tokens green again. Also self-proved [B1]: the old
  `key=value` CLI add_list made `:migrate-equrl-preserved` FAIL (URL lost);
  `uci_add_list` helper fixed it.
- Whole-chain verified in-container: `has_outbound_section` returns TRUE for an
  option-shaped config → requirements gate passes → config gen + sing-box check
  proceed.
- PRE-EXISTING (NOT mine): `test_rejected_hash` rh-case1/2/6 fail on the BASELINE
  bin/netshift too (verified via git stash) — an existing container/env issue,
  unrelated to task-048.
- Gates: shellcheck -S error clean (bin + libs + install.sh); `smoke-tests all`
  178→190 passed / 0 failed (the +12 is the 12 `suburlopt` tokens, which now
  count because the test parses driver output in the CURRENT shell, NOT a pipe).
  NO sacred constant/port/mark/path changed; UCI schema only normalizes an
  existing key's representation (option→list, back-compat).
- code-review round 2: APPROVED WITH CONDITIONS — [B1]/[S1]/[M1] all resolved;
  the only condition was fixing THIS stale memory note (done).

## task-049: avoid api.github.com rate-limit via github.com redirect (curl)

- Anonymous api.github.com = 60 req/HOUR/IP; CGNAT/shared-IP/shared-VPN routers
  share that budget → frequent "API rate limit exceeded". LEVER (proven on HW):
  github.com/<repo>/releases/latest is the github.com FRONTEND (NOT the API) and
  302-redirects to /releases/tag/<tag>; releases/download/<tag>/<asset> 302s to
  the CDN. Neither hits the rate-limited API.
- New constants (constants.sh, repo slug ONLY here): NETSHIFT_REPO_RELEASES_LATEST_URL
  (.../releases/latest), NETSHIFT_REPO_RELEASES_DOWNLOAD_BASE (.../releases/download).
  Kept NETSHIFT_RELEASE_API_URL as the fallback.
- New STUBBABLE resolver `updates_github_resolve_redirect <url>` (updater.sh):
  `command -v curl || return 1; curl -sI -o /dev/null -w '%{redirect_url}'
  --connect-timeout 5 -m 15 -A 'netshift-updater' "$url"`. busybox wget is
  STRIPPED (no -S/header read) so tag extraction MUST be curl; curl is a hard dep.
- `updates_netshift_latest_tag` rewrite: PRIMARY resolve redirect, parse with
  `case "$redirect" in */releases/tag/*) tag="${redirect##*/releases/tag/}";
  case "$tag" in ''|*/*) tag="" ;; esac ;; *) tag="" ;; esac` (NO Oniguruma) —
  a trailing-slash redirect leaves a `/` in tag → rejected → empty → fallback.
  FALLBACK = the task-047 api.github.com + `jq -r '.tag_name // empty'` path,
  kept intact. Bare-tag/non-zero contract preserved (feeds updates_check_netshift
  + self-update worker).
- `updates_netshift_asset_filename <pkg> <tag> <ext>` single-source naming helper:
  i18n = `<pkg>-<tag>.<ext>` (no -r1); core/luci ipk = `<pkg>-<tag>-r1-all.ipk`,
  apk = `<pkg>-<tag>-r1.apk`. `_updates_self_update_download_assets` now resolves
  the tag and builds deterministic `$DOWNLOAD_BASE/<tag>/<filename>` URLs (core+luci
  always, i18n only if updates_pkg_is_installed), downloads via updates_http_get_once
  (follows the 302 to CDN), got_core=1 when core `-s "$dest"`. OLD api-JSON grep -o
  loop KEPT verbatim as the else branch when tag unresolved.
- install.sh: added RELEASES_LATEST_REDIRECT + RELEASES_DOWNLOAD_BASE literals
  (install.sh has its own REPO, not constants.sh). PRIMARY: curl -sI redirect →
  case/param-expansion tag → deterministic releases/download/<tag>/<asset> URLs
  (core+luci, RU i18n if pkg_is_installed). FALLBACK: existing API scrape + the
  "API rate limit" message kept intact. Factored the retry-download into a new
  `download_release_asset url filename` helper reused by both paths. name-prefix
  install loop semantics unchanged.
- GOTCHA: the EXISTING test_netshift_latest_tag driver had to ALSO stub
  `updates_github_resolve_redirect() { printf ''; }` — else the new primary would
  shell out to real curl in CI (network) and bypass the API path that test targets.
- EXTENDED PATH UNTOUCHED: updates_fetch_sing_box_extended_releases
  (releases?per_page=30) + updates_extended_release_* — they need the releases LIST
  (draft/prerelease/per-arch) a redirect can't give. Left on API + proxy-fallback.
- New smoke test `test_github_redirect_tag` (alias `ghredirect`, 6 tokens): stubs
  the resolver + updates_http_get_once, parses driver output in the CURRENT shell
  (gates). tag-from-redirect, tag-trailing-slash-rejected (→fallback empty),
  nonmatch-falls-back (login URL→API stub→tag), ratelimit-empty (curl-absent +
  rate-limit object→empty+nonzero), asset-ipk, asset-apk. Registered all 5 points.
- SELF-PROVEN: `if false && [ -n "$tag" ]` on the primary return made
  ghredirect:tag-from-redirect FAIL (5/1), restored→6/0.
- Gates: shellcheck -S error clean (bin+libs+install.sh); `smoke-tests all`
  190→196 passed / 0 failed (+6 ghredirect). NO sacred constant/port/mark/path/
  schema/frontend change.

## task-050: "Fastest" cross-group urltest of urltests (grouping-on default)

- New constant `SB_SUBSCRIPTION_FASTEST_GROUP_TAG="⚡ Fastest"` (constants.sh,
  sing-box Outbounds group, valid UTF-8) — single source for the top-level
  cross-group urltest tag. Per-group tags stay the inline literal
  `"$group_key Fastest"` (NOT a constant; the spec only added the cross-group
  one). Lightning glyph is deliberately distinct from a per-group `<flag>
  Fastest` so the auto choice is tellable apart in the dashboard.
- Grouped branch (bin/netshift `configure_outbound_handler`, subscription
  `group_mode != off`): after the per-group urltest loop fills
  `selector_outbounds_json` with ONLY group tags (before ungrouped is
  appended), capture `group_tags_json="$selector_outbounds_json"` +
  `group_tags_count=$(... | jq -r 'length')`. If `>= 2`:
  `fastest_tag=$(sing_box_get_unique_outbound_tag "$config" "$SB_..._TAG")`,
  add the nested urltest via `sing_box_cm_add_urltest_outbound "$config"
  "$fastest_tag" "$group_tags_json" <section's url/interval/tolerance>` (reuse
  the SECTION's urltest knobs — user-tunable, no hardcoded aggressive
  interval), prepend with `jq -acn --arg t --argjson rest '[$t] + $rest'`, and
  set `selector_default="$fastest_tag"`. EDGE: `==1` group → skip nest (lone
  group already IS fastest; default = `.[0]`); `==0` → no nest, default =
  first ungrouped. Never emits an empty-member urltest. New locals
  `group_tags_json group_tags_count fastest_tag`. Existing fatal+exit 1 guards
  intact. No Oniguruma.
- WHOLE-CHAIN proven: `sing-box check` ACCEPTS a urltest whose members are
  other urltest tags (nesting works) — asserted live in-container in the new
  test. Runtime-contract impact NONE (pure outbound-tree shape).
- FRONTEND: ZERO change needed. The subscription dashboard
  (`getDashboardSections.ts` `proxy_config_type === 'subscription'`) maps the
  LIVE `selector.value.all` and shows each member's `value.name` VERBATIM,
  EXCEPT it maps ONLY the legacy `${section}-urltest-out` code to `_('Fastest')`
  (`isLegacyFastest`). The new "⚡ Fastest" gets a DEDUPED synthetic tag (code =
  the tag, NOT `-urltest-out`), so it renders raw `⚡ Fastest` — same treatment
  as the per-group `🇷🇺 Fastest` tags. Urltests sort first → it leads the list
  and is selectable automatically. main.js untouched (correct).
- TEST `test_fastest_group` (alias `fastest`, after test_subscription; 6
  tokens). The grouped branch is INLINE shell (not a function), so the driver
  awk-extracts the WHOLE `if [ "$group_mode" != "off" ]; then ... else ... fi`
  region VERBATIM (from the `if`-opener through the off-branch's
  `"$urltest_tag" "true")"` line + the following `fi`; awk q-style: set
  `seen_else_end` on the off selector line, exit on the next `^\s*fi$`) and
  wraps it in a driver `_grouped_branch()` so the leading `if ...; then local`
  is valid. Sources real constants.sh + sing_box_config_manager.sh; awk-extracts
  `sing_box_get_unique_outbound_tag` + `sing_box_build_subscription_groups`
  verbatim; stubs `get_outbound_tag_by_section`/`log`. Synthetic flag tags
  built by codepoint (RU=flag(17,20), DE=flag(3,4)) + a `plain-node` ungrouped
  + shadowsocks/aes-256-gcm so `sing-box check` accepts. Asserts: (a) one
  top-level urltest tagged the constant whose outbounds == [ru,de] group tags;
  (b) selector default == fastest + outbounds == [fastest, ru, de,
  plain-node]; (c) live `sing-box check` passes WITH the nest; (d) groups==1 →
  no nested urltest, default = lone group; (e) off → flat 1 urltest, no
  fastest tag, default == `<section>-urltest-out`. Parsed in the CURRENT shell
  via per-run `ash "$work/runN.sh" > out.json` (each run sources the spliced
  driver) → tokens GATE. Registered all 5 points (all)/case alias/usage/compose
  comment).
- SPLICE PATTERN (reusable for inline-region extraction): write the driver with
  a placeholder line `EXTRACT_GROUPED`, then rebuild it as
  `{ sed '/MARK/q' drv | sed '$d'; cat region; sed -n '/MARK/,$p' drv | sed
  '1d'; } > drv.spliced; mv`. Replaces exactly the one placeholder line with the
  arbitrary-content region (no s/// escaping hazard).
- SELF-PROVED twice: (1) comment out the prepend line → only
  `fastest-selector-default-membership` FAILs; (2) change the guard to `-ge 99`
  (never nest) → BOTH `fastest-nested-urltest-members` AND
  `-selector-default-membership` FAIL. Restored → 6/0.
- Gates: shellcheck -S error clean (bin + libs + install.sh). `smoke-tests all`
  196→202 passed / 0 failed (+6 fastest, all counted — current-shell parse).
  Pre-existing `rh-case1/2/6:FAIL` red marks persist (documented task-031/048
  env quirk; suite EXIT=0). PRIVACY: synthetic codepoint-built flag tags only,
  no real subscription URL/host/id anywhere. NO sacred constant/port/mark/path/
  UCI-schema/frontend/main.js change.
