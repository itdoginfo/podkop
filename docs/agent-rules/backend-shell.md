# NetShift Backend — Shell Rules (AUTHORITATIVE)

> Scope: the backend package `netshift/files/usr/**` (POSIX `ash` + `jq`). Read alongside `project-core.md`. Every rule is grounded in the actual source — do not invent.

## 1. Stack

- **POSIX `ash`** (busybox), NOT bash. CLI dispatcher: `netshift/files/usr/bin/netshift`. Libraries: `netshift/files/usr/lib/*.sh`.
- **`jq`** generates and mutates the sing-box JSON config.
- **sing-box** is the routing engine; the backend only generates/validates its config and (re)starts the service.
- **nftables** tproxy provides the marking/redirect path (table `NetShiftTable`, family `inet`).
- **dnsmasq** integration points the router's DNS at sing-box (`server 127.0.0.42`).
- **UCI** holds configuration (`/etc/config/netshift`); **procd** init in `/etc/init.d/netshift`.

`/usr/bin/netshift` sources, in order: `/lib/functions.sh`, `/lib/config/uci.sh`, `/lib/functions/network.sh`, then `constants.sh`, `nft.sh`, `helpers.sh`, `sing_box_config_manager.sh`, `sing_box_config_facade.sh`, `logging.sh`, `rulesets.sh`, `updater.sh`. The CLI dispatcher (`case "$1" in ...`) is at the bottom of the file; entry points are `start`/`stop`/`reload`/`restart` (procd) and the diagnostics/`get_*`/`show_*`/`*_update`/`clash_api`/`component_action` commands.

## 2. File headers and variable scope

- Every lib `.sh` file starts with `# shellcheck shell=ash`.
- Constants files that intentionally hold unused-looking vars also add `# shellcheck disable=SC2034` (see `constants.sh` lines 1–2).
- Declare **all** function-local variables with `local`. ShellCheck (severity error) gates this.

## 3. Strict function-naming prefixes

Use the right prefix; it signals the function's layer and contract.

| Prefix | Meaning | Examples |
|---|---|---|
| `sing_box_cm_*` | **Config-manager primitives** — low-level jq mutations, ONE mutation each, take `$config` first, echo new JSON | `sing_box_cm_configure_log`, `sing_box_cm_add_udp_dns_server`, `sing_box_cm_add_route_rule` (`sing_box_config_manager.sh`) |
| `sing_box_cf_*` | **Facade orchestration** — parse a URL and call several `cm_*` | `sing_box_cf_add_proxy_outbound`, `sing_box_cf_add_dns_server` (`sing_box_config_facade.sh`) |
| `url_*` | URL parsing — pure, param-expansion / `sed` only | `url_get_host`, `url_get_port`, `url_get_scheme`, `url_decode` (`helpers.sh`) |
| `is_*` | Predicates returning 0/1 | `is_ipv4`, `is_domain`, `is_min_package_version`, `is_sing_box_extended` |
| `nft_*` | nft wrappers | `nft_create_table`, `nft_create_ipv4_set`, `nft_add_set_elements_from_file_chunked` (`nft.sh`) |
| `updates_*` / updater | binary updater | `updater.sh` |
| `get_*_tag` | Deterministic tag builders | `get_outbound_tag_by_section` (`<section>-out`), `get_inbound_tag_by_section`, `get_domain_resolver_tag`, `get_ruleset_tag` |
| `configure_*` / `import_*` / `_*_handler` | `config_foreach` / `config_list_foreach` callbacks | `configure_outbound_handler`, `import_community_subnet_lists`, `include_source_ip_in_routing_handler` |
| leading `_` | private helper (internal to a flow) | `_check_outbound_section`, `_update_subscription_for_section` |

## 4. The `$config` threading model

The sing-box config is carried as a shell string variable named `config`. `cm_*`/`cf_*` functions take it as `$1`, echo the mutated JSON, and the caller reassigns:

```sh
config=$(sing_box_cm_add_direct_outbound "$config" "$SB_DIRECT_OUTBOUND_TAG")
config=$(sing_box_cf_add_proxy_outbound "$config" "$section" "$proxy_string" "$udp_over_tcp")
```

`sing_box_init_config` seeds the skeleton, then runs `sing_box_configure_log/inbounds/outbounds/dns/route/experimental/additional_inbounds` and finally `sing_box_save_config`. Keep this echo-and-reassign discipline; never mutate config via global side effects.

## 5. jq idioms and the Oniguruma constraint

- Pass data with `--arg` (string) / `--argjson` (JSON), never string interpolation into the program:
  ```sh
  echo "$config" | jq --arg tag "$tag" --argjson port "$port" '...'
  ```
- Optional keys via the merge pattern:
  ```jq
  { ... } + (if $detour != "" then { detour: $detour } else {} end)
  ```
- **CRITICAL: OpenWRT's `jq` is built WITHOUT Oniguruma.** Never use `test()`, `match()`, `sub()`, `gsub()`, or any regex-based jq function — they will fail on-device. Use explicit string/codepoint logic instead (e.g. `explode`/`implode`, `index`, label/break loops — see the country-flag grouping in `sing_box_build_subscription_country_groups` and the tag-dedup in `normalize_subscription_to_singbox`). The updater documents the workarounds.
- Custom jq helpers live in `netshift/files/usr/lib/helpers.jq`, imported as:
  ```jq
  import "helpers" as h {"search": "/usr/lib/netshift"};
  ```

