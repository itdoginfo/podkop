#!/bin/sh
# ──────────────────────────────────────────────────────────────────
# Netshift Evolution — Smoke Test Suite Entrypoint
#
# Runs validation tests against the netshift codebase in an OpenWrt
# rootfs container. Designed for CI and pre-deployment verification.
# ──────────────────────────────────────────────────────────────────

set -e

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
RESULTS_DIR="${RESULTS_DIR:-/tmp/test-results}"
NETSHIFT_SRC="${NETSHIFT_SRC:-/netshift/files}"
NETSHIFT_LIB_DIR="${NETSHIFT_SRC}/usr/lib"

mkdir -p "$RESULTS_DIR"

# ── Helpers ─────────────────────────────────────────────────────
header() {
    printf "\n${BOLD}${CYAN}━━━ %s ━━━${NC}\n" "$1"
}

pass() {
    PASS=$((PASS + 1))
    printf "  ${GREEN}✓${NC} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "  ${RED}✗${NC} %s\n" "$1"
    if [ -n "$2" ]; then
        printf "    ${RED}→${NC} %s\n" "$2"
    fi
}

skip() {
    SKIP=$((SKIP + 1))
    printf "  ${YELLOW}⊘${NC} %s (skipped)\n" "$1"
}

summary() {
    printf "\n${BOLD}──────────────────────────────────────${NC}\n"
    printf "Results: ${GREEN}%d passed${NC}" "$PASS"
    printf " / ${RED}%d failed${NC}" "$FAIL"
    if [ "$SKIP" -gt 0 ]; then
        printf " / ${YELLOW}%d skipped${NC}" "$SKIP"
    fi
    printf "\n"
    if [ "$FAIL" -gt 0 ]; then
        printf "${RED}${BOLD}✗ TESTS FAILED${NC} ($FAIL failure(s))\n"
        exit 1
    else
        printf "${GREEN}${BOLD}✓ ALL TESTS PASSED${NC} ($PASS test(s))\n"
        exit 0
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: Dependency Check
# ─────────────────────────────────────────────────────────────────
test_deps() {
    header "Dependency Check"

    for bin in sing-box curl jq base64 dig nft ash; do
        if command -v "$bin" > /dev/null 2>&1; then
            pass "$bin is available ($(command -v "$bin"))"
        else
            fail "$bin is NOT available"
        fi
    done

    # Version checks
    if command -v sing-box > /dev/null 2>&1; then
        local sb_ver
        sb_ver=$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')
        if [ -n "$sb_ver" ]; then
            pass "sing-box version: $sb_ver"
        else
            fail "sing-box version detection failed"
        fi
    fi

    if command -v jq > /dev/null 2>&1; then
        local jq_ver
        jq_ver=$(jq --version 2>/dev/null | awk -F- '{print $2}')
        if [ -n "$jq_ver" ]; then
            pass "jq version: $jq_ver"
        else
            fail "jq version detection failed"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: Shell Syntax & Loading
# ─────────────────────────────────────────────────────────────────
test_syntax() {
    header "Shell Syntax & Library Loading"

    local lib="${NETSHIFT_LIB_DIR}"

    # Test each library file for syntax errors
    for f in \
        "$lib/constants.sh" \
        "$lib/helpers.sh" \
        "$lib/logging.sh" \
        "$lib/nft.sh" \
        "$lib/rulesets.sh" \
        "$lib/sing_box_config_manager.sh" \
        "$lib/sing_box_config_facade.sh" \
        "$lib/updater.sh"; do

        if [ ! -r "$f" ]; then
            fail "File not found: $f"
            continue
        fi

        if ash -n "$f" 2>&1; then
            pass "Syntax OK: $(basename "$f")"
        else
            fail "Syntax ERROR in $(basename "$f")" "$(ash -n "$f" 2>&1)"
        fi
    done

    # Parse-check the CLI dispatcher itself (not just the libs).
    local cli="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$cli" ]; then
        fail "File not found: $cli"
    elif ash -n "$cli" 2>&1; then
        pass "Syntax OK: $(basename "$cli")"
    else
        fail "Syntax ERROR in $(basename "$cli")" "$(ash -n "$cli" 2>&1)"
    fi

    # Guard against re-introduction of the task-004 double-encode mojibake
    # (UTF-8 emoji/box-drawing read as CP1251 and re-saved as UTF-8). The
    # corrupted bytes render as рџ… / в”… / вЂ…; build the byte markers with
    # printf octal escapes (busybox sed/grep lack \x).
    if [ -r "$cli" ]; then
        local mojibake_found=0
        local marker
        for marker in '\321\200\321\237' '\320\262\342\200\235' '\320\262\320\202'; do
            if grep -qF "$(printf "$marker")" "$cli" 2>/dev/null; then
                mojibake_found=1
            fi
        done
        if [ "$mojibake_found" -eq 0 ]; then
            pass "netshift CLI free of double-encode mojibake"
        else
            fail "netshift CLI contains residual mojibake (рџ/в”/вЂ)"
        fi
    fi

    # Test that libraries can be sourced (requires /lib/functions stubs).
    # Use a temp script to avoid fragile shell quoting.
    local source_test="/tmp/netshift-source-test-$$.sh"
    cat > "$source_test" << EOF
NETSHIFT_LIB="$lib"
NETSHIFT_CONFIG="/etc/config/netshift.test"
mkdir -p /lib/config /lib/functions
touch /etc/config/dhcp /etc/config/sing-box
. "$lib/logging.sh" 2>/dev/null && echo "OK"
EOF

    if ash "$source_test" 2>&1 | grep -q "OK"; then
        pass "logging.sh can be sourced"
    else
        skip "logging.sh source test (needs OpenWrt /lib/functions)"
    fi
    rm -f "$source_test"
}

# ─────────────────────────────────────────────────────────────────
# Test: UCI Config Validation
# ─────────────────────────────────────────────────────────────────
test_config() {
    header "UCI Config Validation"

    local config="${NETSHIFT_SRC}/etc/config/netshift"

    if [ ! -r "$config" ]; then
        fail "Config file not found: $config"
        return
    fi

    pass "Config file exists: $config"

    # Check for required sections
    if grep -q "config settings" "$config"; then
        pass "settings section present"
    else
        fail "settings section missing"
    fi

    if grep -q "config section" "$config"; then
        pass "section (proxy) present"
    else
        fail "section (proxy) missing"
    fi

    # Check that core options exist
    for opt in "shutdown_correctly" "dns_type" "connection_type" "proxy_config_type"; do
        if grep -q "option $opt" "$config"; then
            pass "option $opt present"
        else
            fail "option $opt missing"
        fi
    done

    # Count sections
    local section_count
    section_count=$(grep -c "^config section\|^#config section" "$config")
    pass "Sections in config: $section_count"
}

# ─────────────────────────────────────────────────────────────────
# Test: Helper Functions
# ─────────────────────────────────────────────────────────────────
test_helpers() {
    header "Helper Functions"

    local helpers="${NETSHIFT_LIB_DIR}/helpers.sh"

    if [ ! -r "$helpers" ]; then
        fail "helpers.sh not found"
        return
    fi

    # Write test script to a temp file to avoid quoting issues
    local tmp="/tmp/test-helpers-$$.sh"
    cat > "$tmp" << 'TESTEOF'
mkdir -p /lib/config /lib/functions /tmp/sysinfo
echo 'OpenWrt Test' > /tmp/sysinfo/model
touch /etc/config/dhcp /etc/config/sing-box

. "HELPERS_PATH"

# Test is_ipv4
is_ipv4 '192.168.1.1' && echo 'ipv4:OK' || echo 'ipv4:FAIL'
is_ipv4 'not-an-ip' && echo 'ipv4-bad:FAIL' || echo 'ipv4-bad:OK'

# Test url_is_ipv6_literal (our fork's IPv6 helper; expects a full URL with a bracketed host)
url_is_ipv6_literal 'http://[::1]:443/test' && echo 'ipv6-literal:OK' || echo 'ipv6-literal:FAIL'
url_is_ipv6_literal 'https://example.com:8080/path' && echo 'ipv6-literal-neg:FAIL' || echo 'ipv6-literal-neg:OK'

# Test is_ipv4_ip_or_ipv4_cidr
is_ipv4_ip_or_ipv4_cidr '10.0.0.0/8' && echo 'ipv4cidr:OK' || echo 'ipv4cidr:FAIL'

# Test generate_hwid (needs WAN MAC)
generate_hwid 2>/dev/null && echo 'hwid:OK' || echo 'hwid:SKIP'

# Test get_device_model
get_device_model 2>/dev/null && echo 'model:OK' || echo 'model:SKIP'

# Test URL parsing
url_get_host 'https://example.com:8080/path' | grep -q 'example.com' && echo 'url-host:OK' || echo 'url-host:FAIL'
url_get_port 'https://example.com:8080/path' | grep -q '8080' && echo 'url-port:OK' || echo 'url-port:FAIL'
url_get_port 'http://[::1]:443/test' | grep -q '443' && echo 'url-ipv6-port:OK' || echo 'url-ipv6-port:FAIL'

# Test URL decoding (issue #50). url_decode keeps the form-encoded '+'->space
# rule (query values); url_decode_component decodes a single URI component and
# preserves '+'. Both must leave a '%' that is not a valid escape untouched.
[ "$(url_decode 'a+b%40c')" = 'a b@c' ] && echo 'url-decode:OK' || echo "url-decode:FAIL (got='$(url_decode 'a+b%40c')')"
[ "$(url_decode_component 'a+b%40c')" = 'a+b@c' ] && echo 'url-decode-component:OK' || echo "url-decode-component:FAIL (got='$(url_decode_component 'a+b%40c')')"
[ "$(url_decode_component '50%off')" = '50%off' ] && echo 'url-decode-bare-percent:OK' || echo "url-decode-bare-percent:FAIL (got='$(url_decode_component '50%off')')"
[ "$(url_get_query_param 'vless://x@h:1?path=%2Fa%2Bb&sni=s' 'path')" = '/a+b' ] && echo 'url-query-param-decode:OK' || echo "url-query-param-decode:FAIL (got='$(url_get_query_param 'vless://x@h:1?path=%2Fa%2Bb&sni=s' 'path')')"

echo 'DONE'
TESTEOF

    sed -i "s|HELPERS_PATH|$helpers|" "$tmp"

    # Run the driver to a RESULT FILE, then consume tokens in the CURRENT shell
    # (while read < file — NO pipe) so pass/fail/skip mutate the real counters.
    local h_out="/tmp/test-helpers-out-$$.log"
    sh "$tmp" > "$h_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$h_out"
    if [ "$saw_done" = "1" ]; then
        pass "helpers-driver-completed:OK"
    else
        fail "helpers-driver-completed:FAIL (driver aborted early)"
    fi

    rm -f "$tmp" "$h_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: NFT Rules Syntax
# ─────────────────────────────────────────────────────────────────
test_nft() {
    header "NFT Rules Syntax"

    if ! command -v nft > /dev/null 2>&1; then
        skip "nft not available"
        return
    fi

    # Test basic nft operations
    local test_table="netshift_test_$$"
    if nft add table inet "$test_table" 2>/dev/null; then
        pass "nft table creation works"
        nft delete table inet "$test_table" 2>/dev/null
    else
        fail "nft table creation failed (are capabilities set?)"
        return
    fi

    # Test set creation
    if nft add table inet "$test_table" 2>/dev/null && \
       nft add set inet "$test_table" testset '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null && \
       nft add element inet "$test_table" testset '{ 10.0.0.0/8 }' 2>/dev/null; then
        pass "nft set and element operations work"
        nft delete table inet "$test_table" 2>/dev/null
    else
        fail "nft set/element operations failed"
        nft delete table inet "$test_table" 2>/dev/null
    fi

    # Test chain creation
    if nft add table inet "$test_table" 2>/dev/null && \
       nft add chain inet "$test_table" testchain '{ type filter hook input priority 0; policy accept; }' 2>/dev/null; then
        pass "nft chain creation works"
        nft delete table inet "$test_table" 2>/dev/null
    else
        fail "nft chain creation failed"
        nft delete table inet "$test_table" 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: NFT IPv6 TProxy regression (B-01 blocker guard)
#
# The PR #11 IPv6 tproxy rule was emitted UNBRACKETED
# (`tproxy ip6 to ::1:1603`), which nft silently normalizes to a
# portless bare address (observed forms: `[::0.1.22.3]` on nftables
# v1.1.3 where 1603 == 0x1603, and `[::1:1603]` on OpenWRT 24.10.6).
# Either way the port is lost. The backend fix emits the BRACKETED
# form `[::1]:1603`. This test pins that
# contract at the real nft level so any revert fails the suite.
# Constants drive rule construction; the expected normalized
# `[::1]:1603` literal is the contract we deliberately hardcode.
# ─────────────────────────────────────────────────────────────────
test_nft_ipv6() {
    header "NFT IPv6 TProxy Regression"

    if ! command -v nft > /dev/null 2>&1; then
        skip "nft not available"
        return
    fi

    local constants="${NETSHIFT_LIB_DIR}/constants.sh"
    if [ ! -f "$constants" ]; then
        fail "constants.sh not found at $constants"
        return
    fi

    # Source the real runtime contract values (v6 tproxy addr/port).
    # shellcheck disable=SC1090
    . "$constants"

    if [ -z "$SB_TPROXY_INBOUND_ADDRESS_V6" ] || [ -z "$SB_TPROXY_INBOUND_PORT_V6" ]; then
        fail "v6 tproxy constants missing (SB_TPROXY_INBOUND_ADDRESS_V6/_PORT_V6)"
        return
    fi

    local test_table="netshift_v6_test_$$"

    # ── ipv6_addr interval set + v6 element (mirrors the ipv4 set test) ──
    if nft add table inet "$test_table" 2>/dev/null && \
       nft add set inet "$test_table" testset6 '{ type ipv6_addr; flags interval; auto-merge; }' 2>/dev/null && \
       nft add element inet "$test_table" testset6 '{ fc00::/7 }' 2>/dev/null; then
        pass "nft-v6-set-element:OK (ipv6_addr interval set + fc00::/7)"
    else
        fail "nft-v6-set-element:FAIL (ipv6_addr interval set / element insert failed)"
    fi
    nft delete table inet "$test_table" 2>/dev/null

    # ── v6 tproxy rule: build EXACTLY as the backend emits, list back ──
    # Capability-gate: if adding the rule errors for a kernel/capability
    # reason (no ip6 tproxy support), skip instead of false-failing.
    local add_err=""
    nft add table inet "$test_table" 2>/dev/null
    nft add chain inet "$test_table" proxy \
        '{ type filter hook prerouting priority -100; policy accept; }' 2>/dev/null
    # A v6 daddr return rule (exclusion) coexisting with the tproxy rule.
    nft add rule inet "$test_table" proxy ip6 daddr fc00::/7 counter return 2>/dev/null

    if add_err="$(nft add rule inet "$test_table" proxy meta l4proto tcp \
            tproxy ip6 to "[$SB_TPROXY_INBOUND_ADDRESS_V6]:$SB_TPROXY_INBOUND_PORT_V6" counter 2>&1)"; then
        local listed=""
        listed="$(nft list chain inet "$test_table" proxy 2>/dev/null)"

        # Positive: MUST normalize to the bracketed [::1]:1603 form.
        if echo "$listed" | grep -q 'tproxy ip6 to \[::1\]:1603'; then
            pass "nft-v6-tproxy-bracketed:OK (normalizes to [::1]:1603)"
        else
            fail "nft-v6-tproxy-bracketed:FAIL (expected [::1]:1603)" \
                "$(echo "$listed" | grep -i 'tproxy ip6' || echo "$listed")"
        fi

        # Negative guard: a buggy/portless bare v6 dest must NOT appear.
        # The unbracketed `::1:1603` is parsed as a bare address (no port);
        # nft re-prints it bracketed but mangled. Observed normalizations:
        #   nftables v1.1.3:  tproxy ip6 to [::0.1.22.3]   (1603 -> 0x1603)
        #   OpenWRT 24.10.6:  tproxy ip6 to [::1:1603]     (no `]:` port sep)
        # So the robust marker is: a `tproxy ip6 to [...]` line that is NOT
        # the correct `[::1]:1603`. Such a line is the bug; its absence is OK.
        if echo "$listed" | grep 'tproxy ip6 to \[' | grep -qv '\[::1\]:1603'; then
            fail "nft-v6-tproxy-no-bare:FAIL (buggy portless bare form present)" \
                "$(echo "$listed" | grep -i 'tproxy ip6')"
        else
            pass "nft-v6-tproxy-no-bare:OK (no portless bare ip6 form)"
        fi
    else
        case "$add_err" in
            *[Nn]ot\ supported*|*[Oo]peration\ not\ supported*|*[Nn]o\ such\ file*)
                skip "nft-v6-tproxy: kernel lacks ip6 tproxy support ($add_err)"
                ;;
            *)
                fail "nft-v6-tproxy:FAIL (rule add failed unexpectedly)" "$add_err"
                ;;
        esac
    fi

    nft delete table inet "$test_table" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────
# Test: Destination-selective nft marking (task-034 + router-originated OUTPUT marking fix)
#
# Regression: 0.8.6 marked ALL LAN tcp/udp into tproxy (mangle prerouting),
# so EVERY forwarded flow (e.g. a torrent to a random direct IP) entered
# sing-box -> sniff + full route-rule walk per connection -> 100% CPU on a
# weak router, even when only selected lists were configured for proxying.
# 0.8.5 marked SELECTIVELY: only proxied destination subnets
# (@netshift_subnets) + the FakeIP range (proxied domains). task-034 restores
# that selective model, keeping mark-EVERYTHING only when a global_proxy
# section is active.
#
# router-originated OUTPUT marking fix regression: the router-originated chain (mangle_output) had NO
# marking rules at all, but dnsmasq hands the router ITSELF FakeIP answers for
# proxied domains -> the router's own wget/opkg to a proxied destination was
# never tproxied and black-holed. mangle_output must carry the SAME
# destination-selective (or global_proxy mark-all) rules as mangle, AFTER the
# localv4/v6 + NFT_OUTBOUND_MARK returns. The outbound return is what keeps
# OUTPUT marking loop-safe: sing-box egress carries route.default_mark =
# NFT_OUTBOUND_MARK (task-033) and must escape re-marking.
#
# This test awk-extracts the SHIPPED create_nft_rules (+ its task-034 helpers)
# verbatim from the live bin, stubs the few UCI/predicate functions, and runs
# the real ruleset against a real nft table, then inspects BOTH the mangle
# (prerouting, LAN) and mangle_output (router-originated) chains. The driver
# dump is split into ---MANGLE--- / ---MANGLE_OUTPUT--- / ---SETS--- sections
# and every assertion is scoped to its own section (sel_section), so a rule in
# one chain can never satisfy — or hide — an assertion about the other.
# Cases (per the spec):
#   1. selective marking present + NO unconditional mark-all (default) — in
#      BOTH chains (drift between them black-holes router-originated traffic)
#   2. a direct (non-listed) destination is NOT marked -> bypasses sing-box
#      (rule-structure check)
#   3. global_proxy override = mark-all IS present (in BOTH chains)
#   4. IPv6 mirror selective when enable_ipv6=1 (+ no v6 mark-all)
#   5. domain routing intact: FakeIP range still marked; sing-box check passes
#   6. mangle_output ORDER: the localv4 + outbound-mark returns precede the marks
#   7. DoH-block CIDRs marked in mangle_output too when block_doh=1
# ─────────────────────────────────────────────────────────────────
test_selective_marking() {
    header "Destination-selective nft marking (task-034)"

    if ! command -v nft > /dev/null 2>&1; then
        skip "nft not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$bin" ] || [ ! -r "$lib/constants.sh" ] || [ ! -r "$lib/nft.sh" ]; then
        skip "selective-marking (bin / constants.sh / nft.sh not found)"
        return
    fi

    # Source the runtime contract values + nft helpers for the constants the
    # assertions reference (NFT_COMMON_SET_NAME, FakeIP ranges, marks).
    # shellcheck disable=SC1090
    . "$lib/constants.sh"

    # Confirm the new constants were actually re-added (DoD item).
    if [ -n "$NFT_COMMON_SET_NAME" ] && [ -n "$NFT_COMMON_SET_NAME_V6" ]; then
        pass "selective:constants — NFT_COMMON_SET_NAME(+v6) defined"
    else
        fail "selective:constants — NFT_COMMON_SET_NAME(+v6) missing"
        return
    fi

    # Common driver preamble shared by every scenario. Args via env:
    #   SCN_TABLE        unique nft table name for this run
    #   SCN_IPV6         1 to enable the IPv6 mirror, else 0
    #   SCN_GLOBALPROXY  non-empty -> global_proxy section name, else ""
    #   SCN_BLOCKDOH     1 to enable DoH-block CIDR marking, else 0
    #   SCN_FULLROUTED   space-separated fully_routed_ips (proxy section), else ""
    # The driver writes the real shipped create_nft_rules + helpers, runs it,
    # then dumps BOTH chains + the union set to stdout, each under a
    # ---SECTION--- label (---MANGLE---, ---MANGLE_OUTPUT---, ---SETS---) for
    # the parent to parse with sel_section.
    local drv="/tmp/netshift-selmark-$$.sh"
    cat > "$drv" << 'SELEOF'
set -e
LIB="LIB_DIR_PLACEHOLDER"
BIN="BIN_PATH_PLACEHOLDER"

# shellcheck disable=SC1090
. "$LIB/constants.sh"
# shellcheck disable=SC1090
. "$LIB/nft.sh"

# Override the table name so we never touch the real NetShiftTable.
NFT_TABLE_NAME="$SCN_TABLE"

# Quiet logger.
log() { :; }
nolog() { :; }
echolog() { :; }

# ── UCI / predicate stubs driven by env ──────────────────────────
netshift_ipv6_enabled() { [ "${SCN_IPV6:-0}" = "1" ]; }
get_global_proxy_section() { printf '%s' "${SCN_GLOBALPROXY:-}"; }

config_get() {
    # $1=var $2=section $3=option [$4=default]
    eval "$1=\"\${4:-}\""
    case "$3" in
        source_network_interfaces) eval "$1=\"selmark0\"" ;;
    esac
}
config_get_bool() {
    # $1=var $2=section $3=option [$4=default]
    eval "$1=\"\${4:-0}\""
    case "$3" in
        block_doh) eval "$1=\"${SCN_BLOCKDOH:-0}\"" ;;
        exclude_ntp) eval "$1=\"0\"" ;;
    esac
}
# fully_routed_ips iteration: one proxy section "frsec" carrying SCN_FULLROUTED.
config_foreach() {
    # $1=callback $2=type
    [ -n "${SCN_FULLROUTED:-}" ] || return 0
    "$1" "frsec"
}
config_list_foreach() {
    # $1=section $2=option $3=callback
    [ "$2" = "fully_routed_ips" ] || return 0
    for _ip in ${SCN_FULLROUTED:-}; do
        "$3" "$_ip"
    done
}
# The fully_routed section is always a proxy section in this harness.
# (config_get above returns connection_type default "", so force it here.)
_orig_cg=config_get

# Extract the shipped functions verbatim (column-0 opener to column-0 '}').
for fn in nft_init_interfaces_set populate_netshift_subnets_from_file \
          populate_netshift_subnets_from_string nft_mark_fully_routed_source_ips \
          _nft_mark_fully_routed_ips_for_section _nft_mark_fully_routed_ip_handler \
          foreach_active_section _active_section_dispatch \
          create_nft_rules; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done

# This harness has no `disabled` option: sections are never disabled.
section_is_disabled() { return 1; }

# The fully_routed handler reads connection_type via config_get; make that
# section a proxy section so its IPs get a source mark rule.
config_get() {
    eval "$1=\"\${4:-}\""
    case "$3" in
        source_network_interfaces) eval "$1=\"selmark0\"" ;;
        connection_type) eval "$1=\"proxy\"" ;;
        fully_routed_ips) eval "$1=\"${SCN_FULLROUTED:-}\"" ;;
    esac
}

# SCN_PRESEED: when set, do NOT start from a clean slate. Instead leave behind a
# STALE mark-EVERYTHING table (as a previous global_proxy/0.8.6 run would) and
# then run create_nft_rules on top of it WITHOUT a stop — faithfully reproducing
# the procd-respawn / in-place-upgrade service path that the original test
# missed. The fix (create_nft_rules flushing the table first) must make the
# FINAL live chain purely selective regardless of this leftover.
if [ "${SCN_PRESEED:-0}" = "1" ]; then
    nft delete table inet "$NFT_TABLE_NAME" 2>/dev/null || true
    nft add table inet "$NFT_TABLE_NAME"
    nft add set inet "$NFT_TABLE_NAME" "$NFT_LOCALV4_SET_NAME" '{ type ipv4_addr; flags interval; auto-merge; }'
    nft add set inet "$NFT_TABLE_NAME" "$NFT_INTERFACE_SET_NAME" '{ type ifname; flags interval; }'
    nft add element inet "$NFT_TABLE_NAME" "$NFT_INTERFACE_SET_NAME" '{ "selmark0" }'
    nft add chain inet "$NFT_TABLE_NAME" mangle '{ type filter hook prerouting priority -150; policy accept; }'
    nft add rule inet "$NFT_TABLE_NAME" mangle ct status dnat return
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" ip daddr "@$NFT_LOCALV4_SET_NAME" return
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" meta l4proto tcp meta mark set "$NFT_FAKEIP_MARK" counter
    nft add rule inet "$NFT_TABLE_NAME" mangle iifname "@$NFT_INTERFACE_SET_NAME" meta l4proto udp meta mark set "$NFT_FAKEIP_MARK" counter
    # Build on TOP of the stale table (no nft delete here on purpose).
    create_nft_rules >/dev/null 2>&1
else
    # Clean slate, then build the real ruleset.
    nft delete table inet "$NFT_TABLE_NAME" 2>/dev/null || true
    create_nft_rules >/dev/null 2>&1
fi

echo "---MANGLE---"
nft list chain inet "$NFT_TABLE_NAME" mangle 2>/dev/null || true
echo "---MANGLE_OUTPUT---"
nft list chain inet "$NFT_TABLE_NAME" mangle_output 2>/dev/null || true
echo "---SETS---"
nft list set inet "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" 2>/dev/null || true
SELEOF
    sed -i "s|LIB_DIR_PLACEHOLDER|$lib|g; s|BIN_PATH_PLACEHOLDER|$bin|g" "$drv"

    # Extract ONE ---LABEL--- section of a driver dump (to the next label / EOF).
    # Every assertion below is scoped through this: mangle and mangle_output are
    # separate sections, and only scoping keeps each check meaningful (an
    # unscoped grep would let an mangle_output rule satisfy a mangle assertion,
    # silently hiding exactly the drift this test exists to catch).
    sel_section() {
        printf '%s\n' "$1" | awk -v want="---$2---" '
            $0 == want { in_sec = 1; next }
            /^---[A-Z_]+---$/ { in_sec = 0 }
            in_sec { print }
        '
    }

    # ── Scenario 1+2+5: default selective (no global_proxy) ──────────
    local out1 mangle1 mout1
    out1="$(SCN_TABLE="selmark_def_$$" SCN_IPV6=0 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_def_$$" 2>/dev/null
    mangle1="$(sel_section "$out1" MANGLE)"
    mout1="$(sel_section "$out1" MANGLE_OUTPUT)"

    # The selective marks must be present in the PREROUTING (LAN) chain.
    if echo "$mangle1" | grep -q "@$NFT_COMMON_SET_NAME"; then
        pass "selective:default — proxied-subnets set rule present in mangle (@$NFT_COMMON_SET_NAME)"
    else
        fail "selective:default — @$NFT_COMMON_SET_NAME mark rule missing in mangle" "$(echo "$mangle1" | grep -i 'mark set' || echo "$out1")"
    fi
    if echo "$mangle1" | grep -Fq "$SB_FAKEIP_INET4_RANGE"; then
        pass "selective:default — FakeIP range marked in mangle ($SB_FAKEIP_INET4_RANGE) [domain routing intact]"
    else
        fail "selective:default — FakeIP range mark rule missing in mangle"
    fi
    # The proxied-subnets union set must exist (DoD: created).
    local set1
    set1="$(sel_section "$out1" SETS)"
    if echo "$set1" | grep -q "set $NFT_COMMON_SET_NAME"; then
        pass "selective:default — union set $NFT_COMMON_SET_NAME created"
    else
        fail "selective:default — union set $NFT_COMMON_SET_NAME not created"
    fi

    # router-originated OUTPUT marking fix: the OUTPUT chain (router-originated traffic) must carry the SAME
    # destination-selective marks, or dnsmasq's FakeIP answer for a proxied
    # domain black-holes the router's own wget/opkg (no mark -> no tproxy).
    if echo "$mout1" | grep -q "ip daddr @$NFT_COMMON_SET_NAME meta mark set $NFT_FAKEIP_MARK counter"; then
        pass "selective:output — proxied-subnets mark present in mangle_output (@$NFT_COMMON_SET_NAME)"
    else
        fail "selective:output — @$NFT_COMMON_SET_NAME mark missing in mangle_output (router-originated traffic black-holes)" "$(echo "$mout1" | grep -i 'mark set' || echo "$mout1")"
    fi
    if echo "$mout1" | grep -q "ip daddr $SB_FAKEIP_INET4_RANGE meta mark set $NFT_FAKEIP_MARK counter"; then
        pass "selective:output — FakeIP range marked in mangle_output ($SB_FAKEIP_INET4_RANGE) [router-originated domain routing]"
    else
        fail "selective:output — FakeIP range mark missing in mangle_output (router-originated traffic black-holes)"
    fi

    # Negative guard: the OUTPUT chain must NEVER carry the LAN-interface
    # (iifname) qualifier — router-originated traffic does not arrive on a LAN
    # interface, so a stray qualifier would silently exempt every rule in this
    # chain (no mark -> no tproxy -> the original black-hole). The positive
    # substrings above cannot catch it: nft can print the qualifier BEFORE the
    # daddr match, so such a rule still contains the checked substring.
    if echo "$mout1" | grep -q 'iifname'; then
        fail "selective:output — iifname qualifier present in mangle_output (router-originated rules would never match)" "$(echo "$mout1" | grep 'iifname' || true)"
    else
        pass "selective:output — no iifname qualifier in mangle_output (router-originated rules can match)"
    fi

    # Regression bypass: there must be NO unconditional mark-all rule (a
    # mark-set rule that has NO daddr / saddr / set qualifier) in EITHER chain.
    # For mangle we detect it structurally: a `meta l4proto (tcp|udp) meta mark
    # set` line that does NOT also contain `daddr` or `saddr`; for mangle_output
    # any `meta mark set` line without daddr/saddr would be mark-all.
    local markall_lines mout_markall_lines
    markall_lines="$(echo "$mangle1" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
    mout_markall_lines="$(echo "$mout1" | grep 'meta mark set' | grep -v 'daddr' | grep -v 'saddr' || true)"
    if [ -z "$markall_lines" ] && [ -z "$mout_markall_lines" ]; then
        pass "selective:bypass — NO unconditional mark-all rule (direct IP NOT marked)"
    else
        fail "selective:bypass — unconditional mark-all rule still present" "mangle: $markall_lines mangle_output: $mout_markall_lines"
    fi

    # router-originated OUTPUT marking fix: the returns MUST precede the marks in mangle_output. sing-box's
    # OWN egress carries NFT_OUTBOUND_MARK (route.default_mark, task-033) and
    # must escape re-marking (that is what makes OUTPUT marking loop-safe);
    # local/loopback (router->router, DNS to 127.0.0.42) must stay direct.
    local o_ret_local o_ret_out o_first_mark
    o_ret_local="$(echo "$mout1" | grep -n "ip daddr @$NFT_LOCALV4_SET_NAME return" | head -1 | cut -d: -f1)"
    o_ret_out="$(echo "$mout1" | grep -n "meta mark $NFT_OUTBOUND_MARK counter" | head -1 | cut -d: -f1)"
    o_first_mark="$(echo "$mout1" | grep -n "meta mark set $NFT_FAKEIP_MARK" | head -1 | cut -d: -f1)"
    if [ -n "$o_ret_local" ] && [ -n "$o_ret_out" ] && [ -n "$o_first_mark" ] && \
       [ "$o_ret_local" -lt "$o_first_mark" ] && [ "$o_ret_out" -lt "$o_first_mark" ]; then
        pass "selective:output-order — localv4 + outbound-mark returns precede the marks (loop-safe)"
    else
        fail "selective:output-order — returns missing or not before the marks (loop hazard)" "localv4=$o_ret_local outbound=$o_ret_out first_mark=$o_first_mark"
    fi

    # ── Scenario 3: global_proxy override -> mark-all present ────────
    local out3 mangle3 mout3
    out3="$(SCN_TABLE="selmark_gp_$$" SCN_IPV6=0 SCN_GLOBALPROXY="gpsec" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_gp_$$" 2>/dev/null
    mangle3="$(sel_section "$out3" MANGLE)"
    mout3="$(sel_section "$out3" MANGLE_OUTPUT)"

    local gp_markall
    gp_markall="$(echo "$mangle3" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
    if [ -n "$gp_markall" ]; then
        pass "selective:globalproxy — mark-EVERYTHING rules present under global_proxy"
    else
        fail "selective:globalproxy — mark-all rules missing under global_proxy" "$out3"
    fi
    # router-originated OUTPUT marking fix: router-originated traffic must be marked too under global_proxy
    # (tcp AND udp), or the router's own flows still bypass the proxy.
    if echo "$mout3" | grep -q "meta l4proto tcp meta mark set $NFT_FAKEIP_MARK counter"; then
        pass "selective:globalproxy-output — mark-EVERYTHING tcp rule present in mangle_output"
    else
        fail "selective:globalproxy-output — tcp mark-all rule missing in mangle_output" "$(echo "$mout3" | grep -i 'mark set' || echo "$mout3")"
    fi
    if echo "$mout3" | grep -q "meta l4proto udp meta mark set $NFT_FAKEIP_MARK counter"; then
        pass "selective:globalproxy-output — mark-EVERYTHING udp rule present in mangle_output"
    else
        fail "selective:globalproxy-output — udp mark-all rule missing in mangle_output"
    fi
    # And under global_proxy the selective @set rule should NOT be added to
    # EITHER chain.
    if printf '%s\n%s\n' "$mangle3" "$mout3" | grep -q "@$NFT_COMMON_SET_NAME"; then
        fail "selective:globalproxy — selective @set rule unexpectedly present under global_proxy"
    else
        pass "selective:globalproxy — selective @set rule correctly bypassed"
    fi

    # ── Scenario 4: IPv6 mirror selective (enable_ipv6=1) ────────────
    # Only meaningful if the kernel supports the v6 set + ip6 rules.
    local out4 mangle4 mout4
    out4="$(SCN_TABLE="selmark_v6_$$" SCN_IPV6=1 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_v6_$$" 2>/dev/null
    mangle4="$(sel_section "$out4" MANGLE)"
    mout4="$(sel_section "$out4" MANGLE_OUTPUT)"

    if echo "$mangle4" | grep -q "ip6 daddr @$NFT_COMMON_SET_NAME_V6"; then
        pass "selective:ipv6 — v6 union set mark rule present (@$NFT_COMMON_SET_NAME_V6)"
        local v6_markall
        v6_markall="$(echo "$mangle4" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
        if [ -z "$v6_markall" ]; then
            pass "selective:ipv6 — no mark-all rule with IPv6 enabled"
        else
            fail "selective:ipv6 — unexpected mark-all rule with IPv6 enabled" "$v6_markall"
        fi
        if echo "$mangle4" | grep -Fq "$SB_FAKEIP_INET6_RANGE"; then
            pass "selective:ipv6 — FakeIP v6 range marked ($SB_FAKEIP_INET6_RANGE)"
        else
            fail "selective:ipv6 — FakeIP v6 range mark rule missing"
        fi
        # router-originated OUTPUT marking fix: the same v6 marks must exist in the OUTPUT chain (the
        # router's own v6 flows to proxied destinations were black-holed too).
        if echo "$mout4" | grep -q "ip6 daddr @$NFT_COMMON_SET_NAME_V6 meta mark set $NFT_FAKEIP_MARK counter"; then
            pass "selective:ipv6-output — v6 union set mark present in mangle_output (@$NFT_COMMON_SET_NAME_V6)"
        else
            fail "selective:ipv6-output — v6 union set mark missing in mangle_output" "$(echo "$mout4" | grep -i daddr || echo "$mout4")"
        fi
        if echo "$mout4" | grep -q "ip6 daddr $SB_FAKEIP_INET6_RANGE meta mark set $NFT_FAKEIP_MARK counter"; then
            pass "selective:ipv6-output — FakeIP v6 range marked in mangle_output ($SB_FAKEIP_INET6_RANGE)"
        else
            fail "selective:ipv6-output — FakeIP v6 range mark missing in mangle_output"
        fi
    else
        # The driver enables v6 only if netshift_ipv6_enabled() returns true,
        # which it forced; absence here means the kernel rejected the v6 set/rule.
        skip "selective:ipv6 — v6 set/rule not applied (kernel ip6 support?)"
        skip "selective:ipv6-output — mangle_output v6 marks not verified (kernel ip6 support?)"
    fi

    # ── fully_routed_ips: SOURCE-based marking (any destination) ────
    # Clients listed in fully_routed_ips get their traffic proxied regardless
    # of destination, so the source-mark rule must exist in the prerouting
    # chain. (The rule-ordering / structure assertions live in Scenario 1+2+5.)
    local out_order mangle_order
    out_order="$(SCN_TABLE="selmark_ord_$$" SCN_IPV6=0 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="192.168.50.7" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_ord_$$" 2>/dev/null
    mangle_order="$(sel_section "$out_order" MANGLE)"
    if echo "$mangle_order" | grep -q "ip saddr 192.168.50.7 meta mark set"; then
        pass "selective:fullrouted — fully_routed_ips source-mark rule present"
    else
        fail "selective:fullrouted — fully_routed_ips source mark missing" "$(echo "$mangle_order" | grep -i saddr || echo "$out_order")"
    fi

    # ── Scenario 6 (THE REGRESSION REPRO): stale mark-all table + respawn ──
    # Reproduces the real on-hardware service path the original test missed: a
    # NetShiftTable left behind by a previous global_proxy / 0.8.6 mark-all run,
    # then create_nft_rules run again WITHOUT a clean stop (procd respawn /
    # in-place package upgrade). Before the fix, the stale mark-EVERYTHING rules
    # survived at the TOP of the prerouting chain and marked all traffic, making
    # the new destination-selective rules dead -> "everything proxied / 100%
    # CPU" even though the selective code was present. The fix flushes the table
    # first, so the FINAL live chain must be purely selective with NO mark-all.
    local out6 mangle6 mout6
    out6="$(SCN_TABLE="selmark_respawn_$$" SCN_IPV6=0 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" SCN_PRESEED=1 sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_respawn_$$" 2>/dev/null
    mangle6="$(sel_section "$out6" MANGLE)"
    mout6="$(sel_section "$out6" MANGLE_OUTPUT)"

    local respawn_markall
    respawn_markall="$(echo "$mangle6" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
    if [ -z "$respawn_markall" ]; then
        pass "selective:respawn — NO stale mark-all rule survives a respawn (table flushed)"
    else
        fail "selective:respawn — stale mark-all rule SURVIVED the rebuild (regression)" "$respawn_markall"
    fi
    if echo "$mangle6" | grep -q "@$NFT_COMMON_SET_NAME"; then
        pass "selective:respawn — selective @set rule present after respawn"
    else
        fail "selective:respawn — selective @set rule missing after respawn" "$out6"
    fi
    local set6
    set6="$(sel_section "$out6" SETS)"
    if echo "$set6" | grep -q "set $NFT_COMMON_SET_NAME"; then
        pass "selective:respawn — union set $NFT_COMMON_SET_NAME present after respawn"
    else
        fail "selective:respawn — union set $NFT_COMMON_SET_NAME missing after respawn"
    fi
    # The selective rules must not be DUPLICATED (proof the chain was rebuilt,
    # not appended): exactly one @set mark rule in EACH chain. The trailing
    # space anchors the match to the v4 set (a v6 mirror `_v6` suffix would
    # otherwise also match).
    local setrule_count mout_setrule_count
    setrule_count="$(echo "$mangle6" | grep -c "daddr @$NFT_COMMON_SET_NAME " || true)"
    mout_setrule_count="$(echo "$mout6" | grep -c "daddr @$NFT_COMMON_SET_NAME " || true)"
    if [ "$setrule_count" = "1" ] && [ "$mout_setrule_count" = "1" ]; then
        pass "selective:respawn — exactly one @set mark rule per chain (rebuilt, not appended)"
    else
        fail "selective:respawn — expected 1 @set rule per chain, found mangle=$setrule_count mangle_output=$mout_setrule_count (append, not rebuild)" "$out6"
    fi

    # ── Scenario 6b: DoH-block CIDRs marked in mangle_output too ─────
    # block_doh is read ONCE and shared by both chains (router-originated OUTPUT marking fix), so a router
    # whose own resolver probes a DoH IP is forced into sing-box exactly like
    # LAN clients are — otherwise the route-level DoH reject never sees the
    # router's own DoH traffic. Runs with IPv6 enabled to cover both loops.
    local out_doh mangle_doh mout_doh doh_v4_first doh_v6_first
    out_doh="$(SCN_TABLE="selmark_doh_$$" SCN_IPV6=1 SCN_GLOBALPROXY="" SCN_BLOCKDOH=1 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_doh_$$" 2>/dev/null
    mangle_doh="$(sel_section "$out_doh" MANGLE)"
    mout_doh="$(sel_section "$out_doh" MANGLE_OUTPUT)"

    # nft normalises /32 and /128 host CIDRs to the bare address in its output.
    doh_v4_first="$(echo "$DOH_BLOCK_IPV4_CIDRS" | awk '{print $1}')"
    doh_v4_first="${doh_v4_first%%/*}"
    if echo "$mangle_doh" | grep -q "ip daddr $doh_v4_first meta mark set $NFT_FAKEIP_MARK counter"; then
        pass "selective:doh — DoH CIDR marked in mangle ($doh_v4_first)"
    else
        fail "selective:doh — DoH CIDR mark missing in mangle ($doh_v4_first)" "$(echo "$mangle_doh" | grep -i daddr || echo "$out_doh")"
    fi
    if echo "$mout_doh" | grep -q "ip daddr $doh_v4_first meta mark set $NFT_FAKEIP_MARK counter"; then
        pass "selective:doh-output — DoH CIDR marked in mangle_output ($doh_v4_first)"
    else
        fail "selective:doh-output — DoH CIDR mark missing in mangle_output (router DoH probe escapes rejection)" "$(echo "$mout_doh" | grep -i daddr || echo "$mout_doh")"
    fi
    if echo "$mangle_doh" | grep -q "ip6 daddr @$NFT_COMMON_SET_NAME_V6"; then
        doh_v6_first="$(echo "$DOH_BLOCK_IPV6_CIDRS" | awk '{print $1}')"
        doh_v6_first="${doh_v6_first%%/*}"
        if echo "$mout_doh" | grep -q "ip6 daddr $doh_v6_first meta mark set $NFT_FAKEIP_MARK counter"; then
            pass "selective:doh-output — v6 DoH CIDR marked in mangle_output ($doh_v6_first)"
        else
            fail "selective:doh-output — v6 DoH CIDR mark missing in mangle_output ($doh_v6_first)"
        fi
    else
        skip "selective:doh-output — v6 DoH mark not verified (kernel ip6 support?)"
    fi

    rm -f "$drv"

    # ── Scenario 7: REAL get_global_proxy_section via a real config_load ─────
    # The original test STUBBED get_global_proxy_section, so it never exercised
    # the actual UCI-reading helper that decides mark-all vs selective. Here we
    # use the SHIPPED get_global_proxy_section / _determine_global_proxy_section /
    # section_has_configured_outbound / get_subscription_urls_for_section against
    # a REAL config_load of a hardware-shaped config (one subscription proxy
    # section, global_proxy=0). It MUST return empty -> selective branch.
    if [ -r /lib/functions.sh ] && [ -r /lib/config/uci.sh ] && command -v uci > /dev/null 2>&1; then
        local rgp_drv rgp_out
        rgp_drv="/tmp/netshift-selmark-rgp-$$.sh"
        cat > "$rgp_drv" << 'RGPEOF'
BIN="BIN_PATH_PLACEHOLDER"
LIB="LIB_DIR_PLACEHOLDER"
. /lib/functions.sh
. /lib/config/uci.sh 2>/dev/null || true
# shellcheck disable=SC1090
. "$LIB/constants.sh"
# shellcheck disable=SC1090
. "$LIB/helpers.sh"
log() { :; }
echolog() { :; }
nolog() { :; }
for fn in get_global_proxy_section _determine_global_proxy_section \
          foreach_active_section _active_section_dispatch section_is_disabled \
          section_has_configured_outbound get_subscription_urls_for_section \
          _collect_subscription_url_handler; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done
mkdir -p /etc/config
cat > /etc/config/netshift_selmarktest <<'CFGEOF'
config settings 'settings'
    option block_doh '0'

config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'subscription'
    option global_proxy '0'
    list subscription_url 'https://example.com/sub'
CFGEOF
# Mirror exactly what bin/netshift does: config_load with the config name.
config_load netshift_selmarktest
printf 'GP=[%s]\n' "$(get_global_proxy_section)"
rm -f /etc/config/netshift_selmarktest
RGPEOF
        sed -i "s|LIB_DIR_PLACEHOLDER|$lib|g; s|BIN_PATH_PLACEHOLDER|$bin|g" "$rgp_drv"
        rgp_out="$(sh "$rgp_drv" 2>/dev/null)"
        rm -f "$rgp_drv"
        if echo "$rgp_out" | grep -q '^GP=\[\]$'; then
            pass "selective:realgp — real get_global_proxy_section returns empty for global_proxy=0 (selective branch)"
        else
            fail "selective:realgp — real get_global_proxy_section wrongly non-empty (would force mark-all)" "$rgp_out"
        fi
    else
        skip "selective:realgp — LuCI config_load / uci not available"
    fi

    # ── Case 5b: sing-box validates a 2-section selective config ─────
    # The generated sing-box config is independent of the nft marking, but the
    # spec requires confirming sing-box still accepts a domain+subnet config.
    if command -v sing-box > /dev/null 2>&1 && command -v jq > /dev/null 2>&1; then
            local sbtmp sbcfg sbres
            sbtmp="/tmp/netshift-selmark-sb-$$.json"
            sbcfg=$(jq -n \
                --arg direct "$SB_DIRECT_OUTBOUND_TAG" \
                --arg tproxy "$SB_TPROXY_INBOUND_TAG" \
                --arg listen "$SB_TPROXY_INBOUND_ADDRESS" \
                --argjson port "$SB_TPROXY_INBOUND_PORT" \
                '{
                  log:{disabled:false,level:"warn",timestamp:true},
                  dns:{servers:[],rules:[],final:$direct,strategy:"prefer_ipv4",independent_cache:true},
                  ntp:{},
                  inbounds:[{type:"tproxy",tag:$tproxy,listen:$listen,listen_port:$port}],
                  outbounds:[{type:"direct",tag:$direct},{type:"direct",tag:"sec1-out"},{type:"direct",tag:"sec2-out"}],
                  route:{rules:[
                    {ip_cidr:["1.2.3.0/24"],outbound:"sec1-out"},
                    {ip_cidr:["198.18.0.0/15"],outbound:"sec2-out"}
                  ],rule_set:[],final:$direct,auto_detect_interface:true}
                }')
            printf '%s' "$sbcfg" > "$sbtmp"
            sbres="$(sing-box -c "$sbtmp" check 2>&1)"
            if [ -z "$sbres" ]; then
                pass "selective:singboxcheck — 2-section selective config validates"
            else
                fail "selective:singboxcheck — sing-box rejected config" "$sbres"
            fi
            rm -f "$sbtmp"
    else
        skip "selective:singboxcheck — sing-box / jq not installed"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: Section-isolation invariant (task-033)
#
# Regression: upgrading 0.8.5 -> 0.8.6 made ANY additional / not-ready /
# unreachable section black-hole ALL traffic to outbound/direct[direct-out]
# with `i/o timeout` (+ DNS n/a). Root cause (confirmed on a live kernel):
# the nft `mangle` prerouting chain marks ALL LAN tcp/udp with NFT_FAKEIP_MARK
# and `ip rule ... fwmark NFT_FAKEIP_MARK lookup netshift` redirects it to
# tproxy, but NOTHING stamped a mark on sing-box's OWN egress. So sing-box's
# direct-out sockets (which now carry ALL unmatched traffic) inherited the
# tproxy SO_MARK (NFT_FAKEIP_MARK) and the `ip rule` re-captured them into
# `local default dev lo` -> they looped back into tproxy and timed out.
#
# Fix: sing_box_cm_configure_route now emits route.default_mark =
# NFT_OUTBOUND_MARK, so every sing-box egress connection is marked
# NFT_OUTBOUND_MARK. The `ip rule` matches only NFT_FAKEIP_MARK, so the marked
# egress escapes via the main table (fail-open) and the existing
# `mangle_output meta mark NFT_OUTBOUND_MARK return` rule keeps it out of the
# proxy chain.
#
# This test pins (a) the config-gen contract (default_mark present, decimal,
# == NFT_OUTBOUND_MARK; empty-arg path byte-identical for back-compat), (b)
# that sing-box accepts a 2-section config (one outbound unreachable) with the
# generated route, and (c) — when runnable on the live kernel — that an egress
# packet carrying NFT_OUTBOUND_MARK reaches the internet while one carrying
# NFT_FAKEIP_MARK loops/black-holes (the exact mechanism of the regression).
# ─────────────────────────────────────────────────────────────────
test_section_isolation() {
    header "Section-isolation invariant (task-033)"

    if ! command -v sing-box > /dev/null 2>&1; then
        skip "sing-box not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local cm_lib="$lib/sing_box_config_manager.sh"
    local const_lib="$lib/constants.sh"
    if [ ! -r "$cm_lib" ] || [ ! -r "$const_lib" ]; then
        fail "sing_box_config_manager.sh / constants.sh not found"
        return
    fi

    # ── (a) config-gen contract: default_mark present + correct + back-compat ──
    local drv="/tmp/test-section-isolation-$$.sh"
    cat > "$drv" << 'SIEOF'
. "CONST_LIB"
. "CM_LIB"

mark_dec=$(( NFT_OUTBOUND_MARK ))
seed='{"route":{},"outbounds":[{"type":"direct","tag":"direct-out"}]}'

# WITH a default_mark (the fix path): assert it lands as a NUMBER equal to the
# decimal NFT_OUTBOUND_MARK.
with=$(sing_box_cm_configure_route "$seed" "direct-out" true "dns-server" "" "$mark_dec")
got=$(echo "$with" | jq -r '.route.default_mark // "MISSING"')
got_type=$(echo "$with" | jq -r '.route.default_mark | type')
if [ "$got" = "$mark_dec" ] && [ "$got_type" = "number" ]; then
    echo "si-default-mark-present:OK ($got, $got_type)"
else
    echo "si-default-mark-present:FAIL (got '$got' type '$got_type', want '$mark_dec' number)"
fi

# The mark must NOT collide with NFT_FAKEIP_MARK (which the ip rule catches).
if [ "$mark_dec" != "$(( NFT_FAKEIP_MARK ))" ]; then
    echo "si-mark-distinct-from-fakeip:OK"
else
    echo "si-mark-distinct-from-fakeip:FAIL (egress mark == fakeip mark -> would still loop)"
fi

# WITHOUT a default_mark (empty 6th arg): must be byte-identical to the legacy
# 5-arg call (back-compat for any other caller / the off path).
empty6=$(sing_box_cm_configure_route "$seed" "direct-out" true "dns-server" "" "")
legacy5=$(sing_box_cm_configure_route "$seed" "direct-out" true "dns-server" "")
if [ "$(echo "$empty6" | jq -cS .)" = "$(echo "$legacy5" | jq -cS .)" ]; then
    echo "si-empty-mark-byte-parity:OK"
else
    echo "si-empty-mark-byte-parity:FAIL (empty default_mark changed output)"
fi
if echo "$empty6" | jq -e '.route | has("default_mark")' > /dev/null 2>&1; then
    echo "si-empty-mark-omitted:FAIL (default_mark key present when empty)"
else
    echo "si-empty-mark-omitted:OK"
fi

# Emit the generated route (with mark) for the caller to build a full config.
echo "$with" | jq -c 'del(.route.rules[]?.__service_tag) | .route' > "ROUTE_JSON"
echo 'DONE'
SIEOF
    local route_json="/tmp/si-route-$$.json"
    sed -i "s#CONST_LIB#$const_lib#g; s#CM_LIB#$cm_lib#g; s#ROUTE_JSON#$route_json#g" "$drv"

    rm -f "$route_json"
    # Tokens go to a FILE (no pipe): pass/fail must run in this shell or the
    # counter increments are lost in the pipeline subshell.
    local out="/tmp/si-driver-out-$$.log"
    ash "$drv" > "$out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:FAIL*) fail "$line" ;;
            *:OK*)   pass "$line" ;;
            DONE)    saw_done=1 ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "si-driver-completed:OK"
    else
        fail "si-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$out"

    # ── (b) 2-section config (section 2 unreachable) + generated route: check ──
    local mark_dec
    # shellcheck disable=SC1090
    . "$const_lib"
    mark_dec=$(( NFT_OUTBOUND_MARK ))
    if [ -r "$route_json" ]; then
        local cfg="/tmp/si-config-$$.json"
        jq -n --slurpfile route "$route_json" '{
            log: { level: "warn" },
            dns: { servers: [ { tag: "dns-server", type: "udp", server: "1.1.1.1" } ], final: "dns-server" },
            inbounds: [ { type: "tproxy", tag: "tproxy-in", listen: "127.0.0.1", listen_port: 1602 } ],
            outbounds: [
                { type: "direct", tag: "direct-out" },
                { type: "shadowsocks", tag: "main-out", server: "10.10.10.10", server_port: 8388, method: "aes-256-gcm", password: "password" },
                { type: "hysteria2", tag: "second-out", server: "198.51.100.99", server_port: 443, password: "pass", tls: { enabled: true, insecure: true } }
            ],
            route: $route[0]
        }' > "$cfg"
        if sing-box check -c "$cfg" > /dev/null 2>&1; then
            pass "si-2section-unreachable-check:OK (sing-box accepts config + route.default_mark)"
        else
            fail "si-2section-unreachable-check:FAIL" "$(sing-box check -c "$cfg" 2>&1)"
        fi
        # the generated route must actually carry default_mark
        if [ "$(jq -r '.route.default_mark' "$cfg")" = "$mark_dec" ]; then
            pass "si-config-has-default-mark:OK"
        else
            fail "si-config-has-default-mark:FAIL"
        fi
        rm -f "$cfg"
    else
        fail "si-route-gen:FAIL (route JSON not produced)"
    fi

    # ── (c) live-kernel fail-open mechanism (only if nft + curl + net) ──────────
    # Build the EXACT ip rule the backend installs (fwmark NFT_FAKEIP_MARK ->
    # table netshift = local default dev lo) and prove:
    #   - egress carrying NFT_FAKEIP_MARK loops/black-holes (the bug)
    #   - egress carrying NFT_OUTBOUND_MARK (the fix) reaches the internet
    if [ "${TEST_SKIP_NETWORK:-0}" = "1" ]; then
        skip "si-live-loop: network skipped (TEST_SKIP_NETWORK=1)"
    elif ! command -v nft > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
        skip "si-live-loop: nft/curl not available"
    elif ! curl -s -m 5 -o /dev/null http://1.1.1.1/ 2>/dev/null; then
        skip "si-live-loop: no outbound connectivity in container"
    else
        # All ip/nft mutations are best-effort and may legitimately return
        # non-zero (rule absent on first del, etc.); guard each against `set -e`.
        grep -q "105 netshift" /etc/iproute2/rt_tables 2>/dev/null || \
            echo "105 netshift" >> /etc/iproute2/rt_tables
        ip -4 route replace local 0.0.0.0/0 dev lo table netshift 2>/dev/null || \
            ip -4 route add local 0.0.0.0/0 dev lo table netshift 2>/dev/null || true
        ip -4 rule del fwmark "$NFT_FAKEIP_MARK"/"$NFT_FAKEIP_MARK" table netshift priority 105 2>/dev/null || true
        ip -4 rule add fwmark "$NFT_FAKEIP_MARK"/"$NFT_FAKEIP_MARK" table netshift priority 105 2>/dev/null || true

        nft delete table inet netshift_si_test 2>/dev/null || true
        nft add table inet netshift_si_test 2>/dev/null || true
        nft add chain inet netshift_si_test out \
            '{ type route hook output priority -200; policy accept; }' 2>/dev/null || true

        # FAKEIP_MARK egress -> must loop (curl times out, rc!=0).
        nft flush chain inet netshift_si_test out 2>/dev/null || true
        nft add rule inet netshift_si_test out ip daddr 1.0.0.1 meta mark set "$NFT_FAKEIP_MARK" counter 2>/dev/null || true
        if curl -s -m 6 -o /dev/null http://1.0.0.1/ 2>/dev/null; then
            fail "si-live-loop-fakeip-blackholes:FAIL (fakeip-marked egress unexpectedly escaped)"
        else
            pass "si-live-loop-fakeip-blackholes:OK (fakeip-marked egress loops, as in the bug)"
        fi

        # OUTBOUND_MARK egress (the fix) -> must reach the internet (rc==0).
        nft flush chain inet netshift_si_test out 2>/dev/null || true
        nft add rule inet netshift_si_test out ip daddr 1.0.0.1 meta mark set "$NFT_OUTBOUND_MARK" counter 2>/dev/null || true
        if curl -s -m 6 -o /dev/null http://1.0.0.1/ 2>/dev/null; then
            pass "si-live-loop-outbound-escapes:OK (outbound-marked egress reaches internet -> fail-open)"
        else
            fail "si-live-loop-outbound-escapes:FAIL (outbound-marked egress did NOT escape)"
        fi

        nft delete table inet netshift_si_test 2>/dev/null || true
        ip -4 rule del fwmark "$NFT_FAKEIP_MARK"/"$NFT_FAKEIP_MARK" table netshift priority 105 2>/dev/null || true
        ip -4 route flush table netshift 2>/dev/null || true
    fi

    rm -f "$drv" "$route_json"
}

# ─────────────────────────────────────────────────────────────────
# Test: graceful-skip of unsupported proxy schemes + splithttp→xhttp (task-038)
# ─────────────────────────────────────────────────────────────────
# Two defects fixed by task-038:
#  1. sing_box_cf_add_proxy_outbound's `*)` default arm used to log fatal + exit 1
#     for an unsupported scheme. Since the dispatcher is shared by the single-URL,
#     selector-loop AND urltest-loop callers, ONE bad link (tuic/wireguard/typo)
#     aborted generation of the WHOLE config. It now logs a WARNING, echoes the
#     config UNCHANGED (never empty) and returns non-zero so the caller skips that
#     node and continues. Loop callers add the member tag only on success (no
#     dangling selector member); an all-unsupported section is marked unavailable
#     (reject route rule) instead of crashing the start.
#  2. `splithttp` (the pre-rename name of `xhttp`) is now accepted as an alias of
#     xhttp in BOTH the facade transport builder (?type=splithttp) and the
#     xray_json_to_uri_lines converter (network:"splithttp" / splithttpSettings),
#     normalized to the modern `xhttp` key downstream.
#
# This test drives the SHIPPED configure_outbound_handler (awk-extracted verbatim)
# for the url/selector/urltest branches with a table-driven config_get stub, the
# REAL facade/manager/helpers, and a log stub that records warnings/errors. All
# values are synthetic placeholders (nothing from private.json).
test_unsupported_skip() {
    header "Graceful-skip unsupported protocol + splithttp alias (task-038)"

    if ! command -v sing-box > /dev/null 2>&1; then
        skip "sing-box not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local facade_lib="$lib/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ] || [ ! -r "$bin" ]; then
        fail "facade lib / bin not found"
        return
    fi

    # The facade hardcodes NETSHIFT_LIB="/usr/lib/netshift" for its own sourcing
    # of helpers + manager; bind the bind-mounted sources to that path.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/test-unsupported-skip-$$.sh"
    local out="/tmp/test-unsupported-skip-out-$$.txt"
    cat > "$drv" << 'USEOF'
. "CONST_LIB"
. "FACADE_LIB"

WARN_LOG="/tmp/us-warn-$$.log"
: > "$WARN_LOG"
# log/echolog/nolog: record level+message so we can assert a warning fired.
log()     { printf '%s|%s\n' "${2:-info}" "$1" >> "$WARN_LOG"; }
echolog() { printf '%s|%s\n' "${2:-info}" "$1" >> "$WARN_LOG"; }
nolog()   { :; }

# Extended ON so vmess/xhttp gates pass where used.
is_sing_box_extended() { return 0; }

# awk-extract the SHIPPED member-building helper + handler + the unavailable
# marker verbatim. configure_outbound_handler delegates all selector/urltest
# member construction to _build_proxy_member_outbounds, so the helper MUST be
# extracted too — otherwise the member loop never runs ("not found"), no members
# or per-link warnings are produced and the section is wrongly marked unavailable.
eval "$(awk '/^_build_proxy_member_outbounds\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^configure_outbound_handler\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^mark_section_outbound_unavailable\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

# Table-driven UCI stub. Per-section options are read from US_<section>_<opt>
# shell vars (dots/dashes in section names normalized to underscores).
_us_key() { printf 'US_%s_%s' "$(printf '%s' "$1" | tr '.-' '__')" "$2"; }
config_get() {
    # $1=dest var, $2=section, $3=option, $4=default
    local _k _v
    _k="$(_us_key "$2" "$3")"
    eval "_v=\"\${$_k:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"\$_v\""
    return 0
}
config_get_bool() {
    local _k _v
    _k="$(_us_key "$2" "$3")"
    eval "_v=\"\${$_k:-${4:-0}}\""
    eval "$1=\"\$_v\""
    return 0
}

# Helper: assert a warn/error log line containing a substring exists.
warn_logged() { grep -q "$1" "$WARN_LOG"; }

# Build a minimal full sing-box config around the produced outbounds and run a
# real `sing-box check`. $1=config JSON, $2=label.
check_full() {
    local cfgjson="$1" label="$2" full
    full="/tmp/us-full-$$-${label}.json"
    printf '%s' "$cfgjson" | jq '{
        log: { level: "error" },
        dns: { servers: [ { tag: "dns-server", type: "udp", server: "1.1.1.1" } ], final: "dns-server" },
        inbounds: [ { type: "tproxy", tag: "tproxy-in", listen: "127.0.0.1", listen_port: 1602 } ],
        outbounds: (.outbounds + [ { type: "direct", tag: "direct-out" } ]),
        route: { rules: [], final: "direct-out" }
    }' > "$full" 2>/dev/null
    if sing-box -c "$full" check > /dev/null 2>&1; then
        echo "${label}:OK"
    else
        echo "${label}:FAIL"
    fi
    rm -f "$full"
}

# ── (1) URLTEST list mixing supported (vless/hysteria2) + unsupported ────────
#         (tuic:// / wireguard:// / garbage://). Generation must NOT abort, the
#         supported members must be present, the unsupported ones skipped, and a
#         warning logged. config must NOT be wiped.
: > "$WARN_LOG"
config='{"outbounds":[]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
US_mix_connection_type="proxy"
US_mix_proxy_config_type="urltest"
US_mix_urltest_proxy_links="vless://11111111-2222-3333-4444-555555555555@v.example.com:443?security=tls&sni=v.example.com tuic://uuid:pw@t.example.com:443 hysteria2://hpass@h.example.com:8443?sni=h.example.com wireguard://x@w.example.com:51820 garbage://nope"
configure_outbound_handler "mix"
mix_rc=$?

[ "$mix_rc" = "0" ] && echo 'us-urltest-no-abort:OK' || echo "us-urltest-no-abort:FAIL (rc=$mix_rc)"
[ -n "$config" ] && printf '%s' "$config" | jq -e . >/dev/null 2>&1 \
    && echo 'us-urltest-config-not-wiped:OK' || echo 'us-urltest-config-not-wiped:FAIL'

# The two supported member outbounds exist (vless = mix-1-out, hysteria2 = mix-3-out).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="mix-1-out" and .type=="vless")] | length==1' >/dev/null 2>&1 \
    && echo 'us-urltest-vless-present:OK' || echo 'us-urltest-vless-present:FAIL'
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="mix-3-out" and .type=="hysteria2")] | length==1' >/dev/null 2>&1 \
    && echo 'us-urltest-hy2-present:OK' || echo 'us-urltest-hy2-present:FAIL'

# The unsupported members were NOT created.
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="mix-2-out" or .tag=="mix-4-out" or .tag=="mix-5-out")] | length==0' >/dev/null 2>&1 \
    && echo 'us-urltest-unsupported-absent:OK' || echo 'us-urltest-unsupported-absent:FAIL'

# The urltest + selector reference ONLY the two real members (no dangling tag).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.type=="urltest")][0].outbounds | (index("mix-1-out")!=null and index("mix-3-out")!=null and index("mix-2-out")==null and index("mix-4-out")==null and index("mix-5-out")==null)' >/dev/null 2>&1 \
    && echo 'us-urltest-members-clean:OK' || echo 'us-urltest-members-clean:FAIL'

# A warning was logged for the skipped schemes.
warn_logged "unsupported scheme" && echo 'us-urltest-warning-logged:OK' || echo 'us-urltest-warning-logged:FAIL'

# Whole-chain: the assembled config passes a real sing-box check.
check_full "$config" "us-urltest-singbox-check"

# ── (1b) SELECTOR list, same mix ─────────────────────────────────────────────
: > "$WARN_LOG"
config='{"outbounds":[]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
US_sel_connection_type="proxy"
US_sel_proxy_config_type="selector"
US_sel_selector_proxy_links="garbage://nope vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@v2.example.com:443?security=tls&sni=v2.example.com tuic://u:p@t2.example.com:443"
configure_outbound_handler "sel"
sel_rc=$?
[ "$sel_rc" = "0" ] && echo 'us-selector-no-abort:OK' || echo "us-selector-no-abort:FAIL (rc=$sel_rc)"
# Only the vless (sel-2-out) member exists; selector references just it.
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="sel-2-out" and .type=="vless")] | length==1' >/dev/null 2>&1 \
    && echo 'us-selector-vless-present:OK' || echo 'us-selector-vless-present:FAIL'
printf '%s' "$config" | jq -e '[.outbounds[] | select(.type=="selector")][0].outbounds | (index("sel-2-out")!=null and index("sel-1-out")==null and index("sel-3-out")==null)' >/dev/null 2>&1 \
    && echo 'us-selector-members-clean:OK' || echo 'us-selector-members-clean:FAIL'
check_full "$config" "us-selector-singbox-check"

# ── (2) SINGLE-URL section with ONLY an unsupported scheme → degrade ─────────
#         No crash, no outbound, section marked unavailable, rest of config
#         continues to generate.
: > "$WARN_LOG"
config='{"outbounds":[{"type":"direct","tag":"direct-out"}]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
US_solo_connection_type="proxy"
US_solo_proxy_config_type="url"
US_solo_proxy_string="tuic://uuid:pw@only.example.com:443"
configure_outbound_handler "solo"
solo_rc=$?
[ "$solo_rc" = "0" ] && echo 'us-single-no-crash:OK' || echo "us-single-no-crash:FAIL (rc=$solo_rc)"
# No solo-out outbound was created.
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="solo-out")] | length==0' >/dev/null 2>&1 \
    && echo 'us-single-no-outbound:OK' || echo 'us-single-no-outbound:FAIL'
# The pre-existing direct-out (rest of config) survived (config not wiped).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="direct-out")] | length==1' >/dev/null 2>&1 \
    && echo 'us-single-rest-continues:OK' || echo 'us-single-rest-continues:FAIL'
# Section marked unavailable so the route emits a reject rule.
case " $SUBSCRIPTION_UNAVAILABLE_SECTIONS " in
*" solo "*) echo 'us-single-marked-unavailable:OK' ;;
*) echo 'us-single-marked-unavailable:FAIL' ;;
esac
warn_logged "no usable outbound" && echo 'us-single-error-logged:OK' || echo 'us-single-error-logged:FAIL'

# ── (3a) splithttp recognized as xhttp via a vless URL ?type=splithttp ───────
base='{"outbounds":[]}'
out_split=$(sing_box_cf_add_proxy_outbound "$base" "spl" "vless://77777777-8888-9999-aaaa-bbbbbbbbbbbb@s.example.com:8443?type=splithttp&security=tls&sni=s.example.com&path=/sp&host=s.example.com&mode=auto" "0")
printf '%s' "$out_split" | jq -e '.outbounds[0].transport.type=="xhttp"' >/dev/null 2>&1 \
    && echo 'us-splithttp-url-xhttp:OK' || echo 'us-splithttp-url-xhttp:FAIL'
printf '%s' "$out_split" | jq -e '.outbounds[0].transport.path=="/sp"' >/dev/null 2>&1 \
    && echo 'us-splithttp-url-path:OK' || echo 'us-splithttp-url-path:FAIL'
# Extended gate respected: with extended OFF the whole link is skipped (rc!=0,
# config unchanged) — not kept as an outbound without its transport, which
# would validate but could never connect.
is_sing_box_extended() { return 1; }
out_split_off=$(sing_box_cf_add_proxy_outbound "$base" "splo" "vless://77777777-8888-9999-aaaa-bbbbbbbbbbbb@s.example.com:8443?type=splithttp&security=tls&sni=s.example.com&path=/sp&host=s.example.com&mode=auto" "0")
split_off_rc=$?
if [ "$split_off_rc" != "0" ] && [ "$out_split_off" = "$base" ]; then
    echo 'us-splithttp-gate-off:OK'
else
    echo "us-splithttp-gate-off:FAIL (rc=$split_off_rc)"
fi
is_sing_box_extended() { return 0; }
# Whole-chain: the splithttp(→xhttp) outbound passes a real sing-box check on
# extended (the container core may be stock, so only assert when it accepts
# xhttp; otherwise emit SKIP).
spl_full="/tmp/us-split-full-$$.json"
printf '%s' "$out_split" | jq '{
    log: { level: "error" },
    inbounds: [],
    outbounds: (.outbounds + [ { type: "direct", tag: "direct-out" } ]),
    route: { final: "direct-out" }
}' > "$spl_full" 2>/dev/null
if sing-box -c "$spl_full" check > /dev/null 2>&1; then
    echo 'us-splithttp-singbox-check:OK'
else
    echo 'us-splithttp-singbox-check:SKIP'
fi
rm -f "$spl_full"

# ── (3b) splithttp recognized in xray_json_to_uri_lines (Xray JSON) ──────────
xray_src="/tmp/us-xray-split-$$.json"
cat > "$xray_src" << 'XJSON'
{ "outbounds": [ {
  "protocol": "vless",
  "tag": "xray-split",
  "settings": { "vnext": [ { "address": "xj.example.com", "port": 8443, "users": [ { "id": "cccccccc-dddd-eeee-ffff-000000000000" } ] } ] },
  "streamSettings": {
    "network": "splithttp",
    "security": "tls",
    "tlsSettings": { "serverName": "xj.example.com" },
    "splithttpSettings": { "path": "/xj", "host": "xj.example.com", "mode": "auto" }
  }
} ] }
XJSON
xray_uri="$(xray_json_to_uri_lines "$xray_src" 2>/dev/null)"
case "$xray_uri" in
*"type=xhttp"*) echo 'us-xray-splithttp-type-xhttp:OK' ;;
*) echo "us-xray-splithttp-type-xhttp:FAIL ($xray_uri)" ;;
esac
case "$xray_uri" in
*"path=/xj"*) echo 'us-xray-splithttp-path:OK' ;;
*) echo "us-xray-splithttp-path:FAIL ($xray_uri)" ;;
esac
case "$xray_uri" in
*"splithttp"*) echo "us-xray-splithttp-normalized:FAIL ($xray_uri)" ;;
*) echo 'us-xray-splithttp-normalized:OK' ;;
esac
rm -f "$xray_src"

rm -f "$WARN_LOG"
echo 'DONE'
USEOF
    sed -i "s|CONST_LIB|$lib/constants.sh|g; s|FACADE_LIB|$facade_lib|g; s|BIN_PATH|$bin|g" "$drv"

    # Run the driver to a RESULT FILE, then consume tokens in the CURRENT shell
    # (while read < file — NO pipe) so pass/fail/skip mutate the real counters
    # and this test actually GATES the suite.
    sh "$drv" > "$out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK)   pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE)   saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "us-driver-completed:OK"
    else
        fail "us-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: extended-only links are skipped as a whole on stock sing-box
# ─────────────────────────────────────────────────────────────────
# vmess:// and the XHTTP transport need sing-box-extended. On a stock core the
# facade must skip such a link with the `*)` contract (config UNCHANGED,
# non-zero return), so that:
#  - selector/urltest never get a member tag for an outbound that was not
#    created (sing-box check passes that, but sing-box fails to start with
#    "dependency[...] not found");
#  - a vless/trojan XHTTP link is not kept as an outbound without its
#    transport (valid, listed in the group, but it can never connect).
# Drives the REAL facade/manager/helpers and the SHIPPED
# _build_proxy_member_outbounds (awk-extracted). Synthetic values only.
test_extended_gate_skip() {
    header "Extended-only links skipped on stock sing-box"

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local facade_lib="$lib/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ] || [ ! -r "$bin" ]; then
        fail "facade lib / bin not found"
        return
    fi

    # The facade sources helpers + manager from /usr/lib/netshift.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/test-extgate-$$.sh"
    local out="/tmp/test-extgate-out-$$.txt"
    cat > "$drv" << 'EGEOF'
. "CONST_LIB"
. "FACADE_LIB"

LOG_FILE="/tmp/eg-log-$$.log"
: > "$LOG_FILE"
log()     { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
echolog() { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
nolog()   { :; }

eval "$(awk '/^_build_proxy_member_outbounds\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

base='{"outbounds":[]}'
VM_JSON='{"v":"2","ps":"vm","add":"vm.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"ws","host":"vm.example.com","path":"/vm","tls":"tls","sni":"vm.example.com"}'
VM="vmess://$(printf '%s' "$VM_JSON" | base64 | tr -d '\n')"
XH="vless://22222222-3333-4444-5555-666666666666@x.example.com:443?type=xhttp&security=tls&sni=x.example.com&path=/x&host=x.example.com&mode=auto"
XT="trojan://synthetic-pass@t.example.com:443?type=splithttp&security=tls&sni=t.example.com&path=/t&host=t.example.com"
PLAIN="vless://66666666-7777-8888-9999-aaaaaaaaaaaa@plain.example.com:443?type=tcp&security=tls&sni=plain.example.com"

# ── (1) stock: each extended-only link alone is skipped ──────────────────────
is_sing_box_extended() { return 1; }
for pair in "vmess|$VM" "vless-xhttp|$XH" "trojan-splithttp|$XT"; do
    name="${pair%%|*}"; link="${pair#*|}"
    : > "$LOG_FILE"
    got=$(sing_box_cf_add_proxy_outbound "$base" "eg" "$link" "0")
    rc=$?
    if [ "$rc" != "0" ] && [ "$got" = "$base" ] && grep -q '^error|.*requires sing-box-extended' "$LOG_FILE"; then
        echo "eg-stock-skip-$name:OK"
    else
        echo "eg-stock-skip-$name:FAIL (rc=$rc)"
    fi
done

# ── (2) stock: a urltest list keeps only the ordinary member ────────────────
config="$base"
_build_proxy_member_outbounds "eg" "$VM
$XH
$XT
$PLAIN" "0" "URLTest"
[ "$_member_outbound_tags" = "eg-4-out" ] && echo 'eg-stock-members-only-plain:OK' \
    || echo "eg-stock-members-only-plain:FAIL ($_member_outbound_tags)"
printf '%s' "$config" | jq -e '[.outbounds[].tag] == ["eg-4-out"]' >/dev/null 2>&1 \
    && echo 'eg-stock-no-transportless-outbound:OK' || echo 'eg-stock-no-transportless-outbound:FAIL'

# ── (3) the resulting group config validates AND starts ─────────────────────
# `sing-box check` does not resolve group members, so also run it briefly and
# make sure it does not stop on a missing dependency.
eg_full="/tmp/eg-full-$$.json"
printf '%s' "$config" | jq --arg m "$_member_outbound_tags" '{
    log: { level: "error" },
    inbounds: [],
    outbounds: (.outbounds + [
        { type: "urltest", tag: "eg-urltest", outbounds: ($m | split(",")) },
        { type: "direct", tag: "direct-out" } ]),
    route: { final: "eg-urltest" }
}' > "$eg_full" 2>/dev/null
if command -v sing-box > /dev/null 2>&1; then
    sing-box -c "$eg_full" check > /dev/null 2>&1 \
        && echo 'eg-stock-group-check:OK' || echo 'eg-stock-group-check:FAIL'
    eg_run_log="/tmp/eg-run-$$.log"
    sing-box -c "$eg_full" run > "$eg_run_log" 2>&1 &
    eg_pid=$!
    sleep 2
    kill "$eg_pid" 2>/dev/null
    wait "$eg_pid" 2>/dev/null
    grep -q 'dependency\[' "$eg_run_log" \
        && echo "eg-stock-group-starts:FAIL ($(grep -m1 'dependency\[' "$eg_run_log"))" \
        || echo 'eg-stock-group-starts:OK'
    rm -f "$eg_run_log"
else
    echo 'eg-stock-group-check:SKIP'
    echo 'eg-stock-group-starts:SKIP'
fi
rm -f "$eg_full"

# ── (4) extended: the same list builds all four members ─────────────────────
is_sing_box_extended() { return 0; }
config="$base"
_build_proxy_member_outbounds "ex" "$VM
$XH
$XT
$PLAIN" "0" "URLTest"
[ "$_member_outbound_tags" = "ex-1-out,ex-2-out,ex-3-out,ex-4-out" ] && echo 'eg-ext-members-all:OK' \
    || echo "eg-ext-members-all:FAIL ($_member_outbound_tags)"
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag == "ex-2-out" or .tag == "ex-3-out") | .transport.type] == ["xhttp", "xhttp"]' >/dev/null 2>&1 \
    && echo 'eg-ext-xhttp-transport:OK' || echo 'eg-ext-xhttp-transport:FAIL'

rm -f "$LOG_FILE"
echo 'DONE'
EGEOF
    sed -i "s|CONST_LIB|$lib/constants.sh|g; s|FACADE_LIB|$facade_lib|g; s|BIN_PATH|$bin|g" "$drv"

    sh "$drv" > "$out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK)    pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP*) skip "$line" ;;
            DONE)    saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "eg-driver-completed:OK"
    else
        fail "eg-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: VLESS Encryption passthrough + extended gate
# ─────────────────────────────────────────────────────────────────
# A vless:// link may carry the ML-KEM-768 + X25519 handshake in encryption=.
# The facade passes it to the outbound's `encryption` field, which exists only
# in sing-box-extended 2.0.0 and newer. Stock sing-box and older extended builds
# decode configs strictly, so the field there would fail `sing-box check` for
# the WHOLE config. The gate skips just that link (config UNCHANGED, non-zero
# rc, like the `*)` arm), so url/selector/urltest never reference an outbound
# that was not created. Ordinary links (encryption=none or absent) are never
# gated and their JSON is unchanged.
#
# The value itself is checked too: it is decoded as a URI component (a '+'
# stays '+') and must match what the extended parser accepts, so a key mangled
# into a space or carrying a '%' skips the link with an error rather than
# failing `sing-box check` for the whole config. Xray-JSON feeds keep such a
# key (percent-encoded) instead of silently downgrading it to "none". The core
# version is resolved once per feed / member list, not once per PQ link.
#
# Drives the REAL gate through get_sing_box_version (first through a stub
# `sing-box` on PATH, then through a version override), the REAL facade/
# manager/helpers and the SHIPPED _build_proxy_member_outbounds (awk-extracted).
# All values are synthetic placeholders.
test_vless_encryption() {
    header "VLESS Encryption passthrough + extended gate"

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local facade_lib="$lib/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ] || [ ! -r "$bin" ]; then
        fail "facade lib / bin not found"
        return
    fi

    # The facade sources helpers + manager from /usr/lib/netshift.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/test-vless-enc-$$.sh"
    local out="/tmp/test-vless-enc-out-$$.txt"
    cat > "$drv" << 'VEEOF'
. "CONST_LIB"
. "FACADE_LIB"

LOG_FILE="/tmp/ve-log-$$.log"
: > "$LOG_FILE"
log()     { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
echolog() { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
nolog()   { :; }

eval "$(awk '/^_build_proxy_member_outbounds\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

base='{"outbounds":[]}'
KEY='mlkem768x25519plus.native.0rtt.U8FmnIZILXq_jbMEEiPCkNENtc8sTHgADfkO5zB6_E4'
PQ="vless://11111111-2222-3333-4444-555555555555@pq.example.com:28872?encryption=$KEY&type=tcp&security=none#pq"
PLAIN="vless://66666666-7777-8888-9999-aaaaaaaaaaaa@plain.example.com:443?encryption=none&type=tcp&security=tls&sni=plain.example.com#plain"
BARE="vless://66666666-7777-8888-9999-aaaaaaaaaaaa@plain.example.com:443?type=tcp&security=tls&sni=plain.example.com#bare"

# ── (0) the REAL get_sing_box_version, through a stub `sing-box` on PATH ─────
# The stub prints $VE_SB_LINE for `version` and counts those calls; anything
# else (e.g. `check`) succeeds silently.
VE_BIN="/tmp/ve-bin-$$"
VE_CALLS="/tmp/ve-calls-$$"
mkdir -p "$VE_BIN"
: > "$VE_CALLS"
cat > "$VE_BIN/sing-box" << STUB
#!/bin/sh
if [ "\$1" = "version" ]; then
    echo x >> "$VE_CALLS"
    printf '%s\n' "\$VE_SB_LINE"
fi
exit 0
STUB
chmod +x "$VE_BIN/sing-box"
ve_saved_path="$PATH"
PATH="$VE_BIN:$PATH"
export VE_SB_LINE

VE_SB_LINE="sing-box version 1.13.14-extended-2.5.0"
v="$(get_sing_box_version)"
[ "$v" = "1.13.14-extended-2.5.0" ] && echo 've-version-parse:OK' || echo "ve-version-parse:FAIL ($v)"
# A build that appends more words must not lose the version (and the feature).
VE_SB_LINE="sing-box version 1.13.14-extended-2.5.0 (go1.23.4, linux/arm64)"
v="$(get_sing_box_version)"
[ "$v" = "1.13.14-extended-2.5.0" ] && echo 've-version-parse-suffix:OK' || echo "ve-version-parse-suffix:FAIL ($v)"

# One `sing-box version` per feed / per member list, not one per PQ link.
VE_SB_LINE="sing-box version 1.13.14-extended-2.5.0"
ve_sub="/tmp/ve-sub-$$"
ve_subout="/tmp/ve-subout-$$"
: > "$ve_sub"
i=1
while [ $i -le 5 ]; do
    printf 'vless://11111111-2222-3333-4444-55555555555%s@pq%s.example.com:28872?encryption=%s&type=tcp&security=none#pq%s\n' \
        "$i" "$i" "$KEY" "$i" >> "$ve_sub"
    i=$((i + 1))
done
: > "$VE_CALLS"
normalize_subscription_to_singbox "$ve_sub" "$ve_subout" "vc" > /dev/null 2>&1
n=$(jq '[.outbounds[] | select(has("encryption"))] | length' "$ve_subout" 2>/dev/null)
calls=$(wc -l < "$VE_CALLS" | tr -d ' ')
[ "$n" = "5" ] && echo 've-cache-sub-outbounds:OK' || echo "ve-cache-sub-outbounds:FAIL (n=$n)"
[ "$calls" = "1" ] && echo 've-cache-sub-one-call:OK' || echo "ve-cache-sub-one-call:FAIL (calls=$calls)"
: > "$VE_CALLS"
config="$base"
_build_proxy_member_outbounds "vm" "$(sed 's/#.*//' "$ve_sub")" "0" "URLTest"
calls=$(wc -l < "$VE_CALLS" | tr -d ' ')
[ "$calls" = "1" ] && echo 've-cache-members-one-call:OK' || echo "ve-cache-members-one-call:FAIL (calls=$calls)"
rm -f "$ve_sub" "$ve_subout"
PATH="$ve_saved_path"
rm -rf "$VE_BIN" "$VE_CALLS"

# From here on drive the gate through the version string it reads.
SB_VER=""
get_sing_box_version() { echo "$SB_VER"; }

# ── (0b) is_valid_vless_encryption accepts what the extended core accepts ──
# (parseClientEncryption + ClientInstance.Init; checked against the real core
# below when one is available). Keys are 43 (X25519) or 1579 (ML-KEM-768)
# base64url characters; padding "N-N-N" only before the first key.
K='U8FmnIZILXq_jbMEEiPCkNENtc8sTHgADfkO5zB6_E4'
BIG_OK="$(awk 'BEGIN { while (i++ < 1579) printf "A" }')"
BIG_BAD="$(awk 'BEGIN { while (i++ < 1579) printf "_" }')"
# Only the first 1152 bytes (1536 characters, the t vector) carry coefficients;
# the last 32 bytes are rho and take any value. "____" = three 0xFF bytes.
BIG_BAD_T_LAST="$(awk 'BEGIN { while (i++ < 1532) printf "A"; printf "____"; while (j++ < 43) printf "A" }')"
BIG_BAD_RHO="$(awk 'BEGIN { while (i++ < 1536) printf "A"; printf "____"; while (j++ < 39) printf "A" }')"
# Known differences, all in the safe direction (the validator is stricter, the
# link is skipped, the config cannot fail): the core also takes a '+' in a gap
# padding (Atoi("+0") == 0) and padding numbers of 19 digits (int64), while
# the validator allows only [A-Za-z0-9._-] and at most 18 digits.
STRICTER_PLUS="mlkem768x25519plus.native.0rtt.100-35-35.0-+0-+0.$K"
STRICTER_19="mlkem768x25519plus.native.0rtt.100-35-35.100-2-1234567890123456789.$K"
for v in "$KEY" "mlkem768x25519plus.xorpub.1rtt.$K" "mlkem768x25519plus.random.0rtt.$K.$K" \
    "mlkem768x25519plus.native.0rtt.100-35-35.$K" "mlkem768x25519plus.native.0rtt.100-35-35.1-2-3.$K" \
    "mlkem768x25519plus.native.1rtt.$BIG_OK" "mlkem768x25519plus.native.1rtt.$BIG_OK.$K"     "mlkem768x25519plus.native.1rtt.$BIG_BAD_RHO"; do
    short="len${#v}:$(printf '%s' "$v" | cut -c1-90)"
    is_valid_vless_encryption "$v" && echo "ve-valid-accepts-[$short]:OK" || echo "ve-valid-accepts-[$short]:FAIL"
done
K42="$(printf '%s' "$K" | cut -c1-42)"
K41="$(printf '%s' "$K" | cut -c1-41)"
for v in "" "none" "mlkem768x25519plus.native.0rtt" "mlkem768x25519plus.native.0rtt." \
    "mlkem768x25519plus.native.0rtt.A" "mlkem768x25519plus.native.0rtt.AAAA" \
    "mlkem768x25519plus.native.0rtt.$K42" "mlkem768x25519plus.native.0rtt.$K41" \
    "mlkem768x25519plus.native.0rtt.${K}A" \
    "mlkem768.native.0rtt.$K" "mlkem768x25519plus.fast.0rtt.$K" "mlkem768x25519plus.native.2rtt.$K" \
    "mlkem768x25519plus.native.0rtt.$K..$K" "mlkem768x25519plus.native.0rtt.$K.100-35-35" \
    "mlkem768x25519plus.native.0rtt.100-111-1111.$K" "mlkem768x25519plus.native.0rtt.100-34-35.$K" \
    "mlkem768x25519plus.native.0rtt.12345.$K" "mlkem768x25519plus.native.1rtt.$BIG_BAD" \
    "mlkem768x25519plus.native.0rtt.AB CD" \
    "mlkem768x25519plus.native.0rtt.AB+CD" "mlkem768x25519plus.native.0rtt.AB%2BCD"     "mlkem768x25519plus.native.1rtt.$BIG_BAD_T_LAST" "$STRICTER_PLUS" "$STRICTER_19"; do
    short="len${#v}:$(printf '%s' "$v" | cut -c1-90)"
    is_valid_vless_encryption "$v" && echo "ve-valid-rejects-[$short]:FAIL" || echo "ve-valid-rejects-[$short]:OK"
done

# ── (0c) the encryption value is read as a URI component: '+' survives ──────
# (This is what tells the component decoder from the form decoder; a facade
# level test cannot, since '+' and ' ' are both rejected by the validator.)
v="$(url_get_query_param_component 'vless://u@h:1?encryption=a+b%2Bc&type=tcp' encryption)"
[ "$v" = 'a+b+c' ] && echo 've-param-component-plus:OK' || echo "ve-param-component-plus:FAIL ($v)"
v="$(url_get_query_param 'vless://u@h:1?encryption=a+b&type=tcp' encryption)"
[ "$v" = 'a b' ] && echo 've-param-form-plus-is-space:OK' || echo "ve-param-form-plus-is-space:FAIL ($v)"

# ── (1) the release after "-extended-" decides, not the upstream version ────
# extended-lite builds report the same release with a "-lite" suffix; it is
# cut exactly like a pre-release tag, so a lite core passes every gate the
# full build does (its gate features — VLESS Encryption included — are kept).
for v in 1.13.14-extended-2.5.0 1.13.18-extended-2.6.5 1.12.22-extended-2.0.0 1.12.22-extended-2.0.0-rc.1 \
    1.14.1-extended-2.7.2-lite 1.12.22-extended-2.0.0-lite; do
    is_sing_box_extended_at_least "2.0.0" "$v" \
        && echo "ve-min-accepts-$v:OK" || echo "ve-min-accepts-$v:FAIL"
done
# extended-1.6.2 ships on sing-box 1.13.11 and still lacks the field.
for v in 1.13.11-extended-1.6.2 1.12.12-extended-1.5.0 1.13.14 1.12.0 \
    1.13.11-extended-1.6.2-lite; do
    is_sing_box_extended_at_least "2.0.0" "$v" \
        && echo "ve-min-rejects-$v:FAIL" || echo "ve-min-rejects-$v:OK"
done

# ── (2) extended >= 2.0.0: the key reaches the outbound ─────────────────────
SB_VER="1.13.14-extended-2.5.0"
out_pq=$(sing_box_cf_add_proxy_outbound "$base" "pq" "$PQ" "0")
rc=$?
[ "$rc" = "0" ] && echo 've-ext-pq-rc0:OK' || echo "ve-ext-pq-rc0:FAIL (rc=$rc)"
printf '%s' "$out_pq" | jq -e --arg k "$KEY" '.outbounds[0].encryption == $k' >/dev/null 2>&1 \
    && echo 've-ext-pq-field:OK' || echo 've-ext-pq-field:FAIL'
out_plain=$(sing_box_cf_add_proxy_outbound "$base" "plain" "$PLAIN" "0")
printf '%s' "$out_plain" | jq -e '.outbounds[0] | has("encryption") | not' >/dev/null 2>&1 \
    && echo 've-ext-none-omitted:OK' || echo 've-ext-none-omitted:FAIL'
out_bare=$(sing_box_cf_add_proxy_outbound "$base" "bare" "$BARE" "0")
printf '%s' "$out_bare" | jq -e '.outbounds[0] | has("encryption") | not' >/dev/null 2>&1 \
    && echo 've-ext-absent-omitted:OK' || echo 've-ext-absent-omitted:FAIL'

# A value that is not a VLESS Encryption handshake ("auto", "None") keeps the
# pre-PR behaviour — plain VLESS — but is no longer silent.
for other in auto None; do
    : > "$LOG_FILE"
    out_other=$(sing_box_cf_add_proxy_outbound "$base" "other" \
        "vless://66666666-7777-8888-9999-aaaaaaaaaaaa@plain.example.com:443?encryption=$other&type=tcp&security=tls&sni=plain.example.com" "0")
    rc=$?
    if [ "$rc" = "0" ] &&
        printf '%s' "$out_other" | jq -e '(.outbounds | length) == 1 and (.outbounds[0] | has("encryption") | not)' >/dev/null 2>&1 &&
        grep -q "^warn|Section 'other': unknown VLESS encryption value '$other'" "$LOG_FILE"; then
        echo "ve-other-value-plain-with-warning-[$other]:OK"
    else
        echo "ve-other-value-plain-with-warning-[$other]:FAIL (rc=$rc)"
    fi
done

# The value is decoded as a URI component: percent-escapes are undone, a
# literal '+' stays '+' (never a space) and is then rejected as malformed —
# the link is skipped with an error instead of failing `sing-box check` for
# the whole config.
ENC_DOTS='mlkem768x25519plus%2Enative%2E0rtt%2EU8FmnIZILXq_jbMEEiPCkNENtc8sTHgADfkO5zB6_E4'
out_dots=$(sing_box_cf_add_proxy_outbound "$base" "dots" \
    "vless://11111111-2222-3333-4444-555555555555@pq.example.com:28872?encryption=$ENC_DOTS&type=tcp&security=none" "0")
printf '%s' "$out_dots" | jq -e --arg k "$KEY" '.outbounds[0].encryption == $k' >/dev/null 2>&1 \
    && echo 've-ext-percent-decoded:OK' || echo 've-ext-percent-decoded:FAIL'
for raw in 'mlkem768x25519plus.native.0rtt.AAAA+BBBB' 'mlkem768x25519plus.native.0rtt.AAAA%2BBBBB' \
    'mlkem768x25519plus.native.0rtt.AAAA%25BBBB' 'mlkem768x25519plus.native'; do
    : > "$LOG_FILE"
    out_bad=$(sing_box_cf_add_proxy_outbound "$base" "bad" \
        "vless://11111111-2222-3333-4444-555555555555@pq.example.com:28872?encryption=$raw&type=tcp&security=none" "0")
    rc=$?
    if [ "$rc" != "0" ] && [ "$out_bad" = "$base" ] &&
        grep -q '^error|Section .*VLESS Encryption key of this link is malformed' "$LOG_FILE"; then
        echo "ve-ext-malformed-skipped-[$raw]:OK"
    else
        echo "ve-ext-malformed-skipped-[$raw]:FAIL (rc=$rc)"
    fi
done

# ── (3) stock: the PQ link is skipped, ordinary links are untouched ─────────
SB_VER="1.13.14"
: > "$LOG_FILE"
out_st=$(sing_box_cf_add_proxy_outbound "$base" "pq" "$PQ" "0")
rc=$?
[ "$rc" != "0" ] && echo 've-stock-pq-skip-rc:OK' || echo 've-stock-pq-skip-rc:FAIL (rc=0)'
[ "$out_st" = "$base" ] && echo 've-stock-pq-config-unchanged:OK' \
    || echo "ve-stock-pq-config-unchanged:FAIL ($out_st)"
grep -q '^error|Section .*VLESS Encryption requires sing-box-extended' "$LOG_FILE" \
    && echo 've-stock-pq-logged:OK' || echo 've-stock-pq-logged:FAIL'
out_st_plain=$(sing_box_cf_add_proxy_outbound "$base" "plain" "$PLAIN" "0")
rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out_st_plain" |
    jq -e '(.outbounds | length) == 1 and (.outbounds[0] | has("encryption") | not)' >/dev/null 2>&1; then
    echo 've-stock-plain-unaffected:OK'
else
    echo "ve-stock-plain-unaffected:FAIL (rc=$rc)"
fi

# ── (4) older extended without the field is gated too ───────────────────────
SB_VER="1.13.11-extended-1.6.2"
sing_box_cf_add_proxy_outbound "$base" "pq" "$PQ" "0" > /dev/null 2>&1
rc=$?
[ "$rc" != "0" ] && echo 've-ext162-pq-skip:OK' || echo 've-ext162-pq-skip:FAIL (rc=0)'

# ── (5) urltest on stock: only the ordinary member, and the config checks ───
SB_VER="1.13.14"
config="$base"
_build_proxy_member_outbounds "vt" "$PQ
$PLAIN" "0" "URLTest"
[ "$_member_outbound_tags" = "vt-2-out" ] && echo 've-stock-members-no-dangling:OK' \
    || echo "ve-stock-members-no-dangling:FAIL ($_member_outbound_tags)"
printf '%s' "$config" | jq -e '[.outbounds[].tag] == ["vt-2-out"]' >/dev/null 2>&1 \
    && echo 've-stock-members-outbounds:OK' || echo 've-stock-members-outbounds:FAIL'
ve_full="/tmp/ve-full-$$.json"
printf '%s' "$config" | jq --arg m "$_member_outbound_tags" '{
    log: { level: "error" },
    inbounds: [],
    outbounds: (.outbounds + [
        { type: "urltest", tag: "vt-urltest", outbounds: ($m | split(",")) },
        { type: "direct", tag: "direct-out" } ]),
    route: { final: "vt-urltest" }
}' > "$ve_full" 2>/dev/null
if command -v sing-box > /dev/null 2>&1; then
    sing-box -c "$ve_full" check > /dev/null 2>&1 \
        && echo 've-stock-urltest-check:OK' || echo 've-stock-urltest-check:FAIL'
else
    echo 've-stock-urltest-check:SKIP'
fi

# A list made only of PQ links on stock: no member at all and the config left
# untouched, so the caller marks the section unavailable (reject rule) instead
# of emitting an empty group.
config="$base"
_build_proxy_member_outbounds "vo" "$PQ
$PQ" "0" "URLTest"
[ -z "$_member_outbound_tags" ] && [ "$config" = "$base" ] \
    && echo 've-stock-pq-only-no-members:OK' \
    || echo "ve-stock-pq-only-no-members:FAIL ($_member_outbound_tags)"

# urltest on extended keeps both members, and a real extended core accepts the
# config with the field.
SB_VER="1.13.14-extended-2.5.0"
config="$base"
_build_proxy_member_outbounds "vx" "$PQ
$PLAIN" "0" "URLTest"
[ "$_member_outbound_tags" = "vx-1-out,vx-2-out" ] && echo 've-ext-members-both:OK' \
    || echo "ve-ext-members-both:FAIL ($_member_outbound_tags)"
# A real core that carries the field: the image ships a pinned
# /usr/local/bin/sing-box-extended next to the stock sing-box; otherwise use
# the container core itself if it happens to be extended.
ve_core_ver() {
    "$1" version 2>/dev/null | head -n1 | awk '
        { for (i = 1; i < NF; i++) if ($i == "version") { print $(i + 1); exit } print $NF }'
}
ext_core=""
for c in /usr/local/bin/sing-box-extended "$(command -v sing-box 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    if is_sing_box_extended_at_least "$SB_EXTENDED_VLESS_ENCRYPTION_MIN" "$(ve_core_ver "$c")"; then
        ext_core="$c"
        break
    fi
done
if [ -n "$ext_core" ]; then
    printf '%s' "$config" | jq --arg m "$_member_outbound_tags" '{
        log: { level: "error" },
        inbounds: [],
        outbounds: (.outbounds + [
            { type: "urltest", tag: "vx-urltest", outbounds: ($m | split(",")) },
            { type: "direct", tag: "direct-out" } ]),
        route: { final: "vx-urltest" }
    }' > "$ve_full" 2>/dev/null
    "$ext_core" -c "$ve_full" check > /dev/null 2>&1 \
        && echo 've-ext-urltest-check:OK' || echo 've-ext-urltest-check:FAIL'

    # The validator accepts exactly what the core accepts: truncated keys,
    # padding after a key, Xray-style padding (it decodes, so the fork takes it
    # for a 9-byte key), ML-KEM keys with valid / out-of-range coefficients,
    # including where the coefficient window ends (t vs rho).
    for v in "$KEY" "mlkem768x25519plus.native.0rtt.$K42" "mlkem768x25519plus.native.0rtt.$K41" \
        "mlkem768x25519plus.native.0rtt.A" "mlkem768x25519plus.native.0rtt.100-35-35.$K" \
        "mlkem768x25519plus.native.0rtt.$K.100-35-35" "mlkem768x25519plus.native.0rtt.100-111-1111.$K" \
        "mlkem768x25519plus.xorpub.1rtt.$BIG_OK" "mlkem768x25519plus.xorpub.1rtt.$BIG_BAD" \
        "mlkem768x25519plus.xorpub.1rtt.$BIG_BAD_T_LAST" "mlkem768x25519plus.xorpub.1rtt.$BIG_BAD_RHO"; do
        jq -n --arg e "$v" '{ log: { level: "error" }, outbounds: [ { type: "vless", tag: "t",
            server: "x.example.com", server_port: 1,
            uuid: "11111111-2222-3333-4444-555555555555", encryption: $e } ] }' > "$ve_full"
        "$ext_core" -c "$ve_full" check > /dev/null 2>&1 && core=accept || core=reject
        is_valid_vless_encryption "$v" && mine=accept || mine=reject
        short="len${#v}:$(printf '%s' "$v" | cut -c1-60)"
        [ "$mine" = "$core" ] && echo "ve-validator-matches-core-[$short]:OK" \
            || echo "ve-validator-matches-core-[$short]:FAIL (validator=$mine core=$core)"
    done

    # Known differences stay in the safe direction: never accepted by the
    # validator while the core would reject them.
    for v in "$STRICTER_PLUS" "$STRICTER_19"; do
        jq -n --arg e "$v" '{ log: { level: "error" }, outbounds: [ { type: "vless", tag: "t",
            server: "x.example.com", server_port: 1,
            uuid: "11111111-2222-3333-4444-555555555555", encryption: $e } ] }' > "$ve_full"
        "$ext_core" -c "$ve_full" check > /dev/null 2>&1 && core=accept || core=reject
        is_valid_vless_encryption "$v" && mine=accept || mine=reject
        short="len${#v}:$(printf '%s' "$v" | cut -c1-60)"
        if [ "$mine" = "accept" ] && [ "$core" = "reject" ]; then
            echo "ve-validator-safe-direction-[$short]:FAIL (validator accepts, core rejects)"
        else
            echo "ve-validator-safe-direction-[$short]:OK"
        fi
    done

    # flow + encryption together is a valid outbound on the core.
    jq -n --arg e "$KEY" '{ log: { level: "error" }, outbounds: [ { type: "vless", tag: "t",
        server: "x.example.com", server_port: 1, flow: "xtls-rprx-vision",
        uuid: "11111111-2222-3333-4444-555555555555", encryption: $e } ] }' > "$ve_full"
    "$ext_core" -c "$ve_full" check > /dev/null 2>&1 \
        && echo 've-ext-flow-plus-encryption:OK' || echo 've-ext-flow-plus-encryption:FAIL'
else
    echo 've-ext-urltest-check:SKIP'
    echo 've-validator-matches-core:SKIP'
    echo 've-validator-safe-direction:SKIP'
    echo 've-ext-flow-plus-encryption:SKIP'
fi

# The gate is needed at all: a stock core rejects the whole config once the
# field is in it.
stock_core="$(command -v sing-box 2>/dev/null)"
if [ -n "$stock_core" ] && ! is_sing_box_extended "$(ve_core_ver "$stock_core")"; then
    jq -n --arg e "$KEY" '{ log: { level: "error" }, outbounds: [ { type: "vless", tag: "t",
        server: "x.example.com", server_port: 1,
        uuid: "11111111-2222-3333-4444-555555555555", encryption: $e } ] }' > "$ve_full"
    "$stock_core" -c "$ve_full" check > /dev/null 2>&1 \
        && echo 've-stock-core-rejects-field:FAIL (stock core accepted encryption)' \
        || echo 've-stock-core-rejects-field:OK'
else
    echo 've-stock-core-rejects-field:SKIP'
fi
rm -f "$ve_full"

# ── (6) Xray-JSON subscriptions carry the key into the URI ──────────────────
xsrc="/tmp/ve-xray-$$.json"
cat > "$xsrc" << XJSON
{ "outbounds": [
  { "protocol": "vless", "tag": "xpq",
    "settings": { "vnext": [ { "address": "xpq.example.com", "port": 28872,
      "users": [ { "id": "11111111-2222-3333-4444-555555555555", "encryption": "$KEY" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "none" } },
  { "protocol": "vless", "tag": "xplain",
    "settings": { "vnext": [ { "address": "xplain.example.com", "port": 443,
      "users": [ { "id": "66666666-7777-8888-9999-aaaaaaaaaaaa" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "tls",
      "tlsSettings": { "serverName": "xplain.example.com" } } }
] }
XJSON
xuris="$(xray_json_to_uri_lines "$xsrc" 2>/dev/null)"
pq_line="$(printf '%s\n' "$xuris" | grep 'xpq.example.com')"
plain_line="$(printf '%s\n' "$xuris" | grep 'xplain.example.com')"
case "$pq_line" in
*"encryption=$KEY"*) echo 've-xray-pq-encryption:OK' ;;
*) echo "ve-xray-pq-encryption:FAIL ($pq_line)" ;;
esac
case "$plain_line" in
*"encryption=none"*) echo 've-xray-plain-none:OK' ;;
*) echo "ve-xray-plain-none:FAIL ($plain_line)" ;;
esac
SB_VER="1.13.14-extended-2.5.0"
rt=$(sing_box_cf_add_proxy_outbound "$base" "rt" "$pq_line" "0")
printf '%s' "$rt" | jq -e --arg k "$KEY" '.outbounds[0].encryption == $k' >/dev/null 2>&1 \
    && echo 've-xray-roundtrip:OK' || echo 've-xray-roundtrip:FAIL'
rm -f "$xsrc"

# A key with '%' or '+' is not dropped to "none" (that would silently turn the
# PQ node into plain VLESS): it is percent-encoded into the URI, and the facade
# then rejects it loudly as malformed.
cat > "$xsrc" << XJSON
{ "outbounds": [
  { "protocol": "vless", "tag": "xbad",
    "settings": { "vnext": [ { "address": "xbad.example.com", "port": 28872,
      "users": [ { "id": "11111111-2222-3333-4444-555555555555",
                   "encryption": "mlkem768x25519plus.native.0rtt.AA%B+C" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "none" } }
] }
XJSON
bad_line="$(xray_json_to_uri_lines "$xsrc" 2>/dev/null)"
case "$bad_line" in
*"encryption=mlkem768x25519plus.native.0rtt.AA%25B%2BC"*) echo 've-xray-bad-key-kept:OK' ;;
*) echo "ve-xray-bad-key-kept:FAIL ($bad_line)" ;;
esac
: > "$LOG_FILE"
sing_box_cf_add_proxy_outbound "$base" "xbad" "$bad_line" "0" > /dev/null 2>&1
rc=$?
if [ "$rc" != "0" ] && grep -q '^error|Section .*VLESS Encryption key of this link is malformed' "$LOG_FILE"; then
    echo 've-xray-bad-key-rejected-loudly:OK'
else
    echo "ve-xray-bad-key-rejected-loudly:FAIL (rc=$rc)"
fi
rm -f "$xsrc"

rm -f "$LOG_FILE"
echo 'DONE'
VEEOF
    sed -i "s|CONST_LIB|$lib/constants.sh|g; s|FACADE_LIB|$facade_lib|g; s|BIN_PATH|$bin|g" "$drv"

    # Consume tokens in the CURRENT shell (while read < file, no pipe) so
    # pass/fail/skip mutate the real counters. FAIL lines carry details after
    # the token ("...:FAIL (rc=0)"), so match the token, not the line end.
    sh "$drv" > "$out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK)    pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP*) skip "$line" ;;
            DONE)    saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "ve-driver-completed:OK"
    else
        fail "ve-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Text-list Selector / URLTest (task-051)
#
# Drives the SHIPPED configure_outbound_handler (awk-extracted verbatim) for the
# NEW selector_text / urltest_text branches with a table-driven config_get stub,
# the REAL facade/manager/helpers, and a real `sing-box check`. The textarea
# value is a multi-line blob: two synthetic vless:// + one ss:// + a blank line +
# one unsupported tuic://, plus a CRLF-suffixed line to prove trailing-\r
# tolerance. All values are synthetic placeholders (nothing private).
#
# IMPORTANT (gating): the driver writes name:OK/FAIL/SKIP tokens to a RESULT FILE
# and the assertions are consumed in the CURRENT shell via `while read < file`
# (NOT `cmd | while read`), so pass/fail mutate the real PASS/FAIL counters and
# this test actually GATES the suite.
test_text_list_outbound() {
    header "Text-list Selector / URLTest (task-051)"

    if ! command -v sing-box > /dev/null 2>&1; then
        skip "sing-box not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local facade_lib="$lib/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ] || [ ! -r "$bin" ]; then
        fail "facade lib / bin not found"
        return
    fi

    # The facade hardcodes NETSHIFT_LIB="/usr/lib/netshift" for its own sourcing
    # of helpers + manager; bind the bind-mounted sources to that path.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/test-text-list-$$.sh"
    local out="/tmp/test-text-list-out-$$.txt"
    cat > "$drv" << 'TLEOF'
. "CONST_LIB"
. "FACADE_LIB"

WARN_LOG="/tmp/tl-warn-$$.log"
: > "$WARN_LOG"
log()     { printf '%s|%s\n' "${2:-info}" "$1" >> "$WARN_LOG"; }
echolog() { printf '%s|%s\n' "${2:-info}" "$1" >> "$WARN_LOG"; }
nolog()   { :; }

is_sing_box_extended() { return 0; }

# awk-extract the SHIPPED helper + handler + unavailable marker verbatim.
eval "$(awk '/^_build_proxy_member_outbounds\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^configure_outbound_handler\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^mark_section_outbound_unavailable\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

_tl_key() { printf 'TL_%s_%s' "$(printf '%s' "$1" | tr '.-' '__')" "$2"; }
config_get() {
    local _k _v
    _k="$(_tl_key "$2" "$3")"
    eval "_v=\"\${$_k:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"\$_v\""
    return 0
}

warn_logged() { grep -q "$1" "$WARN_LOG"; }

check_full() {
    local cfgjson="$1" label="$2" full
    full="/tmp/tl-full-$$-${label}.json"
    printf '%s' "$cfgjson" | jq '{
        log: { level: "error" },
        dns: { servers: [ { tag: "dns-server", type: "udp", server: "1.1.1.1" } ], final: "dns-server" },
        inbounds: [ { type: "tproxy", tag: "tproxy-in", listen: "127.0.0.1", listen_port: 1602 } ],
        outbounds: (.outbounds + [ { type: "direct", tag: "direct-out" } ]),
        route: { rules: [], final: "direct-out" }
    }' > "$full" 2>/dev/null
    if sing-box -c "$full" check > /dev/null 2>&1; then
        echo "${label}:OK"
    else
        echo "${label}:FAIL"
    fi
    rm -f "$full"
}

# Multi-line synthetic blob: vless (line1) + vless (line2) + blank line +
# ss+CRLF (line3 carries a trailing \r) + unsupported tuic (line4). The CRLF on
# the ss line proves the trailing \r is stripped: it sits right after the
# `:8388` port, so an un-stripped \r would corrupt the port and the member would
# NOT build (a decisive gate, unlike a CR buried in a query string). Built with
# printf so the \r and the blank line are real bytes inside one scalar value.
TL_BLOB="$(printf '%s\n%s\n\n%s\r\n%s\n' \
    'vless://11111111-2222-3333-4444-555555555555@v1.example.com:443?security=tls&sni=v1.example.com' \
    'vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@v2.example.com:443?security=tls&sni=v2.example.com' \
    'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@s1.example.com:8388' \
    'tuic://uuid:pw@t1.example.com:443')"

# ── selector_text ────────────────────────────────────────────────────────────
config='{"outbounds":[]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
TL_seltxt_connection_type="proxy"
TL_seltxt_proxy_config_type="selector_text"
TL_seltxt_selector_proxy_links_text="$TL_BLOB"
configure_outbound_handler "seltxt"
seltxt_rc=$?
[ "$seltxt_rc" = "0" ] && echo 'tl-seltxt-no-abort:OK' || echo "tl-seltxt-no-abort:FAIL (rc=$seltxt_rc)"

# 3 supported members built (seltxt-1 vless, seltxt-2 vless [CRLF line], seltxt-4 ss).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="seltxt-1-out" and .type=="vless")] | length==1' >/dev/null 2>&1 \
    && echo 'tl-seltxt-vless1-present:OK' || echo 'tl-seltxt-vless1-present:FAIL'
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="seltxt-2-out" and .type=="vless")] | length==1' >/dev/null 2>&1 \
    && echo 'tl-seltxt-vless2-present:OK' || echo 'tl-seltxt-vless2-present:FAIL'
# The ss line carries a trailing CR (CRLF); it must still build with the \r
# stripped (decisive CRLF-tolerance gate).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="seltxt-3-out" and .type=="shadowsocks")] | length==1' >/dev/null 2>&1 \
    && echo 'tl-seltxt-ss-crlf-present:OK' || echo 'tl-seltxt-ss-crlf-present:FAIL'

# Unsupported tuic (line5 → seltxt-4; blank line is collapsed by IFS so it does
# NOT consume an index) NOT created.
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="seltxt-4-out")] | length==0' >/dev/null 2>&1 \
    && echo 'tl-seltxt-tuic-absent:OK' || echo 'tl-seltxt-tuic-absent:FAIL'

# Selector references exactly the 3 real members, default = first (seltxt-1-out).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.type=="selector")][0].outbounds | (index("seltxt-1-out")!=null and index("seltxt-2-out")!=null and index("seltxt-3-out")!=null and index("seltxt-4-out")==null)' >/dev/null 2>&1 \
    && echo 'tl-seltxt-members-clean:OK' || echo 'tl-seltxt-members-clean:FAIL'
printf '%s' "$config" | jq -e '[.outbounds[] | select(.type=="selector")][0].default=="seltxt-1-out"' >/dev/null 2>&1 \
    && echo 'tl-seltxt-default-first:OK' || echo 'tl-seltxt-default-first:FAIL'

warn_logged "unsupported scheme" && echo 'tl-seltxt-warning-logged:OK' || echo 'tl-seltxt-warning-logged:FAIL'
check_full "$config" "tl-seltxt-singbox-check"

# ── urltest_text ─────────────────────────────────────────────────────────────
: > "$WARN_LOG"
config='{"outbounds":[]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
TL_urltxt_connection_type="proxy"
TL_urltxt_proxy_config_type="urltest_text"
TL_urltxt_urltest_proxy_links_text="$TL_BLOB"
configure_outbound_handler "urltxt"
urltxt_rc=$?
[ "$urltxt_rc" = "0" ] && echo 'tl-urltxt-no-abort:OK' || echo "tl-urltxt-no-abort:FAIL (rc=$urltxt_rc)"

# urltest built over the 3 real members (no dangling unsupported tag).
printf '%s' "$config" | jq -e '[.outbounds[] | select(.type=="urltest")][0].outbounds | (index("urltxt-1-out")!=null and index("urltxt-2-out")!=null and index("urltxt-3-out")!=null and index("urltxt-4-out")==null)' >/dev/null 2>&1 \
    && echo 'tl-urltxt-urltest-members-clean:OK' || echo 'tl-urltxt-urltest-members-clean:FAIL'

# selector built over [members + urltest tag].
printf '%s' "$config" | jq -e '[.outbounds[] | select(.type=="selector")][0].outbounds as $o | ($o | index("urltxt-1-out")!=null) and ($o | index("urltxt-urltest-out")!=null)' >/dev/null 2>&1 \
    && echo 'tl-urltxt-selector-over-urltest:OK' || echo 'tl-urltxt-selector-over-urltest:FAIL'

check_full "$config" "tl-urltxt-singbox-check"

# ── _check_outbound_section returns 0 for a non-empty text option ────────────
# Pull in the requirements-check chain verbatim and stub config_foreach to drive
# our single section through it.
eval "$(awk '/^section_has_configured_outbound\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^_check_outbound_section\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^has_outbound_section\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
get_subscription_urls_for_section() { :; }
config_foreach() { "$1" "chk_seltxt"; "$1" "chk_urltxt"; }

TL_chk_seltxt_connection_type="proxy"
TL_chk_seltxt_proxy_config_type="selector_text"
TL_chk_seltxt_selector_proxy_links_text="vless://11111111-2222-3333-4444-555555555555@v1.example.com:443"
section_has_configured_outbound "chk_seltxt" \
    && echo 'tl-check-seltxt-found:OK' || echo 'tl-check-seltxt-found:FAIL'

TL_chk_urltxt_connection_type="proxy"
TL_chk_urltxt_proxy_config_type="urltest_text"
TL_chk_urltxt_urltest_proxy_links_text="vless://11111111-2222-3333-4444-555555555555@v1.example.com:443"
section_has_configured_outbound "chk_urltxt" \
    && echo 'tl-check-urltxt-found:OK' || echo 'tl-check-urltxt-found:FAIL'

rm -f "$WARN_LOG"
echo 'DONE'
TLEOF
    sed -i "s|CONST_LIB|$lib/constants.sh|g; s|FACADE_LIB|$facade_lib|g; s|BIN_PATH|$bin|g" "$drv"

    # Run the driver to a RESULT FILE, then consume tokens in the CURRENT shell
    # (while read < file — NO pipe) so pass/fail mutate the real counters/gate.
    sh "$drv" > "$out" 2>/dev/null
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK)   pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE)   saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "tl-driver-completed:OK"
    else
        fail "tl-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Ruleset import chunk-size default (upstream port 0c99ddd)
#
# Pins the ported chunking default: import_plain_domain_list_to_local_source_
# ruleset_chunked and import_plain_subnet_list_to_local_source_ruleset_chunked
# must patch the ruleset in 1000-element chunks (upstream lowered this from
# 5000; `chunk_size="${3:-1000}"`). The driver sources the REAL rulesets.sh from
# the read-only mount, neutralizes log + the validators, and replaces the jq
# patch step with a call logger. 2500 domains and 2500 IPv4 /32 entries must
# each produce exactly 3 calls — 1000 + 1000 + 500 — with keys domain_suffix /
# ip_cidr. Reverting the default to 5000 collapses each import into a single
# 2500-element call and FAILs both the call-count and the size assertions.
#
# IMPORTANT (gating): the driver appends its call log to a FILE and the
# assertions are consumed in the CURRENT shell via `while read < file` (NOT
# `cmd | while`), so pass/fail mutate the real PASS/FAIL counters and this test
# actually GATES the suite.
# ─────────────────────────────────────────────────────────────────
test_ruleset_chunk_size() {
    header "Ruleset Chunk Size Default (upstream 0c99ddd)"

    local lib="${NETSHIFT_LIB_DIR}/rulesets.sh"
    if [ ! -r "$lib" ]; then
        skip "rulesets.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-chunkcheck-$$"
    rm -rf "$work"
    mkdir -p "$work"

    # 2500 domains (site1..site2500.example.com) and 2500 IPv4 /32 entries:
    # with the 1000 default each import splits 1000/1000/500.
    local domlist="$work/domains.txt"
    local netlist="$work/subnets.txt"
    local domout="$work/dom.ruleset.json"
    local netout="$work/net.ruleset.json"
    local calllog="$work/calls.log"
    : > "$calllog"
    local i=1
    while [ "$i" -le 2500 ]; do
        printf 'site%d.example.com\n' "$i" >> "$domlist"
        printf '10.0.%d.%d/32\n' "$((i / 256))" "$((i % 256))" >> "$netlist"
        i=$((i + 1))
    done

    # Driver: source the REAL importers with neutralized dependencies; replace
    # the jq patch with a logger writing "<key>:<element-count>" per call.
    local drv="$work/driver.sh"
    cat > "$drv" << 'CHUNKEOF'
log() { :; }
is_domain_suffix() { return 0; }
is_ipv4() { return 0; }
is_ipv4_cidr() { return 0; }
# helpers.sh is not sourced here, so the case-normalization helper the importer
# now calls (issue #52) is stubbed with its real one-liner body: the chunk test
# cares about chunk sizes, not about case.
normalize_domain_case() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

. "RULESETS_LIB"

# Minimal stand-in for helpers.sh's comma_string_to_json_array (helpers.sh is
# not sourced here); only the comma count survives into the patch logger.
comma_string_to_json_array() {
    local input="$1"
    if [ -z "$input" ]; then
        printf '[]'
        return
    fi
    printf '["%s"]\n' "$(printf '%s' "$input" | sed 's/,/","/g')"
}

# Replaces the real jq patch step: log the key ($2) and the element count of
# the JSON array ($3, comma-separated -> awk field count).
patch_source_ruleset_rules() {
    local count
    count=$(printf '%s' "$3" | awk -F, '{print NF}')
    printf '%s:%s\n' "$2" "$count" >> "CHUNK_LOG"
}

import_plain_domain_list_to_local_source_ruleset_chunked "DOM_LIST" "DOM_OUT"
import_plain_subnet_list_to_local_source_ruleset_chunked "NET_LIST" "NET_OUT"
printf 'DONE\n' >> "CHUNK_LOG"
CHUNKEOF
    sed -i "s|RULESETS_LIB|$lib|g; s|CHUNK_LOG|$calllog|g; s|DOM_LIST|$domlist|g; s|NET_LIST|$netlist|g; s|DOM_OUT|$domout|g; s|NET_OUT|$netout|g" "$drv"

    sh "$drv" > /dev/null 2>&1 || true

    # Consume the call log in the CURRENT shell (no pipe) so the counters gate.
    local line
    local dom_calls=0 dom_sizes="" net_calls=0 net_sizes="" other_lines=0 saw_done=0
    while IFS= read -r line; do
        case "$line" in
            DONE) saw_done=1 ;;
            domain_suffix:*)
                dom_calls=$((dom_calls + 1))
                dom_sizes="$dom_sizes ${line#domain_suffix:}"
                ;;
            ip_cidr:*)
                net_calls=$((net_calls + 1))
                net_sizes="$net_sizes ${line#ip_cidr:}"
                ;;
            *) other_lines=$((other_lines + 1)) ;;
        esac
    done < "$calllog"

    if [ "$dom_calls" = "3" ]; then
        pass "chunk-domain-calls-3:OK"
    else
        fail "chunk-domain-calls-3:FAIL" "domain_suffix patches=$dom_calls (want 3)"
    fi

    if [ "$dom_sizes" = " 1000 1000 500" ]; then
        pass "chunk-domain-sizes-1000-1000-500:OK"
    else
        fail "chunk-domain-sizes-1000-1000-500:FAIL" "sizes=[$dom_sizes]"
    fi

    if [ "$net_calls" = "3" ]; then
        pass "chunk-subnet-calls-3:OK"
    else
        fail "chunk-subnet-calls-3:FAIL" "ip_cidr patches=$net_calls (want 3)"
    fi

    if [ "$net_sizes" = " 1000 1000 500" ]; then
        pass "chunk-subnet-sizes-1000-1000-500:OK"
    else
        fail "chunk-subnet-sizes-1000-1000-500:FAIL" "sizes=[$net_sizes]"
    fi

    if [ "$other_lines" = "0" ]; then
        pass "chunk-only-domain-suffix-ip-cidr-keys:OK"
    else
        fail "chunk-only-domain-suffix-ip-cidr-keys:FAIL" "unexpected log lines=$other_lines"
    fi

    if [ "$saw_done" = "1" ]; then
        pass "chunk-driver-completed:OK"
    else
        fail "chunk-driver-completed:FAIL (driver aborted early)"
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Domain case normalization (issue #52)
#
# ROOT CAUSE: the LuCI validators accept [a-zA-Z] in a domain, but the backend
# is_domain() only matches [a-z0-9]. A user domain typed as "Example.COM" was
# therefore dropped by parse_domain_or_subnet_file_to_comma_string() with a
# debug-only log and no rule was ever created, while the UI reported the value
# as valid.
#
# The fix lowercases every user-supplied domain before validation (helpers.sh:
# normalize_domain_case, used by the user-list parser and by the plain-list
# importer in rulesets.sh), so the stored rule is always "example.com".
#
# This test drives the SHIPPED code — parse_domain_or_subnet_string_to_commas_
# string, the awk-extracted configure_user_domain_list and import_plain_domain_
# list_to_local_source_ruleset_chunked — with the REAL jq ruleset patcher, for
# BOTH input modes (dynamic list / text list) and for a plain list file, and
# asserts the mixed-case domain survives as lowercase while invalid entries
# ("example.com/path", "exa!mple.com") are still dropped.
#
# UPGRADE SIMULATION: the driver's config_get stub carries ONLY the pre-existing
# UCI keys (no new option exists for this fix), i.e. exactly what an upgraded
# router has in /etc/config/netshift. Scenario 4 runs with the domain option
# absent altogether, and every produced source ruleset is fed to a real
# `sing-box check` — an upgraded config still builds a valid sing-box config.
# ─────────────────────────────────────────────────────────────────
test_domain_case() {
    header "Domain case normalization (issue #52)"

    if ! command -v sing-box > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
        skip "sing-box / jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$lib/helpers.sh" ] || [ ! -r "$lib/rulesets.sh" ] || [ ! -r "$bin" ]; then
        fail "helpers.sh / rulesets.sh / bin not found"
        return
    fi

    local work="/tmp/netshift-domcase-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local drv="$work/driver.sh"
    cat > "$drv" << 'DOMCASEEOF'
HELPERS_LIB="HELPERS_PATH"
RULESETS_LIB="RULESETS_PATH"
BIN_PATH="BIN_PATH_PLACEHOLDER"
LOGFILE="WORK_PATH/domcase.log"
RULESET_DIR="WORK_PATH/rulesets"

rm -rf "$RULESET_DIR"
mkdir -p "$RULESET_DIR"

. "$HELPERS_LIB"
. "$RULESETS_LIB"

: > "$LOGFILE"
log() { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOGFILE"; }

# awk-extract the SHIPPED user-domain ruleset builder verbatim.
eval "$(awk '/^configure_user_domain_list\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$BIN_PATH")"

# Real source-ruleset creation + real jq patcher (from rulesets.sh); only the
# bin-side wrapper that resolves the ruleset path and registers the rule_set in
# the sing-box config is stubbed (it is not what this test is about).
prepare_source_ruleset() {
    ruleset_filepath="$RULESET_DIR/$1-$2-$3.json"
    rm -f "$ruleset_filepath"
    create_source_rule_set "$ruleset_filepath"
}

# Table-driven stand-in for LuCI's config_get. Only the UCI keys an already
# released config carries are set: no option is added by this fix, so an
# upgraded router has exactly this shape.
config_get() {
    local _k _v
    _k="$(printf 'CFG_%s_%s' "$2" "$3" | tr -c 'a-zA-Z0-9_' '_')"
    eval "_v=\"\${$_k:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"\$_v\""
    return 0
}

domains_of() {
    jq -r '[.rules[]? | .domain_suffix[]?] | unique | join(",")' "$1" 2>/dev/null
}

has_domain() {
    jq -e --arg d "$2" '[.rules[]? | .domain_suffix[]?] | index($d) != null' "$1" > /dev/null 2>&1
}

all_lowercase() {
    jq -e 'all(.rules[]? | .domain_suffix[]?; . == (ascii_downcase))' "$1" > /dev/null 2>&1
}

# Diagnostics go on their own DIAG-prefixed lines: the consumer only counts
# lines ENDING in :OK / :FAIL, so a "label:FAIL (detail)" line would be ignored
# and could not gate the suite.
expect_domains() {
    if [ "$1" = "$2" ]; then
        echo "$3:OK"
    else
        echo "$3:FAIL"
        echo "DIAG $3 got=[$1] want=[$2]"
    fi
}

make_config() {
    jq -n --arg path "$1" '{
        log: { level: "error" },
        dns: { servers: [ { tag: "dns-server", type: "udp", server: "1.1.1.1" } ], final: "dns-server" },
        inbounds: [ { type: "tproxy", tag: "tproxy-in", listen: "127.0.0.1", listen_port: 1602 } ],
        outbounds: [ { type: "direct", tag: "direct-out" } ],
        route: {
            rule_set: [ { tag: "user-domains", type: "local", format: "source", path: $path } ],
            rules: [ { rule_set: ["user-domains"], outbound: "direct-out" } ],
            final: "direct-out"
        }
    }' > "$2" 2>/dev/null
}

check_sing_box() {
    local cfg="$RULESET_DIR/$1.json"
    make_config "$2" "$cfg"
    if sing-box -c "$cfg" check > /dev/null 2>&1; then
        echo "$1:OK"
    else
        echo "$1:FAIL"
        sing-box -c "$cfg" check 2>&1 | head -3 | sed 's/^/DIAG /'
    fi
    rm -f "$cfg"
}

# ── Scenario 1: dynamic list mode ───────────────────────────────────────────
CFG_s1_user_domain_list_type="dynamic"
CFG_s1_user_domains="Example.COM Sub.Example.ORG example.com/path exa!mple.com example.com"
configure_user_domain_list "s1" "route-rule-s1"
rs1="$RULESET_DIR/s1-user-domains.json"

expect_domains "$(domains_of "$rs1")" "example.com,sub.example.org" 'domcase-dynamic-domains'
has_domain "$rs1" "Example.COM" && echo 'domcase-dynamic-uppercase-absent:FAIL' || echo 'domcase-dynamic-uppercase-absent:OK'
has_domain "$rs1" "example.com/path" && echo 'domcase-dynamic-path-absent:FAIL' || echo 'domcase-dynamic-path-absent:OK'
has_domain "$rs1" "exa!mple.com" && echo 'domcase-dynamic-invalid-absent:FAIL' || echo 'domcase-dynamic-invalid-absent:OK'
all_lowercase "$rs1" && echo 'domcase-dynamic-all-lowercase:OK' || echo 'domcase-dynamic-all-lowercase:FAIL'
grep -q "example.com/path' is not a valid domain" "$LOGFILE" && echo 'domcase-dynamic-path-logged:OK' || echo 'domcase-dynamic-path-logged:FAIL'

check_sing_box 'domcase-dynamic-singbox-check' "$rs1"

# ── Scenario 2: text list mode ──────────────────────────────────────────────
CFG_s2_user_domain_list_type="text"
CFG_s2_user_domains_text="$(printf 'Example.COM, sub.Example.ORG // comment\nMixed.Case.NET test.com')"
configure_user_domain_list "s2" "route-rule-s2"
rs2="$RULESET_DIR/s2-user-domains.json"

expect_domains "$(domains_of "$rs2")" "example.com,mixed.case.net,sub.example.org,test.com" 'domcase-text-domains'
all_lowercase "$rs2" && echo 'domcase-text-all-lowercase:OK' || echo 'domcase-text-all-lowercase:FAIL'

check_sing_box 'domcase-text-singbox-check' "$rs2"

# ── Scenario 3: plain domain list file (local list / remote plain list) ─────
LISTFILE="$RULESET_DIR/list.txt"
printf 'Example.COM\nsub.Example.ORG\nexample.com\n\n' > "$LISTFILE"
rs3="$RULESET_DIR/s3-local-domains.json"
create_source_rule_set "$rs3"
import_plain_domain_list_to_local_source_ruleset_chunked "$LISTFILE" "$rs3"

expect_domains "$(domains_of "$rs3")" "example.com,sub.example.org" 'domcase-listfile-domains'
all_lowercase "$rs3" && echo 'domcase-listfile-all-lowercase:OK' || echo 'domcase-listfile-all-lowercase:FAIL'

# ── Scenario 4: upgrade simulation — old config, list enabled but empty ─────
# The UCI option is absent (exactly the upgraded-config case for a newly added
# option): building must not abort and the result must stay a valid config.
CFG_s4_user_domain_list_type="dynamic"
unset CFG_s4_user_domains
configure_user_domain_list "s4" "route-rule-s4"
rs4="$RULESET_DIR/s4-user-domains.json"
[ -f "$rs4" ] && echo 'domcase-empty-no-crash:OK' || echo 'domcase-empty-no-crash:FAIL'
check_sing_box 'domcase-empty-singbox-check' "$rs4"

echo 'DONE'
DOMCASEEOF
    sed -i "s|HELPERS_PATH|$lib/helpers.sh|; s|RULESETS_PATH|$lib/rulesets.sh|; s|BIN_PATH_PLACEHOLDER|$bin|; s|WORK_PATH|$work|g" "$drv"

    # Run the driver to a RESULT FILE, then consume tokens in the CURRENT shell
    # (while read < file — NO pipe) so pass/fail/skip mutate the real counters.
    local out="$work/out.log" saw_done=0 line
    sh "$drv" > "$out" 2>&1 || true
    while IFS= read -r line; do
        case "$line" in
            *:OK)   pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE)   saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "domcase-driver-completed:OK"
    else
        fail "domcase-driver-completed:FAIL (driver aborted early)"
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Monitor procd-lock fd hygiene (task-035) + monitor-leak (task-036)
#
# ROOT CAUSE under test: the long-lived health monitor used to be launched with
# a bare `monitor_sing_box &`, which inherited ALL open fds — including procd's
# init service lock on fd 1000 (/tmp/lock/procd_<name>.lock). The monitor then
# held that lock forever, so the NEXT reload/restart blocked on `flock 1000`
# indefinitely and settings were never re-applied.
#
# The fix launches the monitor via `setsid /bin/sh -c 'exec 1000>&- ...; exec
# /usr/bin/netshift __monitor' </dev/null >/dev/null 2>&1 &` so the detached
# monitor holds NO procd fds. This test reproduces the fd-inheritance scenario
# deterministically:
#   1. The parent opens fd 1000 onto a sentinel lock file and takes an exclusive
#      flock on it (exactly how procd serializes init actions).
#   2. We awk-extract the SHIPPED start_sing_box_monitor verbatim and run it with
#      MONITOR_PIDFILE re-pinned to a temp path and /usr/bin/netshift replaced by
#      a stub whose `__monitor` runs a tiny pid-writing sleep loop (so the real
#      launch mechanism — setsid + fd-close + re-exec — is exercised end to end).
#   3. Assert: the monitor child's /proc/<pid>/fd does NOT reference the sentinel
#      lock file (fd 1000 was closed), the monitor is alive, the pidfile is
#      correct, and a fresh non-blocking flock on the sentinel acquires
#      immediately (it WOULD block before the fix because the monitor inherited
#      the held lock).
#
# task-036 (monitor-leak follow-up): the task-035 detach is correct, but because
# each monitor self-writes its OWN $$ to MONITOR_PIDFILE, the pidfile only ever
# remembers the LATEST monitor; stop() kills only that pid, so monitors from
# PRIOR reloads (detached, reparented to init) leaked (2-3 live monitors). Fix:
# start_sing_box_monitor (and stop()) now run _kill_stale_sing_box_monitors,
# which kills ALL `__monitor` procs (excluding self/parent) via `pgrep -f`.
#   4. Launch the monitor a SECOND time (modeling a 2nd reload's start phase) and
#      assert the prior monitor is dead, EXACTLY ONE __monitor process survives
#      (no accumulation), and the respawned monitor also holds no lock fd.
# ─────────────────────────────────────────────────────────────────
test_monitor_fd_hygiene() {
    header "Monitor procd-lock fd Hygiene (task-035) + leak (task-036)"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ]; then
        skip "netshift bin not found"
        return
    fi
    if ! command -v setsid > /dev/null 2>&1; then
        skip "setsid not available"
        return
    fi
    if ! command -v flock > /dev/null 2>&1; then
        skip "flock not available"
        return
    fi

    local work="/tmp/netshift-monfd-$$"
    rm -rf "$work"
    mkdir -p "$work/bin"

    local pidfile="$work/monitor.pid"
    local lockfile="$work/procd_sentinel.lock"
    local fakecli="$work/bin/netshift"
    local out="$work/out.txt"
    local livefile="$work/live.txt"
    : > "$lockfile"

    # Stub /usr/bin/netshift: only its hidden `__monitor` path matters here. It
    # mimics the real monitor: write its own pid, then sleep-loop (so it is a
    # long-lived child we can inspect). It inherits MONITOR_PIDFILE via env.
    cat > "$fakecli" << 'FAKECLI'
#!/bin/sh
case "$1" in
__monitor)
    echo $$ > "$MONITOR_PIDFILE"
    while true; do sleep 1; done
    ;;
*)
    exit 0
    ;;
esac
FAKECLI
    chmod +x "$fakecli"

    # The shipped start_sing_box_monitor hardcodes `/usr/bin/netshift __monitor`.
    # Install the stub at that absolute path; back up any existing real binary
    # and restore it afterwards (the smoke container ships none, but be safe).
    local real_cli="/usr/bin/netshift"
    local real_cli_bak=""
    if [ -e "$real_cli" ]; then
        real_cli_bak="$work/real_cli.bak"
        cp -p "$real_cli" "$real_cli_bak" 2>/dev/null || real_cli_bak=""
    fi
    mkdir -p /usr/bin
    cp "$fakecli" "$real_cli"
    chmod +x "$real_cli"

    local drv="$work/driver.sh"
    cat > "$drv" << 'MONEOF'
# Quiet logger + the constant the extracted function references.
log() { :; }
MONITOR_PIDFILE="DRV_PIDFILE"

# Pull the SHIPPED helper + launcher out of the live bin so we test the real
# mechanism (task-036 leak fix: start_sing_box_monitor now calls
# _kill_stale_sing_box_monitors before spawning).
eval "$(awk '/^_kill_stale_sing_box_monitors\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "DRV_BIN")"
eval "$(awk '/^start_sing_box_monitor\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "DRV_BIN")"

# Simulate procd: open fd 1000 onto the sentinel lock file and hold an
# exclusive flock on it (this is exactly what procd does while running an init
# action). The launcher must NOT let the detached monitor inherit this fd.
exec 1000> "DRV_LOCKFILE"
flock -x 1000

# Launch the monitor via the SHIPPED code path (setsid + fd-close + re-exec).
start_sing_box_monitor

# Give the detached child a moment to write its pid (the launcher already waits,
# but the re-exec/setsid chain may lag slightly under the container).
i=0
while [ ! -s "$MONITOR_PIDFILE" ] && [ "$i" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done

mpid="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"

# ── Assert 1: pidfile populated with a live pid. ─────────────────────────────
if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
    echo 'monfd-monitor-alive-pidfile:OK'
else
    echo "monfd-monitor-alive-pidfile:FAIL (pid='$mpid')"
fi

# ── Assert 2: the monitor child does NOT have the sentinel lock fd open. We
#    resolve every /proc/<pid>/fd symlink and assert none points at the lock
#    file (the procd lock fd 1000 was closed before the re-exec). ─────────────
held=0
if [ -n "$mpid" ] && [ -d "/proc/$mpid/fd" ]; then
    for fd in /proc/"$mpid"/fd/*; do
        [ -e "$fd" ] || continue
        tgt="$(readlink "$fd" 2>/dev/null)"
        case "$tgt" in
            *procd_sentinel.lock*) held=1 ;;
        esac
    done
fi
if [ "$held" -eq 0 ]; then
    echo 'monfd-no-sentinel-lock-fd:OK'
else
    echo 'monfd-no-sentinel-lock-fd:FAIL (monitor still holds the lock fd)'
fi

# ── Assert 3: fd 1000 specifically is not the sentinel lock in the child. ────
if [ -n "$mpid" ] && [ -e "/proc/$mpid/fd/1000" ]; then
    t1000="$(readlink "/proc/$mpid/fd/1000" 2>/dev/null)"
    case "$t1000" in
        *procd_sentinel.lock*) echo 'monfd-fd1000-not-lock:FAIL' ;;
        *) echo 'monfd-fd1000-not-lock:OK' ;;
    esac
else
    echo 'monfd-fd1000-not-lock:OK'
fi

# ── Assert 4 (repeated-reload no-hang proxy): a fresh non-blocking flock on the
#    SAME sentinel must acquire immediately. Before the fix the inherited fd
#    1000 would keep the lock held by the live monitor and this would block /
#    fail. We drop the parent's own flock first (procd releases the lock when
#    the action returns), then a separate process tries flock -n. ─────────────
# Model procd ending the init action: it simply CLOSES its fd 1000 (it does NOT
# explicitly unlock). The advisory flock lives on the open-file-description, so
# if the monitor child inherited fd 1000 (the bug) the SAME OFD stays open in
# the child and the lock persists; with the fix the child never had that OFD, so
# closing the parent's fd here releases the lock. We must NOT `flock -u` (that
# would release the per-OFD lock for everyone and mask the bug).
exec 1000>&- 2>/dev/null
# A separate subshell opens its OWN fd onto the same lock file and tries a
# non-blocking exclusive flock. If the detached monitor still held the lock
# (the bug), this blocks/fails; with the fix it acquires instantly.
if ( exec 9> "DRV_LOCKFILE"; flock -n -x 9 ) 2>/dev/null; then
    echo 'monfd-second-flock-immediate:OK'
else
    echo 'monfd-second-flock-immediate:FAIL (monitor still holds the lock)'
fi

# ── Assert 5 (task-036 monitor-leak fix): launching the monitor AGAIN (modeling
#    a SECOND reload's start phase) must reliably kill the prior monitor and
#    leave EXACTLY ONE __monitor process alive — no accumulation. Before the fix
#    (return-0-if-alive + pidfile-only kill) the first monitor leaked because the
#    pidfile only ever named the latest one. We count survivors via pgrep -f on
#    the unique `__monitor` marker, into a temp file + counted `while read` (no
#    pipe) so the count is exact. ─────────────────────────────────────────────
prev_mpid="$mpid"

# Model the REAL leak precondition: monitor A is still alive (from a prior
# reload cycle) but the pidfile no longer points at it — exactly what happens
# because each monitor overwrites the pidfile with its own $$, so A's pid record
# is lost once a later monitor wrote, and stop() then cleared the pidfile while
# killing only the LATEST pid. We simulate that by pointing the pidfile at a
# dead pid. With the OLD guard, the launcher would see a dead pidfile pid,
# `rm -f` it, and spawn B — leaving A orphaned (2 live monitors). The task-036
# kill-all must terminate A regardless of the pidfile.
echo 999999 > "$MONITOR_PIDFILE"   # a pid that is not alive

# Re-open + re-hold the sentinel lock to model procd serializing the 2nd action,
# so we also re-prove fd hygiene on the freshly spawned monitor.
exec 1000> "DRV_LOCKFILE"
flock -x 1000

start_sing_box_monitor

i=0
while [ ! -s "$MONITOR_PIDFILE" ] && [ "$i" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done
mpid2="$(cat "$MONITOR_PIDFILE" 2>/dev/null)"

# The previous monitor must be dead (reliably killed before the new spawn).
if [ -n "$prev_mpid" ] && kill -0 "$prev_mpid" 2>/dev/null; then
    echo "monfd-prior-monitor-killed:FAIL (old pid $prev_mpid still alive)"
else
    echo 'monfd-prior-monitor-killed:OK'
fi

# Exactly one live __monitor process must remain. Count with pgrep -f (the same
# selector the fix uses) into a file, then a counted loop (no pipe).
livecount=0
livefile="DRV_LIVEFILE"
pgrep -f "/usr/bin/netshift __monitor" 2>/dev/null > "$livefile" || true
while IFS= read -r lp; do
    [ -n "$lp" ] || continue
    case "$lp" in *[!0-9]*) continue ;; esac
    if kill -0 "$lp" 2>/dev/null; then
        livecount=$((livecount + 1))
    fi
done < "$livefile"
if [ "$livecount" -eq 1 ]; then
    echo 'monfd-exactly-one-monitor:OK'
else
    echo "monfd-exactly-one-monitor:FAIL (found $livecount live monitors)"
fi

# The freshly spawned (2nd) monitor must also hold NO sentinel lock fd.
held2=0
if [ -n "$mpid2" ] && [ -d "/proc/$mpid2/fd" ]; then
    for fd in /proc/"$mpid2"/fd/*; do
        [ -e "$fd" ] || continue
        tgt="$(readlink "$fd" 2>/dev/null)"
        case "$tgt" in
            *procd_sentinel.lock*) held2=1 ;;
        esac
    done
fi
if [ "$held2" -eq 0 ]; then
    echo 'monfd-respawn-no-lock-fd:OK'
else
    echo 'monfd-respawn-no-lock-fd:FAIL (respawned monitor holds the lock fd)'
fi

exec 1000>&- 2>/dev/null

# Clean up the monitor child(ren).
[ -n "$mpid2" ] && kill "$mpid2" 2>/dev/null
[ -n "$prev_mpid" ] && kill "$prev_mpid" 2>/dev/null
echo 'DONE'
MONEOF

    sed -i \
        -e "s|DRV_PIDFILE|$pidfile|g" \
        -e "s|DRV_BIN|$bin|g" \
        -e "s|DRV_LOCKFILE|$lockfile|g" \
        -e "s|DRV_LIVEFILE|$livefile|g" \
        "$drv"

    MONITOR_PIDFILE="$pidfile" ash "$drv" > "$out" 2>/dev/null || true

    # Parse in the CURRENT shell (no pipe) so PASS/FAIL counts are exact.
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            *) ;;
        esac
    done < "$out"

    # Belt-and-suspenders: kill any leftover stub monitor and restore the cli.
    if [ -s "$pidfile" ]; then
        local leftover
        leftover="$(cat "$pidfile" 2>/dev/null)"
        [ -n "$leftover" ] && kill "$leftover" 2>/dev/null || true
    fi
    if [ -n "$real_cli_bak" ]; then
        cp -p "$real_cli_bak" "$real_cli" 2>/dev/null || true
    else
        rm -f "$real_cli" 2>/dev/null || true
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: sing-box Config Generation
# ─────────────────────────────────────────────────────────────────
test_sing_box_config() {
    header "sing-box Config Generation"

    if ! command -v sing-box > /dev/null 2>&1; then
        skip "sing-box not installed"
        return
    fi

    # Create a minimal valid sing-box config and validate it
    local test_config="/tmp/test-sing-box-config.json"
    jq -n '{
        log: { disabled: false, level: "warn", timestamp: true },
        dns: { servers: [], rules: [], final: "direct", strategy: "prefer_ipv4", independent_cache: true },
        ntp: {},
        inbounds: [
            { type: "direct", tag: "dns-in", listen: "127.0.0.42", listen_port: 53 }
        ],
        outbounds: [
            { type: "direct", tag: "direct-out" }
        ],
        route: { rules: [], rule_set: [], final: "direct-out", auto_detect_interface: true }
    }' > "$test_config"

    if sing-box -c "$test_config" check > /dev/null 2>&1; then
        pass "sing-box validates minimal config"
    else
        fail "sing-box config validation failed" "$(sing-box -c "$test_config" check 2>&1)"
    fi

    # Test with FakeIP
    jq '.dns.servers += [{
        type: "fakeip", tag: "fakeip", inet4_range: "198.18.0.0/15"
    }]' "$test_config" > "${test_config}.2"

    if sing-box -c "${test_config}.2" check > /dev/null 2>&1; then
        pass "sing-box validates config with FakeIP"
    else
        fail "sing-box FakeIP config failed"
    fi

    # Test with TProxy inbound
    jq '.inbounds += [{
        type: "tproxy", tag: "tproxy-in",
        listen: "127.0.0.1", listen_port: 1602,
        tcp_fast_open: true, udp_fragment: true
    }]' "$test_config" > "${test_config}.3"

    if sing-box -c "${test_config}.3" check > /dev/null 2>&1; then
        pass "sing-box validates config with TProxy"
    else
        fail "sing-box TProxy config failed"
    fi

    # Test with inline ruleset (DoH blocking)
    jq '.route.rule_set += [{
        type: "inline", tag: "doh-block",
        rules: [{ ip_cidr: ["1.1.1.1/32", "8.8.8.8/32", "2606:4700:4700::1111/128", "2001:4860:4860::8888/128"] }]
    }]' "$test_config" > "${test_config}.4"

    if sing-box -c "${test_config}.4" check > /dev/null 2>&1; then
        pass "sing-box validates inline ruleset (DoH block)"
    else
        fail "sing-box inline ruleset failed"
    fi

    # Test with IPv6 fakeip
    jq '.dns.servers[0].inet6_range = "fd00:ec3a::/32"' "${test_config}.2" > "${test_config}.5"

    if sing-box -c "${test_config}.5" check > /dev/null 2>&1; then
        pass "sing-box validates config with IPv6 FakeIP"
    else
        fail "sing-box IPv6 FakeIP failed"
    fi

    rm -f "$test_config" "${test_config}.2" "${test_config}.3" "${test_config}.4" "${test_config}.5"

    # ── VMess vmess://base64(JSON) parse path (facade) ─────────────────────
    # Validate the GENERATED outbound JSON SHAPE with jq (NOT a live sing-box
    # check): the test container's sing-box is the stock build, which rejects
    # the vmess type, so we assert shape only. The extended gate is exercised
    # by toggling is_sing_box_extended via a shell override.
    local facade_lib="${NETSHIFT_LIB_DIR}/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ]; then
        fail "sing_box_config_facade.sh not found"
        return
    fi

    # The facade hardcodes NETSHIFT_LIB="/usr/lib/netshift" for its own sourcing
    # of helpers.sh + sing_box_config_manager.sh; bind the bind-mounted sources
    # to that runtime path so the facade resolves them in the container.
    mkdir -p /usr/lib/netshift
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local vm_tmp="/tmp/test-vmess-facade-$$.sh"
    cat > "$vm_tmp" << 'VMEOF'
# logging.sh is sourced by /usr/bin/netshift in production; the facade itself
# only sources helpers + manager, so pull it in for log() here.
. "NETSHIFT_LIB/logging.sh" 2>/dev/null || log() { :; }
. "FACADE_LIB_PATH"

base_config='{"outbounds":[]}'

# ws + tls synthetic link: base64(JSON). aid=0 must be omitted.
ws_json='{"v":"2","ps":"node-ws","add":"ws.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","host":"ws.example.com","path":"/wspath","tls":"tls","sni":"sni.example.com","alpn":"h2,http/1.1","fp":"chrome"}'
ws_link="vmess://$(printf '%s' "$ws_json" | base64 | tr -d '\n')"

# plain tcp synthetic link: no transport, no tls.
tcp_json='{"v":"2","ps":"node-tcp","add":"tcp.example.com","port":"8080","id":"99999999-8888-7777-6666-555555555555","aid":"0","scy":"auto","net":"tcp","host":"","path":"","tls":"","sni":"","alpn":"","fp":""}'
tcp_link="vmess://$(printf '%s' "$tcp_json" | base64 | tr -d '\n')"

# task-012: a key with a trailing '#fragment' (server display name / remark,
# like the user's real key `...In0=#🇳🇱Ne`). The '#' + emoji/Cyrillic bytes must
# be STRIPPED before base64 decode; the canonical name still comes from `ps`.
frag_json='{"v":"2","ps":"node-frag","add":"frag.example.com","port":"443","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","aid":"0","scy":"auto","net":"ws","host":"frag.example.com","path":"/fragpath","tls":"tls","sni":"frag.example.com","alpn":"","fp":""}'
frag_link="vmess://$(printf '%s' "$frag_json" | base64 | tr -d '\n')#🇳🇱Ne"
# Sanity: confirm the crafted link actually carries a '#fragment'.
case "$frag_link" in
*#*) echo 'vmess-frag-link-has-hash:OK' ;;
*) echo 'vmess-frag-link-has-hash:FAIL' ;;
esac

# REGRESSION (S1): a key whose STANDARD base64 body DELIBERATELY contains a '+'.
# The "node>>" ps label (bytes 0x3E 0x3E) forces a base64 group that maps to
# '+' (alphabet index 62). If the facade url_decode'd the link before decoding,
# the '+'->space rewrite would corrupt the body and base64 -d would fail/garble,
# so this outbound would NOT be generated. Asserting server/uuid here proves the
# raw-link threading keeps '+' intact.
plus_json='{"v":"2","ps":"node>>","add":"plus.example.com","port":"2053","id":"abcdef00-1111-2222-3333-444455556666","aid":"0","scy":"auto","net":"tcp","host":"","path":"","tls":"","sni":"","alpn":"","fp":""}'
plus_link="vmess://$(printf '%s' "$plus_json" | base64 | tr -d '\n')"
# Sanity: confirm the crafted base64 body actually contains a '+'.
case "$plus_link" in
*+*) echo 'vmess-plus-body-has-plus:OK' ;;
*) echo 'vmess-plus-body-has-plus:FAIL' ;;
esac

# ── Extended ON: parse path produces a real vmess outbound ──
is_sing_box_extended() { return 0; }

out_ws=$(sing_box_cf_add_proxy_outbound "$base_config" "vmess_ws" "$ws_link" "0")
echo "$out_ws" | jq -e '.outbounds[0].type == "vmess"' >/dev/null 2>&1 && echo 'vmess-ws-type:OK' || echo 'vmess-ws-type:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].server == "ws.example.com"' >/dev/null 2>&1 && echo 'vmess-ws-server:OK' || echo 'vmess-ws-server:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].server_port == 443' >/dev/null 2>&1 && echo 'vmess-ws-port:OK' || echo 'vmess-ws-port:FAIL'
echo "$out_ws" | jq -e '.outbounds[0] | has("alter_id") | not' >/dev/null 2>&1 && echo 'vmess-ws-aid-omitted:OK' || echo 'vmess-ws-aid-omitted:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].transport.type == "ws"' >/dev/null 2>&1 && echo 'vmess-ws-transport:OK' || echo 'vmess-ws-transport:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].transport.path == "/wspath"' >/dev/null 2>&1 && echo 'vmess-ws-path:OK' || echo 'vmess-ws-path:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].transport.headers.Host == "ws.example.com"' >/dev/null 2>&1 && echo 'vmess-ws-host:OK' || echo 'vmess-ws-host:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].tls.enabled == true' >/dev/null 2>&1 && echo 'vmess-ws-tls:OK' || echo 'vmess-ws-tls:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].tls.server_name == "sni.example.com"' >/dev/null 2>&1 && echo 'vmess-ws-sni:OK' || echo 'vmess-ws-sni:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].tls.alpn == ["h2","http/1.1"]' >/dev/null 2>&1 && echo 'vmess-ws-alpn:OK' || echo 'vmess-ws-alpn:FAIL'
echo "$out_ws" | jq -e '.outbounds[0].tls.utls.fingerprint == "chrome"' >/dev/null 2>&1 && echo 'vmess-ws-fp:OK' || echo 'vmess-ws-fp:FAIL'

out_tcp=$(sing_box_cf_add_proxy_outbound "$base_config" "vmess_tcp" "$tcp_link" "0")
echo "$out_tcp" | jq -e '.outbounds[0].type == "vmess"' >/dev/null 2>&1 && echo 'vmess-tcp-type:OK' || echo 'vmess-tcp-type:FAIL'
echo "$out_tcp" | jq -e '.outbounds[0] | has("transport") | not' >/dev/null 2>&1 && echo 'vmess-tcp-no-transport:OK' || echo 'vmess-tcp-no-transport:FAIL'
echo "$out_tcp" | jq -e '.outbounds[0] | has("tls") | not' >/dev/null 2>&1 && echo 'vmess-tcp-no-tls:OK' || echo 'vmess-tcp-no-tls:FAIL'
echo "$out_tcp" | jq -e '.outbounds[0].security == "auto"' >/dev/null 2>&1 && echo 'vmess-tcp-security:OK' || echo 'vmess-tcp-security:FAIL'

# ── REGRESSION (S1): '+'-in-base64 link must parse via the RAW link ──
out_plus=$(sing_box_cf_add_proxy_outbound "$base_config" "vmess_plus" "$plus_link" "0")
echo "$out_plus" | jq -e '.outbounds[0].type == "vmess"' >/dev/null 2>&1 && echo 'vmess-plus-type:OK' || echo 'vmess-plus-type:FAIL'
echo "$out_plus" | jq -e '.outbounds[0].server == "plus.example.com"' >/dev/null 2>&1 && echo 'vmess-plus-server:OK' || echo 'vmess-plus-server:FAIL'
echo "$out_plus" | jq -e '.outbounds[0].server_port == 2053' >/dev/null 2>&1 && echo 'vmess-plus-port:OK' || echo 'vmess-plus-port:FAIL'
echo "$out_plus" | jq -e '.outbounds[0].uuid == "abcdef00-1111-2222-3333-444455556666"' >/dev/null 2>&1 && echo 'vmess-plus-uuid:OK' || echo 'vmess-plus-uuid:FAIL'

# ── task-012: '#fragment' link must parse (fragment stripped before decode) ──
out_frag=$(sing_box_cf_add_proxy_outbound "$base_config" "vmess_frag" "$frag_link" "0")
echo "$out_frag" | jq -e '.outbounds[0].type == "vmess"' >/dev/null 2>&1 && echo 'vmess-frag-type:OK' || echo 'vmess-frag-type:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].server == "frag.example.com"' >/dev/null 2>&1 && echo 'vmess-frag-server:OK' || echo 'vmess-frag-server:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].server_port == 443' >/dev/null 2>&1 && echo 'vmess-frag-port:OK' || echo 'vmess-frag-port:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].uuid == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"' >/dev/null 2>&1 && echo 'vmess-frag-uuid:OK' || echo 'vmess-frag-uuid:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].transport.type == "ws"' >/dev/null 2>&1 && echo 'vmess-frag-transport:OK' || echo 'vmess-frag-transport:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].transport.path == "/fragpath"' >/dev/null 2>&1 && echo 'vmess-frag-path:OK' || echo 'vmess-frag-path:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].tls.enabled == true' >/dev/null 2>&1 && echo 'vmess-frag-tls:OK' || echo 'vmess-frag-tls:FAIL'
echo "$out_frag" | jq -e '.outbounds[0].tls.server_name == "frag.example.com"' >/dev/null 2>&1 && echo 'vmess-frag-sni:OK' || echo 'vmess-frag-sni:FAIL'

# ── Extended OFF: gate returns config UNCHANGED (no vmess outbound) ──
is_sing_box_extended() { return 1; }
out_gate=$(sing_box_cf_add_proxy_outbound "$base_config" "vmess_gate" "$ws_link" "0")
gate_rc=$?
echo "$out_gate" | jq -e '.outbounds | length == 0' >/dev/null 2>&1 && echo 'vmess-gate-unchanged:OK' || echo 'vmess-gate-unchanged:FAIL'
# Non-zero, so selector/urltest callers do not add a member tag for it.
[ "$gate_rc" != "0" ] && echo 'vmess-gate-nonzero:OK' || echo 'vmess-gate-nonzero:FAIL (rc=0)'

echo 'DONE'
VMEOF
    sed -i "s|FACADE_LIB_PATH|$facade_lib|; s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g" "$vm_tmp"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite.
    local vm_out="/tmp/test-vmess-out-$$.log"
    sh "$vm_tmp" > "$vm_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$vm_out"
    if [ "$saw_done" = "1" ]; then
        pass "vmess-driver-completed:OK"
    else
        fail "vmess-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$vm_tmp" "$vm_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Proxy Link Escaping (issue #50)
# ─────────────────────────────────────────────────────────────────
# The link must be parsed as a URI FIRST and only then must its components be
# percent-decoded. Decoding the whole link up front turned an escaped '%40' /
# '%23' inside a password into a structural '@' / '#' (wrong split point, or the
# fragment stripping everything after it) and rewrote a literal '+' into a space.
#
# Upgrade safety: this fix adds NO new UCI option, so an existing (conffile)
# /etc/config/netshift is untouched by design. What must not change is the
# parsing of ordinary links, which the 'plain-link-unchanged' token pins down by
# comparing the generated outbound with the exact pre-fix JSON.
test_proxy_link_escaping() {
    header "Proxy Link Escaping (%40 / %23 / '+')"

    local facade_lib="${NETSHIFT_LIB_DIR}/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ]; then
        fail "sing_box_config_facade.sh not found"
        return
    fi

    # The facade hardcodes NETSHIFT_LIB="/usr/lib/netshift" for its own sourcing
    # of helpers.sh + sing_box_config_manager.sh; bind the bind-mounted sources
    # to that runtime path so the facade resolves them in the container.
    mkdir -p /usr/lib/netshift
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/test-proxy-link-$$.sh"
    cat > "$drv" << 'LINKEOF'
. "NETSHIFT_LIB/logging.sh" 2>/dev/null || log() { :; }
. "FACADE_LIB_PATH"

base='{"outbounds":[]}'

# check <token> <jq-filter> <link>
check() {
    tok="$1"; filt="$2"; link="$3"
    out=$(sing_box_cf_add_proxy_outbound "$base" "demo" "$link" "0" 2>/dev/null)
    if printf '%s' "$out" | jq -e "$filt" > /dev/null 2>&1; then
        echo "$tok:OK"
    else
        echo "$tok:FAIL (got=$(printf '%s' "$out" | jq -c '.outbounds[0] // .' 2>/dev/null))"
    fi
}

# ── issue #50 examples ───────────────────────────────────────────────
check trojan-pct40 '.outbounds[0].password == "abc@def" and .outbounds[0].server == "example.com" and .outbounds[0].server_port == 443' 'trojan://abc%40def@example.com:443?security=tls'
check trojan-plus '.outbounds[0].password == "abc+def"' 'trojan://abc+def@example.com:443?security=tls'
check trojan-pct23 '.outbounds[0].password == "abc#def" and .outbounds[0].server == "example.com" and .outbounds[0].server_port == 443' 'trojan://abc%23def@example.com:443?security=tls'
check trojan-mixed '.outbounds[0].password == "a@b#c+d"' 'trojan://a%40b%23c+d@example.com:443'
check trojan-utf8 '.outbounds[0].password == "пароль"' 'trojan://%D0%BF%D0%B0%D1%80%D0%BE%D0%BB%D1%8C@example.com:443'
check trojan-fragment '.outbounds[0].password == "abc@def"' 'trojan://abc%40def@example.com:443#DE%20Frankfurt'

# ── other schemes go through the same component extraction ───────────
check hy2-escaped-password '.outbounds[0].password == "p#ss@word+1"' 'hysteria2://p%23ss%40word+1@h.example.com:8443?sni=h.example.com'
check socks-escaped-password '.outbounds[0].username == "user" and .outbounds[0].password == "p@ss"' 'socks5://user:p%40ss@example.com:1080'

# Shadowsocks userinfo base64 contains '+' (base64 alphabet index 62): the body
# must survive verbatim, so this outbound can only be built from the raw link.
ss_b64=$(printf '%s' 'aes-256-gcm:ab>' | base64 | tr -d '\n')
case "$ss_b64" in
*+*) echo 'ss-base64-plus-fixture:OK' ;;
*) echo "ss-base64-plus-fixture:FAIL (b64=$ss_b64)" ;;
esac
check ss-base64-plus ".outbounds[0].method == \"aes-256-gcm\" and .outbounds[0].password == \"ab>\"" "ss://$ss_b64@ss.example.com:8388"

# ── query values: still decoded, legacy '+'->space preserved ─────────
check query-value-percent '.outbounds[0].transport.path == "/ws+path"' 'vless://11111111-2222-3333-4444-555555555555@v.example.com:443?security=tls&type=ws&path=%2Fws%2Bpath&host=cdn.example.com'
check query-value-plus-space '.outbounds[0].transport.path == "/a b"' 'vless://11111111-2222-3333-4444-555555555555@v.example.com:443?security=tls&type=ws&path=/a+b&host=cdn.example.com'

# ── upgrade safety: an ordinary link must yield the pre-fix JSON ─────
check plain-link-unchanged '.outbounds[0] == {"type":"trojan","tag":"demo-out","server":"example.com","server_port":443,"password":"pw","tls":{"enabled":true,"server_name":"example.com"}}' 'trojan://pw@example.com:443?security=tls&sni=example.com'

# ── the generated config must still pass sing-box check ──────────────
if command -v sing-box > /dev/null 2>&1; then
    for pw in 'abc%40def' 'abc%23def' 'abc+def'; do
        out=$(sing_box_cf_add_proxy_outbound "$base" "demo" "trojan://$pw@example.com:443?security=tls" 0 2>/dev/null)
        printf '%s' "$out" | jq -c '{log:{disabled:true,level:"warn"},outbounds:.outbounds}' > /tmp/proxy-link-check.json 2>/dev/null
        if sing-box -c /tmp/proxy-link-check.json check > /dev/null 2>&1; then
            echo "singbox-check-$pw:OK"
        else
            echo "singbox-check-$pw:FAIL ($(sing-box -c /tmp/proxy-link-check.json check 2>&1 | head -2 | tr '\n' ' '))"
        fi
    done
    rm -f /tmp/proxy-link-check.json
else
    echo 'singbox-check-pct23:SKIP'
fi

echo DONE
LINKEOF
    sed -i "s|FACADE_LIB_PATH|$facade_lib|; s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g" "$drv"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite.
    local link_out="/tmp/test-proxy-link-out-$$.log"
    sh "$drv" > "$link_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            # The driver appends the offending JSON in parentheses, so the FAIL
            # token is not at the end of the line (case patterns must match the
            # WHOLE line).
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$link_out"
    if [ "$saw_done" = "1" ]; then
        pass "proxy-link-driver-completed:OK"
    else
        fail "proxy-link-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$link_out" 2>/dev/null)"
    fi
    rm -f "$drv" "$link_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Diagnostics Commands
# ─────────────────────────────────────────────────────────────────
test_diagnostics() {
    header "Diagnostics Commands"

    if ! command -v sing-box > /dev/null 2>&1; then
        skip "sing-box not installed — skipping diagnostic tests"
        return
    fi

    # sing-box version
    if sing-box version > /dev/null 2>&1; then
        pass "sing-box version works"
    else
        fail "sing-box version failed"
    fi

    # sing-box check on empty config
    echo '{}' > /tmp/empty.json
    if sing-box -c /tmp/empty.json check > /dev/null 2>&1; then
        pass "sing-box check accepts empty config"
    else
        # This might fail — some versions require more structure
        pass "sing-box check rejects empty config (expected on newer versions)"
    fi
    rm -f /tmp/empty.json

    # dig
    if command -v dig > /dev/null 2>&1; then
        if dig +short +timeout=3 google.com > /dev/null 2>&1; then
            pass "dig DNS resolution works"
        else
            skip "dig DNS resolution (no network?)"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: jq Helpers
# ─────────────────────────────────────────────────────────────────
test_jq_helpers() {
    header "jq Helper Functions"

    local jq_helpers="${NETSHIFT_LIB_DIR}/helpers.jq"

    if [ ! -r "$jq_helpers" ]; then
        skip "helpers.jq not found"
        return
    fi

    # Production scripts import helpers.jq from /usr/lib/netshift. In the test
    # container sources are bind-mounted under /netshift/files, so provide the
    # runtime path as a symlink for jq module resolution.
    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq

    # Test the extend_key_value function. Keep the jq program in a file instead
    # of a shell variable because BusyBox ash can choke on jq syntax like
    # `h::extend_key_value(.; ...)` during script parsing in some builds.
    local jq_filter_file="/tmp/netshift-jq-filter-$$.jq"
    cat > "$jq_filter_file" << 'JQEOF'
import "helpers" as h;
[1,2,3] | h::extend_key_value(.; [4,5])
JQEOF
    local jq_error_file="/tmp/netshift-jq-error-$$.log"
    result=$(jq -n -L "/usr/lib/netshift" -f "$jq_filter_file" 2>"$jq_error_file" || true)
    rm -f "$jq_filter_file"
    
    if echo "$result" | jq -e '. | length == 5' > /dev/null 2>&1; then
        pass "helpers.jq extend_key_value merges arrays"
    else
        fail "helpers.jq extend_key_value failed" "got: $result $(cat "$jq_error_file" 2>/dev/null)"
    fi
    rm -f "$jq_error_file"
}

# ─────────────────────────────────────────────────────────────────
# Test: Config Manager JSON Generation
# ─────────────────────────────────────────────────────────────────
test_config_manager() {
    header "sing-box Config Manager (jq)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    # Test basic config operations by simulating the config manager pipeline
    local config
    config=$(jq -n '{
        log: {}, dns: {}, ntp: {}, certificate: {}, endpoints: [],
        inbounds: [], outbounds: [], route: {}, services: [], experimental: {}
    }')

    # Simulate adding a direct outbound
    config=$(echo "$config" | jq '.outbounds += [{ type: "direct", tag: "direct-out" }]')
    if echo "$config" | jq -e '.outbounds | length == 1' > /dev/null 2>&1; then
        pass "jq: direct outbound added to config"
    else
        fail "jq: direct outbound failed"
    fi

    # Simulate adding a TProxy inbound
    config=$(echo "$config" | jq '.inbounds += [{
        type: "tproxy", tag: "tproxy-in",
        listen: "127.0.0.1", listen_port: 1602,
        tcp_fast_open: true, udp_fragment: true
    }]')
    if echo "$config" | jq -e '.inbounds | length == 1' > /dev/null 2>&1; then
        pass "jq: TProxy inbound added to config"
    else
        fail "jq: TProxy inbound failed"
    fi

    # Simulate adding route rule
    config=$(echo "$config" | jq '.route.rules += [{
        action: "route", inbound: "tproxy-in", outbound: "direct-out"
    }]')
    if echo "$config" | jq -e '.route.rules | length == 1' > /dev/null 2>&1; then
        pass "jq: route rule added to config"
    else
        fail "jq: route rule failed"
    fi

    # ── VMess outbound primitive (sing_box_cm_add_vmess_outbound) ──────────
    local cm_lib="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    if [ ! -r "$cm_lib" ]; then
        fail "sing_box_config_manager.sh not found"
        return
    fi

    local cm_tmp="/tmp/test-cm-vmess-$$.sh"
    cat > "$cm_tmp" << 'CMEOF'
. "CM_LIB_PATH"

base_config='{"outbounds":[]}'

# Default security ("auto") + alter_id omitted when "0".
out=$(sing_box_cm_add_vmess_outbound "$base_config" "vmess-out" "example.com" "443" \
    "bf000d23-0752-40b4-affe-68f7707a9661" "" "0")
echo "$out" | jq -e '.outbounds[0].type == "vmess"' >/dev/null 2>&1 && echo 'cm-vmess-type:OK' || echo 'cm-vmess-type:FAIL'
echo "$out" | jq -e '.outbounds[0].server == "example.com"' >/dev/null 2>&1 && echo 'cm-vmess-server:OK' || echo 'cm-vmess-server:FAIL'
echo "$out" | jq -e '.outbounds[0].server_port == 443' >/dev/null 2>&1 && echo 'cm-vmess-port:OK' || echo 'cm-vmess-port:FAIL'
echo "$out" | jq -e '.outbounds[0].uuid == "bf000d23-0752-40b4-affe-68f7707a9661"' >/dev/null 2>&1 && echo 'cm-vmess-uuid:OK' || echo 'cm-vmess-uuid:FAIL'
echo "$out" | jq -e '.outbounds[0].security == "auto"' >/dev/null 2>&1 && echo 'cm-vmess-security-default:OK' || echo 'cm-vmess-security-default:FAIL'
echo "$out" | jq -e '.outbounds[0] | has("alter_id") | not' >/dev/null 2>&1 && echo 'cm-vmess-aid-omitted:OK' || echo 'cm-vmess-aid-omitted:FAIL'

# Explicit security + non-zero alter_id present as a number.
out2=$(sing_box_cm_add_vmess_outbound "$base_config" "vmess-out" "example.com" "443" \
    "bf000d23-0752-40b4-affe-68f7707a9661" "aes-128-gcm" "64")
echo "$out2" | jq -e '.outbounds[0].security == "aes-128-gcm"' >/dev/null 2>&1 && echo 'cm-vmess-security-explicit:OK' || echo 'cm-vmess-security-explicit:FAIL'
echo "$out2" | jq -e '.outbounds[0].alter_id == 64' >/dev/null 2>&1 && echo 'cm-vmess-aid-number:OK' || echo 'cm-vmess-aid-number:FAIL'

doh_cfg='{"route":{"rules":[],"rule_set":[]}}'
doh_out=$(sing_box_cm_add_doh_block_route_rule "$doh_cfg" "doh-block" "tproxy-in" \
    "1.1.1.1/32 8.8.8.8/32" "2606:4700:4700::1111/128 2001:4860:4860::8888/128")
echo "$doh_out" | jq -e '.route.rule_set[0].rules[0].ip_cidr | (index("1.1.1.1/32") != null) and (index("2606:4700:4700::1111/128") != null)' >/dev/null 2>&1 && echo 'cm-doh-cidrs-v4-v6:OK' || echo 'cm-doh-cidrs-v4-v6:FAIL'
echo "$doh_out" | jq -e '.route.rules[0].action == "reject" and .route.rules[0].rule_set == "doh-block-ruleset" and .route.rules[0].inbound == "tproxy-in"' >/dev/null 2>&1 && echo 'cm-doh-route-rule:OK' || echo 'cm-doh-route-rule:FAIL'

echo 'DONE'
CMEOF
    sed -i "s|CM_LIB_PATH|$cm_lib|" "$cm_tmp"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite.
    local cm_out="/tmp/test-cm-out-$$.log"
    sh "$cm_tmp" > "$cm_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$cm_out"
    if [ "$saw_done" = "1" ]; then
        pass "cm-driver-completed:OK"
    else
        fail "cm-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$cm_tmp" "$cm_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Subscription JSON Validation
# ─────────────────────────────────────────────────────────────────
test_subscription() {
    header "Subscription JSON Validation"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    # Create a valid subscription-like JSON
    local sub='{
        "outbounds": [
            {"type": "shadowsocks", "tag": "ss-01", "server": "example.com", "server_port": 443, "method": "aes-256-gcm", "password": "test"},
            {"type": "vless", "tag": "vl-01", "server": "vless.example.com", "server_port": 443, "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": "example.com"}},
            {"type": "trojan", "tag": "tj-01", "server": "trojan.example.com", "server_port": 443, "password": "test"},
            {"type": "hysteria2", "tag": "hy2-01", "server": "hysteria.example.com", "server_port": 443, "password": "test"},
            {"type": "selector", "tag": "select", "outbounds": ["ss-01", "vl-01"]},
            {"type": "urltest", "tag": "auto", "outbounds": ["ss-01", "vl-01"]},
            {"type": "direct", "tag": "direct"},
            {"type": "dns", "tag": "dns"},
            {"type": "block", "tag": "block"}
        ]
    }'

    # Count proxy outbounds (exclude selector, urltest, direct, dns, block)
    local proxy_count
    local proxy_filter_file="/tmp/netshift-proxy-filter-$$.jq"
    cat > "$proxy_filter_file" << 'JQEOF'
[.outbounds[] | select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "dns" and .type != "block")] | length
JQEOF
    proxy_count=$(echo "$sub" | jq -f "$proxy_filter_file")
    rm -f "$proxy_filter_file"

    if [ "$proxy_count" -eq 4 ]; then
        pass "Subscription proxy count correct: $proxy_count (ss + vless + trojan + hysteria2)"
    else
        fail "Subscription proxy count wrong: expected 4, got $proxy_count"
    fi

    # Test filtering for subscription outbound tags
    local outbound_tags
    local tags_filter_file="/tmp/netshift-tags-filter-$$.jq"
    cat > "$tags_filter_file" << 'JQEOF'
[.outbounds[] | select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "dns" and .type != "block") | .tag]
JQEOF
    outbound_tags=$(echo "$sub" | jq -c -f "$tags_filter_file")
    rm -f "$tags_filter_file"

    if echo "$outbound_tags" | jq -e 'length == 4' > /dev/null 2>&1; then
        pass "Subscription outbound tags extracted correctly"
    else
        fail "Subscription outbound tags extraction failed"
    fi

    # Test country flag extraction from tags
    # Build tags with actual Unicode regional indicator flags
    local country_test
    local flag_filter_file="/tmp/netshift-flag-filter-$$.jq"
    cat > "$flag_filter_file" << 'JQEOF'
def flag($l1; $l2): ([127462 + $l1, 127462 + $l2] | implode);
[(flag(3; 4) + " Frankfurt"), (flag(20; 18) + " New York"), (flag(13; 11) + " Amsterdam"), (flag(9; 15) + " Tokyo"), "no-flag"]
JQEOF
    country_test=$(jq -cn -f "$flag_filter_file")
    rm -f "$flag_filter_file"

    local grouping
    local group_filter_file="/tmp/netshift-group-filter-$$.jq"
    cat > "$group_filter_file" << 'JQEOF'
def is_regional_indicator: . >= 127462 and . <= 127487;
def extract_country_flag:
  (. | explode) as $codepoints
  | if ($codepoints | length) >= 2
      and ($codepoints[0] | is_regional_indicator)
      and ($codepoints[1] | is_regional_indicator)
    then ($codepoints[0:2] | implode)
    else "" end;
(if type == "array" then . else [] end) as $tags
| reduce $tags[] as $tag (
    {count: 0, ungrouped: 0};
    ($tag | extract_country_flag) as $flag
    | if $flag == "" then .ungrouped += 1 else .count += 1 end
  )
JQEOF
    grouping=$(echo "$country_test" | jq -c -f "$group_filter_file")
    rm -f "$group_filter_file"

    local grouped
    grouped=$(echo "$grouping" | jq -r '.count')
    local ungrouped
    ungrouped=$(echo "$grouping" | jq -r '.ungrouped')

    if [ "$grouped" -eq 4 ] && [ "$ungrouped" -eq 1 ]; then
        pass "Country flag grouping: $grouped grouped, $ungrouped ungrouped"
    else
        fail "Country flag grouping wrong: got $grouped grouped, $ungrouped ungrouped"
    fi

    # ── Universal grouper (task-044): prefix mode over synthetic tags ──────
    # Mirror the shipped sing_box_build_subscription_groups extractor in an
    # inline .jq so we exercise the exact mode-aware key logic without real
    # node names. Synthetic tags only.
    local grouper_filter_file="/tmp/netshift-grouper-filter-$$.jq"
    cat > "$grouper_filter_file" << 'JQEOF'
def is_regional_indicator: . >= 127462 and . <= 127487;
def extract_country_flag:
  (. | explode) as $codepoints
  | if ($codepoints | length) >= 2
      and ($codepoints[0] | is_regional_indicator)
      and ($codepoints[1] | is_regional_indicator)
    then ($codepoints[0:2] | implode)
    else "" end;
def extract_prefix($n):
  (. | explode) as $codepoints
  | if ($codepoints | length) == 0 then ""
    else ($codepoints[0:$n] | implode) end;
(try ($prefix_len | tonumber) catch $default_len) as $raw_len
| (if ($raw_len | type) != "number" or $raw_len < 1
    then $default_len else ($raw_len | floor) end) as $n
| (if type == "array" then . else [] end) as $tags
| reduce $tags[] as $tag (
    {group_order: [], groups: {}, ungrouped: []};
    (if $mode == "prefix" then ($tag | extract_prefix($n))
     else ($tag | extract_country_flag) end) as $key
    | if $key == "" then .ungrouped += [$tag]
      else
        .groups[$key] = ((.groups[$key] // []) + [$tag])
        | if (.group_order | index($key)) == null
            then .group_order += [$key] else . end
      end
  )
JQEOF

    # prefix-len 2 over synthetic tags: US(2), DE(1), short tag X keyed as X(1)
    local prefix_synth prefix_result prefix_groups prefix_us prefix_de prefix_x prefix_ungrouped
    prefix_synth='["US-01","US-02","DE-01","X"]'
    prefix_result=$(echo "$prefix_synth" | jq -c \
        --arg mode "prefix" --arg prefix_len "2" --argjson default_len 2 \
        -f "$grouper_filter_file")
    prefix_groups=$(echo "$prefix_result" | jq -r '.group_order | length')
    prefix_us=$(echo "$prefix_result" | jq -r '.groups["US"] | length')
    prefix_de=$(echo "$prefix_result" | jq -r '.groups["DE"] | length')
    prefix_x=$(echo "$prefix_result" | jq -r '.groups["X"] | length')
    prefix_ungrouped=$(echo "$prefix_result" | jq -r '.ungrouped | length')
    if [ "$prefix_groups" -eq 3 ] && [ "$prefix_us" -eq 2 ] && \
        [ "$prefix_de" -eq 1 ] && [ "$prefix_x" -eq 1 ] && [ "$prefix_ungrouped" -eq 0 ]; then
        pass "Prefix grouping (len 2): US=$prefix_us DE=$prefix_de X=$prefix_x, groups=$prefix_groups, ungrouped=$prefix_ungrouped"
    else
        fail "Prefix grouping (len 2) wrong: US=$prefix_us DE=$prefix_de X=$prefix_x groups=$prefix_groups ungrouped=$prefix_ungrouped"
    fi

    # Consistency: prefix-len 2 over flag-only tags == country grouping. A
    # flag is exactly 2 codepoints, so prefix-len-2 keys each flag tag by its
    # leading flag — identical group keys to country mode (the non-flag
    # "no-flag" element of country_test is excluded here, since under prefix
    # mode it would group by its first 2 chars instead of going ungrouped).
    local flag_only_test prefix_flag_result country_flag_result
    local flag_only_file="/tmp/netshift-flagonly-$$.jq"
    cat > "$flag_only_file" << 'JQEOF'
def flag($l1; $l2): ([127462 + $l1, 127462 + $l2] | implode);
[(flag(3; 4) + " Frankfurt"), (flag(20; 18) + " New York"), (flag(13; 11) + " Amsterdam"), (flag(9; 15) + " Tokyo")]
JQEOF
    flag_only_test=$(jq -cn -f "$flag_only_file")
    rm -f "$flag_only_file"
    prefix_flag_result=$(echo "$flag_only_test" | jq -c \
        --arg mode "prefix" --arg prefix_len "2" --argjson default_len 2 \
        -f "$grouper_filter_file")
    country_flag_result=$(echo "$flag_only_test" | jq -c \
        --arg mode "country" --arg prefix_len "2" --argjson default_len 2 \
        -f "$grouper_filter_file")
    if [ "$prefix_flag_result" = "$country_flag_result" ]; then
        pass "Prefix grouping consistency vs country: identical grouping over flag tags"
    else
        fail "Prefix grouping consistency vs country wrong: prefix=$prefix_flag_result country=$country_flag_result"
    fi

    # Bad/empty len must NOT crash; falls back to default 2.
    local prefix_badlen_result prefix_badlen_us prefix_emptylen_result prefix_emptylen_us
    prefix_badlen_result=$(echo "$prefix_synth" | jq -c \
        --arg mode "prefix" --arg prefix_len "abc" --argjson default_len 2 \
        -f "$grouper_filter_file" 2>/dev/null)
    prefix_badlen_us=$(echo "$prefix_badlen_result" | jq -r '.groups["US"] | length' 2>/dev/null)
    prefix_emptylen_result=$(echo "$prefix_synth" | jq -c \
        --arg mode "prefix" --arg prefix_len "" --argjson default_len 2 \
        -f "$grouper_filter_file" 2>/dev/null)
    prefix_emptylen_us=$(echo "$prefix_emptylen_result" | jq -r '.groups["US"] | length' 2>/dev/null)
    if [ "$prefix_badlen_us" = "2" ] && [ "$prefix_emptylen_us" = "2" ]; then
        pass "Prefix grouping bad/empty len falls back to 2 (no crash)"
    else
        fail "Prefix grouping len fallback wrong: bad-len US=$prefix_badlen_us empty-len US=$prefix_emptylen_us"
    fi

    # Space-containing prefix keys must group correctly (regression for the
    # word-splitting bug: a `for k in $(...)` loop over group keys shatters a
    # key like "A " (letter+space) — the current-shell `while read < file`
    # loop in the subscription branch preserves it). Synthetic tags only.
    local space_synth space_result space_groups space_a space_b space_ungrouped space_keys
    space_synth='["A 1","A 2","B 9"]'
    space_result=$(echo "$space_synth" | jq -c \
        --arg mode "prefix" --arg prefix_len "2" --argjson default_len 2 \
        -f "$grouper_filter_file")
    rm -f "$grouper_filter_file"
    space_groups=$(echo "$space_result" | jq -r '.group_order | length')
    space_a=$(echo "$space_result" | jq -r '.groups["A "] | length')
    space_b=$(echo "$space_result" | jq -r '.groups["B "] | length')
    space_ungrouped=$(echo "$space_result" | jq -r '.ungrouped | length')
    # The group_order keys must be exactly "A " and "B " (each ends with a
    # space) — confirms the space is preserved, not split away.
    space_keys=$(echo "$space_result" | jq -c '.group_order')
    if [ "$space_groups" -eq 2 ] && [ "$space_a" = "2" ] && [ "$space_b" = "1" ] && \
        [ "$space_ungrouped" -eq 0 ] && [ "$space_keys" = '["A ","B "]' ]; then
        pass "Prefix grouping space-key: 'A '=$space_a 'B '=$space_b, groups=$space_groups, ungrouped=$space_ungrouped"
    else
        fail "Prefix grouping space-key wrong: 'A '=$space_a 'B '=$space_b groups=$space_groups ungrouped=$space_ungrouped keys=$space_keys"
    fi

    # ── Fallback Subscription Normalizer (helpers.sh) ───────────────
    # Exercise normalize_subscription_to_singbox end-to-end against the
    # real libs. The facade hardcodes NETSHIFT_LIB=/usr/lib/netshift, so we
    # mirror test_jq_helpers and expose the bind-mounted libs there via
    # symlinks, then source constants + logging + facade (the facade pulls in
    # helpers.sh and the config manager). Tokens are emitted on stdout and
    # parsed with the same name:OK/FAIL/SKIP convention used by test_helpers.
    # NB: no `set -u` in the harness — the URI builders rely on optional unset
    # query-param vars, exactly like the production backend.
    printf "\n  ${BOLD}Fallback Subscription Normalizer${NC}\n"

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/helpers.sh" ] || [ ! -r "$lib/sing_box_config_facade.sh" ]; then
        skip "fallback normalizer (libs not found in $lib)"
        return
    fi

    local fb="/tmp/netshift-sub-fallback-$$.sh"
    cat > "$fb" << 'FBEOF'
# Make the facade's hardcoded NETSHIFT_LIB path resolve to the bind-mounted libs.
mkdir -p /usr/lib/netshift
for f in constants.sh helpers.sh logging.sh sing_box_config_manager.sh sing_box_config_facade.sh; do
    ln -sf "LIB_DIR/$f" "/usr/lib/netshift/$f"
done

. /usr/lib/netshift/constants.sh
. /usr/lib/netshift/logging.sh
# The facade sources helpers.sh + sing_box_config_manager.sh itself.
. /usr/lib/netshift/sing_box_config_facade.sh

# ── CASE A: plaintext URI list with comment/metadata lines ──────────
caseA_in="/tmp/netshift-fb-caseA-$$.txt"
caseA_out="/tmp/netshift-fb-caseA-out-$$.json"
cat > "$caseA_in" << 'LIST'
#profile-title: Test
#subscription-userinfo: upload=0
vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&sni=example.com&type=tcp#A
trojan://password123@example.com:8443?security=tls&sni=example.com#B
ss://YWVzLTI1Ni1nY206cGFzcw==@example.com:8388#C
hysteria2://pass@example.com:443?sni=example.com#D

socks5://user:pass@example.com:1080#E
LIST

if normalize_subscription_to_singbox "$caseA_in" "$caseA_out" "testsub"; then
    echo 'fb-caseA-rc:OK'
else
    echo 'fb-caseA-rc:FAIL'
fi
a_len="$(jq -r '.outbounds | length' "$caseA_out" 2>/dev/null)"
[ -n "$a_len" ] || a_len=0
if [ "$a_len" -ge 4 ]; then
    echo "fb-caseA-count(>=4 got $a_len):OK"
else
    echo "fb-caseA-count(>=4 got $a_len):FAIL"
fi
if validate_subscription_file "$caseA_out"; then
    echo 'fb-caseA-validate:OK'
else
    echo 'fb-caseA-validate:FAIL'
fi
rm -f "$caseA_in" "$caseA_out"

# ── CASE B: base64-wrapped URI list ─────────────────────────────────
# busybox base64 may lack -w0; encode then strip newlines with tr.
caseB_plain="vless://22222222-2222-2222-2222-222222222222@example.com:443?security=tls&sni=example.com&type=tcp#B1
trojan://secretpw@example.com:8443?security=tls&sni=example.com#B2"
caseB_in="/tmp/netshift-fb-caseB-$$.txt"
caseB_out="/tmp/netshift-fb-caseB-out-$$.json"
printf '%s' "$caseB_plain" | base64 | tr -d '\n' > "$caseB_in"

if normalize_subscription_to_singbox "$caseB_in" "$caseB_out" "testsub"; then
    echo 'fb-caseB-rc:OK'
else
    echo 'fb-caseB-rc:FAIL'
fi
b_len="$(jq -r '.outbounds | length' "$caseB_out" 2>/dev/null)"
[ -n "$b_len" ] || b_len=0
if [ "$b_len" -ge 2 ]; then
    echo "fb-caseB-count(>=2 got $b_len):OK"
else
    echo "fb-caseB-count(>=2 got $b_len):FAIL"
fi
if validate_subscription_file "$caseB_out"; then
    echo 'fb-caseB-validate:OK'
else
    echo 'fb-caseB-validate:FAIL'
fi
rm -f "$caseB_in" "$caseB_out"

# ── CASE C: robustness — valid keys mixed with garbage ──────────────
# Two valid known-scheme keys; an unknown scheme (vmess), a malformed line,
# a blank line and a comment must all be skipped without aborting the parse.
caseC_in="/tmp/netshift-fb-caseC-$$.txt"
caseC_out="/tmp/netshift-fb-caseC-out-$$.json"
cat > "$caseC_in" << 'LIST'
#header comment
vless://33333333-3333-3333-3333-333333333333@example.com:443?security=tls&sni=example.com&type=tcp#C1
vmess://eyJ0aGlzIjoidW5rbm93biJ9
not-a-uri

trojan://pw3@example.com:8443?security=tls&sni=example.com#C2
LIST

if normalize_subscription_to_singbox "$caseC_in" "$caseC_out" "testsub"; then
    echo 'fb-caseC-rc:OK'
else
    echo 'fb-caseC-rc:FAIL'
fi
c_len="$(jq -r '.outbounds | length' "$caseC_out" 2>/dev/null)"
[ -n "$c_len" ] || c_len=0
if [ "$c_len" -eq 2 ]; then
    echo "fb-caseC-count(==2 valid got $c_len):OK"
else
    echo "fb-caseC-count(==2 valid got $c_len):FAIL"
fi
rm -f "$caseC_in" "$caseC_out"

# ── CASE D: negative — only comments / junk, no valid keys ──────────
caseD_in="/tmp/netshift-fb-caseD-$$.txt"
caseD_out="/tmp/netshift-fb-caseD-out-$$.json"
cat > "$caseD_in" << 'LIST'
#profile-title: Empty
#subscription-userinfo: upload=0
not-a-uri
vmess://eyJqdW5rIjoidHJ1ZSJ9

LIST

if normalize_subscription_to_singbox "$caseD_in" "$caseD_out" "testsub"; then
    echo 'fb-caseD-rc-nonzero:FAIL'
else
    echo 'fb-caseD-rc-nonzero:OK'
fi
# No usable output: either no file, or a file that fails validation.
if [ ! -s "$caseD_out" ] || ! validate_subscription_file "$caseD_out"; then
    echo 'fb-caseD-no-usable-output:OK'
else
    echo 'fb-caseD-no-usable-output:FAIL'
fi
rm -f "$caseD_in" "$caseD_out"

# ── CASE E: Xray JSON subscription (array of Xray client configs) ───
# A provider that returns an "Xray JSON" body instead of a sing-box config:
# an array of Xray configs whose proxy outbounds use the Xray schema
# (protocol + settings.vnext + streamSettings). The normalizer must detect
# this, convert the directly-usable (non-dialerProxy) outbounds to share URIs
# and produce a valid sing-box config. The chained (sockopt.dialerProxy)
# outbound must be skipped.
caseE_in="/tmp/netshift-fb-caseE-$$.json"
caseE_out="/tmp/netshift-fb-caseE-out-$$.json"
cat > "$caseE_in" << 'XRAYJSON'
[
  {
    "remarks": "Reality TCP",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy-reality",
        "settings": {"vnext": [{"address": "uk.example.com", "port": 8443,
          "users": [{"id": "59e308c0-071d-4214-bb4a-64a2409d9e3b",
            "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
        "streamSettings": {"network": "tcp", "security": "reality",
          "realitySettings": {"publicKey": "dY9SNEllJMW63xo-JdXufhmjAxB",
            "shortId": "c20b1035d72d7793", "serverName": "storage.yandex.net",
            "fingerprint": "firefox"}}
      }
    ]
  },
  {
    "remarks": "WS TLS",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy-ws",
        "settings": {"vnext": [{"address": "ws.example.com", "port": 443,
          "users": [{"id": "dea6c6da-3903-4dbc-b98c-e79364764f9f",
            "flow": "", "encryption": "none"}]}]},
        "streamSettings": {"network": "ws", "security": "tls",
          "tlsSettings": {"serverName": "ws.example.com"},
          "wsSettings": {"path": "/livestreamcontent/",
            "headers": {"Host": "ws.example.com"}}}
      },
      {
        "protocol": "vless",
        "tag": "proxy-chained",
        "settings": {"vnext": [{"address": "bypass.example.com", "port": 8443,
          "users": [{"id": "8c459cd3-f3b0-496c-9d87-138d292ecdf6",
            "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
        "streamSettings": {"network": "tcp", "security": "reality",
          "sockopt": {"dialerProxy": "upstream-0"},
          "realitySettings": {"publicKey": "abc", "shortId": "def",
            "serverName": "storage.yandex.net", "fingerprint": "firefox"}}
      }
    ]
  }
]
XRAYJSON

if normalize_subscription_to_singbox "$caseE_in" "$caseE_out" "testsub"; then
    echo 'fb-caseE-rc:OK'
else
    echo 'fb-caseE-rc:FAIL'
fi
# Exactly two usable outbounds: reality-tcp + ws-tls; the dialerProxy one skipped.
e_len="$(jq -r '.outbounds | length' "$caseE_out" 2>/dev/null)"
[ -n "$e_len" ] || e_len=0
if [ "$e_len" -eq 2 ]; then
    echo "fb-caseE-count(==2 got $e_len):OK"
else
    echo "fb-caseE-count(==2 got $e_len):FAIL"
fi
if validate_subscription_file "$caseE_out"; then
    echo 'fb-caseE-validate:OK'
else
    echo 'fb-caseE-validate:FAIL'
fi
# The reality outbound must carry the converted reality block + flow.
if jq -e '[.outbounds[] | select(.type == "vless"
        and .tls.reality.public_key == "dY9SNEllJMW63xo-JdXufhmjAxB"
        and .flow == "xtls-rprx-vision")] | length == 1' "$caseE_out" \
        > /dev/null 2>&1; then
    echo 'fb-caseE-reality-fields:OK'
else
    echo 'fb-caseE-reality-fields:FAIL'
fi
rm -f "$caseE_in" "$caseE_out"

# ── CASE F: Xray JSON reality node WITHOUT shortId ──────────────────
# Regression guard: a missing Xray field reads as JSON null, and a naive
# (null | tostring) would emit a literal "sid=null" query param, which
# sing-box would then store as short_id:"null". The converter must drop the
# absent param entirely, so the produced reality block carries NO short_id.
caseF_in="/tmp/netshift-fb-caseF-$$.json"
caseF_out="/tmp/netshift-fb-caseF-out-$$.json"
cat > "$caseF_in" << 'XRAYJSON'
[
  {
    "remarks": "no-sid",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy-no-sid",
        "settings": {"vnext": [{"address": "ru.example.com", "port": 443,
          "users": [{"id": "1dff23f6-b2f1-4242-9746-b586808ed302",
            "encryption": "none"}]}]},
        "streamSettings": {"network": "tcp", "security": "reality",
          "realitySettings": {"publicKey": "G2i-nsQgWiVf52tdCUV",
            "serverName": "cloudrynth.com", "fingerprint": "firefox"}}
      }
    ]
  }
]
XRAYJSON

if normalize_subscription_to_singbox "$caseF_in" "$caseF_out" "testsub"; then
    echo 'fb-caseF-rc:OK'
else
    echo 'fb-caseF-rc:FAIL'
fi
if validate_subscription_file "$caseF_out"; then
    echo 'fb-caseF-validate:OK'
else
    echo 'fb-caseF-validate:FAIL'
fi
# No outbound may carry a literal "null" short_id, and the public_key must be set.
if jq -e '([.outbounds[].tls.reality.short_id // empty] | map(select(. == "null")) | length) == 0
        and ([.outbounds[] | select(.tls.reality.public_key == "G2i-nsQgWiVf52tdCUV")] | length == 1)' \
        "$caseF_out" > /dev/null 2>&1; then
    echo 'fb-caseF-no-null-sid:OK'
else
    echo 'fb-caseF-no-null-sid:FAIL'
fi
rm -f "$caseF_in" "$caseF_out"

# ── CASE G: Xray JSON duplicate-node dedup ──────────────────────────
# Providers commonly ship one server set across many "profiles"/balancers,
# repeating identical nodes with only the display name differing. The
# converter must dedup on the connection part (ignoring the #name), so N
# copies of the same server collapse to one. Here three configs reference the
# same two servers (A, B) plus one extra (C) -> exactly 3 unique outbounds.
caseG_in="/tmp/netshift-fb-caseG-$$.json"
caseG_out="/tmp/netshift-fb-caseG-out-$$.json"
cat > "$caseG_in" << 'XRAYJSON'
[
  {"remarks": "profile-1", "outbounds": [
    {"protocol": "vless", "tag": "A", "settings": {"vnext": [{"address": "a.example.com", "port": 443,
      "users": [{"id": "11111111-1111-1111-1111-111111111111", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "a.example.com", "fingerprint": "firefox"}}},
    {"protocol": "vless", "tag": "B", "settings": {"vnext": [{"address": "b.example.com", "port": 443,
      "users": [{"id": "22222222-2222-2222-2222-222222222222", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "cd", "serverName": "b.example.com", "fingerprint": "firefox"}}}
  ]},
  {"remarks": "profile-2", "outbounds": [
    {"protocol": "vless", "tag": "A-copy", "settings": {"vnext": [{"address": "a.example.com", "port": 443,
      "users": [{"id": "11111111-1111-1111-1111-111111111111", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "a.example.com", "fingerprint": "firefox"}}},
    {"protocol": "vless", "tag": "B-copy", "settings": {"vnext": [{"address": "b.example.com", "port": 443,
      "users": [{"id": "22222222-2222-2222-2222-222222222222", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "cd", "serverName": "b.example.com", "fingerprint": "firefox"}}}
  ]},
  {"remarks": "profile-3", "outbounds": [
    {"protocol": "vless", "tag": "C", "settings": {"vnext": [{"address": "c.example.com", "port": 443,
      "users": [{"id": "33333333-3333-3333-3333-333333333333", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ef", "serverName": "c.example.com", "fingerprint": "firefox"}}}
  ]}
]
XRAYJSON

if normalize_subscription_to_singbox "$caseG_in" "$caseG_out" "testsub"; then
    echo 'fb-caseG-rc:OK'
else
    echo 'fb-caseG-rc:FAIL'
fi
# 5 raw nodes (A,B,A-copy,B-copy,C) must dedup to 3 unique servers (A,B,C).
g_len="$(jq -r '.outbounds | length' "$caseG_out" 2>/dev/null)"
[ -n "$g_len" ] || g_len=0
if [ "$g_len" -eq 3 ]; then
    echo "fb-caseG-dedup(==3 got $g_len):OK"
else
    echo "fb-caseG-dedup(==3 got $g_len):FAIL"
fi
# All three distinct servers must survive (a, b, c).
if jq -e '([.outbounds[].server] | sort) == ["a.example.com","b.example.com","c.example.com"]' \
        "$caseG_out" > /dev/null 2>&1; then
    echo 'fb-caseG-servers:OK'
else
    echo 'fb-caseG-servers:FAIL'
fi
rm -f "$caseG_in" "$caseG_out"

# ── CASE H: Xray JSON with unsupported VMess alongside VLESS ────────
# The facade cannot build VMess. The converter must skip vmess but keep the
# vless node, and xray_json_count_unsupported must report the dropped vmess so
# the backend can warn the user instead of silently losing it.
caseH_in="/tmp/netshift-fb-caseH-$$.json"
caseH_out="/tmp/netshift-fb-caseH-out-$$.json"
cat > "$caseH_in" << 'XRAYJSON'
[
  {
    "remarks": "mixed",
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "ok-vless",
        "settings": {"vnext": [{"address": "vl.example.com", "port": 443,
          "users": [{"id": "11111111-1111-1111-1111-111111111111",
            "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
        "streamSettings": {"network": "tcp", "security": "reality",
          "realitySettings": {"publicKey": "PK", "shortId": "ab",
            "serverName": "vl.example.com", "fingerprint": "firefox"}}
      },
      {
        "protocol": "vmess",
        "tag": "drop-vmess",
        "settings": {"vnext": [{"address": "vm.example.com", "port": 443,
          "users": [{"id": "22222222-2222-2222-2222-222222222222",
            "alterId": 0, "security": "auto"}]}]},
        "streamSettings": {"network": "tcp", "security": "tls",
          "tlsSettings": {"serverName": "vm.example.com"}}
      }
    ]
  }
]
XRAYJSON

if normalize_subscription_to_singbox "$caseH_in" "$caseH_out" "testsub"; then
    echo 'fb-caseH-rc:OK'
else
    echo 'fb-caseH-rc:FAIL'
fi
# Exactly one usable outbound (vless); vmess dropped.
h_len="$(jq -r '.outbounds | length' "$caseH_out" 2>/dev/null)"
[ -n "$h_len" ] || h_len=0
if [ "$h_len" -eq 1 ] \
        && jq -e '.outbounds[0].server == "vl.example.com"' "$caseH_out" >/dev/null 2>&1; then
    echo "fb-caseH-vless-kept(==1 got $h_len):OK"
else
    echo "fb-caseH-vless-kept(==1 got $h_len):FAIL"
fi
# The unsupported-protocol counter must report exactly one vmess.
h_unsup="$(xray_json_count_unsupported "$caseH_in")"
if [ "$h_unsup" = "1" ]; then
    echo 'fb-caseH-vmess-counted:OK'
else
    echo "fb-caseH-vmess-counted(==1 got $h_unsup):FAIL"
fi
rm -f "$caseH_in" "$caseH_out"

# ── CASE H2: Xray JSON (Happ) names from remarks ────────────────────
# Generic "proxy"/"proxy-N" tags give way to remarks; any other tag (fi-1,
# nl-1, proxy-eu) is kept. Node A is listed in the balancer first but keeps
# its own profile name. Special characters in remarks must round-trip through
# the URI fragment; missing or blank remarks fall back to the tag.
caseH2_in="/tmp/netshift-fb-caseH2-$$.json"
caseH2_out="/tmp/netshift-fb-caseH2-out-$$.json"
cat > "$caseH2_in" << 'XRAYJSON'
[
  {"remarks": "Balancer", "outbounds": [
    {"protocol": "vless", "tag": "proxy", "settings": {"vnext": [{"address": "de.example.com", "port": 443,
      "users": [{"id": "11111111-1111-1111-1111-111111111111", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "de.example.com", "fingerprint": "chrome"}}},
    {"protocol": "trojan", "tag": "proxy-2", "settings": {"servers": [{"address": "ru.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "ru.example.com"}}},
    {"protocol": "freedom", "tag": "direct"}
  ]},
  {"remarks": "Node A", "outbounds": [
    {"protocol": "vless", "tag": "proxy", "settings": {"vnext": [{"address": "de.example.com", "port": 443,
      "users": [{"id": "11111111-1111-1111-1111-111111111111", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "de.example.com", "fingerprint": "chrome"}}},
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]},
  {"remarks": "Node B", "outbounds": [
    {"protocol": "vless", "tag": "proxy", "settings": {"vnext": [{"address": "nl.example.com", "port": 443,
      "users": [{"id": "22222222-2222-2222-2222-222222222222", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "cd", "serverName": "nl.example.com", "fingerprint": "chrome"}}},
    {"protocol": "freedom", "tag": "direct"}
  ]},
  {"remarks": "Auto", "outbounds": [
    {"protocol": "trojan", "tag": "fi-1", "settings": {"servers": [{"address": "fi.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "fi.example.com"}}},
    {"protocol": "trojan", "tag": "se-1", "settings": {"servers": [{"address": "se.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "se.example.com"}}}
  ]},
  {"remarks": "A+B #1 %20 🇩🇪", "outbounds": [
    {"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "de2.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "de2.example.com"}}}
  ]},
  {"remarks": "Solo", "outbounds": [
    {"protocol": "trojan", "tag": "nl-1", "settings": {"servers": [{"address": "nl1.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "nl1.example.com"}}}
  ]},
  {"remarks": "Solo EU", "outbounds": [
    {"protocol": "trojan", "tag": "proxy-eu", "settings": {"servers": [{"address": "eu.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "eu.example.com"}}}
  ]},
  {"outbounds": [
    {"protocol": "trojan", "tag": "proxy-7", "settings": {"servers": [{"address": "pl.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "pl.example.com"}}}
  ]},
  {"remarks": "   ", "outbounds": [
    {"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "cz.example.com", "port": 443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "cz.example.com"}}}
  ]}
]
XRAYJSON

if normalize_subscription_to_singbox "$caseH2_in" "$caseH2_out" "testsub"; then
    echo 'fb-caseH2-rc:OK'
else
    echo 'fb-caseH2-rc:FAIL'
fi
h2_tags="$(jq -c '[.outbounds[].tag]' "$caseH2_out" 2>/dev/null)"
if [ "$h2_tags" = '["Node A","Balancer · 2","Node B","fi-1","se-1","A+B #1 %20 🇩🇪","nl-1","proxy-eu","proxy-7","proxy"]' ]; then
    echo 'fb-caseH2-remarks-names:OK'
else
    echo "fb-caseH2-remarks-names(got $h2_tags):FAIL"
fi
rm -f "$caseH2_in" "$caseH2_out"

# ── CASE H3: Xray JSON name edge cases ──────────────────────────────
# A one-node balancer loses the name to the plain profile of the same node;
# balancer members are numbered after their proxy-N tag (vmess proxy-2 is
# dropped, so proxy-3 stays " · 3"), by position when tag numbers repeat;
# names repeated across configs get the next free number.
caseH3_in="/tmp/netshift-fb-caseH3-$$.json"
caseH3_out="/tmp/netshift-fb-caseH3-out-$$.json"
cat > "$caseH3_in" << 'XRAYJSON'
[
  {"remarks": "Bal1", "routing": {"balancers": [{"tag": "b", "selector": ["proxy"]}]}, "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "p1.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "p1.example.com"}}}]},
  {"remarks": "Prof", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "p1.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "p1.example.com"}}}]},
  {"remarks": "Grp", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "g1.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "g1.example.com"}}}, {"protocol": "vmess", "tag": "proxy-2", "settings": {"vnext": [{"address": "vm.example.com", "port": 443, "users": [{"id": "33333333-3333-3333-3333-333333333333"}]}]}}, {"protocol": "trojan", "tag": "proxy-3", "settings": {"servers": [{"address": "g3.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "g3.example.com"}}}]},
  {"remarks": "Dup", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "d1.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "d1.example.com"}}}, {"protocol": "trojan", "tag": "proxy-1", "settings": {"servers": [{"address": "d2.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "d2.example.com"}}}]},
  {"remarks": "Twin", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "t1.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "t1.example.com"}}}, {"protocol": "trojan", "tag": "proxy-2", "settings": {"servers": [{"address": "t2.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "t2.example.com"}}}]},
  {"remarks": "Twin", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "t3.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "t3.example.com"}}}, {"protocol": "trojan", "tag": "proxy-2", "settings": {"servers": [{"address": "t4.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "t4.example.com"}}}]},
  {"remarks": "Same", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "s1.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "s1.example.com"}}}]},
  {"remarks": "Same", "outbounds": [{"protocol": "trojan", "tag": "proxy", "settings": {"servers": [{"address": "s2.example.com", "port": 443, "password": "testpass"}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "s2.example.com"}}}]}
]
XRAYJSON

if normalize_subscription_to_singbox "$caseH3_in" "$caseH3_out" "testsub"; then
    echo 'fb-caseH3-rc:OK'
else
    echo 'fb-caseH3-rc:FAIL'
fi
h3_tags="$(jq -c '[.outbounds[].tag]' "$caseH3_out" 2>/dev/null)"
if [ "$h3_tags" = '["Prof","Grp · 1","Grp · 3","Dup · 1","Dup · 2","Twin · 1","Twin · 2","Twin · 3","Twin · 4","Same","Same · 2"]' ]; then
    echo 'fb-caseH3-names:OK'
else
    echo "fb-caseH3-names(got $h3_tags):FAIL"
fi
rm -f "$caseH3_in" "$caseH3_out"

# ── CASE I: subscription User-Agent candidate building ──────────────
# Auto mode (no configured UA) must emit, in order and without duplicates:
# the default singbox/<ver> first, then the cached/preferred UA, then the
# constants whitelist. A configured UA must short-circuit to exactly itself.
caseI_default="$(get_subscription_user_agent)"

# (a) Auto mode, no preferred: first line is the default; v2rayN present; no dup default.
caseI_auto="$(build_subscription_user_agent_candidates "" "")"
caseI_first="$(printf '%s\n' "$caseI_auto" | sed -n '1p')"
if [ "$caseI_first" = "$caseI_default" ]; then
    echo 'fb-caseI-auto-default-first:OK'
else
    echo "fb-caseI-auto-default-first(got '$caseI_first'):FAIL"
fi
if printf '%s\n' "$caseI_auto" | grep -Fxq 'v2rayN'; then
    echo 'fb-caseI-auto-has-v2rayN:OK'
else
    echo 'fb-caseI-auto-has-v2rayN:FAIL'
fi
caseI_default_count="$(printf '%s\n' "$caseI_auto" | grep -Fxc "$caseI_default")"
if [ "$caseI_default_count" = "1" ]; then
    echo 'fb-caseI-auto-default-unique:OK'
else
    echo "fb-caseI-auto-default-unique(got $caseI_default_count):FAIL"
fi

# (b) Preferred UA is emitted right after the default and only once.
caseI_pref="$(build_subscription_user_agent_candidates "" "Hiddify")"
caseI_second="$(printf '%s\n' "$caseI_pref" | sed -n '2p')"
caseI_hid_count="$(printf '%s\n' "$caseI_pref" | grep -Fxc 'Hiddify')"
if [ "$caseI_second" = "Hiddify" ] && [ "$caseI_hid_count" = "1" ]; then
    echo 'fb-caseI-preferred-second-unique:OK'
else
    echo "fb-caseI-preferred-second-unique(2nd='$caseI_second' count=$caseI_hid_count):FAIL"
fi

# (c) Configured UA short-circuits to exactly one line = itself.
caseI_conf="$(build_subscription_user_agent_candidates "MyClient/1.0" "Hiddify")"
caseI_conf_lines="$(printf '%s\n' "$caseI_conf" | grep -c .)"
if [ "$caseI_conf" = "MyClient/1.0" ] && [ "$caseI_conf_lines" = "1" ]; then
    echo 'fb-caseI-configured-only:OK'
else
    echo "fb-caseI-configured-only(got '$caseI_conf' lines=$caseI_conf_lines):FAIL"
fi

# (c2) Empty preference (auto via 3rd arg) keeps today's order: default first.
caseI_emptyp="$(build_subscription_user_agent_candidates "" "" "")"
caseI_emptyp_first="$(printf '%s\n' "$caseI_emptyp" | sed -n '1p')"
if [ "$caseI_emptyp_first" = "$caseI_default" ]; then
    echo 'fb-caseI-emptypref-default-first:OK'
else
    echo "fb-caseI-emptypref-default-first(got '$caseI_emptyp_first'):FAIL"
fi

# (d) auto preference keeps today's order: default singbox/<ver> first.
caseI_autop="$(build_subscription_user_agent_candidates "" "" "auto")"
caseI_autop_first="$(printf '%s\n' "$caseI_autop" | sed -n '1p')"
if [ "$caseI_autop_first" = "$caseI_default" ]; then
    echo 'fb-caseI-autopref-default-first:OK'
else
    echo "fb-caseI-autopref-default-first(got '$caseI_autop_first'):FAIL"
fi

# (e) singbox preference: default singbox/<ver> first (defined behaviour).
caseI_sbp="$(build_subscription_user_agent_candidates "" "Hiddify" "singbox")"
caseI_sbp_first="$(printf '%s\n' "$caseI_sbp" | sed -n '1p')"
if [ "$caseI_sbp_first" = "$caseI_default" ]; then
    echo 'fb-caseI-singboxpref-default-first:OK'
else
    echo "fb-caseI-singboxpref-default-first(got '$caseI_sbp_first'):FAIL"
fi

# (f) xray preference: the versioned Xray-JSON UAs come FIRST — before the
# default singbox/<ver> AND before the cached preferred winner. Pass a cached
# preferred ('Hiddify') to prove the xray UAs outrank it. The expected first two
# candidates are DERIVED from the SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES constant
# (sourced above) so a future constant tweak doesn't rot this test.
caseI_xray="$(build_subscription_user_agent_candidates "" "Hiddify" "xray")"
caseI_xray_first="$(printf '%s\n' "$caseI_xray" | sed -n '1p')"
caseI_xray_second="$(printf '%s\n' "$caseI_xray" | sed -n '2p')"
# Expected first/second/third xray UAs, split from the constant (in order).
# shellcheck disable=SC2086 # word-splitting of the candidate list is intentional
set -- $SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES
caseI_xray_exp1="$1"
caseI_xray_exp2="$2"
caseI_xray_exp3="$3"
# Position helper: line number of an exact match (empty if absent).
caseI_pos() { printf '%s\n' "$1" | grep -Fxn "$2" | head -n1 | cut -d: -f1; }
caseI_xray_p_1="$(caseI_pos "$caseI_xray" "$caseI_xray_exp1")"
caseI_xray_p_2="$(caseI_pos "$caseI_xray" "$caseI_xray_exp2")"
caseI_xray_p_3="$(caseI_pos "$caseI_xray" "$caseI_xray_exp3")"
caseI_xray_p_default="$(caseI_pos "$caseI_xray" "$caseI_default")"
caseI_xray_p_pref="$(caseI_pos "$caseI_xray" 'Hiddify')"
# First two lines are the first two xray candidates (in constant order).
if [ "$caseI_xray_first" = "$caseI_xray_exp1" ] && [ "$caseI_xray_second" = "$caseI_xray_exp2" ]; then
    echo 'fb-caseI-xraypref-xray-first:OK'
else
    echo "fb-caseI-xraypref-xray-first(1st='$caseI_xray_first' 2nd='$caseI_xray_second'):FAIL"
fi
# Guard: the first xray candidate is VERSIONED (contains a '/'), not a bare UA.
case "$caseI_xray_first" in
*/*) echo 'fb-caseI-xraypref-first-versioned:OK' ;;
*) echo "fb-caseI-xraypref-first-versioned(got '$caseI_xray_first'):FAIL" ;;
esac
# Every xray UA precedes the default and the cached preferred winner.
if [ -n "$caseI_xray_p_1" ] && [ -n "$caseI_xray_p_2" ] && [ -n "$caseI_xray_p_3" ] &&
    [ -n "$caseI_xray_p_default" ] && [ -n "$caseI_xray_p_pref" ] &&
    [ "$caseI_xray_p_1" -lt "$caseI_xray_p_default" ] &&
    [ "$caseI_xray_p_2" -lt "$caseI_xray_p_default" ] &&
    [ "$caseI_xray_p_3" -lt "$caseI_xray_p_default" ] &&
    [ "$caseI_xray_p_1" -lt "$caseI_xray_p_pref" ] &&
    [ "$caseI_xray_p_2" -lt "$caseI_xray_p_pref" ] &&
    [ "$caseI_xray_p_3" -lt "$caseI_xray_p_pref" ]; then
    echo 'fb-caseI-xraypref-outranks-default-and-cache:OK'
else
    echo "fb-caseI-xraypref-outranks-default-and-cache(1=$caseI_xray_p_1 2=$caseI_xray_p_2 3=$caseI_xray_p_3 def=$caseI_xray_p_default pref=$caseI_xray_p_pref):FAIL"
fi
# Dedup holds: no UA emitted twice (each xray UA and the default appears once).
caseI_xray_1_count="$(printf '%s\n' "$caseI_xray" | grep -Fxc "$caseI_xray_exp1")"
caseI_xray_2_count="$(printf '%s\n' "$caseI_xray" | grep -Fxc "$caseI_xray_exp2")"
caseI_xray_3_count="$(printf '%s\n' "$caseI_xray" | grep -Fxc "$caseI_xray_exp3")"
caseI_xray_def_count="$(printf '%s\n' "$caseI_xray" | grep -Fxc "$caseI_default")"
if [ "$caseI_xray_1_count" = "1" ] && [ "$caseI_xray_2_count" = "1" ] &&
    [ "$caseI_xray_3_count" = "1" ] && [ "$caseI_xray_def_count" = "1" ]; then
    echo 'fb-caseI-xraypref-dedup:OK'
else
    echo "fb-caseI-xraypref-dedup(1=$caseI_xray_1_count 2=$caseI_xray_2_count 3=$caseI_xray_3_count def=$caseI_xray_def_count):FAIL"
fi

# (g) Unrecognised preference falls back to auto order: default first.
caseI_unk="$(build_subscription_user_agent_candidates "" "Hiddify" "totally-bogus")"
caseI_unk_first="$(printf '%s\n' "$caseI_unk" | sed -n '1p')"
if [ "$caseI_unk_first" = "$caseI_default" ]; then
    echo 'fb-caseI-unknownpref-auto-first:OK'
else
    echo "fb-caseI-unknownpref-auto-first(got '$caseI_unk_first'):FAIL"
fi

# (h) Explicit configured UA still short-circuits regardless of preference.
caseI_conf_xray="$(build_subscription_user_agent_candidates "MyClient/1.0" "Hiddify" "xray")"
caseI_conf_xray_lines="$(printf '%s\n' "$caseI_conf_xray" | grep -c .)"
if [ "$caseI_conf_xray" = "MyClient/1.0" ] && [ "$caseI_conf_xray_lines" = "1" ]; then
    echo 'fb-caseI-configured-overrides-pref:OK'
else
    echo "fb-caseI-configured-overrides-pref(got '$caseI_conf_xray' lines=$caseI_conf_xray_lines):FAIL"
fi

# ── CASE J: subscription keyword whitelist/blacklist filter ─────────
# Drive sing_box_cf_prepare_subscription_batch directly with a synthetic
# subscription JSON and assert kept counts/names for include/exclude lists.
# Matching: substring, OR across keywords, ASCII case-insensitive, byte-exact
# for non-folded scripts (emoji/etc). No jq regex (index + inline ucfold only).
caseJ_cfg='{"outbounds":[]}'
caseJ_sub="/tmp/netshift-fb-caseJ-$$.json"
cat > "$caseJ_sub" << 'JSUB'
{
  "outbounds": [
    {"type": "shadowsocks", "tag": "US grpc", "server": "a.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "US ws", "server": "b.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "DE grpc", "server": "c.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"}
  ]
}
JSUB

# Helper: emit the JSON `count` for given include/exclude arrays.
caseJ_count() {
    sing_box_cf_prepare_subscription_batch "$caseJ_cfg" "$caseJ_sub" "$1" "$2" |
        jq -r '.count // -1'
}
# Helper: emit a comma-joined sorted names list for given include/exclude arrays.
caseJ_names() {
    sing_box_cf_prepare_subscription_batch "$caseJ_cfg" "$caseJ_sub" "$1" "$2" |
        jq -r '(.names // []) | sort | join(",")'
}

# (1) include-only: ["grpc"] keeps exactly the 2 grpc nodes.
caseJ_inc_count="$(caseJ_count '["grpc"]' '[]')"
caseJ_inc_names="$(caseJ_names '["grpc"]' '[]')"
if [ "$caseJ_inc_count" = "2" ] && [ "$caseJ_inc_names" = "DE grpc,US grpc" ]; then
    echo 'fb-caseJ-include-only:OK'
else
    echo "fb-caseJ-include-only(count=$caseJ_inc_count names='$caseJ_inc_names'):FAIL"
fi

# (2) exclude-only: ["ws"] drops the ws node, keeps the other 2.
caseJ_exc_count="$(caseJ_count '[]' '["ws"]')"
caseJ_exc_names="$(caseJ_names '[]' '["ws"]')"
if [ "$caseJ_exc_count" = "2" ] && [ "$caseJ_exc_names" = "DE grpc,US grpc" ]; then
    echo 'fb-caseJ-exclude-only:OK'
else
    echo "fb-caseJ-exclude-only(count=$caseJ_exc_count names='$caseJ_exc_names'):FAIL"
fi

# (3) include + exclude OR: include=["US"], exclude=["ws"] => "US grpc" only.
caseJ_both_count="$(caseJ_count '["US"]' '["ws"]')"
caseJ_both_names="$(caseJ_names '["US"]' '["ws"]')"
if [ "$caseJ_both_count" = "1" ] && [ "$caseJ_both_names" = "US grpc" ]; then
    echo 'fb-caseJ-include-exclude:OK'
else
    echo "fb-caseJ-include-exclude(count=$caseJ_both_count names='$caseJ_both_names'):FAIL"
fi

# (4) case-insensitive ASCII: include=["GRPC"] matches "US grpc"/"DE grpc".
caseJ_ci_count="$(caseJ_count '["GRPC"]' '[]')"
if [ "$caseJ_ci_count" = "2" ]; then
    echo 'fb-caseJ-ascii-ci:OK'
else
    echo "fb-caseJ-ascii-ci(count=$caseJ_ci_count):FAIL"
fi

# (5) emoji/unicode substring: a robot-emoji node kept, a plain node dropped.
caseJ_emoji_sub="/tmp/netshift-fb-caseJ-emoji-$$.json"
cat > "$caseJ_emoji_sub" << 'JEMOJI'
{
  "outbounds": [
    {"type": "shadowsocks", "tag": "🤖 Gemini", "server": "a.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "Plain Node", "server": "b.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"}
  ]
}
JEMOJI
caseJ_emoji_count="$(sing_box_cf_prepare_subscription_batch "$caseJ_cfg" "$caseJ_emoji_sub" '["🤖"]' '[]' | jq -r '.count // -1')"
caseJ_emoji_names="$(sing_box_cf_prepare_subscription_batch "$caseJ_cfg" "$caseJ_emoji_sub" '["🤖"]' '[]' | jq -r '(.names // []) | join(",")')"
if [ "$caseJ_emoji_count" = "1" ] && [ "$caseJ_emoji_names" = "🤖 Gemini" ]; then
    echo 'fb-caseJ-emoji-substring:OK'
else
    echo "fb-caseJ-emoji-substring(count=$caseJ_emoji_count names='$caseJ_emoji_names'):FAIL"
fi
rm -f "$caseJ_emoji_sub"

# (6) empty include keeps all; over-strict filter removes everything (count 0).
caseJ_all_count="$(caseJ_count '[]' '[]')"
if [ "$caseJ_all_count" = "3" ]; then
    echo 'fb-caseJ-empty-include-keeps-all:OK'
else
    echo "fb-caseJ-empty-include-keeps-all(count=$caseJ_all_count):FAIL"
fi
caseJ_none_count="$(caseJ_count '["nomatch-zzz"]' '[]')"
if [ "$caseJ_none_count" = "0" ]; then
    echo 'fb-caseJ-filter-removes-all-zero-kept:OK'
else
    echo "fb-caseJ-filter-removes-all-zero-kept(count=$caseJ_none_count):FAIL"
fi
rm -f "$caseJ_sub"

# ── CASE K: Cyrillic + Ё/ё case-fold (task-010) ─────────────────────
# The keyword filter must fold ASCII AND Cyrillic (inline ucfold), so a
# mixed-case Cyrillic keyword matches a mixed-case Cyrillic server name.
# Emoji keywords still match by exact codepoints; ASCII is unaffected.
caseK_sub="/tmp/netshift-fb-caseK-$$.json"
cat > "$caseK_sub" << 'KSUB'
{
  "outbounds": [
    {"type": "shadowsocks", "tag": "🇩🇪 Германия", "server": "a.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "🇵🇱 Польша", "server": "b.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "🇰🇿 Казахстан", "server": "c.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "Орёл", "server": "d.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "shadowsocks", "tag": "US grpc", "server": "e.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"}
  ]
}
KSUB

caseK_count() {
    sing_box_cf_prepare_subscription_batch "$caseJ_cfg" "$caseK_sub" "$1" "$2" |
        jq -r '.count // -1'
}
caseK_names() {
    sing_box_cf_prepare_subscription_batch "$caseJ_cfg" "$caseK_sub" "$1" "$2" |
        jq -r '(.names // []) | join(",")'
}

# (1) include mixed-case Cyrillic ["ГеРма"] keeps Германия (was 0 before fix).
caseK_mixed_count="$(caseK_count '["ГеРма"]' '[]')"
caseK_mixed_names="$(caseK_names '["ГеРма"]' '[]')"
if [ "$caseK_mixed_count" = "1" ] && [ "$caseK_mixed_names" = "🇩🇪 Германия" ]; then
    echo 'fb-caseK-cyrillic-mixed-include:OK'
else
    echo "fb-caseK-cyrillic-mixed-include(count=$caseK_mixed_count names='$caseK_mixed_names'):FAIL"
fi

# (2) lower ["германия"] and upper ["ГЕРМАНИЯ"] both keep Германия.
caseK_lower_count="$(caseK_count '["германия"]' '[]')"
caseK_upper_count="$(caseK_count '["ГЕРМАНИЯ"]' '[]')"
if [ "$caseK_lower_count" = "1" ] && [ "$caseK_upper_count" = "1" ]; then
    echo 'fb-caseK-cyrillic-lower-upper-include:OK'
else
    echo "fb-caseK-cyrillic-lower-upper-include(lower=$caseK_lower_count upper=$caseK_upper_count):FAIL"
fi

# (3) exclude ["польша"] (lower) drops Польша (upper-P name) regardless of case.
caseK_exc_count="$(caseK_count '[]' '["польша"]')"
caseK_exc_names="$(caseK_names '[]' '["польша"]')"
case "$caseK_exc_names" in
    *Польша*) caseK_exc_has_pl=1 ;;
    *) caseK_exc_has_pl=0 ;;
esac
if [ "$caseK_exc_count" = "4" ] && [ "$caseK_exc_has_pl" = "0" ]; then
    echo 'fb-caseK-cyrillic-exclude:OK'
else
    echo "fb-caseK-cyrillic-exclude(count=$caseK_exc_count names='$caseK_exc_names'):FAIL"
fi

# (4) Ё/ё fold: name "Орёл" matched by lower "орёл" and upper "ОРЁЛ".
caseK_yo_lower="$(caseK_count '["орёл"]' '[]')"
caseK_yo_upper="$(caseK_count '["ОРЁЛ"]' '[]')"
caseK_yo_names="$(caseK_names '["ОРЁЛ"]' '[]')"
if [ "$caseK_yo_lower" = "1" ] && [ "$caseK_yo_upper" = "1" ] && [ "$caseK_yo_names" = "Орёл" ]; then
    echo 'fb-caseK-yo-fold:OK'
else
    echo "fb-caseK-yo-fold(lower=$caseK_yo_lower upper=$caseK_yo_upper names='$caseK_yo_names'):FAIL"
fi

# (5) emoji keyword ["🇰🇿"] keeps Казахстан by exact codepoint match.
caseK_emoji_count="$(caseK_count '["🇰🇿"]' '[]')"
caseK_emoji_names="$(caseK_names '["🇰🇿"]' '[]')"
if [ "$caseK_emoji_count" = "1" ] && [ "$caseK_emoji_names" = "🇰🇿 Казахстан" ]; then
    echo 'fb-caseK-emoji-flag-include:OK'
else
    echo "fb-caseK-emoji-flag-include(count=$caseK_emoji_count names='$caseK_emoji_names'):FAIL"
fi

# (6) ASCII no regression: include ["GRPC"] still keeps the "US grpc" node.
caseK_ascii_count="$(caseK_count '["GRPC"]' '[]')"
caseK_ascii_names="$(caseK_names '["GRPC"]' '[]')"
if [ "$caseK_ascii_count" = "1" ] && [ "$caseK_ascii_names" = "US grpc" ]; then
    echo 'fb-caseK-ascii-no-regression:OK'
else
    echo "fb-caseK-ascii-no-regression(count=$caseK_ascii_count names='$caseK_ascii_names'):FAIL"
fi
rm -f "$caseK_sub"

# ── CASE L: Xray JSON Hysteria2 (protocol "hysteria", version 2) ────
# Real subscriptions ship Hysteria2 inside the Xray-JSON array as
# protocol:"hysteria" + streamSettings.network:"hysteria" +
# hysteriaSettings.{version:2, auth:<password>}; addressing in
# settings.address/port; TLS in tlsSettings.{serverName, alpn, allowInsecure}.
# xray_json_to_uri_lines must emit a hysteria2:// URI carrying the auth as
# userinfo, host:port from settings, and sni/alpn/insecure query params.
# (Synthetic placeholder values only — nothing from any real subscription.)
caseL_in="/tmp/netshift-fb-caseL-$$.json"
cat > "$caseL_in" << 'XRAYJSON'
[
  {
    "remarks": "HY2 node",
    "outbounds": [
      {
        "protocol": "hysteria",
        "tag": "hy2-tag",
        "settings": {"address": "hy.example.com", "port": 8443},
        "streamSettings": {"network": "hysteria", "security": "tls",
          "tlsSettings": {"serverName": "hy.example.com",
            "alpn": ["h3"], "allowInsecure": true},
          "hysteriaSettings": {"version": 2, "auth": "testpass"}}
      }
    ]
  }
]
XRAYJSON
caseL_uris="$(xray_json_to_uri_lines "$caseL_in" 2>/dev/null)"
# Exactly one URI emitted, and it is a hysteria2:// scheme.
caseL_n="$(printf '%s\n' "$caseL_uris" | grep -c .)"
if [ "$caseL_n" = "1" ] && printf '%s\n' "$caseL_uris" | grep -q '^hysteria2://'; then
    echo 'fb-caseL-hy2-scheme:OK'
else
    echo "fb-caseL-hy2-scheme(n=$caseL_n uris='$caseL_uris'):FAIL"
fi
# Auth as userinfo, host:port from settings.
if printf '%s\n' "$caseL_uris" | grep -q '^hysteria2://testpass@hy.example.com:8443'; then
    echo 'fb-caseL-hy2-auth-host-port:OK'
else
    echo "fb-caseL-hy2-auth-host-port(uris='$caseL_uris'):FAIL"
fi
# sni + alpn + insecure query params present; NO type= param.
if printf '%s\n' "$caseL_uris" | grep -q 'sni=hy.example.com' \
        && printf '%s\n' "$caseL_uris" | grep -q 'alpn=h3' \
        && printf '%s\n' "$caseL_uris" | grep -q 'insecure=1' \
        && ! printf '%s\n' "$caseL_uris" | grep -q 'type='; then
    echo 'fb-caseL-hy2-query-params:OK'
else
    echo "fb-caseL-hy2-query-params(uris='$caseL_uris'):FAIL"
fi
rm -f "$caseL_in"

# ── CASE M: Hysteria v1 / missing version → skipped, no fatal ───────
# The facade has no Hysteria v1 parser; the converter must select out any
# hysteria node whose hysteriaSettings.version is not 2 (and emit nothing),
# WITHOUT aborting/fatal. A v2 node in the same doc must still be emitted.
caseM_in="/tmp/netshift-fb-caseM-$$.json"
cat > "$caseM_in" << 'XRAYJSON'
[
  {
    "remarks": "HY1 + missing + v2",
    "outbounds": [
      {
        "protocol": "hysteria",
        "tag": "hy1",
        "settings": {"address": "v1.example.com", "port": 443},
        "streamSettings": {"network": "hysteria", "security": "tls",
          "tlsSettings": {"serverName": "v1.example.com"},
          "hysteriaSettings": {"version": 1, "auth": "testpass"}}
      },
      {
        "protocol": "hysteria",
        "tag": "hy-noversion",
        "settings": {"address": "nov.example.com", "port": 443},
        "streamSettings": {"network": "hysteria", "security": "tls",
          "tlsSettings": {"serverName": "nov.example.com"},
          "hysteriaSettings": {"auth": "testpass"}}
      },
      {
        "protocol": "hysteria",
        "tag": "hy2",
        "settings": {"address": "v2.example.com", "port": 443},
        "streamSettings": {"network": "hysteria", "security": "tls",
          "tlsSettings": {"serverName": "v2.example.com"},
          "hysteriaSettings": {"version": 2, "auth": "testpass"}}
      }
    ]
  }
]
XRAYJSON
caseM_uris="$(xray_json_to_uri_lines "$caseM_in" 2>/dev/null)"
caseM_rc=$?
# Only the v2 node survives; v1 and missing-version are dropped silently.
caseM_n="$(printf '%s\n' "$caseM_uris" | grep -c .)"
if [ "$caseM_n" = "1" ] \
        && printf '%s\n' "$caseM_uris" | grep -q '@v2.example.com:443' \
        && ! printf '%s\n' "$caseM_uris" | grep -q 'v1.example.com' \
        && ! printf '%s\n' "$caseM_uris" | grep -q 'nov.example.com'; then
    echo 'fb-caseM-v1-and-missing-skipped:OK'
else
    echo "fb-caseM-v1-and-missing-skipped(rc=$caseM_rc n=$caseM_n uris='$caseM_uris'):FAIL"
fi
rm -f "$caseM_in"

# ── CASE N: mixed vless+trojan+ss+hysteria2 each duplicated → dedup ──
# Four distinct nodes (one per protocol), each repeated across three configs
# with only the display tag/remarks differing. The existing $conn dedup must
# collapse them to exactly the four unique connections, first-seen order
# preserved (vless, trojan, ss, hysteria2).
caseN_in="/tmp/netshift-fb-caseN-$$.json"
cat > "$caseN_in" << 'XRAYJSON'
[
  {"remarks": "p1", "outbounds": [
    {"protocol": "vless", "tag": "vl-1", "settings": {"vnext": [{"address": "vl.example.com", "port": 443,
      "users": [{"id": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "vl.example.com", "fingerprint": "firefox"}}},
    {"protocol": "trojan", "tag": "tj-1", "settings": {"servers": [{"address": "tj.example.com", "port": 8443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "tj.example.com"}}},
    {"protocol": "shadowsocks", "tag": "ss-1", "settings": {"servers": [{"address": "ss.example.com", "port": 8388, "password": "testpass", "method": "aes-256-gcm"}]},
      "streamSettings": {"network": "tcp"}},
    {"protocol": "hysteria", "tag": "hy-1", "settings": {"address": "hy.example.com", "port": 443},
      "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "hy.example.com"},
        "hysteriaSettings": {"version": 2, "auth": "testpass"}}}
  ]},
  {"remarks": "p2", "outbounds": [
    {"protocol": "vless", "tag": "vl-2", "settings": {"vnext": [{"address": "vl.example.com", "port": 443,
      "users": [{"id": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "vl.example.com", "fingerprint": "firefox"}}},
    {"protocol": "trojan", "tag": "tj-2", "settings": {"servers": [{"address": "tj.example.com", "port": 8443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "tj.example.com"}}},
    {"protocol": "shadowsocks", "tag": "ss-2", "settings": {"servers": [{"address": "ss.example.com", "port": 8388, "password": "testpass", "method": "aes-256-gcm"}]},
      "streamSettings": {"network": "tcp"}},
    {"protocol": "hysteria", "tag": "hy-2", "settings": {"address": "hy.example.com", "port": 443},
      "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "hy.example.com"},
        "hysteriaSettings": {"version": 2, "auth": "testpass"}}}
  ]},
  {"remarks": "p3", "outbounds": [
    {"protocol": "vless", "tag": "vl-3", "settings": {"vnext": [{"address": "vl.example.com", "port": 443,
      "users": [{"id": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"publicKey": "PK", "shortId": "ab", "serverName": "vl.example.com", "fingerprint": "firefox"}}},
    {"protocol": "trojan", "tag": "tj-3", "settings": {"servers": [{"address": "tj.example.com", "port": 8443, "password": "testpass"}]},
      "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "tj.example.com"}}},
    {"protocol": "shadowsocks", "tag": "ss-3", "settings": {"servers": [{"address": "ss.example.com", "port": 8388, "password": "testpass", "method": "aes-256-gcm"}]},
      "streamSettings": {"network": "tcp"}},
    {"protocol": "hysteria", "tag": "hy-3", "settings": {"address": "hy.example.com", "port": 443},
      "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "hy.example.com"},
        "hysteriaSettings": {"version": 2, "auth": "testpass"}}}
  ]}
]
XRAYJSON
caseN_uris="$(xray_json_to_uri_lines "$caseN_in" 2>/dev/null)"
# 12 raw nodes (4 protocols x 3 profiles) collapse to exactly 4 unique conns.
caseN_n="$(printf '%s\n' "$caseN_uris" | grep -c .)"
if [ "$caseN_n" = "4" ]; then
    echo 'fb-caseN-dedup-count(==4):OK'
else
    echo "fb-caseN-dedup-count(==4 got $caseN_n uris='$caseN_uris'):FAIL"
fi
# First-seen order preserved: vless, trojan, ss, hysteria2 (scheme prefixes).
caseN_schemes="$(printf '%s\n' "$caseN_uris" | sed -e 's#://.*##' | tr '\n' ',' )"
if [ "$caseN_schemes" = "vless,trojan,ss,hysteria2," ]; then
    echo 'fb-caseN-first-seen-order:OK'
else
    echo "fb-caseN-first-seen-order(got '$caseN_schemes'):FAIL"
fi
rm -f "$caseN_in"

# ── CASE O: end-to-end Hysteria2 through the facade + sing-box check ─
# Feed the emitted hysteria2:// URI through normalize_subscription_to_singbox
# (the real subscription path) and assert a hysteria2 outbound is produced
# with the expected server/port/password and TLS. Then wrap the produced
# outbounds into a minimal full sing-box config and assert `sing-box check`
# passes (whole-chain validation; project-core.md §4).
caseO_in="/tmp/netshift-fb-caseO-$$.json"
caseO_out="/tmp/netshift-fb-caseO-out-$$.json"
cat > "$caseO_in" << 'XRAYJSON'
[
  {
    "remarks": "HY2 e2e",
    "outbounds": [
      {
        "protocol": "hysteria",
        "tag": "hy2-e2e",
        "settings": {"address": "e2e.example.com", "port": 8443},
        "streamSettings": {"network": "hysteria", "security": "tls",
          "tlsSettings": {"serverName": "e2e.example.com", "alpn": ["h3"]},
          "hysteriaSettings": {"version": 2, "auth": "testpass"}}
      }
    ]
  }
]
XRAYJSON
if normalize_subscription_to_singbox "$caseO_in" "$caseO_out" "testsub"; then
    echo 'fb-caseO-rc:OK'
else
    echo 'fb-caseO-rc:FAIL'
fi
if validate_subscription_file "$caseO_out"; then
    echo 'fb-caseO-validate:OK'
else
    echo 'fb-caseO-validate:FAIL'
fi
# Exactly one hysteria2 outbound with the expected server/port/password + sni.
if jq -e '[.outbounds[] | select(.type == "hysteria2"
        and .server == "e2e.example.com"
        and .server_port == 8443
        and .password == "testpass"
        and .tls.server_name == "e2e.example.com")] | length == 1' \
        "$caseO_out" > /dev/null 2>&1; then
    echo 'fb-caseO-hy2-outbound-fields:OK'
else
    echo 'fb-caseO-hy2-outbound-fields:FAIL'
fi
# Whole-chain: wrap the produced outbounds into a minimal full config and run
# the real `sing-box check`. Skipped cleanly if the binary is unavailable.
if command -v sing-box > /dev/null 2>&1; then
    caseO_full="/tmp/netshift-fb-caseO-full-$$.json"
    jq '{log: {level: "error"},
         inbounds: [],
         outbounds: (.outbounds + [{type: "direct", tag: "direct-out"}]),
         route: {}}' "$caseO_out" > "$caseO_full" 2>/dev/null
    if sing-box -c "$caseO_full" check > /dev/null 2>&1; then
        echo 'fb-caseO-singbox-check:OK'
    else
        echo 'fb-caseO-singbox-check:FAIL'
    fi
    rm -f "$caseO_full"
else
    echo 'fb-caseO-singbox-check:SKIP'
fi
rm -f "$caseO_in" "$caseO_out"

# ── CASE P: gzip subscription body handling (task-046, issue #13) ───
# All synthetic fixtures (no real node/panel data). The smoke container
# installs gzip (tests/Dockerfile), so we can build a real gzip body in-test.
if command -v gzip > /dev/null 2>&1; then
    # (P1) gzip -> text: gzip a tiny known-good plain body, run the helper,
    # assert the result is the original plain text (byte-equal).
    caseP_plain="/tmp/netshift-fb-caseP-plain-$$.txt"
    caseP_gz="/tmp/netshift-fb-caseP-gz-$$.bin"
    printf 'vless://33333333-3333-3333-3333-333333333333@example.com:443#P\n' > "$caseP_plain"
    gzip -c "$caseP_plain" > "$caseP_gz"
    maybe_gunzip_subscription_file "$caseP_gz"
    if cmp -s "$caseP_gz" "$caseP_plain"; then
        echo 'fb-caseP-gzip-to-text:OK'
    else
        echo 'fb-caseP-gzip-to-text:FAIL'
    fi
    rm -f "$caseP_gz"

    # (P2) non-gzip passthrough: a plain-text body is UNCHANGED (no spurious
    # gunzip, no corruption).
    caseP_pt="/tmp/netshift-fb-caseP-pt-$$.txt"
    caseP_pt_ref="/tmp/netshift-fb-caseP-pt-ref-$$.txt"
    printf 'just plain text, definitely not gzip\nsecond line\n' > "$caseP_pt"
    cp "$caseP_pt" "$caseP_pt_ref"
    maybe_gunzip_subscription_file "$caseP_pt"
    if cmp -s "$caseP_pt" "$caseP_pt_ref"; then
        echo 'fb-caseP-text-passthrough:OK'
    else
        echo 'fb-caseP-text-passthrough:FAIL'
    fi
    rm -f "$caseP_pt" "$caseP_pt_ref" "$caseP_plain"

    # (P3) whole-chain: gzip a small synthetic VALID sing-box JSON, run the
    # helper, then validate_subscription_file -> must now VALIDATE.
    caseP_json="/tmp/netshift-fb-caseP-json-$$.json"
    caseP_jgz="/tmp/netshift-fb-caseP-jgz-$$.bin"
    cat > "$caseP_json" << 'PJSON'
{"outbounds":[{"type":"shadowsocks","tag":"P-node","server":"example.com","server_port":443,"method":"aes-256-gcm","password":"p"}]}
PJSON
    gzip -c "$caseP_json" > "$caseP_jgz"
    maybe_gunzip_subscription_file "$caseP_jgz"
    if validate_subscription_file "$caseP_jgz"; then
        echo 'fb-caseP-gzip-then-validate:OK'
    else
        echo 'fb-caseP-gzip-then-validate:FAIL'
    fi
    rm -f "$caseP_json" "$caseP_jgz"
else
    echo 'fb-caseP-gzip-to-text:SKIP'
    echo 'fb-caseP-text-passthrough:SKIP'
    echo 'fb-caseP-gzip-then-validate:SKIP'
fi

# ── CASE Q: NUL-byte binary detector (task-046) ─────────────────────
# A body with an embedded NUL is binary (true); plain text is not (false).
caseQ_nul="/tmp/netshift-fb-caseQ-nul-$$.bin"
caseQ_txt="/tmp/netshift-fb-caseQ-txt-$$.txt"
printf 'abc\000def' > "$caseQ_nul"
printf 'abcdef\nplain text\n' > "$caseQ_txt"
if subscription_body_is_binary "$caseQ_nul"; then
    echo 'fb-caseQ-nul-is-binary:OK'
else
    echo 'fb-caseQ-nul-is-binary:FAIL'
fi
if subscription_body_is_binary "$caseQ_txt"; then
    echo 'fb-caseQ-text-not-binary:FAIL'
else
    echo 'fb-caseQ-text-not-binary:OK'
fi
rm -f "$caseQ_nul" "$caseQ_txt"

echo 'DONE'
FBEOF

    sed -i "s|LIB_DIR|$lib|g" "$fb"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite.
    local fb_out="/tmp/test-sub-fb-out-$$.log"
    ash "$fb" > "$fb_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$fb_out"
    if [ "$saw_done" = "1" ]; then
        pass "fb-driver-completed:OK"
    else
        fail "fb-driver-completed:FAIL (driver aborted early)"
    fi

    rm -f "$fb" "$fb_out"

    # ── Multi-URL subscription merge (task-022) ─────────────────────
    # Exercises the per-URL hashed cache keying + the config-gen merge-file
    # approach against the REAL facade (live sing-box check bisection). The
    # cache-path builders / URL-hash / URL-list collector / cache-usable /
    # mark-unavailable functions are awk-extracted VERBATIM from the live bin so
    # the test runs shipped code; the merge jq mirrors the inline subscription)
    # branch program exactly. Tokens use the same name:OK/FAIL convention.
    printf "\n  ${BOLD}Multi-URL Subscription Merge${NC}\n"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/sing_box_config_facade.sh" ]; then
        skip "multi-url merge (bin / facade not found)"
        return
    fi

    local mu="/tmp/netshift-sub-multiurl-$$.sh"
    cat > "$mu" << 'MUEOF'
mkdir -p /usr/lib/netshift
for f in constants.sh helpers.sh logging.sh sing_box_config_manager.sh sing_box_config_facade.sh; do
    ln -sf "LIB_DIR/$f" "/usr/lib/netshift/$f"
done
. /usr/lib/netshift/constants.sh
. /usr/lib/netshift/logging.sh
. /usr/lib/netshift/sing_box_config_facade.sh

# Isolated per-run cache dir for the path builders.
SUBSCRIPTION_CACHE_FOLDER="/tmp/netshift-mu-cache-$$"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"

# Quiet logger + redaction stub (functions under test call these).
log() { :; }
echolog() { :; }
nolog() { :; }
redact_url_for_log() { printf '%s' "redacted"; }

# Stub config_list_foreach to feed the URLs of the "current" section from a
# global newline list MU_URLS (mimics UCI list iteration; a 1-element list
# proves the legacy single-option back-compat path).
config_list_foreach() {
    # $1=section $2=option $3=callback [extra...]; we only honour subscription_url.
    # The real LuCI config_list_foreach iterates in the CURRENT shell (no pipe),
    # so the callback CAN mutate accumulator globals; mirror that with a temp
    # file + plain `while read` (a pipe would subshell-trap the mutation).
    [ "$2" = "subscription_url" ] || return 0
    _clf_tmp="/tmp/netshift-mu-clf-$$"
    printf '%s\n' "$MU_URLS" > "$_clf_tmp"
    while IFS= read -r _u || [ -n "$_u" ]; do
        [ -n "$_u" ] || continue
        "$3" "$_u"
    done < "$_clf_tmp"
    rm -f "$_clf_tmp"
}

# Extract the shipped functions verbatim (column-0 opener to column-0 '}').
for fn in get_subscription_url_hash get_subscription_json_path \
          get_subscription_url_cache_path get_subscription_rejected_cache_path \
          get_subscription_user_agent_cache_path _collect_subscription_url_handler \
          get_subscription_urls_for_section reap_legacy_subscription_cache_files \
          subscription_cache_is_usable section_has_usable_subscription_cache \
          mark_subscription_outbound_unavailable; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
done

# Globals the extracted functions touch.
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
subscription_startup_blocked=0

base_config='{"outbounds":[]}'

# Helper: write a per-URL cache for (section,url) from a JSON body.
write_feed() {
    _sec="$1"; _url="$2"; _body="$3"
    _h="$(get_subscription_url_hash "$_url")"
    printf '%s' "$_body" > "$(get_subscription_json_path "$_sec" "$_h")"
    printf '%s' "$_url" > "$(get_subscription_url_cache_path "$_sec" "$_h")"
}

# Helper: build the merged file exactly like the subscription) branch and run
# the facade once. Echoes the resulting config to stdout; sets MERGED_COUNT.
merge_and_add() {
    _sec="$1"
    _merged="/tmp/netshift-mu-merged-$$-$_sec.json"
    printf '%s' '{"outbounds":[]}' > "$_merged"
    MU_URLS="$2"
    printf '%s\n' "$MU_URLS" | while IFS= read -r _u; do
        [ -n "$_u" ] || continue
        _h="$(get_subscription_url_hash "$_u")"
        _j="$(get_subscription_json_path "$_sec" "$_h")"
        subscription_cache_is_usable "$_j" || continue
        _t="${_merged}.t"
        jq -c --slurpfile feed "$_j" '
            .outbounds += [ $feed[0].outbounds[]? | select(
                .type != "selector" and .type != "urltest" and
                .type != "direct" and .type != "dns" and .type != "block"
            ) ]
        ' "$_merged" > "$_t" 2>/dev/null && mv "$_t" "$_merged"
    done
    MERGED_COUNT="$(jq -r '.outbounds | length' "$_merged" 2>/dev/null)"
}

# ── CASE 1: multi-URL merge — two feeds, distinct node names ──────────
s1="sec1"
url1a="https://feed-a.example.com/sub"
url1b="https://feed-b.example.com/sub"
write_feed "$s1" "$url1a" '{"outbounds":[
  {"type":"shadowsocks","tag":"A-Tokyo","server":"a1.example.com","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"A-Osaka","server":"a2.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
write_feed "$s1" "$url1b" '{"outbounds":[
  {"type":"shadowsocks","tag":"B-Berlin","server":"b1.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
s1_urls="$url1a
$url1b"
merge_and_add "$s1" "$s1_urls"
if [ "$MERGED_COUNT" = "3" ]; then
    echo 'mu-case1-merged-count-3:OK'
else
    echo "mu-case1-merged-count-3(got $MERGED_COUNT):FAIL"
fi
# Call the facade like the real bin: NO command-substitution (globals must
# propagate to this shell); read the result from SING_BOX_CF_LAST_CONFIG.
sing_box_cf_add_subscription_outbounds "$base_config" "$s1" "/tmp/netshift-mu-merged-$$-$s1.json" "[]" "[]" >/dev/null
out1="$SING_BOX_CF_LAST_CONFIG"
if printf '%s' "$out1" | jq -e '[.outbounds[] | select(.type=="shadowsocks") | .tag] | (index("A-Tokyo") != null) and (index("A-Osaka") != null) and (index("B-Berlin") != null)' >/dev/null 2>&1; then
    echo 'mu-case1-both-feeds-present:OK'
else
    echo 'mu-case1-both-feeds-present:FAIL'
fi
if [ "$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null)" = "3" ]; then
    echo 'mu-case1-tags-json-3:OK'
else
    echo "mu-case1-tags-json-3(got $(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null)):FAIL"
fi
rm -f "/tmp/netshift-mu-merged-$$-$s1.json"

# ── CASE 2: same-named nodes across feeds → dedup -2 suffix ───────────
s2="sec2"
url2a="https://feed-a2.example.com/sub"
url2b="https://feed-b2.example.com/sub"
write_feed "$s2" "$url2a" '{"outbounds":[
  {"type":"shadowsocks","tag":"Same Node","server":"c1.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
write_feed "$s2" "$url2b" '{"outbounds":[
  {"type":"shadowsocks","tag":"Same Node","server":"c2.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
s2_urls="$url2a
$url2b"
merge_and_add "$s2" "$s2_urls"
sing_box_cf_add_subscription_outbounds "$base_config" "$s2" "/tmp/netshift-mu-merged-$$-$s2.json" "[]" "[]" >/dev/null
out2="$SING_BOX_CF_LAST_CONFIG"
# Two same-named nodes must both survive with distinct deduped tags, and the
# resulting config must have no duplicate outbound tags (would fail sing-box).
n2="$(printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -r 'length' 2>/dev/null)"
dup2="$(printf '%s' "$out2" | jq -r '[.outbounds[].tag] | (length) - ([.[]] | unique | length)' 2>/dev/null)"
if [ "$n2" = "2" ] && [ "$dup2" = "0" ]; then
    echo 'mu-case2-samename-dedup:OK'
else
    echo "mu-case2-samename-dedup(n=$n2 dup=$dup2):FAIL"
fi
# The facade's dedup appends a numeric suffix to the second same-named node
# ("Same Node" + "Same Node-1"); assert one base + one suffixed variant survive.
if printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -e 'any(.[]; . == "Same Node") and any(.[]; (startswith("Same Node-")))' >/dev/null 2>&1; then
    echo 'mu-case2-suffix-dedup-present:OK'
else
    echo "mu-case2-suffix-dedup-present(tags=$SUBSCRIPTION_OUTBOUND_TAGS_JSON):FAIL"
fi
rm -f "/tmp/netshift-mu-merged-$$-$s2.json"

# ── CASE 3: partial failure / best-effort — feed A usable, B invalid ──
s3="sec3"
url3a="https://feed-a3.example.com/sub"
url3b="https://feed-b3.example.com/sub"
write_feed "$s3" "$url3a" '{"outbounds":[
  {"type":"shadowsocks","tag":"Good","server":"d1.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
# Feed B is structurally invalid (not a sing-box object): NOT cache-usable.
_h3b="$(get_subscription_url_hash "$url3b")"
printf '%s' 'this is not json' > "$(get_subscription_json_path "$s3" "$_h3b")"
printf '%s' "$url3b" > "$(get_subscription_url_cache_path "$s3" "$_h3b")"
s3_urls="$url3a
$url3b"
merge_and_add "$s3" "$s3_urls"
sing_box_cf_add_subscription_outbounds "$base_config" "$s3" "/tmp/netshift-mu-merged-$$-$s3.json" "[]" "[]" >/dev/null
out3="$SING_BOX_CF_LAST_CONFIG"
if [ "$MERGED_COUNT" = "1" ] && [ -n "$SUBSCRIPTION_OUTBOUND_TAGS" ]; then
    echo 'mu-case3-partial-best-effort:OK'
else
    echo "mu-case3-partial-best-effort(count=$MERGED_COUNT tags='$SUBSCRIPTION_OUTBOUND_TAGS'):FAIL"
fi
case " $SUBSCRIPTION_UNAVAILABLE_SECTIONS " in
*" $s3 "*) echo 'mu-case3-not-unavailable:FAIL' ;;
*) echo 'mu-case3-not-unavailable:OK' ;;
esac
rm -f "/tmp/netshift-mu-merged-$$-$s3.json"

# ── CASE 4: all feeds fail → section marked unavailable ───────────────
s4="sec4"
url4a="https://feed-a4.example.com/sub"
url4b="https://feed-b4.example.com/sub"
_h4a="$(get_subscription_url_hash "$url4a")"
_h4b="$(get_subscription_url_hash "$url4b")"
printf '%s' 'garbage' > "$(get_subscription_json_path "$s4" "$_h4a")"
printf '%s' '{"outbounds":[]}' > "$(get_subscription_json_path "$s4" "$_h4b")"
s4_urls="$url4a
$url4b"
merge_and_add "$s4" "$s4_urls"
subscription_ready=0
if [ "$MERGED_COUNT" -gt 0 ] 2>/dev/null; then subscription_ready=1; fi
if [ "$subscription_ready" -eq 0 ]; then
    MU_URLS="$s4_urls"
    mark_subscription_outbound_unavailable "$s4" 0
fi
case " $SUBSCRIPTION_UNAVAILABLE_SECTIONS " in
*" $s4 "*) echo 'mu-case4-all-fail-unavailable:OK' ;;
*) echo "mu-case4-all-fail-unavailable(merged=$MERGED_COUNT list='$SUBSCRIPTION_UNAVAILABLE_SECTIONS'):FAIL" ;;
esac
rm -f "/tmp/netshift-mu-merged-$$-$s4.json"

# ── CASE 5: cache-key isolation — distinct files; rejected per-URL ────
s5="sec5"
url5a="https://feed-a5.example.com/sub"
url5b="https://feed-b5.example.com/sub"
write_feed "$s5" "$url5a" '{"outbounds":[
  {"type":"shadowsocks","tag":"Iso-A","server":"e1.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
write_feed "$s5" "$url5b" '{"outbounds":[
  {"type":"shadowsocks","tag":"Iso-B","server":"e2.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
_h5a="$(get_subscription_url_hash "$url5a")"
_h5b="$(get_subscription_url_hash "$url5b")"
p5a="$(get_subscription_json_path "$s5" "$_h5a")"
p5b="$(get_subscription_json_path "$s5" "$_h5b")"
if [ "$_h5a" != "$_h5b" ] && [ "$p5a" != "$p5b" ] && [ -s "$p5a" ] && [ -s "$p5b" ]; then
    echo 'mu-case5-distinct-cache-files:OK'
else
    echo "mu-case5-distinct-cache-files(ha=$_h5a hb=$_h5b):FAIL"
fi
# Poison URL-A's rejected hash with its own body hash → A vetoed, B untouched.
md5sum "$p5a" | awk '{print $1}' > "$(get_subscription_rejected_cache_path "$s5" "$_h5a")"
# Force the rejected-veto path: a body with no proxy outbound + matching hash.
# (subscription_cache_is_usable returns 0 for a body WITH proxies regardless of
# rejected, so prove isolation via the rejected FILE targeting, not the veto.)
ra="$(get_subscription_rejected_cache_path "$s5" "$_h5a")"
rb="$(get_subscription_rejected_cache_path "$s5" "$_h5b")"
if [ -s "$ra" ] && [ ! -e "$rb" ]; then
    echo 'mu-case5-rejected-per-url-isolated:OK'
else
    echo 'mu-case5-rejected-per-url-isolated:FAIL'
fi

# ── CASE 6: back-compat — single (1-element) URL list works ───────────
s6="sec6"
url6="https://feed-legacy.example.com/sub"
write_feed "$s6" "$url6" '{"outbounds":[
  {"type":"shadowsocks","tag":"Legacy","server":"f1.example.com","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
# A lone option reads as a 1-element list.
MU_URLS="$url6"
collected6="$(get_subscription_urls_for_section "$s6")"
if [ "$collected6" = "$url6" ]; then
    echo 'mu-case6-single-option-1elem:OK'
else
    echo "mu-case6-single-option-1elem(got '$collected6'):FAIL"
fi
merge_and_add "$s6" "$url6"
sing_box_cf_add_subscription_outbounds "$base_config" "$s6" "/tmp/netshift-mu-merged-$$-$s6.json" "[]" "[]" >/dev/null
out6="$SING_BOX_CF_LAST_CONFIG"
if [ "$MERGED_COUNT" = "1" ] && printf '%s' "$out6" | jq -e 'any(.outbounds[]; .tag=="Legacy")' >/dev/null 2>&1; then
    echo 'mu-case6-backcompat-config:OK'
else
    echo "mu-case6-backcompat-config(count=$MERGED_COUNT):FAIL"
fi
rm -f "/tmp/netshift-mu-merged-$$-$s6.json"

rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
echo 'DONE'
MUEOF

    sed -i "s|LIB_DIR|$lib|g; s|BIN_PATH|$bin|g" "$mu"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite.
    local mu_out="/tmp/test-sub-mu-out-$$.log"
    sh "$mu" > "$mu_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$mu_out"
    if [ "$saw_done" = "1" ]; then
        pass "mu-driver-completed:OK"
    else
        fail "mu-driver-completed:FAIL (driver aborted early)"
    fi

    rm -f "$mu" "$mu_out"

    # ── Clear-subscription-cache worker (task-039) ───────────────────
    # Exercises subscription_clear_cache_and_redownload (bin/netshift) which
    # backs `component_action subscription clear_cache`. The worker is
    # awk-extracted VERBATIM from the shipped bin; subscription_update is STUBBED
    # to a no-op so the test is hermetic (no network/restart). The driver is
    # parsed in the CURRENT shell (`while read < "$out"`, NO pipe) so the
    # assertions get EXACT state — and we verify both the guarded deletion and
    # the JSON shape the async status layer consumes.
    printf "\n  ${BOLD}Clear Subscription Cache${NC}\n"

    local ccbin="${NETSHIFT_SRC}/usr/bin/netshift"
    local ccupd="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$ccbin" ] || [ ! -r "$ccupd" ]; then
        skip "clear-cache worker (bin / updater.sh not found)"
        return
    fi

    local cc="/tmp/netshift-sub-clearcache-$$.sh"
    cat > "$cc" << 'CCEOF'
# Isolated synthetic cache dir — NEVER the real /etc/netshift/subscriptions.
SUBSCRIPTION_CACHE_FOLDER="/tmp/netshift-cc-cache-$$"

# Quiet logger; record subscription_update invocation count + control its rc.
SUB_UPDATE_CALLS=0
SUB_UPDATE_RC=0
log() { :; }
echolog() { :; }
nolog() { :; }
# Hermetic no-op stub for the redownload+restart path (verbatim reuse is what
# the production worker does; here we only assert the worker CALLS it).
subscription_update() { SUB_UPDATE_CALLS=$((SUB_UPDATE_CALLS + 1)); return "$SUB_UPDATE_RC"; }

# config_foreach / config_get stubs driven by the CC_SECTIONS table:
#   CC_SECTIONS = newline list of "<section>|<connection_type>|<proxy_config_type>"
config_foreach() {
    # $1=callback $2=type ; iterate sections in the CURRENT shell (no pipe) so
    # the callback can mutate accumulator globals like has_subscription.
    _cf_tmp="/tmp/netshift-cc-cf-$$"
    printf '%s\n' "$CC_SECTIONS" > "$_cf_tmp"
    while IFS= read -r _row || [ -n "$_row" ]; do
        [ -n "$_row" ] || continue
        CC_CUR_SECTION="${_row%%|*}"
        _rest="${_row#*|}"
        CC_CUR_CT="${_rest%%|*}"
        CC_CUR_PCT="${_rest##*|}"
        "$1" "$CC_CUR_SECTION"
    done < "$_cf_tmp"
    rm -f "$_cf_tmp"
}
config_get() {
    # $1=varname $2=section $3=option [default]
    case "$3" in
        connection_type) eval "$1=\"\$CC_CUR_CT\"" ;;
        proxy_config_type) eval "$1=\"\$CC_CUR_PCT\"" ;;
        *) eval "$1=\"\${4:-}\"" ;;
    esac
}

# Extract the worker VERBATIM from the shipped bin (column-0 opener → column-0 '}').
eval "$(awk '/^subscription_clear_cache_and_redownload\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^foreach_active_section\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^_active_section_dispatch\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
# The stubbed sections in this harness are never disabled.
section_is_disabled() { return 1; }

# Seed helper: write the four per-feed sidecars for a synthetic (section,hash).
seed_feed() {
    _s="$1"; _h="$2"
    printf 'json'  > "$SUBSCRIPTION_CACHE_FOLDER/${_s}.${_h}.json"
    printf 'url'   > "$SUBSCRIPTION_CACHE_FOLDER/${_s}.${_h}.url"
    printf 'rej'   > "$SUBSCRIPTION_CACHE_FOLDER/${_s}.${_h}.rejected"
    printf 'ua'    > "$SUBSCRIPTION_CACHE_FOLDER/${_s}.${_h}.user_agent"
}

# ── CASE 1: ≥2 feeds seeded, sections configured → all files deleted, dir
#            preserved, subscription_update called, JSON success:true ───────
rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
seed_feed "sec1" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
seed_feed "sec1" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
seed_feed "sec2" "cccccccccccccccccccccccccccccccc"
before_count=$(ls -1 "$SUBSCRIPTION_CACHE_FOLDER" 2>/dev/null | wc -l)
CC_SECTIONS="sec1|proxy|subscription
sec2|proxy|subscription"
SUB_UPDATE_CALLS=0
SUB_UPDATE_RC=0
# Run WITHOUT $()-capture so SUB_UPDATE_CALLS (set by the stub) survives — a
# $() subshell would trap the mutation (the documented capture landmine).
cc1_out="/tmp/netshift-cc-json1-$$"
subscription_clear_cache_and_redownload > "$cc1_out"
cc1_rc=$?
cc1_json="$(cat "$cc1_out")"
rm -f "$cc1_out"
after_count=$(ls -1 "$SUBSCRIPTION_CACHE_FOLDER" 2>/dev/null | wc -l)
if [ "$before_count" -ge 8 ] && [ "$after_count" -eq 0 ]; then
    echo "cc-case1-all-deleted(before=$before_count after=$after_count):OK"
else
    echo "cc-case1-all-deleted(before=$before_count after=$after_count):FAIL"
fi
if [ -d "$SUBSCRIPTION_CACHE_FOLDER" ]; then
    echo 'cc-case1-dir-preserved:OK'
else
    echo 'cc-case1-dir-preserved:FAIL'
fi
if printf '%s' "$cc1_json" | jq -e '.success == true' >/dev/null 2>&1; then
    echo 'cc-case1-json-success-true:OK'
else
    echo "cc-case1-json-success-true(got '$cc1_json'):FAIL"
fi
if [ "$SUB_UPDATE_CALLS" -eq 1 ] && [ "$cc1_rc" -eq 0 ]; then
    echo 'cc-case1-redownload-invoked:OK'
else
    echo "cc-case1-redownload-invoked(calls=$SUB_UPDATE_CALLS rc=$cc1_rc):FAIL"
fi

# ── CASE 2: empty cache dir → graceful success:true ──────────────────
rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
CC_SECTIONS="sec1|proxy|subscription"
SUB_UPDATE_CALLS=0
cc2_json="$(subscription_clear_cache_and_redownload)"
if printf '%s' "$cc2_json" | jq -e '.success == true' >/dev/null 2>&1; then
    echo 'cc-case2-empty-dir-success:OK'
else
    echo "cc-case2-empty-dir-success(got '$cc2_json'):FAIL"
fi

# ── CASE 2b: missing cache dir → graceful success:true, no error ─────
rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
CC_SECTIONS="sec1|proxy|subscription"
cc2b_json="$(subscription_clear_cache_and_redownload 2>/dev/null)"
if printf '%s' "$cc2b_json" | jq -e '.success == true' >/dev/null 2>&1; then
    echo 'cc-case2b-missing-dir-success:OK'
else
    echo "cc-case2b-missing-dir-success(got '$cc2b_json'):FAIL"
fi
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"

# ── CASE 3: no subscription sections → graceful success:true, no redownload ─
rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
seed_feed "sec1" "dddddddddddddddddddddddddddddddd"
CC_SECTIONS="sec1|proxy|url"
SUB_UPDATE_CALLS=0
cc3_out="/tmp/netshift-cc-json3-$$"
subscription_clear_cache_and_redownload > "$cc3_out"
cc3_json="$(cat "$cc3_out")"
rm -f "$cc3_out"
cc3_after=$(ls -1 "$SUBSCRIPTION_CACHE_FOLDER" 2>/dev/null | wc -l)
if printf '%s' "$cc3_json" | jq -e '.success == true' >/dev/null 2>&1 \
   && [ "$SUB_UPDATE_CALLS" -eq 0 ] && [ "$cc3_after" -eq 0 ]; then
    echo 'cc-case3-no-subs-graceful:OK'
else
    echo "cc-case3-no-subs-graceful(calls=$SUB_UPDATE_CALLS after=$cc3_after json='$cc3_json'):FAIL"
fi

# ── CASE 4: redownload failure → success:false, message surfaced ─────
rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
seed_feed "sec1" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
CC_SECTIONS="sec1|proxy|subscription"
SUB_UPDATE_RC=1
cc4_json="$(subscription_clear_cache_and_redownload)"
SUB_UPDATE_RC=0
if printf '%s' "$cc4_json" | jq -e '.success == false and (.message | length > 0)' >/dev/null 2>&1; then
    echo 'cc-case4-redownload-fail-surfaced:OK'
else
    echo "cc-case4-redownload-fail-surfaced(got '$cc4_json'):FAIL"
fi

# ── CASE 5: guarded delete — empty constant can NEVER `rm -f /*` ─────
# Structural proof: the worker only deletes when the constant is non-empty AND
# the dir exists. Point the constant at a guarded sentinel tree and confirm an
# UNRELATED file outside SUBSCRIPTION_CACHE_FOLDER survives, and that an empty
# constant is a no-op (guard short-circuits before any glob).
guard_root="/tmp/netshift-cc-guard-$$"
rm -rf "$guard_root"
mkdir -p "$guard_root/sub" "$guard_root/other"
printf 'keep' > "$guard_root/other/sentinel"
printf 'wipe' > "$guard_root/sub/feed.json"
SUBSCRIPTION_CACHE_FOLDER="$guard_root/sub"
CC_SECTIONS="sec1|proxy|subscription"
subscription_clear_cache_and_redownload >/dev/null 2>&1
if [ -f "$guard_root/other/sentinel" ] && [ ! -f "$guard_root/sub/feed.json" ] \
   && [ -d "$guard_root/sub" ]; then
    echo 'cc-case5-guard-scoped-to-cache-dir:OK'
else
    echo 'cc-case5-guard-scoped-to-cache-dir:FAIL'
fi
# Empty constant → guard short-circuits, sentinel still alive, no error.
SUBSCRIPTION_CACHE_FOLDER=""
CC_SECTIONS="sec1|proxy|subscription"
subscription_clear_cache_and_redownload >/dev/null 2>&1
if [ -f "$guard_root/other/sentinel" ]; then
    echo 'cc-case5-empty-constant-noop:OK'
else
    echo 'cc-case5-empty-constant-noop:FAIL'
fi
rm -rf "$guard_root"

# ── CASE 6: router dispatch — `component_action subscription clear_cache`
#            reaches the worker (also the path the async fork uses) ──────────
# Source the SHIPPED updater.sh component_action(); the worker is already defined
# above, so the arm must dispatch to it. Re-point the cache dir + a fresh stub
# that records the call so we prove the arm reached our worker.
ROUTER_HIT=0
subscription_clear_cache_and_redownload() {
    ROUTER_HIT=1
    echo '{"success":true,"message":"router-hit"}'
    return 0
}
# Silence updater.sh's own logger if it defines one after sourcing.
eval "$(awk '/^component_action\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "UPD_PATH")"
# No $()-capture (would subshell-trap ROUTER_HIT); write JSON to a file.
router_out="/tmp/netshift-cc-router-$$"
component_action subscription clear_cache > "$router_out"
router_json="$(cat "$router_out")"
rm -f "$router_out"
if [ "$ROUTER_HIT" -eq 1 ] && printf '%s' "$router_json" | jq -e '.success == true' >/dev/null 2>&1; then
    echo 'cc-case6-router-dispatch:OK'
else
    echo "cc-case6-router-dispatch(hit=$ROUTER_HIT json='$router_json'):FAIL"
fi

rm -rf "/tmp/netshift-cc-cache-$$"
echo 'DONE'
CCEOF

    sed -i "s|BIN_PATH|$ccbin|g; s|UPD_PATH|$ccupd|g" "$cc"

    local cc_out="/tmp/netshift-cc-out-$$"
    sh "$cc" > "$cc_out" 2>/dev/null
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done < "$cc_out"

    rm -f "$cc" "$cc_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: "Fastest" cross-group urltest of urltests (task-050)
#
# When subscription grouping is ON (country/prefix) and there are >= 2 groups,
# the grouped branch in bin/netshift adds a top-level urltest tagged
# $SB_SUBSCRIPTION_FASTEST_GROUP_TAG whose members are the per-group urltests
# ("<key> Fastest"), PREPENDS it to the main selector, and makes it the selector
# default. Groups + ungrouped stay selectable. groups==1 -> no nested layer
# (default = lone group). off -> flat urltest+selector unchanged.
#
# The grouped branch is inline shell inside configure_outbound_handler (not its
# own function), so we awk-extract that exact code region VERBATIM out of the
# live bin (from the branch's `local grouping_json ...` decl through the final
# grouped selector build) and wrap it in a driver function — the test exercises
# the SHIPPED logic, not a copy. We seed $config with synthetic flag-tagged
# shadowsocks outbounds (no real subscription data) so the generated config can
# be fed to `sing-box check`. Tokens use the name:OK/FAIL convention; the driver
# output is parsed in the CURRENT shell (no pipe) so the tokens GATE CI.
# ─────────────────────────────────────────────────────────────────
test_fastest_group() {
    header "Fastest Cross-Group urltest (task-050)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local constants="${NETSHIFT_LIB_DIR}/constants.sh"
    local manager="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    if [ ! -r "$bin" ] || [ ! -r "$constants" ] || [ ! -r "$manager" ]; then
        skip "netshift bin / constants.sh / config_manager.sh not found"
        return
    fi

    local work="/tmp/netshift-fastest-$$"
    mkdir -p "$work"
    local drv="$work/driver.sh"

    cat > "$drv" << 'FGEOF'
# Quiet logger (the grouped branch logs at info/debug/fatal; never let a fatal
# log mask the real exit code — the branch calls `exit 1` itself on failure).
log() { :; }
echolog() { :; }
nolog() { :; }

# Real constant ($SB_SUBSCRIPTION_FASTEST_GROUP_TAG) + cm primitives.
. "CONSTANTS_PATH"
. "MANAGER_PATH"

# Pull the shipped helpers VERBATIM out of the live bin so we test shipped code.
eval "$(awk '/^sing_box_get_unique_outbound_tag\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^sing_box_build_subscription_groups\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

# Extract the WHOLE grouping if/else region VERBATIM (the grouped `then` branch
# AND the flat `off` `else` branch) and wrap it as a function so we can drive
# both modes against the SHIPPED code. The leading `if ...; then local ...`
# line is valid inside this wrapper.
_grouped_branch() {
EXTRACT_GROUPED
}

# The off branch derives its urltest tag via get_outbound_tag_by_section; the
# grouped branch derives only $selector_tag (which we set ourselves). Stub it
# deterministically (synthetic, no real data).
get_outbound_tag_by_section() { printf '%s-out' "$1"; }

run_case() {
    # $1 = group_mode, $2 = prefix_len, $3 = tags-json, $4 = base config (with
    # the synthetic outbounds), $5 = selector tag. Echoes the resulting config.
    group_mode="$1"
    prefix_len="$2"
    subscription_outbound_tags_json="$3"
    config="$4"
    selector_tag="$5"
    section="syn"
    urltest_testing_url="https://www.gstatic.com/generate_204"
    urltest_check_interval="3m0s"
    urltest_tolerance="50"
    selector_outbounds=""
    selector_default=""
    _grouped_branch
    printf '%s' "$config"
}
FGEOF

    # Build the synthetic outbound set: two country groups (RU/DE flags) with two
    # nodes each + one ungrouped node. Flags are regional-indicator pairs built
    # by codepoint so NO real subscription identifiers appear anywhere.
    local synth_json
    synth_json="$(jq -cn '
        def flag($a; $b): ([127462 + $a, 127462 + $b] | implode);
        (flag(17; 20)) as $ru   # RU
        | (flag(3; 4))  as $de  # DE
        | {
            outbounds: [
                {type:"shadowsocks", tag:($ru + " N1"), server:"10.0.0.1", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"shadowsocks", tag:($ru + " N2"), server:"10.0.0.2", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"shadowsocks", tag:($de + " N1"), server:"10.0.0.3", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"shadowsocks", tag:($de + " N2"), server:"10.0.0.4", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"shadowsocks", tag:"plain-node",  server:"10.0.0.5", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"direct", tag:"direct-out"}
            ]
        }')"
    local tags_json
    tags_json="$(printf '%s' "$synth_json" | jq -c '[.outbounds[] | select(.type=="shadowsocks") | .tag]')"

    # Single-group set: only RU nodes (no DE, no ungrouped).
    local synth1_json synth1_tags
    synth1_json="$(jq -cn '
        def flag($a; $b): ([127462 + $a, 127462 + $b] | implode);
        (flag(17; 20)) as $ru
        | {
            outbounds: [
                {type:"shadowsocks", tag:($ru + " N1"), server:"10.0.1.1", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"shadowsocks", tag:($ru + " N2"), server:"10.0.1.2", server_port:443, method:"aes-256-gcm", password:"p"},
                {type:"direct", tag:"direct-out"}
            ]
        }')"
    synth1_tags="$(printf '%s' "$synth1_json" | jq -c '[.outbounds[] | select(.type=="shadowsocks") | .tag]')"

    # Substitute the awk-extracted grouped-branch region into the driver. The
    # region is plain shell statements; sed reads it from the live bin between
    # the unique markers and writes it where EXTRACT_GROUPED sits.
    local region="$work/region.sh"
    # Capture from the `if [ "$group_mode" != "off" ]; then` opener through the
    # off-branch's final selector build line and the immediately following `fi`
    # that closes the if/else (q-flag stops after that fi).
    awk '
        /if \[ "\$group_mode" != "off" \]; then/{p=1}
        p{print}
        p && /"\$urltest_tag" "true"\)"/{seen_else_end=1; next}
        seen_else_end && /^[[:space:]]*fi$/{exit}
    ' "$bin" > "$region"
    # Confirm the region captured BOTH branches: the fastest prepend (grouped),
    # the cm urltest call, and the off-branch closing.
    if grep -q 'SB_SUBSCRIPTION_FASTEST_GROUP_TAG' "$region" \
        && grep -q 'sing_box_cm_add_urltest_outbound' "$region" \
        && grep -q 'Create urltest + selector' "$region"; then
        pass "fastest-region-extracted:OK"
    else
        fail "fastest-region-extracted:FAIL" "$(head -5 "$region" 2>/dev/null)"
    fi

    # Splice region into the driver in place of the EXTRACT_GROUPED placeholder
    # (use an r-command via a temp because the region contains arbitrary chars).
    {
        sed '/EXTRACT_GROUPED/q' "$drv" | sed '$d'
        cat "$region"
        sed -n '/EXTRACT_GROUPED/,$p' "$drv" | sed '1d'
    } > "$drv.spliced"
    mv "$drv.spliced" "$drv"
    sed -i "s|CONSTANTS_PATH|$constants|g;s|MANAGER_PATH|$manager|g;s|BIN_PATH|$bin|g" "$drv"

    # ── >= 2 groups (country mode): nested Fastest urltest + selector default ──
    local out2="$work/out2.json"
    {
        echo ". \"$drv\""
        echo "run_case country 2 '$tags_json' '$synth_json' 'syn-out'"
    } > "$work/run2.sh"
    ash "$work/run2.sh" > "$out2" 2>/dev/null || true

    # The deduped fastest tag (the constant; no collision in our synthetic set).
    local fastest_expected ru_tag de_tag
    fastest_expected="$(. "$constants"; printf '%s' "$SB_SUBSCRIPTION_FASTEST_GROUP_TAG")"
    ru_tag="$(printf '%s' "$synth_json" | jq -r '.outbounds[0].tag' | sed 's/ N1$//') Fastest"
    de_tag="$(printf '%s' "$synth_json" | jq -r '.outbounds[2].tag' | sed 's/ N1$//') Fastest"

    # (a) Top-level urltest tagged the fastest tag whose outbounds are EXACTLY
    #     the per-group urltest tags.
    if jq -e --arg t "$fastest_expected" --arg g1 "$ru_tag" --arg g2 "$de_tag" '
        ([.outbounds[] | select(.type=="urltest" and .tag==$t)]) as $f
        | ($f | length) == 1
        and ($f[0].outbounds == [$g1, $g2])
    ' "$out2" > /dev/null 2>&1; then
        pass "fastest-nested-urltest-members:OK"
    else
        fail "fastest-nested-urltest-members:FAIL" "$(jq -c '[.outbounds[]|select(.type=="urltest")|{tag,outbounds}]' "$out2" 2>/dev/null)"
    fi

    # (b) Main selector default == fastest tag, and outbounds ==
    #     [fastest, group1, group2, ungrouped...].
    if jq -e --arg t "$fastest_expected" --arg g1 "$ru_tag" --arg g2 "$de_tag" '
        ([.outbounds[] | select(.type=="selector" and .tag=="syn-out")]) as $s
        | ($s | length) == 1
        and ($s[0].default == $t)
        and ($s[0].outbounds == [$t, $g1, $g2, "plain-node"])
    ' "$out2" > /dev/null 2>&1; then
        pass "fastest-selector-default-membership:OK"
    else
        fail "fastest-selector-default-membership:FAIL" "$(jq -c '.outbounds[]|select(.type=="selector")|{tag,default,outbounds}' "$out2" 2>/dev/null)"
    fi

    # (c) sing-box check PASSES on the generated config WITH the nested urltest.
    if command -v sing-box > /dev/null 2>&1; then
        local chk2="$work/check2.json"
        # Wrap the outbounds into a minimal full config sing-box can validate.
        jq '{
            log: {disabled:true},
            dns: {servers: [], rules: [], final: "direct"},
            inbounds: [{type:"direct", tag:"dns-in", listen:"127.0.0.42", listen_port:53}],
            outbounds: .outbounds,
            route: {rules: [], rule_set: [], final: "direct-out", auto_detect_interface: true}
        }' "$out2" > "$chk2" 2>/dev/null
        if sing-box -c "$chk2" check > /dev/null 2>&1; then
            pass "fastest-singbox-check-passes:OK"
        else
            fail "fastest-singbox-check-passes:FAIL" "$(sing-box -c "$chk2" check 2>&1 | head -3)"
        fi
    else
        skip "fastest-singbox-check-passes (sing-box not installed)"
    fi

    # (d) groups==1 -> NO redundant nested urltest; default = lone group.
    local out1="$work/out1.json"
    {
        echo ". \"$drv\""
        echo "run_case country 2 '$synth1_tags' '$synth1_json' 'syn1-out'"
    } > "$work/run1.sh"
    ash "$work/run1.sh" > "$out1" 2>/dev/null || true
    local lone_group
    lone_group="$(printf '%s' "$synth1_json" | jq -r '.outbounds[0].tag' | sed 's/ N1$//') Fastest"
    if jq -e --arg t "$fastest_expected" --arg lone "$lone_group" '
        ([.outbounds[] | select(.type=="urltest" and .tag==$t)] | length) == 0
        and ([.outbounds[] | select(.type=="selector" and .tag=="syn1-out")][0].default == $lone)
    ' "$out1" > /dev/null 2>&1; then
        pass "fastest-single-group-no-nest:OK"
    else
        fail "fastest-single-group-no-nest:FAIL" "$(jq -c '[.outbounds[]|select(.type=="urltest" or .type=="selector")|{type,tag,default}]' "$out1" 2>/dev/null)"
    fi

    # (e) off mode unchanged (regression): flat urltest + selector, NO fastest
    #     tag, selector default == the flat urltest tag (<section>-urltest-out).
    local outoff="$work/outoff.json"
    {
        echo ". \"$drv\""
        echo "run_case off 2 '$tags_json' '$synth_json' 'syn-out'"
    } > "$work/runoff.sh"
    ash "$work/runoff.sh" > "$outoff" 2>/dev/null || true
    if jq -e --arg t "$fastest_expected" '
        ([.outbounds[] | select(.type=="urltest" and .tag==$t)] | length) == 0
        and ([.outbounds[] | select(.type=="urltest")] | length) == 1
        and ([.outbounds[] | select(.type=="selector" and .tag=="syn-out")][0].default
              == "syn-urltest-out")
    ' "$outoff" > /dev/null 2>&1; then
        pass "fastest-off-mode-unchanged:OK"
    else
        fail "fastest-off-mode-unchanged:FAIL" "$(jq -c '[.outbounds[]|select(.type=="urltest" or .type=="selector")|{type,tag,default}]' "$outoff" 2>/dev/null)"
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: per-subscription urltest groups (several subscription_url in one section)
#
# A subscription section with two or more feeds gets, next to the section-wide
# "<section>-urltest-out", one urltest per feed ("⚡ <feed name>") so the
# dashboard can show every subscription in its own block with its own Fastest.
# Covers the shipped pieces end to end: the feed display name, the merge that
# stamps every node with its feed index, the section loop that computes the
# index and the names, the REAL facade carrying that index through keyword
# filter / tag dedup / sing-box check bisection (a rejected node forces the
# split), the feed grouper, the flat (group_mode=off) branch extracted verbatim
# from the bin, and the #fragment-blind .url sidecar check at startup.
# Synthetic hosts/tags only. Tokens use the name:OK/FAIL convention.
# ─────────────────────────────────────────────────────────────────
test_feed_groups() {
    header "Per-Subscription urltest Groups"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="$NETSHIFT_LIB_DIR"
    if [ ! -r "$bin" ] || [ ! -r "$lib/sing_box_config_facade.sh" ]; then
        skip "netshift bin / facade not found"
        return
    fi

    local work="/tmp/netshift-feedgroups-$$"
    mkdir -p "$work"
    local drv="$work/driver.sh"

    cat > "$drv" << 'FDEOF'
mkdir -p /usr/lib/netshift
for f in constants.sh helpers.sh logging.sh sing_box_config_manager.sh sing_box_config_facade.sh; do
    ln -sf "LIB_DIR/$f" "/usr/lib/netshift/$f"
done
. /usr/lib/netshift/constants.sh
. /usr/lib/netshift/logging.sh
. /usr/lib/netshift/sing_box_config_facade.sh
log() { :; }
echolog() { :; }
nolog() { :; }
is_sing_box_extended() { return 0; }

for fn in sing_box_get_unique_outbound_tag sing_box_build_subscription_feed_groups \
          get_subscription_feed_display_name subscription_merge_feed_outbounds \
          get_subscription_url_hash subscription_merge_section_feeds \
          get_subscription_json_path get_subscription_url_cache_path \
          subscription_url_cache_matches subscription_cache_is_usable \
          prepare_subscription_cache_for_startup reap_orphan_subscription_cache_files; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
done
get_outbound_tag_by_section() { printf '%s-out' "$1"; }

_off_branch() {
EXTRACT_OFF
}

# $1 = tags json, $2 = feeds json ("" = unset), $3 = names json, $4 = config
run_off() {
    section="syn"
    selector_tag="syn-out"
    subscription_outbound_tags_json="$1"
    subscription_outbound_feeds_json="$2"
    subscription_feed_names_json="$3"
    config="$4"
    urltest_testing_url="https://www.gstatic.com/generate_204"
    urltest_check_interval="3m"
    urltest_tolerance="50"
    selector_outbounds=""
    _off_branch
    printf '%s' "$config"
}

ok() { echo "$1:OK"; }
bad() { echo "$1:FAIL $2"; }
expect_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "(got '$2', want '$3')"; fi
}

# ── Feed display name ─────────────────────────────────────────────
expect_eq fg-name-fragment "$(get_subscription_feed_display_name 'https://sub.example.com/api/TOKEN#My%20VPN' x)" "My VPN"
expect_eq fg-name-fragment-plus "$(get_subscription_feed_display_name 'https://sub.example.com/x#My+VPN' x)" "My VPN"
expect_eq fg-name-fragment-utf8 "$(get_subscription_feed_display_name 'https://sub.example.com/x#%D0%A0%D0%A4' x)" "РФ"
expect_eq fg-name-fragment-ctrl "$(get_subscription_feed_display_name 'https://sub.example.com/x#A%0AB%09C' x)" "ABC"
expect_eq fg-name-host "$(get_subscription_feed_display_name 'https://sub.example.com/api/TOKEN?x=1' x)" "sub.example.com"
expect_eq fg-name-empty-fragment "$(get_subscription_feed_display_name 'https://sub.example.com/p#' x)" "sub.example.com"
expect_eq fg-name-userinfo-port "$(get_subscription_feed_display_name 'https://u:p@sub.example.com:8443/p' x)" "sub.example.com"
expect_eq fg-name-at-in-path "$(get_subscription_feed_display_name 'https://sub.example.com/a@b/c' x)" "sub.example.com"
expect_eq fg-name-ipv6 "$(get_subscription_feed_display_name 'https://[2001:db8::1]:8443/p' x)" "2001:db8::1"
expect_eq fg-name-fallback "$(get_subscription_feed_display_name 'not a url/' 'Subscription 2')" "Subscription 2"
expect_eq fg-name-fragment-trim "$(get_subscription_feed_display_name 'https://sub.example.com/x#%20%20My%20VPN%20' x)" "My VPN"
expect_eq fg-name-fragment-blank "$(get_subscription_feed_display_name 'https://sub.example.com/x#%20%09' x)" "sub.example.com"
expect_eq fg-name-fragment-nbsp "$(get_subscription_feed_display_name 'https://sub.example.com/x#%C2%A0' x)" "sub.example.com"
expect_eq fg-name-fragment-unicode-blank \
    "$(get_subscription_feed_display_name 'https://sub.example.com/x#%E3%80%80%E2%80%8B%E2%80%AF%EF%BB%BF' x)" "sub.example.com"
expect_eq fg-name-fragment-unicode-trim \
    "$(get_subscription_feed_display_name 'https://sub.example.com/x#%E2%80%83My%C2%A0VPN%E3%80%80' x)" "$(printf 'My\302\240VPN')"

# ── The fragment is only a name: not hashed, never fetched ────────
expect_eq fg-hash-ignores-fragment \
    "$(get_subscription_url_hash 'https://sub.example.com/api/TOKEN#My%20VPN')" \
    "$(get_subscription_url_hash 'https://sub.example.com/api/TOKEN')"
if [ "$(get_subscription_url_hash 'https://sub.example.com/api/A')" != "$(get_subscription_url_hash 'https://sub.example.com/api/B')" ]; then
    ok fg-hash-distinct-urls
else
    bad fg-hash-distinct-urls
fi

# Fake wget: logs its URL (last argument), writes a body to its -O target.
fg_bin="/tmp/fg-bin-$$"
mkdir -p "$fg_bin"
cat > "$fg_bin/wget" << 'FGWEOF'
#!/bin/sh
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-O" ] && out="$a"
    prev="$a"
    last="$a"
done
printf '%s\n' "$last" >> "$FG_WGET_LOG"
[ -n "$out" ] && [ "$out" != /dev/null ] && printf 'body' > "$out"
exit 0
FGWEOF
chmod 0755 "$fg_bin/wget"
FG_WGET_LOG="/tmp/fg-wget-$$.log"
export FG_WGET_LOG
get_sing_box_version() { echo "1.12.0"; }
get_device_model() { echo "test-model"; }
get_kernel_version() { echo "test-kernel"; }
generate_hwid() { echo "test-hwid"; }
should_force_wget_ipv4() { return 1; }
has_ipv4_default_route() { return 1; }
wget_supports_ipv4_flag() { return 1; }
fg_path="$PATH"
PATH="$fg_bin:$PATH"
: > "$FG_WGET_LOG"
download_subscription 'https://sub.example.com/sub?x=1#My%20VPN' "/tmp/fg-dl-$$" "" 1 0 5 "ua/test" 0 > /dev/null 2>&1
expect_eq fg-download-drops-fragment "$(cat "$FG_WGET_LOG")" "https://sub.example.com/sub?x=1"
: > "$FG_WGET_LOG"
download_subscription 'https://sub.example.com/sub#My%20VPN' "/tmp/fg-dl-$$" "127.0.0.1:4534" 1 0 5 "ua/test" 0 > /dev/null 2>&1
expect_eq fg-download-proxy-drops-fragment "$(cat "$FG_WGET_LOG")" "https://sub.example.com/sub"
: > "$FG_WGET_LOG"
check_subscription_connectivity 'https://sub.example.com/sub?x=1#My%20VPN' "" 1 0 5 > /dev/null 2>&1
expect_eq fg-connectivity-drops-fragment "$(cat "$FG_WGET_LOG")" "https://sub.example.com/sub?x=1"
PATH="$fg_path"
rm -rf "$fg_bin" "$FG_WGET_LOG" "/tmp/fg-dl-$$"

# ── Merge stamps the feed index ───────────────────────────────────
feed_a="/tmp/fg-feed-a-$$.json"
feed_b="/tmp/fg-feed-b-$$.json"
feed_bad="/tmp/fg-feed-bad-$$.json"
merged="/tmp/fg-merged-$$.json"
printf '%s' '{"outbounds":[
  {"type":"shadowsocks","tag":"A-1","server":"10.1.0.1","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"Same","server":"10.1.0.2","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"A-drop","server":"10.1.0.3","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"selector","tag":"sel","outbounds":["A-1"]},
  {"type":"direct","tag":"direct"}
]}' > "$feed_a"
printf '%s' '{"outbounds":[
  {"type":"shadowsocks","tag":"Same","server":"10.2.0.1","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"B-2","server":"10.2.0.2","server_port":443,"method":"aes-256-gcm","password":"p"}
]}' > "$feed_b"
printf '%s' 'not json' > "$feed_bad"
printf '%s' '{"outbounds":[]}' > "$merged"

subscription_merge_feed_outbounds "$merged" "$feed_a" 0 && ok fg-merge-a-rc || bad fg-merge-a-rc
if subscription_merge_feed_outbounds "$merged" "$feed_bad" 1; then bad fg-merge-bad-rc; else ok fg-merge-bad-rc; fi
subscription_merge_feed_outbounds "$merged" "$feed_b" 2 && ok fg-merge-b-rc || bad fg-merge-b-rc
expect_eq fg-merge-feeds "$(jq -c --arg k "$SUBSCRIPTION_FEED_MARKER_KEY" '[.outbounds[] | .[$k]]' "$merged")" "[0,0,0,2,2]"
expect_eq fg-merge-proxies-only "$(jq -c '[.outbounds[].type] | unique' "$merged")" '["shadowsocks"]'

# ── Facade carries the feed index through filter / dedup / check ──
base_config='{"outbounds":[{"type":"direct","tag":"direct-out"}]}'
sing_box_cf_add_subscription_outbounds "$base_config" "syn" "$merged" '[]' '["drop"]' > /dev/null
out_cfg="$SING_BOX_CF_LAST_CONFIG"
expect_eq fg-facade-tags "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" '["A-1","Same","Same-1","B-2"]'
expect_eq fg-facade-feeds "$SUBSCRIPTION_OUTBOUND_FEEDS_JSON" '[0,0,2,2]'
expect_eq fg-facade-marker-stripped \
    "$(printf '%s' "$out_cfg" | jq -r --arg k "$SUBSCRIPTION_FEED_MARKER_KEY" '[.outbounds[] | select(has($k))] | length')" "0"

# Unmarked input (no marker key) keeps working; feeds are all null.
unmarked="/tmp/fg-unmarked-$$.json"
cp "$feed_b" "$unmarked"
sing_box_cf_add_subscription_outbounds "$base_config" "syn" "$unmarked" '[]' '[]' > /dev/null
expect_eq fg-facade-unmarked-feeds "$SUBSCRIPTION_OUTBOUND_FEEDS_JSON" '[null,null]'

# ── Feed grouper ──────────────────────────────────────────────────
expect_eq fg-groups-two \
    "$(sing_box_build_subscription_feed_groups '["a","b","c","d"]' '[0,2,0,2]' '["Feed A","dead","Feed C"]')" \
    '[{"name":"Feed A","tags":["a","c"]},{"name":"Feed C","tags":["b","d"]}]'
expect_eq fg-groups-null-feeds \
    "$(sing_box_build_subscription_feed_groups '["a","b"]' '[null,null]' '[]')" '[]'
expect_eq fg-groups-short-feeds \
    "$(sing_box_build_subscription_feed_groups '["a","b"]' '[0]' '["A"]')" '[{"name":"A","tags":["a"]}]'
expect_eq fg-groups-missing-name \
    "$(sing_box_build_subscription_feed_groups '["a"]' '[1]' '["A"]')" '[{"name":"Subscription 2","tags":["a"]}]'

# ── Flat (off) branch ─────────────────────────────────────────────
nodes='{"outbounds":[
  {"type":"direct","tag":"direct-out"},
  {"type":"shadowsocks","tag":"a1","server":"10.3.0.1","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"a2","server":"10.3.0.2","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"b1","server":"10.3.0.3","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
tags='["a1","a2","b1"]'
P="$SB_SUBSCRIPTION_FEED_GROUP_TAG_PREFIX"

two="$(run_off "$tags" '[0,0,1]' '["Feed A","Feed B"]' "$nodes")"
if printf '%s' "$two" | jq -e --arg a "${P}Feed A" --arg b "${P}Feed B" '
    ([.outbounds[] | select(.type == "urltest")] | map({(.tag): .outbounds}) | add)
      == {($a): ["a1","a2"], ($b): ["b1"], "syn-urltest-out": ["a1","a2","b1"]}
' > /dev/null 2>&1; then
    ok fg-off-two-feed-urltests
else
    bad fg-off-two-feed-urltests "$(printf '%s' "$two" | jq -c '[.outbounds[]|select(.type=="urltest")|{tag,outbounds}]')"
fi
if printf '%s' "$two" | jq -e --arg a "${P}Feed A" --arg b "${P}Feed B" '
    [.outbounds[] | select(.type == "selector" and .tag == "syn-out")] as $s
    | ($s | length) == 1
    and $s[0].default == "syn-urltest-out"
    and $s[0].outbounds == ["a1","a2","b1",$a,$b,"syn-urltest-out"]
' > /dev/null 2>&1; then
    ok fg-off-two-selector
else
    bad fg-off-two-selector "$(printf '%s' "$two" | jq -c '.outbounds[]|select(.type=="selector")|{default,outbounds}')"
fi
if command -v sing-box > /dev/null 2>&1; then
    printf '%s' "$two" | jq '{
        log: {disabled: true},
        dns: {servers: [], rules: [], final: "direct"},
        inbounds: [{type: "direct", tag: "dns-in", listen: "127.0.0.42", listen_port: 53}],
        outbounds: .outbounds,
        route: {rules: [], rule_set: [], final: "direct-out", auto_detect_interface: true}
    }' > /tmp/fg-check-$$.json
    if sing-box -c /tmp/fg-check-$$.json check > /dev/null 2>&1; then
        ok fg-off-two-singbox-check
    else
        bad fg-off-two-singbox-check "$(sing-box -c /tmp/fg-check-$$.json check 2>&1 | head -2)"
    fi
    rm -f /tmp/fg-check-$$.json
else
    echo 'fg-off-two-singbox-check:SKIP'
fi

# One feed with nodes (the other one is dead): exactly the old shape.
one="$(run_off "$tags" '[1,1,1]' '["dead","Feed B"]' "$nodes")"
if printf '%s' "$one" | jq -e '
    ([.outbounds[] | select(.type == "urltest")] | map(.tag)) == ["syn-urltest-out"]
    and ([.outbounds[] | select(.type == "selector")][0].outbounds == ["a1","a2","b1","syn-urltest-out"])
' > /dev/null 2>&1; then
    ok fg-off-single-feed-unchanged
else
    bad fg-off-single-feed-unchanged "$(printf '%s' "$one" | jq -c '[.outbounds[]|select(.type=="urltest" or .type=="selector")|{tag,outbounds}]')"
fi

# No feed info at all (e.g. a caller that never set it): old shape.
none="$(run_off "$tags" '' '' "$nodes")"
if printf '%s' "$none" | jq -e '
    ([.outbounds[] | select(.type == "urltest")] | map(.tag)) == ["syn-urltest-out"]
    and ([.outbounds[] | select(.type == "selector")][0].default == "syn-urltest-out")
' > /dev/null 2>&1; then
    ok fg-off-no-feed-info-unchanged
else
    bad fg-off-no-feed-info-unchanged "$(printf '%s' "$none" | jq -c '[.outbounds[]|select(.type=="urltest" or .type=="selector")|{tag,outbounds}]')"
fi

# Two feeds with the same display name get distinct urltest tags.
dup="$(run_off "$tags" '[0,0,1]' '["same.example.com","same.example.com"]' "$nodes")"
expect_eq fg-off-duplicate-names-unique \
    "$(printf '%s' "$dup" | jq -c '[.outbounds[] | select(.type == "urltest") | .tag] | length as $n | (unique | length) == $n and $n == 3')" "true"

# A group entry without name/tags is skipped instead of breaking the config
# (the builder never emits one; the subshell keeps the stub local).
holey="$(
    sing_box_build_subscription_feed_groups() {
        printf '%s' '[{"name":"Feed A","tags":["a1","a2"]},{},{"name":"Feed B","tags":["b1"]}]'
    }
    run_off "$tags" '[0,0,1]' '["Feed A","Feed B"]' "$nodes"
)"
expect_eq fg-off-unreadable-group-skipped \
    "$(printf '%s' "$holey" | jq -c --arg p "$P" '[.outbounds[] | select(.type == "urltest") | .tag] | sort == (["\($p)Feed A","\($p)Feed B","syn-urltest-out"] | sort)')" "true"

# ── Section loop: feed index + names → facade (bisection) → blocks ─
# Four URLs: A, a dead one (no cache), C with a node sing-box rejects, and D
# from A's host with A's name. The shipped loop computes the index and the
# names; the real facade has to bisect (10 nodes > 8, one bad) and keep the
# feed index parallel over several kept ranges.
SUBSCRIPTION_CACHE_FOLDER="/tmp/fg-cache-$$"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
ss() { printf '{"type":"shadowsocks","tag":"%s","server":"10.4.0.%s","server_port":443,"method":"%s","password":"p"}' "$1" "$2" "${3:-aes-256-gcm}"; }
seed_feed() { # $1 = url, $2... = outbounds
    local url="$1" path
    shift
    path="$(get_subscription_json_path loop "$(get_subscription_url_hash "$url")")"
    printf '{"outbounds":[%s]}' "$(IFS=,; printf '%s' "$*")" > "$path"
}
url_a='https://a.example.com/sub#Feed%20A'
url_dead='https://dead.example.com/sub'
url_c='https://c.example.com/sub#Feed+C'
url_d='https://a.example.com/other#Feed%20A'
seed_feed "$url_a" "$(ss a1 1)" "$(ss a2 2)" "$(ss a3 3)" "$(ss a4 4)"
seed_feed "$url_c" "$(ss c1 5)" "$(ss c-bad 6 not-a-method)" "$(ss c2 7)"
seed_feed "$url_d" "$(ss d1 8)" "$(ss d2 9)" "$(ss d3 10)"
loop_urls="/tmp/fg-loop-urls-$$"
printf '%s\n' "$url_a" "$url_dead" "$url_c" "$url_d" > "$loop_urls"
loop_merged="/tmp/fg-loop-merged-$$.json"
printf '%s' '{"outbounds":[]}' > "$loop_merged"
redact_url_for_log() { printf '%s' "$1"; }

subscription_merge_section_feeds loop "$loop_urls" "$loop_merged"
expect_eq fg-loop-names "$SUBSCRIPTION_FEED_NAMES_JSON" '["Feed A","dead.example.com","Feed C","Feed A (4)"]'
expect_eq fg-loop-usable-count "$SUBSCRIPTION_USABLE_FEED_COUNT" "3"
expect_eq fg-loop-merged-feeds \
    "$(jq -c --arg k "$SUBSCRIPTION_FEED_MARKER_KEY" '[.outbounds[] | .[$k]]' "$loop_merged")" "[0,0,0,0,2,2,2,3,3,3]"

if command -v sing-box > /dev/null 2>&1; then
    FG_LOG="/tmp/fg-log-$$"
    : > "$FG_LOG"
    log() { printf '%s\n' "$1" >> "$FG_LOG"; }
    sing_box_cf_add_subscription_outbounds "$base_config" "loop" "$loop_merged" '[]' '[]' > /dev/null
    log() { :; }
    expect_eq fg-bisect-dropped-bad \
        "$(grep -c "Skip unsupported outbound for current sing-box: 'c-bad'" "$FG_LOG")" "1"
    expect_eq fg-bisect-tags "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" '["a1","a2","a3","a4","c1","c2","d1","d2","d3"]'
    expect_eq fg-bisect-feeds "$SUBSCRIPTION_OUTBOUND_FEEDS_JSON" '[0,0,0,0,2,2,3,3,3]'

    blocks="$(run_off "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" "$SUBSCRIPTION_OUTBOUND_FEEDS_JSON" \
        "$SUBSCRIPTION_FEED_NAMES_JSON" "$SING_BOX_CF_LAST_CONFIG")"
    if printf '%s' "$blocks" | jq -e --arg p "$P" '
        ([.outbounds[] | select(.type == "urltest")] | map({(.tag): .outbounds}) | add)
          == {("\($p)Feed A"): ["a1","a2","a3","a4"], ("\($p)Feed C"): ["c1","c2"],
              ("\($p)Feed A (4)"): ["d1","d2","d3"],
              "syn-urltest-out": ["a1","a2","a3","a4","c1","c2","d1","d2","d3"]}
    ' > /dev/null 2>&1; then
        ok fg-loop-blocks-aligned
    else
        bad fg-loop-blocks-aligned "$(printf '%s' "$blocks" | jq -c '[.outbounds[]|select(.type=="urltest")|{tag,outbounds}]')"
    fi
    rm -f "$FG_LOG"
else
    echo 'fg-bisect-dropped-bad:SKIP'
fi

# A literal "A (3)" takes the name a repeated "A" at position 3 would get, so
# that one moves on to "A (4)". The last link repeats the first with another
# #fragment: same cache file, merged once.
url_x='https://x.example.com/one#A'
url_y='https://y.example.com/sub#A%20(3)'
url_z='https://z.example.com/sub#A'
url_twin='https://x.example.com/one#Twin'
seed_feed "$url_x" "$(ss x1 11)"
seed_feed "$url_y" "$(ss y1 12)"
seed_feed "$url_z" "$(ss z1 13)"
printf '%s\n' "$url_x" "$url_y" "$url_z" "$url_twin" > "$loop_urls"
printf '%s' '{"outbounds":[]}' > "$loop_merged"
subscription_merge_section_feeds loop "$loop_urls" "$loop_merged"
expect_eq fg-loop-name-collision "$SUBSCRIPTION_FEED_NAMES_JSON" '["A","A (3)","A (4)","Twin"]'
expect_eq fg-loop-twin-usable-count "$SUBSCRIPTION_USABLE_FEED_COUNT" "3"
expect_eq fg-loop-twin-merged-once \
    "$(jq -c --arg k "$SUBSCRIPTION_FEED_MARKER_KEY" '[.outbounds[] | [.tag, .[$k]]]' "$loop_merged")" \
    '[["x1",0],["y1",1],["z1",2]]'

# ── .url sidecar ignores the #fragment on both sides ──────────────
sidecar="$SUBSCRIPTION_CACHE_FOLDER/side.url"
printf '%s' 'https://h.example.com/sub' > "$sidecar"
subscription_url_cache_matches "$sidecar" 'https://h.example.com/sub#New' && ok fg-sidecar-new-name || bad fg-sidecar-new-name
printf '%s' 'https://h.example.com/sub#Old' > "$sidecar"
subscription_url_cache_matches "$sidecar" 'https://h.example.com/sub#New' && ok fg-sidecar-legacy-fragment || bad fg-sidecar-legacy-fragment
if subscription_url_cache_matches "$sidecar" 'https://h.example.com/other#Old'; then bad fg-sidecar-other-url; else ok fg-sidecar-other-url; fi
if subscription_url_cache_matches "$sidecar.missing" 'https://h.example.com/sub'; then bad fg-sidecar-missing; else ok fg-sidecar-missing; fi

# Startup: a feed renamed only by #fragment (old sidecar still holds the old
# fragment) and a second URL that differs from its twin only by fragment are
# both served from cache; a feed whose sidecar names another URL is fetched.
config_get() {
    case "$3" in
    connection_type) eval "$1=proxy" ;;
    proxy_config_type) eval "$1=subscription" ;;
    *) eval "$1=''" ;;
    esac
}
config_get_bool() { eval "$1=0"; }
ensure_subscription_cache_dir() { :; }
migrate_subscription_cache_from_tmp() { :; }
reap_legacy_subscription_cache_files() { :; }
FG_FETCHED="/tmp/fg-fetched-$$"
: > "$FG_FETCHED"
wait_for_subscription_connectivity() { printf '%s\n' "$2" >> "$FG_FETCHED"; return 1; }
url_ren='https://r.example.com/sub#New%20name'
url_twin='https://r.example.com/sub#Twin'
url_moved='https://m.example.com/sub#M'
seed_feed "$url_ren" "$(ss r1 11)"
seed_feed "$url_moved" "$(ss m1 12)"
start_sidecar() { get_subscription_url_cache_path startup "$(get_subscription_url_hash "$1")"; }
for u in "$url_ren" "$url_moved"; do
    mv "$(get_subscription_json_path loop "$(get_subscription_url_hash "$u")")" \
        "$(get_subscription_json_path startup "$(get_subscription_url_hash "$u")")"
done
printf '%s' 'https://r.example.com/sub#Old%20name' > "$(start_sidecar "$url_ren")"
printf '%s' 'https://m.example.com/elsewhere' > "$(start_sidecar "$url_moved")"
get_subscription_urls_for_section() { printf '%s\n' "$url_ren" "$url_twin" "$url_moved"; }
subscription_startup_blocked=0
prepare_subscription_cache_for_startup startup
expect_eq fg-startup-fetches-only-moved "$(cat "$FG_FETCHED")" "$url_moved"
rm -f "$FG_FETCHED"

# ── Orphan cache files ────────────────────────────────────────────
# Files of a link dropped from the list and of a link cached while the hash
# still held the #fragment go; the listed link, another section, the legacy
# bare name and non-hash names stay. A hash that cannot be computed removes
# nothing.
orph_urls="/tmp/fg-orph-urls-$$"
url_keep='https://k.example.com/sub#Keep'
url_gone='https://g.example.com/sub'
h_keep="$(get_subscription_url_hash "$url_keep")"
h_gone="$(get_subscription_url_hash "$url_gone")"
h_old="$(printf '%s' "$url_keep" | md5sum | awk '{print $1}')"
printf '%s\n' "$url_keep" > "$orph_urls"
for f in "orph.$h_keep.json" "orph.$h_keep.url" "orph.$h_keep.rejected" \
    "orph.$h_gone.json" "orph.$h_gone.user_agent" "orph.$h_gone.json.tmp.42" \
    "orph.$h_old.json" "orph.$h_old.url" \
    orph.json orph.notahash.json "orph_x.$h_gone.json"; do
    : > "$SUBSCRIPTION_CACHE_FOLDER/$f"
done
orph_left() { (cd "$SUBSCRIPTION_CACHE_FOLDER" && ls orph.* orph_x.* 2>/dev/null | sort | tr '\n' ' '); }
orph_want="$(printf '%s\n' "orph.$h_keep.json" "orph.$h_keep.rejected" "orph.$h_keep.url" \
    orph.json orph.notahash.json "orph_x.$h_gone.json" | sort | tr '\n' ' ')"
(get_subscription_url_hash() { :; }; reap_orphan_subscription_cache_files orph "$orph_urls")
expect_eq fg-orphan-no-hash-keeps-all "$(orph_left | wc -w | tr -d ' ')" "11"
reap_orphan_subscription_cache_files orph "$orph_urls"
expect_eq fg-orphan-reaped "$(orph_left)" "$orph_want"
rm -f "$orph_urls"

rm -rf "$SUBSCRIPTION_CACHE_FOLDER" "$loop_urls" "$loop_merged"
rm -f "$feed_a" "$feed_b" "$feed_bad" "$merged" "$unmarked"
echo 'DONE'
FDEOF

    # Splice the flat-branch body (from its marker comment through the final
    # selector add, which is the last statement of that else) into the driver.
    local region="$work/region.sh"
    awk '
        /# Create urltest \+ selector \(default subscription behaviour\)/{p=1}
        p{print}
        p && /"\$selector_tag" "\$selector_outbounds" "\$urltest_tag" "true"\)"/{exit}
    ' "$bin" > "$region"
    if grep -q 'sing_box_build_subscription_feed_groups' "$region" \
        && grep -q 'sing_box_cm_add_selector_outbound' "$region"; then
        pass "fg-region-extracted:OK"
    else
        fail "fg-region-extracted:FAIL" "$(head -3 "$region" 2>/dev/null)"
    fi

    # configure_outbound_handler reaps orphans once the URL list is known and
    # before any feed is downloaded.
    local reap_order
    reap_order="$(awk '
        /^configure_outbound_handler\(\) \{/{p=1}
        !p{next}
        /Subscription URL is not set/{print "empty-check"}
        /reap_orphan_subscription_cache_files "\$section" "\$subscription_urls_tmp"/{print "reap"}
        /Per-feed download/{print "download"}
        /^\}/{exit}
    ' "$bin" | tr '\n' ' ')"
    if [ "$reap_order" = "empty-check reap download " ]; then
        pass "fg-orphan-reap-wired:OK"
    else
        fail "fg-orphan-reap-wired:FAIL" "order: $reap_order"
    fi
    {
        sed '/EXTRACT_OFF/q' "$drv" | sed '$d'
        cat "$region"
        sed -n '/EXTRACT_OFF/,$p' "$drv" | sed '1d'
    } > "$drv.spliced"
    mv "$drv.spliced" "$drv"
    sed -i "s|LIB_DIR|$lib|g; s|BIN_PATH|$bin|g" "$drv"

    local out="$work/out.log"
    ash "$drv" > "$out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "fg-driver-completed:OK"
    else
        fail "fg-driver-completed:FAIL (driver aborted early)" "$(tail -3 "$out" 2>/dev/null)"
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Insecure subscription fetch flag (task-021b)
#
# Exercises download_subscription's 8th positional arg (insecure 0|1). A
# PATH-prepended fake `wget` records its full argv to a log and writes a dummy
# body to its -O target (so the FIRST attempt succeeds → no retry/fallback).
# A driver sources the REAL helpers.sh (real download_subscription +
# _wget_subscription_request), stubs the metadata/logging helpers, and pins
# should_force_wget_ipv4 per scenario to drive the normal vs ipv4 branch. We
# assert --no-check-certificate is ABSENT when insecure=0 and PRESENT when
# insecure=1, across the normal and proxy branches (plus the ipv4 branch).
# Tokens use the same name:OK/FAIL convention as test_subscription.
# ─────────────────────────────────────────────────────────────────
test_insecure_fetch() {
    header "Insecure Subscription Fetch Flag (task-021b)"

    local helpers="${NETSHIFT_LIB_DIR}/helpers.sh"
    if [ ! -r "$helpers" ]; then
        skip "helpers.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-insecure-$$"
    rm -rf "$work"
    mkdir -p "$work/bin"

    # Fake wget: append the FULL argv to $WGET_ARGV_LOG (one line, NUL-free),
    # then satisfy download_subscription's success check by writing a non-empty
    # body to whatever follows -O. Always exit 0 so the first attempt wins.
    cat > "$work/bin/wget" << 'WGETEOF'
#!/bin/sh
# Record argv as a single space-joined line for substring assertions.
printf '%s\n' "$*" >> "$WGET_ARGV_LOG"
# Find the -O target and write a dummy body there.
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-O" ] && { out="$a"; break; }
    prev="$a"
done
[ -n "$out" ] && printf 'dummy-body' > "$out"
exit 0
WGETEOF
    chmod 0755 "$work/bin/wget"

    local drv="$work/driver.sh"
    cat > "$drv" << 'IFEOF'
# Quiet logging + deterministic metadata stubs (no real device probing).
log() { :; }
echolog() { :; }
nolog() { :; }
get_sing_box_version() { echo "1.12.0"; }
get_device_model() { echo "test-model"; }
get_kernel_version() { echo "test-kernel"; }
generate_hwid() { echo "test-hwid"; }
get_subscription_user_agent() { echo "singbox/test"; }

# Real download_subscription + _wget_subscription_request from helpers.sh.
. "HELPERS_PATH"

# Scenario knobs: $1 = branch (normal|ipv4), rest of the call is fixed.
case "$1" in
ipv4)   should_force_wget_ipv4() { return 0; } ;;
*)      should_force_wget_ipv4() { return 1; } ;;
esac
# IPv4 fallback retry helpers — keep them inert so a success on attempt 1 is
# unambiguous (the fake wget always succeeds anyway).
has_ipv4_default_route() { return 1; }
wget_supports_ipv4_flag() { return 1; }

branch="$1"
proxy="$2"
insecure="$3"
out="$WGET_OUT_FILE"
rm -f "$out"
: > "$WGET_ARGV_LOG"

# url, tmpfile, proxy, retries=1, wait=0, timeout=5, user_agent, insecure
download_subscription "https://1.2.3.4:2096/sub/abc" "$out" "$proxy" 1 0 5 "singbox/test" "$insecure"
echo "DONE"
IFEOF
    sed -i "s|HELPERS_PATH|$helpers|g" "$drv"

    export WGET_ARGV_LOG="$work/wget.argv"
    export WGET_OUT_FILE="$work/sub.json"

    # Helper: run one scenario, return the recorded argv on stdout.
    _if_run() {
        : > "$WGET_ARGV_LOG"
        PATH="$work/bin:$PATH" ash "$drv" "$1" "$2" "$3" > /dev/null 2>&1
        cat "$WGET_ARGV_LOG" 2>/dev/null
    }

    local argv

    # ── normal branch, insecure=0 → NO --no-check-certificate ──
    argv="$(_if_run normal "" 0)"
    case "$argv" in
        *--no-check-certificate*) fail "if-normal-off: flag present (should be absent): $argv" ;;
        *) pass "if-normal-off: no --no-check-certificate (secure default)" ;;
    esac

    # ── normal branch, insecure=1 → HAS --no-check-certificate ──
    argv="$(_if_run normal "" 1)"
    case "$argv" in
        *--no-check-certificate*) pass "if-normal-on: --no-check-certificate present" ;;
        *) fail "if-normal-on: flag missing (should be present): $argv" ;;
    esac

    # ── proxy branch, insecure=0 → NO --no-check-certificate ──
    argv="$(_if_run normal "127.0.0.1:4534" 0)"
    case "$argv" in
        *--no-check-certificate*) fail "if-proxy-off: flag present (should be absent): $argv" ;;
        *) pass "if-proxy-off: no --no-check-certificate (secure default)" ;;
    esac

    # ── proxy branch, insecure=1 → HAS --no-check-certificate ──
    argv="$(_if_run normal "127.0.0.1:4534" 1)"
    case "$argv" in
        *--no-check-certificate*) pass "if-proxy-on: --no-check-certificate present" ;;
        *) fail "if-proxy-on: flag missing (should be present): $argv" ;;
    esac

    # ── ipv4 branch, insecure=1 → HAS both -4 and --no-check-certificate ──
    argv="$(_if_run ipv4 "" 1)"
    case "$argv" in
        *--no-check-certificate*)
            case "$argv" in
                *-4*) pass "if-ipv4-on: -4 and --no-check-certificate both present" ;;
                *) fail "if-ipv4-on: -4 missing: $argv" ;;
            esac
            ;;
        *) fail "if-ipv4-on: flag missing (should be present): $argv" ;;
    esac

    # ── ipv4 branch, insecure=0 → -4 present, NO --no-check-certificate ──
    argv="$(_if_run ipv4 "" 0)"
    case "$argv" in
        *--no-check-certificate*) fail "if-ipv4-off: flag present (should be absent): $argv" ;;
        *) pass "if-ipv4-off: no --no-check-certificate (secure default)" ;;
    esac

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Async component-action job state (updater.sh)
# ─────────────────────────────────────────────────────────────────
# Exercises the jq job-state machinery from updater.sh with a STUBBED worker
# (no network, no real download). A tiny stub CLI sources the real updater.sh,
# provides a trivial `log`, and lets the `component_action` worker be controlled
# by env vars (STUB_JSON / STUB_SLEEP / STUB_RC). component_action_async forks
# `"$0" component_action ...`, so $0 must be the stub CLI itself — hence the
# separate executable. All assertions are jq-validated; tokens are parsed with
# the same name:OK/FAIL convention as test_subscription.
test_jobstate() {
    header "Async Component-Action Job State (updater.sh)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local stub="/tmp/netshift-jobstub-$$"
    cat > "$stub" << 'STUBEOF'
#!/bin/sh
# Minimal stand-in for /usr/bin/netshift that exposes the async job-state API.
log() { :; }
echolog() { :; }
nolog() { :; }
# Isolate state under a per-process tmpfs dir so parallel/old runs never clash.
UPDATES_JOB_DIR="${JOBSTUB_DIR:-/tmp/netshift-jobstub-state}"

. "UPDATER_PATH"

# Re-pin after sourcing (the source sets its own default).
UPDATES_JOB_DIR="${JOBSTUB_DIR:-/tmp/netshift-jobstub-state}"

case "$1" in
component_action)
    # Stubbed worker: emit a (possibly delayed) JSON object then exit STUB_RC.
    [ -n "$STUB_SLEEP" ] && sleep "$STUB_SLEEP"
    if [ -z "$STUB_JSON" ]; then
        STUB_JSON='{"success":true,"version":"1.0.0-extended"}'
    fi
    printf '%s\n' "$STUB_JSON"
    exit "${STUB_RC:-0}"
    ;;
component_action_async)
    component_action_async "$2" "$3"
    ;;
component_action_status)
    component_action_status "$2"
    ;;
esac
STUBEOF
    sed -i "s|UPDATER_PATH|$updater|g" "$stub"
    chmod 0755 "$stub"

    local jdir="/tmp/netshift-jobstate-$$"
    rm -rf "$jdir"

    # ── 1. async returns {success:true, job_id} fast; running state appears ──
    local start_async end_async elapsed async_json job_id
    start_async="$(date +%s)"
    async_json="$(JOBSTUB_DIR="$jdir" STUB_SLEEP=2 STUB_JSON='{"success":true,"version":"1.7.0-extended"}' \
        "$stub" component_action_async sing_box install_extended)"
    end_async="$(date +%s)"
    elapsed=$((end_async - start_async))

    if echo "$async_json" | jq -e '.success == true and (.job_id | length) > 0' > /dev/null 2>&1; then
        pass "async returns success+job_id ($async_json)"
    else
        fail "async did not return success+job_id" "$async_json"
    fi
    if [ "$elapsed" -lt 5 ]; then
        pass "async returned fast (${elapsed}s, well under 30s)"
    else
        fail "async too slow: ${elapsed}s"
    fi

    job_id="$(echo "$async_json" | jq -r '.job_id')"
    if [ -f "$jdir/$job_id.json" ]; then
        pass "running state file created"
    else
        fail "running state file missing: $jdir/$job_id.json"
    fi
    # While the stub sleeps, the state must read running:true / success:true.
    if jq -e '.running == true and .success == true and .exit_code == null' \
            "$jdir/$job_id.json" > /dev/null 2>&1; then
        pass "running state has running:true,success:true,exit_code:null"
    else
        fail "running state shape wrong" "$(cat "$jdir/$job_id.json" 2>/dev/null)"
    fi
    # The recorded pid must be a live integer while running.
    local running_pid
    running_pid="$(jq -r '.pid' "$jdir/$job_id.json" 2>/dev/null)"
    case "$running_pid" in
        '' | *[!0-9]*) fail "running pid not an integer: '$running_pid'" ;;
        *) pass "running pid recorded ($running_pid)" ;;
    esac

    # ── 2. after the worker finishes, status reports the surfaced outcome ────
    # Wait for the background worker (stub sleeps 2s) to complete.
    local waited=0
    while [ "$waited" -lt 15 ]; do
        if jq -e '.running == false' "$jdir/$job_id.json" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    local status_json
    status_json="$(JOBSTUB_DIR="$jdir" "$stub" component_action_status "$job_id")"
    if echo "$status_json" | jq -e '.running == false and .success == true and .exit_code == 0 and .version == "1.7.0-extended"' > /dev/null 2>&1; then
        pass "finished status surfaces success/version/exit_code"
    else
        fail "finished status wrong" "$status_json"
    fi

    # ── 2b. a failing worker is recorded (success:false, non-zero exit) ──────
    local fail_json fail_id fail_status
    fail_json="$(JOBSTUB_DIR="$jdir" STUB_RC=3 STUB_JSON='{"success":false,"message":"boom"}' \
        "$stub" component_action_async sing_box install_extended)"
    fail_id="$(echo "$fail_json" | jq -r '.job_id')"
    waited=0
    while [ "$waited" -lt 15 ]; do
        if jq -e '.running == false' "$jdir/$fail_id.json" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail_status="$(JOBSTUB_DIR="$jdir" "$stub" component_action_status "$fail_id")"
    if echo "$fail_status" | jq -e '.running == false and .success == false and .exit_code == 3 and .message == "boom"' > /dev/null 2>&1; then
        pass "failed worker recorded (success:false, exit_code:3, message surfaced)"
    else
        fail "failed worker status wrong" "$fail_status"
    fi

    # ── 2c. worker stdout polluted with log lines: last JSON object wins ─────
    local noisy_json noisy_id noisy_status
    noisy_json="$(JOBSTUB_DIR="$jdir" \
        STUB_JSON='Updater: some log line
another stray line {not-json}
{"success":true,"version":"9.9.9-extended"}' \
        "$stub" component_action_async sing_box install_extended)"
    noisy_id="$(echo "$noisy_json" | jq -r '.job_id')"
    waited=0
    while [ "$waited" -lt 15 ]; do
        if jq -e '.running == false' "$jdir/$noisy_id.json" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    noisy_status="$(JOBSTUB_DIR="$jdir" "$stub" component_action_status "$noisy_id")"
    if echo "$noisy_status" | jq -e '.running == false and .success == true and .version == "9.9.9-extended"' > /dev/null 2>&1; then
        pass "finished parser extracts the LAST well-formed JSON object from noisy stdout"
    else
        fail "noisy-stdout parse wrong" "$noisy_status"
    fi

    # ── 2d. a worker warning reaches the status the UI polls ─────────────────
    # The stable core switch reports a pin it had to leave in the apk world as
    # "warning" next to success:true; dropping it here would leave it CLI-only.
    local warn_json warn_id warn_status
    warn_json="$(JOBSTUB_DIR="$jdir" \
        STUB_JSON='{"success":true,"version":"1.12.0","warning":"apk world pins sing-box"}' \
        "$stub" component_action_async sing_box install_stable)"
    warn_id="$(echo "$warn_json" | jq -r '.job_id')"
    waited=0
    while [ "$waited" -lt 15 ]; do
        if jq -e '.running == false' "$jdir/$warn_id.json" > /dev/null 2>&1; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    warn_status="$(JOBSTUB_DIR="$jdir" "$stub" component_action_status "$warn_id")"
    if echo "$warn_status" | jq -e '.running == false and .success == true and .warning == "apk world pins sing-box"' > /dev/null 2>&1; then
        pass "finished status surfaces the worker warning"
    else
        fail "worker warning not surfaced" "$warn_status"
    fi
    if echo "$status_json" | jq -e '.warning == ""' > /dev/null 2>&1; then
        pass "finished status without a worker warning has an empty one"
    else
        fail "finished status warning not empty" "$status_json"
    fi

    # ── 3. invalid / traversal job ids are rejected safely ──────────────────
    local bad bad_json bad_rc bad_out="/tmp/netshift-jobstate-bad-$$"
    for bad in "../foo" "../../etc/passwd" "foo/bar" "a b" "" "."; do
        bad_rc=0
        JOBSTUB_DIR="$jdir" "$stub" component_action_status "$bad" > "$bad_out" 2>/dev/null || bad_rc=$?
        bad_json="$(cat "$bad_out" 2>/dev/null)"
        if [ "$bad_rc" -ne 0 ] \
                && echo "$bad_json" | jq -e '.success == false and .running == false' > /dev/null 2>&1; then
            pass "invalid job_id rejected safely: '$bad'"
        else
            fail "invalid job_id NOT rejected: '$bad'" "rc=$bad_rc json=$bad_json"
        fi
    done
    rm -f "$bad_out"
    # The validator must never resolve a traversal id to a path.
    local fb_jobstate="/tmp/netshift-jobstate-validate-$$.sh"
    cat > "$fb_jobstate" << 'VEOF'
log() { :; }
UPDATES_JOB_DIR="VDIR"
. "UPDATER_PATH"
UPDATES_JOB_DIR="VDIR"
if updates_job_state_path "../foo" >/dev/null 2>&1; then
    echo 'jobstate-traversal-rejected:FAIL'
else
    echo 'jobstate-traversal-rejected:OK'
fi
if updates_job_state_path "good-1.2_3" >/dev/null 2>&1; then
    echo 'jobstate-valid-id-accepted:OK'
else
    echo 'jobstate-valid-id-accepted:FAIL'
fi
echo 'DONE'
VEOF
    sed -i "s|UPDATER_PATH|$updater|g;s|VDIR|$jdir|g" "$fb_jobstate"
    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail
    # mutate the real counters and gate the suite.
    local js_out="/tmp/netshift-jobstate-validate-out-$$.log"
    ash "$fb_jobstate" > "$js_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done < "$js_out"
    if [ "$saw_done" = "1" ]; then
        pass "jobstate-validate-driver-completed:OK"
    else
        fail "jobstate-validate-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$fb_jobstate" "$js_out"

    # ── 4. stale job: running:true with a dead pid past grace → finished ─────
    local stale_dir="$jdir/stale"
    mkdir -p "$stale_dir"
    local stale_state="$stale_dir/staletest.json"
    local stale_sh="/tmp/netshift-jobstate-stale-$$.sh"
    cat > "$stale_sh" << 'SEOF'
log() { :; }
UPDATES_JOB_DIR="SDIR"
. "UPDATER_PATH"
UPDATES_JOB_DIR="SDIR"
state="SSTATE"
# Pick a pid that is certainly dead, and a started_at far in the past so we are
# well beyond the stale grace window.
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
done
old_started=$(( $(date +%s) - 3600 ))
jq -nc --argjson pid "$dead_pid" --argjson started "$old_started" \
    '{success:true,running:true,component:"sing_box",action:"install_extended",
      message:"Component action is running",pid:$pid,started_at:$started,
      updated_at:$started,exit_code:null,version:"",latest_version:""}' > "$state"
updates_refresh_running_job_state "$state"
if jq -e '.running == false and .success == false' "$state" >/dev/null 2>&1; then
    echo 'jobstate-stale-marked-finished:OK'
else
    echo 'jobstate-stale-marked-finished:FAIL'
fi
echo 'DONE'
SEOF
    sed -i "s|UPDATER_PATH|$updater|g;s|SDIR|$stale_dir|g;s|SSTATE|$stale_state|g" "$stale_sh"
    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail
    # mutate the real counters and gate the suite.
    local stale_out="/tmp/netshift-jobstate-stale-out-$$.log"
    ash "$stale_sh" > "$stale_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done < "$stale_out"
    if [ "$saw_done" = "1" ]; then
        pass "jobstate-stale-driver-completed:OK"
    else
        fail "jobstate-stale-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$stale_sh" "$stale_out"

    rm -rf "$jdir" "$stub"
}

# ─────────────────────────────────────────────────────────────────
# Test: Core-switch connectivity self-heal + rollback (updater.sh, task-009)
#
# Fully mocked — no real network, no real package install, no real binary
# touched. A generated driver sources updater.sh, points RESOLV_CONF and the
# tmpfs backup at test files, stubs dig/nslookup/curl/opkg/apk and a fake
# /etc/init.d/netshift via a PATH-prepended bin dir + a writable init stub, and
# drives each scenario via env flags. The driver emits `name:OK`/`name:FAIL`
# tokens which the case parser turns into pass/fail.
# ─────────────────────────────────────────────────────────────────
test_selfheal() {
    header "Core-switch Connectivity Self-Heal + Rollback (updater.sh)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-selfheal-$$"
    rm -rf "$work"
    mkdir -p "$work/bin" "$work/init"

    # ── Command stubs (PATH-prepended). Behaviour is driven by env files so the
    # driver can flip them between scenarios without rewriting the stubs. ──────
    #
    # DNS/HTTPS probes: a stub "succeeds" only when its marker file is present.
    cat > "$work/bin/dig" << 'DIGEOF'
#!/bin/sh
# Echo an address (so the resolver-detect grep matches) only if allowed.
[ -f "$SELFHEAL_DNS_OK" ] && { echo "1.2.3.4"; exit 0; }
exit 1
DIGEOF
    cat > "$work/bin/nslookup" << 'NSEOF'
#!/bin/sh
[ -f "$SELFHEAL_DNS_OK" ] && { echo "Address 1.2.3.4"; exit 0; }
exit 1
NSEOF
    cat > "$work/bin/curl" << 'CURLEOF'
#!/bin/sh
# Reachability probe (-I/HEAD). Succeed only when the marker is present.
[ -f "$SELFHEAL_HTTP_OK" ] && exit 0
exit 1
CURLEOF
    # opkg/apk stubs: package "install" succeeds or fails per marker, and on a
    # "successful" stable install they flip the installed core to non-extended.
    cat > "$work/bin/opkg" << 'OPKGEOF'
#!/bin/sh
case "$1" in
update) exit 0 ;;
install)
    if [ -f "$SELFHEAL_PKG_OK" ]; then
        printf 'stable-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
        # A package manager that reports success yet leaves no runnable core
        # (half-written binary, missing library): the updater must catch that
        # instead of restarting NetShift onto nothing.
        [ -f "$SELFHEAL_PKG_BREAKS_CORE" ] && rm -f "$SELFHEAL_BIN"
        # Same, with a core that still prints a version line but exits non-zero
        # (a build that crashes after printing): the output alone must not pass.
        if [ -f "$SELFHEAL_PKG_CORE_FAILS" ]; then
            printf '%s\n' '#!/bin/sh' 'echo "sing-box version stable-1.12.0"' 'exit 1' > "$SELFHEAL_BIN"
            chmod 0755 "$SELFHEAL_BIN"
        fi
        exit 0
    fi
    # Simulate a package failure that ALSO removed the live binary (the brick
    # scenario): blow away the mock binary so the rollback must restore it.
    rm -f "$SELFHEAL_BIN" 2>/dev/null
    exit 1
    ;;
esac
exit 0
OPKGEOF
    chmod 0755 "$work/bin/dig" "$work/bin/nslookup" "$work/bin/curl" "$work/bin/opkg"

    # Fake /etc/init.d/netshift: records each invocation (stop/start/restart) to
    # a log so the driver can assert teardown/bring-up happened, plus a
    # `backup-present` line when the stable path's tmpfs backup still exists at
    # that moment.
    cat > "$work/init/netshift" << 'INITEOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SELFHEAL_INIT_LOG"
for d in /tmp/netshift-sbstable.*; do
    [ -e "$d" ] && printf 'backup-present\n' >> "$SELFHEAL_INIT_LOG"
done
exit 0
INITEOF
    chmod 0755 "$work/init/netshift"

    # ── Driver: sources updater, overrides paths/helpers, runs one scenario. ──
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
updates_log() { :; }
RESOLV_CONF="DRV_RESOLV"
UPDATES_RESOLV_BACKUP="DRV_BACKUP"
UPDATES_FEED_PROBE_HOST="feeds.test"
UPDATES_GITHUB_PROBE_HOST="github.test"
UPDATES_HEAL_RESOLVERS="1.1.1.1 9.9.9.9"
UPDATES_SING_BOX_BIN="$SELFHEAL_BIN"
UPDATES_LIBCRONET_LIB="DRV_CRONET"
UPDATES_APK_WORLD="$SELFHEAL_APK_WORLD"
UPDATES_APK_FETCH_DIR="$SELFHEAL_APK_FETCH_DIR"
. "DRV_UPDATER"
# Re-pin after sourcing (the source sets its own defaults).
RESOLV_CONF="DRV_RESOLV"
UPDATES_RESOLV_BACKUP="DRV_BACKUP"
UPDATES_FEED_PROBE_HOST="feeds.test"
UPDATES_GITHUB_PROBE_HOST="github.test"
UPDATES_HEAL_RESOLVERS="1.1.1.1 9.9.9.9"
UPDATES_SING_BOX_BIN="$SELFHEAL_BIN"
UPDATES_LIBCRONET_LIB="DRV_CRONET"
UPDATES_APK_WORLD="$SELFHEAL_APK_WORLD"
UPDATES_APK_FETCH_DIR="$SELFHEAL_APK_FETCH_DIR"

# Mocked helpers used by the stable core (normally from helpers.sh).
get_sing_box_version() { cat "$SELFHEAL_CORE_VERSION" 2>/dev/null; }
is_sing_box_extended() {
    case "${1:-$(get_sing_box_version)}" in
    *extended*) return 0 ;;
    *) return 1 ;;
    esac
}
# Make the post-install restart a no-op probe (the fake init records it anyway).
updates_restart_netshift() { /etc/init.d/netshift restart >/dev/null 2>&1 || true; }

case "$1" in
run_stable)  updates_install_sing_box_stable ;;
esac
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_RESOLV|$work/resolv.conf|g;s|DRV_BACKUP|$work/resolv.bak|g;s|DRV_CRONET|$work/libcronet.so|g" "$drv"

    # Common per-run wiring: PATH-prepended stubs + fake init under /etc/init.d.
    # We back up any real /etc/init.d/netshift and restore it at the end.
    local init_target="/etc/init.d/netshift"
    local init_saved=""
    if [ -e "$init_target" ]; then
        init_saved="$work/netshift.realinit"
        cp -p "$init_target" "$init_saved" 2>/dev/null || init_saved=""
    fi
    mkdir -p /etc/init.d 2>/dev/null || true
    cp -p "$work/init/netshift" "$init_target" 2>/dev/null
    chmod 0755 "$init_target" 2>/dev/null || true

    # Marker/state files shared with the stubs via env.
    export SELFHEAL_DNS_OK="$work/dns_ok"
    export SELFHEAL_HTTP_OK="$work/http_ok"
    export SELFHEAL_PKG_OK="$work/pkg_ok"
    export SELFHEAL_INIT_LOG="$work/init.log"
    export SELFHEAL_CORE_VERSION="$work/core.version"
    export SELFHEAL_BIN="$work/usr-bin-sing-box"
    export SELFHEAL_PKG_BREAKS_CORE="$work/pkg_breaks_core"
    export SELFHEAL_PKG_CORE_FAILS="$work/pkg_core_fails"
    export SELFHEAL_APK_LOG="$work/apk.log"
    export SELFHEAL_APK_FETCHED_TO="$work/apk_fetched_to"
    mkdir -p "$work/fetch"
    export SELFHEAL_APK_FETCH_DIR="$work/fetch/apk-fetch"

    # The "NetShift was not restarted" assertions below read init.log, and they
    # mean something only if the init stub installed above really logs there.
    : > "$SELFHEAL_INIT_LOG"
    "$init_target" selfcheck > /dev/null 2>&1 || true
    if grep -qx 'selfcheck' "$SELFHEAL_INIT_LOG" 2>/dev/null; then
        pass "selfheal-init-stub-logs:OK"
    else
        fail "selfheal-init-stub-logs:FAIL" "init.log=$(cat "$SELFHEAL_INIT_LOG" 2>/dev/null)"
    fi

    # The fake sing-box core has to be a runnable program: the stable path now
    # reads the version by executing $UPDATES_SING_BOX_BIN rather than trusting
    # get_sing_box_version()'s PATH lookup, which answers "1.0" for a missing or
    # broken core and would let a core-less router pass as a good downgrade.
    # $1 is a marker baked into the script so the rollback assertions can tell
    # the restored bytes apart; the version it reports lives in a separate file
    # that the package-manager stubs rewrite on a successful install.
    make_fake_core() {
        cat > "$SELFHEAL_BIN" << COREEOF
#!/bin/sh
# core-marker: ${1:-PLAIN-CORE-BYTES}
[ "\$1" = "version" ] || exit 1
printf 'sing-box version %s\n' "\$(cat "\$SELFHEAL_CORE_VERSION" 2>/dev/null)"
COREEOF
        chmod 0755 "$SELFHEAL_BIN"
    }

    local out="$work/out.json"

    run_scenario() {
        # The worker returns non-zero on recoverable failures (success:false);
        # under `set -e` that would abort the suite, so swallow the rc here — the
        # assertions read the JSON + file state, not the exit code.
        rm -f "$SELFHEAL_APK_LOG" "$SELFHEAL_APK_FETCHED_TO"
        : > "$work/init.log"
        PATH="$work/bin:$PATH" ash "$drv" run_stable > "$out" 2>/dev/null || true
    }

    # ── Scenario 1: pre-flight passes → install proceeds, no teardown ─────────
    : > "$SELFHEAL_DNS_OK"; : > "$SELFHEAL_HTTP_OK"; : > "$SELFHEAL_PKG_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    printf 'original-resolver\n' > "$work/resolv.conf"
    make_fake_core
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1; then
        pass "selfheal-preflight-pass-proceeds:OK"
    else
        fail "selfheal-preflight-pass-proceeds:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if [ ! -f "$work/init.log" ] || ! grep -q 'stop' "$work/init.log"; then
        pass "selfheal-preflight-pass-no-teardown:OK"
    else
        fail "selfheal-preflight-pass-no-teardown:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi
    if [ "$(cat "$work/resolv.conf" 2>/dev/null)" = "original-resolver" ]; then
        pass "selfheal-preflight-pass-resolv-untouched:OK"
    else
        fail "selfheal-preflight-pass-resolv-untouched:FAIL" "$(cat "$work/resolv.conf" 2>/dev/null)"
    fi
    # Restart ordering on the opkg path too (the move is shared by both package
    # managers): NetShift comes back only once the tmpfs backup — a full copy of
    # the extended core — has been freed.
    if grep -qx 'restart' "$work/init.log" 2>/dev/null && \
            ! grep -q 'backup-present' "$work/init.log" 2>/dev/null; then
        pass "selfheal-opkg-restart-after-backup-freed:OK"
    else
        fail "selfheal-opkg-restart-after-backup-freed:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi

    # ── Scenario 2: pre-flight fails → DNS heal succeeds → resolv restored ────
    # DNS fails first, but once the temp resolver is written DNS+HTTP pass. We
    # model "temp resolver fixes DNS" by making the DNS probe key off the temp
    # resolver content: the stub succeeds only when the marker exists, and the
    # heal writes the marker via a wrapper. Simpler: DNS off initially, but the
    # heal's resolv write triggers a hook that flips DNS on. We emulate that by
    # having the temp-resolver write observed through resolv.conf content.
    rm -f "$SELFHEAL_DNS_OK"; : > "$SELFHEAL_HTTP_OK"; : > "$SELFHEAL_PKG_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    printf 'original-resolver\n' > "$work/resolv.conf"
    make_fake_core
    # dig stub variant for scenario 2: DNS resolves only once resolv.conf holds
    # the temp resolver (i.e. after the heal wrote it).
    cat > "$work/bin/dig" << 'DIG2EOF'
#!/bin/sh
grep -q '1.1.1.1' "DRV_RESOLV2" 2>/dev/null && { echo "1.2.3.4"; exit 0; }
exit 1
DIG2EOF
    sed -i "s|DRV_RESOLV2|$work/resolv.conf|g" "$work/bin/dig"
    chmod 0755 "$work/bin/dig"
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1; then
        pass "selfheal-dns-heal-proceeds:OK"
    else
        fail "selfheal-dns-heal-proceeds:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # Epilogue must have restored the ORIGINAL resolv.conf.
    if [ "$(cat "$work/resolv.conf" 2>/dev/null)" = "original-resolver" ]; then
        pass "selfheal-dns-heal-resolv-restored:OK"
    else
        fail "selfheal-dns-heal-resolv-restored:FAIL" "$(cat "$work/resolv.conf" 2>/dev/null)"
    fi
    # DNS heal alone was enough → redirect should NOT have been torn down.
    if [ ! -f "$work/init.log" ] || ! grep -q 'stop' "$work/init.log"; then
        pass "selfheal-dns-heal-no-teardown:OK"
    else
        fail "selfheal-dns-heal-no-teardown:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi

    # ── Scenario 3: DNS heal insufficient → redirect teardown heals ───────────
    # DNS resolves even with the temp resolver, but HTTP only comes up AFTER the
    # redirect is torn down (the fake init writes a marker on stop that flips
    # HTTP on).
    rm -f "$SELFHEAL_DNS_OK"; rm -f "$SELFHEAL_HTTP_OK"; : > "$SELFHEAL_PKG_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    printf 'original-resolver\n' > "$work/resolv.conf"
    make_fake_core
    # DNS resolves only with temp resolver present (as scenario 2).
    # HTTP succeeds only after init stop has been recorded.
    cat > "$work/bin/curl" << 'CURL3EOF'
#!/bin/sh
grep -q 'stop' "$SELFHEAL_INIT_LOG" 2>/dev/null && exit 0
exit 1
CURL3EOF
    chmod 0755 "$work/bin/curl"
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1; then
        pass "selfheal-teardown-heal-proceeds:OK"
    else
        fail "selfheal-teardown-heal-proceeds:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if grep -q 'stop' "$work/init.log" 2>/dev/null; then
        pass "selfheal-teardown-taken:OK"
    else
        fail "selfheal-teardown-taken:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi
    if grep -q 'start' "$work/init.log" 2>/dev/null; then
        pass "selfheal-teardown-bringup-called:OK"
    else
        fail "selfheal-teardown-bringup-called:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi
    if [ "$(cat "$work/resolv.conf" 2>/dev/null)" = "original-resolver" ]; then
        pass "selfheal-teardown-resolv-restored:OK"
    else
        fail "selfheal-teardown-resolv-restored:FAIL" "$(cat "$work/resolv.conf" 2>/dev/null)"
    fi

    # ── Scenario 4: heal fails entirely → install ABORTED, binary not removed ─
    rm -f "$SELFHEAL_DNS_OK"; rm -f "$SELFHEAL_HTTP_OK"; : > "$SELFHEAL_PKG_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    printf 'original-resolver\n' > "$work/resolv.conf"
    make_fake_core
    # DNS never resolves; HTTP never reachable even after teardown.
    cat > "$work/bin/dig" << 'DIG4EOF'
#!/bin/sh
exit 1
DIG4EOF
    cat > "$work/bin/curl" << 'CURL4EOF'
#!/bin/sh
exit 1
CURL4EOF
    chmod 0755 "$work/bin/dig" "$work/bin/curl"
    run_scenario
    if jq -e '.success == false and (.message | length) > 0' "$out" > /dev/null 2>&1; then
        pass "selfheal-heal-fail-aborts-successfalse:OK"
    else
        fail "selfheal-heal-fail-aborts-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # The (mock) binary must NOT have been removed (opkg install never ran).
    if [ -e "$work/usr-bin-sing-box" ]; then
        pass "selfheal-heal-fail-binary-intact:OK"
    else
        fail "selfheal-heal-fail-binary-intact:FAIL" "mock binary was removed"
    fi
    # Original resolv.conf restored by the epilogue.
    if [ "$(cat "$work/resolv.conf" 2>/dev/null)" = "original-resolver" ]; then
        pass "selfheal-heal-fail-resolv-restored:OK"
    else
        fail "selfheal-heal-fail-resolv-restored:FAIL" "$(cat "$work/resolv.conf" 2>/dev/null)"
    fi
    # Redirect was torn down during the (failed) heal → epilogue brings it back.
    if grep -q 'start' "$work/init.log" 2>/dev/null; then
        pass "selfheal-heal-fail-bringup-called:OK"
    else
        fail "selfheal-heal-fail-bringup-called:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi

    # ── Scenario 5: stable install fails after binary removed → backup restored
    : > "$SELFHEAL_DNS_OK"; : > "$SELFHEAL_HTTP_OK"; rm -f "$SELFHEAL_PKG_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    printf 'original-resolver\n' > "$work/resolv.conf"
    make_fake_core EXTENDED-CORE-BYTES
    # Connectivity is fine; dig/curl just check the markers.
    cat > "$work/bin/dig" << 'DIG5EOF'
#!/bin/sh
[ -f "$SELFHEAL_DNS_OK" ] && { echo "1.2.3.4"; exit 0; }
exit 1
DIG5EOF
    cat > "$work/bin/curl" << 'CURL5EOF'
#!/bin/sh
[ -f "$SELFHEAL_HTTP_OK" ] && exit 0
exit 1
CURL5EOF
    chmod 0755 "$work/bin/dig" "$work/bin/curl"
    run_scenario
    if jq -e '.success == false' "$out" > /dev/null 2>&1; then
        pass "selfheal-stable-install-fail-successfalse:OK"
    else
        fail "selfheal-stable-install-fail-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # The opkg stub removed the live binary; the tmpfs backup must be restored
    # so a working binary remains with the ORIGINAL extended bytes.
    if grep -q 'core-marker: EXTENDED-CORE-BYTES' "$work/usr-bin-sing-box" 2>/dev/null; then
        pass "selfheal-stable-install-fail-backup-restored:OK"
    else
        fail "selfheal-stable-install-fail-backup-restored:FAIL" "$(cat "$work/usr-bin-sing-box" 2>/dev/null)"
    fi

    # ── apk-tools 3 scenarios (OpenWrt 25.12+). The stub mirrors apk 3.0.5 as
    # observed on a router: there is no --allow-downgrade; `fix` (and `add
    # --force-reinstall NAME`) exit 0 without reinstalling when the installed
    # build is no longer in the feed index; `fetch` downloads the feed package;
    # a package file installs only with --allow-untrusted and pins its hash in
    # the world file. It is created only here, so scenarios 1-5 stay on opkg.
    cat > "$work/bin/apk" << 'APKEOF'
#!/bin/sh
for a in "$@"; do
    if [ "$a" = "--allow-downgrade" ]; then
        echo "ERROR: command line: unrecognized option 'allow-downgrade'" >&2
        exit 1
    fi
done
set_world_entry() {
    grep -v '^sing-box' "$SELFHEAL_APK_WORLD" > "$SELFHEAL_APK_WORLD.new" 2>/dev/null
    [ -n "$1" ] && printf '%s\n' "$1" >> "$SELFHEAL_APK_WORLD.new"
    mv -f "$SELFHEAL_APK_WORLD.new" "$SELFHEAL_APK_WORLD"
}
cmd="$1"
printf '%s\n' "$cmd" >> "$SELFHEAL_APK_LOG"
shift
case "$cmd" in
update) exit 0 ;;
fix)
    [ -f "$SELFHEAL_APK_INDEXED" ] && printf 'stable-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    exit 0
    ;;
fetch)
    [ -f "$SELFHEAL_APK_FETCH_OK" ] || exit 1
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "-o" ]; then
            printf '%s\n' "$2" > "$SELFHEAL_APK_FETCHED_TO"
            : > "$2/sing-box-1.12.0-r1.apk"
            exit 0
        fi
        shift
    done
    exit 1
    ;;
add)
    untrusted=0
    reinstall=0
    file=""
    name=""
    for a in "$@"; do
        case "$a" in
        --allow-untrusted) untrusted=1 ;;
        --force-reinstall) reinstall=1 ;;
        -*) ;;
        *.apk) file="$a" ;;
        *) name="$a" ;;
        esac
    done
    if [ -n "$file" ]; then
        [ "$untrusted" -eq 1 ] || exit 99
        [ -f "$file" ] || exit 1
        printf 'stable-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
        set_world_entry 'sing-box><Q1FAKEHASH='
        exit 0
    fi
    if [ "$reinstall" -eq 1 ] && [ -f "$SELFHEAL_APK_INDEXED" ]; then
        printf 'stable-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    fi
    # A version-pinned world entry can no longer be satisfied once the feed has
    # moved on; apk rejects it and leaves the world as it is.
    case "$name" in
    *=*)
        if [ "${name#*=}" != "$(cat "$SELFHEAL_APK_FEED_VERSION" 2>/dev/null)" ]; then
            echo "ERROR: unable to select packages: breaks: world[$name]" >&2
            exit 2
        fi
        ;;
    esac
    [ -n "$name" ] && set_world_entry "$name"
    exit 0
    ;;
del)
    # Removing a world entry also drops reverse dependencies that are not world
    # members themselves, so the package (and NetShift with it) can disappear.
    # The marker models an apk that takes the core even though netshift IS a
    # world member — the caller must not trust the dependency blindly.
    if [ -f "$SELFHEAL_APK_DEL_PURGES" ] || ! grep -q '^netshift' "$SELFHEAL_APK_WORLD" 2>/dev/null; then
        rm -f "$SELFHEAL_BIN" 2>/dev/null
    fi
    [ -f "$SELFHEAL_APK_DEL_PURGES_NETSHIFT" ] && rm -f /etc/init.d/netshift
    set_world_entry ""
    exit 0
    ;;
esac
exit 0
APKEOF
    chmod 0755 "$work/bin/apk"
    export SELFHEAL_APK_INDEXED="$work/apk_indexed"
    export SELFHEAL_APK_FETCH_OK="$work/apk_fetch_ok"
    export SELFHEAL_APK_WORLD="$work/apk-world"
    export SELFHEAL_APK_FEED_VERSION="$work/apk_feed_version"
    export SELFHEAL_APK_DEL_PURGES="$work/apk_del_purges"
    export SELFHEAL_APK_DEL_PURGES_NETSHIFT="$work/apk_del_purges_netshift"
    printf '1.12.0-r1\n' > "$SELFHEAL_APK_FEED_VERSION"
    rm -f "$SELFHEAL_APK_DEL_PURGES"

    # ── Scenario 6 (apk): installed build still in the feed index → in-place
    # reinstall lands; NetShift restarts only once the tmpfs backup is gone.
    : > "$SELFHEAL_DNS_OK"; : > "$SELFHEAL_HTTP_OK"; rm -f "$SELFHEAL_PKG_OK"
    : > "$SELFHEAL_APK_INDEXED"; : > "$SELFHEAL_APK_FETCH_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1 && \
            [ "$(cat "$SELFHEAL_CORE_VERSION" 2>/dev/null)" = "stable-1.12.0" ]; then
        pass "selfheal-apk-indexed-stable-installed:OK"
    else
        fail "selfheal-apk-indexed-stable-installed:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if [ "$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null)" = "netshift" ]; then
        pass "selfheal-apk-indexed-world-untouched:OK"
    else
        fail "selfheal-apk-indexed-world-untouched:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null)"
    fi
    if grep -qx 'restart' "$work/init.log" 2>/dev/null && \
            ! grep -q 'backup-present' "$work/init.log" 2>/dev/null; then
        pass "selfheal-apk-restart-after-backup-freed:OK"
    else
        fail "selfheal-apk-restart-after-backup-freed:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi

    # ── Scenario 7 (apk): installed build no longer in the feed index (the feed
    # was rebuilt) → `apk fix` skips silently, so the feed package file must be
    # installed instead, without leaving its hash pinned in the world file.
    rm -f "$SELFHEAL_APK_INDEXED"; : > "$SELFHEAL_APK_FETCH_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\n' > "$SELFHEAL_APK_WORLD"
    # Download directory left on flash by a run that was killed mid-fetch.
    mkdir -p "$SELFHEAL_APK_FETCH_DIR.stale1"
    : > "$SELFHEAL_APK_FETCH_DIR.stale1/sing-box-1.11.0-r1.apk"
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1 && \
            [ "$(cat "$SELFHEAL_CORE_VERSION" 2>/dev/null)" = "stable-1.12.0" ]; then
        pass "selfheal-apk-unindexed-stable-installed:OK"
    else
        fail "selfheal-apk-unindexed-stable-installed:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # The package is downloaded next to the binary, not into the tmpfs
    # directory that holds the backup of the extended core.
    case "$(cat "$SELFHEAL_APK_FETCHED_TO" 2>/dev/null)" in
    /tmp/netshift-sbstable.*)
        fail "selfheal-apk-fetch-not-in-backup-tmpfs:FAIL" "fetched to $(cat "$SELFHEAL_APK_FETCHED_TO")"
        ;;
    "$SELFHEAL_APK_FETCH_DIR".*)
        pass "selfheal-apk-fetch-not-in-backup-tmpfs:OK"
        ;;
    *)
        fail "selfheal-apk-fetch-not-in-backup-tmpfs:FAIL" "fetched to '$(cat "$SELFHEAL_APK_FETCHED_TO" 2>/dev/null)'"
        ;;
    esac
    if [ -z "$(ls -d "$SELFHEAL_APK_FETCH_DIR".* 2>/dev/null)" ]; then
        pass "selfheal-apk-fetch-dirs-cleaned:OK"
    else
        fail "selfheal-apk-fetch-dirs-cleaned:FAIL" "$(ls -d "$SELFHEAL_APK_FETCH_DIR".* 2>/dev/null)"
    fi
    if jq -e '.success == true' "$out" > /dev/null 2>&1 && \
            [ "$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null)" = "netshift" ]; then
        pass "selfheal-apk-unindexed-world-pin-dropped:OK"
    else
        fail "selfheal-apk-unindexed-world-pin-dropped:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null)"
    fi
    # Same, but sing-box was an explicit world entry → that entry is kept.
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\nsing-box\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1 && \
            [ "$(grep '^sing-box' "$SELFHEAL_APK_WORLD" 2>/dev/null)" = "sing-box" ]; then
        pass "selfheal-apk-unindexed-world-entry-kept:OK"
    else
        fail "selfheal-apk-unindexed-world-entry-kept:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi

    # ── Scenario 8 (apk): the switch does not land (not in the index and the
    # fetch fails) → success:false, core intact, and NetShift is NOT restarted.
    rm -f "$SELFHEAL_APK_INDEXED"; rm -f "$SELFHEAL_APK_FETCH_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == false' "$out" > /dev/null 2>&1; then
        pass "selfheal-apk-not-landed-successfalse:OK"
    else
        fail "selfheal-apk-not-landed-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if grep -q 'core-marker: EXTENDED-CORE-BYTES' "$work/usr-bin-sing-box" 2>/dev/null; then
        pass "selfheal-apk-not-landed-core-intact:OK"
    else
        fail "selfheal-apk-not-landed-core-intact:FAIL" "$(cat "$work/usr-bin-sing-box" 2>/dev/null)"
    fi
    if [ -f "$work/init.log" ] && ! grep -q 'restart' "$work/init.log"; then
        pass "selfheal-apk-not-landed-no-restart:OK"
    else
        fail "selfheal-apk-not-landed-no-restart:FAIL" "init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi

    # ── Scenario 9 (apk): the world held a VERSION PIN the feed no longer has.
    # Putting it back fails ("breaks: world[sing-box=...]"), but the hash pin the
    # file install wrote must not survive that: it would silently block every
    # later `apk upgrade sing-box`. The switch itself stands, and the unrestored
    # entry is reported in the result rather than only logged.
    rm -f "$SELFHEAL_APK_INDEXED"; : > "$SELFHEAL_APK_FETCH_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\nsing-box=1.11.0-r1\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true' "$out" > /dev/null 2>&1 && \
            ! grep -q '^sing-box><' "$SELFHEAL_APK_WORLD" 2>/dev/null; then
        pass "selfheal-apk-stale-pin-hash-pin-dropped:OK"
    else
        fail "selfheal-apk-stale-pin-hash-pin-dropped:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi
    if jq -e '(.warning // "") | length > 0' "$out" > /dev/null 2>&1; then
        pass "selfheal-apk-stale-pin-reported:OK"
    else
        fail "selfheal-apk-stale-pin-reported:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Scenario 10 (apk): a repo-tagged world entry ("sing-box@custom") is a
    # legal entry too — it must be recognised and put back, not silently lost.
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\nsing-box@custom\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if [ "$(grep '^sing-box' "$SELFHEAL_APK_WORLD" 2>/dev/null)" = "sing-box@custom" ] && \
            jq -e 'has("warning") | not' "$out" > /dev/null 2>&1; then
        pass "selfheal-apk-tagged-world-entry-kept:OK"
    else
        fail "selfheal-apk-tagged-world-entry-kept:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi

    # ── Scenario 11 (apk): NetShift is not a world member. `apk del sing-box`
    # would purge NetShift along with the package, so the pin is left in place
    # and reported instead — a blocked upgrade beats a purged application.
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'sing-box\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if ! grep -qx 'del' "$SELFHEAL_APK_LOG" 2>/dev/null && [ -x /etc/init.d/netshift ]; then
        pass "selfheal-apk-no-netshift-in-world-no-del:OK"
    else
        fail "selfheal-apk-no-netshift-in-world-no-del:FAIL" "apk.log=$(cat "$SELFHEAL_APK_LOG" 2>/dev/null)"
    fi
    if jq -e '.success == true and ((.warning // "") | length > 0)' "$out" > /dev/null 2>&1; then
        pass "selfheal-apk-no-netshift-in-world-reported:OK"
    else
        fail "selfheal-apk-no-netshift-in-world-reported:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Scenario 12 (apk): `apk del` takes the core with it after all. The
    # dependency is not treated as a guarantee: with no runnable core left the
    # backup is restored and the switch is reported as failed, not successful.
    : > "$SELFHEAL_APK_DEL_PURGES"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == false' "$out" > /dev/null 2>&1 && \
            grep -q 'core-marker: EXTENDED-CORE-BYTES' "$SELFHEAL_BIN" 2>/dev/null && \
            [ -f "$work/init.log" ] && ! grep -q 'restart' "$work/init.log"; then
        pass "selfheal-apk-del-took-core-rolled-back:OK"
    else
        fail "selfheal-apk-del-took-core-rolled-back:FAIL" "out=$(cat "$out" 2>/dev/null) init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi
    rm -f "$SELFHEAL_APK_DEL_PURGES"

    # ── Scenario 14 (apk): a hash pin is already in the world before the switch
    # (left by an earlier run that could not drop it). Comparing the world with
    # its state before the install cannot see it — two installs of one file
    # write the same pin — so a hash pin is never taken as the entry to keep,
    # whichever route the install takes.
    : > "$SELFHEAL_APK_INDEXED"; : > "$SELFHEAL_APK_FETCH_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\nsing-box><Q1FAKEHASH=\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true and (has("warning") | not)' "$out" > /dev/null 2>&1 && \
            [ "$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null)" = "netshift" ]; then
        pass "selfheal-apk-leftover-pin-dropped-fix-route:OK"
    else
        fail "selfheal-apk-leftover-pin-dropped-fix-route:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi
    rm -f "$SELFHEAL_APK_INDEXED"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\nsing-box><Q1FAKEHASH=\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true and (has("warning") | not)' "$out" > /dev/null 2>&1 && \
            [ "$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null)" = "netshift" ]; then
        pass "selfheal-apk-leftover-pin-dropped-file-route:OK"
    else
        fail "selfheal-apk-leftover-pin-dropped-file-route:FAIL" "world=$(cat "$SELFHEAL_APK_WORLD" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi

    # ── Scenario 15 (apk): the same leftover pin on a router where NetShift is
    # not a world member — scenario 11 run a second time with the same feed.
    # The pin cannot be dropped safely, and that must be reported every time,
    # not only on the run that wrote it.
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'sing-box><Q1FAKEHASH=\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true and ((.warning // "") | contains("sing-box><Q1FAKEHASH="))' "$out" > /dev/null 2>&1 && \
            ! grep -qx 'del' "$SELFHEAL_APK_LOG" 2>/dev/null; then
        pass "selfheal-apk-leftover-pin-no-netshift-reported:OK"
    else
        fail "selfheal-apk-leftover-pin-no-netshift-reported:FAIL" "apk.log=$(cat "$SELFHEAL_APK_LOG" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi
    # "!netshift" excludes NetShift instead of keeping it installed, so it does
    # not make `apk del sing-box` safe.
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf '!netshift\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true and ((.warning // "") | length > 0)' "$out" > /dev/null 2>&1 && \
            ! grep -qx 'del' "$SELFHEAL_APK_LOG" 2>/dev/null; then
        pass "selfheal-apk-excluded-netshift-no-del:OK"
    else
        fail "selfheal-apk-excluded-netshift-no-del:FAIL" "apk.log=$(cat "$SELFHEAL_APK_LOG" 2>/dev/null) out=$(cat "$out" 2>/dev/null)"
    fi

    # ── Scenario 16 (apk): the switch fails (fetch fails) while the world holds
    # a pin that cannot be dropped: success:false, and the pin is reported in
    # that result too.
    rm -f "$SELFHEAL_APK_FETCH_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'sing-box><Q1FAKEHASH=\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == false and ((.warning // "") | contains("sing-box><Q1FAKEHASH="))' "$out" > /dev/null 2>&1 && \
            grep -q 'core-marker: EXTENDED-CORE-BYTES' "$SELFHEAL_BIN" 2>/dev/null; then
        pass "selfheal-apk-failed-switch-reports-pin:OK"
    else
        fail "selfheal-apk-failed-switch-reports-pin:FAIL" "out=$(cat "$out" 2>/dev/null)"
    fi
    : > "$SELFHEAL_APK_FETCH_OK"

    # ── Scenario 17 (apk): `apk del sing-box` removes NetShift although it is a
    # world member. The core switch stands, and the user is told in the result.
    : > "$SELFHEAL_APK_DEL_PURGES_NETSHIFT"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    printf 'netshift\n' > "$SELFHEAL_APK_WORLD"
    run_scenario
    if jq -e '.success == true and ((.warning // "") | contains("NetShift"))' "$out" > /dev/null 2>&1; then
        pass "selfheal-apk-del-took-netshift-reported:OK"
    else
        fail "selfheal-apk-del-took-netshift-reported:FAIL" "out=$(cat "$out" 2>/dev/null)"
    fi
    rm -f "$SELFHEAL_APK_DEL_PURGES_NETSHIFT"
    cp -p "$work/init/netshift" "$init_target" 2>/dev/null
    chmod 0755 "$init_target" 2>/dev/null || true
    rm -f "$work/bin/apk"

    # ── Scenario 13 (opkg): the package manager exits 0 and reports a stable
    # version, but leaves no runnable core. The version gate must read the
    # binary itself — get_sing_box_version()'s "1.0" fallback is not extended
    # either, so trusting it would restart NetShift onto a missing core and call
    # that a success.
    : > "$SELFHEAL_DNS_OK"; : > "$SELFHEAL_HTTP_OK"; : > "$SELFHEAL_PKG_OK"
    : > "$SELFHEAL_PKG_BREAKS_CORE"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    run_scenario
    if jq -e '.success == false and (.message | contains("runnable"))' "$out" > /dev/null 2>&1; then
        pass "selfheal-no-runnable-core-successfalse:OK"
    else
        fail "selfheal-no-runnable-core-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if grep -q 'core-marker: EXTENDED-CORE-BYTES' "$SELFHEAL_BIN" 2>/dev/null && \
            [ -f "$work/init.log" ] && ! grep -q 'restart' "$work/init.log"; then
        pass "selfheal-no-runnable-core-rolled-back:OK"
    else
        fail "selfheal-no-runnable-core-rolled-back:FAIL" "core=$(cat "$SELFHEAL_BIN" 2>/dev/null) init.log=$(cat "$work/init.log" 2>/dev/null)"
    fi
    rm -f "$SELFHEAL_PKG_BREAKS_CORE"
    # A core that prints a version line and then exits non-zero is not a
    # runnable core either.
    : > "$SELFHEAL_PKG_CORE_FAILS"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    make_fake_core EXTENDED-CORE-BYTES
    run_scenario
    if jq -e '.success == false and (.message | contains("runnable"))' "$out" > /dev/null 2>&1 && \
            grep -q 'core-marker: EXTENDED-CORE-BYTES' "$SELFHEAL_BIN" 2>/dev/null; then
        pass "selfheal-failing-core-rolled-back:OK"
    else
        fail "selfheal-failing-core-rolled-back:FAIL" "out=$(cat "$out" 2>/dev/null) core=$(cat "$SELFHEAL_BIN" 2>/dev/null)"
    fi
    rm -f "$SELFHEAL_PKG_CORE_FAILS"

    # ── Restore the real init script (if any) and clean up. ──────────────────
    if [ -n "$init_saved" ] && [ -e "$init_saved" ]; then
        cp -p "$init_saved" "$init_target" 2>/dev/null || true
    else
        rm -f "$init_target" 2>/dev/null || true
    fi
    unset SELFHEAL_DNS_OK SELFHEAL_HTTP_OK SELFHEAL_PKG_OK SELFHEAL_INIT_LOG \
        SELFHEAL_CORE_VERSION SELFHEAL_BIN SELFHEAL_APK_INDEXED \
        SELFHEAL_APK_FETCH_OK SELFHEAL_APK_WORLD SELFHEAL_APK_FEED_VERSION \
        SELFHEAL_APK_DEL_PURGES SELFHEAL_APK_LOG SELFHEAL_APK_FETCH_DIR \
        SELFHEAL_PKG_BREAKS_CORE SELFHEAL_PKG_CORE_FAILS \
        SELFHEAL_APK_FETCHED_TO SELFHEAL_APK_DEL_PURGES_NETSHIFT
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Subscription rejected-hash validity (task-011)
# ─────────────────────────────────────────────────────────────────
# Verifies the keyword-filter no longer poisons the per-section .rejected hash
# and that a structurally valid body with >=1 proxy outbound is never vetoed by
# a stale rejected-hash, while a genuinely outbound-less body still is. The
# functions under test (mark_subscription_outbound_unavailable,
# subscription_cache_is_usable) and the per-URL cache path/hash builders live in
# /usr/bin/netshift, not a sourceable lib, so a tiny driver extracts them
# VERBATIM from the live bin (awk between the `name() {` line and the matching
# column-0 `}`), stubs only the UCI-facing subscription-URL provider (plus the
# logger), sources helpers.sh for the real validate_subscription_file, and
# re-pins SUBSCRIPTION_CACHE_FOLDER to a temp dir. Tokens use the same
# name:OK/FAIL convention as test_subscription.
test_rejected_hash() {
    header "Subscription Rejected-Hash Validity (task-011)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local helpers="${NETSHIFT_LIB_DIR}/helpers.sh"
    if [ ! -r "$bin" ] || [ ! -r "$helpers" ]; then
        skip "netshift bin / helpers.sh not found"
        return
    fi

    local drv="/tmp/netshift-rejected-$$.sh"
    cat > "$drv" << 'RHEOF'
# Isolated cache dir for this run (the path builders read SUBSCRIPTION_CACHE_FOLDER).
SUBSCRIPTION_CACHE_FOLDER="${RH_CACHE_DIR:-/tmp/netshift-rejected-cache}"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"

# Quiet stubs for the logger used by the functions under test.
log() { :; }
echolog() { :; }
nolog() { :; }

# The real get_subscription_urls_for_section() enumerates a section's feed URLs
# from UCI, which this driver has no access to, so stub ONLY that boundary. The
# stub emits each URL newline-terminated: the consumers inside
# mark_subscription_outbound_unavailable() read the provider output with a bare
# `while IFS= read -r url` (no `|| [ -n "$url" ]` EOF guard), which drops an
# unterminated final line - so the stub feeds the shape those consumers need.
RH_TEST_URL="https://feed.example.com/sub"
get_subscription_urls_for_section() { printf '%s\n' "$RH_TEST_URL"; }

# Real validate_subscription_file from helpers.sh (no other deps needed).
. "HELPERS_PATH"

# Pull the per-URL hash + path builders and the two functions under test
# VERBATIM out of the live bin so the test exercises the shipped code, not a
# copy. awk grabs each function from its opener to the matching column-0 brace.
for fn in get_subscription_url_hash get_subscription_json_path \
          get_subscription_rejected_cache_path \
          mark_subscription_outbound_unavailable subscription_cache_is_usable; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
done

# Globals the functions touch.
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
subscription_startup_blocked=0

# The bin keys every feed by the md5 of its URL. Precompute that hash once and
# build both the fixture and assertion paths with the shipped builders, so they
# resolve exactly the per-URL cache files the functions under test touch.
RH_URLHASH="$(get_subscription_url_hash "$RH_TEST_URL")"
rh_json_path() { get_subscription_json_path "$1" "$RH_URLHASH"; }
rh_rejected_path() { get_subscription_rejected_cache_path "$1" "$RH_URLHASH"; }

valid_body='{
  "outbounds": [
    {"type": "shadowsocks", "tag": "ss-01", "server": "a.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "selector", "tag": "select", "outbounds": ["ss-01"]}
  ]
}'

# ── CASE 1: A — over-strict keyword filter (kept=0) must NOT write .rejected,
#            and must remove a pre-existing one. ─────────────────────────────
s1="sec1"
printf '%s' "$valid_body" > "$(rh_json_path "$s1")"
# Pre-poison with this body's hash; arg=1 (keyword filter) must clear it.
md5sum "$(rh_json_path "$s1")" | awk '{print $1}' \
    > "$(rh_rejected_path "$s1")"
mark_subscription_outbound_unavailable "$s1" 1
if [ ! -e "$(rh_rejected_path "$s1")" ]; then
    echo 'rh-case1-filter-no-rejected:OK'
else
    echo 'rh-case1-filter-no-rejected:FAIL'
fi
if [ "$subscription_startup_blocked" = "1" ]; then
    echo 'rh-case1-blocked-state-set:OK'
else
    echo 'rh-case1-blocked-state-set:FAIL'
fi

# ── CASE 2: A-recovery — pre-existing .rejected == a valid body hash, call with
#            arg=1, assert .rejected gone (self-heal). ────────────────────────
s2="sec2"
printf '%s' "$valid_body" > "$(rh_json_path "$s2")"
md5sum "$(rh_json_path "$s2")" | awk '{print $1}' \
    > "$(rh_rejected_path "$s2")"
[ -s "$(rh_rejected_path "$s2")" ] && pre2=1 || pre2=0
mark_subscription_outbound_unavailable "$s2" 1
if [ "$pre2" = "1" ] && [ ! -e "$(rh_rejected_path "$s2")" ]; then
    echo 'rh-case2-recovery-rejected-removed:OK'
else
    echo 'rh-case2-recovery-rejected-removed:FAIL'
fi

# ── CASE 3: B — valid body with >=1 proxy outbound + .rejected == its hash ⇒
#            subscription_cache_is_usable returns 0 (usable). ─────────────────
s3="sec3"
s3_json="$(rh_json_path "$s3")"
printf '%s' "$valid_body" > "$s3_json"
md5sum "$s3_json" | awk '{print $1}' > "$(rh_rejected_path "$s3")"
if subscription_cache_is_usable "$s3_json"; then
    echo 'rh-case3-valid-body-not-vetoed:OK'
else
    echo 'rh-case3-valid-body-not-vetoed:FAIL'
fi

# ── CASE 4: A-protected — a JSON body with ZERO proxy outbounds whose hash is in
#            .rejected ⇒ still vetoed (return 1). validate_subscription_file
#            itself requires >=1 proxy outbound, so an outbound-less body is
#            rejected at validation; this case proves the guard still holds. ──
s4="sec4"
s4_json="$(rh_json_path "$s4")"
cat > "$s4_json" << 'NOPROXY'
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": []},
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ]
}
NOPROXY
md5sum "$s4_json" | awk '{print $1}' > "$(rh_rejected_path "$s4")"
if subscription_cache_is_usable "$s4_json"; then
    echo 'rh-case4-no-proxy-body-vetoed:FAIL'
else
    echo 'rh-case4-no-proxy-body-vetoed:OK'
fi

# ── CASE 5: Regression — a normal valid body, no .rejected ⇒ usable (0). ──────
s5="sec5"
s5_json="$(rh_json_path "$s5")"
printf '%s' "$valid_body" > "$s5_json"
rm -f "$(rh_rejected_path "$s5")"
if subscription_cache_is_usable "$s5_json"; then
    echo 'rh-case5-normal-valid-usable:OK'
else
    echo 'rh-case5-normal-valid-usable:FAIL'
fi

# ── CASE 6: A — keyword_filter_active=0 (default) still records the rejected
#            hash for a genuinely outbound-less body (flash-loop guard kept). ──
s6="sec6"
s6_json="$(rh_json_path "$s6")"
cat > "$s6_json" << 'NOPROXY'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ]
}
NOPROXY
rm -f "$(rh_rejected_path "$s6")"
mark_subscription_outbound_unavailable "$s6" 0
expect6="$(md5sum "$s6_json" | awk '{print $1}')"
got6="$(cat "$(rh_rejected_path "$s6")" 2>/dev/null)"
if [ -s "$(rh_rejected_path "$s6")" ] && [ "$got6" = "$expect6" ]; then
    echo 'rh-case6-genuine-unusable-recorded:OK'
else
    echo 'rh-case6-genuine-unusable-recorded:FAIL'
fi

echo 'DONE'
RHEOF

    sed -i "s|HELPERS_PATH|$helpers|g; s|BIN_PATH|$bin|g" "$drv"

    local rhcache="/tmp/netshift-rejected-cache-$$"
    rm -rf "$rhcache"

    # Parse in the CURRENT shell (temp file + `while read < "$rh_out"`, NO pipe)
    # so pass/fail update the global counters and an rh-case*:FAIL actually gates
    # the suite (a pipe would run the while-body in a subshell - non-gating).
    local rh_out="/tmp/netshift-rejected-out-$$.txt"
    if ! RH_CACHE_DIR="$rhcache" ash "$drv" > "$rh_out" 2>/dev/null; then
        fail "netshift-rejected driver exited non-zero"
    fi
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done < "$rh_out"

    rm -rf "$rhcache"
    rm -f "$drv" "$rh_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: DNS via outbound (task-014) — detour wiring + fail-safe cascade
# ─────────────────────────────────────────────────────────────────
test_dns_via_outbound() {
    header "DNS via Outbound (task-014)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local facade_lib="${NETSHIFT_LIB_DIR}/sing_box_config_facade.sh"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$facade_lib" ] || [ ! -r "$bin" ]; then
        skip "facade lib / netshift bin not found"
        return
    fi

    # Bind bind-mounted sources to the runtime path the facade hardcodes.
    mkdir -p /usr/lib/netshift
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/netshift-dnsdetour-$$.sh"
    cat > "$drv" << 'DDEOF'
. "NETSHIFT_LIB/logging.sh" 2>/dev/null || log() { :; }
. "FACADE_LIB_PATH"

# Minimal DNS skeleton like sing_box_cm_configure_dns produces.
base_config='{"dns":{"servers":[],"rules":[],"final":"dns-server","strategy":"prefer_ipv4","independent_cache":true},"outbounds":[{"type":"direct","tag":"direct-out"}]}'

# Tags mirror the constants used in production.
BOOT="bootstrap"
MAIN="dns-server"
FAKE="fakeip"
DETOUR_TAG="main-out"

# ── Build a config WITH a non-empty detour on the MAIN DNS only. ─────────────
cfg_on="$base_config"
cfg_on=$(sing_box_cm_add_udp_dns_server "$cfg_on" "$BOOT" "77.88.8.8" 53)
cfg_on=$(sing_box_cf_add_dns_server "$cfg_on" "udp" "$MAIN" "1.1.1.1" "" "$DETOUR_TAG")
cfg_on=$(sing_box_cm_add_fakeip_dns_server "$cfg_on" "$FAKE" "198.18.0.0/15")

echo "$cfg_on" | jq -e --arg t "$MAIN" --arg d "$DETOUR_TAG" \
    '(.dns.servers[] | select(.tag==$t) | .detour) == $d' >/dev/null 2>&1 \
    && echo 'dns-on-main-has-detour:OK' || echo 'dns-on-main-has-detour:FAIL'
echo "$cfg_on" | jq -e --arg t "$BOOT" \
    '(.dns.servers[] | select(.tag==$t) | has("detour")) == false' >/dev/null 2>&1 \
    && echo 'dns-on-bootstrap-no-detour:OK' || echo 'dns-on-bootstrap-no-detour:FAIL'
echo "$cfg_on" | jq -e --arg t "$FAKE" \
    '(.dns.servers[] | select(.tag==$t) | has("detour")) == false' >/dev/null 2>&1 \
    && echo 'dns-on-fakeip-no-detour:OK' || echo 'dns-on-fakeip-no-detour:FAIL'

# ── Build a config with an EMPTY detour (feature off) — no .detour key. ──────
cfg_off="$base_config"
cfg_off=$(sing_box_cm_add_udp_dns_server "$cfg_off" "$BOOT" "77.88.8.8" 53)
cfg_off=$(sing_box_cf_add_dns_server "$cfg_off" "udp" "$MAIN" "1.1.1.1" "" "")
cfg_off=$(sing_box_cm_add_fakeip_dns_server "$cfg_off" "$FAKE" "198.18.0.0/15")

echo "$cfg_off" | jq -e --arg t "$MAIN" \
    '(.dns.servers[] | select(.tag==$t) | has("detour")) == false' >/dev/null 2>&1 \
    && echo 'dns-off-main-no-detour:OK' || echo 'dns-off-main-no-detour:FAIL'

# Byte-parity: the main DNS server object with empty tag must equal the object
# built without passing a detour arg at all.
cfg_legacy="$base_config"
cfg_legacy=$(sing_box_cf_add_dns_server "$cfg_legacy" "udp" "$MAIN" "1.1.1.1" "")
legacy_obj=$(echo "$cfg_legacy" | jq -cS --arg t "$MAIN" '.dns.servers[] | select(.tag==$t)')
off_obj=$(echo "$cfg_off" | jq -cS --arg t "$MAIN" '.dns.servers[] | select(.tag==$t)')
if [ "$legacy_obj" = "$off_obj" ]; then
    echo 'dns-off-byte-parity:OK'
else
    echo 'dns-off-byte-parity:FAIL'
fi

# ── Both configs must pass sing-box check (whole-chain validation). ──────────
if command -v sing-box > /dev/null 2>&1; then
    echo "$cfg_on" > /tmp/dnsdetour-on.json
    echo "$cfg_off" > /tmp/dnsdetour-off.json
    sing-box -c /tmp/dnsdetour-on.json check >/dev/null 2>&1 \
        && echo 'dns-on-singbox-check:OK' || echo 'dns-on-singbox-check:FAIL'
    sing-box -c /tmp/dnsdetour-off.json check >/dev/null 2>&1 \
        && echo 'dns-off-singbox-check:OK' || echo 'dns-off-singbox-check:FAIL'
    rm -f /tmp/dnsdetour-on.json /tmp/dnsdetour-off.json
else
    echo 'dns-on-singbox-check:SKIP'
    echo 'dns-off-singbox-check:SKIP'
fi

# ── Fail-safe cascade: exercise _get_dns_detour_tag VERBATIM from the bin. ───
# Stub UCI + the reused helpers so the cascade is fully controllable. The stubs
# read from shell variables set per-case below.
eval "$(awk '/^_get_dns_detour_tag\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

# UCI stubs (mimic LuCI config_get / config_get_bool: assign-and-return-0).
config_get_bool() { eval "$1=\"\${UCI_DNS_VIA_OUTBOUND:-0}\""; return 0; }
config_get() {
    case "$3" in
    dns_outbound_section) eval "$1=\"\$UCI_DNS_SECTION\"" ;;
    connection_type) eval "$1=\"\$(_stub_conn_type \"$2\")\"" ;;
    *) eval "$1=\"\"" ;;
    esac
    return 0
}
_stub_conn_type() {
    case "$1" in
    block-sec) echo "block" ;;
    excl-sec) echo "exclusion" ;;
    "") echo "" ;;
    *) echo "proxy" ;;
    esac
}
# section_has_configured_outbound: true unless name contains 'noout'.
section_has_configured_outbound() {
    case "$1" in
    *noout*|"") return 1 ;;
    esac
    return 0
}
get_first_outbound_section() { echo "$STUB_FIRST_SECTION"; }
get_outbound_tag_by_section() { echo "$1-out"; }
subscription_outbound_is_unavailable() {
    case " $STUB_UNAVAILABLE " in *" $1 "*) return 0 ;; esac
    return 1
}

# CASE off: feature disabled -> empty.
UCI_DNS_VIA_OUTBOUND=0; UCI_DNS_SECTION="main"; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ -z "$r" ] && echo 'cascade-off-empty:OK' || echo 'cascade-off-empty:FAIL'

# CASE explicit-valid: enabled + valid explicit section -> its tag.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION="vpn1"; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ "$r" = "vpn1-out" ] && echo 'cascade-explicit-valid:OK' || echo 'cascade-explicit-valid:FAIL'

# CASE invalid->first: explicit section has no configured outbound -> first.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION="noout-sec"; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ "$r" = "main-out" ] && echo 'cascade-invalid-to-first:OK' || echo 'cascade-invalid-to-first:FAIL'

# CASE empty-selector->first: no explicit section -> first.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION=""; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ "$r" = "main-out" ] && echo 'cascade-empty-to-first:OK' || echo 'cascade-empty-to-first:FAIL'

# CASE no-outbound->direct: enabled but no outbound section at all -> empty.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION=""; STUB_FIRST_SECTION=""; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ -z "$r" ] && echo 'cascade-no-outbound-direct:OK' || echo 'cascade-no-outbound-direct:FAIL'

# CASE block->direct: explicit block section -> empty.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION="block-sec"; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ -z "$r" ] && echo 'cascade-block-direct:OK' || echo 'cascade-block-direct:FAIL'

# CASE exclusion->direct: explicit exclusion section -> empty.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION="excl-sec"; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE=""
r=$(_get_dns_detour_tag)
[ -z "$r" ] && echo 'cascade-exclusion-direct:OK' || echo 'cascade-exclusion-direct:FAIL'

# CASE subscription-unavailable->direct: candidate present but outbound not built.
UCI_DNS_VIA_OUTBOUND=1; UCI_DNS_SECTION="sub1"; STUB_FIRST_SECTION="main"; STUB_UNAVAILABLE="sub1"
r=$(_get_dns_detour_tag)
[ -z "$r" ] && echo 'cascade-subscription-unavailable-direct:OK' || echo 'cascade-subscription-unavailable-direct:FAIL'

echo 'DONE'
DDEOF
    sed -i "s|FACADE_LIB_PATH|$facade_lib|; s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g; s|BIN_PATH|$bin|g" "$drv"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite.
    local dd_out="/tmp/netshift-dnsdetour-out-$$.log"
    ash "$drv" > "$dd_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$dd_out"
    if [ "$saw_done" = "1" ]; then
        pass "dnsdetour-driver-completed:OK"
    else
        fail "dnsdetour-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$dd_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: EDNS Client Subnet (issue #36)
# ─────────────────────────────────────────────────────────────────
# Exercises the REAL DNS-section generator (sing_box_configure_dns extracted
# verbatim from the CLI) with the REAL libraries, stubbing only UCI, and covers
# the upgrade path explicitly: `dns_client_subnet` is a NEW option, and an
# existing /etc/config/netshift is preserved as a conffile on upgrade, so the
# option is simply MISSING for every upgraded user. That case must produce a
# DNS section with no client_subnet field at all (byte-identical to the
# pre-#36 output) and must still pass `sing-box check`. The option being set
# must add .dns.client_subnet, and an invalid value must be skipped with a
# warning instead of poisoning the whole config (sing_box_config_check would
# otherwise exit 1 and the service would never start).
test_dns_client_subnet() {
    header "EDNS Client Subnet (issue #36)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local config_file="${NETSHIFT_SRC}/etc/config/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/helpers.sh" ]; then
        skip "ecssubnet — libs / bin not found"
        return
    fi

    # The shipped default must document the option AND default it to off, so a
    # fresh install cannot silently turn ECS on.
    if [ -r "$config_file" ] && grep -q "option dns_client_subnet ''" "$config_file"; then
        pass "shipped config ships dns_client_subnet empty (feature off by default)"
    else
        fail "shipped config is missing an empty 'option dns_client_subnet'"
    fi

    # Bind bind-mounted sources to the runtime path the libs hardcode.
    mkdir -p /usr/lib/netshift
    ln -sf "${lib}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "${lib}/helpers.jq" /usr/lib/netshift/helpers.jq
    ln -sf "${lib}/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh
    ln -sf "${lib}/constants.sh" /usr/lib/netshift/constants.sh

    local drv="/tmp/netshift-ecssubnet-$$.sh"
    cat > "$drv" << 'ECSEOF'
. "NETSHIFT_LIB/constants.sh"
. "NETSHIFT_LIB/helpers.sh"
. "NETSHIFT_LIB/sing_box_config_manager.sh"
. "NETSHIFT_LIB/sing_box_config_facade.sh"

if command -v sing-box > /dev/null 2>&1; then
    ECS_SB=1
else
    ECS_SB=0
fi

# Capture log output instead of writing to syslog: the feature must only ever
# WARN about a bad value, never abort.
LOG_LINES=""
log() {
    if [ -n "$LOG_LINES" ]; then
        LOG_LINES="$LOG_LINES
[$2] $1"
    else
        LOG_LINES="[$2] $1"
    fi
}

# REAL functions, extracted verbatim from the shipped CLI (same awk trick the
# other tests use): the DNS-section generator plus the helpers it calls.
eval "$(awk '/^sing_box_configure_dns\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^netshift_ipv6_enabled\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^_get_dns_detour_tag\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

# UCI stubs: option values live in UCI_<section>_<option>; an UNSET variable
# reproduces an option missing from /etc/config/netshift (the upgrade case).
# The fallback mirrors config_get's ${CONFIG_x:-default} semantics.
config_get() {
    local _var="$1" _sec="$2" _opt="$3" _def="${4-}"
    local _val
    eval "_val=\"\${UCI_${_sec}_${_opt}:-}\""
    [ -n "$_val" ] || _val="$_def"
    eval "$_var=\"\$_val\""
    return 0
}
config_get_bool() { config_get "$@"; }

reset_settings() {
    UCI_settings_dns_type="udp"
    UCI_settings_dns_server="1.1.1.1"
    UCI_settings_bootstrap_dns_server="77.88.8.8"
    UCI_settings_block_doh="0"
    UCI_settings_enable_ipv6="0"
    UCI_settings_dns_rewrite_ttl="60"
    UCI_settings_dns_via_outbound="0"
    unset UCI_settings_dns_client_subnet
}

build_dns_config() {
    config='{"log":{},"dns":{},"ntp":{},"certificate":{},"endpoints":[],"inbounds":[],"outbounds":[],"route":{},"services":[],"experimental":{}}'
    LOG_LINES=""
    # sing_box_configure_dns mutates the global `config` in place (no echo).
    sing_box_configure_dns
}

# Save with the PRODUCTION writer (it strips the internal __service_tag marker
# that sing-box refuses) and validate with the real binary.
config_passes_sing_box_check() {
    sing_box_cm_save_config_to_file "$config" /tmp/ecs-check.json
    sing-box -c /tmp/ecs-check.json check > /dev/null 2>&1
}

sb_check_token() {
    if [ "$ECS_SB" -eq 0 ]; then
        echo "$1:SKIP"
    elif config_passes_sing_box_check; then
        echo "$1:OK"
    else
        echo "$1:FAIL"
    fi
}

# ══ 1. UPGRADE SIMULATION: option ABSENT from UCI ═══════════════════════════
reset_settings
build_dns_config
if printf '%s' "$config" | jq -e '.dns | has("client_subnet") | not' > /dev/null 2>&1; then
    echo 'ecs-absent-no-field:OK'
else
    echo 'ecs-absent-no-field:FAIL'
fi
absent_servers=$(printf '%s' "$config" | jq -cS '.dns.servers')
sb_check_token 'ecs-absent-singbox-check'

# An explicitly empty value (what the shipped default config holds) must behave
# exactly like the absent option.
reset_settings
UCI_settings_dns_client_subnet=""
build_dns_config
if printf '%s' "$config" | jq -e '.dns | has("client_subnet") | not' > /dev/null 2>&1; then
    echo 'ecs-empty-no-field:OK'
else
    echo 'ecs-empty-no-field:FAIL'
fi

# ══ 2. Option SET: IPv4 prefix / bare address / IPv6 prefix ═════════════════
reset_settings
UCI_settings_dns_client_subnet="203.0.113.0/24"
build_dns_config
val=$(printf '%s' "$config" | jq -r '.dns.client_subnet // "MISSING"')
[ "$val" = "203.0.113.0/24" ] && echo 'ecs-set-ipv4-prefix:OK' || echo "ecs-set-ipv4-prefix:FAIL [$val]"
sb_check_token 'ecs-set-ipv4-singbox-check'

reset_settings
UCI_settings_dns_client_subnet="198.51.100.7"
build_dns_config
val=$(printf '%s' "$config" | jq -r '.dns.client_subnet // "MISSING"')
[ "$val" = "198.51.100.7" ] && echo 'ecs-set-bare-address:OK' || echo "ecs-set-bare-address:FAIL [$val]"

reset_settings
UCI_settings_dns_client_subnet="2001:db8::/32"
build_dns_config
val=$(printf '%s' "$config" | jq -r '.dns.client_subnet // "MISSING"')
[ "$val" = "2001:db8::/32" ] && echo 'ecs-set-ipv6-prefix:OK' || echo "ecs-set-ipv6-prefix:FAIL [$val]"
sb_check_token 'ecs-set-ipv6-singbox-check'

# The new field must not disturb the rest of the DNS section.
set_servers=$(printf '%s' "$config" | jq -cS '.dns.servers')
[ "$absent_servers" = "$set_servers" ] && echo 'ecs-servers-unchanged:OK' || echo 'ecs-servers-unchanged:FAIL'

# ══ 3. Invalid values: skipped + warned, config stays valid ═════════════════
bad_skipped=""
bad_unwarned=""
bad_invalid=""
for bad in 'garbage' '1.2.3.4/33' '1234' '1.2.3.4.' '999.1.1.1' '1.2.3.0/024' '1.2.3.4/' '1.2.3.4 '; do
    reset_settings
    UCI_settings_dns_client_subnet="$bad"
    build_dns_config
    printf '%s' "$config" | jq -e '.dns | has("client_subnet") | not' > /dev/null 2>&1 ||
        bad_skipped="$bad_skipped [$bad]"
    case "$LOG_LINES" in
    *warn*) ;;
    *) bad_unwarned="$bad_unwarned [$bad]" ;;
    esac
    if [ "$ECS_SB" -eq 1 ] && ! config_passes_sing_box_check; then
        bad_invalid="$bad_invalid [$bad]"
    fi
done
[ -z "$bad_skipped" ] && echo 'ecs-invalid-skipped:OK' || echo "ecs-invalid-skipped:FAIL$bad_skipped"
[ -z "$bad_unwarned" ] && echo 'ecs-invalid-warned:OK' || echo "ecs-invalid-warned:FAIL$bad_unwarned"
if [ "$ECS_SB" -eq 1 ]; then
    [ -z "$bad_invalid" ] && echo 'ecs-invalid-keeps-config-valid:OK' || echo "ecs-invalid-keeps-config-valid:FAIL$bad_invalid"
else
    echo 'ecs-invalid-keeps-config-valid:SKIP'
fi

# ══ 4. Manager primitive ════════════════════════════════════════════════════
prim=$(sing_box_cm_set_dns_client_subnet '{"dns":{"servers":[]}}' "203.0.113.0/24")
prim_val=$(printf '%s' "$prim" | jq -r '.dns.client_subnet // "MISSING"')
[ "$prim_val" = "203.0.113.0/24" ] && echo 'ecs-cm-set-field:OK' || echo "ecs-cm-set-field:FAIL [$prim_val]"

# ══ 5. Validator matrix, cross-checked against sing-box itself ══════════════
# sing-box parses the value with netip.ParsePrefix (falling back to
# netip.ParseAddr for a bare address); a value it rejects invalidates the WHOLE
# config, so the shell validator must agree with it exactly.
matrix_bad=""
sb_bad=""
while IFS='|' read -r expect value; do
    [ -n "$expect" ] || continue
    if is_ip_or_ip_prefix "$value"; then got="accept"; else got="reject"; fi
    [ "$got" = "$expect" ] || matrix_bad="$matrix_bad [$value:expected $expect got $got]"
    if [ "$ECS_SB" -eq 1 ]; then
        printf '{"dns":{"client_subnet":"%s"}}' "$value" > /tmp/ecs-matrix.json
        if sing-box -c /tmp/ecs-matrix.json check > /dev/null 2>&1; then sb="accept"; else sb="reject"; fi
        [ "$sb" = "$expect" ] || sb_bad="$sb_bad [$value:sing-box says $sb]"
    fi
done << 'MATRIX'
accept|203.0.113.0/24
accept|203.0.113.0
accept|0.0.0.0/0
accept|255.255.255.255/32
accept|198.51.100.7
accept|2001:db8::/32
accept|2001:db8::
accept|::/0
accept|::
accept|::1
accept|::ffff:198.51.100.0/120
accept|::ffff:198.51.100.7
accept|2001:db8:3:4::192.0.2.33
accept|2001:db8::1.2.3.4
accept|1:2:3:4:5:6:1.2.3.4
accept|1:2:3:4:5:6:7:8
accept|1::8
accept|fe80::1
reject|garbage
reject|1.2.3
reject|1.2.3.4/33
reject|1.2.3.4/024
reject|1234
reject|1.2.3.4.
reject|999.1.1.1
reject|01.2.3.4
reject|1.2.3.4:80
reject|1.2.3.4/
reject|1.2.3.4/24/32
reject|1.2.3.4/+24
reject|1.2.3.4/99999999999999999999
reject|1.2.3.4/1e1
reject|1::2::3
reject|1:2:3:4:5:6:7:8:9
reject|1:2:3:4:5:6:7::1.2.3.4
reject|2001:db8::/129
reject|2001:db8::g
reject|1.2.3.4%eth0
reject|203.0.113.0/ 24
MATRIX
[ -z "$matrix_bad" ] && echo 'ecs-validator-matrix:OK' || echo "ecs-validator-matrix:FAIL$matrix_bad"
if [ "$ECS_SB" -eq 1 ]; then
    [ -z "$sb_bad" ] && echo 'ecs-validator-matches-singbox:OK' || echo "ecs-validator-matches-singbox:FAIL$sb_bad"
else
    echo 'ecs-validator-matches-singbox:SKIP'
fi

echo 'DONE'
ECSEOF
    sed -i "s|NETSHIFT_LIB|$lib|g; s|BIN_PATH|$bin|g" "$drv"

    # Consume in the CURRENT shell (while read < file — NO pipe) so pass/fail/
    # skip mutate the real counters and gate the suite. FAIL/SKIP tokens may
    # carry a trailing " [diagnostic]" suffix, hence the trailing globs (a bare
    # "*:FAIL)" would silently drop them and the failure would not gate).
    local ecs_out="/tmp/netshift-ecssubnet-out-$$.log"
    ash "$drv" > "$ecs_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:FAIL*) fail "$line" ;;
            *:SKIP*) skip "$line" ;;
            *:OK) pass "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$ecs_out"
    if [ "$saw_done" = "1" ]; then
        pass "ecssubnet-driver-completed:OK"
    else
        fail "ecssubnet-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$ecs_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: scalar `option subscription_url` read-fallback + option->list migration
# (task-048)
# ─────────────────────────────────────────────────────────────────
# REAL-UCI regression guard for the hardware bug: a section storing
# subscription_url as a scalar UCI `option` (legacy / CLI / podkop-migrated
# configs) made get_subscription_urls_for_section return EMPTY (config_list_foreach
# iterates ONLY list values), so has_outbound_section failed and sing-box never
# started. This must use the SHIPPED functions against an actual config_load — NOT
# the stubbed config_list_foreach in test_subscription (which honors MU_URLS
# directly and therefore cannot catch the broken primitive). Synthetic URL only.
test_sub_url_option() {
    header "Scalar option subscription_url read-fallback + migration (task-048)"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ]; then
        skip "suburlopt — bin/netshift not found"
        return
    fi
    if [ ! -r /lib/functions.sh ] || [ ! -r /lib/config/uci.sh ] || ! command -v uci > /dev/null 2>&1; then
        skip "suburlopt — LuCI config_load / uci not available"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local drv="/tmp/netshift-suburlopt-$$.sh"
    cat > "$drv" << 'SUBOPTEOF'
BIN="BIN_PATH_PLACEHOLDER"
LIB="LIB_DIR_PLACEHOLDER"
. /lib/functions.sh
. /lib/config/uci.sh 2>/dev/null || true
# shellcheck disable=SC1090
. "$LIB/constants.sh"
# shellcheck disable=SC1090
. "$LIB/helpers.sh"
log() { :; }
echolog() { :; }
nolog() { :; }
# Exercise the SHIPPED functions verbatim (awk-extracted) against a real
# config_load — this is the whole point: the real LuCI config_list_foreach /
# config_get primitives, not a stub.
for fn in get_subscription_urls_for_section _collect_subscription_url_handler \
          section_has_configured_outbound \
          migrate_legacy_subscription_url_option \
          _migrate_legacy_subscription_url_option_handler; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done

mkdir -p /etc/config

# ── Fixture A: SCALAR option subscription_url (the exact broken shape) ──
cat > /etc/config/netshift_suboptscalar <<'CFGEOF'
config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'subscription'
    option subscription_url 'https://example.com/sub'
CFGEOF
config_load netshift_suboptscalar
urls="$(get_subscription_urls_for_section main)"
[ "$urls" = "https://example.com/sub" ] && echo 'suburlopt:scalar-read:OK' || echo "suburlopt:scalar-read:FAIL [$urls]"
if section_has_configured_outbound main; then
    echo 'suburlopt:scalar-hasoutbound:OK'
else
    echo 'suburlopt:scalar-hasoutbound:FAIL'
fi
rm -f /etc/config/netshift_suboptscalar

# ── Fixture B: LIST subscription_url (must still work — no regression) ──
cat > /etc/config/netshift_suboptlist <<'CFGEOF'
config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'subscription'
    list subscription_url 'https://example.com/sub'
CFGEOF
config_load netshift_suboptlist
urls="$(get_subscription_urls_for_section main)"
[ "$urls" = "https://example.com/sub" ] && echo 'suburlopt:list-read:OK' || echo "suburlopt:list-read:FAIL [$urls]"
rm -f /etc/config/netshift_suboptlist

# ── Migration: option -> list, idempotent. The migration function hardcodes
# the `netshift` config name, so write a throwaway /etc/config/netshift (the
# caller backs up + restores any real one). Two sections: a plain URL AND a URL
# with a query string containing `=`/`&`/`?` — the latter is the [B1] regression
# guard: the old `uci add_list "key=value"` CLI form splits on the first `=` and
# LOSES the value, while uci_add_list preserves it byte-for-byte. ──
NETSHIFT_CONFIG="netshift"
EQ_URL='https://example.com/sub?token=abc&x=1'
cat > /etc/config/netshift <<CFGEOF
config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'subscription'
    option subscription_url 'https://example.com/sub'

config section 'query'
    option connection_type 'proxy'
    option proxy_config_type 'subscription'
    option subscription_url '$EQ_URL'
CFGEOF
config_load netshift

# First run: must migrate both scalar options -> lists and flip the flag.
migrate_legacy_subscription_url_option
if [ "$SUBSCRIPTION_URL_OPTION_MIGRATED" = "1" ]; then
    echo 'suburlopt:migrate-flag:OK'
else
    echo "suburlopt:migrate-flag:FAIL [$SUBSCRIPTION_URL_OPTION_MIGRATED]"
fi
# The stored values must be preserved.
migrated_val="$(uci -q get netshift.main.subscription_url)"
[ "$migrated_val" = "https://example.com/sub" ] && echo 'suburlopt:migrate-value:OK' || echo "suburlopt:migrate-value:FAIL [$migrated_val]"
# [B1] regression guard: the `=`/`&` URL survives byte-for-byte.
migrated_eq="$(uci -q get netshift.query.subscription_url)"
[ "$migrated_eq" = "$EQ_URL" ] && echo 'suburlopt:migrate-equrl-preserved:OK' || echo "suburlopt:migrate-equrl-preserved:FAIL [$migrated_eq]"

# After a fresh config_load the LIST path (config_list_foreach) returns each URL,
# and the committed state must be a CLEAN single-element list (no leftover scalar
# option and no duplicate element).
config_load netshift
SUBSCRIPTION_URLS_COLLECTED=""
config_list_foreach main subscription_url _collect_subscription_url_handler
[ "$SUBSCRIPTION_URLS_COLLECTED" = "https://example.com/sub" ] && echo 'suburlopt:migrate-islist:OK' || echo "suburlopt:migrate-islist:FAIL [$SUBSCRIPTION_URLS_COLLECTED]"
SUBSCRIPTION_URLS_COLLECTED=""
config_list_foreach query subscription_url _collect_subscription_url_handler
[ "$SUBSCRIPTION_URLS_COLLECTED" = "$EQ_URL" ] && echo 'suburlopt:migrate-equrl-islist:OK' || echo "suburlopt:migrate-equrl-islist:FAIL [$SUBSCRIPTION_URLS_COLLECTED]"
# Clean single element: `uci show` must render exactly one list value per section
# (no leftover scalar option, no duplicate). uci renders a list element with the
# index-bearing `[0]` syntax; assert exactly one line each.
eq_lines="$(uci -q show netshift.query.subscription_url | grep -c "subscription_url")"
[ "$eq_lines" = "1" ] && echo 'suburlopt:migrate-equrl-single:OK' || echo "suburlopt:migrate-equrl-single:FAIL [$eq_lines]"

# Second run: idempotent no-op (already a list -> flag stays 0, no churn).
migrate_legacy_subscription_url_option
if [ "$SUBSCRIPTION_URL_OPTION_MIGRATED" = "0" ]; then
    echo 'suburlopt:migrate-idempotent:OK'
else
    echo "suburlopt:migrate-idempotent:FAIL [$SUBSCRIPTION_URL_OPTION_MIGRATED]"
fi
idem_val="$(uci -q get netshift.main.subscription_url)"
[ "$idem_val" = "https://example.com/sub" ] && echo 'suburlopt:migrate-idempotent-value:OK' || echo "suburlopt:migrate-idempotent-value:FAIL [$idem_val]"
idem_eq="$(uci -q get netshift.query.subscription_url)"
[ "$idem_eq" = "$EQ_URL" ] && echo 'suburlopt:migrate-idempotent-equrl:OK' || echo "suburlopt:migrate-idempotent-equrl:FAIL [$idem_eq]"

rm -f /etc/config/netshift
echo 'DONE'
SUBOPTEOF
    sed -i "s|LIB_DIR_PLACEHOLDER|$lib|g; s|BIN_PATH_PLACEHOLDER|$bin|g" "$drv"

    # Protect any real /etc/config/netshift the container may carry: the
    # migration path writes a throwaway one under that exact name.
    local netshift_cfg_backup=""
    if [ -f /etc/config/netshift ]; then
        netshift_cfg_backup="/tmp/netshift-cfg-backup-$$"
        cp /etc/config/netshift "$netshift_cfg_backup"
    fi

    # Parse in the CURRENT shell (temp file + `while read < "$out"`, NO pipe) so
    # pass/fail update the global counters and a suburlopt:*:FAIL actually gates
    # the suite (a pipe would run the while-body in a subshell — non-gating).
    local sub_out="/tmp/netshift-suburlopt-out-$$"
    sh "$drv" > "$sub_out" 2>/dev/null
    # FAIL/SKIP tokens carry a trailing " [diagnostic]" suffix, so match with a
    # trailing glob (*:FAIL*) — a bare "*:FAIL)" would miss them and silently
    # drop the failure, defeating S1's gating.
    while IFS= read -r line; do
        case "$line" in
            *:FAIL*) fail "$line" ;;
            *:SKIP*) skip "$line" ;;
            *:OK) pass "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done < "$sub_out"
    rm -f "$drv" "$sub_out"

    if [ -n "$netshift_cfg_backup" ]; then
        mv "$netshift_cfg_backup" /etc/config/netshift
    else
        rm -f /etc/config/netshift
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: per-section subscription auto-update interval (issue #51)
#
# The cron job used to be built from whichever subscription section came last in
# UCI order and then drove EVERY section on that one interval. One job per
# distinct interval is created now, each updating only the sections carrying it,
# so a section's own option decides its schedule wherever it sits in the config.
# ─────────────────────────────────────────────────────────────────
test_sub_cron() {
    header "Per-section subscription update interval (issue #51)"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ]; then
        skip "subcron — bin/netshift not found"
        return
    fi
    if [ ! -r /lib/functions.sh ]; then
        skip "subcron — LuCI config_load not available"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local drv="/tmp/netshift-subcron-$$.sh"
    cat > "$drv" << 'SUBCRONEOF'
BIN="BIN_PATH_PLACEHOLDER"
LIB="LIB_DIR_PLACEHOLDER"
. /lib/functions.sh
# shellcheck disable=SC1090
. "$LIB/constants.sh"

extract() {
    awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN"
}

WORK="/tmp/netshift-subcron-work-$$"
rm -rf "$WORK"
mkdir -p "$WORK"
CRONTAB_FILE="$WORK/crontab"
: > "$CRONTAB_FILE"

# The log is a file: the shipped code is expected to SAY that it fell back to
# the default interval, so a silent fallback has to be visible here.
LOG_FILE="$WORK/log"
: > "$LOG_FILE"
log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
nolog() { :; }
echolog() { log "$1" "${2:-info}"; }

# A crontab that is a file, so the shipped code is exercised verbatim without
# touching the container's real one. The write goes through a temp file + mv,
# exactly like busybox crontab: a plain `cat > $file` would truncate the file
# while the `crontab -l` of the same pipeline is still reading it, and the
# appended jobs would silently vanish.
crontab() {
    case "$1" in
    -l)
        [ -f "$CRONTAB_FILE" ] && cat "$CRONTAB_FILE"
        return 0
        ;;
    -)
        cat > "$CRONTAB_FILE.new" || return 1
        mv "$CRONTAB_FILE.new" "$CRONTAB_FILE"
        ;;
    esac
}

for fn in get_subscription_cron_line_for_interval \
          _collect_subscription_update_interval \
          sync_subscription_cron_jobs \
          remove_cron_job \
          foreach_active_section _active_section_dispatch section_is_disabled \
          subscription_update; do
    eval "$(extract "$fn")"
done

has_line() { grep -qxF "$1" "$CRONTAB_FILE"; }
job_count() { grep -c "/usr/bin/netshift subscription_update" "$CRONTAB_FILE"; }
# $1 = fixture, $2 = "keep" to keep the crontab as it is (upgrade simulation).
sync() {
    cp "$1" /etc/config/nsfixture
    config_load nsfixture
    [ "$2" = "keep" ] || : > "$CRONTAB_FILE"
    sync_subscription_cron_jobs
    rm -f /etc/config/nsfixture
}

# ── Every interval has its own schedule, and only the known ones ──
for spec in "30m|*/30 * * * *" "1h|17 * * * *" "3h|7 */3 * * *" "6h|24 */6 * * *" "12h|40 */12 * * *" "1d|52 9 * * *"; do
    iv="${spec%%|*}"
    want="${spec#*|}"
    got="$(get_subscription_cron_line_for_interval "$iv")"
    if [ "$got" = "$want /usr/bin/netshift subscription_update $iv" ]; then
        echo "subcron:schedule-$iv:OK"
    else
        echo "subcron:schedule-$iv:FAIL [got '$got']"
    fi
done
# The fallback for an unknown value is the default interval, so a value the
# mapper does not know must not silently map to a job.
if get_subscription_cron_line_for_interval 2h > /dev/null 2>&1; then
    echo 'subcron:schedule-unknown-rejected:FAIL [2h accepted]'
else
    echo 'subcron:schedule-unknown-rejected:OK'
fi
if get_subscription_cron_line_for_interval '' > /dev/null 2>&1; then
    echo 'subcron:schedule-empty-rejected:FAIL [empty accepted]'
else
    echo 'subcron:schedule-empty-rejected:OK'
fi

# ── The jobs never share a minute ─────────────────────────────────
# Two jobs firing in the same minute would run two subscription_update processes
# side by side, and those race on the pending-apply marker and on the sing-box
# rebuild + reload. `*/30` fires at :00 and :30, so the fixed minutes must avoid
# both of them as well.
fired=""
collision=""
for iv in 30m 1h 3h 6h 12h 1d; do
    minute="$(get_subscription_cron_line_for_interval "$iv" | cut -d' ' -f1)"
    if [ "$minute" = "*/30" ]; then
        minutes="0 30"
    else
        minutes="$minute"
    fi
    for m in $minutes; do
        case " $fired " in
        *" $m "*) collision="$collision $iv@$m" ;;
        esac
        fired="$fired $m"
    done
done
if [ -z "$collision" ]; then
    echo 'subcron:distinct-minutes:OK'
else
    echo "subcron:distinct-minutes:FAIL [collision:$collision]"
fi

# ── Fixtures ───────────────────────────────────────────────────
cat > "$WORK/fast_slow" <<'CFGEOF'
config section 'fast'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/fast'
        option subscription_update_interval '30m'

config section 'slow'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/slow'
        option subscription_update_interval '1d'
CFGEOF
cat > "$WORK/slow_fast" <<'CFGEOF'
config section 'slow'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/slow'
        option subscription_update_interval '1d'

config section 'fast'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/fast'
        option subscription_update_interval '30m'
CFGEOF
# Upgrade simulation: a config written before subscription_update_interval
# existed — the option is simply absent (the package keeps the old conffile).
cat > "$WORK/no_interval" <<'CFGEOF'
config section 'one'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/one'

config section 'two'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/two'
CFGEOF
# Two sections sharing one interval must share ONE job.
cat > "$WORK/same_interval" <<'CFGEOF'
config section 'a'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/a'
        option subscription_update_interval '1h'

config section 'b'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/b'
        option subscription_update_interval '1h'
CFGEOF
cat > "$WORK/no_subscription" <<'CFGEOF'
config section 'plain'
        option connection_type 'proxy'
        option proxy_config_type 'url'
        option proxy_string 'vless://node'
CFGEOF
# A hand-edited interval the UI never offers. Such a section used to be dropped
# from every job and stopped being refreshed; it must run on the default instead.
cat > "$WORK/invalid_only" <<'CFGEOF'
config section 'hand'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/hand'
        option subscription_update_interval '2h'
CFGEOF
# ... and it shares the default job with the sections that really ask for it,
# without disturbing a section on another interval.
cat > "$WORK/invalid_and_known" <<'CFGEOF'
config section 'hourly'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/hourly'
        option subscription_update_interval '1h'

config section 'hand'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/hand'
        option subscription_update_interval '2h'

config section 'fast'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/fast'
        option subscription_update_interval '30m'
CFGEOF

# ── Two sections, two intervals, independent of the UCI order ───
sync "$WORK/fast_slow"
if has_line "*/30 * * * * /usr/bin/netshift subscription_update 30m"; then
    echo 'subcron:fast-keeps-30m:OK'
else
    echo "subcron:fast-keeps-30m:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
if has_line "52 9 * * * /usr/bin/netshift subscription_update 1d"; then
    echo 'subcron:slow-keeps-1d:OK'
else
    echo "subcron:slow-keeps-1d:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
if [ "$(job_count)" = "2" ]; then
    echo 'subcron:one-job-per-interval:OK'
else
    echo "subcron:one-job-per-interval:FAIL [$(job_count)]"
fi
first_crontab="$(cat "$CRONTAB_FILE")"

sync "$WORK/slow_fast"
if [ "$(cat "$CRONTAB_FILE")" = "$first_crontab" ]; then
    echo 'subcron:order-independent:OK'
else
    echo "subcron:order-independent:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
# No job may be left without an interval: a bare one updates every section on
# one interval, which is the bug being fixed.
if has_line "17 * * * * /usr/bin/netshift subscription_update"; then
    echo 'subcron:no-interval-less-job:FAIL [bare job present]'
else
    echo 'subcron:no-interval-less-job:OK'
fi

# ── Upgrade: the legacy interval-less job is replaced, list_update survives ──
cat > "$CRONTAB_FILE" <<'CRONEOF'
13 9 * * * /usr/bin/netshift list_update
17 9 * * * /usr/bin/netshift subscription_update
CRONEOF
sync "$WORK/fast_slow" keep
if grep -qxF "17 9 * * * /usr/bin/netshift subscription_update" "$CRONTAB_FILE"; then
    echo 'subcron:legacy-job-dropped:FAIL [bare job still there]'
else
    echo 'subcron:legacy-job-dropped:OK'
fi
if has_line "13 9 * * * /usr/bin/netshift list_update"; then
    echo 'subcron:list-update-job-kept:OK'
else
    echo 'subcron:list-update-job-kept:FAIL'
fi
if [ "$(job_count)" = "2" ]; then
    echo 'subcron:legacy-replaced-by-intervals:OK'
else
    echo "subcron:legacy-replaced-by-intervals:FAIL [$(job_count)]"
fi

# ── Upgrade simulation: the option is absent (old conffile) ─────
sync "$WORK/no_interval"
if has_line "17 * * * * /usr/bin/netshift subscription_update 1h"; then
    echo 'subcron:missing-option-uses-default:OK'
else
    echo "subcron:missing-option-uses-default:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
if [ "$(job_count)" = "1" ]; then
    echo 'subcron:missing-option-single-job:OK'
else
    echo "subcron:missing-option-single-job:FAIL [$(job_count)]"
fi

# ── Two sections sharing an interval share one job ──────────────
sync "$WORK/same_interval"
if [ "$(job_count)" = "1" ] && has_line "17 * * * * /usr/bin/netshift subscription_update 1h"; then
    echo 'subcron:shared-interval-deduped:OK'
else
    echo "subcron:shared-interval-deduped:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi

# ── Re-running adds nothing (the jobs are rebuilt, not appended) ──
sync "$WORK/same_interval"
sync "$WORK/same_interval" keep
sync "$WORK/same_interval" keep
if [ "$(job_count)" = "1" ]; then
    echo 'subcron:idempotent:OK'
else
    echo "subcron:idempotent:FAIL [$(job_count)]"
fi

# ── A section without a usable interval must never lose its job ──
# Regression (issue #51): an unknown value used to be logged and skipped, so the
# section was left out of EVERY job and stopped being refreshed. It runs on the
# default interval now, i.e. the section lands in the 1h job.
: > "$LOG_FILE"
sync "$WORK/invalid_only"
if has_line "17 * * * * /usr/bin/netshift subscription_update 1h"; then
    echo 'subcron:unknown-interval-falls-back-to-default:OK'
else
    echo "subcron:unknown-interval-falls-back-to-default:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
if [ "$(job_count)" = "1" ]; then
    echo 'subcron:unknown-interval-one-job:OK'
else
    echo "subcron:unknown-interval-one-job:FAIL [$(job_count)]"
fi
if grep -q "2h" "$CRONTAB_FILE"; then
    echo "subcron:unknown-interval-not-scheduled:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
else
    echo 'subcron:unknown-interval-not-scheduled:OK'
fi
# The fallback is only acceptable if it is visible: a warning naming the section
# and the value it is replacing.
if grep -q "^\[warn\] Unknown subscription_update_interval '2h' in section 'hand'" "$LOG_FILE"; then
    echo 'subcron:unknown-interval-warned:OK'
else
    echo "subcron:unknown-interval-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi
# ... and the known intervals are not warned about at all.
: > "$LOG_FILE"
sync "$WORK/fast_slow"
if grep -q "Unknown subscription_update_interval" "$LOG_FILE"; then
    echo "subcron:known-interval-not-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
else
    echo 'subcron:known-interval-not-warned:OK'
fi

# A section asking for the default and one carrying an unknown value share that
# one job, and the section on another interval keeps its own: the unknown value
# must neither add a schedule of its own nor swallow the other one.
sync "$WORK/invalid_and_known"
if [ "$(job_count)" = "2" ] && has_line "17 * * * * /usr/bin/netshift subscription_update 1h" &&
    has_line "*/30 * * * * /usr/bin/netshift subscription_update 30m"; then
    echo 'subcron:unknown-interval-shares-default-job:OK'
else
    echo "subcron:unknown-interval-shares-default-job:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi

# ── Non-subscription sections get no job at all ─────────────────
sync "$WORK/no_subscription"
if [ "$(job_count)" = "0" ]; then
    echo 'subcron:no-subscription-no-job:OK'
else
    echo "subcron:no-subscription-no-job:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi

# ── remove_cron_job clears the legacy bare job and the interval jobs ──
# stop_main calls it, and the interval jobs are matched by the same
# `/usr/bin/netshift subscription_update` substring as the old interval-less one.
cat > "$CRONTAB_FILE" <<'CRONEOF'
13 9 * * * /usr/bin/netshift list_update
17 9 * * * /usr/bin/netshift subscription_update
17 * * * * /usr/bin/netshift subscription_update 1h
52 9 * * * /usr/bin/netshift subscription_update 1d
4 4 * * * /usr/bin/netshift check_proxy
CRONEOF
remove_cron_job
if [ "$(job_count)" = "0" ] &&
    ! grep -q "/usr/bin/netshift list_update" "$CRONTAB_FILE" &&
    has_line "4 4 * * * /usr/bin/netshift check_proxy"; then
    echo 'subcron:remove-cron-job-clears-all:OK'
else
    echo "subcron:remove-cron-job-clears-all:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi

# ── start_main (re)builds the jobs ───────────────────────────────
# The wiring, not the builder: start_main must call sync_subscription_cron_jobs.
# The hot-reload test only counts the calls to a stub, so here the REAL builder
# runs against a loaded config and the resulting crontab is checked.
eval "$(extract start_main | sed \
    -e 's|/usr/sbin/ntpd|: ntpd|' \
    -e 's|/etc/init.d/sing-box start|subcron_sing_box_start|' \
    -e 's|^    sleep 1$|    :|' \
    -e 's|/var/run/netshift_list_update.pid|$WORK/list_update.pid|')"
subcron_sing_box_start() { :; }
migrate_legacy_subscription_url_option() { :; }
check_requirements() { :; }
migration() { :; }
process_validate_service() { :; }
br_netfilter_disable() { :; }
ensure_subscription_cache_dir() { :; }
migrate_subscription_cache_from_tmp() { :; }
prepare_subscription_caches_for_startup() { subscription_startup_blocked=0; }
stop_subscription_startup_retry_worker() { :; }
route_table_rule_mark() { :; }
create_nft_rules() { :; }
sing_box_configure_service() { :; }
sing_box_init_config() { :; }
add_cron_job() { :; }
list_update() { :; }
TMP_SING_BOX_FOLDER="$WORK/sing-box"
TMP_RULESET_FOLDER="$WORK/rulesets"
TMP_SUBSCRIPTION_FOLDER="$WORK/sub-tmp"

cp "$WORK/fast_slow" /etc/config/nsfixture
config_load nsfixture
: > "$CRONTAB_FILE"
rm -f "$WORK/list_update.pid"
mkdir -p "$(dirname "$SUBSCRIPTION_PENDING_APPLY_FLAG")"
: > "$SUBSCRIPTION_PENDING_APPLY_FLAG"
( start_main ) > /dev/null 2>&1
rc=$?
rm -f /etc/config/nsfixture
if [ "$rc" -eq 0 ] && [ "$(job_count)" = "2" ] &&
    has_line "52 9 * * * /usr/bin/netshift subscription_update 1d" &&
    has_line "*/30 * * * * /usr/bin/netshift subscription_update 30m"; then
    echo 'subcron:start-main-builds-jobs:OK'
else
    echo "subcron:start-main-builds-jobs(rc=$rc jobs=$(job_count) crontab=$(tr '\n' ';' < "$CRONTAB_FILE")):FAIL"
fi
# ... and the call sits where the built config has already been accepted: the
# marker is dropped and the pidfile of the backgrounded list_update is written,
# so the run above really went through the whole function.
if [ ! -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ] && [ -f "$WORK/list_update.pid" ]; then
    echo 'subcron:start-main-ran-through:OK'
else
    echo 'subcron:start-main-ran-through:FAIL [marker or pidfile missing]'
fi

# ── subscription_update <interval> touches only that interval ───
# The real function is exercised with the download/apply helpers stubbed, and
# config_get/config_foreach fed three subscription sections: two with a known
# interval and one carrying an unknown value.
eval "$(extract subscription_update)"

TMP_SUBSCRIPTION_FOLDER="$WORK/sub-tmp"
TMP_SING_BOX_FOLDER="$WORK/sing-box"
SUBSCRIPTION_PENDING_APPLY_FLAG="$TMP_SING_BOX_FOLDER/subscription-pending-apply"
SUBSCRIPTION_CACHE_FOLDER="$WORK/sub-cache"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"

config_foreach() { "$1" "fast"; "$1" "slow"; "$1" "odd"; }
config_get() {
    case "$2:$3" in
    fast:connection_type | slow:connection_type | odd:connection_type) eval "$1=proxy" ;;
    fast:proxy_config_type | slow:proxy_config_type | odd:proxy_config_type) eval "$1=subscription" ;;
    fast:subscription_update_interval) eval "$1=30m" ;;
    slow:subscription_update_interval) eval "$1=1d" ;;
    odd:subscription_update_interval) eval "$1=2h" ;;
    *) eval "$1=\"\${4:-}\"" ;;
    esac
}
ensure_subscription_cache_dir() { :; }
reap_legacy_subscription_cache_files() { :; }
get_subscription_urls_for_section() { printf '%s\n' "https://feed.example.com/$1"; }
get_subscription_url_hash() { printf 'feedhash'; }
get_subscription_json_path() { printf '%s' "$SUBSCRIPTION_CACHE_FOLDER/$1.$2.json"; }
get_subscription_url_cache_path() { printf '%s' "$SUBSCRIPTION_CACHE_FOLDER/$1.$2.url"; }
get_subscription_download_proxy_address() { :; }
wait_for_subscription_connectivity() { return 0; }
redact_url_for_log() { printf '%s' "$1"; }
subscription_cache_is_usable() { return 0; }
download_subscription_into_cache() {
    printf '%s' '{"outbounds":[{"type":"vless","tag":"node-1"}]}' > "$3"
    printf '%s\n' "$1" >> "$WORK/updated.log"
    return 0
}
reload_sing_box_config_in_place() { return 0; }

updated_sections() {
    : > "$WORK/updated.log"
    rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
    subscription_update "$1" > /dev/null 2>&1
    printf '%s' "$(sort -u "$WORK/updated.log" | tr '\n' ' ')"
}

got="$(updated_sections 30m)"
if [ "$got" = "fast " ]; then
    echo 'subcron:filter-30m-only-fast:OK'
else
    echo "subcron:filter-30m-only-fast:FAIL [$got]"
fi
got="$(updated_sections 1d)"
if [ "$got" = "slow " ]; then
    echo 'subcron:filter-1d-only-slow:OK'
else
    echo "subcron:filter-1d-only-slow:FAIL [$got]"
fi
# The 1h job is the one the unknown value fell back to, so it has to pick that
# section up — a job that is created but never matches its section would leave
# the section un-updated just like being dropped from every job did.
got="$(updated_sections 1h)"
if [ "$got" = "odd " ]; then
    echo 'subcron:filter-1h-picks-unknown-value:OK'
else
    echo "subcron:filter-1h-picks-unknown-value:FAIL [$got]"
fi
got="$(updated_sections '')"
if [ "$got" = "fast odd slow " ]; then
    echo 'subcron:no-filter-updates-all:OK'
else
    echo "subcron:no-filter-updates-all:FAIL [$got]"
fi
got="$(updated_sections 6h)"
if [ "$got" = "" ]; then
    echo 'subcron:filter-unused-interval-noop:OK'
else
    echo "subcron:filter-unused-interval-noop:FAIL [$got]"
fi
# A filter that matches nothing must still succeed: the cron job of an interval
# whose last section was removed has to exit cleanly, not report a failure.
subscription_update 6h > /dev/null 2>&1
if [ "$?" -eq 0 ]; then
    echo 'subcron:filter-unused-interval-rc:OK'
else
    echo 'subcron:filter-unused-interval-rc:FAIL'
fi
# An interval this version does not schedule is not a filter that matches
# nothing: the call used to update no section at all and still exit 0. It
# refreshes every section instead, which the log says out loud.
: > "$LOG_FILE"
got="$(updated_sections 2h)"
if [ "$got" = "fast odd slow " ]; then
    echo 'subcron:unknown-arg-updates-all:OK'
else
    echo "subcron:unknown-arg-updates-all:FAIL [$got]"
fi
if grep -q "^\[warn\] ⚠️ Unknown subscription update interval '2h'" "$LOG_FILE"; then
    echo 'subcron:unknown-arg-warned:OK'
else
    echo "subcron:unknown-arg-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi
subscription_update 2h > /dev/null 2>&1
if [ "$?" -eq 0 ]; then
    echo 'subcron:unknown-arg-rc:OK'
else
    echo 'subcron:unknown-arg-rc:FAIL'
fi
# ... and the same for a value with a typo in the unit.
got="$(updated_sections 2H)"
if [ "$got" = "fast odd slow " ]; then
    echo 'subcron:unknown-arg-case-updates-all:OK'
else
    echo "subcron:unknown-arg-case-updates-all:FAIL [$got]"
fi

rm -rf "$WORK"
echo 'DONE'
SUBCRONEOF
    sed -i "s|LIB_DIR_PLACEHOLDER|$lib|g; s|BIN_PATH_PLACEHOLDER|$bin|g" "$drv"

    local sub_out="/tmp/netshift-subcron-out-$$"
    sh "$drv" > "$sub_out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
        *:FAIL*) fail "$line" ;;
        *:SKIP*) skip "$line" ;;
        *:OK) pass "$line" ;;
        DONE) saw_done=1 ;;
        *) ;;
        esac
    done < "$sub_out"
    # The driver echoes DONE last. Without this guard a driver that died in the
    # middle (a syntax error in an extracted function, for instance) would report
    # "passed" with nothing checked.
    if [ "$saw_done" = "1" ]; then
        pass "subcron-driver-completed"
    else
        fail "subcron-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$sub_out" 2>/dev/null)"
    fi
    rm -f "$drv" "$sub_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: global_proxy route rule semantics
# ─────────────────────────────────────────────────────────────────
test_global_proxy() {
    header "Global Proxy Route Semantics"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local cm_lib="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    local constants_lib="${NETSHIFT_LIB_DIR}/constants.sh"
    local jq_helpers="${NETSHIFT_LIB_DIR}/helpers.jq"
    if [ ! -r "$cm_lib" ] || [ ! -r "$constants_lib" ] || [ ! -r "$jq_helpers" ]; then
        skip "config manager / constants / helpers.jq not found"
        return
    fi

    # sing_box_cm_patch_route_rule imports helpers.jq from the runtime path.
    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq

    local cfg tmp
    tmp="/tmp/netshift-global-proxy-$$.json"

    . "$constants_lib"
    . "$cm_lib"

    local global_out ruleset_tag ipv6_excluded_rule_tag
    global_out="global-out"
    ruleset_tag="global-user-domains"
    ipv6_excluded_rule_tag="global-ipv6-excluded"

    cfg=$(jq -n \
        --arg direct "$SB_DIRECT_OUTBOUND_TAG" \
        --arg global "$global_out" \
        --arg tproxy "$SB_TPROXY_INBOUND_TAG" \
        --arg listen "$SB_TPROXY_INBOUND_ADDRESS" \
        --argjson port "$SB_TPROXY_INBOUND_PORT" \
        --arg ruleset "$ruleset_tag" \
        '{
        log: { disabled: false, level: "warn", timestamp: true },
        dns: { servers: [], rules: [], final: $direct, strategy: "prefer_ipv4", independent_cache: true },
        ntp: {},
        inbounds: [
            { type: "tproxy", tag: $tproxy, listen: $listen, listen_port: $port }
        ],
        outbounds: [
            { type: "direct", tag: $direct },
            { type: "direct", tag: $global }
        ],
        route: {
            rules: [],
            rule_set: [{ type: "inline", tag: $ruleset, rules: [{ domain_suffix: ["example.com"] }] }],
            final: $global,
            auto_detect_interface: true
        }
    }')

    cfg=$(sing_box_cm_add_route_rule "$cfg" "$SB_EXCLUSION_RULE_TAG" "$SB_TPROXY_INBOUND_TAG" "$SB_DIRECT_OUTBOUND_TAG")
    cfg=$(sing_box_cm_patch_route_rule "$cfg" "$SB_EXCLUSION_RULE_TAG" "rule_set" "$ruleset_tag")
    cfg=$(sing_box_cm_add_route_rule "$cfg" "$ipv6_excluded_rule_tag" "$SB_TPROXY_INBOUND_TAG" "$SB_DIRECT_OUTBOUND_TAG")
    cfg=$(sing_box_cm_patch_route_rule "$cfg" "$ipv6_excluded_rule_tag" "source_ip_cidr" "fd00:ec3a::123/128")

    if echo "$cfg" | jq -e --arg global "$global_out" '.route.final == $global' > /dev/null 2>&1; then
        pass "global_proxy route.final points to global-out"
    else
        fail "global_proxy route.final is not global-out" "$(echo "$cfg" | jq -r '.route.final // "missing"' 2>/dev/null)"
    fi

    if echo "$cfg" | jq -e --arg tag "$SB_EXCLUSION_RULE_TAG" \
            '[.route.rules[] | select(.__service_tag == $tag and (has("rule_set") | not))] | length == 0' \
            > /dev/null 2>&1; then
        pass "global_proxy exclusion route rule is constrained by rule_set"
    else
        fail "global_proxy exclusion route rule lacks rule_set" "$(echo "$cfg" | jq -c '.route.rules' 2>/dev/null)"
    fi

    if echo "$cfg" | jq -e --arg tag "$SB_EXCLUSION_RULE_TAG" --arg direct "$SB_DIRECT_OUTBOUND_TAG" --arg ruleset "$ruleset_tag" \
            '[.route.rules[] | select(.__service_tag == $tag and .outbound == $direct and .rule_set == $ruleset)] | length == 1' \
            > /dev/null 2>&1; then
        pass "global_proxy exclusion rule routes global-user-domains direct-out"
    else
        fail "global_proxy exclusion direct rule shape wrong" "$(echo "$cfg" | jq -c '.route.rules' 2>/dev/null)"
    fi

    if echo "$cfg" | jq -e --arg tag "$ipv6_excluded_rule_tag" --arg direct "$SB_DIRECT_OUTBOUND_TAG" \
            '[.route.rules[] | select(.__service_tag == $tag and .outbound == $direct and .source_ip_cidr == "fd00:ec3a::123/128")] | length == 1' \
            > /dev/null 2>&1; then
        pass "global_proxy routing_excluded_ips supports IPv6 source_ip_cidr"
    else
        fail "global_proxy IPv6 source_ip_cidr rule shape wrong" "$(echo "$cfg" | jq -c '.route.rules' 2>/dev/null)"
    fi

    if command -v sing-box > /dev/null 2>&1; then
        sing_box_cm_save_config_to_file "$cfg" "$tmp"
        if sing-box -c "$tmp" check > /dev/null 2>&1; then
            pass "sing-box validates global_proxy route config"
        else
            fail "sing-box rejects global_proxy route config" "$(sing-box -c "$tmp" check 2>&1)"
        fi
        rm -f "$tmp"
    else
        skip "sing-box not installed — skipping global_proxy config check"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Test: `disabled` option for sections (issue #42)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL section_is_disabled / foreach_active_section /
# section_has_configured_outbound / section_has_enabled_lists (extracted
# verbatim from the bin) against a stubbed UCI layer. Asserts:
#   - a section with `disabled '1'` is skipped by foreach_active_section and
#     is reported as having no outbound and no enabled lists;
#   - `disabled '0'` and a MISSING option (every pre-existing config) keep the
#     section fully active (upgrade safety);
#   - the callback bookkeeping is restored after the walk (nesting-safe).
test_section_disabled() {
    header "Section disabled option (issue #42)"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ]; then
        skip "netshift bin not found"
        return
    fi

    local out
    out="$(
        # shellcheck disable=SC2030
        extract() {
            awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin"
        }
        eval "$(extract section_is_disabled)"
        eval "$(extract _active_section_dispatch)"
        eval "$(extract foreach_active_section)"
        eval "$(extract section_has_configured_outbound)"
        eval "$(extract section_has_enabled_lists)"
        eval "$(extract _check_outbound_section)"
        eval "$(extract has_outbound_section)"
        eval "$(extract _determine_first_outbound_section)"
        eval "$(extract get_first_outbound_section)"
        eval "$(extract _determine_global_proxy_section)"
        eval "$(extract get_global_proxy_section)"
        _active_section_callback=

        SD_SECTIONS="alpha beta gamma delta"
        sd_key() { printf 'SD_%s_%s' "$1" "$2"; }
        config_get() {
            local _v
            eval "_v=\"\${$(sd_key "$2" "$3"):-}\""
            [ -n "$_v" ] || _v="$4"
            eval "$1=\"\$_v\""
        }
        config_get_bool() {
            local _v
            eval "_v=\"\${$(sd_key "$2" "$3"):-}\""
            [ -n "$_v" ] || _v="$4"
            case "$_v" in 1 | on | true | yes | enabled) _v=1 ;; *) _v=0 ;; esac
            eval "$1=\"\$_v\""
        }
        config_foreach() {
            local _cb="$1" _t="$2" _s
            shift 2
            for _s in $SD_SECTIONS; do "$_cb" "$_s" "$@"; done
        }

        # alpha: active (no `disabled` option at all = every existing config)
        # beta:  disabled '1'    gamma: disabled '0'    delta: disabled '1'
        for s in alpha beta gamma delta; do
            eval "SD_${s}_connection_type=proxy"
            eval "SD_${s}_proxy_config_type=url"
            eval "SD_${s}_proxy_string=vless://x@example.com:443"
            eval "SD_${s}_community_lists=russia_inside"
        done
        SD_beta_disabled=1
        SD_gamma_disabled=0
        SD_delta_disabled=1

        visited=""
        sd_visit() { visited="$visited $1"; }
        foreach_active_section sd_visit "section"
        echo "walk:${visited# }"

        section_is_disabled alpha && echo "alpha-disabled:yes" || echo "alpha-disabled:no"
        section_is_disabled beta && echo "beta-disabled:yes" || echo "beta-disabled:no"
        section_is_disabled gamma && echo "gamma-disabled:yes" || echo "gamma-disabled:no"

        section_has_configured_outbound alpha && echo "alpha-outbound:yes" || echo "alpha-outbound:no"
        section_has_configured_outbound beta && echo "beta-outbound:yes" || echo "beta-outbound:no"
        section_has_enabled_lists alpha && echo "alpha-lists:yes" || echo "alpha-lists:no"
        section_has_enabled_lists beta && echo "beta-lists:yes" || echo "beta-lists:no"

        echo "callback-restored:${_active_section_callback:-empty}"

        # Selection helpers: a disabled section is never the first outbound and
        # never the global-proxy section, even when it comes first / asks for it.
        SD_beta_global_proxy=1
        SD_gamma_global_proxy=1
        SD_SECTIONS="beta alpha gamma"
        echo "first-outbound:$(get_first_outbound_section)"
        echo "global-proxy:$(get_global_proxy_section)"
        has_outbound_section && echo "has-outbound:yes" || echo "has-outbound:no"

        # The walker must hand back the callback's status (list_update relies on
        # `foreach_active_section ... || update_failed=1` to report a failed run).
        SD_SECTIONS="alpha gamma"
        sd_fail() { return 1; }
        sd_pass() { return 0; }
        foreach_active_section sd_fail "section" && echo "rc-failing-callback:0" || echo "rc-failing-callback:1"
        foreach_active_section sd_pass "section" && echo "rc-passing-callback:0" || echo "rc-passing-callback:1"
        echo "rc-callback-restored:${_active_section_callback:-empty}"

        # Only disabled sections left -> as if there were no sections at all.
        SD_SECTIONS="beta delta"
        echo "only-disabled-first:[$(get_first_outbound_section)]"
        echo "only-disabled-global:[$(get_global_proxy_section)]"
        has_outbound_section && echo "only-disabled-has-outbound:yes" || echo "only-disabled-has-outbound:no"
    )"

    _sd_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted line [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _sd_check "disabled sections are skipped by foreach_active_section" "walk:alpha gamma"
    _sd_check "missing disabled option keeps the section active" "alpha-disabled:no"
    _sd_check "disabled '1' is detected" "beta-disabled:yes"
    _sd_check "disabled '0' keeps the section active" "gamma-disabled:no"
    _sd_check "active section has a configured outbound" "alpha-outbound:yes"
    _sd_check "disabled section has no configured outbound" "beta-outbound:no"
    _sd_check "active section has enabled lists" "alpha-lists:yes"
    _sd_check "disabled section has no enabled lists" "beta-lists:no"
    _sd_check "foreach_active_section restores its callback state" "callback-restored:empty"
    _sd_check "disabled section is never the first outbound" "first-outbound:alpha"
    _sd_check "disabled section is never the global-proxy section" "global-proxy:gamma"
    _sd_check "active sections still count as having an outbound" "has-outbound:yes"
    _sd_check "foreach_active_section returns a failing callback status" "rc-failing-callback:1"
    _sd_check "foreach_active_section returns 0 when callbacks succeed" "rc-passing-callback:0"
    _sd_check "foreach_active_section restores its callback after a failure" "rc-callback-restored:empty"
    _sd_check "only disabled sections: no first outbound" "only-disabled-first:[]"
    _sd_check "only disabled sections: no global-proxy section" "only-disabled-global:[]"
    _sd_check "only disabled sections: has_outbound_section is false" "only-disabled-has-outbound:no"

    # A disabled section picked in "Download Lists via specific proxy section"
    # has no outbound, so nothing may reference "<section>-out" (sing-box check
    # would fail and the whole service would not start).
    local cm_lib="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    local facade_lib="${NETSHIFT_LIB_DIR}/sing_box_config_facade.sh"
    local jq_helpers="${NETSHIFT_LIB_DIR}/helpers.jq"
    if ! command -v jq > /dev/null 2>&1 || [ ! -r "$cm_lib" ] || [ ! -r "$facade_lib" ] || [ ! -r "$jq_helpers" ]; then
        skip "download proxy section disabled: jq / libs not available"
        return
    fi

    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$cm_lib" /usr/lib/netshift/sing_box_config_manager.sh

    out="$(
        # shellcheck disable=SC2030,SC2031
        extract() {
            awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin"
        }
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        . "${NETSHIFT_LIB_DIR}/helpers.sh"
        . "${NETSHIFT_LIB_DIR}/logging.sh" 2>/dev/null || log() { :; }
        . "$facade_lib"
        for fn in section_is_disabled _active_section_dispatch foreach_active_section \
            subscription_outbound_is_unavailable download_proxy_section_is_unavailable \
            sing_box_additional_inbounds get_download_detour_tag; do
            eval "$(extract "$fn")"
        done
        _active_section_callback=
        SUBSCRIPTION_UNAVAILABLE_SECTIONS=""

        SD_PROXY_SECTION=""
        config_get() {
            case "$2:$3" in
            settings:download_lists_via_proxy_section) eval "$1=\"\$SD_PROXY_SECTION\"" ;;
            *) eval "$1=\"\${4:-}\"" ;;
            esac
        }
        config_get_bool() {
            case "$2:$3" in
            settings:download_lists_via_proxy) eval "$1=1" ;;
            beta:disabled) eval "$1=1" ;;
            *) eval "$1=\"\${4:-0}\"" ;;
            esac
        }
        config_foreach() { :; }
        get_outbound_tag_by_section() { echo "$1-out"; }

        base='{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct-out"},{"type":"direct","tag":"alpha-out"}],"route":{"rules":[],"final":"direct-out"}}'

        SD_PROXY_SECTION=beta
        echo "detour-disabled:[$(get_download_detour_tag)]"
        config="$base"
        sing_box_additional_inbounds
        echo "$config" | jq -e '[.route.rules[] | select(.outbound == "beta-out")] | length == 0' > /dev/null &&
            echo "inbounds-disabled-no-dangling-outbound:yes" || echo "inbounds-disabled-no-dangling-outbound:no"
        echo "$config" | jq -e '[.route.rules[] | select(.action == "reject")] | length == 1' > /dev/null &&
            echo "inbounds-disabled-rejects:yes" || echo "inbounds-disabled-rejects:no"
        if command -v sing-box > /dev/null 2>&1; then
            printf '%s' "$config" | jq 'walk(if type == "object" then del(.__service_tag) else . end)' > /tmp/sd-dl-disabled.json
            sing-box -c /tmp/sd-dl-disabled.json check > /dev/null 2>&1 &&
                echo "inbounds-disabled-singbox-check:yes" || echo "inbounds-disabled-singbox-check:no"
            rm -f /tmp/sd-dl-disabled.json
        fi

        SD_PROXY_SECTION=alpha
        echo "detour-active:[$(get_download_detour_tag)]"
        config="$base"
        sing_box_additional_inbounds
        echo "$config" | jq -e '[.route.rules[] | select(.outbound == "alpha-out")] | length == 1' > /dev/null &&
            echo "inbounds-active-routes-to-section:yes" || echo "inbounds-active-routes-to-section:no"
    )"

    _sd_check "disabled download proxy section: no detour tag" "detour-disabled:[]"
    _sd_check "disabled download proxy section: no route to its outbound" "inbounds-disabled-no-dangling-outbound:yes"
    _sd_check "disabled download proxy section: proxy requests are rejected" "inbounds-disabled-rejects:yes"
    if command -v sing-box > /dev/null 2>&1; then
        _sd_check "disabled download proxy section: config passes sing-box check" "inbounds-disabled-singbox-check:yes"
    fi
    _sd_check "active download proxy section keeps its detour tag" "detour-active:[alpha-out]"
    _sd_check "active download proxy section keeps its route" "inbounds-active-routes-to-section:yes"
}

# ─────────────────────────────────────────────────────────────────
# Test: BitTorrent exclusion (issue #56)
# ─────────────────────────────────────────────────────────────────
# Exercises the REAL sing_box_configure_route (extracted verbatim from the bin,
# like test_dns_via_outbound extracts _get_dns_detour_tag) with a stubbed UCI
# layer, plus the REAL sing-box_config_manager helpers. Asserts:
#   - upgrade simulation: with `exclude_bittorrent` ABSENT from the saved UCI
#     config the generated config is byte-identical to an explicit `0` and
#     carries no BitTorrent rule (sing-box check still passes);
#   - option on: exactly one route rule, protocol bittorrent -> direct-out,
#     placed IMMEDIATELY after the sniff rule (a rule placed before sniff can
#     never match — the protocol is not sniffed yet);
#   - option on is purely additive: every other route rule is untouched.
test_bittorrent_direct() {
    header "BitTorrent Exclusion (issue #56)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local cm_lib="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    local facade_lib="${NETSHIFT_LIB_DIR}/sing_box_config_facade.sh"
    local constants_lib="${NETSHIFT_LIB_DIR}/constants.sh"
    local jq_helpers="${NETSHIFT_LIB_DIR}/helpers.jq"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$cm_lib" ] || [ ! -r "$facade_lib" ] || [ ! -r "$constants_lib" ] || [ ! -r "$jq_helpers" ] \
        || [ ! -r "$bin" ]; then
        skip "config manager / facade / constants / helpers.jq / netshift bin not found"
        return
    fi

    # The manager and the facade hardcode the runtime library path; bind the
    # bind-mounted sources there (test_dns_via_outbound pattern).
    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$cm_lib" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/netshift-bittorrent-$$.sh"
    cat > "$drv" << 'BTEOF'
LIB="NETSHIFT_LIB"
BIN="BIN_PATH"
FACADE="FACADE_PATH"

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
. "$LIB/logging.sh" 2>/dev/null || log() { :; }
. "$FACADE"

# UCI stubs mirroring /lib/functions.sh: config_get_bool falls back to its
# default argument when the option is absent, which is exactly the upgrade case.
config_get_bool() {
    local _tmp=""
    case "$3" in
    exclude_bittorrent) _tmp="$UCI_EXCLUDE_BITTORRENT" ;;
    esac
    case "$_tmp" in
    1 | on | true | yes | enabled) _tmp=1 ;;
    0 | off | false | no | disabled) _tmp=0 ;;
    *) _tmp="$4" ;;
    esac
    eval "$1=\"\$_tmp\""
    return 0
}
config_get() {
    eval "$1=\"\""
    return 0
}
config_foreach() { :; }
config_list_foreach() { :; }
get_global_proxy_section() { echo ""; }
netshift_ipv6_enabled() { return 1; }
get_sections_by_connection_type() { echo ""; }
get_first_outbound_section() { echo ""; }
get_outbound_tag_by_section() { echo "$1-out"; }
subscription_outbound_is_unavailable() { return 1; }

# Pull the real route builder + its two helpers VERBATIM out of the bin.
for fn in section_is_disabled _active_section_dispatch foreach_active_section \
    sing_box_configure_route configure_common_reject_route_rule configure_common_direct_route_rule; do
    eval "$(awk -v name="$fn" '$0 == name "() {"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done
if command -v sing_box_configure_route > /dev/null 2>&1 &&
    command -v configure_common_reject_route_rule > /dev/null 2>&1 &&
    command -v configure_common_direct_route_rule > /dev/null 2>&1; then
    echo 'bittorrent-real-functions-loaded:OK'
else
    echo 'bittorrent-real-functions-loaded:FAIL'
fi

base=$(jq -n \
    --arg direct "$SB_DIRECT_OUTBOUND_TAG" \
    --arg tproxy "$SB_TPROXY_INBOUND_TAG" \
    --arg listen "$SB_TPROXY_INBOUND_ADDRESS" \
    --argjson port "$SB_TPROXY_INBOUND_PORT" \
    --arg dns "$SB_DNS_SERVER_TAG" \
    '{
    log: { disabled: false, level: "warn", timestamp: true },
    dns: {
        servers: [{ type: "udp", tag: $dns, server: "77.88.8.8" }],
        rules: [], final: $dns, strategy: "prefer_ipv4", independent_cache: true
    },
    inbounds: [
        { type: "tproxy", tag: $tproxy, listen: $listen, listen_port: $port }
    ],
    outbounds: [
        { type: "direct", tag: $direct }
    ],
    route: { rules: [], rule_set: [], final: $direct, auto_detect_interface: true }
}')

gen() {
    # $1 = UCI value of exclude_bittorrent ("" = option absent from the config)
    UCI_EXCLUDE_BITTORRENT="$1"
    config="$base"
    sing_box_configure_route
    printf '%s' "$config"
}

cfg_absent=$(gen "")
cfg_off=$(gen "0")
cfg_on=$(gen "1")

TAG="$SB_BITTORRENT_DIRECT_RULE_TAG"
DIRECT="$SB_DIRECT_OUTBOUND_TAG"
TPROXY="$SB_TPROXY_INBOUND_TAG"

# ── Upgrade simulation: option absent from the saved UCI config ─────────────
echo "$cfg_absent" | jq -e --arg tag "$TAG" \
    '[.route.rules[] | select(.["__service_tag"] == $tag)] | length == 0' > /dev/null 2>&1 &&
    echo 'bittorrent-upgrade-absent-no-rule:OK' || echo 'bittorrent-upgrade-absent-no-rule:FAIL'

echo "$cfg_off" | jq -e --arg tag "$TAG" \
    '[.route.rules[] | select(.["__service_tag"] == $tag)] | length == 0' > /dev/null 2>&1 &&
    echo 'bittorrent-off-no-rule:OK' || echo 'bittorrent-off-no-rule:FAIL'

# absent == explicit 0, compared through the SAVED artifact because the live
# config carries random gen_id tags that sing_box_cm_save_config_to_file strips.
sing_box_cm_save_config_to_file "$cfg_absent" /tmp/bt-absent.json
sing_box_cm_save_config_to_file "$cfg_off" /tmp/bt-off.json
sing_box_cm_save_config_to_file "$cfg_on" /tmp/bt-on.json
if cmp -s /tmp/bt-absent.json /tmp/bt-off.json; then
    echo 'bittorrent-absent-vs-off-parity:OK'
else
    echo 'bittorrent-absent-vs-off-parity:FAIL'
fi

# ── Option on: rule shape ───────────────────────────────────────────────────
echo "$cfg_on" | jq -e --arg tag "$TAG" --arg direct "$DIRECT" --arg tproxy "$TPROXY" \
    '[.route.rules[] | select(.["__service_tag"] == $tag
        and .action == "route" and .inbound == $tproxy
        and .protocol == "bittorrent" and .outbound == $direct)] | length == 1' > /dev/null 2>&1 &&
    echo 'bittorrent-on-rule-shape:OK' || echo 'bittorrent-on-rule-shape:FAIL'

# ── Ordering: strictly after sniff, and directly after it ──────────────────
echo "$cfg_on" | jq -e --arg tag "$TAG" \
    '([.route.rules[] | .action] | index("sniff")) as $sniff
     | ([.route.rules[] | .["__service_tag"]] | index($tag)) as $bt
     | ($sniff != null) and ($bt != null) and ($bt > $sniff)' > /dev/null 2>&1 &&
    echo 'bittorrent-on-after-sniff:OK' || echo 'bittorrent-on-after-sniff:FAIL'

echo "$cfg_on" | jq -e --arg tag "$TAG" \
    '([.route.rules[] | .action] | index("sniff")) as $sniff
     | ([.route.rules[] | .["__service_tag"]] | index($tag)) as $bt
     | $bt == ($sniff + 1)' > /dev/null 2>&1 &&
    echo 'bittorrent-on-immediately-after-sniff:OK' || echo 'bittorrent-on-immediately-after-sniff:FAIL'

# ── Option on is purely additive ───────────────────────────────────────────
on_without_bt=$(jq -cS '[.route.rules[] | select(.protocol != "bittorrent")]' /tmp/bt-on.json)
off_all=$(jq -cS '[.route.rules[]]' /tmp/bt-off.json)
if [ "$on_without_bt" = "$off_all" ]; then
    echo 'bittorrent-on-purely-additive:OK'
else
    echo 'bittorrent-on-purely-additive:FAIL'
fi

# ── sing-box validation of the SAVED artifact (service tags stripped) ──────
if command -v sing-box > /dev/null 2>&1; then
    sing-box -c /tmp/bt-absent.json check > /dev/null 2>&1 &&
        echo 'bittorrent-absent-singbox-check:OK' || echo 'bittorrent-absent-singbox-check:FAIL'
    sing-box -c /tmp/bt-on.json check > /dev/null 2>&1 &&
        echo 'bittorrent-on-singbox-check:OK' || echo 'bittorrent-on-singbox-check:FAIL'
    jq -e '[.route.rules[] | select(.protocol == "bittorrent")] | length == 1' /tmp/bt-on.json > /dev/null 2>&1 &&
        echo 'bittorrent-on-survives-save:OK' || echo 'bittorrent-on-survives-save:FAIL'
else
    echo 'bittorrent-absent-singbox-check:SKIP'
    echo 'bittorrent-on-singbox-check:SKIP'
    echo 'bittorrent-on-survives-save:SKIP'
fi
rm -f /tmp/bt-absent.json /tmp/bt-off.json /tmp/bt-on.json

# ── The new manager helper against a bare config ───────────────────────────
bare='{"route":{"rules":[{"action":"sniff","inbound":"tproxy-in"}],"rule_set":[],"final":"direct-out","auto_detect_interface":true}}'
out=$(sing_box_cm_add_bittorrent_direct_route_rule "$bare" "bt-tag" "tproxy-in" "direct-out")
echo "$out" | jq -e '(.route.rules | length) == 2
    and .route.rules[1].action == "route"
    and .route.rules[1].protocol == "bittorrent"
    and .route.rules[1].inbound == "tproxy-in"
    and .route.rules[1].outbound == "direct-out"
    and .route.rules[1]["__service_tag"] == "bt-tag"' > /dev/null 2>&1 &&
    echo 'bittorrent-helper-appends-rule:OK' || echo 'bittorrent-helper-appends-rule:FAIL'

echo 'DONE'
BTEOF
    sed -i "s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g; s|BIN_PATH|$bin|; s|FACADE_PATH|$facade_lib|" "$drv"

    local bt_out="/tmp/netshift-bittorrent-out-$$.log"
    ash "$drv" > "$bt_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$bt_out"
    if [ "$saw_done" = "1" ]; then
        pass "bittorrent-driver-completed:OK"
    else
        fail "bittorrent-driver-completed:FAIL (driver aborted early)"
    fi
    rm -f "$drv" "$bt_out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Stock sing-box update check (task-017)
# ─────────────────────────────────────────────────────────────────
# Exercises updates_check_sing_box_stable through the real sourced updater.sh
# with a PATH-prepended fake opkg whose candidate version + presence of sing-box
# are driven by env/marker files (the test_selfheal stub-harness pattern). Asserts
# the STABLE JSON `status` for: installed == candidate -> latest; candidate newer
# -> outdated; sing-box absent -> not_installed; feed unreachable -> success:false.
test_check_update_stable() {
    header "Stock sing-box Update Check (task-017)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-stablecheck-$$"
    rm -rf "$work"
    mkdir -p "$work/bin"

    # Fake opkg: `update` always ok; `list sing-box` echoes the candidate line
    # only when the candidate marker is set; a `sing-box` shim reports the
    # running version only when the present marker is set.
    cat > "$work/bin/opkg" << 'OPKGEOF'
#!/bin/sh
case "$1" in
update) exit 0 ;;
list)
    if [ -n "$STUBCHECK_CANDIDATE" ]; then
        printf 'sing-box - %s\n' "$STUBCHECK_CANDIDATE"
    fi
    exit 0
    ;;
esac
exit 0
OPKGEOF
    cat > "$work/bin/sing-box" << 'SBEOF'
#!/bin/sh
case "$1" in
version) printf 'sing-box version %s\n' "$STUBCHECK_INSTALLED" ;;
esac
exit 0
SBEOF
    chmod 0755 "$work/bin/opkg" "$work/bin/sing-box"

    # Isolated PATH: symlink only the utilities the updater/helpers need into a
    # dedicated dir so the real /usr/bin/sing-box is NOT reachable. The fake
    # sing-box is linked in conditionally per scenario (present vs absent).
    mkdir -p "$work/path"
    local _tool _tool_path
    for _tool in sh ash cat grep awk cut head sort sed printf basename ls rm mkdir cp mv chmod env jq dirname; do
        _tool_path="$(command -v "$_tool" 2>/dev/null)" && ln -sf "$_tool_path" "$work/path/$_tool" 2>/dev/null
    done
    ln -sf "$work/bin/opkg" "$work/path/opkg"

    # Driver: source updater.sh + helpers.sh (real is_min_package_version /
    # get_sing_box_version), silence logging, run the check.
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
. "DRV_HELPERS"
. "DRV_UPDATER"
updates_check_sing_box_stable
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_HELPERS|${NETSHIFT_LIB_DIR}/helpers.sh|g" "$drv"

    local out="$work/out.json"
    run_check() {
        # Isolated PATH: only $work/path (no real sing-box, apk absent → opkg
        # branch). sing-box presence is controlled by linking the fake in/out.
        if [ -n "$STUBCHECK_PRESENT" ]; then
            ln -sf "$work/bin/sing-box" "$work/path/sing-box" 2>/dev/null
        else
            rm -f "$work/path/sing-box" 2>/dev/null
        fi
        PATH="$work/path" ash "$drv" > "$out" 2>/dev/null || true
    }

    # ── Case 1: installed == candidate → latest ──────────────────────────────
    export STUBCHECK_CANDIDATE="1.12.0-r1"
    export STUBCHECK_PRESENT=1
    export STUBCHECK_INSTALLED="1.12.0"
    run_check
    if jq -e '.success == true and .status == "latest"' "$out" > /dev/null 2>&1; then
        pass "stablecheck-installed-eq-candidate-latest:OK"
    else
        fail "stablecheck-installed-eq-candidate-latest:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 2: candidate newer → outdated ───────────────────────────────────
    export STUBCHECK_CANDIDATE="1.13.5-r1"
    export STUBCHECK_PRESENT=1
    export STUBCHECK_INSTALLED="1.12.0"
    run_check
    if jq -e '.success == true and .status == "outdated"' "$out" > /dev/null 2>&1; then
        pass "stablecheck-candidate-newer-outdated:OK"
    else
        fail "stablecheck-candidate-newer-outdated:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 3: sing-box absent → not_installed ──────────────────────────────
    export STUBCHECK_CANDIDATE="1.13.5-r1"
    unset STUBCHECK_PRESENT
    run_check
    if jq -e '.success == true and .status == "not_installed"' "$out" > /dev/null 2>&1; then
        pass "stablecheck-absent-not_installed:OK"
    else
        fail "stablecheck-absent-not_installed:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 4: feed unreachable (empty candidate) → success:false ───────────
    unset STUBCHECK_CANDIDATE
    export STUBCHECK_PRESENT=1
    export STUBCHECK_INSTALLED="1.12.0"
    run_check
    if jq -e '.success == false and (.message | length) > 0' "$out" > /dev/null 2>&1; then
        pass "stablecheck-feed-unreachable-successfalse:OK"
    else
        fail "stablecheck-feed-unreachable-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    unset STUBCHECK_CANDIDATE STUBCHECK_PRESENT STUBCHECK_INSTALLED
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Extended sing-box Update Check — v-prefix regression (task-019)
# ─────────────────────────────────────────────────────────────────
# Sources the REAL updates_check_sing_box_extended from updater.sh and stubs its
# three dependencies (get_sing_box_version, updates_fetch_sing_box_extended_releases,
# updates_extended_release_tag) via markers so the comparison + emitted JSON can
# be driven deterministically. The regression: installed "1.13.12-extended-2.3.2"
# (no v) vs GitHub tag "v1.13.12-extended-2.3.2" (with v) must report
# status:"latest" (NOT "outdated"), with current_version/latest_version both
# emitted v-stripped and equal.
test_check_update_extended() {
    header "Extended sing-box Update Check — v-prefix (task-019)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-extcheck-$$"
    rm -rf "$work"
    mkdir -p "$work"

    # Driver: source updater.sh, silence logging, OVERRIDE the three deps after
    # sourcing (so the real updates_check_sing_box_extended calls our stubs), run
    # the check. STUBEXT_INSTALLED = get_sing_box_version output;
    # STUBEXT_RELEASES = the raw releases blob (empty → fetch-failure branch);
    # STUBEXT_TAG = the resolved release tag (with the leading v, as GitHub gives).
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
. "DRV_HELPERS"
. "DRV_UPDATER"
get_sing_box_version() { printf '%s' "$STUBEXT_INSTALLED"; }
updates_fetch_sing_box_extended_releases() { printf '%s' "$STUBEXT_RELEASES"; }
updates_extended_release_tag() { printf '%s' "$STUBEXT_TAG"; }
updates_check_sing_box_extended
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_HELPERS|${NETSHIFT_LIB_DIR}/helpers.sh|g" "$drv"

    local out="$work/out.json"
    run_extcheck() {
        ash "$drv" > "$out" 2>/dev/null || true
    }

    # ── Case 1: installed == latest, only the tag carries a leading v → latest ──
    # THE regression: must NOT be "outdated"; both versions emitted v-stripped+eq.
    export STUBEXT_INSTALLED="1.13.12-extended-2.3.2"
    export STUBEXT_RELEASES='[{"tag_name":"v1.13.12-extended-2.3.2"}]'
    export STUBEXT_TAG="v1.13.12-extended-2.3.2"
    run_extcheck
    if jq -e '.success == true and .status == "latest"
            and .current_version == "1.13.12-extended-2.3.2"
            and .latest_version == "1.13.12-extended-2.3.2"
            and .current_version == .latest_version' "$out" > /dev/null 2>&1; then
        pass "extcheck-vprefix-installed-eq-latest:OK"
    else
        fail "extcheck-vprefix-installed-eq-latest:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 2: installed older than the latest tag → outdated ──────────────────
    export STUBEXT_INSTALLED="1.13.10-extended-2.3.0"
    export STUBEXT_RELEASES='[{"tag_name":"v1.13.12-extended-2.3.2"}]'
    export STUBEXT_TAG="v1.13.12-extended-2.3.2"
    run_extcheck
    if jq -e '.success == true and .status == "outdated"
            and .current_version == "1.13.10-extended-2.3.0"
            and .latest_version == "1.13.12-extended-2.3.2"' "$out" > /dev/null 2>&1; then
        pass "extcheck-older-outdated:OK"
    else
        fail "extcheck-older-outdated:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 3: releases fetch failure (empty blob) → success:false ─────────────
    export STUBEXT_INSTALLED="1.13.12-extended-2.3.2"
    export STUBEXT_RELEASES=""
    export STUBEXT_TAG=""
    run_extcheck
    if jq -e '.success == false and (.message | length) > 0' "$out" > /dev/null 2>&1; then
        pass "extcheck-fetch-failure-successfalse:OK"
    else
        fail "extcheck-fetch-failure-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    unset STUBEXT_INSTALLED STUBEXT_RELEASES STUBEXT_TAG
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: sing-box-extended asset selection on 32-bit ARM (issue #37)
# ─────────────────────────────────────────────────────────────────
# Sources the REAL updater.sh and drives the REAL
# updates_resolve_sing_box_extended_arch_suffix / updates_extended_asset_url /
# updates_extract_sing_box_binary / _updates_install_sing_box_extended_core, with
# the /proc/cpuinfo "Features" line, DISTRIB_ARCH and the
# sing_box_extended_arm_build option injected per case.
#
# The bug (issue #37): every generic ARM asset of sing-box-extended needs
# floating point HARDWARE — "armv7" is GOARM=7 (VFPv3) and even "armv6" is
# GOARM=6 (VFPv1/VFPv2, runtime.checkgoarm exits without HWCAP_VFP). On a CPU
# with no FPU at all — Broadcom BCM5301X / Asus RT-AC88U, /proc/cpuinfo
# "half thumb fastmult edsp tls" — the downloaded binary cannot run ("Illegal
# instruction"). Only the OpenWrt package build for that target (GOARM=5,
# software floating point) works, so the no-FPU case must select that asset.
#
# The end-to-end cases run the real installer with only the network download
# faked: the fake artifacts' binary prints which asset was fetched, so the
# assertions cover what actually lands in /usr/bin/sing-box — including the
# nested unpacking of an OpenWrt .ipk (tar.gz -> data.tar.gz -> ./usr/bin/sing-box).
test_sing_box_extended_arm_arch() {
    header "sing-box-extended ARM asset selection (issue #37)"

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-sbextarch-$$"
    local out="$work/out.txt"
    local drv="$work/driver.sh"
    rm -rf "$work"
    mkdir -p "$work"

    # The end-to-end cases replace /usr/bin/sing-box — the very path the real
    # installer swaps. Keep the container's real core to restore afterwards.
    if [ -e /usr/bin/sing-box ]; then
        cp -p /usr/bin/sing-box "$work/sing-box.orig" 2>/dev/null || true
    fi

    cat > "$drv" << 'DRVEOF'
#!/bin/sh
log() { :; }
echolog() { :; }
nolog() { :; }

LIB_DIR="DRV_LIB_DIR"
. "$LIB_DIR/updater.sh"

# ── injection points ────────────────────────────────────────────────
CASE_FEATURES=""
CASE_ARM_BUILD=""
CASE_UNAME="armv7l"
CASE_OPTION_PRESENT=0
CASE_DISTRIB_ARCH="arm_cortex-a9"

uname() { printf '%s\n' "$CASE_UNAME"; }
updates_read_cpu_features() { printf '%s' "$CASE_FEATURES"; }
updates_read_openwrt_release_value() { printf '%s' "$CASE_DISTRIB_ARCH"; }
config_get() {
    # config_get <var> <section> <option> [default]
    if [ "$CASE_OPTION_PRESENT" = "1" ]; then
        eval "$1=\"\$CASE_ARM_BUILD\""
    else
        eval "$1=\"\${4:-}\""
    fi
    return 0
}
updates_system_uses_musl() { return 0; }

RELEASES='[{"tag_name":"v1.14.1-extended-2.7.2","draft":false,"prerelease":false,"assets":[
 {"name":"sing-box-1.14.1-extended-2.7.2-linux-armv6.tar.gz","browser_download_url":"https://example.invalid/armv6.tar.gz"},
 {"name":"sing-box-1.14.1-extended-2.7.2-linux-armv7-musl.tar.gz","browser_download_url":"https://example.invalid/armv7-musl.tar.gz"},
 {"name":"sing-box-1.14.1-extended-2.7.2-linux-armv7.tar.gz","browser_download_url":"https://example.invalid/armv7.tar.gz"},
 {"name":"sing-box-1.14.1-extended-2.7.2-linux-arm64-musl.tar.gz","browser_download_url":"https://example.invalid/arm64-musl.tar.gz"},
 {"name":"sing-box-extended_1.14.1-extended-2.7.2_openwrt_arm_cortex-a9.ipk","browser_download_url":"https://example.invalid/openwrt_arm_cortex-a9.ipk"},
 {"name":"sing-box-extended_1.14.1-extended-2.7.2_openwrt_arm_cortex-a9.apk","browser_download_url":"https://example.invalid/openwrt_arm_cortex-a9.apk"}]}]'

# Real RT-AC88U (Broadcom BCM5301X, Cortex-A9 without any FPU) feature line.
FEAT_NO_VFP="half thumb fastmult edsp tls"
# A modern ARMv7 (e.g. Cortex-A7) feature line.
FEAT_VFPV3="half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt"
# Cortex-A9 with the 16 double-register VFPv3 subset (OpenWrt arm_cortex-a9).
FEAT_VFPV3D16="half thumb fastmult vfp edsp vfpv3d16 tls"
# ARMv6-style VFPv2 only (VFP but no VFPv3).
FEAT_VFP2="half thumb fastmult vfp edsp tls"

REL="$(updates_extended_release_object "$RELEASES" "v1.14.1-extended-2.7.2")"

report() { # <token-name> <expected> <got>
    if [ "$2" = "$3" ]; then
        echo "$1:OK"
    else
        echo "$1:FAIL (expected '$2', got '$3')"
    fi
}

resolve_case() { # <name> <expected-suffix> <expected-kind> <expected-rc>
    SB_EXT_ARCH_SUFFIX=""
    SB_EXT_ASSET_KIND=""
    SB_EXT_ARCH_ERROR=""
    updates_resolve_sing_box_extended_arch_suffix
    rc=$?
    report "$1" "$2/$3/$4" "$SB_EXT_ARCH_SUFFIX/$SB_EXT_ASSET_KIND/$rc"
}

url_case() { # <name> <expected-url>
    report "$1" "$2" "$(updates_extended_asset_url "$REL")"
}

# ── Case 1: modern ARMv7 (VFPv3) keeps the armv7 tarball (unchanged) ──
CASE_UNAME=armv7l
CASE_FEATURES="$FEAT_VFPV3"
CASE_OPTION_PRESENT=0
resolve_case "sbext-armv7-vfpv3-uses-armv7-tarball" armv7 tarball 0
url_case "sbext-armv7-vfpv3-asset-url" "https://example.invalid/armv7-musl.tar.gz"

# ── Case 2: THE BUG — a CPU with no FPU must NOT get a generic ARM build ──
# The armv7 asset dies with SIGILL there and the armv6 asset cannot run either,
# so the OpenWrt package built for this target (GOARM=5) is the only usable one.
CASE_FEATURES="$FEAT_NO_VFP"
resolve_case "sbext-armv7-no-fpu-uses-openwrt-package" arm_cortex-a9 openwrt-package 0
url_case "sbext-armv7-no-fpu-asset-url" "https://example.invalid/openwrt_arm_cortex-a9.ipk"

# ── Case 2b: VFPv3-D16 (Cortex-A9 subset) still runs the armv7 build ──
CASE_FEATURES="$FEAT_VFPV3D16"
resolve_case "sbext-armv7-vfpv3d16-uses-armv7-tarball" armv7 tarball 0

# ── Case 2c: plain VFP (VFPv2 only) cannot run VFPv3 code -> armv6 ──
CASE_FEATURES="$FEAT_VFP2"
resolve_case "sbext-armv7-vfpv2-uses-armv6-tarball" armv6 tarball 0
url_case "sbext-armv7-vfpv2-asset-url" "https://example.invalid/armv6.tar.gz"

# ── Case 3: unreadable features (unknown CPU) keeps the armv7 tarball ──
# Upgrade safety: a router whose /proc/cpuinfo exposes no Features line must
# behave exactly as it did before this check existed.
CASE_FEATURES=""
resolve_case "sbext-armv7-no-features-keeps-armv7" armv7 tarball 0
url_case "sbext-armv7-no-features-asset-url" "https://example.invalid/armv7-musl.tar.gz"

# ── Case 3b: no FPU and no DISTRIB_ARCH -> refuse, never a broken build ──
CASE_FEATURES="$FEAT_NO_VFP"
CASE_DISTRIB_ARCH=""
SB_EXT_ARCH_SUFFIX=""
SB_EXT_ASSET_KIND=""
SB_EXT_ARCH_ERROR=""
updates_resolve_sing_box_extended_arch_suffix
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$SB_EXT_ARCH_SUFFIX" ] && [ -n "$SB_EXT_ARCH_ERROR" ]; then
    echo "sbext-no-fpu-no-distrib-arch-refuses:OK"
else
    echo "sbext-no-fpu-no-distrib-arch-refuses:FAIL (rc=$rc suffix='$SB_EXT_ARCH_SUFFIX' error='$SB_EXT_ARCH_ERROR')"
fi
CASE_DISTRIB_ARCH="arm_cortex-a9"

# ── Case 4: option present but empty / unknown value -> auto detection ──
CASE_OPTION_PRESENT=1
CASE_ARM_BUILD=""
resolve_case "sbext-option-empty-falls-back-to-auto" arm_cortex-a9 openwrt-package 0
CASE_ARM_BUILD="banana"
resolve_case "sbext-option-unknown-falls-back-to-auto" arm_cortex-a9 openwrt-package 0

# ── Case 5: explicit overrides ──
CASE_ARM_BUILD="armv6"
CASE_FEATURES="$FEAT_VFPV3"
resolve_case "sbext-option-armv6-forces-armv6" armv6 tarball 0
CASE_ARM_BUILD="armv7"
CASE_FEATURES="$FEAT_NO_VFP"
resolve_case "sbext-option-armv7-forces-armv7" armv7 tarball 0
CASE_ARM_BUILD="openwrt"
CASE_FEATURES="$FEAT_VFPV3"
resolve_case "sbext-option-openwrt-forces-package" arm_cortex-a9 openwrt-package 0

# ── Case 6: other architectures unchanged ──
CASE_OPTION_PRESENT=0
CASE_UNAME=aarch64
CASE_FEATURES="$FEAT_VFPV3"
resolve_case "sbext-aarch64-uses-arm64" arm64 tarball 0
CASE_UNAME=armv6l
resolve_case "sbext-armv6-host-with-vfp-uses-armv6" armv6 tarball 0
CASE_FEATURES="$FEAT_NO_VFP"
resolve_case "sbext-armv6-host-no-fpu-uses-openwrt-package" arm_cortex-a9 openwrt-package 0
CASE_UNAME=x86_64
resolve_case "sbext-x86-64-uses-amd64" amd64 tarball 0
CASE_UNAME=riscv64
resolve_case "sbext-riscv64-uses-riscv64" riscv64 tarball 0

# ── Case 7: END-TO-END real installs with a fake download ────────────
CASE_UNAME=armv7l
updates_fetch_sing_box_extended_releases() { printf '%s' "$RELEASES"; }
updates_restart_netshift() { :; }

# Builds a fake sing-box-extended .ipk with the real layout: a tar.gz holding
# control.tar.gz + data.tar.gz + debian-binary, payload at ./usr/bin/sing-box
# inside data.tar.gz.
make_fake_ipk() { # <dest> <marker>
    local dest="$1" marker="$2" d
    d="$(mktemp -d /tmp/sbext-ipk.XXXXXX)"
    mkdir -p "$d/data/usr/bin" "$d/control"
    cat > "$d/data/usr/bin/sing-box" <<EOF
#!/bin/sh
echo "sing-box version 1.14.1-extended-2.7.2-$marker"
EOF
    chmod 0755 "$d/data/usr/bin/sing-box"
    ( cd "$d/data" && tar -czf "$d/data.tar.gz" ./usr/bin/sing-box )
    printf 'Package: sing-box-extended\nArchitecture: arm_cortex-a9\n' > "$d/control/control"
    ( cd "$d/control" && tar -czf "$d/control.tar.gz" ./control )
    printf '2.0\n' > "$d/debian-binary"
    ( cd "$d" && tar -czf "$dest" control.tar.gz data.tar.gz debian-binary )
    rm -rf "$d"
}

updates_download_to_file() {
    local _url="$1"
    local _dest="$2"
    local _marker="unknown"
    local _d

    case "$_url" in
    *openwrt_arm_cortex-a9.ipk*)
        make_fake_ipk "$_dest" "openwrt-ipk"
        return 0
        ;;
    esac

    case "$_url" in
    *armv6*) _marker="armv6" ;;
    *armv7*) _marker="armv7" ;;
    *arm64*) _marker="arm64" ;;
    esac
    _d="$(mktemp -d /tmp/sbext-fake.XXXXXX)"
    cat > "$_d/sing-box" <<EOF
#!/bin/sh
echo "sing-box version 1.14.1-extended-2.7.2-$_marker"
EOF
    chmod 0755 "$_d/sing-box"
    ( cd "$_d" && tar -czf "$_dest" sing-box )
    rm -rf "$_d"
    return 0
}

# No-FPU CPU: must install the OpenWrt package payload and succeed.
CASE_FEATURES="$FEAT_NO_VFP"
CASE_OPTION_PRESENT=0
json="$(_updates_install_sing_box_extended_core 2>/dev/null)"
installed="$(LD_LIBRARY_PATH=/usr/lib /usr/bin/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
report "sbext-e2e-no-fpu-installs-openwrt-package" "1.14.1-extended-2.7.2-openwrt-ipk" "$installed"
if printf '%s' "$json" | grep -q '"success":true'; then
    echo "sbext-e2e-install-json-success:OK"
else
    echo "sbext-e2e-install-json-success:FAIL ($json)"
fi

# The same install on a VFPv3 CPU must keep using the armv7 tarball.
CASE_FEATURES="$FEAT_VFPV3"
json="$(_updates_install_sing_box_extended_core 2>/dev/null)"
installed="$(LD_LIBRARY_PATH=/usr/lib /usr/bin/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
report "sbext-e2e-vfpv3-installs-armv7-tarball" "1.14.1-extended-2.7.2-armv7" "$installed"

# A VFPv2-only CPU must use the armv6 tarball.
CASE_FEATURES="$FEAT_VFP2"
json="$(_updates_install_sing_box_extended_core 2>/dev/null)"
installed="$(LD_LIBRARY_PATH=/usr/lib /usr/bin/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
report "sbext-e2e-vfpv2-installs-armv6-tarball" "1.14.1-extended-2.7.2-armv6" "$installed"

# A package without a sing-box payload must fail the install AND leave the
# previously installed core in place (rollback), never an empty /usr/bin/sing-box.
CASE_FEATURES="$FEAT_NO_VFP"
updates_download_to_file() {
    local _dest="$2" _d
    _d="$(mktemp -d /tmp/sbext-bad.XXXXXX)"
    mkdir -p "$_d/data/usr/share/doc"
    printf 'nothing here\n' > "$_d/data/usr/share/doc/readme"
    ( cd "$_d/data" && tar -czf "$_d/data.tar.gz" ./usr/share/doc/readme )
    printf '2.0\n' > "$_d/debian-binary"
    ( cd "$_d" && tar -czf "$_dest" data.tar.gz debian-binary )
    rm -rf "$_d"
    return 0
}
json="$(_updates_install_sing_box_extended_core 2>/dev/null)"
installed="$(LD_LIBRARY_PATH=/usr/lib /usr/bin/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
if printf '%s' "$json" | grep -q '"success":false' &&
    [ "$installed" = "1.14.1-extended-2.7.2-armv6" ]; then
    echo "sbext-e2e-payload-less-package-fails-cleanly:OK"
else
    echo "sbext-e2e-payload-less-package-fails-cleanly:FAIL ($json restored='$installed')"
fi

echo DONE
DRVEOF
    sed -i "s|DRV_LIB_DIR|${NETSHIFT_LIB_DIR}|g" "$drv"

    sh "$drv" > "$out" 2>&1 || true

    # Restore the core the end-to-end cases replaced, whatever happened.
    if [ -f "$work/sing-box.orig" ]; then
        cp -p "$work/sing-box.orig" /usr/bin/sing-box 2>/dev/null || true
    fi

    local line saw_done=0
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "sbext-arch-driver-completed"
    else
        fail "sbext-arch-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$out" 2>/dev/null)"
    fi

    # ── Part 2: UPGRADE SIMULATION against real UCI + real config_get ───────
    # A router upgraded from an older NetShift keeps its own /etc/config/netshift,
    # so sing_box_extended_arm_build is simply ABSENT there. This part loads a
    # real UCI config dir (no such option) through the real config_load /
    # config_get and checks that the resolution still works, that a CPU which
    # always worked keeps the exact build it got before, and that the no-FPU CPU
    # gets the OpenWrt package — with no error and no exit either way.
    if [ ! -r /lib/functions.sh ] || ! command -v uci > /dev/null 2>&1; then
        skip "real-UCI upgrade simulation (uci/functions.sh unavailable)"
        rm -rf "$work"
        return
    fi

    local uci_dir="$work/uci"
    local uout="$work/uci-out.txt"
    local udrv="$work/uci-driver.sh"
    mkdir -p "$uci_dir"
    cat > "$uci_dir/netshift" << 'UCICFG'
config settings 'settings'
        option dns_type 'udp'
        option update_interval '1d'
UCICFG

    cat > "$udrv" << 'UCIDRV'
#!/bin/sh
# Real /lib/functions.sh + real config_load/config_get over UCI_CONFIG_DIR.
log() { :; }
echolog() { :; }
nolog() { :; }

. /lib/functions.sh
. "DRV_LIB_DIR/updater.sh"

CASE_FEATURES=""
uname() { printf 'armv7l\n'; }
updates_read_cpu_features() { printf '%s' "$CASE_FEATURES"; }
updates_read_openwrt_release_value() { printf 'arm_cortex-a9'; }

NO_FPU="half thumb fastmult edsp tls"
VFPV3="half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt"

resolve() { # <name> <expected-suffix> <expected-kind>
    SB_EXT_ARCH_SUFFIX=""
    SB_EXT_ASSET_KIND=""
    SB_EXT_ARCH_ERROR=""
    updates_resolve_sing_box_extended_arch_suffix
    rc=$?
    if [ "$2" = "$SB_EXT_ARCH_SUFFIX" ] && [ "$3" = "$SB_EXT_ASSET_KIND" ] && [ "$rc" -eq 0 ]; then
        echo "$1:OK"
    else
        echo "$1:FAIL (expected '$2/$3', got '$SB_EXT_ARCH_SUFFIX/$SB_EXT_ASSET_KIND' rc=$rc)"
    fi
}

config_load netshift

# Upgrade case: the option does not exist in this config at all. The behaviour
# on a CPU that always worked must be byte-for-byte the old one (armv7 tarball),
# and the no-FPU CPU must now get the OpenWrt package.
CASE_FEATURES="$VFPV3"
resolve "sbext-upgrade-absent-option-keeps-armv7" armv7 tarball
CASE_FEATURES="$NO_FPU"
resolve "sbext-upgrade-absent-option-detects-package" arm_cortex-a9 openwrt-package

# Present-but-unset and present-but-unknown values must fall back to detection.
uci -c "$UCI_DIR" set netshift.settings.sing_box_extended_arm_build=''
uci -c "$UCI_DIR" commit netshift > /dev/null 2>&1
config_load netshift
resolve "sbext-upgrade-empty-option-detects-package" arm_cortex-a9 openwrt-package

uci -c "$UCI_DIR" set netshift.settings.sing_box_extended_arm_build='banana'
uci -c "$UCI_DIR" commit netshift > /dev/null 2>&1
config_load netshift
resolve "sbext-upgrade-unknown-option-detects-package" arm_cortex-a9 openwrt-package

# Explicit overrides, read through the real UCI stack.
uci -c "$UCI_DIR" set netshift.settings.sing_box_extended_arm_build='armv7'
uci -c "$UCI_DIR" commit netshift > /dev/null 2>&1
config_load netshift
resolve "sbext-upgrade-option-forces-armv7" armv7 tarball

uci -c "$UCI_DIR" set netshift.settings.sing_box_extended_arm_build='armv6'
uci -c "$UCI_DIR" commit netshift > /dev/null 2>&1
config_load netshift
CASE_FEATURES="$VFPV3"
resolve "sbext-upgrade-option-forces-armv6" armv6 tarball

uci -c "$UCI_DIR" set netshift.settings.sing_box_extended_arm_build='openwrt'
uci -c "$UCI_DIR" commit netshift > /dev/null 2>&1
config_load netshift
CASE_FEATURES="$VFPV3"
resolve "sbext-upgrade-option-forces-package" arm_cortex-a9 openwrt-package

echo DONE
UCIDRV
    sed -i "s|DRV_LIB_DIR|${NETSHIFT_LIB_DIR}|g" "$udrv"

    UCI_DIR="$uci_dir" UCI_CONFIG_DIR="$uci_dir" sh "$udrv" > "$uout" 2>&1 || true

    saw_done=0
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done < "$uout"
    if [ "$saw_done" = "1" ]; then
        pass "sbext-upgrade-driver-completed"
    else
        fail "sbext-upgrade-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$uout" 2>/dev/null)"
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: sing-box extended lite — third core variant
# ─────────────────────────────────────────────────────────────────
# Sources the REAL constants/helpers/updater and drives the whole lite
# machinery with only the network faked:
#   * the variant predicates (get_sing_box_variant / sing_box_lite_is_upx)
#     over fake /usr/bin/sing-box layouts (ELF, our UPX wrapper+core, a
#     community manual install whose version lacks the -lite suffix);
#   * is_sing_box_extended_at_least with the -lite suffix (a lite build is
#     an extended build as far as the feature gates are concerned);
#   * the build selection (UCI override, auto by effective free space) and
#     the upx_ram_spike warning code;
#   * END-TO-END installs (ELF and compressed) with fake tar.gz artifacts
#     and a REAL sha256sums.txt check — the UPX wrapper must answer
#     `version` from the snapshot cache WITHOUT running the core (marker),
#     a wrong binary must roll back to the previous core AND the previous
#     lite artifacts, and leaving lite for stock/full-extended must clean
#     the lite artifacts away (or restore them when the switch fails);
#   * check_update_lite (latest / outdated / manual install without -lite /
#     fetch failure) and the async job state carrying the build flavour.
# The end-to-end cases replace /usr/bin/sing-box and create
# /usr/libexec/sing-box-core + the version caches; whatever existed before
# is saved and restored afterwards.
test_sing_box_lite() {
    header "sing-box extended lite (third core variant)"

    local constants="${NETSHIFT_LIB_DIR}/constants.sh"
    local helpers="${NETSHIFT_LIB_DIR}/helpers.sh"
    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$constants" ] || [ ! -r "$helpers" ] || [ ! -r "$updater" ] || [ ! -r "$bin" ]; then
        skip "constants/helpers/updater/bin not found in ${NETSHIFT_SRC}"
        return
    fi
    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local work="/tmp/netshift-sbextlite-$$"
    local out="$work/out.txt"
    local out2="$work/out2.txt"
    local drv="$work/driver.sh"
    rm -rf "$work"
    mkdir -p "$work"

    # State the end-to-end cases replace — saved here, restored after.
    if [ -e /usr/bin/sing-box ]; then
        cp -p /usr/bin/sing-box "$work/sing-box.orig" 2>/dev/null || true
    fi
    if [ -e /usr/libexec/sing-box-core ]; then
        cp -p /usr/libexec/sing-box-core "$work/lite-core.orig" 2>/dev/null || true
    fi
    if [ -e /etc/netshift/core-version.cache ]; then
        cp -p /etc/netshift/core-version.cache "$work/core-cache.orig" 2>/dev/null || true
    fi
    if [ -e /etc/sing-box-version.cache ]; then
        cp -p /etc/sing-box-version.cache "$work/orphan-cache.orig" 2>/dev/null || true
    fi

    cat > "$drv" << 'DRVEOF'
#!/bin/sh
log() { :; }
echolog() { :; }
nolog() { :; }

. "DRV_CONSTANTS"
. "DRV_HELPERS"
. "DRV_UPDATER"

# ── injection points ────────────────────────────────────────────────
LITE_RELEASES='[{"tag_name":"v1.14.1-extended-2.7.2-lite","draft":false,"prerelease":false,"assets":[
 {"name":"sing-box-extended-lite-linux-amd64.tar.gz","browser_download_url":"https://example.invalid/dl/sing-box-extended-lite-linux-amd64.tar.gz"},
 {"name":"sing-box-extended-lite-linux-amd64-compressed.tar.gz","browser_download_url":"https://example.invalid/dl/sing-box-extended-lite-linux-amd64-compressed.tar.gz"},
 {"name":"sha256sums.txt","browser_download_url":"https://example.invalid/dl/sha256sums.txt"}]}]'
LITE_RELEASES_NOSUMS='[{"tag_name":"v1.14.1-extended-2.7.2-lite","draft":false,"prerelease":false,"assets":[
 {"name":"sing-box-extended-lite-linux-amd64.tar.gz","browser_download_url":"https://example.invalid/dl/sing-box-extended-lite-linux-amd64.tar.gz"},
 {"name":"sing-box-extended-lite-linux-amd64-compressed.tar.gz","browser_download_url":"https://example.invalid/dl/sing-box-extended-lite-linux-amd64-compressed.tar.gz"}]}]'
EXT_RELEASES='[{"tag_name":"v1.14.1-extended-2.7.2","draft":false,"prerelease":false,"assets":[
 {"name":"sing-box-1.14.1-extended-2.7.2-linux-amd64.tar.gz","browser_download_url":"https://example.invalid/dl/sing-box-1.14.1-extended-2.7.2-linux-amd64.tar.gz"}]}]'
CASE_UNAME="x86_64"
CASE_FEATURES=""
CASE_DISTRIB_ARCH=""
CASE_LITE_BUILD="auto"
CASE_RAM_MB=512
CASE_DF_KB=999999
CASE_SUMS_MODE="good"
CASE_PKG_MODE="ok"
CASE_FETCH_FAIL=0
CASE_RELEASES="$LITE_RELEASES"
CORE_VERSION="1.14.1-extended-2.7.2-lite"
CORE_MARKER="/tmp/sblite-core-calls-$$"
SB_VER_OVERRIDE=""
STOCK_CORE_VERSION="1.12.0"
WRK="/tmp/sblite-wrk-$$"
rm -rf "$WRK"
mkdir -p "$WRK" /etc/netshift

# The stubs below fake ONLY the environment (arch/UCI/RAM/disk) and the
# network (releases + downloads). The real helpers under test — variant
# detection, build selection, sha256 verification, install, rollback,
# check — all run for real. The async worker re-execs this driver, so the
# stubs must be in place for every dispatch mode except "realhelpers",
# which deliberately runs the pure sourced libraries untouched.
if [ "${1:-}" != "realhelpers" ]; then
    uname() { printf '%s\n' "$CASE_UNAME"; }
    updates_read_cpu_features() { printf '%s' "$CASE_FEATURES"; }
    updates_read_openwrt_release_value() { printf '%s' "$CASE_DISTRIB_ARCH"; }
    config_get() {
        # config_get <var> <section> <option> [default]
        case "$3" in
        sing_box_lite_build) eval "$1=\"\$CASE_LITE_BUILD\"" ;;
        sing_box_extended_arm_build) eval "$1=\"auto\"" ;;
        *) eval "$1=\"\${4:-}\"" ;;
        esac
        return 0
    }
    get_ram_total_mb() { printf '%s' "$CASE_RAM_MB"; }
    df() {
        case "$1 $2" in
        "-Pk /") printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 100000 1000 %s 1%% /\n' "$CASE_DF_KB" ;;
        *) command df "$@" ;;
        esac
    }
    # The real probe (word after "version"), minus the process cache, with
    # an override hook for the check_update_lite cases.
    get_sing_box_version() {
        if [ -n "$SB_VER_OVERRIDE" ]; then
            printf '%s' "$SB_VER_OVERRIDE"
            return
        fi
        local version=""
        if command -v sing-box >/dev/null 2>&1; then
            version="$(sing-box version 2>/dev/null | head -n1 | awk '
                { for (i = 1; i < NF; i++) if ($i == "version") { print $(i + 1); exit }
                  print $NF }')"
        fi
        echo "${version:-1.0}"
    }

    updates_fetch_github_releases() {
        [ "$CASE_FETCH_FAIL" = "0" ] || return 1
        case "$1" in
        "$UPDATES_SING_BOX_LITE_REPO") printf '%s' "$CASE_RELEASES" ;;
        "$UPDATES_SING_BOX_EXTENDED_REPO") printf '%s' "$EXT_RELEASES" ;;
        esac
    }
    updates_system_uses_musl() { return 1; }
    updates_restart_netshift() { :; }
    updates_ensure_connectivity() { return 0; }
    updates_restore_after_swap() { :; }

    apk() {
        case "$1" in
        update) return 0 ;;
        fix)
            [ "$CASE_PKG_MODE" = "ok" ] || return 1
            place_fake_bin /usr/bin/sing-box "$STOCK_CORE_VERSION" elf
            return 0
            ;;
        fetch) return 1 ;;
        esac
        return 0
    }
    opkg() {
        case "$1" in
        update) return 0 ;;
        install)
            [ "$CASE_PKG_MODE" = "ok" ] || return 1
            place_fake_bin /usr/bin/sing-box "$STOCK_CORE_VERSION" elf
            return 0
            ;;
        esac
        return 0
    }

    # Fake binaries. "elf" fakes start WITHOUT a shebang on purpose: head -c 2
    # must not see "#!" (ash still runs them as shell scripts), so they pass
    # for an ELF binary in every layout check.
    place_fake_bin() { # <path> <version> <elf|wrapper>
        local path="$1" ver="$2" mode="$3"
        if [ "$mode" = "wrapper" ]; then
            cat >"$path" <<WEOF
#!/bin/sh
# sblite test wrapper
if [ "\$1" = "version" ]; then
    echo run >>"$CORE_MARKER"
    echo "sing-box version $ver"
    exit 0
fi
exec /usr/libexec/sing-box-core "\$@"
WEOF
        else
            # Single-quoted on purpose: $1 must reach the fake verbatim.
            printf 'if [ "$1" = "version" ]; then echo run >>"%s"; echo "sing-box version %s"; exit 0; fi\n' "$CORE_MARKER" "$ver" >"$path"
        fi
        chmod 0755 "$path"
    }

    make_fake_archive() { # <dest> <asset-name> <version>
        local dest="$1" name="$2" ver="$3" d h
        d="$(mktemp -d /tmp/sblite-fake.XXXXXX)"
        cat >"$d/sing-box" <<FEOF
#!/bin/sh
echo run >>"$CORE_MARKER"
echo "sing-box version $ver"
FEOF
        chmod 0755 "$d/sing-box"
        ( cd "$d" && tar -czf "$dest" sing-box )
        h="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
        if [ "$CASE_SUMS_MODE" = "bad" ]; then
            h="0000000000000000000000000000000000000000000000000000000000000000"
        fi
        printf '%s  %s\n' "$h" "$name" >"$dest.sums"
        rm -rf "$d"
    }

    FAKE_ARCHIVE=""
    updates_download_to_file() {
        local url="$1" dest="$2"
        case "$url" in
        *sha256sums.txt*)
            [ -n "$FAKE_ARCHIVE" ] && cp "$FAKE_ARCHIVE.sums" "$dest" && [ -s "$dest" ] && return 0
            return 1
            ;;
        *sing-box-extended-lite-*)
            make_fake_archive "$dest" "$(basename "$url")" "$CORE_VERSION"
            FAKE_ARCHIVE="$dest"
            return 0
            ;;
        *)
            # the full-extended asset: same archive shape, extended version
            make_fake_archive "$dest" "$(basename "$url")" "1.14.1-extended-2.7.2-x86"
            return 0
            ;;
        esac
    }
fi

main_body() {
    # ── Part 1: variant predicates over fake layouts ──────────────
    variant_case() { # <name> <expected-variant> <expected-upx-rc>
        local name="$1" want="$2" wantupx="$3" v u
        v="$(get_sing_box_variant)"
        if sing_box_lite_is_upx; then u=0; else u=1; fi
        if [ "$v" = "$want" ] && [ "$u" = "$wantupx" ]; then
            echo "$name:OK"
        else
            echo "$name:FAIL (variant='$v' want='$want' upx_rc=$u want_rc=$wantupx)"
        fi
    }

    rm -f /usr/bin/sing-box /usr/libexec/sing-box-core \
        /etc/netshift/core-version.cache /etc/sing-box-version.cache
    place_fake_bin /usr/bin/sing-box "1.14.1" elf
    variant_case sblite-variant-stock-elf stock 1
    place_fake_bin /usr/bin/sing-box "1.14.1-extended-2.7.2" elf
    variant_case sblite-variant-extended-elf extended 1
    place_fake_bin /usr/bin/sing-box "1.14.1-extended-2.7.2-lite" elf
    variant_case sblite-variant-lite-elf extended_lite 1

    place_fake_bin /usr/bin/sing-box "1.14.1-extended-2.7.2-lite" wrapper
    place_fake_bin /usr/libexec/sing-box-core "1.14.1-extended-2.7.2-lite" elf
    variant_case sblite-variant-lite-upx extended_lite 0
    # community manual install: the wrapper reports a version WITHOUT -lite;
    # the layout (wrapper + side-loaded core) is authoritative.
    place_fake_bin /usr/bin/sing-box "1.14.1-extended-2.7.2" wrapper
    variant_case sblite-variant-lite-manual extended_lite 0
    rm -f /usr/libexec/sing-box-core
    variant_case sblite-variant-wrapper-no-core extended 1
    place_fake_bin /usr/bin/sing-box "1.14.1" wrapper
    variant_case sblite-variant-wrapper-stock stock 1

    # ── Part 2: -lite passes the extended feature gates ───────────
    for v in 1.14.1-extended-2.7.2-lite 1.13.14-extended-2.5.0-lite \
        1.12.22-extended-2.0.0-lite 1.12.22-extended-2.0.0-rc.1-lite; do
        if is_sing_box_extended_at_least "2.0.0" "$v"; then
            echo "sblite-atleast-accepts-$v:OK"
        else
            echo "sblite-atleast-accepts-$v:FAIL"
        fi
    done
    for v in 1.13.11-extended-1.6.2-lite 1.12.22-extended-1.9.9-lite \
        1.14.1 1.14.1-lite; do
        if is_sing_box_extended_at_least "2.0.0" "$v"; then
            echo "sblite-atleast-rejects-$v:FAIL"
        else
            echo "sblite-atleast-rejects-$v:OK"
        fi
    done

    # ── Part 3: the architecture predicate ─────────────────────
    arch_case() { # <name> <uname> <expected-rc>
        local name="$1" u="$2" wantrc="$3" rc
        CASE_UNAME="$u"
        if sing_box_lite_arch_supported; then rc=0; else rc=1; fi
        if [ "$rc" = "$wantrc" ]; then
            echo "$name:OK"
        else
            echo "$name:FAIL (rc=$rc want_rc=$wantrc)"
        fi
    }
    arch_case sblite-arch-amd64 x86_64 0
    arch_case sblite-arch-arm64 aarch64 0
    arch_case sblite-arch-armv7 armv7l 0
    arch_case sblite-arch-armv6 armv6l 1
    arch_case sblite-arch-mips mips 0
    arch_case sblite-arch-mips64 mips64 1
    arch_case sblite-arch-riscv64 riscv64 1
    arch_case sblite-arch-386 i686 1
    # a no-FPU ARM CPU resolves to the OpenWrt .ipk — no lite counterpart.
    CASE_UNAME=armv7l
    CASE_FEATURES="half thumb fastmult edsp tls"
    if sing_box_lite_arch_supported; then
        echo "sblite-arch-nofpu-arm:FAIL (ipk host must be unsupported)"
    else
        echo "sblite-arch-nofpu-arm:OK"
    fi
    CASE_FEATURES=""
    CASE_UNAME=x86_64

    # ── Part 4: build selection + warning code ────────────────
    select_case() { # <name> <want-build>
        local b
        b="$(updates_lite_select_build)"
        if [ "$b" = "$2" ]; then
            echo "$1:OK"
        else
            echo "$1:FAIL (got '$b' want '$2')"
        fi
    }
    CASE_LITE_BUILD=auto
    CASE_DF_KB=999999
    select_case sblite-select-auto-big-flash elf
    CASE_DF_KB=1000
    select_case sblite-select-auto-tiny-flash compressed
    CASE_LITE_BUILD=elf
    select_case sblite-select-explicit-elf elf
    CASE_LITE_BUILD=compressed
    CASE_DF_KB=999999
    select_case sblite-select-explicit-compressed compressed
    CASE_LITE_BUILD=banana
    CASE_DF_KB=1000
    select_case sblite-select-unknown-option-auto compressed
    # the bytes the current /usr/bin/sing-box frees count towards the space
    CASE_LITE_BUILD=auto
    CASE_DF_KB=65000
    place_fake_bin /usr/bin/sing-box "1.14.1" elf
    select_case sblite-select-tiny-bin-still-compressed compressed
    dd if=/dev/zero of=/usr/bin/sing-box bs=1024 count=1024 2>/dev/null
    select_case sblite-select-freed-bin-crosses-threshold elf
    CASE_DF_KB=999999

    if [ -z "$(updates_lite_build_warning compressed)" ] &&
        [ -z "$(updates_lite_build_warning elf)" ]; then
        echo "sblite-warn-highram-none:OK"
    else
        echo "sblite-warn-highram-none:FAIL"
    fi
    CASE_RAM_MB=128
    if [ "$(updates_lite_build_warning compressed)" = "upx_ram_spike" ]; then
        echo "sblite-warn-lowram-code:OK"
    else
        echo "sblite-warn-lowram-code:FAIL"
    fi
    CASE_RAM_MB=0
    if [ -z "$(updates_lite_build_warning compressed)" ]; then
        echo "sblite-warn-unknownram-none:OK"
    else
        echo "sblite-warn-unknownram-none:FAIL"
    fi
    CASE_RAM_MB=512

    # ── Part 5: sha256 verification unit ────────────────────
    printf 'hello lite\n' >"$WRK/f"
    lh="$(sha256sum "$WRK/f" 2>/dev/null | awk '{print $1}')"
    printf '%s  sing-box-extended-lite-linux-amd64.tar.gz\n' "$lh" >"$WRK/sums"
    if updates_lite_verify_sha256 "$WRK/sums" sing-box-extended-lite-linux-amd64.tar.gz "$WRK/f"; then
        echo "sblite-sha-good:OK"
    else
        echo "sblite-sha-good:FAIL"
    fi
    printf 'deadbeef  sing-box-extended-lite-linux-amd64.tar.gz\n' >"$WRK/sums"
    if updates_lite_verify_sha256 "$WRK/sums" sing-box-extended-lite-linux-amd64.tar.gz "$WRK/f"; then
        echo "sblite-sha-mismatch:FAIL"
    else
        echo "sblite-sha-mismatch:OK"
    fi
    printf '%s  other-asset.tar.gz\n' "$lh" >"$WRK/sums"
    if updates_lite_verify_sha256 "$WRK/sums" sing-box-extended-lite-linux-amd64.tar.gz "$WRK/f"; then
        echo "sblite-sha-no-line:FAIL"
    else
        echo "sblite-sha-no-line:OK"
    fi

    # ── Part 6: END-TO-END ELF install ─────────────────────
    CASE_LITE_BUILD=auto
    CASE_DF_KB=999999
    CASE_SUMS_MODE=good
    CORE_VERSION="1.14.1-extended-2.7.2-lite"
    place_fake_bin /usr/bin/sing-box "1.14.1" elf
    rm -f /usr/libexec/sing-box-core /etc/netshift/core-version.cache /etc/sing-box-version.cache
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .version == "1.14.1-extended-2.7.2-lite" and .build == "elf" and ((has("warning") | not))' >/dev/null 2>&1; then
        echo "sblite-e2e-elf-json:OK"
    else
        echo "sblite-e2e-elf-json:FAIL ($json)"
    fi
    v="$(/usr/bin/sing-box version 2>/dev/null | head -n1)"
    if [ "$v" = "sing-box version 1.14.1-extended-2.7.2-lite" ]; then
        echo "sblite-e2e-elf-binary:OK"
    else
        echo "sblite-e2e-elf-binary:FAIL ($v)"
    fi
    if [ ! -e /usr/libexec/sing-box-core ] && [ ! -e /etc/netshift/core-version.cache ] && [ ! -e /etc/sing-box-version.cache ]; then
        echo "sblite-e2e-elf-no-leftovers:OK"
    else
        echo "sblite-e2e-elf-no-leftovers:FAIL"
    fi

    # ── Part 7: END-TO-END UPX install ────────────────────
    CASE_LITE_BUILD=compressed
    CASE_RAM_MB=512
    : >"$CORE_MARKER"
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .build == "compressed" and ((has("warning") | not))' >/dev/null 2>&1; then
        echo "sblite-e2e-upx-json:OK"
    else
        echo "sblite-e2e-upx-json:FAIL ($json)"
    fi
    if [ -x /usr/libexec/sing-box-core ] &&
        [ "$(head -c 2 /usr/bin/sing-box 2>/dev/null)" = "#!" ] &&
        [ -s /etc/netshift/core-version.cache ]; then
        echo "sblite-e2e-upx-layout:OK"
    else
        echo "sblite-e2e-upx-layout:FAIL"
    fi
    calls="$(wc -l <"$CORE_MARKER" | tr -d ' ')"
    # the pre-check of the previous binary and the post-extract validation
    # each ran a core exactly once — nothing else may have
    if [ "$calls" = "2" ]; then
        echo "sblite-e2e-upx-validate-ran-core:OK"
    else
        echo "sblite-e2e-upx-validate-ran-core:FAIL (calls=$calls)"
    fi
    # `sing-box version` answers from the cache — the core is NOT run
    v="$(sing-box version 2>/dev/null | head -n1)"
    calls2="$(wc -l <"$CORE_MARKER" | tr -d ' ')"
    if [ "$v" = "sing-box version 1.14.1-extended-2.7.2-lite" ] && [ "$calls2" = "$calls" ]; then
        echo "sblite-e2e-upx-version-from-cache:OK"
    else
        echo "sblite-e2e-upx-version-from-cache:FAIL (v='$v' calls=$calls2 want=$calls)"
    fi
    # with the cache gone the wrapper probes once and rebuilds it
    rm -f /etc/netshift/core-version.cache
    v="$(sing-box version 2>/dev/null | head -n1)"
    calls3="$(wc -l <"$CORE_MARKER" | tr -d ' ')"
    if [ "$v" = "sing-box version 1.14.1-extended-2.7.2-lite" ] &&
        [ -s /etc/netshift/core-version.cache ] && [ "$calls3" = "$((calls + 1))" ]; then
        echo "sblite-e2e-upx-cache-rebuild:OK"
    else
        echo "sblite-e2e-upx-cache-rebuild:FAIL (v='$v' calls=$calls3 want=$((calls + 1)))"
    fi

    # auto-compressed on a tiny flash + low RAM -> warning code
    CASE_LITE_BUILD=auto
    CASE_DF_KB=1000
    CASE_RAM_MB=128
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .build == "compressed" and .warning == "upx_ram_spike"' >/dev/null 2>&1; then
        echo "sblite-e2e-upx-lowram-warning:OK"
    else
        echo "sblite-e2e-upx-lowram-warning:FAIL ($json)"
    fi
    CASE_RAM_MB=512
    CASE_DF_KB=999999

    # ── Part 8: wrong binary -> full rollback ────────────────
    # Previous state: a community manual lite install (wrapper + core +
    # caches) whose version lacks the suffix. The downloaded asset is a
    # FULL extended build (no -lite): the install must fail and restore the
    # manual layout bit for bit.
    CASE_LITE_BUILD=elf
    place_fake_bin /usr/bin/sing-box "1.14.1-extended-2.7.2" wrapper
    place_fake_bin /usr/libexec/sing-box-core "1.14.1-extended-2.7.2" elf
    printf 'manual snapshot\n' >/etc/sing-box-version.cache
    printf 'netshift snapshot\n' >/etc/netshift/core-version.cache
    CORE_VERSION="1.14.1-extended-2.7.2"
    : >"$CORE_MARKER"
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    v="$(sing-box version 2>/dev/null | head -n1)"
    if printf '%s' "$json" | jq -e '.success == false' >/dev/null 2>&1 &&
        [ "$v" = "sing-box version 1.14.1-extended-2.7.2" ] &&
        [ "$(head -c 2 /usr/bin/sing-box 2>/dev/null)" = "#!" ] &&
        [ -x /usr/libexec/sing-box-core ] &&
        grep -q 'manual snapshot' /etc/sing-box-version.cache &&
        grep -q 'netshift snapshot' /etc/netshift/core-version.cache; then
        echo "sblite-e2e-bad-version-rollback:OK"
    else
        echo "sblite-e2e-bad-version-rollback:FAIL (v='$v' json=$json)"
    fi
    CORE_VERSION="1.14.1-extended-2.7.2-lite"

    # sha mismatch: aborted BEFORE anything was touched
    CASE_SUMS_MODE=bad
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    v="$(sing-box version 2>/dev/null | head -n1)"
    if printf '%s' "$json" | jq -e '.success == false' >/dev/null 2>&1 &&
        [ "$v" = "sing-box version 1.14.1-extended-2.7.2" ] &&
        [ -x /usr/libexec/sing-box-core ]; then
        echo "sblite-e2e-sha-mismatch-aborts:OK"
    else
        echo "sblite-e2e-sha-mismatch-aborts:FAIL ($json)"
    fi
    CASE_SUMS_MODE=good

    # a release without sha256sums.txt is refused outright
    CASE_RELEASES="$LITE_RELEASES_NOSUMS"
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == false' >/dev/null 2>&1; then
        echo "sblite-e2e-no-sums-refused:OK"
    else
        echo "sblite-e2e-no-sums-refused:FAIL ($json)"
    fi
    CASE_RELEASES="$LITE_RELEASES"

    # unsupported architecture: refused, nothing touched
    CASE_UNAME=armv6l
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    v="$(sing-box version 2>/dev/null | head -n1)"
    if printf '%s' "$json" | jq -e '.success == false' >/dev/null 2>&1 &&
        [ "$v" = "sing-box version 1.14.1-extended-2.7.2" ]; then
        echo "sblite-e2e-unsupported-arch:OK"
    else
        echo "sblite-e2e-unsupported-arch:FAIL ($json)"
    fi
    CASE_UNAME=x86_64

    # ── Part 9: leaving lite for the FULL extended core cleans up ─
    json="$(_updates_install_sing_box_extended_core 2>/dev/null)"
    v="$(/usr/bin/sing-box version 2>/dev/null | head -n1)"
    if printf '%s' "$json" | jq -e '.success == true' >/dev/null 2>&1 &&
        [ "$v" = "sing-box version 1.14.1-extended-2.7.2-x86" ] &&
        [ ! -e /usr/libexec/sing-box-core ] &&
        [ ! -e /etc/netshift/core-version.cache ] &&
        [ ! -e /etc/sing-box-version.cache ]; then
        echo "sblite-leave-extended-cleans-artifacts:OK"
    else
        echo "sblite-leave-extended-cleans-artifacts:FAIL (v='$v' json=$json)"
    fi

    # ── Part 10: leaving lite for the STOCK core cleans up too ───
    # Rebuild a lite-UPX state (real install), then switch via the package
    # manager stub; the apk world + libcronet paths are isolated in $WRK.
    CASE_LITE_BUILD=compressed
    CASE_DF_KB=999999
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .build == "compressed"' >/dev/null 2>&1 &&
        [ -x /usr/libexec/sing-box-core ]; then
        echo "sblite-leave-stock-rebuild-lite:OK"
    else
        echo "sblite-leave-stock-rebuild-lite:FAIL ($json)"
    fi
    UPDATES_APK_WORLD="$WRK/apk-world"
    UPDATES_LIBCRONET_LIB="$WRK/libcronet.so"
    : >"$UPDATES_APK_WORLD"
    CASE_PKG_MODE=ok
    json="$(_updates_install_sing_box_stable_core 2>/dev/null)"
    v="$(/usr/bin/sing-box version 2>/dev/null | head -n1)"
    if printf '%s' "$json" | jq -e '.success == true' >/dev/null 2>&1 &&
        [ "$v" = "sing-box version $STOCK_CORE_VERSION" ] &&
        [ ! -e /usr/libexec/sing-box-core ] &&
        [ ! -e /etc/netshift/core-version.cache ] &&
        [ ! -e /etc/sing-box-version.cache ]; then
        echo "sblite-leave-stock-cleans-artifacts:OK"
    else
        echo "sblite-leave-stock-cleans-artifacts:FAIL (v='$v' json=$json)"
    fi

    # a FAILED stock switch restores the whole lite layout
    CASE_LITE_BUILD=compressed
    json="$(_updates_install_sing_box_lite_core 2>/dev/null)"
    CASE_PKG_MODE=fail
    json="$(_updates_install_sing_box_stable_core 2>/dev/null)"
    v="$(sing-box version 2>/dev/null | head -n1)"
    if printf '%s' "$json" | jq -e '.success == false' >/dev/null 2>&1 &&
        [ "$v" = "sing-box version 1.14.1-extended-2.7.2-lite" ] &&
        [ "$(head -c 2 /usr/bin/sing-box 2>/dev/null)" = "#!" ] &&
        [ -x /usr/libexec/sing-box-core ] &&
        [ -s /etc/netshift/core-version.cache ]; then
        echo "sblite-leave-stock-fail-restores-lite:OK"
    else
        echo "sblite-leave-stock-fail-restores-lite:FAIL (v='$v' json=$json)"
    fi
    CASE_PKG_MODE=ok

    # ── Part 11: check_update_lite ───────────────────────
    SB_VER_OVERRIDE="1.14.1-extended-2.7.2-lite"
    json="$(updates_check_sing_box_lite 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .status == "latest" and .current_version == "1.14.1-extended-2.7.2-lite" and .latest_version == "1.14.1-extended-2.7.2-lite"' >/dev/null 2>&1; then
        echo "sblite-check-latest:OK"
    else
        echo "sblite-check-latest:FAIL ($json)"
    fi
    SB_VER_OVERRIDE="1.14.1-extended-2.6.0-lite"
    json="$(updates_check_sing_box_lite 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .status == "outdated" and .current_version == "1.14.1-extended-2.6.0-lite"' >/dev/null 2>&1; then
        echo "sblite-check-outdated:OK"
    else
        echo "sblite-check-outdated:FAIL ($json)"
    fi
    # a manual install without -lite honestly shows up as outdated
    SB_VER_OVERRIDE="1.14.1-extended-2.7.2"
    json="$(updates_check_sing_box_lite 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .status == "outdated" and .current_version == "1.14.1-extended-2.7.2" and .latest_version == "1.14.1-extended-2.7.2-lite"' >/dev/null 2>&1; then
        echo "sblite-check-manual-outdated:OK"
    else
        echo "sblite-check-manual-outdated:FAIL ($json)"
    fi
    CASE_FETCH_FAIL=1
    json="$(updates_check_sing_box_lite 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == false' >/dev/null 2>&1; then
        echo "sblite-check-fetch-fail:OK"
    else
        echo "sblite-check-fetch-fail:FAIL ($json)"
    fi
    CASE_FETCH_FAIL=0
    SB_VER_OVERRIDE=""
    # sync dispatcher wiring
    SB_VER_OVERRIDE="1.14.1-extended-2.7.2-lite"
    json="$(component_action sing_box check_update_lite 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.success == true and .status == "latest"' >/dev/null 2>&1; then
        echo "sblite-check-dispatch:OK"
    else
        echo "sblite-check-dispatch:FAIL ($json)"
    fi
    SB_VER_OVERRIDE=""

    # ── Part 12: get_system_info fields (shipped bin) ─────────
    extract() {
        awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH"
    }
    eval "$(extract get_system_info)"
    NETSHIFT_VERSION="0.0.0-test"
    CASE_DF_KB=1048576
    CASE_UNAME=x86_64
    json="$(get_system_info 2>/dev/null)"
    if printf '%s' "$json" | jq -e 'has("sing_box_variant") and has("sing_box_lite_upx") and has("sing_box_lite_supported") and has("ram_total_mb") and has("flash_free_mb")' >/dev/null 2>&1; then
        echo "sblite-info-fields-present:OK"
    else
        echo "sblite-info-fields-present:FAIL ($json)"
    fi
    if printf '%s' "$json" | jq -e '.sing_box_variant == "extended_lite" and .sing_box_lite_upx == 1 and .sing_box_lite_supported == 1 and .ram_total_mb == 512 and .flash_free_mb == 1024 and .sing_box_extended == 1' >/dev/null 2>&1; then
        echo "sblite-info-values-upx:OK"
    else
        echo "sblite-info-values-upx:FAIL ($json)"
    fi
    place_fake_bin /usr/bin/sing-box "1.14.1" elf
    rm -f /usr/libexec/sing-box-core
    json="$(get_system_info 2>/dev/null)"
    if printf '%s' "$json" | jq -e '.sing_box_variant == "stock" and .sing_box_lite_upx == 0 and .sing_box_lite_supported == 1 and .sing_box_extended == 0' >/dev/null 2>&1; then
        echo "sblite-info-values-stock:OK"
    else
        echo "sblite-info-values-stock:FAIL ($json)"
    fi

    # ── Part 13: async job state carries the build flavour ──────
    CASE_LITE_BUILD=auto
    CASE_DF_KB=999999
    async_json="$(component_action_async sing_box install_extended_lite)"
    job_id="$(printf '%s' "$async_json" | jq -r '.job_id // empty')"
    if [ -z "$job_id" ]; then
        echo "sblite-async-start:FAIL ($async_json)"
    else
        echo "sblite-async-start:OK"
        waited=0
        while [ "$waited" -lt 20 ]; do
            if [ -f "$UPDATES_JOB_DIR/$job_id.json" ] &&
                jq -e '.running == false' "$UPDATES_JOB_DIR/$job_id.json" >/dev/null 2>&1; then
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        status_json="$(component_action_status "$job_id" 2>/dev/null)"
        if printf '%s' "$status_json" | jq -e '.success == true and .build == "elf" and .version == "1.14.1-extended-2.7.2-lite"' >/dev/null 2>&1; then
            echo "sblite-async-build-field:OK"
        else
            echo "sblite-async-build-field:FAIL ($status_json)"
        fi
        rm -f "$UPDATES_JOB_DIR/$job_id.json" "$UPDATES_JOB_DIR/$job_id.out" 2>/dev/null
    fi

    rm -rf "$WRK"
    echo DONE
}

real_helpers_body() {
    # The pure sourced libraries, no stubs: the RAM/flash readers must
    # produce non-negative integers from the real /proc/meminfo and df.
    local ram flash
    ram="$(get_ram_total_mb)"
    flash="$(get_flash_free_mb)"
    case "$ram:$flash" in
    *[!0-9:]* | '':* | *:'') echo "sblite-real-helpers-int:FAIL (ram='$ram' flash='$flash')" ;;
    *) echo "sblite-real-helpers-int:OK (ram=${ram}MB flash=${flash}MB)" ;;
    esac
    echo DONE
}

case "${1:-}" in
"") main_body ;;
component_action) component_action "$2" "$3" ;;
realhelpers) real_helpers_body ;;
esac
DRVEOF
    sed -i -e "s|DRV_CONSTANTS|$constants|g" \
        -e "s|DRV_HELPERS|$helpers|g" \
        -e "s|DRV_UPDATER|$updater|g" \
        -e "s|BIN_PATH|$bin|g" "$drv"
    chmod 0755 "$drv"

    sh "$drv" >"$out" 2>&1 || true
    sh "$drv" realhelpers >"$out2" 2>&1 || true

    # Restore whatever the end-to-end cases replaced, whatever happened.
    if [ -f "$work/sing-box.orig" ]; then
        cp -p "$work/sing-box.orig" /usr/bin/sing-box 2>/dev/null || true
    else
        rm -f /usr/bin/sing-box 2>/dev/null || true
    fi
    if [ -f "$work/lite-core.orig" ]; then
        cp -p "$work/lite-core.orig" /usr/libexec/sing-box-core 2>/dev/null || true
    else
        rm -f /usr/libexec/sing-box-core 2>/dev/null || true
    fi
    if [ -f "$work/core-cache.orig" ]; then
        cp -p "$work/core-cache.orig" /etc/netshift/core-version.cache 2>/dev/null || true
    else
        rm -f /etc/netshift/core-version.cache 2>/dev/null || true
    fi
    if [ -f "$work/orphan-cache.orig" ]; then
        cp -p "$work/orphan-cache.orig" /etc/sing-box-version.cache 2>/dev/null || true
    else
        rm -f /etc/sing-box-version.cache 2>/dev/null || true
    fi
    rm -rf /tmp/sblite-wrk-* /tmp/sblite-fake.* /tmp/sblite-core-calls-* 2>/dev/null

    local line saw_done=0
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done <"$out"
    if [ "$saw_done" = "1" ]; then
        pass "sblite-driver-completed"
    else
        fail "sblite-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$out" 2>/dev/null)"
    fi

    saw_done=0
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done <"$out2"
    if [ "$saw_done" = "1" ]; then
        pass "sblite-realhelpers-driver-completed"
    else
        fail "sblite-realhelpers-driver-completed:FAIL" "$(tail -5 "$out2" 2>/dev/null)"
    fi

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: NetShift update check on-demand (task-029)
# ─────────────────────────────────────────────────────────────────
# Two parts:
#  (A) STATIC: get_system_info must do NO network I/O — the GitHub curl is gone
#      and netshift_latest_version is the constant "unknown".
#  (B) updates_check_netshift version compare + v-normalization + JSON shape:
#      source updater.sh, silence logging, OVERRIDE updates_netshift_latest_tag
#      (the shared tag fetch) + set NETSHIFT_VERSION, run the check. Stub inputs:
#      STUBNS_INSTALLED = $NETSHIFT_VERSION; STUBNS_TAG = the GitHub latest tag
#      (empty → unreachable branch).
test_check_update_netshift() {
    header "NetShift Update Check — on-demand + v-prefix (task-029)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ] || [ ! -r "$bin" ]; then
        skip "updater.sh / bin not found in ${NETSHIFT_SRC}"
        return
    fi

    # ── Part A (static): get_system_info has NO live GitHub curl ────────────────
    # Extract the get_system_info function body and assert it contains no curl to
    # the releases API, and that it pins netshift_latest_version="unknown".
    local fn
    fn="$(awk '/^get_system_info\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
    if [ -n "$fn" ] \
        && ! printf '%s' "$fn" | grep -q 'releases/latest' \
        && printf '%s' "$fn" | grep -q 'netshift_latest_version="unknown"'; then
        pass "netshiftcheck-get_system_info-no-network:OK"
    else
        fail "netshiftcheck-get_system_info-no-network:FAIL" "$fn"
    fi

    local work="/tmp/netshift-netshiftcheck-$$"
    rm -rf "$work"
    mkdir -p "$work"

    # ── Part B: driver sources updater.sh + helpers.sh, silences logging,
    # overrides the shared tag fetch + NETSHIFT_VERSION, runs the check.
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
. "DRV_HELPERS"
. "DRV_UPDATER"
NETSHIFT_VERSION="$STUBNS_INSTALLED"
updates_netshift_latest_tag() { printf '%s' "$STUBNS_TAG"; }
updates_check_netshift
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_HELPERS|${NETSHIFT_LIB_DIR}/helpers.sh|g" "$drv"

    local out="$work/out.json"
    run_netshiftcheck() {
        ash "$drv" > "$out" 2>/dev/null || true
    }

    # ── Case 1: installed v0.8.6 vs latest 0.8.6 (no v) → latest (NOT outdated) ──
    export STUBNS_INSTALLED="v0.8.6"
    export STUBNS_TAG="0.8.6"
    run_netshiftcheck
    if jq -e '.success == true and .status == "latest"
            and .current_version == "v0.8.6"
            and .latest_version == "0.8.6"' "$out" > /dev/null 2>&1; then
        pass "netshiftcheck-vprefix-installed-eq-latest:OK"
    else
        fail "netshiftcheck-vprefix-installed-eq-latest:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 2: installed 0.8.5 vs latest 0.8.6 → outdated ──────────────────────
    export STUBNS_INSTALLED="0.8.5"
    export STUBNS_TAG="0.8.6"
    run_netshiftcheck
    if jq -e '.success == true and .status == "outdated"
            and .current_version == "0.8.5"
            and .latest_version == "0.8.6"' "$out" > /dev/null 2>&1; then
        pass "netshiftcheck-older-outdated:OK"
    else
        fail "netshiftcheck-older-outdated:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 3: installed v0.8.6 vs latest v0.8.6 (both v) → latest ─────────────
    export STUBNS_INSTALLED="v0.8.6"
    export STUBNS_TAG="v0.8.6"
    run_netshiftcheck
    if jq -e '.success == true and .status == "latest"' "$out" > /dev/null 2>&1; then
        pass "netshiftcheck-both-vprefix-latest:OK"
    else
        fail "netshiftcheck-both-vprefix-latest:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 4: JSON shape — keys success/current_version/latest_version/status ─
    export STUBNS_INSTALLED="0.8.5"
    export STUBNS_TAG="0.8.6"
    run_netshiftcheck
    if jq -e 'has("success") and has("current_version")
            and has("latest_version") and has("status")' "$out" > /dev/null 2>&1; then
        pass "netshiftcheck-json-shape:OK"
    else
        fail "netshiftcheck-json-shape:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 5: tag fetch failure (empty) → success:false ───────────────────────
    export STUBNS_INSTALLED="0.8.6"
    export STUBNS_TAG=""
    run_netshiftcheck
    if jq -e '.success == false and (.message | length) > 0' "$out" > /dev/null 2>&1; then
        pass "netshiftcheck-fetch-failure-successfalse:OK"
    else
        fail "netshiftcheck-fetch-failure-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    # ── Case 6: dev/unstamped build (placeholder) → latest (graceful) ───────────
    export STUBNS_INSTALLED="__COMPILED_VERSION_VARIABLE__"
    export STUBNS_TAG="0.8.6"
    run_netshiftcheck
    if jq -e '.success == true and .status == "latest"
            and .latest_version == "0.8.6"' "$out" > /dev/null 2>&1; then
        pass "netshiftcheck-dev-build-graceful:OK"
    else
        fail "netshiftcheck-dev-build-graceful:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    unset STUBNS_INSTALLED STUBNS_TAG
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: NetShift latest-tag parse — minified vs pretty JSON (task-047)
# ─────────────────────────────────────────────────────────────────
# Guards the false-"outdated" bug: updates_netshift_latest_tag used a
# field-positional grep|cut that, on MINIFIED GitHub JSON (whole object on one
# line, "url" before "tag_name"), returned the release "url" instead of the tag
# — causing a false "outdated" + a self-update that downloaded a garbage
# "version". The fix parses with jq '.tag_name // empty' (format-independent).
#
# We exercise the REAL parse: the driver sources updater.sh and stubs ONLY the
# network boundary (updates_http_get_once) with markered JSON, then calls the
# real updates_netshift_latest_tag / updates_check_netshift. No network.
test_netshift_latest_tag() {
    header "NetShift latest-tag jq parse (task-047)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-latesttag-$$"
    rm -rf "$work"
    mkdir -p "$work"

    # Driver: source helpers.sh + updater.sh, silence logging, pin constants,
    # stub the network boundary (updates_http_get_once) to emit $STUBLT_BODY,
    # then run the REAL parse function named in $STUBLT_FN.
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
updates_log() { :; }
. "DRV_HELPERS"
. "DRV_UPDATER"
NETSHIFT_RELEASE_API_URL="https://api.test/latest"
NETSHIFT_VERSION="$STUBLT_INSTALLED"
# Force the API-fallback path this test targets: the redirect resolver returns
# empty so updates_netshift_latest_tag falls back to the stubbed API body.
updates_github_resolve_redirect() { printf ''; }
updates_http_get_once() { printf '%s' "$STUBLT_BODY"; }
"$STUBLT_FN"
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_HELPERS|${NETSHIFT_LIB_DIR}/helpers.sh|g" "$drv"

    local out="$work/out.txt"
    local rc_file="$work/rc.txt"
    run_lt() {
        # The parse function returns non-zero on the rate-limit/error case; under
        # the harness `set -e` that would abort the suite, so capture rc via the
        # `|| ...` guard (assertions read $out + $rc_file, not the live rc).
        ash "$drv" > "$out" 2>/dev/null && printf '0' > "$rc_file" || printf '%s' "$?" > "$rc_file"
    }

    # The exact minified release object from the bug report: "url" BEFORE
    # "tag_name", whole object on a single line, with .../releases/338202209.
    local minified='{"url":"https://api.github.com/repos/yandexru45/netshift/releases/338202209","id":338202209,"tag_name":"0.8.8","name":"0.8.8"}'
    # Pretty-printed equivalent (one key per line).
    local pretty='{
  "url": "https://api.github.com/repos/yandexru45/netshift/releases/338202209",
  "id": 338202209,
  "tag_name": "0.8.8",
  "name": "0.8.8"
}'
    # Rate-limit/error object — no tag_name.
    local ratelimit='{"message":"API rate limit exceeded for 1.2.3.4","documentation_url":"https://docs.github.com/rest"}'

    export STUBLT_FN="updates_netshift_latest_tag"
    export STUBLT_INSTALLED="0.8.8"

    # ── Case 1 (REGRESSION GUARD): minified → exactly 0.8.8, NOT the url ──────
    export STUBLT_BODY="$minified"
    run_lt
    if [ "$(cat "$out" 2>/dev/null)" = "0.8.8" ] && [ "$(cat "$rc_file" 2>/dev/null)" = "0" ]; then
        pass "latesttag-minified-returns-tag-not-url:OK"
    else
        fail "latesttag-minified-returns-tag-not-url:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 2: pretty-printed → 0.8.8 ───────────────────────────────────────
    export STUBLT_BODY="$pretty"
    run_lt
    if [ "$(cat "$out" 2>/dev/null)" = "0.8.8" ] && [ "$(cat "$rc_file" 2>/dev/null)" = "0" ]; then
        pass "latesttag-pretty-returns-tag:OK"
    else
        fail "latesttag-pretty-returns-tag:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 3: rate-limit/error object (no tag_name) → empty + non-zero ─────
    export STUBLT_BODY="$ratelimit"
    run_lt
    if [ -z "$(cat "$out" 2>/dev/null)" ] && [ "$(cat "$rc_file" 2>/dev/null)" != "0" ]; then
        pass "latesttag-ratelimit-empty-nonzero:OK"
    else
        fail "latesttag-ratelimit-empty-nonzero:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 4 (end-to-end): minified through updates_check_netshift with
    # installed == tag → status "latest" (the false-outdated is gone). ────────
    export STUBLT_FN="updates_check_netshift"
    export STUBLT_BODY="$minified"
    export STUBLT_INSTALLED="0.8.8"
    run_lt
    if jq -e '.success == true and .status == "latest"
            and .latest_version == "0.8.8"' "$out" > /dev/null 2>&1; then
        pass "latesttag-e2e-check-minified-latest:OK"
    else
        fail "latesttag-e2e-check-minified-latest:FAIL" "$(cat "$out" 2>/dev/null)"
    fi

    unset STUBLT_FN STUBLT_BODY STUBLT_INSTALLED
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: GitHub redirect-based latest-tag + deterministic asset URLs (task-049)
# ─────────────────────────────────────────────────────────────────
# Sidestepping the api.github.com 60/hour/IP rate limit: the version-check + the
# self-update asset download now resolve github.com/<repo>/releases/latest via a
# redirect (curl -w '%{redirect_url}') → /releases/tag/<tag>, with the API + jq
# path kept only as a graceful fallback. The network boundary is STUBBED here
# (override updates_github_resolve_redirect / updates_http_get_once), so no curl
# shell-out and no real network in CI. Synthetic data only.
test_github_redirect_tag() {
    header "GitHub redirect latest-tag + asset URLs (task-049)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-ghredirect-$$"
    rm -rf "$work"
    mkdir -p "$work"

    # Driver: source helpers.sh + updater.sh, silence logging, pin the redirect
    # + API constants, OVERRIDE the redirect resolver ($STUBGR_REDIRECT) and the
    # API boundary ($STUBGR_BODY), then run the function/expr named in $STUBGR_FN.
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
updates_log() { :; }
. "DRV_HELPERS"
. "DRV_UPDATER"
NETSHIFT_REPO_RELEASES_LATEST_URL="https://github.com/yandexru45/netshift/releases/latest"
NETSHIFT_REPO_RELEASES_DOWNLOAD_BASE="https://github.com/yandexru45/netshift/releases/download"
NETSHIFT_RELEASE_API_URL="https://api.test/latest"
UPDATES_NETSHIFT_PKG_CORE="netshift"
UPDATES_NETSHIFT_PKG_LUCI="luci-app-netshift"
UPDATES_NETSHIFT_PKG_I18N_RU="luci-i18n-netshift-ru"
updates_github_resolve_redirect() { printf '%s' "$STUBGR_REDIRECT"; }
updates_http_get_once() { printf '%s' "$STUBGR_BODY"; }
eval "$STUBGR_FN"
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_HELPERS|${NETSHIFT_LIB_DIR}/helpers.sh|g" "$drv"

    local out="$work/out.txt"
    local rc_file="$work/rc.txt"
    run_gr() {
        ash "$drv" > "$out" 2>/dev/null && printf '0' > "$rc_file" || printf '%s' "$?" > "$rc_file"
    }

    export STUBGR_FN="updates_netshift_latest_tag"
    export STUBGR_REDIRECT=""
    export STUBGR_BODY=""

    # ── Case 1: clean redirect → tag 0.8.9 (primary path, no API) ────────────
    export STUBGR_REDIRECT="https://github.com/yandexru45/netshift/releases/tag/0.8.9"
    export STUBGR_BODY=""
    run_gr
    if [ "$(cat "$out" 2>/dev/null)" = "0.8.9" ] && [ "$(cat "$rc_file" 2>/dev/null)" = "0" ]; then
        pass "ghredirect:tag-from-redirect:OK"
    else
        fail "ghredirect:tag-from-redirect:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 2: trailing-slash redirect → parse rejects (slash) → falls back ──
    # A trailing slash makes the stripped tag contain "/", which the guard
    # rejects; with NO API body it then yields empty + non-zero.
    export STUBGR_REDIRECT="https://github.com/yandexru45/netshift/releases/tag/0.8.9/"
    export STUBGR_BODY=""
    run_gr
    if [ -z "$(cat "$out" 2>/dev/null)" ] && [ "$(cat "$rc_file" 2>/dev/null)" != "0" ]; then
        pass "ghredirect:tag-trailing-slash-rejected:OK"
    else
        fail "ghredirect:tag-trailing-slash-rejected:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 3: non-matching redirect (login page) → primary empty → API
    # FALLBACK returns the release object → still yields the tag. ─────────────
    export STUBGR_REDIRECT="https://github.com/login?return_to=%2Fyandexru45%2Fnetshift"
    export STUBGR_BODY='{"url":"https://api.github.com/repos/yandexru45/netshift/releases/1","tag_name":"0.8.9"}'
    run_gr
    if [ "$(cat "$out" 2>/dev/null)" = "0.8.9" ] && [ "$(cat "$rc_file" 2>/dev/null)" = "0" ]; then
        pass "ghredirect:nonmatch-falls-back:OK"
    else
        fail "ghredirect:nonmatch-falls-back:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 4: curl-absent (resolver empty) + API rate-limit object → empty +
    # non-zero (honest failure, no false tag). ───────────────────────────────
    export STUBGR_REDIRECT=""
    export STUBGR_BODY='{"message":"API rate limit exceeded for 1.2.3.4"}'
    run_gr
    if [ -z "$(cat "$out" 2>/dev/null)" ] && [ "$(cat "$rc_file" 2>/dev/null)" != "0" ]; then
        pass "ghredirect:ratelimit-empty:OK"
    else
        fail "ghredirect:ratelimit-empty:FAIL" "got=[$(cat "$out" 2>/dev/null)] rc=$(cat "$rc_file" 2>/dev/null)"
    fi

    # ── Case 5: asset-URL builder, ipk → deterministic names ─────────────────
    export STUBGR_REDIRECT=""
    export STUBGR_BODY=""
    export STUBGR_FN='c="$(updates_netshift_asset_filename netshift 0.8.9 ipk)"; l="$(updates_netshift_asset_filename luci-app-netshift 0.8.9 ipk)"; i="$(updates_netshift_asset_filename luci-i18n-netshift-ru 0.8.9 ipk)"; printf "%s\n%s\n%s\n" "$c" "$l" "$i"'
    run_gr
    if [ "$(sed -n 1p "$out" 2>/dev/null)" = "netshift-0.8.9-r1-all.ipk" ] &&
        [ "$(sed -n 2p "$out" 2>/dev/null)" = "luci-app-netshift-0.8.9-r1-all.ipk" ] &&
        [ "$(sed -n 3p "$out" 2>/dev/null)" = "luci-i18n-netshift-ru-0.8.9.ipk" ]; then
        pass "ghredirect:asset-ipk:OK"
    else
        fail "ghredirect:asset-ipk:FAIL" "got=[$(cat "$out" 2>/dev/null)]"
    fi

    # ── Case 6: asset-URL builder, apk → deterministic names ─────────────────
    export STUBGR_FN='c="$(updates_netshift_asset_filename netshift 0.8.9 apk)"; l="$(updates_netshift_asset_filename luci-app-netshift 0.8.9 apk)"; i="$(updates_netshift_asset_filename luci-i18n-netshift-ru 0.8.9 apk)"; printf "%s\n%s\n%s\n" "$c" "$l" "$i"'
    run_gr
    if [ "$(sed -n 1p "$out" 2>/dev/null)" = "netshift-0.8.9-r1.apk" ] &&
        [ "$(sed -n 2p "$out" 2>/dev/null)" = "luci-app-netshift-0.8.9-r1.apk" ] &&
        [ "$(sed -n 3p "$out" 2>/dev/null)" = "luci-i18n-netshift-ru-0.8.9.apk" ]; then
        pass "ghredirect:asset-apk:OK"
    else
        fail "ghredirect:asset-apk:FAIL" "got=[$(cat "$out" 2>/dev/null)]"
    fi

    unset STUBGR_FN STUBGR_REDIRECT STUBGR_BODY
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: NetShift self-update (task-017)
# ─────────────────────────────────────────────────────────────────
# Exercises updates_self_update_netshift (public wrapper + private core) through
# the real sourced updater.sh. Connectivity probes (dig/curl) + the GitHub fetch
# + the asset download + the package install are all stubbed; the heal flags are
# re-pinned to temp paths and a fake /etc/init.d/netshift (absolute path) is
# written+restored. Asserts the anti-brick contract:
#   * connectivity-fail  -> aborts BEFORE any change, restore ran, success:false
#   * download-fail      -> success:false, restore ran, config backup intact
#   * happy path         -> success:true with version, restore ran
# Uses the task-009 `... || true` set -e guard (worker returns non-zero on a
# recoverable failure; assertions read JSON/file-state, not rc).
test_self_update_netshift() {
    header "NetShift Self-Update (task-017)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-selfupdate-$$"
    rm -rf "$work"
    mkdir -p "$work/bin" "$work/init"

    # Connectivity probes (dig/curl), keyed off markers like test_selfheal.
    cat > "$work/bin/dig" << 'DIGEOF'
#!/bin/sh
[ -f "$SU_DNS_OK" ] && { echo "1.2.3.4"; exit 0; }
exit 1
DIGEOF
    cat > "$work/bin/curl" << 'CURLEOF'
#!/bin/sh
[ -f "$SU_HTTP_OK" ] && exit 0
exit 1
CURLEOF
    # Fake opkg: `install <file>` succeeds per marker and records the install.
    # `list-installed` cats $SU_INSTALLED_LIST (the AUTHORITATIVE installed set).
    # On a REAL (non-no-op) install the install arm rewrites the netshift line in
    # that list to the target version (SU_TARGET_INSTALLED_VER), so the
    # verify-after-install belt sees the upgrade. When $SU_NOOP is set the install
    # arm returns rc=0 but does NOT touch the list (simulates opkg "Not
    # downgrading"/"already installed"), so list-installed keeps reporting the OLD
    # version. opkg ignores the extra --force-* flags the production code now
    # passes (they come before the file path).
    cat > "$work/bin/opkg" << 'OPKGEOF'
#!/bin/sh
case "$1" in
update) exit 0 ;;
list-installed) cat "$SU_INSTALLED_LIST" 2>/dev/null; exit 0 ;;
install)
    shift
    # Skip the leading --force-* flags so $1 is the package file path.
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --*) shift ;;
        *) break ;;
        esac
    done
    printf '%s\n' "$1" >> "$SU_INSTALL_LOG"
    [ -f "$SU_PKG_OK" ] || exit 1
    # A real success updates the installed list to the target version for the
    # core package, UNLESS we are simulating a no-op ($SU_NOOP set).
    if [ -z "$SU_NOOP" ]; then
        case "$1" in
        *netshift-* | *netshift_*)
            # Only the core "netshift" file, not luci-app-/luci-i18n- ones.
            case "$1" in
            *luci-* ) : ;;
            *)
                grep -v '^netshift ' "$SU_INSTALLED_LIST" 2>/dev/null > "$SU_INSTALLED_LIST.tmp"
                printf 'netshift - %s\n' "$SU_TARGET_INSTALLED_VER" >> "$SU_INSTALLED_LIST.tmp"
                mv "$SU_INSTALLED_LIST.tmp" "$SU_INSTALLED_LIST"
                ;;
            esac
            ;;
        esac
    fi
    exit 0
    ;;
esac
exit 0
OPKGEOF
    chmod 0755 "$work/bin/dig" "$work/bin/curl" "$work/bin/opkg"

    # Fake /etc/init.d/netshift: records stop/start/restart (used by self-heal
    # teardown/bring-up). We never re-exec /usr/bin/netshift here.
    cat > "$work/init/netshift" << 'INITEOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SU_INIT_LOG"
exit 0
INITEOF
    chmod 0755 "$work/init/netshift"

    # Driver: source updater.sh, re-pin heal/connectivity paths + constants,
    # stub the GitHub fetch + download with markers, run the public wrapper.
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
updates_log() { :; }
RESOLV_CONF="DRV_RESOLV"
UPDATES_RESOLV_BACKUP="DRV_BACKUP"
UPDATES_FEED_PROBE_HOST="feeds.test"
UPDATES_GITHUB_PROBE_HOST="github.test"
UPDATES_HEAL_RESOLVERS="1.1.1.1 9.9.9.9"
NETSHIFT_VERSION="0.8.0"
NETSHIFT_CONFIG="DRV_CONFIG"
NETSHIFT_RELEASE_API_URL="https://api.test/latest"
UPDATES_NETSHIFT_DOWNLOAD_DIR="DRV_DLDIR"
UPDATES_NETSHIFT_CONFIG_BACKUP="DRV_CFGBAK"
UPDATES_NETSHIFT_PKG_CORE="netshift"
UPDATES_NETSHIFT_PKG_LUCI="luci-app-netshift"
UPDATES_NETSHIFT_PKG_I18N_RU="luci-i18n-netshift-ru"
. "DRV_UPDATER"
# Re-pin after sourcing.
RESOLV_CONF="DRV_RESOLV"
UPDATES_RESOLV_BACKUP="DRV_BACKUP"
UPDATES_FEED_PROBE_HOST="feeds.test"
UPDATES_GITHUB_PROBE_HOST="github.test"
UPDATES_HEAL_RESOLVERS="1.1.1.1 9.9.9.9"
NETSHIFT_VERSION="0.8.0"
NETSHIFT_CONFIG="DRV_CONFIG"
NETSHIFT_RELEASE_API_URL="https://api.test/latest"
UPDATES_NETSHIFT_DOWNLOAD_DIR="DRV_DLDIR"
UPDATES_NETSHIFT_CONFIG_BACKUP="DRV_CFGBAK"
UPDATES_NETSHIFT_PKG_CORE="netshift"
UPDATES_NETSHIFT_PKG_LUCI="luci-app-netshift"
UPDATES_NETSHIFT_PKG_I18N_RU="luci-i18n-netshift-ru"

# Stub the GitHub latest-release fetch: emit a tiny JSON with a tag and asset
# URLs only when the marker says GitHub is reachable for the fetch.
updates_http_get_once() {
    [ -f "$SU_GH_OK" ] || return 1
    cat <<JSON
{"tag_name":"$SU_LATEST_TAG",
 "assets":[
   {"browser_download_url":"https://dl.test/netshift-$SU_LATEST_TAG.ipk"},
   {"browser_download_url":"https://dl.test/luci-app-netshift-$SU_LATEST_TAG.ipk"},
   {"browser_download_url":"https://dl.test/luci-i18n-netshift-ru-$SU_LATEST_TAG.ipk"}
 ]}
JSON
}
# Stub the asset download: write a non-empty file only when the marker is set.
updates_download_to_file() {
    [ -f "$SU_DL_OK" ] || return 1
    printf 'pkg-bytes\n' > "$2"
    [ -s "$2" ]
}

updates_self_update_netshift
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_RESOLV|$work/resolv.conf|g;s|DRV_BACKUP|$work/resolv.bak|g;s|DRV_CONFIG|$work/etc-config-netshift|g;s|DRV_DLDIR|$work/dl|g;s|DRV_CFGBAK|$work/config.bak|g" "$drv"

    # Install the fake /etc/init.d/netshift (write+restore the real one).
    local init_target="/etc/init.d/netshift"
    local init_saved=""
    if [ -e "$init_target" ]; then
        init_saved="$work/netshift.realinit"
        cp -p "$init_target" "$init_saved" 2>/dev/null || init_saved=""
    fi
    mkdir -p /etc/init.d 2>/dev/null || true
    cp -p "$work/init/netshift" "$init_target" 2>/dev/null
    chmod 0755 "$init_target" 2>/dev/null || true

    export SU_DNS_OK="$work/dns_ok"
    export SU_HTTP_OK="$work/http_ok"
    export SU_GH_OK="$work/gh_ok"
    export SU_DL_OK="$work/dl_ok"
    export SU_PKG_OK="$work/pkg_ok"
    export SU_INIT_LOG="$work/init.log"
    export SU_INSTALL_LOG="$work/install.log"
    export SU_INSTALLED_LIST="$work/installed.list"
    export SU_LATEST_TAG="0.8.1"
    # Version the fake opkg writes for "netshift" after a REAL (non-no-op)
    # install, so the verify-after-install belt (task-041) sees the upgrade.
    export SU_TARGET_INSTALLED_VER="0.8.1-r1"

    local out="$work/out.json"
    run_scenario() {
        rm -f "$work/init.log" "$work/install.log"
        PATH="$work/bin:/usr/bin:/bin" ash "$drv" > "$out" 2>/dev/null || true
    }

    # RU i18n NOT installed (so it is never downloaded/installed). The installed
    # list starts with the OLD core version; a real install rewrites it.
    printf 'netshift - 0.8.0-r1\n' > "$work/installed.list"

    # ── Scenario 1: connectivity fails → abort BEFORE any change ──────────────
    rm -f "$SU_DNS_OK" "$SU_HTTP_OK" "$SU_GH_OK" "$SU_DL_OK" "$SU_PKG_OK"
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    printf 'original-resolver\n' > "$work/resolv.conf"
    run_scenario
    if jq -e '.success == false and (.message | length) > 0' "$out" > /dev/null 2>&1; then
        pass "selfupdate-connfail-aborts-successfalse:OK"
    else
        fail "selfupdate-connfail-aborts-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # No install attempted (aborted before the core).
    if [ ! -f "$work/install.log" ]; then
        pass "selfupdate-connfail-no-install:OK"
    else
        fail "selfupdate-connfail-no-install:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi
    # Epilogue restored the original resolv.conf (heal may have replaced it).
    if [ "$(cat "$work/resolv.conf" 2>/dev/null)" = "original-resolver" ]; then
        pass "selfupdate-connfail-resolv-restored:OK"
    else
        fail "selfupdate-connfail-resolv-restored:FAIL" "$(cat "$work/resolv.conf" 2>/dev/null)"
    fi

    # ── Scenario 2: download fails → success:false, config backup intact ──────
    : > "$SU_DNS_OK"; : > "$SU_HTTP_OK"; : > "$SU_GH_OK"
    rm -f "$SU_DL_OK" "$SU_PKG_OK"
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    printf 'original-resolver\n' > "$work/resolv.conf"
    run_scenario
    if jq -e '.success == false' "$out" > /dev/null 2>&1; then
        pass "selfupdate-dlfail-successfalse:OK"
    else
        fail "selfupdate-dlfail-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # No package install ran (download failed first).
    if [ ! -f "$work/install.log" ]; then
        pass "selfupdate-dlfail-no-install:OK"
    else
        fail "selfupdate-dlfail-no-install:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi
    # /etc/config/netshift untouched (download failed before any install).
    if [ "$(cat "$work/etc-config-netshift" 2>/dev/null)" = "CONFIG-ORIG" ]; then
        pass "selfupdate-dlfail-config-intact:OK"
    else
        fail "selfupdate-dlfail-config-intact:FAIL" "$(cat "$work/etc-config-netshift" 2>/dev/null)"
    fi

    # ── Scenario 3: happy path → success:true with version, restore ran ───────
    # The fake opkg rewrites the installed list to the target after a real
    # install, so the task-041 verify-after-install belt confirms the upgrade.
    : > "$SU_DNS_OK"; : > "$SU_HTTP_OK"; : > "$SU_GH_OK"; : > "$SU_DL_OK"; : > "$SU_PKG_OK"
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    printf 'original-resolver\n' > "$work/resolv.conf"
    printf 'netshift - 0.8.0-r1\n' > "$work/installed.list"
    run_scenario
    if jq -e '.success == true and .version == "0.8.1"' "$out" > /dev/null 2>&1; then
        pass "selfupdate-happy-successtrue-version:OK"
    else
        fail "selfupdate-happy-successtrue-version:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # Core + LuCI installed; RU i18n NOT (not installed) → exactly 2 installs.
    if [ -f "$work/install.log" ] && [ "$(grep -c . "$work/install.log" 2>/dev/null)" = "2" ] \
            && ! grep -q 'i18n' "$work/install.log" 2>/dev/null; then
        pass "selfupdate-happy-core-luci-installed-no-ru:OK"
    else
        fail "selfupdate-happy-core-luci-installed-no-ru:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi
    # Connectivity was fine → no teardown → resolv.conf untouched original.
    if [ "$(cat "$work/resolv.conf" 2>/dev/null)" = "original-resolver" ]; then
        pass "selfupdate-happy-resolv-untouched:OK"
    else
        fail "selfupdate-happy-resolv-untouched:FAIL" "$(cat "$work/resolv.conf" 2>/dev/null)"
    fi
    # Success cleanup: the download dir is removed.
    if [ ! -d "$work/dl" ]; then
        pass "selfupdate-happy-download-dir-cleaned:OK"
    else
        fail "selfupdate-happy-download-dir-cleaned:FAIL" "dl dir remains"
    fi

    # ── Scenario 4: already up to date (idempotent) → success:true, no install
    : > "$SU_DNS_OK"; : > "$SU_HTTP_OK"; : > "$SU_GH_OK"; : > "$SU_DL_OK"; : > "$SU_PKG_OK"
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    export SU_LATEST_TAG="0.8.0"   # equals the pinned NETSHIFT_VERSION
    run_scenario
    export SU_LATEST_TAG="0.8.1"
    if jq -e '.success == true and (.message | contains("up to date"))' "$out" > /dev/null 2>&1; then
        pass "selfupdate-already-current-idempotent:OK"
    else
        fail "selfupdate-already-current-idempotent:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if [ ! -f "$work/install.log" ]; then
        pass "selfupdate-already-current-no-install:OK"
    else
        fail "selfupdate-already-current-no-install:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi

    # ── Scenario 5: RU i18n IS installed → it is upgraded too (3 installs) ─────
    : > "$SU_DNS_OK"; : > "$SU_HTTP_OK"; : > "$SU_GH_OK"; : > "$SU_DL_OK"; : > "$SU_PKG_OK"
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    printf 'netshift - 0.8.0-r1\nluci-i18n-netshift-ru - 0.8.0\n' > "$work/installed.list"
    run_scenario
    if [ -f "$work/install.log" ] && [ "$(grep -c . "$work/install.log" 2>/dev/null)" = "3" ] \
            && grep -q 'i18n' "$work/install.log" 2>/dev/null; then
        pass "selfupdate-ru-installed-upgraded:OK"
    else
        fail "selfupdate-ru-installed-upgraded:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi

    # ── Scenario 6: opkg silent no-op (task-041) → success:false, config intact
    # All connectivity/GitHub/download/PKG markers "ok" AND the install returns
    # rc=0, but $SU_NOOP makes the fake opkg NOT change what list-installed
    # reports (the core stays at the OLD version) — simulating opkg "Not
    # downgrading"/"already installed". The verify-after-install belt must catch
    # this and report success:false WITHOUT touching the config.
    : > "$SU_DNS_OK"; : > "$SU_HTTP_OK"; : > "$SU_GH_OK"; : > "$SU_DL_OK"; : > "$SU_PKG_OK"
    export SU_NOOP=1
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    printf 'original-resolver\n' > "$work/resolv.conf"
    printf 'netshift - 0.8.0-r1\n' > "$work/installed.list"
    run_scenario
    unset SU_NOOP
    # The worker MUST report success:false (the silent no-op is detected), NOT
    # the false "updated" success it used to emit on rc=0.
    if jq -e '.success == false' "$out" > /dev/null 2>&1; then
        pass "selfupdate-noop-detected-successfalse:OK"
    else
        fail "selfupdate-noop-detected-successfalse:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    # The install was ATTEMPTED (rc=0) but the version never changed.
    if [ -f "$work/install.log" ] && grep -q . "$work/install.log" 2>/dev/null; then
        pass "selfupdate-noop-install-attempted:OK"
    else
        fail "selfupdate-noop-install-attempted:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi
    # Configuration preserved (verify-fail runs the defensive restore; nothing
    # clobbered the live file).
    if [ "$(cat "$work/etc-config-netshift" 2>/dev/null)" = "CONFIG-ORIG" ]; then
        pass "selfupdate-noop-config-intact:OK"
    else
        fail "selfupdate-noop-config-intact:FAIL" "$(cat "$work/etc-config-netshift" 2>/dev/null)"
    fi
    # Download dir cleaned even on the no-op failure path.
    if [ ! -d "$work/dl" ]; then
        pass "selfupdate-noop-download-dir-cleaned:OK"
    else
        fail "selfupdate-noop-download-dir-cleaned:FAIL" "dl dir remains"
    fi

    : > "$work/installed.list"

    # ── Restore the real init script (if any) and clean up. ──────────────────
    if [ -n "$init_saved" ] && [ -e "$init_saved" ]; then
        cp -p "$init_saved" "$init_target" 2>/dev/null || true
    else
        rm -f "$init_target" 2>/dev/null || true
    fi
    unset SU_DNS_OK SU_HTTP_OK SU_GH_OK SU_DL_OK SU_PKG_OK SU_INIT_LOG \
        SU_INSTALL_LOG SU_INSTALLED_LIST SU_LATEST_TAG SU_TARGET_INSTALLED_VER SU_NOOP
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: core-swap backup integrity (task-027)
# ─────────────────────────────────────────────────────────────────
# Guards the on-hardware latent bug where a TRUNCATED tmpfs backup (busybox cp
# under ENOSPC) could be restored over /usr/bin/sing-box, installing a
# segfaulting core as the "safe" fallback. Drives the REAL sourced updater.sh:
#   * updates_verify_copy        — size-match gate used right after the backup cp.
#   * updates_backup_is_complete — size-match gate used before every rollback.
#   * updates_stable_rollback    — must REFUSE to overwrite the live binary from
#                                  a truncated backup (and DO restore a complete
#                                  one), with UPDATES_SING_BOX_BIN pointed at a
#                                  temp file so the container's real binary is
#                                  never touched.
# Asserts: (a) complete backup verifies OK; (b) truncated/missing backup is
# detected (verify nonzero); (c) rollback does not clobber the live path from a
# truncated backup but still restores from a complete one.
test_backup_integrity() {
    header "Core-swap Backup Integrity (task-027)"

    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$updater" ]; then
        skip "updater.sh not found in ${NETSHIFT_LIB_DIR}"
        return
    fi

    local work="/tmp/netshift-backupguard-$$"
    rm -rf "$work"
    mkdir -p "$work"

    # Driver: source updater.sh, silence logging, re-pin the live-binary paths to
    # temp files, then run the verify helpers + the rollback guard. Each check
    # echoes a name:OK / name:FAIL token. The driver runs to a result file which
    # we parse in the CURRENT shell (no pipe) so the PASS/FAIL counters are exact.
    local drv="$work/driver.sh"
    cat > "$drv" << 'DRVEOF'
log() { :; }
echolog() { :; }
nolog() { :; }
updates_log() { :; }
. "DRV_UPDATER"
updates_log() { :; }

W="DRV_WORK"

# Fixtures: a "source" of 64 bytes, a COMPLETE copy, a TRUNCATED copy.
src="$W/src.bin"
complete="$W/complete.backup"
truncated="$W/truncated.backup"
dd if=/dev/zero of="$src" bs=1 count=64 >/dev/null 2>&1
cp -p "$src" "$complete"
dd if=/dev/zero of="$truncated" bs=1 count=10 >/dev/null 2>&1

# ── (a) a complete backup verifies OK ──────────────────────────────────────
if updates_verify_copy "$src" "$complete"; then
    echo 'backupguard-verify-complete-ok:OK'
else
    echo 'backupguard-verify-complete-ok:FAIL'
fi

# ── (b1) a truncated backup is detected (verify nonzero) ────────────────────
if updates_verify_copy "$src" "$truncated"; then
    echo 'backupguard-verify-truncated-detected:FAIL'
else
    echo 'backupguard-verify-truncated-detected:OK'
fi

# ── (b2) a missing backup is detected (verify nonzero) ──────────────────────
if updates_verify_copy "$src" "$W/does-not-exist.backup"; then
    echo 'backupguard-verify-missing-detected:FAIL'
else
    echo 'backupguard-verify-missing-detected:OK'
fi

# ── (b3) absent source = nothing to back up = trivially OK ──────────────────
if updates_verify_copy "$W/no-source" "$W/no-dst"; then
    echo 'backupguard-verify-absent-source-ok:OK'
else
    echo 'backupguard-verify-absent-source-ok:FAIL'
fi

# ── backup-is-complete: size match / mismatch / missing ─────────────────────
sz=$(wc -c < "$src")
if updates_backup_is_complete "$complete" "$sz"; then
    echo 'backupguard-iscomplete-match:OK'
else
    echo 'backupguard-iscomplete-match:FAIL'
fi
if updates_backup_is_complete "$truncated" "$sz"; then
    echo 'backupguard-iscomplete-mismatch:FAIL'
else
    echo 'backupguard-iscomplete-mismatch:OK'
fi
if updates_backup_is_complete "$W/does-not-exist.backup" "$sz"; then
    echo 'backupguard-iscomplete-missing:FAIL'
else
    echo 'backupguard-iscomplete-missing:OK'
fi

# ── (c) updates_stable_rollback must NOT clobber the live path from a
#       TRUNCATED backup; it MUST restore from a COMPLETE one. ───────────────
# Point the live paths at temp files holding a known-good "current" core so we
# can detect whether the rollback overwrote them.
UPDATES_SING_BOX_BIN="$W/live-sing-box"
UPDATES_LIBCRONET_LIB="$W/live-libcronet.so"

# --- truncated backup: rollback must REFUSE (live core left intact) ---
printf 'LIVE-GOOD-CORE-INTACT-MARKER\n' > "$UPDATES_SING_BOX_BIN"
trunc_backup="$W/rb-trunc.backup"
dd if=/dev/zero of="$trunc_backup" bs=1 count=10 >/dev/null 2>&1
# Record an expected size (64) that does NOT match the 10-byte truncated backup.
updates_stable_rollback "$trunc_backup" "" "64" ""
if grep -q 'LIVE-GOOD-CORE-INTACT-MARKER' "$UPDATES_SING_BOX_BIN" 2>/dev/null; then
    echo 'backupguard-rollback-refuses-truncated:OK'
else
    echo 'backupguard-rollback-refuses-truncated:FAIL'
fi
# The truncated backup must NOT have been moved into place either.
if [ -f "$trunc_backup" ]; then
    echo 'backupguard-rollback-truncated-not-moved:OK'
else
    echo 'backupguard-rollback-truncated-not-moved:FAIL'
fi

# --- complete backup: rollback MUST restore it over the live path ---
printf 'STALE-HALF-WRITTEN\n' > "$UPDATES_SING_BOX_BIN"
good_backup="$W/rb-good.backup"
printf 'RESTORED-PREVIOUS-GOOD-CORE\n' > "$good_backup"
good_sz=$(wc -c < "$good_backup")
updates_stable_rollback "$good_backup" "" "$good_sz" ""
if grep -q 'RESTORED-PREVIOUS-GOOD-CORE' "$UPDATES_SING_BOX_BIN" 2>/dev/null; then
    echo 'backupguard-rollback-restores-complete:OK'
else
    echo 'backupguard-rollback-restores-complete:FAIL'
fi
DRVEOF
    sed -i "s|DRV_UPDATER|$updater|g;s|DRV_WORK|$work|g" "$drv"

    local out="$work/out.txt"
    ash "$drv" > "$out" 2>/dev/null || true

    local line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL*) fail "$line" "$(cat "$out" 2>/dev/null)" ;;
        esac
    done < "$out"

    rm -rf "$work"
}

test_hot_reload() {
    header "Subscription Update Without NetShift Restart (sing-box SIGHUP)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$bin" ] || [ ! -r "$lib/rulesets.sh" ] || \
        [ ! -r "$lib/sing_box_config_manager.sh" ] || [ ! -r "$lib/helpers.jq" ]; then
        skip "netshift bin / rulesets.sh / sing_box_config_manager.sh / helpers.jq not found"
        return
    fi

    # The config manager imports helpers.jq from /usr/lib/netshift.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.jq" /usr/lib/netshift/helpers.jq

    local drv="/tmp/netshift-hotreload-$$.sh"
    local out="/tmp/netshift-hotreload-$$.out"
    cat > "$drv" << 'HREOF'
log() { :; }
echolog() { :; }
nolog() { :; }

. "LIB_DIR/constants.sh"
. "LIB_DIR/helpers.sh"
. "LIB_DIR/rulesets.sh"
. "LIB_DIR/sing_box_config_manager.sh"

# Functions under test come VERBATIM from the shipped bin.
extract() {
    awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH"
}

HR_DIR="/tmp/netshift-hotreload-state-$$"
rm -rf "$HR_DIR"
mkdir -p "$HR_DIR"

# ── prepare_source_ruleset: local rule sets survive a rebuild ──────────
# A full restart wipes TMP_RULESET_FOLDER before the config is generated, but a
# rebuild without a restart finds the rule-set files of the running sing-box.
# The rule set must still be referenced by the new config, and a tag prepared
# twice in one build (several plain remote lists) must be added only once.
eval "$(extract rule_references_ruleset)"
eval "$(extract prepare_source_ruleset)"

TMP_RULESET_FOLDER="$HR_DIR/rulesets"
mkdir -p "$TMP_RULESET_FOLDER"
ud_path="$TMP_RULESET_FOLDER/main-user-domains-ruleset.json"
rd_path="$TMP_RULESET_FOLDER/main-remote-domains-ruleset.json"

base_config() {
    config='{"route":{"rules":[],"rule_set":[]},"dns":{"rules":[]}}'
    config=$(sing_box_cm_add_route_rule "$config" "main-route-rule" "tproxy-in" "main-out")
    config=$(sing_box_cm_add_dns_route_rule "$config" "fakeip-server" "$SB_FAKEIP_DNS_RULE_TAG")
}
rule_set_defs() {
    printf '%s' "$config" | jq --arg t "$1" '[.route.rule_set[] | select(.tag == $t)] | length'
}
rule_set_path() {
    printf '%s' "$config" | jq -r --arg t "$1" '.route.rule_set[] | select(.tag == $t) | .path'
}
route_refs() {
    printf '%s' "$config" | jq --arg t "$1" '[.route.rules[] | select(.__service_tag == "main-route-rule")
        | (.rule_set // []) | if type == "array" then .[] else . end | select(. == $t)] | length'
}
route_refs_in() {
    printf '%s' "$config" | jq --arg r "$1" --arg t "$2" '[.route.rules[] | select(.__service_tag == $r)
        | (.rule_set // []) | if type == "array" then .[] else . end | select(. == $t)] | length'
}
dns_refs() {
    printf '%s' "$config" | jq --arg t "$1" '[.dns.rules[] | select(.__service_tag == "fakeip-dns-rule-tag")
        | (.rule_set // []) | if type == "array" then .[] else . end | select(. == $t)] | length'
}

# CASE P1: fresh build, no file yet -> file created, rule set referenced once.
rm -f "$ud_path"
base_config
prepare_source_ruleset "main" "user" "domains" "main-route-rule"
if [ "$(rule_set_defs main-user-domains-ruleset)" = "1" ] && \
    [ "$(rule_set_path main-user-domains-ruleset)" = "$ud_path" ] && \
    [ "$(route_refs main-user-domains-ruleset)" = "1" ] && \
    [ "$(dns_refs main-user-domains-ruleset)" = "1" ] && \
    [ "$(jq -c . "$ud_path" 2>/dev/null)" = '{"version":3,"rules":[]}' ]; then
    echo 'hr-prepare-fresh-file-referenced:OK'
else
    echo "hr-prepare-fresh-file-referenced(defs=$(rule_set_defs main-user-domains-ruleset) route=$(route_refs main-user-domains-ruleset) dns=$(dns_refs main-user-domains-ruleset)):FAIL"
fi

# CASE P2: rebuild while the rule-set file already exists -> still referenced.
#          A `user` rule set is refilled from UCI right after this call and the
#          patches only ever add, so the stale file must NOT be reused: a domain
#          the user just removed would otherwise survive in the running config
#          until the next full restart.
printf '%s' '{"version":3,"rules":[{"domain_suffix":["example.com"]}]}' > "$ud_path"
base_config
prepare_source_ruleset "main" "user" "domains" "main-route-rule"
if [ "$(rule_set_defs main-user-domains-ruleset)" = "1" ] && \
    [ "$(route_refs main-user-domains-ruleset)" = "1" ] && \
    [ "$(dns_refs main-user-domains-ruleset)" = "1" ]; then
    echo 'hr-prepare-existing-file-referenced:OK'
else
    echo "hr-prepare-existing-file-referenced(defs=$(rule_set_defs main-user-domains-ruleset) route=$(route_refs main-user-domains-ruleset) dns=$(dns_refs main-user-domains-ruleset)):FAIL"
fi
if [ "$(jq -c . "$ud_path" 2>/dev/null)" = '{"version":3,"rules":[]}' ]; then
    echo 'hr-prepare-user-file-rebuilt:OK'
else
    echo "hr-prepare-user-file-rebuilt(got '$(cat "$ud_path" 2>/dev/null)'):FAIL"
fi

# CASE P2b: the same for a `local` rule set, whose content comes from the local
#           list files and is re-imported right after this call.
ld_path="$TMP_RULESET_FOLDER/main-local-domains-ruleset.json"
printf '%s' '{"version":3,"rules":[{"domain_suffix":["stale.example"]}]}' > "$ld_path"
base_config
prepare_source_ruleset "main" "local" "domains" "main-route-rule"
if [ "$(jq -c . "$ld_path" 2>/dev/null)" = '{"version":3,"rules":[]}' ] && \
    [ "$(route_refs main-local-domains-ruleset)" = "1" ]; then
    echo 'hr-prepare-local-file-rebuilt:OK'
else
    echo "hr-prepare-local-file-rebuilt(got '$(cat "$ld_path" 2>/dev/null)' route=$(route_refs main-local-domains-ruleset)):FAIL"
fi

# CASE P3: the same tag prepared twice in one fresh build -> one definition.
rm -f "$rd_path"
base_config
prepare_source_ruleset "main" "remote" "domains" "main-route-rule"
prepare_source_ruleset "main" "remote" "domains" "main-route-rule"
if [ "$(rule_set_defs main-remote-domains-ruleset)" = "1" ] && \
    [ "$(route_refs main-remote-domains-ruleset)" = "1" ] && \
    [ "$(dns_refs main-remote-domains-ruleset)" = "1" ]; then
    echo 'hr-prepare-same-tag-fresh-once:OK'
else
    echo "hr-prepare-same-tag-fresh-once(defs=$(rule_set_defs main-remote-domains-ruleset) route=$(route_refs main-remote-domains-ruleset)):FAIL"
fi

# CASE P4: the same tag prepared twice in a rebuild with the file present.
printf '%s' '{"version":3,"rules":[{"domain_suffix":["example.org"]}]}' > "$rd_path"
base_config
prepare_source_ruleset "main" "remote" "domains" "main-route-rule"
prepare_source_ruleset "main" "remote" "domains" "main-route-rule"
if [ "$(rule_set_defs main-remote-domains-ruleset)" = "1" ] && \
    [ "$(route_refs main-remote-domains-ruleset)" = "1" ] && \
    [ "$(dns_refs main-remote-domains-ruleset)" = "1" ]; then
    echo 'hr-prepare-same-tag-existing-once:OK'
else
    echo "hr-prepare-same-tag-existing-once(defs=$(rule_set_defs main-remote-domains-ruleset) route=$(route_refs main-remote-domains-ruleset)):FAIL"
fi
# ...and a plain remote list IS reused: its content comes from downloads that a
# config rebuild does not repeat, so dropping the file would empty the rule set.
if [ "$(jq -c . "$rd_path" 2>/dev/null)" = '{"version":3,"rules":[{"domain_suffix":["example.org"]}]}' ]; then
    echo 'hr-prepare-remote-file-kept:OK'
else
    echo "hr-prepare-remote-file-kept(got '$(cat "$rd_path" 2>/dev/null)'):FAIL"
fi

# CASE P5: a rule-set file that is not valid JSON (an interrupted write) is
#          recreated instead of failing every later build until a restart.
printf '%s' 'not json at all' > "$rd_path"
base_config
prepare_source_ruleset "main" "remote" "domains" "main-route-rule"
if [ "$(jq -c . "$rd_path" 2>/dev/null)" = '{"version":3,"rules":[]}' ] && \
    [ "$(route_refs main-remote-domains-ruleset)" = "1" ]; then
    echo 'hr-prepare-corrupt-file-recreated:OK'
else
    echo "hr-prepare-corrupt-file-recreated(got '$(cat "$rd_path" 2>/dev/null)' route=$(route_refs main-remote-domains-ruleset)):FAIL"
fi

# CASE P6: the tag is already defined, but ANOTHER route rule needs the
#          reference. Deciding by "is this tag anywhere in the config" would
#          leave that rule without a rule_set — everything it matches would go
#          direct.
rm -f "$rd_path"
base_config
config=$(sing_box_cm_add_route_rule "$config" "second-route-rule" "tproxy-in" "main-out")
prepare_source_ruleset "main" "remote" "domains" "main-route-rule"
prepare_source_ruleset "main" "remote" "domains" "second-route-rule"
if [ "$(rule_set_defs main-remote-domains-ruleset)" = "1" ] && \
    [ "$(route_refs_in main-route-rule main-remote-domains-ruleset)" = "1" ] && \
    [ "$(route_refs_in second-route-rule main-remote-domains-ruleset)" = "1" ]; then
    echo 'hr-prepare-second-rule-gets-reference:OK'
else
    echo "hr-prepare-second-rule-gets-reference(defs=$(rule_set_defs main-remote-domains-ruleset) first=$(route_refs_in main-route-rule main-remote-domains-ruleset) second=$(route_refs_in second-route-rule main-remote-domains-ruleset)):FAIL"
fi

# CASE P7: the same rules for subnet rule sets — the decision is made by the
#          source, not by the list type.
for hr_src in user local remote; do
    sn_path="$TMP_RULESET_FOLDER/main-$hr_src-subnets-ruleset.json"
    printf '%s' '{"version":3,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}' > "$sn_path"
    base_config
    prepare_source_ruleset "main" "$hr_src" "subnets" "main-route-rule"
    case "$hr_src" in
    remote) sn_want='{"version":3,"rules":[{"ip_cidr":["192.0.2.0/24"]}]}' ;;
    *) sn_want='{"version":3,"rules":[]}' ;;
    esac
    if [ "$(jq -c . "$sn_path" 2>/dev/null)" = "$sn_want" ] && \
        [ "$(route_refs "main-$hr_src-subnets-ruleset")" = "1" ]; then
        echo "hr-prepare-$hr_src-subnets-file:OK"
    else
        echo "hr-prepare-$hr_src-subnets-file(got '$(cat "$sn_path" 2>/dev/null)' route=$(route_refs "main-$hr_src-subnets-ruleset")):FAIL"
    fi
done

# ── read_proc_cmdline (real) ──────────────────────────────────────────
# The process may be gone by the time /proc is read; that must not print a
# "can't open" line into the log of every subscription update.
hr_proc_err="$( (eval "$(extract read_proc_cmdline)"; read_proc_cmdline 999999) 2>&1 > /dev/null)"
if [ -z "$hr_proc_err" ]; then
    echo 'hr-proc-cmdline-gone-process-silent:OK'
else
    echo "hr-proc-cmdline-gone-process-silent(stderr='$hr_proc_err'):FAIL"
fi

# ── reload_sing_box_config_in_place ───────────────────────────────────
# Stubs replace only the process boundary (pidof/kill), the full restart and
# the heavy config generator. The generator stub behaves like the real one:
# it writes the config, or exits the shell when sing-box rejects it.
eval "$(extract get_sing_box_daemon_pid)"
eval "$(extract reload_sing_box_config_in_place)"

SING_BOX_RELOAD_SETTLE_DELAY=0

hr_cfg="$HR_DIR/config.json"
config_get() {
    case "$2:$3" in
    settings:config_path) eval "$1=\"\$hr_cfg\"" ;;
    *) eval "$1=\"\${4:-}\"" ;;
    esac
}
uci_get() {
    # The reload path reads exactly one option: the sing-box service conffile.
    printf '%s' "$HR_CONFFILE"
}
# Fake process table. pidof lists every sing-box process in no particular order
# and each pid's argv comes from HR_CMDLINE_<pid>: 4241 is one of the transient
# helpers NetShift spawns (`check`) on NetShift's config, 4242 is the daemon the
# sing-box init script starts (argv as seen on a router), 4243 is another
# `sing-box run` on a config that is not NetShift's.
pidof() {
    [ "$1" = "sing-box" ] && [ -n "$HR_PIDS" ] || return 1
    printf '%s\n' "$HR_PIDS"
}
read_proc_cmdline() {
    eval "printf '%s\n' \"\${HR_CMDLINE_$1:-}\""
}
HR_CMDLINE_4241="/usr/bin/sing-box
-c
$hr_cfg
check"
HR_CMDLINE_4242="/usr/bin/sing-box
run
-c
$hr_cfg
-D
/usr/share/sing-box"
HR_CMDLINE_4243='/usr/bin/sing-box
run
-c
/etc/other-sing-box/config.json
-D
/var/lib/other-sing-box'
kill() {
    printf '%s\n' "$*" >> "$HR_DIR/kill.log"
    [ "$HR_KILL_DIES" = "1" ] && HR_PIDS="4241"
    return "$HR_KILL_RC"
}
restart() {
    printf 'restart\n' >> "$HR_DIR/restart.log"
    return 0
}
sing_box_init_config() {
    printf 'build\n' >> "$HR_DIR/build.log"
    [ "$HR_BUILD_OK" = "1" ] || exit 1
    printf '%s' "$HR_NEW_CONFIG" > "$hr_cfg"
}
hr_reset() {
    rm -f "$HR_DIR/kill.log" "$HR_DIR/restart.log" "$HR_DIR/build.log"
    printf '%s' '{"generation":1}' > "$hr_cfg"
    HR_PIDS="4241 4242"
    HR_CONFFILE="$hr_cfg"
    HR_KILL_RC=0
    HR_KILL_DIES=0
    HR_BUILD_OK=1
    HR_NEW_CONFIG='{"generation":2}'
}
hr_count() {
    if [ -f "$HR_DIR/$1.log" ]; then wc -l < "$HR_DIR/$1.log" | tr -d ' '; else echo 0; fi
}
hr_kills() {
    cat "$HR_DIR/kill.log" 2>/dev/null
}

# CASE R1: sing-box is not running -> stock full restart, no build, no signal.
hr_reset
HR_PIDS=""
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count restart)" = "1" ] && [ "$(hr_count build)" = "0" ] && [ -z "$(hr_kills)" ]; then
    echo 'hr-reload-not-running-restarts:OK'
else
    echo "hr-reload-not-running-restarts(rc=$rc restart=$(hr_count restart) build=$(hr_count build) kill='$(hr_kills)'):FAIL"
fi

# CASE R2: the rebuilt config is rejected -> the caller survives, no signal,
#          no restart, the running config file is untouched, non-zero rc.
hr_reset
HR_BUILD_OK=0
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -ne 0 ] && [ "$(hr_count build)" = "1" ] && [ "$(hr_count restart)" = "0" ] && \
    [ -z "$(hr_kills)" ] && [ "$(cat "$hr_cfg")" = '{"generation":1}' ]; then
    echo 'hr-reload-build-failure-keeps-running-config:OK'
else
    echo "hr-reload-build-failure-keeps-running-config(rc=$rc build=$(hr_count build) restart=$(hr_count restart) kill='$(hr_kills)'):FAIL"
fi

# CASE R3: the rebuilt config is identical -> nothing to reload.
hr_reset
HR_NEW_CONFIG='{"generation":1}'
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count build)" = "1" ] && [ "$(hr_count restart)" = "0" ] && [ -z "$(hr_kills)" ]; then
    echo 'hr-reload-unchanged-config-no-signal:OK'
else
    echo "hr-reload-unchanged-config-no-signal(rc=$rc build=$(hr_count build) restart=$(hr_count restart) kill='$(hr_kills)'):FAIL"
fi

# CASE R4: the rebuilt config changed -> SIGHUP to the running sing-box only.
hr_reset
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count build)" = "1" ] && [ "$(hr_count restart)" = "0" ] && [ "$(hr_kills)" = "-HUP 4242" ]; then
    echo 'hr-reload-changed-config-sighup:OK'
else
    echo "hr-reload-changed-config-sighup(rc=$rc build=$(hr_count build) restart=$(hr_count restart) kill='$(hr_kills)'):FAIL"
fi

# CASE R5: the signal cannot be delivered -> fall back to the full restart.
hr_reset
HR_KILL_RC=1
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count restart)" = "1" ] && [ "$(hr_kills)" = "-HUP 4242" ]; then
    echo 'hr-reload-signal-failure-restarts:OK'
else
    echo "hr-reload-signal-failure-restarts(rc=$rc restart=$(hr_count restart) kill='$(hr_kills)'):FAIL"
fi

# CASE R6: only a transient sing-box process is around (a `check` that is about
#          to exit). Signalling it would be silently lost, so there is no daemon
#          to reload and the restart is the honest answer.
hr_reset
HR_PIDS="4241"
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count restart)" = "1" ] && [ "$(hr_count build)" = "0" ] && [ -z "$(hr_kills)" ]; then
    echo 'hr-reload-transient-process-only-restarts:OK'
else
    echo "hr-reload-transient-process-only-restarts(rc=$rc restart=$(hr_count restart) build=$(hr_count build) kill='$(hr_kills)'):FAIL"
fi

# CASE R7: the running daemon uses a different config file than the one the
#          rebuild writes -> SIGHUP would re-read the old file and report an
#          update that never happened. Restart instead, before building.
hr_reset
HR_CONFFILE="/etc/sing-box/config.json"
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count restart)" = "1" ] && [ "$(hr_count build)" = "0" ] && [ -z "$(hr_kills)" ]; then
    echo 'hr-reload-conffile-mismatch-restarts:OK'
else
    echo "hr-reload-conffile-mismatch-restarts(rc=$rc restart=$(hr_count restart) build=$(hr_count build) kill='$(hr_kills)'):FAIL"
fi

# CASE R8: the signal is delivered but the daemon does not survive the reload.
#          A delivered signal is not an applied config, so this is a restart,
#          not a success.
hr_reset
HR_KILL_DIES=1
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_kills)" = "-HUP 4242" ] && [ "$(hr_count restart)" = "1" ]; then
    echo 'hr-reload-daemon-gone-after-signal-restarts:OK'
else
    echo "hr-reload-daemon-gone-after-signal-restarts(rc=$rc kill='$(hr_kills)' restart=$(hr_count restart)):FAIL"
fi

# CASE R9: another `sing-box run` on a different config is listed first. It
#          would take the signal just as well and apply nothing, so the signal
#          goes to the daemon running NetShift's config.
hr_reset
HR_PIDS="4243 4241 4242"
reload_sing_box_config_in_place
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_kills)" = "-HUP 4242" ] && [ "$(hr_count restart)" = "0" ]; then
    echo 'hr-reload-foreign-daemon-not-signalled:OK'
else
    echo "hr-reload-foreign-daemon-not-signalled(rc=$rc kill='$(hr_kills)' restart=$(hr_count restart)):FAIL"
fi

# ── subscription_update applies a changed feed without a restart ──────
eval "$(extract subscription_update)"
eval "$(extract foreach_active_section)"
eval "$(extract _active_section_dispatch)"
section_is_disabled() { return 1; }

TMP_SUBSCRIPTION_FOLDER="$HR_DIR/sub-tmp"
TMP_SING_BOX_FOLDER="$HR_DIR/sing-box"
SUBSCRIPTION_PENDING_APPLY_FLAG="$TMP_SING_BOX_FOLDER/subscription-pending-apply"
SUBSCRIPTION_CACHE_FOLDER="$HR_DIR/sub-cache"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
config_foreach() { "$1" "main"; }
config_get() {
    case "$3" in
    connection_type) eval "$1=proxy" ;;
    proxy_config_type) eval "$1=subscription" ;;
    *) eval "$1=\"\${4:-}\"" ;;
    esac
}
ensure_subscription_cache_dir() { :; }
reap_legacy_subscription_cache_files() { :; }
get_subscription_urls_for_section() { printf '%s\n' "https://feed.example.com/sub"; }
get_subscription_url_hash() { printf 'feedhash'; }
get_subscription_json_path() { printf '%s' "$SUBSCRIPTION_CACHE_FOLDER/$1.$2.json"; }
get_subscription_url_cache_path() { printf '%s' "$SUBSCRIPTION_CACHE_FOLDER/$1.$2.url"; }
get_subscription_download_proxy_address() { :; }
wait_for_subscription_connectivity() { return 0; }
redact_url_for_log() { printf '%s' "$1"; }
subscription_cache_is_usable() { return 0; }
download_subscription_into_cache() {
    printf '%s' '{"outbounds":[{"type":"vless","tag":"node-1"}]}' > "$3"
    # The process dies right after the changed body landed in the cache (OOM,
    # SIGKILL) — before anything could be applied.
    [ "$HR_DOWNLOAD_DIES" = "1" ] && exit 9
    return "$HR_DOWNLOAD_RC"
}
HR_DOWNLOAD_DIES=0
reload_sing_box_config_in_place() {
    printf 'reload\n' >> "$HR_DIR/reload.log"
    return "$HR_RELOAD_RC"
}

# CASE U1: a changed feed is applied by reloading sing-box, not by a restart,
#          and a successful apply leaves no pending marker behind.
rm -f "$HR_DIR/reload.log" "$HR_DIR/restart.log" "$SUBSCRIPTION_PENDING_APPLY_FLAG"
HR_DOWNLOAD_RC=0
HR_RELOAD_RC=0
subscription_update > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count reload)" = "1" ] && [ "$(hr_count restart)" = "0" ] && \
    [ ! -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ]; then
    echo 'hr-update-changed-feed-reloads-without-restart:OK'
else
    echo "hr-update-changed-feed-reloads-without-restart(rc=$rc reload=$(hr_count reload) restart=$(hr_count restart)):FAIL"
fi

# CASE U2: an unchanged feed touches neither sing-box nor NetShift.
rm -f "$HR_DIR/reload.log" "$HR_DIR/restart.log" "$SUBSCRIPTION_PENDING_APPLY_FLAG"
HR_DOWNLOAD_RC=2
subscription_update > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count reload)" = "0" ] && [ "$(hr_count restart)" = "0" ]; then
    echo 'hr-update-unchanged-feed-no-reload:OK'
else
    echo "hr-update-unchanged-feed-no-reload(rc=$rc reload=$(hr_count reload) restart=$(hr_count restart)):FAIL"
fi
# The marker set before the downloads is gone again: nothing was left to apply.
if [ ! -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ]; then
    echo 'hr-update-unchanged-feed-no-marker:OK'
else
    echo 'hr-update-unchanged-feed-no-marker(marker left behind):FAIL'
fi

# CASE U3: a failed reload is reported to the caller and remembered.
rm -f "$HR_DIR/reload.log" "$HR_DIR/restart.log" "$SUBSCRIPTION_PENDING_APPLY_FLAG"
HR_DOWNLOAD_RC=0
HR_RELOAD_RC=1
subscription_update > /dev/null 2>&1
rc=$?
if [ "$rc" -eq "$SUBSCRIPTION_UPDATE_APPLY_FAILED" ] && [ "$(hr_count reload)" = "1" ]; then
    echo 'hr-update-reload-failure-propagates:OK'
else
    echo "hr-update-reload-failure-propagates(rc=$rc reload=$(hr_count reload)):FAIL"
fi
if [ -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ]; then
    echo 'hr-update-failed-apply-marked:OK'
else
    echo 'hr-update-failed-apply-marked(no marker):FAIL'
fi

# CASE U4: the next run finds the feed "unchanged" — the body was already
#          written into the cache before the failed apply — but the change still
#          has not reached sing-box. It must be applied now instead of logging
#          "no changes detected" and leaving the router on the old outbounds.
rm -f "$HR_DIR/reload.log" "$HR_DIR/restart.log"
HR_DOWNLOAD_RC=2
HR_RELOAD_RC=0
subscription_update > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count reload)" = "1" ] && [ ! -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ]; then
    echo 'hr-update-pending-apply-retried:OK'
else
    echo "hr-update-pending-apply-retried(rc=$rc reload=$(hr_count reload) marker=$([ -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ] && echo yes || echo no)):FAIL"
fi

# CASE U5: the process dies right after the changed body was written into the
#          cache, before the apply. The next run reads the feed as "unchanged";
#          the change must still be applied.
rm -f "$HR_DIR/reload.log" "$SUBSCRIPTION_PENDING_APPLY_FLAG"
HR_DOWNLOAD_RC=0
HR_DOWNLOAD_DIES=1
( subscription_update ) > /dev/null 2>&1
HR_DOWNLOAD_DIES=0
HR_DOWNLOAD_RC=2
HR_RELOAD_RC=0
subscription_update > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(hr_count reload)" = "1" ] && [ ! -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ]; then
    echo 'hr-update-killed-after-cache-write-applied-next-run:OK'
else
    echo "hr-update-killed-after-cache-write-applied-next-run(rc=$rc reload=$(hr_count reload)):FAIL"
fi

# ── start_subscription_startup_retry_worker ───────────────────────────
# The worker runs `/usr/bin/netshift subscription_update` in a child process;
# the test swaps that one command for a stub fed from a list of exit codes, and
# records every wait instead of sleeping.
eval "$(extract start_subscription_startup_retry_worker | sed 's|/usr/bin/netshift subscription_update|hr_worker_update|')"
config_load() { :; }
# The first wait really pauses for a moment: the parent writes the pidfile right
# after forking the worker, and a worker that finished before that would leave
# the pidfile behind.
sleep() {
    printf '%s\n' "$1" >> "$HR_DIR/sleep.log"
    [ "$1" = "10" ] && command sleep 1
    return 0
}
hr_worker_update() {
    printf 'update\n' >> "$HR_DIR/worker.log"
    hr_worker_rc="$(sed -n "$(hr_count worker)p" "$HR_DIR/worker_rcs")"
    return "${hr_worker_rc:-0}"
}
hr_worker_pidfile="/var/run/netshift_subscription_retry.pid"
mkdir -p /var/run
hr_worker_run() {
    rm -f "$HR_DIR/worker.log" "$HR_DIR/sleep.log" "$hr_worker_pidfile"
    printf '%s\n' "$@" > "$HR_DIR/worker_rcs"
    start_subscription_startup_retry_worker
    wait
}
hr_sleeps() {
    tr '\n' ' ' < "$HR_DIR/sleep.log" 2>/dev/null | sed 's/ $//'
}

# CASE W1: an unreachable feed keeps being polled at the normal interval until
#          it comes back — that is what the worker is for.
hr_worker_run 1 1 0
if [ "$(hr_count worker)" = "3" ] && [ "$(hr_sleeps)" = "10 30 30" ] && [ ! -f "$hr_worker_pidfile" ]; then
    echo 'hr-worker-unreachable-feed-polled:OK'
else
    echo "hr-worker-unreachable-feed-polled(updates=$(hr_count worker) sleeps='$(hr_sleeps)'):FAIL"
fi

# CASE W2: feeds that download but never apply: the wait doubles, and after
#          SUBSCRIPTION_RETRY_MAX_APPLY_FAILURES failures in a row the worker
#          stops and leaves the change to the scheduled update.
hr_worker_run 3 3 3 3 3 3 3 3
if [ "$(hr_count worker)" = "$SUBSCRIPTION_RETRY_MAX_APPLY_FAILURES" ] && \
    [ "$(hr_sleeps)" = "10 30 60 120 240" ] && [ ! -f "$hr_worker_pidfile" ]; then
    echo 'hr-worker-apply-failures-back-off-and-stop:OK'
else
    echo "hr-worker-apply-failures-back-off-and-stop(updates=$(hr_count worker) sleeps='$(hr_sleeps)'):FAIL"
fi

# CASE W3: the doubled wait is capped, and a failed download in between neither
#          counts as an apply failure nor resets the count.
hr_saved_backoff_max="$SUBSCRIPTION_RETRY_BACKOFF_MAX"
SUBSCRIPTION_RETRY_BACKOFF_MAX=45
hr_worker_run 3 1 3 3 0
SUBSCRIPTION_RETRY_BACKOFF_MAX="$hr_saved_backoff_max"
if [ "$(hr_count worker)" = "5" ] && [ "$(hr_sleeps)" = "10 30 30 45 45" ]; then
    echo 'hr-worker-backoff-capped:OK'
else
    echo "hr-worker-backoff-capped(updates=$(hr_count worker) sleeps='$(hr_sleeps)'):FAIL"
fi

# ── start_main and the pending-apply marker ───────────────────────────
# Only a start that built a valid config may drop the marker: a rejected config
# makes sing_box_init_config exit the process, and the change is still pending.
eval "$(extract start_main | sed \
    -e 's|/usr/sbin/ntpd|: ntpd|' \
    -e 's|/etc/init.d/sing-box start|hr_sing_box_start|' \
    -e 's|/var/run/netshift_list_update.pid|$HR_DIR/list_update.pid|')"
TMP_RULESET_FOLDER="$HR_DIR/rulesets"
migrate_legacy_subscription_url_option() { :; }
check_requirements() { :; }
migration() { :; }
process_validate_service() { :; }
br_netfilter_disable() { :; }
migrate_subscription_cache_from_tmp() { :; }
prepare_subscription_caches_for_startup() { subscription_startup_blocked=0; }
stop_subscription_startup_retry_worker() { :; }
route_table_rule_mark() { :; }
create_nft_rules() { :; }
sing_box_configure_service() { :; }
add_cron_job() { :; }
# start_main has to (re)build the subscription jobs once the config it just built
# was accepted. The stub counts the calls, so dropping the call from start_main
# fails the assertions below instead of passing unnoticed.
sync_subscription_cron_jobs() { printf 'sync\n' >> "$HR_DIR/sub_cron_sync.log"; }
list_update() { :; }
hr_sing_box_start() { printf 'start\n' >> "$HR_DIR/sb_start.log"; }

# CASE S1: the build succeeds -> the marker is dropped and sing-box started.
rm -f "$HR_DIR/sb_start.log"
mkdir -p "$TMP_SING_BOX_FOLDER"
: > "$SUBSCRIPTION_PENDING_APPLY_FLAG"
HR_BUILD_OK=1
rm -f "$HR_DIR/sub_cron_sync.log"
( start_main ) > /dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ] && [ "$(hr_count sb_start)" = "1" ]; then
    echo 'hr-start-built-config-drops-marker:OK'
else
    echo "hr-start-built-config-drops-marker(rc=$rc started=$(hr_count sb_start) marker=$([ -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ] && echo yes || echo no)):FAIL"
fi
if [ "$(hr_count sub_cron_sync)" = "1" ]; then
    echo 'hr-start-syncs-subscription-cron-jobs:OK'
else
    echo "hr-start-syncs-subscription-cron-jobs(syncs=$(hr_count sub_cron_sync)):FAIL"
fi

# CASE S2: sing-box rejects the config -> start_main exits before the marker
#          line, so the next subscription_update still applies the change. The
#          subscription cron jobs are not rebuilt either: the config they would
#          drive was never accepted.
rm -f "$HR_DIR/sb_start.log"
rm -f "$HR_DIR/sub_cron_sync.log"
: > "$SUBSCRIPTION_PENDING_APPLY_FLAG"
HR_BUILD_OK=0
( start_main ) > /dev/null 2>&1
rc=$?
HR_BUILD_OK=1
if [ "$rc" -ne 0 ] && [ -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ] && [ "$(hr_count sb_start)" = "0" ]; then
    echo 'hr-start-rejected-config-keeps-marker:OK'
else
    echo "hr-start-rejected-config-keeps-marker(rc=$rc started=$(hr_count sb_start) marker=$([ -f "$SUBSCRIPTION_PENDING_APPLY_FLAG" ] && echo yes || echo no)):FAIL"
fi
if [ "$(hr_count sub_cron_sync)" = "0" ]; then
    echo 'hr-start-rejected-config-skips-cron-sync:OK'
else
    echo "hr-start-rejected-config-skips-cron-sync(syncs=$(hr_count sub_cron_sync)):FAIL"
fi
unset -f sleep

# ── the rebuild subshell against the REAL save path ───────────────────
# R2 proves the caller survives a rejected config, but only against a stub that
# exits before touching anything. The real guarantee is sing_box_save_config:
# it validates a temporary file and moves it into place only afterwards, while
# sing_box_config_check exits the shell on rejection.
eval "$(extract sing_box_save_config)"
eval "$(extract sing_box_config_check)"

mkdir -p "$HR_DIR/bin"
export HR_SB_CHECK_OK="$HR_DIR/sb_check_ok"
cat > "$HR_DIR/bin/sing-box" << 'SBEOF'
#!/bin/sh
[ -f "$HR_SB_CHECK_OK" ] && exit 0
exit 1
SBEOF
chmod 0755 "$HR_DIR/bin/sing-box"
PATH="$HR_DIR/bin:$PATH"

sb_real_cfg="$HR_DIR/real-config.json"
config_get() {
    case "$2:$3" in
    settings:config_path) eval "$1=\"\$sb_real_cfg\"" ;;
    *) eval "$1=\"\${4:-}\"" ;;
    esac
}
printf '%s' '{"generation":"running"}' > "$sb_real_cfg"
config='{"generation":"new"}'

rm -f "$HR_SB_CHECK_OK"
survived=0
( sing_box_save_config ) > /dev/null 2>&1 || survived=1
if [ "$survived" = "1" ] && [ "$(jq -c . "$sb_real_cfg" 2>/dev/null)" = '{"generation":"running"}' ]; then
    echo 'hr-save-config-rejected-keeps-running-file:OK'
else
    echo "hr-save-config-rejected-keeps-running-file(survived=$survived got='$(cat "$sb_real_cfg" 2>/dev/null)'):FAIL"
fi

: > "$HR_SB_CHECK_OK"
( sing_box_save_config ) > /dev/null 2>&1
if [ "$(jq -c . "$sb_real_cfg" 2>/dev/null)" = '{"generation":"new"}' ]; then
    echo 'hr-save-config-accepted-replaces-file:OK'
else
    echo "hr-save-config-accepted-replaces-file(got='$(cat "$sb_real_cfg" 2>/dev/null)'):FAIL"
fi

rm -rf "$HR_DIR"
echo DONE
HREOF
    sed -i -e "s|BIN_PATH|$bin|g" -e "s|LIB_DIR|$lib|g" "$drv"

    sh "$drv" > "$out" 2>&1 || true

    local line saw_done=0
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "hr-driver-completed"
    else
        fail "hr-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$out" 2>/dev/null)"
    fi

    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: Domain/subnet list separators — commas and ANY ASCII whitespace
#
# The UI validates a Text List by splitting it on /[,\s]+/ (parseValueList), so
# a list pasted from a spreadsheet arrives tab-separated. The backend split the
# value with `tr ', ' '\n'`, which does NOT split on a tab: the whole line stayed
# a single item, failed domain validation and was dropped — every domain on that
# line silently disappeared (issue #53).
#
# The driver sources the REAL helpers.sh / rulesets.sh / sing_box_config_manager.sh,
# pulls configure_user_domain_list / configure_user_subnet_list /
# prepare_source_ruleset out of the shipped bin VERBATIM, and drives them with
# tab-separated UCI values through a config_get stub. It then asserts the
# generated source rule-set files carry both items and that a full sing-box
# config referencing those files passes `sing-box check`.
#
# Gating: tokens are consumed in the CURRENT shell via `while read < file`, so
# pass/fail mutate the real counters. Reverting the shipped separator set to
# `tr ', ' '\n'` FAILs exactly 9 tokens: ds-tab-domains, ds-tab-subnets,
# ds-tab-run, ds-mixed-separators, ds-vt-ff, ds-comment-header,
# ds-invalid-dropped, ds-ruleset-domains and ds-ruleset-subnets.
# (ds-singbox-check stays OK either way: an empty rule set is still a valid
# sing-box config — it only guards the generated JSON against corruption.)
# ─────────────────────────────────────────────────────────────────
test_domain_separators() {
    header "Domain/Subnet List Separators (issue #53)"

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/helpers.sh" ] || \
        [ ! -r "$lib/rulesets.sh" ] || [ ! -r "$lib/sing_box_config_manager.sh" ] || \
        [ ! -r "$lib/helpers.jq" ]; then
        skip "netshift bin / helpers.sh / rulesets.sh / sing_box_config_manager.sh / helpers.jq not found"
        return
    fi

    # patch_route_rule / patch_dns_route_rule import helpers.jq from this path.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.jq" /usr/lib/netshift/helpers.jq

    local drv="/tmp/netshift-domsep-$$.sh"
    local out="/tmp/netshift-domsep-$$.out"
    cat > "$drv" << 'DSEOF'
log() { :; }
echolog() { :; }
nolog() { :; }

. "LIB_DIR/constants.sh"
. "LIB_DIR/helpers.sh"
. "LIB_DIR/rulesets.sh"
. "LIB_DIR/sing_box_config_manager.sh"

# Functions under test come VERBATIM from the shipped bin.
extract() {
    awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH"
}
eval "$(extract rule_references_ruleset)"
eval "$(extract prepare_source_ruleset)"
eval "$(extract configure_user_domain_list)"
eval "$(extract configure_user_subnet_list)"
eval "$(extract populate_netshift_subnets_from_string)"
eval "$(extract populate_netshift_subnets_from_file)"
eval "$(extract netshift_ipv6_enabled)"

# UCI stub: reads the DS_<section>_<option> variables assigned below.
ds_key() { printf 'DS_%s_%s' "$(printf '%s' "$1" | tr '.-' '__')" "$2"; }
config_get() {
    local _k _v
    _k="$(ds_key "$2" "$3")"
    eval "_v=\"\${$_k:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"\$_v\""
    return 0
}
config_get_bool() {
    local _k _v
    _k="$(ds_key "$2" "$3")"
    eval "_v=\"\${$_k:-}\""
    [ -n "$_v" ] || _v="$4"
    case "$_v" in
    1 | on | true | yes | enabled) _v=1 ;;
    *) _v=0 ;;
    esac
    eval "$1=\"\$_v\""
    return 0
}

DS_DIR="/tmp/netshift-domsep-state-$$"
rm -rf "$DS_DIR"
mkdir -p "$DS_DIR"
TMP_RULESET_FOLDER="$DS_DIR/rulesets"
mkdir -p "$TMP_RULESET_FOLDER"

base_config() {
    config='{"route":{"rules":[],"rule_set":[]},"dns":{"rules":[]}}'
    config=$(sing_box_cm_add_route_rule "$config" "main-route-rule" "tproxy-in" "main-out")
    config=$(sing_box_cm_add_dns_route_rule "$config" "$SB_FAKEIP_DNS_SERVER_TAG" "$SB_FAKEIP_DNS_RULE_TAG")
}

# The token MUST be the whole line: the consumer matches `*:OK` / `*:FAIL` at
# end-of-line, so any diagnostic has to go on its own (ignored) line.
ds_eq() {
    if [ "$2" = "$3" ]; then
        echo "$1:OK"
    else
        echo "# ds-detail $1: got [$2], want [$3]"
        echo "$1:FAIL"
    fi
}
ds_parse_eq() {
    ds_eq "$1" "$(parse_domain_or_subnet_string_to_commas_string "$4" "$3")" "$2"
}
ds_keys() {
    jq -r --arg k "$2" '[.rules[]? | (.[$k] // empty) | .[]] | sort | join(" ")' "$1" 2>/dev/null
}

# ── unit: parse_domain_or_subnet_string_to_commas_string ────────────────────
ds_parse_eq "ds-tab-domains" "example.com,example.org" "domains" "$(printf 'example.com\texample.org')"
ds_parse_eq "ds-tab-subnets" "10.0.0.0/8,192.168.1.1" "subnets" "$(printf '10.0.0.0/8\t192.168.1.1')"
ds_parse_eq "ds-tab-run" "example.com,example.org" "domains" "$(printf 'example.com\t\t\texample.org')"
ds_parse_eq "ds-tab-padded" "example.com,example.org" "domains" "$(printf '  example.com\t example.org  ')"
# regression: the separators that already worked must keep working
ds_parse_eq "ds-space-regression" "example.com,example.org" "domains" "example.com example.org"
ds_parse_eq "ds-comma-regression" "example.com,example.org" "domains" "example.com,example.org"
ds_parse_eq "ds-newline-regression" "example.com,example.org" "domains" "$(printf 'example.com\nexample.org')"
ds_parse_eq "ds-crlf-regression" "example.com,example.org" "domains" "$(printf 'example.com\r\nexample.org')"
# every separator the UI splits on (/[,\s]+/) at once
ds_parse_eq "ds-mixed-separators" "a.example.com,b.example.com,c.example.com,d.example.com" "domains" \
    "$(printf 'a.example.com, b.example.com\tc.example.com  d.example.com')"
ds_parse_eq "ds-vt-ff" "example.com,example.org,x.example.com" "domains" \
    "$(printf 'example.com\013example.org\014x.example.com')"
# comments (//) are still honoured, including on a tab-separated line
ds_parse_eq "ds-comment-trailing" "example.com" "domains" "$(printf 'example.com\t// a note')"
ds_parse_eq "ds-comment-header" "example.com,example.org" "domains" \
    "$(printf '// header\n\t example.com\texample.org')"
# an invalid item is still dropped without taking its valid neighbours with it
ds_parse_eq "ds-invalid-dropped" "example.com" "domains" "$(printf 'bad_domain\texample.com')"
ds_parse_eq "ds-empty" "" "domains" ""

# ── end-to-end: UCI text option -> source rule-set file ─────────────────────
base_config
DS_main_user_domain_list_type="text"
DS_main_user_domains_text="$(printf 'example.com\texample.org')"
configure_user_domain_list "main" "main-route-rule"
ds_rc=$?
ds_eq "ds-config-no-abort" "$ds_rc" "0"

base_config
DS_main_user_subnet_list_type="text"
DS_main_user_subnets_text="$(printf '10.0.0.0/8\t192.168.1.1')"
configure_user_subnet_list "main" "main-route-rule"
ds_rc=$?
ds_eq "ds-subnet-config-no-abort" "$ds_rc" "0"

ds_dom_file="$TMP_RULESET_FOLDER/main-user-domains-ruleset.json"
ds_net_file="$TMP_RULESET_FOLDER/main-user-subnets-ruleset.json"
ds_eq "ds-ruleset-domains" "$(ds_keys "$ds_dom_file" domain_suffix)" "example.com example.org"
ds_eq "ds-ruleset-subnets" "$(ds_keys "$ds_net_file" ip_cidr)" "10.0.0.0/8 192.168.1.1"

# ── upgrade simulation: the fix introduces no new UCI option, and a config
# that lacks the text value (or the mode selector) must still build without
# aborting and produce an empty rule set — the pre-existing behaviour.
unset DS_main_user_domains_text
base_config
configure_user_domain_list "main" "main-route-rule"
ds_rc=$?
ds_eq "ds-missing-value-no-abort" "$ds_rc" "0"
ds_eq "ds-missing-value-empty" "$(ds_keys "$ds_dom_file" domain_suffix)" ""

unset DS_main_user_domain_list_type
base_config
configure_user_domain_list "main" "main-route-rule"
ds_rc=$?
ds_eq "ds-missing-mode-no-abort" "$ds_rc" "0"

# ── full sing-box config referencing both generated rule-set files ──────────
if command -v sing-box > /dev/null 2>&1; then
    base_config
    DS_main_user_domain_list_type="text"
    DS_main_user_domains_text="$(printf 'example.com\texample.org')"
    configure_user_domain_list "main" "main-route-rule"
    DS_main_user_subnet_list_type="text"
    DS_main_user_subnets_text="$(printf '10.0.0.0/8\t192.168.1.1')"
    configure_user_subnet_list "main" "main-route-rule"

    printf '%s' "$config" | jq --arg srv "$SB_FAKEIP_DNS_SERVER_TAG" '{
        log: { level: "error" },
        dns: {
            rules: [.dns.rules[] | del(."__service_tag")],
            servers: [{ tag: $srv, type: "udp", server: "1.1.1.1" }],
            final: $srv
        },
        inbounds: [{ type: "tproxy", tag: "tproxy-in", listen: "127.0.0.1", listen_port: 1602 }],
        outbounds: [{ type: "direct", tag: "main-out" }, { type: "direct", tag: "direct-out" }],
        route: {
            rule_set: .route.rule_set,
            rules: [.route.rules[] | del(."__service_tag")],
            final: "direct-out"
        }
    }' > "$DS_DIR/full.json" 2>/dev/null

    if sing-box -c "$DS_DIR/full.json" check > /dev/null 2>&1; then
        echo 'ds-singbox-check:OK'
    else
        echo "# ds-detail sing-box check: $(sing-box -c "$DS_DIR/full.json" check 2>&1 | head -n 2 | tr '\n' ' ')"
        echo 'ds-singbox-check:FAIL'
    fi
else
    echo 'ds-singbox-check:SKIP (sing-box not installed)'
fi

rm -rf "$DS_DIR"
echo 'DONE'
DSEOF
    sed -i "s|LIB_DIR|$lib|g; s|BIN_PATH|$bin|g" "$drv"

    # Run the driver to a RESULT FILE, then consume tokens in the CURRENT shell
    # (while read < file — NO pipe) so pass/fail/skip mutate the real counters.
    sh "$drv" > "$out" 2>/dev/null
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "ds-driver-completed:OK"
    else
        fail "ds-driver-completed:FAIL (driver aborted early)" \
            "$(grep '^# ds-detail' "$out" 2>/dev/null | head -5)"
    fi

    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: selected server survives a reboot (sing-box cache DB copy)
# ─────────────────────────────────────────────────────────────────
test_cache_persist() {
    header "Selected Server Survives Reboot (sing-box cache DB copy)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi
    if ! command -v flock > /dev/null 2>&1 || ! command -v cmp > /dev/null 2>&1; then
        skip "flock / cmp not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$bin" ] || [ ! -r "$lib/constants.sh" ]; then
        skip "netshift bin / constants.sh not found"
        return
    fi

    local drv="/tmp/netshift-cachepersist-$$.sh"
    local out="/tmp/netshift-cachepersist-$$.out"
    cat > "$drv" << 'CPEOF'
. "LIB_DIR/constants.sh"

# Functions under test come VERBATIM from the shipped bin.
extract() {
    awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH"
}
eval "$(extract get_sing_box_cache_path)"
eval "$(extract sing_box_cache_is_volatile)"
eval "$(extract restore_sing_box_cache)"
eval "$(extract discard_restored_sing_box_cache)"
eval "$(extract get_sing_box_selection)"
eval "$(extract snapshot_sing_box_cache)"
eval "$(extract monitor_sing_box)"
eval "$(extract dnsmasq_should_be_restored)"
eval "$(extract clash_api)"

CP_DIR="/tmp/netshift-cachepersist-state-$$"
rm -rf "$CP_DIR"
mkdir -p "$CP_DIR/state"
NETSHIFT_STATE_DIR="$CP_DIR/state"
NETSHIFT_CACHE_BACKUP="$NETSHIFT_STATE_DIR/cache.db"
NETSHIFT_CACHE_SELECTION="$NETSHIFT_STATE_DIR/cache.db.selection"
NETSHIFT_CACHE_BACKUP_LOCK="$CP_DIR/lock/cache-backup.lock"
NETSHIFT_CACHE_RESTORED_FLAG="$CP_DIR/run/cache-restored"
LIVE="$CP_DIR/live/cache.db"
LOG="$CP_DIR/log"

log() { printf '%s %s\n' "${2:-info}" "$1" >> "$LOG"; }
CFG_CACHE_PATH="$LIVE"
CFG_LISTEN=""
CFG_SECRET=""
CFG_SHUTDOWN="1"
CFG_LAN_IP="192.168.1.1"
config_get() {
    local __v=""
    case "$3" in
    cache_path) __v="$CFG_CACHE_PATH" ;;
    service_listen_address) __v="$CFG_LISTEN" ;;
    yacd_secret_key) __v="$CFG_SECRET" ;;
    shutdown_correctly) __v="$CFG_SHUTDOWN" ;;
    esac
    [ -n "$__v" ] || __v="$4"
    eval "$1=\$__v"
}
# dont_touch_dhcp is driven by CFG_DONT_TOUCH_DHCP; every other bool takes its default.
config_get_bool() {
    case "$3" in
    dont_touch_dhcp) eval "$1=\"\${CFG_DONT_TOUCH_DHCP:-0}\"" ;;
    *) eval "$1=\"\${4:-0}\"" ;;
    esac
}
# netshift_configured sentinel: driven by CFG_NS_CONFIGURED (1 = NetShift configured dnsmasq).
dnsmasq_is_configured_for_netshift() { [ "${CFG_NS_CONFIGURED:-0}" = "1" ]; }
get_service_listen_address() { printf '%s' "127.0.0.1"; }
config_load() { :; }
network_get_ipaddr() { eval "$1=\$CFG_LAN_IP"; }

reset_state() {
    rm -rf "$CP_DIR/live" "$NETSHIFT_STATE_DIR" "$LOG" "$CP_DIR/run"
    mkdir -p "$NETSHIFT_STATE_DIR"
    CFG_CACHE_PATH="$LIVE"
    CFG_SHUTDOWN="1"
}
live_db() {
    mkdir -p "$(dirname "$LIVE")"
    printf '%s' "$1" > "$LIVE"
}
check() {
    if eval "$2"; then echo "$1:OK"; else echo "$1:FAIL"; fi
}

# ── restore_sing_box_cache ─────────────────────────────────────────────
# R1: no copy on flash -> nothing is created.
reset_state
restore_sing_box_cache
check cp-restore-without-copy-noop '[ ! -e "$LIVE" ]'

# R2: reboot wiped tmpfs -> the copy becomes the live DB.
reset_state
printf 'saved-db' > "$NETSHIFT_CACHE_BACKUP"
restore_sing_box_cache
check cp-restore-after-reboot '[ "$(cat "$LIVE" 2>/dev/null)" = "saved-db" ]'

# R3: a live DB that survived a restart is newer -> left alone.
reset_state
printf 'saved-db' > "$NETSHIFT_CACHE_BACKUP"
live_db 'live-db'
restore_sing_box_cache
check cp-restore-keeps-live-db '[ "$(cat "$LIVE")" = "live-db" ]'

# R4: cache_path on flash survives a reboot by itself -> no copy is used.
reset_state
printf 'saved-db' > "$NETSHIFT_CACHE_BACKUP"
CFG_CACHE_PATH="$CP_DIR/flash/cache.db"
sing_box_cache_is_volatile() { return 1; }
restore_sing_box_cache
eval "$(extract sing_box_cache_is_volatile)"
check cp-restore-skips-flash-cache-path '[ ! -e "$CP_DIR/flash/cache.db" ]'

# ── sing_box_cache_is_volatile ─────────────────────────────────────────
check cp-volatile-tmp 'sing_box_cache_is_volatile /tmp/sing-box/cache.db'
check cp-volatile-var 'sing_box_cache_is_volatile /var/run/sing-box/cache.db'
check cp-flash-not-volatile '! sing_box_cache_is_volatile /etc/sing-box/cache.db'

# ── get_sing_box_selection ─────────────────────────────────────────────
PROXIES='{"proxies":{
  "main-out":{"type":"Selector","now":"node-b","all":["node-a","node-b"]},
  "alt-out":{"type":"Selector","now":"node-c"},
  "main-urltest-out":{"type":"URLTest","now":"node-a"},
  "direct-out":{"type":"Direct"}}}'
CURL_ARGS="$CP_DIR/curl.args"
curl() { printf '%s\n' "$@" > "$CURL_ARGS"; printf '%s' "$PROXIES"; }

sel="$(get_sing_box_selection)"
expected="$(printf 'alt-out\tnode-c\nmain-out\tnode-b')"
check cp-selection-lists-selectors-only '[ "$sel" = "$expected" ]'
check cp-selection-uses-lan-address 'grep -qx "http://192.168.1.1:$SB_CLASH_API_CONTROLLER_PORT/proxies" "$CURL_ARGS"'
check cp-selection-no-auth-without-secret '! grep -q "Authorization" "$CURL_ARGS"'

CFG_SECRET="s3cret"
CFG_LISTEN="10.0.0.1"
get_sing_box_selection > /dev/null
check cp-selection-sends-secret 'grep -qx "Authorization: Bearer s3cret" "$CURL_ARGS"'
check cp-selection-honours-listen-override 'grep -q "^http://10.0.0.1:" "$CURL_ARGS"'
CFG_SECRET=""
CFG_LISTEN=""

curl() { return 7; }
check cp-selection-empty-when-api-down '[ -z "$(get_sing_box_selection)" ]'

# ── snapshot_sing_box_cache ────────────────────────────────────────────
SELECTION="$(printf 'main-out\tnode-b')"
get_sing_box_selection() { [ -n "$SELECTION" ] && printf '%s\n' "$SELECTION"; }

# S1: no live DB yet -> nothing to copy.
reset_state
snapshot_sing_box_cache
check cp-snapshot-without-live-db-noop '[ ! -e "$NETSHIFT_CACHE_BACKUP" ]'

# S2: Clash API down -> the selection is unknown, keep what is on flash.
reset_state
live_db 'db-1'
SELECTION=""
snapshot_sing_box_cache
SELECTION="$(printf 'main-out\tnode-b')"
check cp-snapshot-api-down-noop '[ ! -e "$NETSHIFT_CACHE_BACKUP" ]'

# S3: first selection -> byte-identical copy, selection recorded, mode 600.
reset_state
live_db 'db-1'
snapshot_sing_box_cache
check cp-snapshot-copies-live-db 'cmp -s "$LIVE" "$NETSHIFT_CACHE_BACKUP"'
check cp-snapshot-records-selection '[ "$(cat "$NETSHIFT_CACHE_SELECTION")" = "$SELECTION" ]'
check cp-snapshot-mode-600 '[ "$(ls -l "$NETSHIFT_CACHE_BACKUP" | cut -c1-10)" = "-rw-------" ]'
check cp-snapshot-no-leftover-tmp '[ ! -e "$NETSHIFT_CACHE_BACKUP.tmp" ] && [ ! -e "$NETSHIFT_CACHE_SELECTION.tmp" ]'

# S4: same selection, DB changed by FakeIP -> no flash write.
live_db 'db-2-fakeip-churn'
snapshot_sing_box_cache
check cp-snapshot-same-selection-no-write '[ "$(cat "$NETSHIFT_CACHE_BACKUP")" = "db-1" ]'

# S5: selection changed -> copy retaken.
SELECTION="$(printf 'main-out\tnode-a')"
snapshot_sing_box_cache
check cp-snapshot-new-selection-rewrites '[ "$(cat "$NETSHIFT_CACHE_BACKUP")" = "db-2-fakeip-churn" ] && [ "$(cat "$NETSHIFT_CACHE_SELECTION")" = "$SELECTION" ]'

# S6: copy from 0.9.3/0.9.4 without a selection file -> retaken once.
reset_state
live_db 'db-3'
printf 'legacy-db' > "$NETSHIFT_CACHE_BACKUP"
snapshot_sing_box_cache
check cp-snapshot-legacy-copy-retaken '[ "$(cat "$NETSHIFT_CACHE_BACKUP")" = "db-3" ] && [ -f "$NETSHIFT_CACHE_SELECTION" ]'

# S7: sing-box writes the DB during every copy -> old copy kept, no torn file.
reset_state
live_db 'db-4'
printf 'good-db' > "$NETSHIFT_CACHE_BACKUP"
cp() { command cp "$@"; printf 'x' >> "$LIVE"; }
sleep() { :; }
snapshot_sing_box_cache
unset -f cp sleep
check cp-snapshot-unstable-keeps-old-copy '[ "$(cat "$NETSHIFT_CACHE_BACKUP")" = "good-db" ] && [ ! -f "$NETSHIFT_CACHE_SELECTION" ]'
check cp-snapshot-unstable-no-leftover-tmp '[ ! -e "$NETSHIFT_CACHE_BACKUP.tmp" ]'
check cp-snapshot-unstable-logs-warn 'grep -q "^warn Could not copy" "$LOG"'

# S8: sing-box writes during the first copy only -> the retry succeeds.
reset_state
live_db 'db-5'
CP_CALLS=0
cp() { command cp "$@"; CP_CALLS=$((CP_CALLS + 1)); [ "$CP_CALLS" -eq 1 ] && printf 'y' >> "$LIVE"; return 0; }
sleep() { :; }
snapshot_sing_box_cache
unset -f cp sleep
check cp-snapshot-retry-after-write '[ "$(cat "$NETSHIFT_CACHE_BACKUP")" = "db-5y" ]'

# S9: cache_path on flash -> nothing copied.
reset_state
CFG_CACHE_PATH="$CP_DIR/flash/cache.db"
mkdir -p "$CP_DIR/flash"
printf 'flash-db' > "$CFG_CACHE_PATH"
sing_box_cache_is_volatile() { return 1; }
snapshot_sing_box_cache
eval "$(extract sing_box_cache_is_volatile)"
check cp-snapshot-skips-flash-cache-path '[ ! -e "$NETSHIFT_CACHE_BACKUP" ]'

# ── monitor_sing_box: periodic check catches dashboard picks ───────────
# Seven healthy 10 s ticks, then sing-box is gone and the stop was clean.
MONITOR_PIDFILE="$CP_DIR/monitor.pid"
MONITOR_CHECK_INTERVAL=10
MONITOR_CACHE_SNAPSHOT_INTERVAL=60
TICKS=0
SNAPSHOTS=0
sleep() { :; }
sing_box_process_exists() { TICKS=$((TICKS + 1)); [ "$TICKS" -le 7 ]; }
snapshot_sing_box_cache() { SNAPSHOTS=$((SNAPSHOTS + 1)); }
monitor_sing_box
check cp-monitor-snapshots-once-per-minute '[ "$SNAPSHOTS" = "1" ]'

# ── restore marks the cache as restored; a crash then heals it ─────────
# H1: a restore records that the cache now running came from the copy.
reset_state
printf 'saved-db' > "$NETSHIFT_CACHE_BACKUP"
restore_sing_box_cache
check cp-restore-sets-restored-flag '[ -f "$NETSHIFT_CACHE_RESTORED_FLAG" ]'

# H2: a crash after a restore drops the restored DB and the copy, so the next
#     start is clean instead of failing on the same file after every reboot.
discard_restored_sing_box_cache
check cp-heal-drops-restored-cache '[ ! -e "$LIVE" ] && [ ! -e "$NETSHIFT_CACHE_BACKUP" ] && [ ! -e "$NETSHIFT_CACHE_RESTORED_FLAG" ]'

# H3: without a restore this boot, nothing is dropped.
reset_state
live_db 'live-db'
printf 'good-db' > "$NETSHIFT_CACHE_BACKUP"
discard_restored_sing_box_cache
check cp-heal-noop-without-restore '[ -e "$LIVE" ] && [ -e "$NETSHIFT_CACHE_BACKUP" ]'

# H4: the monitor heals on the first crash after a restore, not only when the
#     function is called directly.
reset_state
live_db 'live-db'
printf 'bad-db' > "$NETSHIFT_CACHE_BACKUP"
mkdir -p "$(dirname "$NETSHIFT_CACHE_RESTORED_FLAG")"
: > "$NETSHIFT_CACHE_RESTORED_FLAG"
MONITOR_PIDFILE="$CP_DIR/monitor-heal.pid"
MONITOR_MAX_CRASHES=1
CFG_SHUTDOWN="0"
dnsmasq_restore() { :; }
sing_box_process_exists() { return 1; }
monitor_sing_box
check cp-monitor-heals-restored-cache '[ ! -e "$NETSHIFT_CACHE_BACKUP" ] && [ ! -e "$LIVE" ]'

# H5: dont_touch_dhcp. The user owns /etc/config/dhcp then, so a crash must
#     neither restore nor re-configure dnsmasq (the restore used to wipe their
#     DNS forwardings: issue #40); without the flag both still happen. The run
#     is crash -> recovery restart -> crash again -> give up.
for DTD in 0 1; do
    reset_state
    CFG_SHUTDOWN="0"
    CFG_DONT_TOUCH_DHCP="$DTD"
    RESTORED=0
    CONFIGURED=0
    dnsmasq_restore() { RESTORED=$((RESTORED + 1)); }
    dnsmasq_configure() { CONFIGURED=$((CONFIGURED + 1)); }
    stop_main() { :; }
    start_main() { return 0; }
    MONITOR_PIDFILE="$CP_DIR/monitor-dhcp$DTD.pid"
    MONITOR_MAX_CRASHES=2
    MONITOR_BACKOFF_BASE=1
    MONITOR_BACKOFF_MAX=1
    : > "$LOG"
    sing_box_process_exists() { return 1; }
    monitor_sing_box
    if [ "$DTD" = "1" ]; then
        check cp-monitor-dont-touch-skips-restore '[ "$RESTORED" = "0" ]'
        check cp-monitor-dont-touch-skips-reconfigure '[ "$CONFIGURED" = "0" ]'
        check cp-monitor-dont-touch-log-honest '! grep -q "restoring DNS\|Restoring DNS" "$LOG"'
    else
        check cp-monitor-restores-without-dont-touch '[ "$RESTORED" = "2" ]'
        check cp-monitor-reconfigures-without-dont-touch '[ "$CONFIGURED" = "1" ]'
        check cp-monitor-restore-is-logged 'grep -q "Restoring DNS" "$LOG"'
    fi
done
CFG_DONT_TOUCH_DHCP=""

# H6: ownership beats the flag. dont_touch_dhcp=1 switched on AFTER NetShift had
#     configured dnsmasq must still get that undone on a crash/stop (the sentinel
#     says the values are ours); with the flag on and the sentinel clear nothing
#     is touched (the original #40 case).
for CASE in "1 1 yes" "1 0 no" "0 0 yes" "0 1 yes"; do
    set -- $CASE
    CFG_DONT_TOUCH_DHCP="$1"
    CFG_NS_CONFIGURED="$2"
    WANT="$3"
    if dnsmasq_should_be_restored; then GOT=yes; else GOT=no; fi
    check "cp-restore-decision-flag$1-configured$2" '[ "$GOT" = "$WANT" ]'
done
reset_state
CFG_SHUTDOWN="0"
CFG_DONT_TOUCH_DHCP="1"
CFG_NS_CONFIGURED="1"
RESTORED=0
dnsmasq_restore() { RESTORED=$((RESTORED + 1)); }
MONITOR_PIDFILE="$CP_DIR/monitor-owned.pid"
MONITOR_MAX_CRASHES=1
sing_box_process_exists() { return 1; }
monitor_sing_box
check cp-monitor-restores-owned-dnsmasq-despite-flag '[ "$RESTORED" = "1" ]'
check cp-stop-uses-restore-decision 'extract stop | grep -qE "^[[:space:]]*if dnsmasq_should_be_restored"'
CFG_DONT_TOUCH_DHCP=""
CFG_NS_CONFIGURED=""

# ── clash_api 204 branch snapshots the cache (the LuCI pick) ───────────
# A grep of the source cannot tell a real call from a commented-out one, so
# drive the branch: a successful PATCH answers 204 and must snapshot inline,
# a 404 must not.
reset_state
live_db 'live-db'
SELECTION="$(printf 'main-out\tnode-a')"
SNAPSHOTS=0
snapshot_sing_box_cache() { SNAPSHOTS=$((SNAPSHOTS + 1)); }
curl() { printf '\n204'; }
clash_api set_group_proxy main-out node-a > /dev/null 2>&1
check cp-clash-api-204-snapshots '[ "$SNAPSHOTS" = "1" ]'
curl() { printf '\n404'; }
SNAPSHOTS=0
clash_api set_group_proxy main-out node-a > /dev/null 2>&1
check cp-clash-api-404-no-snapshot '[ "$SNAPSHOTS" = "0" ]'
eval "$(extract snapshot_sing_box_cache)"

# ── wiring in the shipped bin ──────────────────────────────────────────
# An UNCOMMENTED call, not just the token appearing somewhere: a commented-out
# call must fail these.
start_body="$(extract start_main)"
check cp-start-restores-before-sing-box 'printf "%s\n" "$start_body" | awk "/^[[:space:]]*restore_sing_box_cache/{r=NR} /sing-box start/{s=NR} END{exit !(r && s && r < s)}"'
check cp-set-group-proxy-snapshots 'extract clash_api | awk "/^        204\\)/{p=1} p&&/;;/{exit} p" | grep -qE "^[[:space:]]*snapshot_sing_box_cache"'
check cp-stop-does-not-snapshot '! extract stop_main | grep -qE "^[[:space:]]*snapshot_sing_box_cache"'
check cp-monitor-heals-on-crash 'extract monitor_sing_box | grep -qE "^[[:space:]]*discard_restored_sing_box_cache"'

rm -rf "$CP_DIR"
echo DONE
CPEOF
    sed -i -e "s|BIN_PATH|$bin|g" -e "s|LIB_DIR|$lib|g" "$drv"

    sh "$drv" > "$out" 2>&1 || true

    local line saw_done=0
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "${line%:OK}" ;;
            *:FAIL) fail "$line" ;;
            DONE) saw_done=1 ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "cp-driver-completed"
    else
        fail "cp-driver-completed:FAIL (driver aborted early)" "$(tail -5 "$out" 2>/dev/null)"
    fi

    rm -f "$drv" "$out"
}

# ─────────────────────────────────────────────────────────────────
# Test: URL of the dashboard latency test
# ─────────────────────────────────────────────────────────────────
# The `latency_test_url` setting of clash_api, extracted verbatim from the bin:
# default when absent, a configured http(s) URL is used, anything else falls back
# to the default and says so in the log.
test_latency_url() {
    header "Latency test URL"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ] || ! command -v jq > /dev/null 2>&1; then
        skip "netshift bin / constants.sh / jq not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        . "${NETSHIFT_LIB_DIR}/helpers.sh"
        LOGF="/tmp/netshift-ltu-log-$$"
        : > "$LOGF"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$LOGF"; }
        eval "$(awk -v f="clash_api" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"

        get_service_listen_address() { echo ""; }
        config_get_bool() { eval "$1=0"; }
        config_get() {
            case "$3" in
            latency_test_url) if [ "${LTU_SET:-0}" = 1 ]; then eval "$1=\"\$LTU\""; else eval "$1=\"\${LTU:-$4}\""; fi ;;
            *) eval "$1=\"$4\"" ;;
            esac
        }
        curl() { local a; for a in "$@"; do case "$a" in url=*) echo "{\"$a\":1}" ;; esac; done; }
        asked() { clash_api get_proxy_latency p | jq -r 'keys[0]'; }
        LTU=""; echo "latency-default:$(asked)"
        echo "latency-default-silent:$(grep -c 'Invalid latency_test_url' "$LOGF")"
        LTU="https://cp.cloudflare.com/generate_204"; echo "latency-custom:$(asked)"
        : > "$LOGF"
        LTU="not a url"; echo "latency-invalid-falls-back:$(asked)"
        echo "latency-invalid-warned:$(grep -c "^\[warn\] Invalid latency_test_url 'not a url" "$LOGF")"
        LTU="ftp://example.com/x"; echo "latency-bad-scheme-falls-back:$(asked)"
        : > "$LOGF"; LTU_SET=1; LTU=""; echo "latency-empty-uses-default:$(asked) warned=$(grep -c 'Invalid latency_test_url' "$LOGF")"
        : > "$LOGF"; LTU="https://user:secret@example.com/x y"; asked > /dev/null
        echo "latency-warning-redacted:$(grep -c 'secret' "$LOGF")"
        LTU_SET=0
        rm -f "$LOGF"
    )"

    _ltu_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _ltu_check "latency test: default URL when the setting is absent" 'latency-default:url=https://www.gstatic.com/generate_204'
    _ltu_check "latency test: the default is not reported as invalid" 'latency-default-silent:0'
    _ltu_check "latency test: configured URL is used" 'latency-custom:url=https://cp.cloudflare.com/generate_204'
    _ltu_check "latency test: an invalid URL falls back to the default" 'latency-invalid-falls-back:url=https://www.gstatic.com/generate_204'
    _ltu_check "latency test: ...and the log says so" 'latency-invalid-warned:1'
    _ltu_check "latency test: a non-http scheme falls back to the default" 'latency-bad-scheme-falls-back:url=https://www.gstatic.com/generate_204'
    _ltu_check "latency test: an empty option (cleared field) uses the default without a warning" 'latency-empty-uses-default:url=https://www.gstatic.com/generate_204 warned=0'
    _ltu_check "latency test: the warning does not leak credentials of the value" 'latency-warning-redacted:0'
}

# ─────────────────────────────────────────────────────────────────
# Test: subscription country filters
# ─────────────────────────────────────────────────────────────────
# country_code_to_flag_emoji / build_subscription_filter_json (country codes turn
# into the flag emoji of the server names and join the keyword filter), extracted
# verbatim from the bin.
test_urltest_filters() {
    header "Subscription country filters"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ] || ! command -v jq > /dev/null 2>&1; then
        skip "netshift bin / constants.sh / jq not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> /tmp/netshift-uf-log-$$; }
        : > /tmp/netshift-uf-log-$$
        for fn in country_code_to_flag_emoji append_subscription_filter_country_handler \
            build_subscription_filter_json build_subscription_filter_keywords_json \
            append_subscription_filter_keyword_handler; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done

        NL="$(printf '\360\237\207\263\360\237\207\261')"
        DE="$(printf '\360\237\207\251\360\237\207\252')"
        [ "$(country_code_to_flag_emoji NL)" = "$NL" ] && echo "flag-NL:ok" || echo "flag-NL:wrong"
        [ "$(country_code_to_flag_emoji de)" = "$DE" ] && echo "flag-lowercase:ok" || echo "flag-lowercase:wrong"
        for bad in "" N NLD 1A "N L" "ру"; do
            country_code_to_flag_emoji "$bad" > /dev/null && echo "flag-bad-[$bad]:accepted" || echo "flag-bad-[$bad]:rejected"
        done

        # UCI stubs: lists come from FILTER_<option> (space separated)
        FILTER_subscription_filter_include_keywords="Premium"
        FILTER_subscription_filter_include_countries="NL de bogus nl"
        FILTER_subscription_filter_exclude_keywords=""
        FILTER_subscription_filter_exclude_countries="DE"
        config_list_foreach() {
            local _v _i
            eval "_v=\"\${FILTER_$2:-}\""
            for _i in $_v; do "$3" "$_i"; done
        }
        append_subscription_filter_keyword_handler() {
            SUBSCRIPTION_FILTER_KEYWORDS_JSON="$(printf '%s' "$SUBSCRIPTION_FILTER_KEYWORDS_JSON" | jq -c --arg k "$1" '. + [$k]')"
        }
        inc="$(build_subscription_filter_json s subscription_filter_include_keywords subscription_filter_include_countries)"
        exc="$(build_subscription_filter_json s subscription_filter_exclude_keywords subscription_filter_exclude_countries)"
        [ "$(printf '%s' "$inc" | jq -c --arg nl "$NL" --arg de "$DE" '. == ["Premium"] + ([$de, $nl] | unique)')" = true ] && echo "include-merged-unique:ok" || echo "include-merged-unique:wrong [$inc]"
        [ "$(printf '%s' "$exc" | jq -c --arg de "$DE" '. == [$de]')" = true ] && echo "exclude-countries-only:ok" || echo "exclude-countries-only:wrong [$exc]"
        grep -q "^\[warn\] Ignoring subscription country filter 'bogus'" /tmp/netshift-uf-log-$$ && echo "bad-code-warned:ok" || echo "bad-code-warned:no"
        FILTER_subscription_filter_include_keywords=""; FILTER_subscription_filter_include_countries=""
        [ "$(build_subscription_filter_json s subscription_filter_include_keywords subscription_filter_include_countries)" = "[]" ] && echo "no-filter-empty:ok" || echo "no-filter-empty:wrong"

        rm -f /tmp/netshift-uf-log-$$
    )"

    _uf_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _uf_check "NL becomes the Netherlands flag emoji" "flag-NL:ok"
    _uf_check "lowercase codes work" "flag-lowercase:ok"
    _uf_check "empty code is rejected" "flag-bad-[]:rejected"
    _uf_check "one letter is rejected" "flag-bad-[N]:rejected"
    _uf_check "three letters are rejected" "flag-bad-[NLD]:rejected"
    _uf_check "digits are rejected" "flag-bad-[1A]:rejected"
    _uf_check "a space inside is rejected" "flag-bad-[N L]:rejected"
    _uf_check "non-latin letters are rejected" "flag-bad-[ру]:rejected"
    _uf_check "include = keywords + country flags, without duplicates" "include-merged-unique:ok"
    _uf_check "exclude countries alone make an exclude filter" "exclude-countries-only:ok"
    _uf_check "an invalid country code is warned about" "bad-code-warned:ok"
    _uf_check "no keywords and no countries: empty filter (unchanged behaviour)" "no-filter-empty:ok"
}
# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
main() {
    printf "${BOLD}Netshift Evolution — Smoke Test Suite${NC}\n"
    printf "Source: %s\n" "$NETSHIFT_SRC"
    printf "OpenWrt: %s\n" "$(grep OPENWRT_RELEASE /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
    printf "Kernel: %s\n" "$(uname -r 2>/dev/null || echo 'unknown')"
    printf "\n"

    local target="${1:-all}"

    case "$target" in
        all)
            test_deps
            test_syntax
            test_config
            test_helpers
            test_jq_helpers
            test_config_manager
            test_sing_box_config
            test_proxy_link_escaping
            test_nft
            test_nft_ipv6
            test_selective_marking
            test_section_isolation
            test_monitor_fd_hygiene
            test_unsupported_skip
            test_extended_gate_skip
            test_vless_encryption
            test_text_list_outbound
            test_ruleset_chunk_size
            test_domain_case
            test_diagnostics
            test_subscription
            test_fastest_group
            test_feed_groups
            test_insecure_fetch
            test_rejected_hash
            test_jobstate
            test_selfheal
            test_dns_via_outbound
            test_dns_client_subnet
            test_sub_url_option
            test_sub_cron
            test_global_proxy
            test_section_disabled
            test_bittorrent_direct
            test_check_update_stable
            test_check_update_extended
            test_sing_box_extended_arm_arch
            test_sing_box_lite
            test_check_update_netshift
            test_netshift_latest_tag
            test_github_redirect_tag
            test_self_update_netshift
            test_backup_integrity
            test_hot_reload
            test_domain_separators
            test_cache_persist
            test_latency_url
            test_urltest_filters
            ;;
        deps)        test_deps ;;
        syntax)      test_syntax ;;
        config)      test_config ;;
        helpers)     test_helpers ;;
        nft)         test_nft ;;
        nftv6)       test_nft_ipv6 ;;
        selmark)     test_selective_marking ;;
        isolation)   test_section_isolation ;;
        monfd)       test_monitor_fd_hygiene ;;
        unsupported) test_unsupported_skip ;;
        extgate)     test_extended_gate_skip ;;
        vlessenc)    test_vless_encryption ;;
        textlist)    test_text_list_outbound ;;
        chunkcheck)  test_ruleset_chunk_size ;;
        domcase)     test_domain_case ;;
        diagnostics) test_diagnostics ;;
        subscription) test_subscription ;;
        fastest)     test_fastest_group ;;
        feedgroups)  test_feed_groups ;;
        insecure)    test_insecure_fetch ;;
        rejected)    test_rejected_hash ;;
        jobstate)    test_jobstate ;;
        selfheal)    test_selfheal ;;
        dnsdetour)   test_dns_via_outbound ;;
        ecssubnet)   test_dns_client_subnet ;;
        suburlopt)   test_sub_url_option ;;
        subcron)     test_sub_cron ;;
        globalproxy) test_global_proxy ;;
        sectiondisabled) test_section_disabled ;;
        bittorrent)  test_bittorrent_direct ;;
        stablecheck) test_check_update_stable ;;
        extcheck)    test_check_update_extended ;;
        sbextarch)   test_sing_box_extended_arm_arch ;;
        sbextlite)   test_sing_box_lite ;;
        netshiftcheck) test_check_update_netshift ;;
        latesttag)   test_netshift_latest_tag ;;
        ghredirect)  test_github_redirect_tag ;;
        selfupdate)  test_self_update_netshift ;;
        backupguard) test_backup_integrity ;;
        hotreload)   test_hot_reload ;;
        domsep)      test_domain_separators ;;
        cachepersist) test_cache_persist ;;
        latencyurl)  test_latency_url ;;
        jq)          test_jq_helpers ;;
        cm)          test_config_manager ;;
        sb)          test_sing_box_config ;;
        proxylink)   test_proxy_link_escaping ;;
        utfilters)   test_urltest_filters ;;
        *)
            echo "Unknown test: $target"
            echo "Available: all deps syntax config helpers jq cm sb nft nftv6 selmark isolation monfd unsupported extgate vlessenc textlist chunkcheck domsep domcase proxylink diagnostics subscription fastest feedgroups insecure rejected jobstate selfheal dnsdetour ecssubnet suburlopt subcron globalproxy sectiondisabled bittorrent stablecheck extcheck sbextarch sbextlite netshiftcheck latesttag ghredirect selfupdate backupguard hotreload cachepersist latencyurl utfilters"
            exit 1
            ;;
    esac

    summary
}

main "$@"