## 6. Validation and atomic writes (mandatory)

- **Every config write is validated.** `sing_box_save_config` writes to a temp file, then `sing_box_config_check` runs `sing-box -c <file> check`; on failure it logs `fatal` and `exit 1`. There is no exception to this.
- JSON shape is checked with `jq -e` (e.g. `validate_subscription_file`, `subscription_cache_is_usable`).
- **Atomic writes**: write `*.tmp.$$` then `mv` into place (subscription cache, URL metadata, rejected-hash). See `download_subscription_into_cache`.
- **Hash-compare before replacing**: `md5sum` the temp vs current and only `mv` when they differ (`sing_box_save_config`, subscription dedup, rejected-hash tracking).

## 7. Logging (`logging.sh`)

| Function | Behavior |
|---|---|
| `log "$msg" "$level"` | syslog via `logger -t netshift` (level defaults to `info`) |
| `nolog "$msg"` | TTY-only stdout (colorized; nothing when not a TTY) |
| `echolog "$msg" "$level"` | both: `log` + `nolog` |

Levels: `debug` / `info` / `warn` / `error` / `fatal`.

**CRITICAL:** `fatal` is only a LABEL — `log` does NOT exit. You must manually `exit 1` after logging fatal:

```sh
log "Subscription URL is not set. Aborted." "fatal"
exit 1
```

This pattern (`... Aborted." "fatal"; exit 1`) appears throughout the CLI; preserve it.

## 8. busybox quirks

- busybox `sed` lacks `\x` hex escapes. Build literal bytes with `printf` octal escapes (e.g. the UTF-8 BOM `printf '\357\273\277'` in `normalize_subscription_to_singbox`).
- Convert CRLF→LF with `convert_crlf_to_lf` before parsing downloaded lists.
- Strip a leading UTF-8 BOM before base64 charset detection.
- The diagnostic strings in `usr/bin/netshift` (emoji / box-drawing in `list_update`, `subscription_update`, `global_check`, `check_nft`, e.g. `📡 🛠️ ✅ ❌ ⚠️ ➡️ 🧱 🥸 📄` and `━` separators) are **valid UTF-8** and must stay valid UTF-8 — they render correctly on the device (SSH/UTF-8 terminal) and LuCI. They are **not** intentional mojibake.
- These were once corrupted by a UTF-8→CP1251 double-encode (real UTF-8 bytes read as CP1251 and re-saved as UTF-8), which made them print as `рџ…`/`в”…` garbage; task-004 repaired them. **Never open/save `usr/bin/netshift` in a non-UTF-8 editor or run it through a CP1251 codepage** — doing so reintroduces the `рџ…`/`в”…`/`вЂ…` mojibake. Edit it as UTF-8 only.

## 9. New constants

Anything that looks like a port, IP, mark, tag, path, version, URL, or service list goes into `constants.sh` under the right group (`## Common`, `## nft`, `## sing-box`, `## Lists`). Never hardcode it inline. See `project-core.md` §5.

## 10. UCI access patterns

- `config_get var section option [default]` — read an option.
- `config_get_bool var section option [default]` — read a boolean (0/1).
- `config_foreach fn type` — call `fn` for each section of `type` (here usually `section`); `fn` receives the section name as `$1`.
- `config_list_foreach section list fn [extra args...]` — call `fn` for each list item.
- The CLI runs `config_load "$NETSHIFT_CONFIG"` at startup; after `uci commit` it reloads (`uci commit ...; config_load ...`).

UCI schema lives in `netshift/files/etc/config/netshift` (`settings` section + per-connection sections with `connection_type` = `proxy`/`vpn`/`block`/`exclusion`, and `proxy_config_type` = `url`/`selector`/`urltest`/`outbound`/`subscription`). Changing it is a system-level change (`project-core.md` §4).

## 11. Tests and gates for backend changes

- Run the **`shellcheck`** skill and the **`smoke-tests`** skill before considering a backend change done.
- Smoke tests live in `tests/entrypoint.sh`. Existing test functions: `test_deps`, `test_syntax`, `test_config`, `test_helpers`, `test_jq_helpers`, `test_config_manager`, `test_sing_box_config`, `test_nft`, `test_diagnostics`, `test_subscription`.
- **Adding a backend test** means all three of:
  1. Add a `test_*` function to `tests/entrypoint.sh`.
  2. Register it in `main()` — add the call to the `all)` branch.
  3. Add a `case` entry (its short alias) AND list the alias in the "Available:" usage line.
- Backend changes affecting **config generation** or **subscription parsing** SHOULD add/extend a smoke test (`test_sing_box_config`, `test_config_manager`, `test_jq_helpers`, or `test_subscription`).

## 12. Glob scope confirmation

These rules apply to everything matched by `netshift/files/usr/**` (the CLI, all `*.sh` libraries, and `helpers.jq`).
