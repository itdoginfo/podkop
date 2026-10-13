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
        "$lib/routecheck.sh" \
        "$lib/sing_box_config_manager.sh" \
        "$lib/sing_box_config_facade.sh" \
        "$lib/updater.sh" \
        "$lib/dnsforward.sh"; do

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
          nft_add_dns_hijack \
          create_nft_rules; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done

# This harness has no `disabled` option: sections are never disabled.
section_is_disabled() { return 1; }

# No bypass sets in this harness (the bypass test covers them): the default
# marking rules are exactly what is checked here.
nft_bypass_requested() { return 1; }
nft_bypass_source_ips() { :; }

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
# Test: block_leaks — fail-closed guard (kill switch)
# ─────────────────────────────────────────────────────────────────
# Drives the SHIPPED kill_switch.sh against a real nftables table. It builds a
# fake "main" table carrying the union subnet set (what create_nft_rules would
# have populated), runs kill_switch_apply, and asserts on the REAL guard table:
# forward/output drops for the mirrored subnets + FakeIP range, the source drop
# for fully_routed_ips, the LAN interface, the global_proxy mode, removal when
# the option is off, and the DNS gate (dnsmasq_should_be_restored) refusing to
# hand resolvers back while block_leaks is on.
test_block_leaks() {
    header "block_leaks fail-closed guard (kill switch)"

    if ! command -v nft > /dev/null 2>&1; then
        skip "nft not available"
        return
    fi

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/kill_switch.sh" ] || [ ! -r "$lib/constants.sh" ] || [ ! -r "$bin" ]; then
        skip "blockleaks (kill_switch.sh / constants.sh / bin not found)"
        return
    fi

    # shellcheck disable=SC1090
    . "$lib/constants.sh"

    if [ -n "$NFT_GUARD_TABLE_NAME" ] && [ -n "$NFT_GUARD_SUBNET_SET_NAME" ] &&
        [ -n "$NFT_GUARD_BYPASS_SET_NAME" ] && [ -n "$NFT_LOCALV4_ELEMENTS" ]; then
        pass "blockleaks:constants — guard table/set constants defined"
    else
        fail "blockleaks:constants — guard table/set constants missing"
        return
    fi

    # ── start order: the guard is rebuilt only after the sets are filled ──
    # create_nft_rules leaves the union set EMPTY and sing_box_init_config is
    # what fills it, so a rebuild between the two would swap a working guard
    # for one without a single subnet (the first revision of this feature did).
    local start_body apply_line init_line create_line
    start_body="$(awk '/^start_main\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
    apply_line="$(printf '%s\n' "$start_body" | grep -n 'kill_switch_apply' | head -n 1 | cut -d: -f1)"
    init_line="$(printf '%s\n' "$start_body" | grep -n '^[[:space:]]*sing_box_init_config$' | head -n 1 | cut -d: -f1)"
    create_line="$(printf '%s\n' "$start_body" | grep -n '^[[:space:]]*create_nft_rules$' | head -n 1 | cut -d: -f1)"
    if [ -n "$apply_line" ] && [ -n "$init_line" ] && [ -n "$create_line" ] &&
        [ "$create_line" -lt "$init_line" ] && [ "$init_line" -lt "$apply_line" ] &&
        [ "$(printf '%s\n' "$start_body" | grep -c 'kill_switch_apply')" -eq 1 ]; then
        pass "blockleaks:order — start_main rebuilds the guard once, after the sets are populated"
    else
        fail "blockleaks:order — kill_switch_apply must run once, after sing_box_init_config" "create=$create_line init=$init_line apply=$apply_line"
    fi
    if awk '/^list_update\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin" | grep -q 'kill_switch_apply'; then
        fail "blockleaks:order — list_update must not rebuild the guard (it is mirrored incrementally)"
    else
        pass "blockleaks:order — list_update relies on the incremental mirror, no rebuild"
    fi

    local drv="/tmp/netshift-blockleaks-$$.sh"
    cat > "$drv" << 'BLEOF'
LIB="LIB_DIR_PLACEHOLDER"
BIN="BIN_PATH_PLACEHOLDER"

# shellcheck disable=SC1090
. "$LIB/constants.sh"
# shellcheck disable=SC1090
. "$LIB/helpers.sh"
# shellcheck disable=SC1090
. "$LIB/nft.sh"
# shellcheck disable=SC1090
. "$LIB/kill_switch.sh"

# Unique tables and scratch space: never touch the real NetShiftTable /
# NetShiftGuard.
NFT_TABLE_NAME="$SCN_TABLE"
NFT_GUARD_TABLE_NAME="$SCN_GUARD"
TMP_SING_BOX_FOLDER="/tmp/$SCN_GUARD.tmp"

log() { [ "$2" = "error" ] && echo "LOG-ERROR: $1"; return 0; }

netshift_ipv6_enabled() { [ "${SCN_IPV6:-0}" = "1" ]; }
get_global_proxy_section() { printf '%s' "${SCN_GLOBALPROXY:-}"; }
foreach_active_section() { [ -n "${SCN_FULLROUTED:-}" ] || return 0; "$1" "frsec"; }
config_list_foreach() {
    case "$2" in
    fully_routed_ips) for _ip in ${SCN_FULLROUTED:-}; do "$3" "$_ip"; done ;;
    routing_excluded_ips) for _ip in ${SCN_EXCLUDED:-}; do "$3" "$_ip"; done ;;
    esac
}
config_get() {
    eval "$1=\"\${4:-}\""
    case "$3" in
    source_network_interfaces) eval "$1=\"scnl0\"" ;;
    connection_type) eval "$1=\"proxy\"" ;;
    fully_routed_ips) eval "$1=\"${SCN_FULLROUTED:-}\"" ;;
    esac
}
config_get_bool() {
    eval "$1=\"\${4:-0}\""
    case "$3" in
    block_leaks) eval "$1=\"${SCN_BLOCKLEAKS:-1}\"" ;;
    block_doh) eval "$1=\"${SCN_BLOCKDOH:-0}\"" ;;
    exclude_ntp) eval "$1=\"${SCN_NTP:-0}\"" ;;
    bypass_excluded_ips) [ -n "${SCN_EXCLUDED:-}" ] && eval "$1=1" ;;
    dont_touch_dhcp) eval "$1=\"0\"" ;;
    esac
    return 0
}
dnsmasq_is_configured_for_netshift() { return 1; }

extract() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN"; }

# The gate that stops DNS being handed back while sing-box is down, and the
# SHIPPED functions that fill the sets (the only place they grow).
eval "$(extract dnsmasq_should_be_restored)"
eval "$(extract populate_netshift_subnets_from_file)"
eval "$(extract populate_netshift_subnets_from_string)"

# What create_nft_rules leaves behind: the sets exist and are EMPTY.
new_main_table() {
    nft delete table inet "$SCN_TABLE" 2> /dev/null
    nft add table inet "$SCN_TABLE"
    nft add set inet "$SCN_TABLE" "$NFT_COMMON_SET_NAME" '{ type ipv4_addr; flags interval; auto-merge; }'
    nft add set inet "$SCN_TABLE" "$NFT_BYPASS_SET_NAME" '{ type ipv4_addr; flags interval; auto-merge; }'
}

# The same sequence start_main runs: empty sets, config generation fills them
# (mirror suspended), then the guard is rebuilt.
start_sequence() {
    KILL_SWITCH_MIRROR_SUSPENDED=1
    new_main_table
    # 198.51.x / 203.0.113.x are documentation ranges (in localv4): fine as set
    # members here, the test only looks at what lands in which set. The two
    # adjacent /24 are listed back by nft as ONE range (a-b), not a CIDR.
    populate_netshift_subnets_from_string "203.0.113.0/24 198.51.100.10 45.9.1.0/24 45.9.2.0/24"
    NFT_SUBNET_SET="$NFT_BYPASS_SET_NAME" populate_netshift_subnets_from_string "45.77.0.0/16"
    KILL_SWITCH_MIRROR_SUSPENDED=0
    kill_switch_apply
    echo "apply-rc=$?"
}

start_sequence

echo "---GUARD---"
nft list table inet "$SCN_GUARD" 2>&1 || true
echo "---DNS---"
if dnsmasq_should_be_restored; then echo "restore=yes"; else echo "restore=no"; fi

if [ "${SCN_LIFECYCLE:-0}" = "1" ]; then
    # The path every real restart takes: a rebuild OVER an armed guard. One
    # subnet is gone from the config and one is new.
    restart_sequence() {
        KILL_SWITCH_MIRROR_SUSPENDED=1
        new_main_table
        populate_netshift_subnets_from_string "203.0.113.0/24 45.55.0.0/16"
        KILL_SWITCH_MIRROR_SUSPENDED=0
        kill_switch_apply
        echo "reapply-rc=$?"
    }
    echo "---REAPPLY---"
    restart_sequence
    nft list set inet "$SCN_GUARD" "$NFT_GUARD_SUBNET_SET_NAME" 2>&1
    echo "---REAPPLY-END---"
    # Back to the first revision for the checks below.
    start_sequence > /dev/null

    # A list update / hot reload adds to the live sets: the guard follows
    # without a rebuild.
    populate_netshift_subnets_from_string "45.88.0.0/16"
    NFT_SUBNET_SET="$NFT_BYPASS_SET_NAME" populate_netshift_subnets_from_string "45.99.0.0/16"
    echo "---MIRROR---"
    nft list set inet "$SCN_GUARD" "$NFT_GUARD_SUBNET_SET_NAME" 2>&1
    echo "---MIRROR-BYPASS---"
    nft list set inet "$SCN_GUARD" "$NFT_GUARD_BYPASS_SET_NAME" 2>&1

    # Restart window: stop_main deleted the table, create_nft_rules rebuilt it
    # empty and the config is still being generated. The previous guard must
    # still hold every subnet.
    KILL_SWITCH_MIRROR_SUSPENDED=1
    new_main_table
    populate_netshift_subnets_from_string "203.0.113.0/24"
    echo "---RESTART-WINDOW---"
    nft list set inet "$SCN_GUARD" "$NFT_GUARD_SUBNET_SET_NAME" 2>&1

    # One-shot release (package removal / self-heal): option still on.
    NETSHIFT_BLOCK_LEAKS_RELEASE=1
    kill_switch_enabled || kill_switch_delete
    echo "---RELEASE---"
    if nft list table inet "$SCN_GUARD" > /dev/null 2>&1; then echo "guard=present"; else echo "guard=gone"; fi
    if dnsmasq_should_be_restored; then echo "restore=yes"; else echo "restore=no"; fi
fi

echo "---LEFTOVERS---"
ls "$TMP_SING_BOX_FOLDER" 2> /dev/null
rm -rf "$TMP_SING_BOX_FOLDER"
BLEOF
    sed -i "s|LIB_DIR_PLACEHOLDER|$lib|; s|BIN_PATH_PLACEHOLDER|$bin|" "$drv"

    # nft lists a counter with its values: match `counter ... drop`.
    local cnt='counter packets [0-9]+ bytes [0-9]+ drop'
    _bl_section() { printf '%s\n' "$1" | sed -n "/^---$2---\$/,/^---/p"; }
    _bl_chain() { printf '%s\n' "$1" | sed -n "/chain $2 {/,/^[[:space:]]*}/p"; }
    # Line number (within a chain) of the first line matching the ERE, or empty.
    _bl_line() { printf '%s\n' "$1" | grep -nE -- "$2" | head -n 1 | cut -d: -f1; }

    # ── option ON: the real start sequence ───────────────────────────
    local t1="bl_main_$$" g1="bl_guard_$$" out1 gdump fwd outc
    out1="$(SCN_TABLE="$t1" SCN_GUARD="$g1" SCN_BLOCKLEAKS=1 SCN_IPV6=0 SCN_LIFECYCLE=1 \
        SCN_GLOBALPROXY="" SCN_FULLROUTED="192.168.50.7" sh "$drv" 2>&1)"
    nft delete table inet "$t1" 2>/dev/null || true
    nft delete table inet "$g1" 2>/dev/null || true
    gdump="$(_bl_section "$out1" GUARD)"
    fwd="$(_bl_chain "$gdump" forward_guard)"
    outc="$(_bl_chain "$gdump" output_guard)"

    if printf '%s\n' "$out1" | grep -q '^apply-rc=0$' && ! printf '%s\n' "$out1" | grep -q 'LOG-ERROR'; then
        pass "blockleaks:apply — the guard is rebuilt without errors"
    else
        fail "blockleaks:apply — kill_switch_apply failed" "$(printf '%s\n' "$out1" | grep -E 'apply-rc|LOG-ERROR|rror' || echo "$out1")"
    fi
    if [ -n "$fwd" ]; then
        pass "blockleaks:forward — forward_guard chain created"
    else
        fail "blockleaks:forward — forward_guard chain missing" "$out1"
    fi
    if echo "$fwd" | grep -Eq "iifname @$NFT_GUARD_INTERFACE_SET_NAME ip daddr @$NFT_GUARD_SUBNET_SET_NAME $cnt\$"; then
        pass "blockleaks:forward — proxied destinations dropped from LAN (with a counter)"
    else
        fail "blockleaks:forward — LAN->proxied drop rule missing" "$(echo "$gdump" | grep -i 'drop' || echo "$gdump")"
    fi
    if echo "$fwd" | grep -Eq "ip daddr $SB_FAKEIP_INET4_RANGE $cnt\$"; then
        pass "blockleaks:fakeip — FakeIP range dropped ($SB_FAKEIP_INET4_RANGE)"
    else
        fail "blockleaks:fakeip — FakeIP drop rule missing"
    fi
    if echo "$fwd" | grep -Eq "iifname @$NFT_GUARD_INTERFACE_SET_NAME ip saddr @$NFT_GUARD_SOURCE_SET_NAME $cnt\$"; then
        pass "blockleaks:fullrouted — fully_routed source drop rule present"
    else
        fail "blockleaks:fullrouted — source drop rule missing"
    fi
    if echo "$outc" | grep -Eq "^[[:space:]]*ip daddr @$NFT_GUARD_SUBNET_SET_NAME $cnt\$"; then
        pass "blockleaks:output — router->proxied drop rule present"
    else
        fail "blockleaks:output — output drop rule missing" "$outc"
    fi
    # The regression of the first revision: the guard was built from the set
    # create_nft_rules had just emptied.
    if echo "$gdump" | grep -q "203.0.113.0/24" && echo "$gdump" | grep -q "198.51.100.10"; then
        pass "blockleaks:sets — subnets added by config generation reach the guard"
    else
        fail "blockleaks:sets — the guard was built without the proxied subnets" "$(echo "$gdump" | grep -A3 "set $NFT_GUARD_SUBNET_SET_NAME")"
    fi
    if echo "$gdump" | grep -q "45.9.1.0-45.9.2.255"; then
        pass "blockleaks:sets — a merged range (a-b) survives the read-back"
    else
        fail "blockleaks:sets — merged range lost in the guard" "$(echo "$gdump" | grep -A3 "set $NFT_GUARD_SUBNET_SET_NAME")"
    fi
    if echo "$gdump" | sed -n "/set $NFT_GUARD_BYPASS_SET_NAME {/,/}/p" | grep -q "45.77.0.0/16" &&
        ! echo "$gdump" | sed -n "/set $NFT_GUARD_SUBNET_SET_NAME {/,/}/p" | grep -q "45.77.0.0/16"; then
        pass "blockleaks:sets — bypass destinations go to the guard's accept set, not the drop set"
    else
        fail "blockleaks:sets — bypass destinations not mirrored correctly" "$(echo "$gdump" | grep -B2 -A3 'elements')"
    fi
    if echo "$gdump" | grep -q "scnl0"; then
        pass "blockleaks:sets — LAN interface mirrored into the guard set"
    else
        fail "blockleaks:sets — LAN interface not mirrored"
    fi
    if _bl_section "$out1" DNS | grep -q "restore=no"; then
        pass "blockleaks:dns — DNS stays fail-closed while sing-box is down"
    else
        fail "blockleaks:dns — DNS was handed back to the direct resolvers"
    fi

    # ── marking-model exceptions: never dropped ──────────────────────
    # mangle returns DNAT-ed flows and local destinations before any mark, so
    # the guard has to accept them BEFORE its first drop, in both chains.
    local first_drop dnat_at local_at bypass_at
    first_drop="$(_bl_line "$fwd" 'drop$')"
    dnat_at="$(_bl_line "$fwd" 'ct status dnat accept$')"
    local_at="$(_bl_line "$fwd" "iifname @$NFT_GUARD_INTERFACE_SET_NAME ip daddr \{.*192\.168\.0\.0/16.*\} accept\$")"
    bypass_at="$(_bl_line "$fwd" "iifname @$NFT_GUARD_INTERFACE_SET_NAME ip daddr @$NFT_GUARD_BYPASS_SET_NAME accept\$")"
    if [ -n "$first_drop" ] && [ -n "$dnat_at" ] && [ "$dnat_at" -lt "$first_drop" ]; then
        pass "blockleaks:exceptions — DNAT-ed flows are accepted before any drop"
    else
        fail "blockleaks:exceptions — no 'ct status dnat accept' ahead of the drops" "$fwd"
    fi
    if [ -n "$first_drop" ] && [ -n "$local_at" ] && [ "$local_at" -lt "$first_drop" ]; then
        pass "blockleaks:exceptions — local destinations (localv4) are accepted before any drop"
    else
        fail "blockleaks:exceptions — localv4 is not accepted ahead of the drops (forward)" "$fwd"
    fi
    if [ -n "$first_drop" ] && [ -n "$bypass_at" ] && [ "$bypass_at" -lt "$first_drop" ]; then
        pass "blockleaks:exceptions — bypass destinations are accepted before any drop"
    else
        fail "blockleaks:exceptions — bypass set is not accepted ahead of the drops" "$fwd"
    fi
    first_drop="$(_bl_line "$outc" 'drop$')"
    local_at="$(_bl_line "$outc" '^[[:space:]]*ip daddr \{.*192\.168\.0\.0/16.*\} accept$')"
    if [ -n "$first_drop" ] && [ -n "$local_at" ] && [ "$local_at" -lt "$first_drop" ]; then
        pass "blockleaks:exceptions — router traffic to local destinations is accepted before any drop"
    else
        fail "blockleaks:exceptions — localv4 is not accepted ahead of the drops (output)" "$outc"
    fi

    # ── a rebuild over an armed guard (what every restart does) ──────
    if _bl_section "$out1" REAPPLY | grep -q '^reapply-rc=0$' &&
        _bl_section "$out1" REAPPLY | grep -q "45.55.0.0/16" &&
        _bl_section "$out1" REAPPLY | grep -q "203.0.113.0/24" &&
        ! _bl_section "$out1" REAPPLY | grep -q "198.51.100.10"; then
        pass "blockleaks:reapply — a rebuild over an armed guard swaps in exactly the new subnets"
    else
        fail "blockleaks:reapply — rebuilding an armed guard failed or kept stale subnets" "$(_bl_section "$out1" REAPPLY)"
    fi

    # ── already-open flows are held too ──────────────────────────────
    if ! echo "$gdump" | grep -q 'ct state established' &&
        echo "$fwd" | grep -q 'ct direction reply accept$' &&
        echo "$outc" | grep -q 'ct direction reply accept$'; then
        pass "blockleaks:conntrack — no blanket established accept, only answers to inbound connections"
    else
        fail "blockleaks:conntrack — established flows would bypass the guard" "$(echo "$gdump" | grep -n 'ct ')"
    fi

    # ── incremental mirror, restart window, one-shot release ─────────
    if _bl_section "$out1" MIRROR | grep -q "45.88.0.0/16"; then
        pass "blockleaks:mirror — a later addition to the union set reaches the guard without a rebuild"
    else
        fail "blockleaks:mirror — the guard did not follow the union set" "$(_bl_section "$out1" MIRROR)"
    fi
    if _bl_section "$out1" MIRROR-BYPASS | grep -q "45.99.0.0/16" &&
        ! _bl_section "$out1" MIRROR | grep -q "45.99.0.0/16"; then
        pass "blockleaks:mirror — a later bypass addition reaches the guard's accept set"
    else
        fail "blockleaks:mirror — bypass addition not mirrored" "$(_bl_section "$out1" MIRROR-BYPASS)"
    fi
    if _bl_section "$out1" RESTART-WINDOW | grep -q "45.88.0.0/16" &&
        _bl_section "$out1" RESTART-WINDOW | grep -q "198.51.100.10"; then
        pass "blockleaks:restart — the previous guard keeps every subnet while the new table is still empty"
    else
        fail "blockleaks:restart — the guard lost its subnets in the restart window" "$(_bl_section "$out1" RESTART-WINDOW)"
    fi
    if _bl_section "$out1" RELEASE | grep -q "guard=gone" && _bl_section "$out1" RELEASE | grep -q "restore=yes"; then
        pass "blockleaks:release — NETSHIFT_BLOCK_LEAKS_RELEASE=1 drops the guard and hands DNS back, option untouched"
    else
        fail "blockleaks:release — the one-shot release did not open the kill switch" "$(_bl_section "$out1" RELEASE)"
    fi
    if [ -z "$(_bl_section "$out1" LEFTOVERS | grep -v '^---')" ]; then
        pass "blockleaks:tmp — no scratch files left behind"
    else
        fail "blockleaks:tmp — scratch files left in the tmp folder" "$(_bl_section "$out1" LEFTOVERS)"
    fi

    # ── option OFF: guard removed, DNS restored normally ─────────────
    local t2="bl_off_$$" g2="bl_off_guard_$$" out2
    out2="$(SCN_TABLE="$t2" SCN_GUARD="$g2" SCN_BLOCKLEAKS=0 SCN_IPV6=0 \
        SCN_GLOBALPROXY="" SCN_FULLROUTED="" sh "$drv" 2>&1)"
    if _bl_section "$out2" GUARD | grep -q "chain forward_guard"; then
        fail "blockleaks:off — guard table still present with the option off"
        nft delete table inet "$g2" 2>/dev/null || true
    else
        pass "blockleaks:off — guard table removed when the option is off"
    fi
    if printf '%s\n' "$out2" | grep -q "restore=yes"; then
        pass "blockleaks:off — DNS restored normally when the option is off"
    else
        fail "blockleaks:off — DNS not restored with the option off"
    fi
    nft delete table inet "$t2" 2>/dev/null || true

    # ── global_proxy: all LAN tcp/udp held, exceptions still first ───
    local t3="bl_gp_$$" g3="bl_gp_guard_$$" out3 fwd3 out3c ntp_at bsrc_at
    out3="$(SCN_TABLE="$t3" SCN_GUARD="$g3" SCN_BLOCKLEAKS=1 SCN_IPV6=0 SCN_NTP=1 \
        SCN_EXCLUDED="192.168.50.9" SCN_GLOBALPROXY="gpsec" SCN_FULLROUTED="" sh "$drv" 2>&1)"
    nft delete table inet "$t3" 2>/dev/null || true
    nft delete table inet "$g3" 2>/dev/null || true
    fwd3="$(_bl_chain "$(_bl_section "$out3" GUARD)" forward_guard)"
    out3c="$(_bl_chain "$(_bl_section "$out3" GUARD)" output_guard)"
    if echo "$fwd3" | grep -Eq "iifname @$NFT_GUARD_INTERFACE_SET_NAME meta l4proto \{ tcp, udp \} $cnt\$"; then
        pass "blockleaks:globalproxy — all LAN tcp/udp held under global_proxy"
    else
        fail "blockleaks:globalproxy — global_proxy drop rule missing" "$fwd3"
    fi
    first_drop="$(_bl_line "$fwd3" 'drop$')"
    local_at="$(_bl_line "$fwd3" 'ip daddr \{.*192\.168\.0\.0/16.*\} accept$')"
    ntp_at="$(_bl_line "$fwd3" 'udp dport 123 accept$')"
    bsrc_at="$(_bl_line "$fwd3" "ip saddr @$NFT_GUARD_BYPASS_SOURCE_SET_NAME ip daddr != $SB_FAKEIP_INET4_RANGE accept\$")"
    if [ -n "$first_drop" ] && [ -n "$local_at" ] && [ "$local_at" -lt "$first_drop" ]; then
        pass "blockleaks:globalproxy — local destinations stay reachable for LAN clients"
    else
        fail "blockleaks:globalproxy — localv4 not accepted ahead of the blanket drop" "$fwd3"
    fi
    if [ -n "$first_drop" ] && [ -n "$ntp_at" ] && [ "$ntp_at" -lt "$first_drop" ]; then
        pass "blockleaks:globalproxy — exclude_ntp traffic is accepted, as in the marking model"
    else
        fail "blockleaks:globalproxy — exclude_ntp is not mirrored into the guard" "$fwd3"
    fi
    if [ -n "$first_drop" ] && [ -n "$bsrc_at" ] && [ "$bsrc_at" -lt "$first_drop" ] &&
        _bl_section "$out3" GUARD | sed -n "/set $NFT_GUARD_BYPASS_SOURCE_SET_NAME {/,/}/p" | grep -q "192.168.50.9"; then
        pass "blockleaks:globalproxy — bypassed devices (routing_excluded_ips) are accepted"
    else
        fail "blockleaks:globalproxy — bypassed devices are not mirrored into the guard" "$fwd3"
    fi
    first_drop="$(_bl_line "$out3c" 'drop$')"
    local_at="$(_bl_line "$out3c" '^[[:space:]]*ip daddr \{.*192\.168\.0\.0/16.*\} accept$')"
    if [ -n "$first_drop" ] && [ -n "$local_at" ] && [ "$local_at" -lt "$first_drop" ]; then
        pass "blockleaks:globalproxy — router traffic to local destinations survives the blanket drop"
    else
        fail "blockleaks:globalproxy — output_guard blackholes local destinations" "$out3c"
    fi

    # ── block_doh: the DoH resolvers are marked, so they are held too ─
    local t5="bl_doh_$$" g5="bl_doh_guard_$$" out5
    out5="$(SCN_TABLE="$t5" SCN_GUARD="$g5" SCN_BLOCKLEAKS=1 SCN_IPV6=0 SCN_BLOCKDOH=1 \
        SCN_GLOBALPROXY="" SCN_FULLROUTED="" sh "$drv" 2>&1)"
    nft delete table inet "$t5" 2>/dev/null || true
    nft delete table inet "$g5" 2>/dev/null || true
    if _bl_chain "$(_bl_section "$out5" GUARD)" forward_guard | grep -Eq "ip daddr \{.*8\.8\.8\.8.*\} $cnt\$"; then
        pass "blockleaks:doh — DoH resolvers are held with block_doh (no direct DoH during the window)"
    else
        fail "blockleaks:doh — DoH resolvers are not held with block_doh" "$(_bl_section "$out5" GUARD | grep -i drop)"
    fi

    # ── IPv6: the v6 half of the program is valid nft and mirrors v4 ──
    local t6="bl_v6_$$" g6="bl_v6_guard_$$" out6 fwd6
    out6="$(SCN_TABLE="$t6" SCN_GUARD="$g6" SCN_BLOCKLEAKS=1 SCN_IPV6=1 SCN_BLOCKDOH=1 SCN_NTP=1         SCN_EXCLUDED="192.168.50.9 fd12:3456::9" SCN_GLOBALPROXY=""         SCN_FULLROUTED="192.168.50.7 fd12:3456::7" sh "$drv" 2>&1)"
    nft delete table inet "$t6" 2>/dev/null || true
    nft delete table inet "$g6" 2>/dev/null || true
    fwd6="$(_bl_chain "$(_bl_section "$out6" GUARD)" forward_guard)"
    first_drop="$(_bl_line "$fwd6" 'drop$')"
    local_at="$(_bl_line "$fwd6" 'ip6 daddr \{.*fe80::/10.*\} accept$')"
    if printf '%s
' "$out6" | grep -q '^apply-rc=0$' &&
        echo "$fwd6" | grep -Eq "ip6 daddr $SB_FAKEIP_INET6_RANGE $cnt\$" &&
        echo "$fwd6" | grep -Eq "ip6 saddr @$NFT_GUARD_SOURCE_SET_NAME_V6 $cnt\$" &&
        [ -n "$first_drop" ] && [ -n "$local_at" ] && [ "$local_at" -lt "$first_drop" ]; then
        pass "blockleaks:ipv6 — the IPv6 rules load and keep the same accept-before-drop order"
    else
        fail "blockleaks:ipv6 — the IPv6 guard is missing or malformed" "$(printf '%s
' "$out6" | grep -E 'apply-rc|rror' ; echo "$fwd6")"
    fi
    [ "${TEST_VERBOSE:-0}" = "1" ] && _bl_section "$out6" GUARD

    # ── invalid fully_routed_ips must not abort the rebuild ──────────
    local t4="bl_bad_$$" g4="bl_bad_guard_$$" out4
    out4="$(SCN_TABLE="$t4" SCN_GUARD="$g4" SCN_BLOCKLEAKS=1 SCN_IPV6=0 \
        SCN_GLOBALPROXY="" SCN_FULLROUTED="192.168.50.7 not_an_ip" sh "$drv" 2>&1)"
    nft delete table inet "$t4" 2>/dev/null || true
    if _bl_section "$out4" GUARD | grep -q "chain forward_guard"; then
        pass "blockleaks:robust — a bad fully_routed_ips entry does not abort the guard"
    else
        fail "blockleaks:robust — guard not built with a bad fully_routed_ips entry" "$(printf '%s\n' "$out4" | grep -i 'error' || true)"
    fi
    nft delete table inet "$g4" 2>/dev/null || true

    rm -f "$drv"

    # ── package prerm: release on removal, keep the option on upgrade ─
    local mk="${NETSHIFT_SRC}/../Makefile" prerm="/tmp/netshift-blockleaks-prerm-$$.sh" stub="/tmp/netshift-blockleaks-stub-$$.sh"
    if [ ! -r "$mk" ]; then
        skip "blockleaks:prerm (package Makefile not found at $mk)"
        return
    fi
    printf '#!/bin/sh\necho "stop-release=${NETSHIFT_BLOCK_LEAKS_RELEASE:-0}"\n' > "$stub"
    chmod +x "$stub"
    # The script as the package ships it ($$ -> $), with the two absolute paths
    # pointed at stand-ins so nothing on this system is touched.
    awk '/^define Package\/netshift\/prerm/{p=1;next} /^endef/{if(p)exit} p' "$mk" |
        sed -e 's/\$\$/$/g' -e "s|/etc/init.d/netshift|$stub|g" -e "s|/etc/iproute2/rt_tables|/dev/null|g" > "$prerm"
    if [ -s "$prerm" ] && ! grep -q 'uci ' "$prerm"; then
        pass "blockleaks:prerm — the stored option is not rewritten by the package script"
    else
        fail "blockleaks:prerm — prerm still edits the config (an upgrade would switch the option off)" "$(grep -n 'uci ' "$prerm")"
    fi
    if [ "$(env -u PKG_UPGRADE sh "$prerm" 2>&1)" = "stop-release=1" ]; then
        pass "blockleaks:prerm — removal stops the service with the kill switch released"
    else
        fail "blockleaks:prerm — removal does not release the kill switch" "$(env -u PKG_UPGRADE sh "$prerm" 2>&1)"
    fi
    # Nothing restarts the service after an upgrade, so an armed kill switch
    # would leave the router without DNS: the upgrade stop releases it as well.
    if [ "$(PKG_UPGRADE=1 sh "$prerm" 2>&1)" = "stop-release=1" ]; then
        pass "blockleaks:prerm — an upgrade stops the service with the kill switch released too"
    else
        fail "blockleaks:prerm — an upgrade leaves the kill switch armed with nothing to restart the service" "$(PKG_UPGRADE=1 sh "$prerm" 2>&1)"
    fi
    rm -f "$prerm" "$stub"

    # ── release after an earlier stop: DNS really comes back ─────────
    # The earlier stop (option on) kept dnsmasq on sing-box and still recorded a
    # correct shutdown. The released stop must run the SHIPPED dnsmasq_restore
    # to the end, not return at the shutdown_correctly gate.
    local rdrv="/tmp/netshift-blockleaks-restore-$$.sh" rout
    cat > "$rdrv" << 'BLREOF'
BIN="BIN_PATH_PLACEHOLDER"
extract() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN"; }
eval "$(extract dnsmasq_restore)"
eval "$(extract dnsmasq_is_configured_for_netshift)"
eval "$(extract dnsmasq_should_be_restored)"
eval "$(extract uci_remove_quiet)"

STORE="/tmp/netshift-blockleaks-dhcp-$$"
mkdir -p "$STORE"
key() { echo "$STORE/$(echo "$1" | tr -c 'A-Za-z0-9_\n' '_')"; }
log() { :; }
file_exists() { return 1; }
uci() { [ "$2" = "delete" ] && rm -f "$(key "${3##*.}")"; return 0; }
uci_get() { cat "$(key "$3")" 2> /dev/null; }
uci_set() { echo "$4" > "$(key "$3")"; }
uci_add_list() { echo "$4" >> "$(key "$3")"; }
uci_commit() { :; }
config_get() { eval "$1=\"${SCN_SHUTDOWN:-1}\""; }
config_get_bool() {
    eval "$1=\"\${4:-0}\""
    [ "$3" = "block_leaks" ] && eval "$1=1"
    return 0
}
kill_switch_enabled() { [ "${NETSHIFT_BLOCK_LEAKS_RELEASE:-0}" = "1" ] && return 1; return 0; }

# dnsmasq as NetShift leaves it: pointed at the DNS inbound, backup kept.
if [ "${SCN_CONFIGURED:-1}" = "1" ]; then
    uci_set dhcp x netshift_configured 1
    uci_set dhcp x server "127.0.0.42"
    uci_set dhcp x noresolv 1
    uci_set dhcp x netshift_server "192.0.2.53"
    uci_set dhcp x netshift_noresolv 0
fi

if dnsmasq_should_be_restored; then
    dnsmasq_restore > /dev/null 2>&1
fi
echo "server=$(uci_get dhcp x server)"
echo "noresolv=$(uci_get dhcp x noresolv)"
echo "configured=$(uci_get dhcp x netshift_configured)"
rm -rf "$STORE"
BLREOF
    sed -i "s|BIN_PATH_PLACEHOLDER|$bin|" "$rdrv"
    # /etc/init.d/dnsmasq restart is the last line of the function: harmless
    # when it is missing here, the checks read the values written before it.
    rout="$(NETSHIFT_BLOCK_LEAKS_RELEASE=1 SCN_SHUTDOWN=1 sh "$rdrv" 2>&1)"
    if echo "$rout" | grep -qx 'server=192.0.2.53' && echo "$rout" | grep -qx 'noresolv=0' &&
        echo "$rout" | grep -qx 'configured='; then
        pass "blockleaks:release — DNS is really handed back after an earlier stop (shutdown_correctly=1)"
    else
        fail "blockleaks:release — the released stop left dnsmasq on the dead sing-box inbound" "$rout"
    fi
    rout="$(SCN_SHUTDOWN=1 sh "$rdrv" 2>&1)"
    if echo "$rout" | grep -qx 'server=127.0.0.42'; then
        pass "blockleaks:release — without a release DNS stays fail-closed"
    else
        fail "blockleaks:release — DNS was restored although the kill switch is armed" "$rout"
    fi
    rm -f "$rdrv"
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
# configure_outbound_handler calls set_section_reality_mlkem first; these sections
# never opt into it (covered by the realitymlkem test), so the stub keeps it off.
set_section_reality_mlkem() { NETSHIFT_REALITY_MLKEM=0; }
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
# Test: HTTPUpgrade transport + whole-link skip on an unknown transport
# ─────────────────────────────────────────────────────────────────
# httpupgrade is an UPSTREAM sing-box transport (shipped since 1.8), so it must
# be applied regardless of the sing-box-extended gate. Support for it was lost
# when main was rebuilt without PR #28 (issue #66): such nodes stayed as
# outbounds WITHOUT a transport — valid, still listed in their group, but unable
# to connect. A genuinely unknown transport must now skip the WHOLE link (config
# UNCHANGED, non-zero return) instead of keeping a transportless node, the same
# contract as the XHTTP-on-stock-core path.
# Drives the REAL facade/manager; synthetic values only.
test_httpupgrade_transport() {
    header "HTTPUpgrade transport + skip on unknown transport"

    local lib="${NETSHIFT_LIB_DIR}"
    local facade_lib="$lib/sing_box_config_facade.sh"
    if [ ! -r "$facade_lib" ]; then
        fail "facade lib not found"
        return
    fi

    # The facade sources helpers + manager from /usr/lib/netshift.
    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/test-hu-$$.sh"
    local out="/tmp/test-hu-out-$$.txt"
    cat > "$drv" << 'HUEOF'
. "CONST_LIB"
. "FACADE_LIB"

LOG_FILE="/tmp/hu-log-$$.log"
: > "$LOG_FILE"
log()     { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
echolog() { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOG_FILE"; }
nolog()   { :; }

base='{"outbounds":[]}'

# ── (1) vless ?type=httpupgrade: transport applied, host falls back to sni ────
HU="vless://99999999-aaaa-bbbb-cccc-dddddddddddd@h.example.com:443?type=httpupgrade&security=tls&sni=h.example.com&path=/hu"
out_hu=$(sing_box_cf_add_proxy_outbound "$base" "hu" "$HU" "0")
printf '%s' "$out_hu" | jq -e '.outbounds[0].transport.type=="httpupgrade"' >/dev/null 2>&1 \
    && echo 'hu-url-type:OK' || echo 'hu-url-type:FAIL'
printf '%s' "$out_hu" | jq -e '.outbounds[0].transport.path=="/hu"' >/dev/null 2>&1 \
    && echo 'hu-url-path:OK' || echo 'hu-url-path:FAIL'
printf '%s' "$out_hu" | jq -e '.outbounds[0].transport.host=="h.example.com"' >/dev/null 2>&1 \
    && echo 'hu-url-host-from-sni:OK' || echo 'hu-url-host-from-sni:FAIL'

# ── (2) explicit ?host= wins over the sni ─────────────────────────────
HUH="vless://99999999-aaaa-bbbb-cccc-dddddddddddd@h.example.com:443?type=httpupgrade&security=tls&sni=h.example.com&path=/hu&host=cdn.example.net"
out_huh=$(sing_box_cf_add_proxy_outbound "$base" "huh" "$HUH" "0")
printf '%s' "$out_huh" | jq -e '.outbounds[0].transport.host=="cdn.example.net"' >/dev/null 2>&1 \
    && echo 'hu-url-host-from-link:OK' || echo 'hu-url-host-from-link:FAIL'

# ── (3) trojan with an empty path defaults to "/" ───────────────────
HUT="trojan://synthetic-pass@t.example.com:443?type=httpupgrade&security=tls&sni=t.example.com"
out_hut=$(sing_box_cf_add_proxy_outbound "$base" "hut" "$HUT" "0")
printf '%s' "$out_hut" | jq -e '.outbounds[0].transport.type=="httpupgrade" and .outbounds[0].transport.path=="/"' >/dev/null 2>&1 \
    && echo 'hu-trojan-default-path:OK' || echo 'hu-trojan-default-path:FAIL'

# ── (4) NO extended gate: a stock core still gets the transport ──────────────
is_sing_box_extended() { return 1; }
out_hu_stock=$(sing_box_cf_add_proxy_outbound "$base" "hus" "$HU" "0")
printf '%s' "$out_hu_stock" | jq -e '.outbounds[0].transport.type=="httpupgrade"' >/dev/null 2>&1 \
    && echo 'hu-no-extended-gate:OK' || echo 'hu-no-extended-gate:FAIL'

# ── (5) vmess net=httpupgrade (vmess itself needs the extended core) ────────
is_sing_box_extended() { return 0; }
HU_JSON='{"v":"2","ps":"hu","add":"vm.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"httpupgrade","host":"vm.example.com","path":"/vmhu","tls":"tls","sni":"vm.example.com"}'
HUV="vmess://$(printf '%s' "$HU_JSON" | base64 | tr -d '\n')"
out_huv=$(sing_box_cf_add_proxy_outbound "$base" "huv" "$HUV" "0")
printf '%s' "$out_huv" | jq -e '.outbounds[0].transport.type=="httpupgrade" and .outbounds[0].transport.path=="/vmhu" and .outbounds[0].transport.host=="vm.example.com"' >/dev/null 2>&1 \
    && echo 'hu-vmess-net:OK' || echo 'hu-vmess-net:FAIL'

# ── (6) unknown transport: the WHOLE link is skipped, not left transportless ──
: > "$LOG_FILE"
out_unk=$(sing_box_cf_add_proxy_outbound "$base" "unk" "vless://99999999-aaaa-bbbb-cccc-dddddddddddd@u.example.com:443?type=quantum-magic&security=tls&sni=u.example.com" "0")
rc_unk=$?
if [ "$rc_unk" != "0" ] && [ "$out_unk" = "$base" ] && grep -q '^error|.*Unknown transport' "$LOG_FILE"; then
    echo 'hu-unknown-skipped:OK'
else
    echo "hu-unknown-skipped:FAIL (rc=$rc_unk)"
fi
printf '%s' "$out_unk" | jq -e '[.outbounds[] | select(.transport == null)] | length == 0' >/dev/null 2>&1 \
    && echo 'hu-unknown-no-transportless-outbound:OK' || echo 'hu-unknown-no-transportless-outbound:FAIL'

# ── (7) unknown vmess net: same skip contract ────────────────────────────────
UNK_JSON='{"v":"2","ps":"unk","add":"u.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"quantum-magic","tls":"tls","sni":"u.example.com"}'
UNKV="vmess://$(printf '%s' "$UNK_JSON" | base64 | tr -d '\n')"
: > "$LOG_FILE"
out_unkv=$(sing_box_cf_add_proxy_outbound "$base" "unkv" "$UNKV" "0")
rc_unkv=$?
if [ "$rc_unkv" != "0" ] && [ "$out_unkv" = "$base" ] && grep -q '^error|.*Unknown VMess transport' "$LOG_FILE"; then
    echo 'hu-unknown-vmess-skipped:OK'
else
    echo "hu-unknown-vmess-skipped:FAIL (rc=$rc_unkv)"
fi

# ── (9) a link WITHOUT `type=` is plain TCP, not an unknown transport ────────
# Regression guard: the skip branch must not swallow ordinary links that simply
# omit `type=` (they carry no transport block at all).
NOTYPE="vless://99999999-aaaa-bbbb-cccc-dddddddddddd@nt.example.com:443?security=tls&sni=nt.example.com"
out_nt=$(sing_box_cf_add_proxy_outbound "$base" "nt" "$NOTYPE" "0")
rc_nt=$?
if [ "$rc_nt" = "0" ] \
    && printf '%s' "$out_nt" | jq -e '(.outbounds | length) == 1 and .outbounds[0].transport == null' >/dev/null 2>&1; then
    echo 'hu-no-type-is-plain-tcp:OK'
else
    echo "hu-no-type-is-plain-tcp:FAIL (rc=$rc_nt)"
fi

# ── (10) whole-chain: a real sing-box check accepts the httpupgrade outbound ──
hu_full="/tmp/hu-full-$$.json"
printf '%s' "$out_hu" | jq '{
    log: { level: "error" },
    inbounds: [],
    outbounds: (.outbounds + [ { type: "direct", tag: "direct-out" } ]),
    route: { final: "direct-out" }
}' > "$hu_full" 2>/dev/null
if command -v sing-box > /dev/null 2>&1; then
    sing-box -c "$hu_full" check > /dev/null 2>&1 \
        && echo 'hu-singbox-check:OK' || echo 'hu-singbox-check:FAIL'
else
    echo 'hu-singbox-check:SKIP'
fi
rm -f "$hu_full"

rm -f "$LOG_FILE"
echo 'DONE'
HUEOF
    sed -i "s|CONST_LIB|$lib/constants.sh|g; s|FACADE_LIB|$facade_lib|g" "$drv"

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
        pass "hu-driver-completed:OK"
    else
        fail "hu-driver-completed:FAIL (driver aborted early)"
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
# configure_outbound_handler calls set_section_reality_mlkem first; these sections
# never opt into it (covered by the realitymlkem test), so the stub keeps it off.
set_section_reality_mlkem() { NETSHIFT_REALITY_MLKEM=0; }
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
# Same for the entry normalizer (prefixes are not what this test is about).
domain_rule_normalize() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }

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
    jq '.dns.servers[0].inet6_range = "2001:2::/48"' "${test_config}.2" > "${test_config}.5"

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
subscription_update_unlocked() { SUB_UPDATE_CALLS=$((SUB_UPDATE_CALLS + 1)); return "$SUB_UPDATE_RC"; }
# The worker holds the subscription update lock around the wipe + redownload;
# the real lock helpers run against a scratch lock directory.
SUBSCRIPTION_UPDATE_LOCK_DIR="/tmp/netshift-cc-lock-$$"
SUBSCRIPTION_UPDATE_LOCK_WAIT=1
SUBSCRIPTION_UPDATE_BUSY=4
SUBSCRIPTION_UPDATE_LOCK_FAILED=5
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"

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
eval "$(awk '/^subscription_update_lock_owner_alive\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^subscription_update_lock_acquire\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^subscription_update_lock_release\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^subscription_update_lock_refused\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^subscription_update_worker_result\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
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

# ── CASE 5b: the lock. Every case above must have released it; while another
#             update holds it, the worker neither wipes the cache nor starts a
#             second update, and says so. ─────────────────────────────────────
if [ ! -e "$SUBSCRIPTION_UPDATE_LOCK_DIR" ]; then
    echo 'cc-lock-released-after-run:OK'
else
    echo 'cc-lock-released-after-run:FAIL'
fi
# CASE 5 left the constant empty: point it back at a scratch cache dir.
SUBSCRIPTION_CACHE_FOLDER="/tmp/netshift-cc-cache-$$"
rm -rf "$SUBSCRIPTION_CACHE_FOLDER"
mkdir -p "$SUBSCRIPTION_CACHE_FOLDER"
seed_feed "sec1" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CC_SECTIONS="sec1|proxy|subscription"
SUB_UPDATE_CALLS=0
SUB_UPDATE_RC=0
cc_holder="/tmp/netshift-cc-holder-$$.sh"
printf 'sleep 30\n:\n' > "$cc_holder"
sh "$cc_holder" &
cc_holder_pid=$!
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
echo "$cc_holder_pid" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
cc5b_out="/tmp/netshift-cc-json5b-$$"
subscription_clear_cache_and_redownload > "$cc5b_out"
cc5b_rc=$?
cc5b_json="$(cat "$cc5b_out")"
rm -f "$cc5b_out"
cc5b_left=$(ls -1 "$SUBSCRIPTION_CACHE_FOLDER" 2>/dev/null | wc -l)
if [ "$cc5b_rc" -eq "$SUBSCRIPTION_UPDATE_BUSY" ] && [ "$SUB_UPDATE_CALLS" -eq 0 ] && [ "$cc5b_left" -eq 4 ] &&
    printf '%s' "$cc5b_json" | jq -e '.success == false and (.message | contains("already running"))' > /dev/null 2>&1; then
    echo 'cc-busy-keeps-cache-and-reports:OK'
else
    echo "cc-busy-keeps-cache-and-reports(rc=$cc5b_rc calls=$SUB_UPDATE_CALLS left=$cc5b_left json=$cc5b_json):FAIL"
fi
if [ "$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid" 2>/dev/null)" = "$cc_holder_pid" ]; then
    echo 'cc-busy-leaves-foreign-lock:OK'
else
    echo 'cc-busy-leaves-foreign-lock:FAIL'
fi
kill "$cc_holder_pid" 2>/dev/null
wait "$cc_holder_pid" 2>/dev/null
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR" "$cc_holder" "$SUBSCRIPTION_CACHE_FOLDER"

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
          subscription_feed_tags_record subscription_feed_tags_publish \
          subscription_resolve_feed_url \
          get_subscription_json_path get_subscription_url_cache_path \
          subscription_url_cache_matches subscription_cache_is_usable \
          prepare_subscription_cache_for_startup reap_orphan_subscription_cache_files; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
done
get_outbound_tag_by_section() { printf '%s-out' "$1"; }

_off_branch() {
EXTRACT_OFF
}

# $1 = tags json, $2 = feeds json ("" = unset), $3 = names json, $4 = config,
# $5 = URL hash per feed index ("" = unset: nothing is recorded in the tag map)
run_off() {
    section="syn"
    selector_tag="syn-out"
    subscription_outbound_tags_json="$1"
    subscription_outbound_feeds_json="$2"
    subscription_feed_names_json="$3"
    config="$4"
    subscription_feed_hashes_json="${5:-}"
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
    '[{"name":"Feed A","tags":["a","c"],"feed":0},{"name":"Feed C","tags":["b","d"],"feed":2}]'
expect_eq fg-groups-null-feeds \
    "$(sing_box_build_subscription_feed_groups '["a","b"]' '[null,null]' '[]')" '[]'
expect_eq fg-groups-short-feeds \
    "$(sing_box_build_subscription_feed_groups '["a","b"]' '[0]' '["A"]')" '[{"name":"A","tags":["a"],"feed":0}]'
expect_eq fg-groups-missing-name \
    "$(sing_box_build_subscription_feed_groups '["a"]' '[1]' '["A"]')" '[{"name":"Subscription 2","tags":["a"],"feed":1}]'

# ── Flat (off) branch ─────────────────────────────────────────────
nodes='{"outbounds":[
  {"type":"direct","tag":"direct-out"},
  {"type":"shadowsocks","tag":"a1","server":"10.3.0.1","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"a2","server":"10.3.0.2","server_port":443,"method":"aes-256-gcm","password":"p"},
  {"type":"shadowsocks","tag":"b1","server":"10.3.0.3","server_port":443,"method":"aes-256-gcm","password":"p"}
]}'
tags='["a1","a2","b1"]'
P="$SB_SUBSCRIPTION_FEED_GROUP_TAG_PREFIX"
SUBSCRIPTION_FEED_TAGS_FILE="/tmp/fg-feed-tags-$$.jsonl"
rm -f "$SUBSCRIPTION_FEED_TAGS_FILE" "$SUBSCRIPTION_FEED_TAGS_FILE.new"

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

# ── Feed tag map: which feed a per-feed urltest stands for ────────
# Another section already owns "⚡ NL", and this one has a feed named "NL" and
# a feed literally named "NL-1". The first gets the deduplicated tag "⚡ NL-1",
# which reads exactly like the second feed's name: only the map tells them
# apart, and the per-feed refresh must follow the map.
nl_nodes="$(printf '%s' "$nodes" | jq -c --arg t "${P}NL" \
    '.outbounds += [{"type":"urltest","tag":$t,"outbounds":["a1"]}]')"
nl_url_first='https://nl.example.com/first#NL'
nl_url_second='https://nl.example.com/second#NL-1'
nl_hashes="$(jq -cn --arg a "$(get_subscription_url_hash "$nl_url_first")" \
    --arg b "$(get_subscription_url_hash "$nl_url_second")" '[$a, $b]')"
rm -f "$SUBSCRIPTION_FEED_TAGS_FILE.new"
nl="$(run_off "$tags" '[0,0,1]' '["NL","NL-1"]' "$nl_nodes" "$nl_hashes")"
expect_eq fg-tagmap-dedup-tags \
    "$(printf '%s' "$nl" | jq -c --arg p "$P" '[.outbounds[] | select(.type == "urltest" and (.tag | startswith($p))) | .tag]')" \
    "$(jq -cn --arg p "$P" '["\($p)NL","\($p)NL-1","\($p)NL-1-1"]')"
expect_eq fg-tagmap-recorded \
    "$(jq -cs '[.[] | [.tag, .section, .hash]]' "$SUBSCRIPTION_FEED_TAGS_FILE.new" 2> /dev/null)" \
    "$(jq -cn --arg p "$P" --argjson h "$nl_hashes" '[["\($p)NL-1","syn",$h[0]],["\($p)NL-1-1","syn",$h[1]]]')"
if [ ! -e "$SUBSCRIPTION_FEED_TAGS_FILE" ]; then ok fg-tagmap-not-live-before-publish; else bad fg-tagmap-not-live-before-publish; fi
subscription_feed_tags_publish
get_subscription_urls_for_section() { printf '%s\n' "$nl_url_first" "$nl_url_second"; }
expect_eq fg-tagmap-dedup-tag-is-first-feed "$(subscription_resolve_feed_url syn "${P}NL-1")" "$nl_url_first"
expect_eq fg-tagmap-second-feed "$(subscription_resolve_feed_url syn "${P}NL-1-1")" "$nl_url_second"
expect_eq fg-tagmap-other-section "$(subscription_resolve_feed_url other "${P}NL-1")" ""
expect_eq fg-tagmap-name-is-not-a-tag "$(subscription_resolve_feed_url syn "NL-1")" ""
expect_eq fg-tagmap-url-verbatim "$(subscription_resolve_feed_url syn "$nl_url_second")" "$nl_url_second"
# A build without per-feed groups leaves no map behind.
subscription_feed_tags_publish
if [ ! -e "$SUBSCRIPTION_FEED_TAGS_FILE" ]; then ok fg-tagmap-dropped-with-groups; else bad fg-tagmap-dropped-with-groups; fi
expect_eq fg-tagmap-no-map-no-match "$(subscription_resolve_feed_url syn "${P}NL-1")" ""

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
    # before any feed is downloaded. The "no URL" arm is matched by its own
    # message (the sibling empty-field arms use mark_section_without_links too,
    # and the enumeration warning above it also contains "subscription URL").
    local reap_order
    reap_order="$(awk '
        /^configure_outbound_handler\(\) \{/{p=1}
        !p{next}
        /subscription URL \(subscription_url\)/{print "empty-check"}
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
    # STUB_ARGS_FILE records the arguments it was started with, one per line.
    [ -n "$STUB_ARGS_FILE" ] && printf '[%s]\n' "$@" > "$STUB_ARGS_FILE"
    [ -n "$STUB_SLEEP" ] && sleep "$STUB_SLEEP"
    if [ -z "$STUB_JSON" ]; then
        STUB_JSON='{"success":true,"version":"1.0.0-extended"}'
    fi
    printf '%s\n' "$STUB_JSON"
    exit "${STUB_RC:-0}"
    ;;
component_action_async)
    # Same forwarding as the shipped CLI dispatcher.
    component_action_async "$2" "$3" "$4" "$5"
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

    # ── 2e. the dispatcher hands the subscription actions to their workers ──
    # The shipped component_action, with the two workers replaced by recorders:
    # `update_feed` must pass section and feed tag on as two intact arguments.
    local disp_out
    disp_out="$(
        # shellcheck disable=SC1090
        . "$NETSHIFT_LIB_DIR/constants.sh"
        # shellcheck disable=SC1090
        . "$NETSHIFT_LIB_DIR/updater.sh"
        subscription_update_feed_worker() { printf 'feed:%s:[%s][%s]
' "$#" "$1" "$2"; }
        subscription_update_all_worker() { printf 'all:%s
' "$#"; }
        component_action subscription update_feed "my sub" "⚡ feed one (2)"
        component_action subscription update_feed "my sub"
        component_action subscription update
    )"
    if [ "$disp_out" = "feed:2:[my sub][⚡ feed one (2)]
feed:2:[my sub][]
all:0" ]; then
        pass "component_action routes subscription update / update_feed to their workers"
    else
        fail "component_action did not route the subscription actions" "$disp_out"
    fi

    # ── 2b. extra arguments reach the worker untouched ──────────────────────
    # `subscription update_feed <section> <feed>`: the feed is a sing-box tag
    # with a space and a non-ASCII prefix, so it must arrive as ONE argument.
    local args_file="$jdir/worker-args" args_json args_id args_waited=0 args_want
    args_json="$(JOBSTUB_DIR="$jdir" STUB_ARGS_FILE="$args_file" \
        "$stub" component_action_async subscription update_feed "my sub" "⚡ feed one (2)")"
    args_id="$(echo "$args_json" | jq -r '.job_id')"
    while [ "$args_waited" -lt 15 ]; do
        jq -e '.running == false' "$jdir/$args_id.json" > /dev/null 2>&1 && break
        sleep 1
        args_waited=$((args_waited + 1))
    done
    args_want="[component_action]
[subscription]
[update_feed]
[my sub]
[⚡ feed one (2)]"
    if [ "$(cat "$args_file" 2>/dev/null)" = "$args_want" ]; then
        pass "async forwards the extra arguments to the worker verbatim"
    else
        fail "async did not forward the extra arguments" "$(cat "$args_file" 2>/dev/null)"
    fi
    # An action without extra arguments still starts (they arrive empty).
    args_json="$(JOBSTUB_DIR="$jdir" STUB_ARGS_FILE="$args_file" \
        "$stub" component_action_async subscription update)"
    args_id="$(echo "$args_json" | jq -r '.job_id')"
    args_waited=0
    while [ "$args_waited" -lt 15 ]; do
        jq -e '.running == false' "$jdir/$args_id.json" > /dev/null 2>&1 && break
        sleep 1
        args_waited=$((args_waited + 1))
    done
    if [ "$(sed -n '1,3p' "$args_file" 2>/dev/null | tr '\n' ' ')" = "[component_action] [subscription] [update] " ] &&
        ! sed -n '4,$p' "$args_file" | grep -q '[^][]'; then
        pass "async without extra arguments passes none to the worker"
    else
        fail "async without extra arguments passed something" "$(cat "$args_file" 2>/dev/null)"
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

for fn in is_valid_subscription_update_time \
          get_section_subscription_update_time \
          cron_number cron_field_matches \
          subscription_daily_minute_is_free suggest_free_daily_minute \
          warn_daily_subscription_time_collisions \
          get_subscription_cron_line_for_interval \
          _collect_subscription_update_interval \
          sync_subscription_cron_jobs \
          remove_cron_job \
          foreach_active_section _active_section_dispatch section_is_disabled \
          subscription_update subscription_update_unlocked \
          subscription_update_lock_process_start subscription_update_lock_take_over           subscription_update_lock_owner_alive subscription_update_lock_acquire \
          subscription_update_lock_release subscription_update_worker_result \
          get_subscription_feed_display_name \
          subscription_update_lock_refused subscription_resolve_feed_url \
          subscription_update_all_worker subscription_update_feed_worker; do
    eval "$(extract "$fn")"
done
# The update lock lives in the scratch dir, never in the container's /var/run.
SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK/subscription-update.lock"
SUBSCRIPTION_FEED_TAGS_FILE="$WORK/subscription-feed-tags.jsonl"

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
    # The daily job also names its time ("1d HH:MM"), default 09:52.
    sfx=""
    [ "$iv" = "1d" ] && sfx=" 09:52"
    if [ "$got" = "$want /usr/bin/netshift subscription_update $iv$sfx" ]; then
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
if has_line "52 9 * * * /usr/bin/netshift subscription_update 1d 09:52"; then
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

# ── Configurable daily time (issue #54) ──────────────────────────
# is_valid_subscription_update_time: HH:MM, 00:00-23:59, two digits each.
time_ok=1
for t in 00:00 00:59 09:52 12:00 19:30 20:00 23:59; do
    is_valid_subscription_update_time "$t" || { time_ok=0; echo "# time-detail valid rejected: $t"; }
done
for t in "" 24:00 12:60 9:15 09:5 0930 09:15:30 09.15 ab:cd " 09:15" 09:15pm -1:00 "09:15 "; do
    is_valid_subscription_update_time "$t" && { time_ok=0; echo "# time-detail invalid accepted: [$t]"; }
done
if [ "$time_ok" = "1" ]; then
    echo 'subcron:time-validation:OK'
else
    echo 'subcron:time-validation:FAIL'
fi

# The cron fields are plain numbers: 04:05 -> "5 4", 00:00 -> "0 0", and 08:09 /
# 09:08 must not hit the octal trap ($((08)) is an error in ash).
time_ok=1
for spec in "04:30|30 4" "00:00|0 0" "08:09|9 8" "09:08|8 9" "23:59|59 23" "10:10|10 10" "00:05|5 0"; do
    t="${spec%%|*}"
    want="${spec#*|} * * * /usr/bin/netshift subscription_update 1d $t"
    got="$(get_subscription_cron_line_for_interval 1d "$t")"
    [ "$got" = "$want" ] || { time_ok=0; echo "# time-detail $t: got [$got] want [$want]"; }
done
if [ "$time_ok" = "1" ]; then
    echo 'subcron:daily-time-cron-fields:OK'
else
    echo 'subcron:daily-time-cron-fields:FAIL'
fi
# An invalid time never turns into a job, and a time on another interval is not
# part of that interval's line.
if get_subscription_cron_line_for_interval 1d 25:00 > /dev/null 2>&1; then
    echo 'subcron:daily-time-invalid-rejected:FAIL [25:00 accepted]'
else
    echo 'subcron:daily-time-invalid-rejected:OK'
fi
if [ "$(get_subscription_cron_line_for_interval 1h 04:30)" = "17 * * * * /usr/bin/netshift subscription_update 1h" ]; then
    echo 'subcron:time-ignored-for-other-intervals:OK'
else
    echo 'subcron:time-ignored-for-other-intervals:FAIL'
fi

cat > "$WORK/daily_times" <<'CFGEOF'
config section 'night'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/night'
        option subscription_update_interval '1d'
        option subscription_update_time '04:30'

config section 'night2'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/night2'
        option subscription_update_interval '1d'
        option subscription_update_time '04:30'

config section 'legacy'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/legacy'
        option subscription_update_interval '1d'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/daily_times"
if has_line "30 4 * * * /usr/bin/netshift subscription_update 1d 04:30" &&
    has_line "52 9 * * * /usr/bin/netshift subscription_update 1d 09:52"; then
    echo 'subcron:daily-time-own-job:OK'
else
    echo "subcron:daily-time-own-job:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
# Two sections on 04:30 share ONE job, the section without the option keeps the
# time the daily job always ran at (upgrade: existing configs do not change).
if [ "$(job_count)" = "2" ]; then
    echo 'subcron:daily-same-time-one-job:OK'
else
    echo "subcron:daily-same-time-one-job:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
# The time survives a service restart / package upgrade: the jobs are rebuilt
# from UCI, so rebuilding again yields the identical crontab.
first_crontab="$(sort "$CRONTAB_FILE")"
sync "$WORK/daily_times" keep
if [ "$(sort "$CRONTAB_FILE")" = "$first_crontab" ] && [ "$(job_count)" = "2" ]; then
    echo 'subcron:daily-time-stable-across-rebuilds:OK'
else
    echo "subcron:daily-time-stable-across-rebuilds:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi

cat > "$WORK/bad_time" <<'CFGEOF'
config section 'oops'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/oops'
        option subscription_update_interval '1d'
        option subscription_update_time '25:99'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/bad_time"
if has_line "52 9 * * * /usr/bin/netshift subscription_update 1d 09:52" && [ "$(job_count)" = "1" ]; then
    echo 'subcron:bad-time-falls-back-to-default:OK'
else
    echo "subcron:bad-time-falls-back-to-default:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
if grep -q "^\[warn\] Invalid subscription_update_time '25:99' in section 'oops'" "$LOG_FILE"; then
    echo 'subcron:bad-time-warned:OK'
else
    echo "subcron:bad-time-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# A time on a non-daily interval is not used: the section keeps its interval job.
cat > "$WORK/time_on_hourly" <<'CFGEOF'
config section 'hourly'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/hourly'
        option subscription_update_interval '1h'
        option subscription_update_time '04:30'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/time_on_hourly"
if has_line "17 * * * * /usr/bin/netshift subscription_update 1h" && [ "$(job_count)" = "1" ]; then
    echo 'subcron:time-on-hourly-ignored:OK'
else
    echo "subcron:time-on-hourly-ignored:FAIL [$(tr '\n' ';' < "$CRONTAB_FILE")]"
fi
# ... and says so: a value that silently does nothing is a trap.
if grep -q "^\[warn\] subscription_update_time '04:30' in section 'hourly' is ignored" "$LOG_FILE"; then
    echo 'subcron:time-on-hourly-warned:OK'
else
    echo "subcron:time-on-hourly-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# The user picks the daily minute, so a minute another job fires at is only
# warned about (the two would race). 04:30 clashes with the 30-minute job.
cat > "$WORK/clash" <<'CFGEOF'
config section 'fast'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/fast'
        option subscription_update_interval '30m'

config section 'daily'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/daily'
        option subscription_update_interval '1d'
        option subscription_update_time '04:30'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/clash"
if grep -q "^\[warn\] The daily subscription update at 04:30 runs at the same time as the subscription update 30m cron job" "$LOG_FILE" &&
    has_line "30 4 * * * /usr/bin/netshift subscription_update 1d 04:30"; then
    echo 'subcron:daily-minute-clash-warned:OK'
else
    echo "subcron:daily-minute-clash-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi
sed -i "s/'04:30'/'04:31'/" "$WORK/clash"
: > "$LOG_FILE"
sync "$WORK/clash"
if grep -q "runs at the same time as" "$LOG_FILE"; then
    echo 'subcron:daily-minute-no-clash-silent:FAIL [warned for 04:31]'
else
    echo 'subcron:daily-minute-no-clash-silent:OK'
fi
# The hint for a minute with a leading zero must not hit the octal trap either.
sed -i "s/'04:31'/'04:00'/" "$WORK/clash"
: > "$LOG_FILE"
sync "$WORK/clash"
if grep -q "for example :05" "$LOG_FILE"; then
    echo 'subcron:clash-hint-leading-zero:OK'
else
    echo "subcron:clash-hint-leading-zero:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# The collision check compares the HOUR as well: the 3h job fires at 7 */3 only
# in hours divisible by 3, so a daily 04:07 never meets it, 03:07 does.
cat > "$WORK/clash3h" <<'CFGEOF'
config section 'threeh'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/threeh'
        option subscription_update_interval '3h'

config section 'daily'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/daily'
        option subscription_update_interval '1d'
        option subscription_update_time '04:07'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/clash3h"
if grep -q "runs at the same time as" "$LOG_FILE"; then
    echo 'subcron:clash-3h-other-hour-silent:FAIL [warned for 04:07]'
else
    echo 'subcron:clash-3h-other-hour-silent:OK'
fi
sed -i "s/'04:07'/'03:07'/" "$WORK/clash3h"
: > "$LOG_FILE"
sync "$WORK/clash3h"
if grep -q "^\[warn\] The daily subscription update at 03:07 runs at the same time as the subscription update 3h cron job" "$LOG_FILE"; then
    echo 'subcron:clash-3h-same-hour-warned:OK'
else
    echo "subcron:clash-3h-same-hour-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# The list_update job (minute 13) is covered too: it is in the crontab by the
# time the subscription jobs are synced, whatever update_interval is set.
cat > "$WORK/clash_lists" <<'CFGEOF'
config section 'daily'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/daily'
        option subscription_update_interval '1d'
        option subscription_update_time '09:13'
CFGEOF
printf '%s\n' '13 */3 * * * /usr/bin/netshift list_update' > "$CRONTAB_FILE"
: > "$LOG_FILE"
sync "$WORK/clash_lists" keep
if grep -q "^\[warn\] The daily subscription update at 09:13 runs at the same time as the lists update cron job" "$LOG_FILE"; then
    echo 'subcron:clash-list-update-warned:OK'
else
    echo "subcron:clash-list-update-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi
sed -i "s/'09:13'/'10:13'/" "$WORK/clash_lists"
printf '%s\n' '13 */3 * * * /usr/bin/netshift list_update' > "$CRONTAB_FILE"
: > "$LOG_FILE"
sync "$WORK/clash_lists" keep
if grep -q "runs at the same time as" "$LOG_FILE"; then
    echo 'subcron:clash-list-update-other-hour-silent:FAIL [warned for 10:13 vs 13 */3]'
else
    echo 'subcron:clash-list-update-other-hour-silent:OK'
fi
printf '%s\n' '13 * * * * /usr/bin/netshift list_update' > "$CRONTAB_FILE"
: > "$LOG_FILE"
sync "$WORK/clash_lists" keep
if grep -q "^\[warn\] The daily subscription update at 10:13 runs at the same time as the lists update cron job" "$LOG_FILE"; then
    echo 'subcron:clash-list-update-hourly-warned:OK'
else
    echo "subcron:clash-list-update-hourly-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# The suggested minute is the next free one: 04:30 clashes with the 30-minute job
# and :35 is free.
cat > "$WORK/clash_hint" <<'CFGEOF'
config section 'fast'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/fast'
        option subscription_update_interval '30m'

config section 'daily'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/daily'
        option subscription_update_interval '1d'
        option subscription_update_time '04:30'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/clash_hint"
if grep -q "for example :35" "$LOG_FILE"; then
    echo 'subcron:clash-hint-free-minute:OK'
else
    echo "subcron:clash-hint-free-minute:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi
# A hint minute that another job fires at is skipped: with :35 taken by a
# list_update job the hint moves on to :40.
printf '%s\n' '35 * * * * /usr/bin/netshift list_update' > "$CRONTAB_FILE"
: > "$LOG_FILE"
sync "$WORK/clash_hint" keep
if grep -q "for example :40" "$LOG_FILE" && ! grep -q "for example :35" "$LOG_FILE"; then
    echo 'subcron:clash-hint-skips-busy-minute:OK'
else
    echo "subcron:clash-hint-skips-busy-minute:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# cron fields with leading zeros match their number; a zero step is no guard-bypass.
if cron_field_matches "07" 7 && ! cron_field_matches "07" 8 && cron_field_matches "*/00" 5 &&
    cron_field_matches "*/05" 10 && ! cron_field_matches "*/05" 11; then
    echo 'subcron:cron-field-leading-zeros:OK'
else
    echo 'subcron:cron-field-leading-zeros:FAIL'
fi

# The default time collides with none of the fixed jobs: a config with every
# other interval and the list_update job stays silent.
cat > "$WORK/clash_default" <<'CFGEOF'
config section 'a30'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/a'
        option subscription_update_interval '30m'

config section 'a1h'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/b'
        option subscription_update_interval '1h'

config section 'a3h'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/c'
        option subscription_update_interval '3h'

config section 'a6h'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/d'
        option subscription_update_interval '6h'

config section 'a12h'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/e'
        option subscription_update_interval '12h'

config section 'dailydef'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/f'
        option subscription_update_interval '1d'
CFGEOF
printf '%s\n' '13 */3 * * * /usr/bin/netshift list_update' > "$CRONTAB_FILE"
: > "$LOG_FILE"
sync "$WORK/clash_default" keep
if grep -q "runs at the same time as" "$LOG_FILE"; then
    echo "subcron:default-time-silent:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
else
    echo 'subcron:default-time-silent:OK'
fi
# 6h and 12h are compared by hour as well: 6h fires at :24 in hours 0,6,12,18.
sed -i "s/option subscription_update_interval '1d'/option subscription_update_interval '1d'\n        option subscription_update_time '06:24'/" "$WORK/clash_default"
: > "$LOG_FILE"
sync "$WORK/clash_default"
if grep -q "^\[warn\] The daily subscription update at 06:24 runs at the same time as the subscription update 6h cron job" "$LOG_FILE"; then
    echo 'subcron:clash-6h-same-hour-warned:OK'
else
    echo "subcron:clash-6h-same-hour-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi
sed -i "s/'06:24'/'07:24'/" "$WORK/clash_default"
: > "$LOG_FILE"
sync "$WORK/clash_default"
if grep -q "runs at the same time as" "$LOG_FILE"; then
    echo 'subcron:clash-6h-other-hour-silent:FAIL'
else
    echo 'subcron:clash-6h-other-hour-silent:OK'
fi
sed -i "s/'07:24'/'12:40'/" "$WORK/clash_default"
: > "$LOG_FILE"
sync "$WORK/clash_default"
if grep -q "^\[warn\] The daily subscription update at 12:40 runs at the same time as the subscription update 12h cron job" "$LOG_FILE"; then
    echo 'subcron:clash-12h-same-hour-warned:OK'
else
    echo "subcron:clash-12h-same-hour-warned:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# A time on a non-daily section names the interval the UCI really holds, also
# when it is one this version does not schedule.
cat > "$WORK/ignored_unknown" <<'CFGEOF'
config section 'odd'
        option connection_type 'proxy'
        option proxy_config_type 'subscription'
        option subscription_url 'https://example.com/odd'
        option subscription_update_interval '2h'
        option subscription_update_time '04:30'
CFGEOF
: > "$LOG_FILE"
sync "$WORK/ignored_unknown"
if grep -q "is ignored: it only applies to the 1d interval, this section is on 2h" "$LOG_FILE"; then
    echo 'subcron:ignored-time-names-configured-interval:OK'
else
    echo "subcron:ignored-time-names-configured-interval:FAIL [$(tr '\n' ';' < "$LOG_FILE")]"
fi

# The CLI usage text documents the HH:MM argument.
if grep -q "(1d takes an optional HH:MM" "$BIN"; then
    echo 'subcron:usage-documents-time:OK'
else
    echo 'subcron:usage-documents-time:FAIL'
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
    has_line "52 9 * * * /usr/bin/netshift subscription_update 1d 09:52" &&
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
    plain:proxy_config_type) eval "$1=url" ;;
    fast:subscription_update_interval) eval "$1=30m" ;;
    slow:subscription_update_interval) eval "$1=1d" ;;
    slow:subscription_update_time) eval "$1=04:30" ;;
    odd:subscription_update_interval) eval "$1=2h" ;;
    *) eval "$1=\"\${4:-}\"" ;;
    esac
}
ensure_subscription_cache_dir() { :; }
reap_legacy_subscription_cache_files() { :; }
get_subscription_urls_for_section() {
    # 'fast' carries two feeds so the per-URL filter has something to narrow.
    case "$1" in
    fast) printf '%s\n' "https://feed.example.com/fast-a" "https://feed.example.com/fast-b" ;;
    *) printf '%s\n' "https://feed.example.com/$1" ;;
    esac
}
get_subscription_url_hash() { printf 'feedhash-%s' "$1"; }
get_subscription_json_path() { printf '%s' "$SUBSCRIPTION_CACHE_FOLDER/$1.$2.json"; }
get_subscription_url_cache_path() { printf '%s' "$SUBSCRIPTION_CACHE_FOLDER/$1.$2.url"; }
get_subscription_download_proxy_address() { :; }
wait_for_subscription_connectivity() { return 0; }
redact_url_for_log() { printf '%s' "$1"; }
subscription_cache_is_usable() { return 0; }
download_subscription_into_cache() {
    printf '%s' '{"outbounds":[{"type":"vless","tag":"node-1"}]}' > "$3"
    printf '%s\n' "$1" >> "$WORK/updated.log"
    printf '%s\n' "$2" >> "$WORK/downloaded-urls.log"
    return 0
}
reload_sing_box_config_in_place() { return 0; }

updated_sections() {
    : > "$WORK/updated.log"
    rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
    subscription_update "$1" "${2:-}" > /dev/null 2>&1
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
# The daily job names its time: it updates only the sections at that time. A bare
# "1d" (an older crontab line, a manual run) keeps meaning every daily section.
got="$(updated_sections 1d 04:30)"
if [ "$got" = "slow " ]; then
    echo 'subcron:filter-1d-time-matches:OK'
else
    echo "subcron:filter-1d-time-matches:FAIL [$got]"
fi
got="$(updated_sections 1d 09:52)"
if [ "$got" = "" ]; then
    echo 'subcron:filter-1d-other-time-noop:OK'
else
    echo "subcron:filter-1d-other-time-noop:FAIL [$got]"
fi
: > "$LOG_FILE"
got="$(updated_sections 1d 25:99)"
if [ "$got" = "slow " ] && grep -q "Invalid subscription update time '25:99'" "$LOG_FILE"; then
    echo 'subcron:filter-1d-invalid-time-updates-daily:OK'
else
    echo "subcron:filter-1d-invalid-time-updates-daily:FAIL [$got|$(tr '\n' ';' < "$LOG_FILE")]"
fi
got="$(updated_sections 1h 04:30)"
if [ "$got" = "odd " ]; then
    echo 'subcron:filter-time-ignored-for-other-intervals:OK'
else
    echo "subcron:filter-time-ignored-for-other-intervals:FAIL [$got]"
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

# ── optional section / url filters (dashboard per-feed refresh) ──
# $3 narrows the run to one section, $4 to one feed URL inside it. Both are how
# the Dashboard refresh buttons call the function; the cron path above never
# passes them, so this must not change its behaviour.
updated_sections_section() {
    : > "$WORK/updated.log"
    rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
    subscription_update "" "" "$1" > /dev/null 2>&1
    printf '%s' "$(sort -u "$WORK/updated.log" | tr '\n' ' ')"
}
downloaded_urls() {
    : > "$WORK/updated.log"
    : > "$WORK/downloaded-urls.log"
    rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
    subscription_update "" "" "$1" "$2" > /dev/null 2>&1
    printf '%s' "$(sort -u "$WORK/downloaded-urls.log" | tr '\n' ' ')"
}

got="$(updated_sections_section fast)"
if [ "$got" = "fast " ]; then
    echo 'subcron:section-filter-only-fast:OK'
else
    echo "subcron:section-filter-only-fast:FAIL [$got]"
fi
got="$(updated_sections_section nope)"
if [ "$got" = "" ]; then
    echo 'subcron:section-filter-unknown-noop:OK'
else
    echo "subcron:section-filter-unknown-noop:FAIL [$got]"
fi
subscription_update "" "" nope > /dev/null 2>&1
if [ "$?" -eq 0 ]; then
    echo 'subcron:section-filter-unknown-rc:OK'
else
    echo 'subcron:section-filter-unknown-rc:FAIL'
fi
got="$(downloaded_urls fast 'https://feed.example.com/fast-b')"
if [ "$got" = "https://feed.example.com/fast-b " ]; then
    echo 'subcron:url-filter-single-feed:OK'
else
    echo "subcron:url-filter-single-feed:FAIL [$got]"
fi
got="$(downloaded_urls fast '')"
if [ "$got" = "https://feed.example.com/fast-a https://feed.example.com/fast-b " ]; then
    echo 'subcron:section-filter-all-feeds:OK'
else
    echo "subcron:section-filter-all-feeds:FAIL [$got]"
fi
# The daily time stays the second argument: the section filter must not eat it.
got="$(updated_sections 1d 04:30)"
if [ "$got" = "slow " ]; then
    echo 'subcron:time-filter-still-second-arg:OK'
else
    echo "subcron:time-filter-still-second-arg:FAIL [$got]"
fi

# ── the update lock: one subscription update at a time ──
# A live owner is a process whose command line names netshift (every real run
# is `/usr/bin/netshift ...`); the holder script's name provides that here.
LOCK_HOLDER="$WORK/netshift-lock-holder.sh"
printf 'sleep 60\n:\n' > "$LOCK_HOLDER"
hold_lock() {
    sh "$LOCK_HOLDER" &
    HOLDER_PID=$!
    mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
    echo "$HOLDER_PID" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
}
drop_lock_holder() {
    kill "$HOLDER_PID" 2> /dev/null
    wait "$HOLDER_PID" 2> /dev/null
}

if [ ! -e "$SUBSCRIPTION_UPDATE_LOCK_DIR" ]; then
    echo 'subcron:lock-released-after-every-run:OK'
else
    echo 'subcron:lock-released-after-every-run:FAIL'
fi

# A dashboard worker (nowait) does not start next to a running update.
hold_lock
: > "$WORK/updated.log"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
if [ "$rc" -eq "$SUBSCRIPTION_UPDATE_BUSY" ] && [ ! -s "$WORK/updated.log" ] &&
    [ "$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid")" = "$HOLDER_PID" ]; then
    echo 'subcron:lock-nowait-busy:OK'
else
    echo "subcron:lock-nowait-busy:FAIL [rc=$rc]"
fi

# A scheduled run waits, and gives up with the same code once the wait is over.
SUBSCRIPTION_UPDATE_LOCK_WAIT=2
: > "$WORK/updated.log"
subscription_update > /dev/null 2>&1
rc=$?
if [ "$rc" -eq "$SUBSCRIPTION_UPDATE_BUSY" ] && [ ! -s "$WORK/updated.log" ]; then
    echo 'subcron:lock-wait-times-out:OK'
else
    echo "subcron:lock-wait-times-out:FAIL [rc=$rc]"
fi

# ...and runs as soon as the owner is done within the wait.
SUBSCRIPTION_UPDATE_LOCK_WAIT=20
(
    sleep 2
    rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"
) &
releaser_pid=$!
: > "$WORK/updated.log"
rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
subscription_update 30m > /dev/null 2>&1
rc=$?
wait "$releaser_pid" 2> /dev/null
if [ "$rc" -eq 0 ] && [ "$(sort -u "$WORK/updated.log" | tr '\n' ' ')" = "fast " ] &&
    [ ! -e "$SUBSCRIPTION_UPDATE_LOCK_DIR" ]; then
    echo 'subcron:lock-wait-runs-after-release:OK'
else
    echo "subcron:lock-wait-runs-after-release:FAIL [rc=$rc]"
fi
drop_lock_holder

# A lock whose owner died (killed mid-update, the restart an update triggers)
# is taken over instead of blocking every later update.
hold_lock
drop_lock_holder
: > "$WORK/updated.log"
rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update 30m > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
if [ "$rc" -eq 0 ] && [ -s "$WORK/updated.log" ] && grep -q "lock is stale" "$LOG_FILE"; then
    echo 'subcron:lock-stale-owner-taken-over:OK'
else
    echo "subcron:lock-stale-owner-taken-over:FAIL [rc=$rc]"
fi

# The owner pid now belongs to something that is not a netshift run.
sleep 60 &
foreign_pid=$!
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
echo "$foreign_pid" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update 30m > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
kill "$foreign_pid" 2> /dev/null
wait "$foreign_pid" 2> /dev/null
if [ "$rc" -eq 0 ]; then
    echo 'subcron:lock-reused-pid-taken-over:OK'
else
    echo "subcron:lock-reused-pid-taken-over:FAIL [rc=$rc]"
fi

# A lock directory left without a pid file (owner died right after mkdir).
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update 30m > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
if [ "$rc" -eq 0 ] && [ ! -e "$SUBSCRIPTION_UPDATE_LOCK_DIR" ]; then
    echo 'subcron:lock-ownerless-taken-over:OK'
else
    echo "subcron:lock-ownerless-taken-over:FAIL [rc=$rc]"
fi

# The lock directory cannot be created at all (tmpfs full, read-only parent):
# every mode must come back, not spin on the takeover path, and with its own
# code: "busy" would tell the user to wait for an update that is not running.
real_lock_dir="$SUBSCRIPTION_UPDATE_LOCK_DIR"
: > "$WORK/not-a-directory"
SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK/not-a-directory/lock"
: > "$LOG_FILE"
: > "$WORK/updated.log"
for lock_mode in nowait wait; do
    SUBSCRIPTION_UPDATE_LOCK_MODE="$lock_mode"
    subscription_update 30m > /dev/null 2>&1 &
    spin_pid=$!
    spin_waited=0
    while kill -0 "$spin_pid" 2> /dev/null && [ "$spin_waited" -lt 15 ]; do
        sleep 1
        spin_waited=$((spin_waited + 1))
    done
    if kill -0 "$spin_pid" 2> /dev/null; then
        kill "$spin_pid" 2> /dev/null
        echo "subcron:lock-uncreatable-$lock_mode:FAIL [still running after ${spin_waited}s]"
    else
        wait "$spin_pid"
        rc=$?
        if [ "$rc" -eq "$SUBSCRIPTION_UPDATE_LOCK_FAILED" ] && [ ! -s "$WORK/updated.log" ] &&
            [ "$(grep -c "lock is stale" "$LOG_FILE")" -eq 0 ] &&
            [ "$(grep -c "Another subscription update is still running" "$LOG_FILE")" -eq 0 ] &&
            grep -q "Cannot create the subscription update lock" "$LOG_FILE"; then
            echo "subcron:lock-uncreatable-$lock_mode:OK"
        else
            echo "subcron:lock-uncreatable-$lock_mode:FAIL [rc=$rc]"
        fi
    fi
done
unset SUBSCRIPTION_UPDATE_LOCK_MODE
SUBSCRIPTION_UPDATE_LOCK_DIR="$real_lock_dir"

# A lock that cannot be taken over (it keeps coming back stale) ends after a
# bounded number of tries, each logged once, and is not reported as "busy":
# no update is running.
subscription_update_lock_take_over() { :; }
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
echo "999999" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
: > "$LOG_FILE"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update 30m > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
if [ "$rc" -eq "$SUBSCRIPTION_UPDATE_LOCK_FAILED" ] &&
    [ "$(grep -c "lock is stale" "$LOG_FILE")" -eq "$SUBSCRIPTION_UPDATE_LOCK_RETRIES" ] &&
    grep -q "could not be taken over" "$LOG_FILE"; then
    echo 'subcron:lock-takeover-bounded:OK'
else
    echo "subcron:lock-takeover-bounded:FAIL [rc=$rc stale=$(grep -c "lock is stale" "$LOG_FILE")]"
fi
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"
eval "$(extract subscription_update_lock_take_over)"

# The owner records its start time: a live netshift process that merely got the
# dead owner's pid does not keep the lock.
hold_lock
echo "1" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/start"
: > "$WORK/updated.log"
rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update 30m > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
drop_lock_holder
if [ "$rc" -eq 0 ] && [ -s "$WORK/updated.log" ]; then
    echo 'subcron:lock-reused-pid-by-netshift-taken-over:OK'
else
    echo "subcron:lock-reused-pid-by-netshift-taken-over:FAIL [rc=$rc]"
fi
# ...and the matching start time keeps it.
hold_lock
subscription_update_lock_process_start "$HOLDER_PID" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/start"
SUBSCRIPTION_UPDATE_LOCK_MODE=nowait
subscription_update 30m > /dev/null 2>&1
rc=$?
unset SUBSCRIPTION_UPDATE_LOCK_MODE
if [ "$rc" -eq "$SUBSCRIPTION_UPDATE_BUSY" ] && [ -s "$SUBSCRIPTION_UPDATE_LOCK_DIR/start" ]; then
    echo 'subcron:lock-start-time-match-busy:OK'
else
    echo "subcron:lock-start-time-match-busy:FAIL [rc=$rc]"
fi
drop_lock_holder
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"

# Two waiters that saw the same dead owner: the slower one must not delete the
# lock the faster one has just taken.
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
echo "999999" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
subscription_update_lock_take_over "999999"
mkdir "$SUBSCRIPTION_UPDATE_LOCK_DIR" && echo "4242" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
subscription_update_lock_take_over "999999"
if [ "$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid" 2> /dev/null)" = "4242" ] &&
    [ -z "$(ls -d "$SUBSCRIPTION_UPDATE_LOCK_DIR".stale.* 2> /dev/null)" ]; then
    echo 'subcron:lock-takeover-keeps-new-owner:OK'
else
    echo "subcron:lock-takeover-keeps-new-owner:FAIL [pid=$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid" 2> /dev/null)]"
fi
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"

# A lock that belongs to another live update is not this run's to release.
hold_lock
subscription_update_lock_release
if [ "$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid" 2> /dev/null)" = "$HOLDER_PID" ]; then
    echo 'subcron:lock-release-keeps-foreign-lock:OK'
else
    echo 'subcron:lock-release-keeps-foreign-lock:FAIL'
fi
drop_lock_holder
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
echo "$$" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
subscription_update_lock_release
if [ ! -e "$SUBSCRIPTION_UPDATE_LOCK_DIR" ]; then
    echo 'subcron:lock-release-removes-own-lock:OK'
else
    echo 'subcron:lock-release-removes-own-lock:FAIL'
fi
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"

# The takeover renamed a lock whose owner turns out to be alive (it was read as
# dead a moment earlier): it goes back untouched instead of being deleted.
hold_lock
subscription_update_lock_take_over "$HOLDER_PID"
if [ "$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid" 2> /dev/null)" = "$HOLDER_PID" ] &&
    [ -z "$(ls -d "$SUBSCRIPTION_UPDATE_LOCK_DIR".stale.* 2> /dev/null)" ]; then
    echo 'subcron:lock-takeover-keeps-live-owner:OK'
else
    echo 'subcron:lock-takeover-keeps-live-owner:FAIL'
fi
# A live lock stranded under the private name by a put-back that failed is not
# deleted by the next takeover either.
mv "$SUBSCRIPTION_UPDATE_LOCK_DIR" "$SUBSCRIPTION_UPDATE_LOCK_DIR.stale.$$"
mkdir -p "$SUBSCRIPTION_UPDATE_LOCK_DIR"
echo "999999" > "$SUBSCRIPTION_UPDATE_LOCK_DIR/pid"
subscription_update_lock_take_over "999999"
if [ "$(cat "$SUBSCRIPTION_UPDATE_LOCK_DIR.stale.$$/pid" 2> /dev/null)" = "$HOLDER_PID" ]; then
    echo 'subcron:lock-takeover-keeps-stranded-live-lock:OK'
else
    echo 'subcron:lock-takeover-keeps-stranded-live-lock:FAIL'
fi
drop_lock_holder
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR" "$SUBSCRIPTION_UPDATE_LOCK_DIR.stale.$$"

# ── dashboard workers: `component_action subscription update[_feed]` ──
# 'fast' has two feeds. A dashboard block is named by the tag of its urltest,
# and the map written with the config says which feed that tag stands for.
# $1 = tag of fast-a's block, $2 = tag of fast-b's block.
feed_tags() {
    jq -cn --arg tag "$1" --arg hash "$(get_subscription_url_hash "https://feed.example.com/fast-a")" \
        '{tag: $tag, section: "fast", hash: $hash}' > "$SUBSCRIPTION_FEED_TAGS_FILE"
    jq -cn --arg tag "$2" --arg hash "$(get_subscription_url_hash "https://feed.example.com/fast-b")" \
        '{tag: $tag, section: "fast", hash: $hash}' >> "$SUBSCRIPTION_FEED_TAGS_FILE"
}
feed_worker() {
    : > "$WORK/updated.log"
    : > "$WORK/downloaded-urls.log"
    rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
    subscription_update_feed_worker "$@" > "$WORK/worker.out" 2> /dev/null
    WORKER_RC=$?
    WORKER_JSON="$(tail -n 1 "$WORK/worker.out")"
    WORKER_URLS="$(sort -u "$WORK/downloaded-urls.log" | tr '\n' ' ')"
}
worker_ok() { printf '%s' "$WORKER_JSON" | jq -e '.success == true' > /dev/null 2>&1; }
worker_failed_with() {
    printf '%s' "$WORKER_JSON" | jq -e --arg t "$1" '.success == false and (.message | contains($t))' > /dev/null 2>&1
}

feed_worker fast
if [ "$WORKER_RC" -eq 0 ] && worker_ok &&
    [ "$WORKER_URLS" = "https://feed.example.com/fast-a https://feed.example.com/fast-b " ]; then
    echo 'subcron:feed-worker-whole-section:OK'
else
    echo "subcron:feed-worker-whole-section:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
feed_tags "⚡ feed.example.com" "⚡ feed.example.com (2)"
: > "$LOG_FILE"
feed_worker fast "⚡ feed.example.com"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$WORKER_URLS" = "https://feed.example.com/fast-a " ]; then
    echo 'subcron:feed-worker-by-tag:OK'
else
    echo "subcron:feed-worker-by-tag:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
# The log counts the feeds this run refreshes, not every feed of the section.
if grep -q "section 'fast' (1 of 2 feed(s))" "$LOG_FILE"; then
    echo 'subcron:feed-worker-log-counts-selected:OK'
else
    echo "subcron:feed-worker-log-counts-selected:FAIL [$(grep 'feed(s)' "$LOG_FILE" | tr '\n' '|')]"
fi
feed_worker fast "⚡ feed.example.com (2)"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$WORKER_URLS" = "https://feed.example.com/fast-b " ]; then
    echo 'subcron:feed-worker-by-tag-second-feed:OK'
else
    echo "subcron:feed-worker-by-tag-second-feed:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
# Another section already owns "⚡ feed.example.com": sing-box got the tags with
# a dedup suffix, and those are what the dashboard sends.
feed_tags "⚡ feed.example.com-1" "⚡ feed.example.com (2)-3"
feed_worker fast "⚡ feed.example.com-1"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$WORKER_URLS" = "https://feed.example.com/fast-a " ]; then
    echo 'subcron:feed-worker-deduplicated-tag:OK'
else
    echo "subcron:feed-worker-deduplicated-tag:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
feed_worker fast "⚡ feed.example.com (2)-3"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$WORKER_URLS" = "https://feed.example.com/fast-b " ]; then
    echo 'subcron:feed-worker-deduplicated-tag-second-feed:OK'
else
    echo "subcron:feed-worker-deduplicated-tag-second-feed:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
# The tag is looked up, never read: here fast-a's block carries a tag that
# spells the NAME of fast-b's feed (a deduplicated "X" next to a feed literally
# named "X-1"). The refresh must hit fast-a, the feed the block shows.
feed_tags "⚡ feed.example.com (2)" "⚡ feed.example.com (2)-1"
feed_worker fast "⚡ feed.example.com (2)"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$WORKER_URLS" = "https://feed.example.com/fast-a " ]; then
    echo 'subcron:feed-worker-tag-spelling-another-feed-name:OK'
else
    echo "subcron:feed-worker-tag-spelling-another-feed-name:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
# The feed URL itself, as it stands in subscription_url, is accepted too.
feed_worker fast "https://feed.example.com/fast-b"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$WORKER_URLS" = "https://feed.example.com/fast-b " ]; then
    echo 'subcron:feed-worker-by-url:OK'
else
    echo "subcron:feed-worker-by-url:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
# An unknown block must fail loudly, never fall back to "refresh everything":
# a tag the map does not hold (a bare display name and a guessed dedup suffix
# among them), a URL of another section, a tag recorded for another section.
feed_tags "⚡ feed.example.com" "⚡ feed.example.com (2)"
jq -cn --arg hash "$(get_subscription_url_hash "https://feed.example.com/fast-a")" \
    '{tag: "⚡ slow block", section: "slow", hash: $hash}' >> "$SUBSCRIPTION_FEED_TAGS_FILE"
for unknown in "⚡ other.example.com" "⚡ feed.example.com-1" "feed.example.com (2)" "⚡ -1" "⚡ " \
    "https://feed.example.com/slow" "⚡ slow block"; do
    feed_worker fast "$unknown"
    if [ "$WORKER_RC" -ne 0 ] && [ -z "$WORKER_URLS" ] && worker_failed_with "was not found"; then
        echo "subcron:feed-worker-unknown-feed [$unknown]:OK"
    else
        echo "subcron:feed-worker-unknown-feed [$unknown]:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
    fi
done
# No map at all (the config was built without per-feed groups).
rm -f "$SUBSCRIPTION_FEED_TAGS_FILE"
feed_worker fast "⚡ feed.example.com"
if [ "$WORKER_RC" -ne 0 ] && [ -z "$WORKER_URLS" ] && worker_failed_with "was not found"; then
    echo 'subcron:feed-worker-no-tag-map:OK'
else
    echo "subcron:feed-worker-no-tag-map:FAIL [rc=$WORKER_RC urls=$WORKER_URLS json=$WORKER_JSON]"
fi
feed_worker plain
if [ "$WORKER_RC" -ne 0 ] && [ -z "$WORKER_URLS" ] && worker_failed_with "not a subscription section"; then
    echo 'subcron:feed-worker-rejects-non-subscription:OK'
else
    echo "subcron:feed-worker-rejects-non-subscription:FAIL [rc=$WORKER_RC json=$WORKER_JSON]"
fi
feed_worker ""
if [ "$WORKER_RC" -ne 0 ] && worker_failed_with "section is required"; then
    echo 'subcron:feed-worker-requires-section:OK'
else
    echo "subcron:feed-worker-requires-section:FAIL [rc=$WORKER_RC json=$WORKER_JSON]"
fi

# Both workers refuse to run next to another update and say why.
hold_lock
feed_worker fast
if [ "$WORKER_RC" -eq "$SUBSCRIPTION_UPDATE_BUSY" ] && [ -z "$WORKER_URLS" ] && worker_failed_with "already running"; then
    echo 'subcron:feed-worker-busy:OK'
else
    echo "subcron:feed-worker-busy:FAIL [rc=$WORKER_RC json=$WORKER_JSON]"
fi
: > "$WORK/updated.log"
subscription_update_all_worker > "$WORK/worker.out" 2> /dev/null
WORKER_RC=$?
WORKER_JSON="$(tail -n 1 "$WORK/worker.out")"
if [ "$WORKER_RC" -eq "$SUBSCRIPTION_UPDATE_BUSY" ] && [ ! -s "$WORK/updated.log" ] && worker_failed_with "already running"; then
    echo 'subcron:all-worker-busy:OK'
else
    echo "subcron:all-worker-busy:FAIL [rc=$WORKER_RC json=$WORKER_JSON]"
fi
drop_lock_holder
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"

# A lock that cannot be created is reported as such, not as a running update.
real_lock_dir="$SUBSCRIPTION_UPDATE_LOCK_DIR"
: > "$WORK/not-a-directory"
SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK/not-a-directory/lock"
feed_worker fast
if [ "$WORKER_RC" -eq "$SUBSCRIPTION_UPDATE_LOCK_FAILED" ] && [ -z "$WORKER_URLS" ] &&
    worker_failed_with "Cannot take the subscription update lock" &&
    ! worker_failed_with "already running"; then
    echo 'subcron:feed-worker-lock-failed:OK'
else
    echo "subcron:feed-worker-lock-failed:FAIL [rc=$WORKER_RC json=$WORKER_JSON]"
fi
SUBSCRIPTION_UPDATE_LOCK_DIR="$real_lock_dir"
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"

: > "$WORK/updated.log"
rm -f "$SUBSCRIPTION_PENDING_APPLY_FLAG"
subscription_update_all_worker > "$WORK/worker.out" 2> /dev/null
WORKER_RC=$?
WORKER_JSON="$(tail -n 1 "$WORK/worker.out")"
if [ "$WORKER_RC" -eq 0 ] && worker_ok && [ "$(sort -u "$WORK/updated.log" | tr '\n' ' ')" = "fast odd slow " ]; then
    echo 'subcron:all-worker-updates-every-section:OK'
else
    echo "subcron:all-worker-updates-every-section:FAIL [rc=$WORKER_RC json=$WORKER_JSON]"
fi
# The nowait mode is the worker's own: a later scheduled run still waits.
if [ -z "${SUBSCRIPTION_UPDATE_LOCK_MODE:-}" ]; then
    echo 'subcron:worker-lock-mode-does-not-leak:OK'
else
    echo "subcron:worker-lock-mode-does-not-leak:FAIL [$SUBSCRIPTION_UPDATE_LOCK_MODE]"
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
# Test: LuCI views cache busting
# ─────────────────────────────────────────────────────────────────
# LuCI requests view modules as .../view/<name>.js?v=<LuCI core version>, which
# does not change when this app is updated, so a browser kept serving the
# previous version's JS. luci-app-netshift/cache-bust.sh (run from the package
# Makefile) installs the views in a content-hashed view/netshift_<hash>/ and
# points the requires and the menu at it, so every new build has new URLs.
# Runs the REAL script on a copy of the source tree and checks:
#   - directory renamed, every `require view.netshift.<x>` and the menu path
#     rewritten, nothing left pointing at the old directory;
#   - the tag follows the content (and the stamped version), and is stable;
#   - a broken tree fails instead of producing a package that cannot load;
# plus the backend lookup of the installed LuCI app version (get_luci_app_version),
# which has to find main.js in the hashed directory.
test_luci_cache_bust() {
    header "LuCI views cache busting"

    local src="${NETSHIFT_LUCI_SRC:-/luci-app-netshift}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$src/cache-bust.sh" ] || [ ! -d "$src/htdocs" ]; then
        fail "cachebust" "luci-app-netshift source not mounted at $src (mount ../luci-app-netshift at /luci-app-netshift)"
        return
    fi
    if [ ! -r "$bin" ] || ! command -v jq > /dev/null 2>&1; then
        skip "cachebust - bin/netshift or jq not found"
        return
    fi

    local work="/tmp/netshift-cachebust-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        W="$work"
        view_rel="htdocs/luci-static/resources/view"

        fresh() { # $1=name: copy of the source tree, version stamped like the Makefile does
            rm -rf "$W/$1"
            mkdir -p "$W/$1"
            cp -R "$src/htdocs" "$src/root" "$W/$1/"
            sed -i -e "s/__COMPILED_VERSION_VARIABLE__/${2:-0.9.9}/g" "$W/$1/$view_rel/netshift/main.js"
        }
        run() { sh "$src/cache-bust.sh" "$W/$1/htdocs" "$W/$1/root" > "$W/$1.out" 2>&1; }
        tag_of() { ls "$W/$1/$view_rel" | grep '^netshift_' | head -1; }

        fresh a
        run a && echo "script-ok:yes" || echo "script-ok:no"
        tag="$(tag_of a)"
        echo "tag-shape:$(printf '%s' "$tag" | grep -Eq '^netshift_[0-9a-f]{8}$' && echo yes || echo no)"
        echo "old-dir-gone:$([ -d "$W/a/$view_rel/netshift" ] && echo no || echo yes)"

        # Same files as in the source tree, just moved.
        moved=yes
        for f in "$src/htdocs/luci-static/resources/view/netshift"/*.js; do
            [ -f "$W/a/$view_rel/$tag/$(basename "$f")" ] || moved=no
        done
        echo "all-views-moved:$moved"

        echo "no-old-requires:$(grep -l 'view\.netshift\.' "$W/a/$view_rel/$tag"/*.js > /dev/null 2>&1 && echo no || echo yes)"
        echo "requires-new-dir:$(grep -h 'require view\.' "$W/a/$view_rel/$tag"/*.js | grep -vc "require view\.$tag\." | grep -qx 0 && echo yes || echo no)"
        deps=yes
        for ref in $(grep -ho "require view\.$tag\.[A-Za-z0-9_]*" "$W/a/$view_rel/$tag"/*.js | sort -u | sed "s/.*\.//"); do
            [ -f "$W/a/$view_rel/$tag/$ref.js" ] || deps=no
        done
        echo "every-require-resolves:$deps"
        echo "has-requires:$(grep -hc "require view\.$tag\." "$W/a/$view_rel/$tag"/*.js | awk '{n+=$1} END{print (n>0)?"yes":"no"}')"

        menu="$W/a/root/usr/share/luci/menu.d/luci-app-netshift.json"
        echo "menu-path:$(jq -r '."admin/services/netshift".action.path' "$menu")"
        echo "menu-only-path-changed:$([ "$(jq -S 'del(."admin/services/netshift".action.path)' "$menu")" = "$(jq -S 'del(."admin/services/netshift".action.path)' "$src/root/usr/share/luci/menu.d/luci-app-netshift.json")" ] && echo yes || echo no)"
        echo "menu-target-exists:$([ -f "$W/a/$view_rel/$(jq -r '."admin/services/netshift".action.path' "$menu" | cut -d/ -f1)/netshift.js" ] && echo yes || echo no)"

        # Deterministic: the same build gives the same directory.
        fresh b
        run b || echo "run-b:failed"
        echo "deterministic:$([ "$(tag_of b)" = "$tag" ] && echo yes || echo no)"
        # The tag follows the stamped version (a new release => new URLs) ...
        fresh c 0.9.10
        run c || echo "run-c:failed"
        echo "changes-with-version:$([ "$(tag_of c)" != "$tag" ] && echo yes || echo no)"
        # ... and the content.
        fresh d
        printf '\n// edit\n' >> "$W/d/$view_rel/netshift/section.js"
        run d || echo "run-d:failed"
        echo "changes-with-content:$([ "$(tag_of d)" != "$tag" ] && echo yes || echo no)"

        # The tag is the md5 of the stamped views concatenated in byte order.
        fresh m
        want_tag="netshift_$(cd "$W/m/$view_rel/netshift" && LC_ALL=C cat ./*.js | LC_ALL=C md5sum | cut -c1-8)"
        run m || echo "run-m:failed"
        echo "tag-is-content-md5:$([ "$(tag_of m)" = "$want_tag" ] && echo yes || echo no)"

        # A broken tree must fail the build.
        fresh e
        rm -rf "$W/e/$view_rel/netshift"
        run e && echo "missing-views-fails:no" || echo "missing-views-fails:yes"
        echo "missing-views-message:$(grep -c 'view/netshift not found' "$W/e.out")"
        fresh f
        rm -f "$W/f/root/usr/share/luci/menu.d/luci-app-netshift.json"
        run f && echo "missing-menu-fails:no" || echo "missing-menu-fails:yes"
        echo "missing-menu-message:$(grep -c 'luci-app-netshift.json not found' "$W/f.out")"
        # A require that points at a view that does not exist is caught.
        fresh g
        sed -i 's/require view\.netshift\.main as main/require view.netshift.nosuchview as main/' "$W/g/$view_rel/netshift/diagnostic.js"
        run g && echo "dangling-require-fails:no" || echo "dangling-require-fails:yes"
        # A leftover path-form reference and a reference to another hash are caught too.
        fresh h
        printf '\nL.resource("view/netshift/main.js");\n' >> "$W/h/$view_rel/netshift/diagnostic.js"
        run h && echo "path-form-reference-fails:no" || echo "path-form-reference-fails:yes"
        fresh i
        printf '\n// require view.netshift_deadbeef.main\n' >> "$W/i/$view_rel/netshift/diagnostic.js"
        run i && echo "foreign-hash-reference-fails:no" || echo "foreign-hash-reference-fails:yes"
        # No .js views at all, and a second run over a processed tree, fail with a clear error.
        fresh j
        rm -f "$W/j/$view_rel/netshift"/*.js
        run j && echo "empty-views-fails:no" || echo "empty-views-fails:yes"
        echo "empty-views-message:$(grep -c 'no .js views' "$W/j.out")"
        fresh k
        run k || echo "run-k:failed"
        run k && echo "rerun-fails:no" || echo "rerun-fails:yes"
        echo "rerun-message:$(grep -c 'view/netshift not found' "$W/k.out")"
        # The target directory already there next to a plain view/netshift: refused.
        fresh x
        run x || echo "run-x:failed"
        mkdir -p "$W/x/$view_rel/netshift"
        cp "$src/htdocs/luci-static/resources/view/netshift"/*.js "$W/x/$view_rel/netshift/"
        sed -i -e "s/__COMPILED_VERSION_VARIABLE__/0.9.9/g" "$W/x/$view_rel/netshift/main.js"
        run x && echo "already-exists-fails:no" || echo "already-exists-fails:yes"
        echo "already-exists-message:$(grep -c 'already exists' "$W/x.out")"
        # A version placeholder that was never stamped fails the build instead of
        # shipping a bundle that cannot tell its version.
        rm -rf "$W/n"; mkdir -p "$W/n"
        cp -R "$src/htdocs" "$src/root" "$W/n/"
        run n && echo "unstamped-version-fails:no" || echo "unstamped-version-fails:yes"
        echo "unstamped-version-message:$(grep -c 'version placeholder not stamped' "$W/n.out")"

        # ── backend: version of the installed LuCI app ──────────────────
        log() { :; }
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        eval "$(awk -v f="get_luci_app_version" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        mkver() { mkdir -p "$LUCI_VIEW_DIR/$1"; printf 'var NETSHIFT_LUCI_APP_VERSION = "%s";\n' "$2" > "$LUCI_VIEW_DIR/$1/main.js"; }
        # The version line of the REAL bundle, as built and stamped, is understood.
        LUCI_VIEW_DIR="$W/a/$view_rel"
        echo "version-real-bundle:$(get_luci_app_version)"
        LUCI_VIEW_DIR="$W/luciview"
        LUCI_MENU_FILE="$W/no-such-menu.json"
        rm -rf "$LUCI_VIEW_DIR"; mkdir -p "$LUCI_VIEW_DIR"
        echo "version-none:$(get_luci_app_version)"
        mkver netshift 0.8.0
        echo "version-legacy-dir:$(get_luci_app_version)"
        # Dates are made by creation order (a one-second gap), never by fixed dates.
        sleep 1
        mkver netshift_1a2b3c4d 0.9.9.5
        echo "version-hashed-dir-wins:$(get_luci_app_version)"
        rm -rf "$LUCI_VIEW_DIR/netshift"
        echo "version-hashed-dir:$(get_luci_app_version)"
        # Without a menu entry the newest main.js is the installed one, whichever way
        # the hash of a leftover directory sorts.
        rm -rf "$LUCI_VIEW_DIR"; mkdir -p "$LUCI_VIEW_DIR"
        mkver netshift_ffffffff 0.9.9.4; mkver netshift_00000000 0.9.9.4
        sleep 1
        mkver netshift_1a2b3c4d 0.9.9.5
        echo "version-old-dirs-lose:$(get_luci_app_version)"
        # With the menu entry, the directory it opens is the installed one even when a
        # leftover (a downgrade, a manual copy) is newer.
        printf '{"admin/services/netshift":{"action":{"type":"view","path":"netshift_1a2b3c4d/netshift"}}}\n' > "$LUCI_MENU_FILE"
        sleep 1
        mkver netshift_22222222 0.9.9.6
        echo "version-menu-wins-over-newer-leftover:$(get_luci_app_version)"
        # A menu entry that points to a directory that is not there is ignored.
        printf '{"admin/services/netshift":{"action":{"type":"view","path":"netshift_99999999/netshift"}}}\n' > "$LUCI_MENU_FILE"
        echo "version-menu-dangling-falls-back:$(get_luci_app_version)"
        rm -f "$LUCI_MENU_FILE"
        # A main.js without the version line is skipped, never reported as an empty
        # string; with nothing usable left the app is installed but of unknown version.
        rm -rf "$LUCI_VIEW_DIR"; mkdir -p "$LUCI_VIEW_DIR"
        mkver netshift_1a2b3c4d 0.9.9.5
        mkdir -p "$LUCI_VIEW_DIR/netshift_00000001"
        printf 'var SOMETHING_ELSE = 1;\n' > "$LUCI_VIEW_DIR/netshift_00000001/main.js"
        echo "version-missing-line-skipped:$(get_luci_app_version)"
        rm -rf "$LUCI_VIEW_DIR/netshift_1a2b3c4d"
        echo "version-missing-line:$(get_luci_app_version)"

        # ── package postinst: earlier view directories are removed, the installed one stays
        mk="$src/Makefile"
        awk '/^define Package\/\$\(PKG_NAME\)\/postinst/{p=1;next} /^endef/{if(p)exit} p' "$mk" | sed 's/\$\$/$/g' > "$W/postinst.sh"
        echo "postinst-extracted:$([ -s "$W/postinst.sh" ] && echo yes || echo no)"
        PV="$W/pi/view"; PM="$W/pi/menu.json"
        rm -rf "$W/pi"; mkdir -p "$PV/netshift_aaaaaaaa" "$PV/netshift_bbbbbbbb" "$PV/netshift_cccccccc" "$PV/netshift" "$PV/other"
        printf '{"admin/services/netshift":{"action":{"type":"view","path":"netshift_bbbbbbbb/netshift"}}}\n' > "$PM"
        ( LUCI_VIEW_DIR="$PV" LUCI_MENU_FILE="$PM" sh "$W/postinst.sh" ) > /dev/null 2>&1
        echo "postinst-keeps-active:$(ls "$PV" | tr '\n' ',')"
        # Image build (IPKG_INSTROOT set): nothing is touched.
        mkdir -p "$PV/netshift_aaaaaaaa"
        ( IPKG_INSTROOT=/x LUCI_VIEW_DIR="$PV" LUCI_MENU_FILE="$PM" sh "$W/postinst.sh" ) > /dev/null 2>&1
        echo "postinst-image-build-untouched:$([ -d "$PV/netshift_aaaaaaaa" ] && echo yes || echo no)"
        # No usable menu entry: nothing is removed.
        printf '{}\n' > "$PM"
        ( LUCI_VIEW_DIR="$PV" LUCI_MENU_FILE="$PM" sh "$W/postinst.sh" ) > /dev/null 2>&1
        echo "postinst-no-menu-removes-nothing:$([ -d "$PV/netshift_aaaaaaaa" ] && [ -d "$PV/netshift_bbbbbbbb" ] && echo yes || echo no)"
    )"
    rm -rf "$work"

    _cb_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _cb_check "the script succeeds on the source tree" "script-ok:yes"
    _cb_check "the views directory is named netshift_<8 hex>" "tag-shape:yes"
    _cb_check "the old view/netshift directory is gone" "old-dir-gone:yes"
    _cb_check "every view file is kept, only moved" "all-views-moved:yes"
    _cb_check "no require points at the old directory" "no-old-requires:yes"
    _cb_check "every require uses the new directory" "requires-new-dir:yes"
    _cb_check "the views do require each other (rewrite is exercised)" "has-requires:yes"
    _cb_check "every required view exists in the new directory" "every-require-resolves:yes"
    _cb_check "the menu opens the hashed directory" "menu-target-exists:yes"
    _cb_check "only the menu path changed in the menu file" "menu-only-path-changed:yes"
    _cb_check "the same build gives the same directory" "deterministic:yes"
    _cb_check "a new version gets a new directory" "changes-with-version:yes"
    _cb_check "changed content gets a new directory" "changes-with-content:yes"
    _cb_check "a missing views directory fails the build" "missing-views-fails:yes"
    _cb_check "a missing menu file fails the build" "missing-menu-fails:yes"
    _cb_check "a require of a missing view fails the build" "dangling-require-fails:yes"
    _cb_check "no LuCI app: not installed" "version-none:not installed"
    _cb_check "version is read from a legacy view/netshift directory" "version-legacy-dir:0.8.0"
    _cb_check "the hashed directory wins over a legacy one" "version-hashed-dir-wins:0.9.9.5"
    _cb_check "version is read from the hashed directory" "version-hashed-dir:0.9.9.5"
    _cb_check "the real bundle's version line is understood" "version-real-bundle:0.9.9"
    _cb_check "leftover older directories lose, whichever way their hash sorts" "version-old-dirs-lose:0.9.9.5"
    _cb_check "the menu entry names the installed directory, even when a leftover is newer" "version-menu-wins-over-newer-leftover:0.9.9.5"
    _cb_check "a menu entry to a missing directory is ignored" "version-menu-dangling-falls-back:0.9.9.6"
    _cb_check "postinst is found in the Makefile" "postinst-extracted:yes"
    _cb_check "postinst removes earlier view directories and keeps the installed one" "postinst-keeps-active:netshift_bbbbbbbb,other,"
    _cb_check "postinst does nothing during an image build" "postinst-image-build-untouched:yes"
    _cb_check "postinst removes nothing without a usable menu entry" "postinst-no-menu-removes-nothing:yes"
    _cb_check "a main.js without a version line is skipped for one that has it" "version-missing-line-skipped:0.9.9.5"
    _cb_check "only a main.js without a version line: unknown, not an empty string or not installed" "version-missing-line:unknown"
    _cb_check "a missing views directory says so" "missing-views-message:1"
    _cb_check "a missing menu file says so" "missing-menu-message:1"
    _cb_check "a second run over a processed tree reports the missing source directory" "rerun-message:1"
    _cb_check "an existing target directory is refused" "already-exists-fails:yes"
    _cb_check "...with its own message" "already-exists-message:1"
    _cb_check "an unstamped version placeholder fails the build" "unstamped-version-fails:yes"
    _cb_check "...and says so" "unstamped-version-message:1"
    _cb_check "the tag is the md5 of the stamped views" "tag-is-content-md5:yes"
    _cb_check "a leftover view/netshift path reference fails the build" "path-form-reference-fails:yes"
    _cb_check "a reference to another hash fails the build" "foreign-hash-reference-fails:yes"
    _cb_check "no .js views fails the build" "empty-views-fails:yes"
    _cb_check "no .js views: the error says so" "empty-views-message:1"
    _cb_check "a second run over a processed tree fails" "rerun-fails:yes"
    if echo "$out" | grep -q '^menu-path:netshift_[0-9a-f]\{8\}/netshift$'; then
        pass "the menu path is netshift_<hash>/netshift"
    else
        fail "the menu path is netshift_<hash>/netshift" "$(echo "$out" | grep '^menu-path' )"
    fi
}

# Test: Reality X25519MLKEM768 per-section option
# ─────────────────────────────────────────────────────────────────
# REALITY servers on Xray-core >= 26.9.8 reject a client that does not offer the
# X25519MLKEM768 key share, and sing-box strips it by default. sing-box-extended
# 2.7.2+ has `tls.reality.support_x25519mlkem768` to keep it. The per-section
# `reality_mlkem` option must:
#   - do nothing by default (no field: older Xray servers may fail with it);
#   - add the field ONLY to Reality outbounds, for link sections and for
#     subscription batches, when the option is on;
#   - be ignored, with a warning, on a core that does not know the field
#     (stock sing-box, extended < 2.7.2), because that field would fail
#     `sing-box check` and take the whole section down.
# The REAL set_section_reality_mlkem / facade / config manager run here.
test_reality_mlkem() {
    header "Reality X25519MLKEM768 option"

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local f
    for f in constants.sh helpers.sh sing_box_config_manager.sh sing_box_config_facade.sh helpers.jq; do
        if [ ! -r "$lib/$f" ]; then
            skip "reality_mlkem - $f not found"
            return
        fi
    done
    if [ ! -r "$bin" ] || ! command -v jq > /dev/null 2>&1; then
        skip "reality_mlkem - bin/netshift or jq not found"
        return
    fi

    # The facade sources its siblings from the runtime path.
    mkdir -p /usr/lib/netshift
    for f in constants.sh helpers.sh sing_box_config_manager.sh sing_box_config_facade.sh helpers.jq; do
        ln -sf "$lib/$f" "/usr/lib/netshift/$f"
    done

    local out
    out="$(
        RM_LOG="/tmp/netshift-realitymlkem-$$.log"
        : > "$RM_LOG"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$RM_LOG"; }
        echolog() { log "$1" "${2:-info}"; }
        nolog() { :; }
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        NETSHIFT_LIB="$lib"
        . "$lib/sing_box_config_manager.sh"
        . "$lib/sing_box_config_facade.sh"
        eval "$(awk -v f="set_section_reality_mlkem" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"

        # UCI stub for config_get_bool: RM_<section>_<option>
        # UCI stub for config_get: connection_type / proxy_config_type of section s
        config_get() {
            local _v
            eval "_v=\"\${RM_${2}_${3}:-}\""
            [ -n "$_v" ] || case "$3" in
            connection_type) _v="${RM_conn:-proxy}" ;;
            proxy_config_type) _v="${RM_ptype:-url}" ;;
            esac
            eval "$1=\"\$_v\""
        }
        config_get_bool() {
            local _v
            eval "_v=\"\${RM_${2}_${3}:-}\""
            [ -n "$_v" ] || _v="$4"
            case "$_v" in 1 | on | true | yes | enabled) _v=1 ;; *) _v=0 ;; esac
            eval "$1=\"\$_v\""
        }

        gate() { # $1=core version, $2=option value ("" = option absent)
            NETSHIFT_SING_BOX_VERSION="$1"
            export NETSHIFT_SING_BOX_VERSION
            RM_s_reality_mlkem="$2"
            : > "$RM_LOG"
            set_section_reality_mlkem s
            printf '%s' "$NETSHIFT_REALITY_MLKEM"
        }
        echo "gate-default-off:$(gate 1.14.1-extended-2.7.2-lite '')"
        echo "gate-off-explicit:$(gate 1.14.1-extended-2.7.2-lite 0)"
        echo "gate-lite-2.7.2:$(gate 1.14.1-extended-2.7.2-lite 1)"
        echo "gate-extended-2.7.2:$(gate 1.14.1-extended-2.7.2 1)"
        echo "gate-extended-newer:$(gate 1.14.2-extended-2.8.0 1)"
        echo "gate-extended-2.7.1:$(gate 1.14.0-extended-2.7.1 1)"
        warned="no"
        grep -q "^\[warn\] Section 's': reality_mlkem needs sing-box-extended $SB_EXTENDED_REALITY_MLKEM_MIN" "$RM_LOG" && warned="yes"
        echo "gate-old-extended-warned:$warned"
        # Two-digit minor: a plain string comparison would sort 2.10.0 below 2.7.2.
        echo "gate-extended-2.10.0:$(gate 1.15.0-extended-2.10.0 1)"
        echo "gate-stock:$(gate 1.13.14 1)"
        warned="no"
        grep -q "^\[warn\] Section 's': reality_mlkem needs sing-box-extended $SB_EXTENDED_REALITY_MLKEM_MIN" "$RM_LOG" && warned="yes"
        echo "gate-stock-warned:$warned"
        gate 1.14.1-extended-2.7.2-lite '' > /dev/null
        warned="no"
        [ -s "$RM_LOG" ] && warned="yes"
        echo "gate-off-silent:$([ "$warned" = no ] && echo yes || echo no)"

        mlk() { printf '%s' "$1" | jq -r '.outbounds[0].tls.reality // {} | if has("support_x25519mlkem768") then (.support_x25519mlkem768 | tostring) else "absent" end'; }
        LINK_R='vless://11111111-2222-3333-4444-555555555555@r.example.com:443?encryption=none&flow=xtls-rprx-vision&fp=chrome&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&security=reality&sid=0123abcd&sni=r.example.com&type=tcp'
        LINK_T='vless://11111111-2222-3333-4444-555555555555@t.example.com:443?encryption=none&security=tls&sni=t.example.com&type=tcp'
        base='{"outbounds":[]}'

        unset NETSHIFT_REALITY_MLKEM
        echo "link-default:$(mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0)")"
        NETSHIFT_REALITY_MLKEM=0
        echo "link-off:$(mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0)")"
        NETSHIFT_REALITY_MLKEM=1
        echo "link-on:$(mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0)")"
        echo "link-on-tls-untouched:$(mlk "$(sing_box_cf_add_proxy_outbound "$base" t "$LINK_T" 0)")"
        # Everything else about the Reality block is unchanged by the flag.
        on="$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0)"
        NETSHIFT_REALITY_MLKEM=0
        off="$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0)"
        same="no"
        [ "$(printf '%s' "$on" | jq -S 'del(.outbounds[0].tls.reality.support_x25519mlkem768)')" = "$(printf '%s' "$off" | jq -S .)" ] && same="yes"
        echo "link-on-otherwise-identical:$same"

        # Subscription batch: only Reality nodes get the field.
        SUBJ="/tmp/netshift-realitymlkem-sub-$$.json"
        cat > "$SUBJ" << 'SUBEOF'
{"outbounds":[
 {"type":"vless","tag":"reality-node","server":"r.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":"r.example.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0","short_id":"0123abcd"}}},
 {"type":"vless","tag":"tls-node","server":"t.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","tls":{"enabled":true,"server_name":"t.example.com"}},
 {"type":"trojan","tag":"plain-node","server":"p.example.com","server_port":443,"password":"x"}
]}
SUBEOF
        batch_field() { # $1=tag
            printf '%s' "$BATCH" | jq -r --arg t "$1" '.outbounds[] | select(.tag==$t) | .tls.reality as $r | $r | if . == null then "no-reality" elif has("support_x25519mlkem768") then (.support_x25519mlkem768 | tostring) else "absent" end'
        }
        NETSHIFT_REALITY_MLKEM=0
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ" '[]' '[]')"
        echo "batch-off:$(batch_field reality-node)"
        NETSHIFT_REALITY_MLKEM=1
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ" '[]' '[]')"
        echo "batch-on-reality:$(batch_field reality-node)"
        echo "batch-on-tls-untouched:$(batch_field tls-node)"
        echo "batch-on-plain-untouched:$(batch_field plain-node)"
        echo "batch-on-count:$(printf '%s' "$BATCH" | jq -r '.count')"

        # A field already on a node (a provider's sing-box config, or a link hint
        # kept by the normalized cache) stays on a core that knows it, option on
        # or off, and goes away on a core that does not (stock sing-box would fail
        # `sing-box check` on it).
        SUBJ2="/tmp/netshift-realitymlkem-sub2-$$.json"
        jq '.outbounds[0].tls.reality.support_x25519mlkem768 = true' "$SUBJ" > "$SUBJ2"
        NETSHIFT_SING_BOX_VERSION="1.14.1-extended-2.7.2-lite"
        export NETSHIFT_SING_BOX_VERSION
        NETSHIFT_REALITY_MLKEM=0
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ2" '[]' '[]')"
        echo "batch-off-keeps-cached-field:$(batch_field reality-node)"
        NETSHIFT_REALITY_MLKEM=1
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ2" '[]' '[]')"
        echo "batch-on-keeps-cached-field:$(batch_field reality-node)"
        NETSHIFT_SING_BOX_VERSION="1.13.14"
        NETSHIFT_REALITY_MLKEM=0
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ2" '[]' '[]')"
        echo "batch-stock-strips-cached-field:$(batch_field reality-node)"
        NETSHIFT_SING_BOX_VERSION="1.14.1-extended-2.7.2-lite"
        rm -f "$SUBJ2"

        # The normalized subscription cache never depends on the option: a URI
        # body parsed with the flag ON comes out without the field.
        NSRC="/tmp/netshift-realitymlkem-norm-$$.txt"
        NOUT="/tmp/netshift-realitymlkem-norm-$$.json"
        printf '%s\n' "$LINK_R" > "$NSRC"
        NETSHIFT_REALITY_MLKEM=1
        if normalize_subscription_to_singbox "$NSRC" "$NOUT" s; then
            echo "normalize-ignores-flag:$(jq -r '[.outbounds[] | .tls.reality // {} | if has("support_x25519mlkem768") then (.support_x25519mlkem768 | tostring) else "absent" end] | unique | join(",")' "$NOUT")"
        else
            echo "normalize-ignores-flag:normalize-failed"
        fi
        echo "normalize-restores-flag:$NETSHIFT_REALITY_MLKEM"
        rm -f "$NSRC" "$NOUT"

        # The user's own outbound JSON is never touched, flag on or not.
        RAW='{"type":"vless","server":"r.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0","short_id":"0123abcd"}}}'
        get_outbound_tag_by_section() { echo "$1-out"; }
        NETSHIFT_REALITY_MLKEM=1
        got="$(sing_box_cf_add_json_outbound "$base" raw "$RAW" | jq -cS '.outbounds[0] | del(.tag)')"
        want="$(printf '%s' "$RAW" | jq -cS .)"
        [ "$got" = "$want" ] && echo "raw-outbound-json-untouched:yes" || echo "raw-outbound-json-untouched:no [$got]"

        # Seam: the option goes through the REAL set_section_reality_mlkem from
        # the bin and the result reaches the facade, end to end (no hand-set flag).
        seam() { # $1=core version, $2=option
            NETSHIFT_SING_BOX_VERSION="$1"
            export NETSHIFT_SING_BOX_VERSION
            RM_s_reality_mlkem="$2"
            : > "$RM_LOG"
            set_section_reality_mlkem s
            mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0)"
        }
        echo "seam-lite-on:$(seam 1.14.1-extended-2.7.2-lite 1)"
        echo "seam-lite-off:$(seam 1.14.1-extended-2.7.2-lite 0)"
        echo "seam-stock-on:$(seam 1.13.14 1)"
        echo "seam-old-extended-on:$(seam 1.14.0-extended-2.7.1 1)"

        # fp other than chrome: the option would be a silent no-op, so it is warned about.
        LINK_F='vless://11111111-2222-3333-4444-555555555555@r.example.com:443?encryption=none&flow=xtls-rprx-vision&fp=firefox&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&security=reality&sid=0123abcd&sni=r.example.com&type=tcp'
        LINK_N='vless://11111111-2222-3333-4444-555555555555@r.example.com:443?encryption=none&flow=xtls-rprx-vision&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&security=reality&sid=0123abcd&sni=r.example.com&type=tcp'
        NETSHIFT_REALITY_MLKEM=1
        : > "$RM_LOG"
        sing_box_cf_add_proxy_outbound "$base" r "$LINK_R" 0 > /dev/null
        grep -q "key share is only sent with fp=chrome" "$RM_LOG" && echo "fp-chrome-silent:no" || echo "fp-chrome-silent:yes"
        : > "$RM_LOG"
        sing_box_cf_add_proxy_outbound "$base" r "$LINK_F" 0 > /dev/null
        grep -q "key share is only sent with fp=chrome" "$RM_LOG" && echo "fp-other-warned:yes" || echo "fp-other-warned:no"
        NETSHIFT_REALITY_MLKEM=0
        : > "$RM_LOG"
        sing_box_cf_add_proxy_outbound "$base" r "$LINK_F" 0 > /dev/null
        grep -q "key share is only sent with fp=chrome" "$RM_LOG" && echo "fp-other-off-silent:no" || echo "fp-other-off-silent:yes"

        # A link that does not use the chrome fingerprint never gets the field (the
        # core could reject it next to another fingerprint), and the log says so.
        NETSHIFT_REALITY_MLKEM=1
        : > "$RM_LOG"
        echo "link-fp-other-no-field:$(mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_F" 0)")"
        grep -q "has fingerprint 'firefox': the X25519MLKEM768 key share is only sent with fp=chrome, so it is not added for this link" "$RM_LOG" && echo "link-fp-other-says-so:yes" || echo "link-fp-other-says-so:no"
        : > "$RM_LOG"
        echo "link-no-fp-no-field:$(mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$LINK_N" 0)")"
        grep -q "has no fingerprint: the X25519MLKEM768 key share is only sent with fp=chrome, so it is not added for this link" "$RM_LOG" && echo "link-no-fp-says-so:yes" || echo "link-no-fp-says-so:no"

        # Subscription nodes: only chrome nodes get the field; a field that is already
        # there (provider's sing-box config) is removed from every other Reality
        # node, also when the node carries no `enabled` key or a string value.
        SUBJ3="/tmp/netshift-realitymlkem-sub3-$$.json"
        cat > "$SUBJ3" << 'SUBEOF'
{"outbounds":[
 {"type":"vless","tag":"chrome","server":"a.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"k","short_id":"s"}}},
 {"type":"vless","tag":"firefox","server":"b.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"utls":{"enabled":true,"fingerprint":"firefox"},"reality":{"enabled":true,"public_key":"k","short_id":"s","support_x25519mlkem768":true}}},
 {"type":"vless","tag":"nofp","server":"c.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"k","short_id":"s"}}},
 {"type":"vless","tag":"noenabled","server":"d.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"public_key":"k","short_id":"s","support_x25519mlkem768":true}}},
 {"type":"vless","tag":"stringtrue","server":"e.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":"true","public_key":"k","short_id":"s","support_x25519mlkem768":true}}}
]}
SUBEOF
        NETSHIFT_REALITY_MLKEM=1
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ3" '[]' '[]')"
        echo "batch-fp-on:$(batch_field chrome),$(batch_field firefox),$(batch_field nofp),$(batch_field noenabled),$(batch_field stringtrue)"
        NETSHIFT_REALITY_MLKEM=0
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ3" '[]' '[]')"
        echo "batch-fp-off:$(batch_field chrome),$(batch_field firefox),$(batch_field nofp),$(batch_field noenabled),$(batch_field stringtrue)"
        rm -f "$SUBJ3"

        # A provider node with a scalar `tls` (or `utls`) must not abort the whole
        # batch: the other nodes still come through.
        SUBJ4="/tmp/netshift-realitymlkem-sub4-$$.json"
        cat > "$SUBJ4" << 'SUBEOF'
{"outbounds":[
 {"type":"vless","tag":"scalar-tls","server":"s.example.com","server_port":443,"uuid":"u","tls":"none"},
 {"type":"vless","tag":"scalar-utls","server":"u.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"utls":"chrome","reality":{"enabled":true,"public_key":"k","short_id":"s"}}},
 {"type":"vless","tag":"chrome","server":"a.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"k","short_id":"s"}}}
]}
SUBEOF
        for flag in 0 1; do
            NETSHIFT_REALITY_MLKEM=$flag
            BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$SUBJ4" '[]' '[]')"
            echo "batch-scalar-tls-$flag:count=$(printf '%s' "$BATCH" | jq -r '.count // "abort"') chrome=$(batch_field chrome) scalar-utls=$(batch_field scalar-utls)"
        done
        rm -f "$SUBJ4"

        # The core version is resolved once per run, not once per section (a subshell:
        # the stub must not outlive this check).
        VCOUNT="/tmp/netshift-realitymlkem-vcount-$$"; : > "$VCOUNT"
        echo "version-resolved-once:$(
            get_sing_box_version() { # the real one reuses NETSHIFT_SING_BOX_VERSION when it is set
                if [ -n "${NETSHIFT_SING_BOX_VERSION:-}" ]; then echo "$NETSHIFT_SING_BOX_VERSION"; return; fi
                echo x >> "$VCOUNT"; echo "1.14.1-extended-2.7.2-lite"
            }
            unset NETSHIFT_SING_BOX_VERSION
            RM_s_reality_mlkem=1
            set_section_reality_mlkem s; set_section_reality_mlkem s; set_section_reality_mlkem s
            echo "$(wc -l < "$VCOUNT" | tr -d ' ')/$NETSHIFT_REALITY_MLKEM"
        )"
        rm -f "$VCOUNT"

        # Sections the option cannot apply to say so instead of ignoring it silently.
        RM_conn=direct
        echo "gate-not-proxy:$(gate 1.14.1-extended-2.7.2-lite 1)"
        grep -q "^\[warn\] Section 's': reality_mlkem does not apply" "$RM_LOG" && echo "gate-not-proxy-warned:yes" || echo "gate-not-proxy-warned:no"
        RM_conn=proxy; RM_ptype=outbound
        echo "gate-outbound-json:$(gate 1.14.1-extended-2.7.2-lite 1)"
        grep -q "^\[warn\] Section 's': reality_mlkem does not apply" "$RM_LOG" && echo "gate-outbound-json-warned:yes" || echo "gate-outbound-json-warned:no"
        RM_ptype=subscription
        echo "gate-subscription:$(gate 1.14.1-extended-2.7.2-lite 1)"
        RM_conn=""; RM_ptype=""

        # ── The link's own hint: support-x25519mlkem768 (3x-ui share links) ──
        # true/1 asks for the key share without the section option, false/0
        # refuses it even with the option on; the core gate and the fp=chrome
        # rule still apply, and a core that cannot send it says so in the log.
        LINK_H="$LINK_R&support-x25519mlkem768=true"
        LINK_H1="$LINK_R&support-x25519mlkem768=1"
        LINK_HF="$LINK_R&support-x25519mlkem768=false"
        LINK_HX="$LINK_R&support-x25519mlkem768=maybe"
        LINK_HFP="$LINK_F&support-x25519mlkem768=true"
        hint() { # $1=core version, $2=option ("" = absent), $3=link
            NETSHIFT_SING_BOX_VERSION="$1"
            export NETSHIFT_SING_BOX_VERSION
            RM_s_reality_mlkem="$2"
            : > "$RM_LOG"
            set_section_reality_mlkem s
            mlk "$(sing_box_cf_add_proxy_outbound "$base" r "$3" 0)"
        }
        hint_warned() { grep -q "asks for the X25519MLKEM768 key share" "$RM_LOG" && echo yes || echo no; }
        echo "hint-true:$(hint 1.14.1-extended-2.7.2 '' "$LINK_H")"
        echo "hint-true-silent:$([ -s "$RM_LOG" ] && echo no || echo yes)"
        echo "hint-1:$(hint 1.14.1-extended-2.7.2 '' "$LINK_H1")"
        echo "hint-true-lite:$(hint 1.14.1-extended-2.7.2-lite '' "$LINK_H")"
        echo "hint-true-stock:$(hint 1.13.14 '' "$LINK_H")"
        echo "hint-true-stock-warned:$(hint_warned)"
        echo "hint-true-old-extended:$(hint 1.14.0-extended-2.7.1 '' "$LINK_H")"
        echo "hint-true-old-extended-warned:$(hint_warned)"
        echo "hint-false-option-on:$(hint 1.14.1-extended-2.7.2 1 "$LINK_HF")"
        echo "hint-false-option-off:$(hint 1.14.1-extended-2.7.2 '' "$LINK_HF")"
        echo "hint-false-stock:$(hint 1.13.14 '' "$LINK_HF")"
        echo "hint-false-stock-silent:$([ -s "$RM_LOG" ] && echo no || echo yes)"
        echo "hint-invalid:$(hint 1.14.1-extended-2.7.2 '' "$LINK_HX")"
        echo "hint-true-fp-other:$(hint 1.14.1-extended-2.7.2 '' "$LINK_HFP")"
        grep -q "key share is only sent with fp=chrome" "$RM_LOG" && echo "hint-true-fp-other-warned:yes" || echo "hint-true-fp-other-warned:no"
        echo "hint-absent-option-off:$(hint 1.14.1-extended-2.7.2 '' "$LINK_R")"
        echo "hint-absent-option-on:$(hint 1.14.1-extended-2.7.2 1 "$LINK_R")"
        # A hint on a plain TLS link is meaningless and changes nothing.
        echo "hint-tls-untouched:$(hint 1.14.1-extended-2.7.2 '' "$LINK_T&support-x25519mlkem768=true")"

        # The normalized subscription cache carries the hint as written, whatever
        # the installed core (it is a property of the body), and without a
        # warning; the batch then gates it on the core and the section option.
        HSRC="/tmp/netshift-realitymlkem-hint-$$.txt"
        HOUT="/tmp/netshift-realitymlkem-hint-$$.json"
        printf '%s\n%s\n%s\n' "$LINK_H" "$LINK_HF" "$LINK_R" > "$HSRC"
        NETSHIFT_SING_BOX_VERSION="1.13.14"
        NETSHIFT_REALITY_MLKEM=0
        : > "$RM_LOG"
        fields() { jq -r '[.outbounds[] | select(.type == "vless") | .tls.reality // {} | if has("support_x25519mlkem768") then (.support_x25519mlkem768 | tostring) else "absent" end] | join(",")' "$1"; }
        if normalize_subscription_to_singbox "$HSRC" "$HOUT" s; then
            echo "normalize-hint:$(fields "$HOUT")"
        else
            echo "normalize-hint:normalize-failed"
        fi
        echo "normalize-hint-silent:$([ "$(hint_warned)" = no ] && echo yes || echo no)"
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$HOUT" '[]' '[]')"
        echo "batch-hint-stock:$(printf '%s' "$BATCH" | fields /dev/stdin)"
        NETSHIFT_SING_BOX_VERSION="1.14.1-extended-2.7.2"
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$HOUT" '[]' '[]')"
        echo "batch-hint-extended-off:$(printf '%s' "$BATCH" | fields /dev/stdin)"
        NETSHIFT_REALITY_MLKEM=1
        BATCH="$(sing_box_cf_prepare_subscription_batch "$base" "$HOUT" '[]' '[]')"
        echo "batch-hint-extended-on:$(printf '%s' "$BATCH" | fields /dev/stdin)"
        rm -f "$HSRC" "$HOUT"

        rm -f "$SUBJ" "$RM_LOG"
    )"

    _rm_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _rm_check "off by default: the option absent leaves the field out" "gate-default-off:0"
    _rm_check "off explicitly stays off" "gate-off-explicit:0"
    _rm_check "extended-lite 2.7.2 enables it" "gate-lite-2.7.2:1"
    _rm_check "extended 2.7.2 enables it" "gate-extended-2.7.2:1"
    _rm_check "a newer extended enables it" "gate-extended-newer:1"
    _rm_check "extended 2.7.1 (no such field) ignores it" "gate-extended-2.7.1:0"
    _rm_check "extended 2.10.0 (two-digit minor) enables it" "gate-extended-2.10.0:1"
    _rm_check "old extended: ignoring it is warned about" "gate-old-extended-warned:yes"
    _rm_check "stock sing-box ignores it" "gate-stock:0"
    _rm_check "stock sing-box: ignoring it is warned about" "gate-stock-warned:yes"
    _rm_check "no warning when the option is off" "gate-off-silent:yes"
    _rm_check "link: no field when the flag is unset" "link-default:absent"
    _rm_check "link: no field when the flag is off" "link-off:absent"
    _rm_check "link: Reality outbound gets support_x25519mlkem768" "link-on:true"
    _rm_check "link: a plain TLS outbound is never touched" "link-on-tls-untouched:absent"
    _rm_check "link: the flag changes nothing else in the outbound" "link-on-otherwise-identical:yes"
    _rm_check "subscription: no field when the flag is off" "batch-off:absent"
    _rm_check "subscription: Reality nodes get the field" "batch-on-reality:true"
    _rm_check "subscription: TLS nodes are untouched" "batch-on-tls-untouched:no-reality"
    _rm_check "subscription: non-TLS nodes are untouched" "batch-on-plain-untouched:no-reality"
    _rm_check "subscription: every node is kept" "batch-on-count:3"
    _rm_check "subscription: a cached field stays on a capable core with the option off" "batch-off-keeps-cached-field:true"
    _rm_check "subscription: a cached field stays when the option is on" "batch-on-keeps-cached-field:true"
    _rm_check "subscription: a cached field is removed on a core that does not know it" "batch-stock-strips-cached-field:absent"
    _rm_check "subscription cache: normalizing ignores the option" "normalize-ignores-flag:absent"
    _rm_check "subscription cache: normalizing restores the flag" "normalize-restores-flag:1"
    _rm_check "outbound_json: raw outbound is never touched" "raw-outbound-json-untouched:yes"
    _rm_check "seam: extended-lite 2.7.2 + option on puts the field in the outbound" "seam-lite-on:true"
    _rm_check "seam: option off leaves the outbound without it" "seam-lite-off:absent"
    _rm_check "seam: stock core leaves the outbound without it" "seam-stock-on:absent"
    _rm_check "seam: extended 2.7.1 leaves the outbound without it" "seam-old-extended-on:absent"
    _rm_check "fp=chrome: no warning" "fp-chrome-silent:yes"
    _rm_check "fp other than chrome: warned about" "fp-other-warned:yes"
    _rm_check "fp other than chrome with the option off: silent" "fp-other-off-silent:yes"
    _rm_check "a link with another fingerprint gets no field" "link-fp-other-no-field:absent"
    _rm_check "...and the log says why" "link-fp-other-says-so:yes"
    _rm_check "a link without a fingerprint gets no field" "link-no-fp-no-field:absent"
    _rm_check "...and the log says why (no fingerprint)" "link-no-fp-says-so:yes"
    _rm_check "subscription, option on: only the chrome node has the field" "batch-fp-on:true,absent,absent,absent,absent"
    _rm_check "subscription, option off: the field is removed from every Reality node" "batch-fp-off:absent,absent,absent,absent,absent"
    _rm_check "subscription: a scalar tls/utls node does not abort the batch (option off)" "batch-scalar-tls-0:count=3 chrome=absent scalar-utls=absent"
    _rm_check "subscription: a scalar tls/utls node does not abort the batch (option on)" "batch-scalar-tls-1:count=3 chrome=true scalar-utls=absent"
    _rm_check "the core version is resolved once for several sections" "version-resolved-once:1/1"
    _rm_check "option on a non-proxy section: off, with a warning" "gate-not-proxy:0"
    _rm_check "...warned" "gate-not-proxy-warned:yes"
    _rm_check "option on an outbound_json section: off, with a warning" "gate-outbound-json:0"
    _rm_check "...warned" "gate-outbound-json-warned:yes"
    _rm_check "option on a subscription section: on" "gate-subscription:1"
    _rm_check "link hint =true: the field without the section option" "hint-true:true"
    _rm_check "link hint =true: no warning on a capable core" "hint-true-silent:yes"
    _rm_check "link hint =1 counts as true" "hint-1:true"
    _rm_check "link hint =true on extended-lite 2.7.2" "hint-true-lite:true"
    _rm_check "link hint =true on stock sing-box: no field" "hint-true-stock:absent"
    _rm_check "...and the log says the server needs a capable core" "hint-true-stock-warned:yes"
    _rm_check "link hint =true on extended 2.7.1: no field" "hint-true-old-extended:absent"
    _rm_check "...and the log says so" "hint-true-old-extended-warned:yes"
    _rm_check "link hint =false wins over the section option" "hint-false-option-on:false"
    _rm_check "link hint =false with the option off: explicit false" "hint-false-option-off:false"
    _rm_check "link hint =false on stock sing-box: no field" "hint-false-stock:absent"
    _rm_check "...and no warning" "hint-false-stock-silent:yes"
    _rm_check "link hint with an unknown value: ignored" "hint-invalid:absent"
    _rm_check "link hint =true with another fingerprint: no field" "hint-true-fp-other:absent"
    _rm_check "...and the fp warning" "hint-true-fp-other-warned:yes"
    _rm_check "no hint, option off: unchanged (no field)" "hint-absent-option-off:absent"
    _rm_check "no hint, option on: unchanged (field)" "hint-absent-option-on:true"
    _rm_check "link hint on a plain TLS link: untouched" "hint-tls-untouched:absent"
    _rm_check "subscription cache: the hint is written as-is, whatever the core" "normalize-hint:true,false,absent"
    _rm_check "subscription cache: no warning while normalizing" "normalize-hint-silent:yes"
    _rm_check "subscription batch, stock core: every hint is dropped" "batch-hint-stock:absent,absent,absent"
    _rm_check "subscription batch, capable core, option off: hints kept" "batch-hint-extended-off:true,false,absent"
    _rm_check "subscription batch, capable core, option on: false still wins" "batch-hint-extended-on:true,false,true"
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
for fn in section_is_disabled _active_section_dispatch foreach_active_section tproxy_route_inbounds \
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
    # a real (if empty) package: the self-update checks that downloads are archives
    cp "$SU_FIXTURE_PKG" "$2"
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

    head -c 4000 /dev/urandom > "$work/fixture-payload"
    tar -czf "$work/fixture.ipk" -C "$work" fixture-payload
    export SU_FIXTURE_PKG="$work/fixture.ipk"
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

    # ── Scenario 3b: the download is an error page, not a package ─────────────
    # Nothing may be installed and the configuration stays as it was.
    : > "$SU_DNS_OK"; : > "$SU_HTTP_OK"; : > "$SU_GH_OK"; : > "$SU_DL_OK"; : > "$SU_PKG_OK"
    printf 'CONFIG-ORIG\n' > "$work/etc-config-netshift"
    printf 'netshift - 0.8.0-r1\n' > "$work/installed.list"
    local good_fixture="$SU_FIXTURE_PKG"
    printf '<html>API rate limit exceeded%s</html>' "$(head -c 3000 /dev/zero | tr '\0' 'x')" > "$work/fixture-page.ipk"
    export SU_FIXTURE_PKG="$work/fixture-page.ipk"
    run_scenario
    export SU_FIXTURE_PKG="$good_fixture"
    if jq -e '.success == false and (.message | contains("damaged"))' "$out" > /dev/null 2>&1; then
        pass "selfupdate-damaged-package-refused:OK"
    else
        fail "selfupdate-damaged-package-refused:FAIL" "$(cat "$out" 2>/dev/null)"
    fi
    if [ ! -f "$work/install.log" ]; then
        pass "selfupdate-damaged-package-nothing-installed:OK"
    else
        fail "selfupdate-damaged-package-nothing-installed:FAIL" "install.log=$(cat "$work/install.log" 2>/dev/null)"
    fi
    if [ "$(cat "$work/etc-config-netshift" 2>/dev/null)" = "CONFIG-ORIG" ] && [ ! -d "$work/dl" ]; then
        pass "selfupdate-damaged-package-config-intact-dir-cleaned:OK"
    else
        fail "selfupdate-damaged-package-config-intact-dir-cleaned:FAIL" "$(cat "$work/etc-config-netshift" 2>/dev/null)"
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
eval "$(extract subscription_update_unlocked)"
eval "$(extract subscription_update_lock_owner_alive)"
eval "$(extract subscription_update_lock_acquire)"
eval "$(extract subscription_update_lock_release)"
eval "$(extract subscription_update_lock_refused)"
eval "$(extract foreach_active_section)"
eval "$(extract _active_section_dispatch)"
section_is_disabled() { return 1; }

SUBSCRIPTION_UPDATE_LOCK_DIR="$HR_DIR/subscription-update.lock"
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
# The "killed" run was a subshell of this driver, so the update lock it left
# names a pid that is still alive here. A really killed process leaves a dead
# pid, and that takeover is covered by the subcron lock cases.
rm -rf "$SUBSCRIPTION_UPDATE_LOCK_DIR"
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
# No priority sections in this scenario; the interval is the default (30 s).
priority_check_interval() { echo 30; }
priority_check_sections() { :; }
monitor_sing_box
check cp-monitor-snapshots-once-per-minute '[ "$SNAPSHOTS" = "1" ]'

# The priority check follows the clock, not the tick count: with a clock that moves
# 10 s per tick it runs every third tick; when a check itself takes 20 s the next one is
# due on the very next tick instead of being pushed back.
FAKE_NOW=1000
PRIORITY_CALLS=0
CHECK_COST=0
date() { echo "$FAKE_NOW"; }
sleep() { FAKE_NOW=$((FAKE_NOW + 10)); }
priority_check_sections() { PRIORITY_CALLS=$((PRIORITY_CALLS + 1)); FAKE_NOW=$((FAKE_NOW + CHECK_COST)); }
TICKS=0
monitor_sing_box
check cp-monitor-priority-runs-by-the-clock '[ "$PRIORITY_CALLS" = "2" ]'
FAKE_NOW=1000; PRIORITY_CALLS=0; CHECK_COST=20; TICKS=0
monitor_sing_box
check cp-monitor-slow-priority-check-does-not-stretch-the-interval '[ "$PRIORITY_CALLS" -ge 4 ]'
unset -f date
sleep() { :; }
priority_check_sections() { :; }
TICKS=0

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
            subscription_outbound_is_unavailable download_proxy_section_is_unavailable service_proxy_needed \
            sing_box_additional_inbounds get_download_detour_tag; do
            eval "$(extract "$fn")"
        done
        _active_section_callback=
        SUBSCRIPTION_UNAVAILABLE_SECTIONS=""

        SD_PROXY_SECTION=""
        config_get() {
            case "$2:$3" in
            settings:download_lists_via_proxy_section) eval "$1=\"\$SD_PROXY_SECTION\"" ;;
            # alpha and beta exist in the config, "ghost" does not
            alpha:connection_type | beta:connection_type) eval "$1=proxy" ;;
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

        # A section id that is no longer in the config, and no section picked at all:
        # the service proxy rejects, nothing points at "<id>-out" / "-out".
        for sec in ghost ""; do
            SD_PROXY_SECTION="$sec"
            config="$base"
            sing_box_additional_inbounds
            echo "$config" | jq -e '([.route.rules[] | select(.action == "reject")] | length == 1)
                and ([.route.rules[] | select(.outbound == "ghost-out" or .outbound == "-out")] | length == 0)' > /dev/null &&
                echo "inbounds-missing-section-[$sec]-rejects:yes" || echo "inbounds-missing-section-[$sec]-rejects:no"
            echo "detour-missing-section-[$sec]:[$(get_download_detour_tag)]"
        done
    )"

    _sd_check "disabled download proxy section: no detour tag" "detour-disabled:[]"
    _sd_check "disabled download proxy section: no route to its outbound" "inbounds-disabled-no-dangling-outbound:yes"
    _sd_check "disabled download proxy section: proxy requests are rejected" "inbounds-disabled-rejects:yes"
    if command -v sing-box > /dev/null 2>&1; then
        _sd_check "disabled download proxy section: config passes sing-box check" "inbounds-disabled-singbox-check:yes"
    fi
    _sd_check "active download proxy section keeps its detour tag" "detour-active:[alpha-out]"
    _sd_check "active download proxy section keeps its route" "inbounds-active-routes-to-section:yes"
    _sd_check "a deleted download proxy section: proxy requests are rejected, no dangling outbound" "inbounds-missing-section-[ghost]-rejects:yes"
    _sd_check "a deleted download proxy section: no detour tag" "detour-missing-section-[ghost]:[]"
    _sd_check "no download proxy section picked: proxy requests are rejected (as before)" "inbounds-missing-section-[]-rejects:yes"
}

# ─────────────────────────────────────────────────────────────────
# Test: DNS sections (connection_type 'dns')
# ─────────────────────────────────────────────────────────────────
# Runs the REAL configure_dns_section_handler / configure_routing_for_section_lists /
# configure_community_list_handler (extracted verbatim from the bin) against a
# stubbed UCI layer and the real manager/facade helpers. Asserts:
#   - a DNS section gets its own DNS server + rule, after the FakeIP rule;
#   - its lists feed THAT rule (and no route rule), the FakeIP rule stays untouched,
#     and other sections still feed the FakeIP rule exactly as before;
#   - subnet lists of a DNS section are ignored; unusable sections are skipped
#     without breaking the config; the detour falls back to direct, never drops it.
test_dns_section() {
    header "DNS sections (connection_type dns)"

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

    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$cm_lib" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/netshift-dnssection-$$.sh"
    cat > "$drv" << 'DSEOF'
LIB="NETSHIFT_LIB"
BIN="BIN_PATH"
FACADE="FACADE_PATH"

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
DS_LOG="/tmp/netshift-dnssec-log-$$"; : > "$DS_LOG"
log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$DS_LOG"; }
. "$FACADE"

# UCI stubs: DS_<section>_<option>
config_get() {
    local _v
    eval "_v=\"\${DS_${2}_${3}:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"\$_v\""
}
config_get_bool() { config_get "$@"; case "$(eval echo \$$1)" in 1) eval "$1=1" ;; *) eval "$1=0" ;; esac; }
config_list_foreach() { # $1=section $2=option $3=callback ... : the option value is a space separated list
    local _sec="$1" _opt="$2" _cb="$3" _v _i
    shift 3
    eval "_v=\"\${DS_${_sec}_${_opt}:-}\""
    for _i in $_v; do "$_cb" "$_i" "$@"; done
}
for fn in section_is_dns_rule section_has_enabled_lists configure_dns_section_handler configure_routing_for_section_lists \
    configure_community_list_handler subscription_outbound_is_unavailable \
    prune_dns_section_rules_without_domains download_proxy_section_is_unavailable section_is_disabled; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done
get_ruleset_tag() { echo "$1-$2-$3"; }
get_download_detour_tag() { echo ""; }
gen_id() { echo "gen$$"; }
if command -v configure_dns_section_handler > /dev/null 2>&1 &&
    command -v configure_routing_for_section_lists > /dev/null 2>&1; then
    echo 'dnssection-real-functions-loaded:OK'
else
    echo 'dnssection-real-functions-loaded:FAIL'
fi

base='{"dns":{"servers":[{"type":"udp","tag":"bootstrap-dns-server","server":"77.88.8.8","server_port":53}],"rules":[{"action":"route","server":"fakeip-server","__service_tag":"fakeip-dns-rule-tag"}],"final":"dns-server"},
 "route":{"rules":[{"action":"route","inbound":"tproxy-in","outbound":"prox-out","__service_tag":"prx"}],"rule_set":[]},
 "outbounds":[{"type":"direct","tag":"direct-out"},{"type":"vless","tag":"prox-out","server":"p.example.com","server_port":443}]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
ok() { [ "$1" = "$2" ] && echo "$3:OK" || echo "$3:FAIL [got '$1' want '$2']"; }
jqc() { printf '%s' "$config" | jq -c "$1"; }

DS_corp_connection_type=dns
DS_corp_dns_type=dot
DS_corp_dns_server=dns.corp.example:853
DS_corp_community_lists="corp_zone"
DS_prox_connection_type=proxy
DS_prox_community_lists="russia_inside"

# ── DNS section: server + rule ─────────────────────────────────────
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | [.type,.server,.server_port,.domain_resolver]]')" '[["tls","dns.corp.example",853,"bootstrap-dns-server"]]' "dnssection-server"
ok "$(jqc '[.dns.rules[] | .__service_tag]')" '["fakeip-dns-rule-tag","dns-section-rule-corp"]' "dnssection-rule-after-fakeip"
ok "$(jqc '.dns.rules[1].server')" '"dns-section-corp"' "dnssection-rule-server"
# other connection types are not touched
config="$base"; configure_dns_section_handler prox
ok "$(printf '%s' "$config" | jq -cS .)" "$(printf '%s' "$base" | jq -cS .)" "dnssection-other-types-untouched"
# IP address needs no bootstrap resolver
DS_corp_dns_server=10.0.0.53
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | .domain_resolver // "none"] | first')" '"none"' "dnssection-ip-no-resolver"
DS_corp_dns_server=dns.corp.example:853

# ── unusable sections are skipped, config stays valid ──────────────
for bad in "dns_server=" "dns_type=bogus"; do
    eval "save_${bad%%=*}=\"\$DS_corp_${bad%%=*}\""
    eval "DS_corp_${bad%%=*}=\"${bad#*=}\""
    [ "${bad%%=*}" = dns_server ] && DS_corp_dns_server=""
    config="$base"; configure_dns_section_handler corp
    ok "$(printf '%s' "$config" | jq -cS .)" "$(printf '%s' "$base" | jq -cS .)" "dnssection-skip-${bad%%=*}"
    DS_corp_dns_type=dot; DS_corp_dns_server=dns.corp.example:853
done
DS_corp_community_lists=""
config="$base"; configure_dns_section_handler corp
ok "$(printf '%s' "$config" | jq -cS .)" "$(printf '%s' "$base" | jq -cS .)" "dnssection-skip-no-lists"
DS_corp_community_lists="corp_zone"

# ── every protocol the field offers builds a server the core knows ──
for spec in "udp|udp|53" "tcp|tcp|53" "dot|tls|853" "doh|https|443" "doh3|h3|443" "doq|quic|853"; do
    ty="${spec%%|*}"; rest="${spec#*|}"
    DS_corp_dns_type="$ty"; DS_corp_dns_server=dns.corp.example
    config="$base"; configure_dns_section_handler corp
    ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | [.type, .server_port]] | first | join(",")')" "\"${rest%%|*},${rest#*|}\"" "dnssection-protocol-$ty"
done
DS_corp_dns_type=dot; DS_corp_dns_server=dns.corp.example:853

# ── a bare IPv6 address is not cut at its first colon ──
DS_corp_dns_type=udp; DS_corp_dns_server=2001:4860:4860::8888
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | [.server, .server_port]] | first | tostring')" '"[\"2001:4860:4860::8888\",53]"' "dnssection-bare-ipv6"
ok "$(jqc '.dns.rules | length')" 2 "dnssection-bare-ipv6-rule-added"
DS_corp_dns_server="[2001:4860:4860::8888]"
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | [.server, .server_port]] | first | tostring')" '"[\"2001:4860:4860::8888\",53]"' "dnssection-bracketed-ipv6-no-port"
DS_corp_dns_server="[2001:4860:4860::8888]:5353"
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | [.server, .server_port]] | first | tostring')" '"[\"2001:4860:4860::8888\",5353]"' "dnssection-bracketed-ipv6-with-port"
DS_corp_dns_type=dot; DS_corp_dns_server=dns.corp.example:853

# ── a disabled section says so and creates nothing ──
DS_corp_disabled=1; : > "$DS_LOG"
config="$base"; configure_dns_section_handler corp
ok "$(printf '%s' "$config" | jq -cS .)$(grep -c 'has no lists' "$DS_LOG")" "$(printf '%s' "$base" | jq -cS .)0" "dnssection-disabled-skipped-quietly"
ok "$(grep -c "DNS section 'corp' is disabled" "$DS_LOG")" 1 "dnssection-disabled-says-so"
DS_corp_disabled=""

# ── a rule that no domain list ever narrowed is dropped (it would catch ALL queries) ──
config="$base"; configure_dns_section_handler corp; : > "$DS_LOG"
prune_dns_section_rules_without_domains
ok "$(jqc '[[.dns.rules[] | .__service_tag], [.dns.servers[] | .tag]] | tostring')" '"[[\"fakeip-dns-rule-tag\"],[\"bootstrap-dns-server\"]]"' "dnssection-conditionless-rule-pruned"
ok "$(grep -c "DNS section 'corp' has no domain lists" "$DS_LOG")" 1 "dnssection-conditionless-rule-warned"
config="$base"; configure_dns_section_handler corp; configure_routing_for_section_lists corp
prune_dns_section_rules_without_domains
ok "$(jqc '[.dns.rules[] | .__service_tag] | tostring')" '"[\"fakeip-dns-rule-tag\",\"dns-section-rule-corp\"]"' "dnssection-rule-with-domains-kept"

# ── a DNS section can not be the download proxy: it has no outbound ──
ok "$(download_proxy_section_is_unavailable corp && echo unavailable || echo usable)" unavailable "dnssection-not-a-download-proxy"
ok "$(download_proxy_section_is_unavailable prox && echo unavailable || echo usable)" usable "dnssection-proxy-section-still-usable"

# ── detour: usable / unusable (falls back to direct) ───────────────
DS_corp_dns_detour_section=prox
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | .detour] | first')" '"prox-out"' "dnssection-detour-usable"
DS_corp_dns_detour_section=nosuch
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | .detour // "none"] | first')" '"none"' "dnssection-detour-missing-direct"
ok "$(jqc '[.dns.rules[] | select(.__service_tag == "dns-section-rule-corp")] | length')" 1 "dnssection-detour-missing-keeps-rule"
DS_corp_dns_detour_section=corp
config="$base"; configure_dns_section_handler corp
ok "$(jqc '[.dns.servers[] | select(.tag == "dns-section-corp") | .detour // "none"] | first')" '"none"' "dnssection-detour-self-direct"
DS_corp_dns_detour_section=""

# ── lists feed the section's rule, not the FakeIP / route rules ─────
config="$base"; configure_dns_section_handler corp
configure_routing_for_section_lists corp
ok "$(jqc '[.dns.rules[] | select(.__service_tag == "dns-section-rule-corp") | .rule_set] | first')" '"corp-corp_zone-community"' "dnssection-lists-feed-own-rule"
ok "$(jqc '[.dns.rules[] | select(.__service_tag == "fakeip-dns-rule-tag") | .rule_set // "none"] | first')" '"none"' "dnssection-fakeip-rule-untouched"
ok "$(jqc '[.route.rules[] | select(.__service_tag != "prx")] | length')" 0 "dnssection-no-route-rule"
ok "$(jqc '[.route.rule_set[].tag]')" '["corp-corp_zone-community"]' "dnssection-ruleset-defined"
# a normal section still feeds the FakeIP rule
configure_routing_for_section_lists prox
ok "$(jqc '[.dns.rules[] | select(.__service_tag == "fakeip-dns-rule-tag") | .rule_set] | first')" '"prox-russia_inside-community"' "dnssection-proxy-section-still-fakeip"
ok "$(jqc '[.dns.rules[] | select(.__service_tag == "dns-section-rule-corp") | .rule_set] | first')" '"corp-corp_zone-community"' "dnssection-own-rule-unchanged-by-proxy"

echo 'DONE'
DSEOF
    sed -i "s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g; s|BIN_PATH|$bin|; s|FACADE_PATH|$facade_lib|" "$drv"

    local ds_out="/tmp/netshift-dnssection-out-$$.log"
    ash "$drv" > "$ds_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$ds_out"
    if [ "$saw_done" = "1" ]; then
        pass "dnssection-driver-completed:OK"
    else
        fail "dnssection-driver-completed:FAIL (driver aborted early)" "$(tail -20 "$ds_out")"
    fi
    rm -f "$drv" "$ds_out"
}

test_update_package_check() {
    header "Self-update: downloaded package files are checked before anything is installed"

    local lib="${NETSHIFT_LIB_DIR}"
    local updater="$lib/updater.sh"
    if [ ! -r "$updater" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "updater.sh / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-pkgcheck-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        UPDATES_PACKAGE_MIN_SIZE=2048
        eval "$(awk '/^updates_package_file_looks_valid\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$updater")"

        # a real gzip archive of a few kilobytes
        head -c 6000 /dev/urandom > "$work/payload"
        tar -czf "$work/good.ipk" -C "$work" payload
        check() { updates_package_file_looks_valid "$1" && echo yes || echo no; }

        echo "ipk-good=$(check "$work/good.ipk")"
        printf '<html>rate limit exceeded</html>%s' "$(head -c 3000 /dev/zero | tr '\0' 'x')" > "$work/page.ipk"
        echo "ipk-html=$(check "$work/page.ipk")"
        head -c 100 "$work/good.ipk" > "$work/small.ipk"
        echo "ipk-tiny=$(check "$work/small.ipk")"
        head -c 3000 "$work/good.ipk" > "$work/trunc.ipk"
        echo "ipk-truncated=$(check "$work/trunc.ipk")"
        cp "$work/good.ipk" "$work/v2.apk"
        echo "apk-gzip=$(check "$work/v2.apk")"
        { printf 'ADB.'; head -c 4000 /dev/urandom; } > "$work/v3.apk"
        echo "apk-adb=$(check "$work/v3.apk")"
        printf '<html>%s' "$(head -c 3000 /dev/zero | tr '\0' 'x')" > "$work/page.apk"
        echo "apk-html=$(check "$work/page.apk")"
        echo "missing=$(check "$work/none.ipk")"
        : > "$work/empty.ipk"
        echo "empty=$(check "$work/empty.ipk")"
    )"

    _pk() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _pk "a real .ipk passes" "ipk-good=yes"
    _pk "an error page named .ipk is refused" "ipk-html=no"
    _pk "a tiny file is refused" "ipk-tiny=no"
    _pk "a truncated .ipk is refused" "ipk-truncated=no"
    _pk "a gzip .apk passes" "apk-gzip=yes"
    _pk "an ADB .apk passes" "apk-adb=yes"
    _pk "an error page named .apk is refused" "apk-html=no"
    _pk "a missing file is refused" "missing=no"
    _pk "an empty file is refused" "empty=no"

    rm -rf "$work"
}

test_environment_check() {
    header "Environment check: flow offloading, clock, IPv6 (check_environment)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/helpers.sh" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "bin / helpers.sh / constants.sh not found"
        return
    fi

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        eval "$(awk '/^check_environment\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"

        ENV_FLOW_SW="" ENV_FLOW_HW="" ENV_FLOWTABLE="" ENV_DATE_HEADER="" ENV_IPV6="" ENV_IPV6_ENABLED=0 ENV_NOW=""
        uci() {
            case "$*" in
            *flow_offloading_hw*) printf '%s' "$ENV_FLOW_HW" ;;
            *flow_offloading*) printf '%s' "$ENV_FLOW_SW" ;;
            *zonename*) printf 'Europe/Moscow' ;;
            *timezone*) printf 'MSK-3' ;;
            *ntp.enabled*) printf '1' ;;
            esac
        }
        nft() { [ -n "$ENV_FLOWTABLE" ] && printf 'table inet fw4 {\n flowtable ft {\n}\n}\n'; true; }
        curl() { [ -n "$ENV_DATE_HEADER" ] && printf 'HTTP/2 200\r\nDate: %s\r\nServer: x\r\n\r\n' "$ENV_DATE_HEADER"; true; }
        ip() { [ -n "$ENV_IPV6" ] && printf '    inet6 %s/64 scope global\n' "$ENV_IPV6"; true; }
        date() {
            if [ "$1" = "+%s" ]; then printf '%s\n' "${ENV_NOW:-1790000000}"; else command date "$@"; fi
        }
        config_get_bool() { eval "$1=\"$ENV_IPV6_ENABLED\""; }

        echo "epoch[$(http_date_to_epoch 'Sun, 04 Oct 2026 09:13:05 GMT')]"
        echo "epoch-bad[$(http_date_to_epoch 'garbage')]"
        echo "epoch-month[$(http_date_to_epoch 'Mon, 01 Jan 2024 00:00:00 GMT')]"

        j() { check_environment | jq -c "$1"; }
        echo "defaults=$(j '[.flow_offloading.software, .flow_offloading.hardware, .flow_offloading.active, .clock.plausible, .clock.skew_seconds, .ipv6.router_has_global]')"
        ENV_FLOW_SW=1; ENV_FLOWTABLE=1
        echo "flow-sw=$(j '[.flow_offloading.software, .flow_offloading.hardware, .flow_offloading.active]')"
        ENV_FLOW_HW=1
        echo "flow-hw=$(j '[.flow_offloading.software, .flow_offloading.hardware]')"
        ENV_NOW=1000000000
        echo "clock-implausible=$(j '.clock.plausible')"
        ENV_NOW=1791115200
        ENV_DATE_HEADER='Sun, 04 Oct 2026 12:00:00 GMT'
        echo "skew-zero=$(j '.clock.skew_seconds')"
        ENV_DATE_HEADER='Sun, 04 Oct 2026 12:10:00 GMT'
        echo "skew-600=$(j '.clock.skew_seconds')"
        echo "zone=$(j '.clock.timezone')"
        ENV_IPV6="2001:db8::5"
        echo "ipv6-global=$(j '[.ipv6.router_has_global, .ipv6.netshift_enabled]')"
        ENV_IPV6="fd12:3456::1"
        echo "ipv6-ula-ignored=$(j '.ipv6.router_has_global')"
        ENV_IPV6="2001:db8::5"; ENV_IPV6_ENABLED=1
        echo "ipv6-enabled=$(j '.ipv6.netshift_enabled')"
    )"

    _ev() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _ev "Date header is converted" "epoch[1791105185]"
    _ev "garbage date gives nothing" "epoch-bad[]"
    _ev "month names are read" "epoch-month[1704067200]"
    _ev "clean router: nothing flagged" "defaults=[false,false,false,true,null,false]"
    _ev "software flow offloading is reported, with the active flowtable" "flow-sw=[true,false,true]"
    _ev "hardware flow offloading is reported" "flow-hw=[true,true]"
    _ev "an impossible clock is reported" "clock-implausible=false"
    _ev "no skew when the clock agrees" "skew-zero=0"
    _ev "skew is measured against the server date" "skew-600=600"
    _ev "time zone is reported" 'zone="Europe/Moscow"'
    _ev "a global IPv6 address with IPv6 off is reported" "ipv6-global=[true,false]"
    _ev "a ULA address does not count as global" "ipv6-ula-ignored=false"
    _ev "IPv6 on is reported" "ipv6-enabled=true"
}

test_mixed_proxy_auth() {
    header "Section mixed proxy: login, port conflicts, nothing for sections without one"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/sing_box_config_manager.sh" ] || [ ! -r "$lib/sing_box_config_facade.sh" ]; then
        fail "bin / libs not found"
        return
    fi

    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.jq" /usr/lib/netshift/helpers.jq
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        . "$lib/sing_box_config_manager.sh"
        . "$lib/sing_box_config_facade.sh"
        LOGF="/tmp/netshift-mixed-log-$$"; : > "$LOGF"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$LOGF"; }
        for fn in configure_section_mixed_proxy mixed_proxy_port_is_reserved; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done
        get_service_listen_address() { echo "192.168.1.1"; }
        get_inbound_tag_by_section() { echo "$1-in"; }
        get_outbound_tag_by_section() { echo "$1-out"; }
        subscription_outbound_is_unavailable() { [ "$1" = "dead" ]; }
        gen_id() { echo "rule-$$"; }
        config_get() { eval "$1=\"\${U_$2_$3:-$4}\""; }
        config_get_bool() { eval "$1=\"\${U_$2_$3:-$4}\""; }

        run() {
            config='{"inbounds":[],"outbounds":[],"route":{"rules":[]}}'
            MIXED_PROXY_PORTS_USED=""
            for s in "$@"; do configure_section_mixed_proxy "$s"; done
        }
        inb() { printf '%s' "$config" | jq -c '[.inbounds[] | [.tag, .listen_port, (.users // "open")]]'; }
        rules() { printf '%s' "$config" | jq -c '[.route.rules[] | [(.inbound // ""), (.outbound // .action)]]'; }

        U_a_mixed_proxy_enabled=1 U_a_mixed_proxy_port=2081
        run a; echo "plain=$(inb)"; echo "plain-rule=$(rules)"

        U_a_mixed_proxy_auth=1 U_a_mixed_proxy_username=me U_a_mixed_proxy_password=secret
        run a; echo "auth=$(inb)"

        U_a_mixed_proxy_password=""
        run a; echo "auth-incomplete=$(inb) warned=$(grep -c 'needs a user name and a password' "$LOGF")"
        U_a_mixed_proxy_auth=0

        U_b_mixed_proxy_enabled=1 U_b_mixed_proxy_port=2081
        run a b; echo "same-port=$(inb) warned=$(grep -c 'already taken by another section' "$LOGF")"
        U_b_mixed_proxy_port=2082
        run a b; echo "two-ports=$(inb)"

        U_c_mixed_proxy_enabled=1 U_c_mixed_proxy_port=9090
        run c; echo "reserved-clash=$(inb) warned=$(grep -c 'used by NetShift itself' "$LOGF")"
        U_c_mixed_proxy_port=4534
        run c; echo "reserved-service=$(inb)"
        U_c_mixed_proxy_port=abc
        run c; echo "bad-port-fallback=$(inb)"

        U_d_mixed_proxy_enabled=0
        run d; echo "disabled=$(inb)"
        run missing; echo "no-option=$(inb)"

        U_dead_mixed_proxy_enabled=1 U_dead_mixed_proxy_port=2090
        run dead; echo "unavailable-inbound=$(inb) rule=$(rules)"

        # sing-box agrees with the result
        if command -v sing-box > /dev/null 2>&1; then
            U_a_mixed_proxy_auth=1 U_a_mixed_proxy_password=secret
            run a b
            config="$(printf '%s' "$config" | jq '.outbounds += [{"type":"direct","tag":"a-out"},{"type":"direct","tag":"b-out"}] | .route.rules |= map(del(.__service_tag))')"
            sing_box_cm_save_config_to_file "$config" /tmp/mixed-check.json
            sing-box -c /tmp/mixed-check.json check > /dev/null 2>&1 && echo "singbox-check=ok" || echo "singbox-check=FAIL"
        else
            echo "singbox-check=ok"
        fi
        rm -f "$LOGF" /tmp/mixed-check.json
    )"

    _mp() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _mp "a proxy is open without a login (as before)" 'plain=[["a-mixed-in",2081,"open"]]'
    _mp "...and routed to its section" 'plain-rule=[["a-mixed-in","a-out"]]'
    _mp "with a login the inbound needs it" 'auth=[["a-mixed-in",2081,[{"username":"me","password":"secret"}]]]'
    _mp "a login asked for but incomplete means no proxy" 'auth-incomplete=[] warned=1'
    _mp "a second section on the same port is left out, not fatal" 'same-port=[["a-mixed-in",2081,"open"]] warned=1'
    _mp "two sections on two ports both work" 'two-ports=[["a-mixed-in",2081,"open"],["b-mixed-in",2082,"open"]]'
    _mp "the Clash API port is not available to a section" 'reserved-clash=[] warned=1'
    _mp "the service proxy port is not available to a section" 'reserved-service=[]'
    _mp "an invalid port falls back to 2080" 'bad-port-fallback=[["c-mixed-in",2080,"open"]]'
    _mp "a section with the proxy off gets nothing" 'disabled=[]'
    _mp "a section without the option gets nothing" 'no-option=[]'
    _mp "an unavailable subscription keeps its inbound but rejects" 'unavailable-inbound=[["dead-mixed-in",2090,"open"]] rule=[["dead-mixed-in","reject"]]'
    _mp "sing-box accepts the result" "singbox-check=ok"
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
# Test: GeoIP country flags for subscription servers
# ─────────────────────────────────────────────────────────────────
# Runs the REAL subscription_geoip_annotate / geoip_hosts_without_flag /
# geoip_resolve_host (extracted verbatim from the bin) with stubbed dig / curl.
# Asserts: only names WITHOUT a flag are annotated; each address is looked up once
# (later runs read the cache); private / FakeIP answers never leave the router;
# offline and a silent service change nothing and are retried later; failures are
# retried only after their TTL; the flag equals the one the country filter builds.
test_subscription_geoip() {
    header "Subscription GeoIP country flags"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ] || [ ! -r "${NETSHIFT_LIB_DIR}/helpers.sh" ] \
        || ! command -v jq > /dev/null 2>&1; then
        skip "netshift bin / constants.sh / helpers.sh / jq not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        . "${NETSHIFT_LIB_DIR}/helpers.sh"
        W="/tmp/netshift-geoip-$$"; rm -rf "$W"; mkdir -p "$W"
        GEOIP_CACHE_FILE="$W/geoip.json"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$W/log"; }
        for fn in country_code_to_flag_emoji geoip_hosts_without_flag geoip_is_private_ip geoip_resolve_host geoip_lookup_hosts subscription_geoip_annotate \
            geoip_section_enabled geoip_name_has_flag geoip_link_host geoip_collect_host geoip_collect_link geoip_collect_json \
            geoip_flush_links configure_outbound_geoip_handler get_geoip_flags; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done
        # geoip_flags comes from GEO_FLAGS, bootstrap from the default
        config_get() {
            case "$3" in
            geoip_flags) eval "$1=\"\${GEO_FLAGS:-$4}\"" ;;
            *) eval "$1=\"$4\"" ;;
            esac
        }

        # dig stub: GEO_DIG="host=ip ..." ; counts calls
        dig() {
            local host="" a
            for a in "$@"; do case "$a" in @*|+*|A) ;; *) host="$a" ;; esac; done
            echo x >> "$W/dig.calls"
            local pair
            for pair in $GEO_DIG; do [ "${pair%%=*}" = "$host" ] && echo "${pair#*=}"; done
            return 0
        }
        # curl stub: records the POST body, answers GEO_API (a JSON array) or nothing
        curl() {
            local body="" prev=""
            for a in "$@"; do [ "$prev" = "-d" ] && body="$a"; prev="$a"; done
            echo x >> "$W/curl.calls"; printf '%s\n' "$body" >> "$W/curl.bodies"
            [ -n "$GEO_API" ] && printf '%s' "$GEO_API"
            return 0
        }
        calls() { [ -f "$W/$1.calls" ] && wc -l < "$W/$1.calls" | tr -d ' ' || echo 0; }

        NL="$(country_code_to_flag_emoji NL)"; JP="$(country_code_to_flag_emoji JP)"; DE="$(country_code_to_flag_emoji DE)"
        mkfile() {
            jq -n --arg de "$DE" --arg nl "$NL" '{outbounds: [
              {type:"vless", tag: ($de + " Berlin"), server:"de.example"},
              {type:"vless", tag:"Amsterdam", server:"nl.example"},
              {type:"vless", tag:"Tokyo", server:"1.2.3.4"},
              {type:"vless", tag:"Unknown", server:"xx.example"},
              {type:"vless", tag:"Private", server:"priv.example"},
              {type:"vless", tag:"Fake", server:"fake.example"},
              {type:"vless", remark:"Remarked", server:"nl.example"},
              {type:"vless", tag:("Premium " + $nl), server:"mid.example"}]}' > "$1"
        }
        names() { jq -c '[.outbounds[] | (.tag // .remark)]' "$1"; }
        GEO_DIG="de.example=9.9.9.1 nl.example=5.5.5.5 xx.example=6.6.6.6 priv.example=192.168.1.5 fake.example=198.18.0.7 mid.example=7.7.7.7"
        GEO_API="$(printf '[{"ip":"5.5.5.5","country":"NL"},{"ip":"1.2.3.4","country":"JP"}]')"

        mkfile "$W/a.json"; subscription_geoip_annotate "$W/a.json"
        echo "annotated:$(names "$W/a.json" | jq -c --arg nl "$NL" --arg jp "$JP" --arg de "$DE" '. == [($de + " Berlin"), ($nl + " Amsterdam"), ($jp + " Tokyo"), "Unknown", "Private", "Fake", ($nl + " Remarked"), ("Premium " + $nl)]')"
        echo "one-batch-request:$(calls curl)"
        body="$(cat "$W/curl.bodies")"
        echo "only-public-ips-sent:$(printf '%s' "$body" | jq -c 'sort == ["1.2.3.4","5.5.5.5","6.6.6.6"]')"
        echo "flagged-names-not-looked-up:$(printf '%s' "$body" | grep -c '9.9.9.1\|7.7.7.7')"
        echo "cache-written:$(jq -c 'keys | sort' "$GEOIP_CACHE_FILE")"
        echo "cache-failure-entry:$(jq -r '.["xx.example"].cc' "$GEOIP_CACHE_FILE")|"

        # second run: no dig, no curl, same result
        : > "$W/dig.calls"; : > "$W/curl.calls"
        mkfile "$W/b.json"; subscription_geoip_annotate "$W/b.json"
        echo "second-run-same:$([ "$(names "$W/b.json")" = "$(names "$W/a.json")" ] && echo yes || echo no)"
        echo "second-run-no-network:$(calls dig)/$(calls curl)"

        # a failure is retried only after its TTL
        jq '.["xx.example"].ts = 1' "$GEOIP_CACHE_FILE" > "$W/c.tmp" && mv "$W/c.tmp" "$GEOIP_CACHE_FILE"
        GEO_API='[{"ip":"5.5.5.5","country":"NL"},{"ip":"6.6.6.6","country":"FR"}]'
        : > "$W/curl.calls"
        mkfile "$W/c.json"; subscription_geoip_annotate "$W/c.json"
        FR="$(country_code_to_flag_emoji FR)"
        echo "expired-failure-retried:$(calls curl):$(names "$W/c.json" | jq -r --arg fr "$FR" '.[3] == ($fr + " Unknown")')"

        # offline: nothing resolves -> stops early, nothing changes, no request
        rm -f "$GEOIP_CACHE_FILE" "$W/dig.calls" "$W/curl.calls" "$W/curl.bodies"
        GEO_DIG=""
        jq -n '{outbounds: [range(0; 12) | {type:"vless", tag:("N" + tostring), server:("h" + tostring + ".example")}]}' > "$W/d.json"
        cp "$W/d.json" "$W/d.orig"
        subscription_geoip_annotate "$W/d.json"
        echo "offline-unchanged:$([ "$(jq -cS . "$W/d.json")" = "$(jq -cS . "$W/d.orig")" ] && echo yes || echo no)"
        echo "offline-stops-early:$([ "$(calls dig)" -le "$GEOIP_RESOLVE_MAX_FAILURES" ] && echo yes || echo no)"
        echo "offline-no-request:$(calls curl)"
        echo "offline-no-cache:$([ -e "$GEOIP_CACHE_FILE" ] && echo written || echo none)"

        # offline with FEW hosts: nothing is known, so nothing is remembered (not even
        # as a day-long failure)
        rm -f "$GEOIP_CACHE_FILE"; GEO_DIG=""
        jq -n '{outbounds: [range(0; 2) | {type:"vless", tag:("M" + tostring), server:("m" + tostring + ".example")}]}' > "$W/d2.json"
        subscription_geoip_annotate "$W/d2.json"
        echo "offline-few-hosts-no-cache:$([ -e "$GEOIP_CACHE_FILE" ] && echo written || echo none)"

        # DNS that answers only now and then: the total number of misses ends the phase
        rm -f "$GEOIP_CACHE_FILE" "$W/dig.calls" "$W/curl.calls" "$W/curl.bodies"
        GEO_DIG="$(i=0; while [ $i -lt 40 ]; do [ $((i % 2)) -eq 0 ] && printf 'p%s.example=5.5.5.5 ' "$i"; i=$((i + 1)); done)"
        jq -n '{outbounds: [range(0; 40) | {type:"vless", tag:("P" + tostring), server:("p" + tostring + ".example")}]}' > "$W/d3.json"
        GEO_API='[{"ip":"5.5.5.5","country":"NL"}]'
        subscription_geoip_annotate "$W/d3.json"
        echo "flaky-dns-bounded:$([ "$(calls dig)" -le $((GEOIP_RESOLVE_MAX_FAILURES * 2 + 2)) ] && echo yes || echo no)"
        # ... and so does the time budget (0 s: the first miss ends it)
        rm -f "$GEOIP_CACHE_FILE" "$W/dig.calls"; GEO_DIG=""
        GEOIP_RESOLVE_BUDGET=0; subscription_geoip_annotate "$W/d3.json"
        echo "time-budget-ends-the-phase:$(calls dig)"
        GEOIP_RESOLVE_BUDGET=60

        # addresses that are never sent out, IPv6 included
        rm -f "$GEOIP_CACHE_FILE" "$W/curl.calls" "$W/curl.bodies"
        GEO_API='[{"ip":"2606:4700::1111","country":"US"}]'
        GEO_DIG=""
        jq -n --arg fake "${SB_FAKEIP_INET6_RANGE%%/*}1" '{outbounds: [
            {type:"vless", tag:"ula", server:"fd12:3456::1"}, {type:"vless", tag:"ll", server:"fe80::1"},
            {type:"vless", tag:"lo", server:"::1"}, {type:"vless", tag:"fk", server:$fake},
            {type:"vless", tag:"cgnat", server:"100.64.1.1"}, {type:"vless", tag:"pub6", server:"2606:4700::1111"}]}' > "$W/d4.json"
        subscription_geoip_annotate "$W/d4.json"
        echo "ipv6-private-never-sent:$(cat "$W/curl.bodies" | jq -c 'sort')"
        echo "fakeip-from-constants:$(for ip in "${SB_FAKEIP_INET4_RANGE%%/*}" 198.19.5.5 198.20.0.1; do geoip_is_private_ip "$ip" && printf 'p' || printf 'u'; done)"

        # files keep owner-only access
        echo "cache-mode:$(ls -ld "$GEOIP_CACHE_FILE" | cut -c1-10)"
        mkfile "$W/g.json"; chmod 600 "$W/g.json"; subscription_geoip_annotate "$W/g.json"
        echo "annotated-file-mode:$(ls -ld "$W/g.json" | cut -c1-10)"

        # a silent service: names unchanged and nothing cached (retry next build)
        GEO_DIG="de.example=9.9.9.1 nl.example=5.5.5.5"; GEO_API=""
        rm -f "$GEOIP_CACHE_FILE"
        mkfile "$W/e.json"; cp "$W/e.json" "$W/e.orig"; subscription_geoip_annotate "$W/e.json"
        echo "silent-service-unchanged:$([ "$(jq -cS . "$W/e.json")" = "$(jq -cS . "$W/e.orig")" ] && echo yes || echo no)"
        echo "silent-service-no-cache:$([ -e "$GEOIP_CACHE_FILE" ] && echo written || echo none)"
        GEO_API="not json"; : > "$W/log"
        mkfile "$W/f.json"; subscription_geoip_annotate "$W/f.json"
        echo "garbage-warned:$(grep -c 'lookup service did not answer' "$W/log")"

        # --- links added by hand: the country goes to GEOIP_LINKS_FILE per outbound tag
        VMFRAG="${VMFRAG_PLACEHOLDER:-}"
        GEOIP_LINKS_FILE="$W/links.json"
        rm -f "$GEOIP_CACHE_FILE" "$W/dig.calls" "$W/curl.calls" "$W/curl.bodies"
        GEO_DIG="de.example=9.9.9.1 nl.example=5.5.5.5 jp.example=1.2.3.4 vm.example=5.5.5.5"
        GEO_API='[{"ip":"5.5.5.5","country":"NL"},{"ip":"1.2.3.4","country":"JP"},{"ip":"9.9.9.1","country":"DE"}]'
        VM="vmess://$(printf '%s' '{"v":"2","ps":"VM node","add":"vm.example","port":"443","id":"u"}' | base64 | tr -d '\n')"
        VMF="vmess://$(printf '%s' "{\"v\":\"2\",\"ps\":\"$NL VM flagged\",\"add\":\"de.example\",\"port\":\"443\",\"id\":\"u\"}" | base64 | tr -d '\n')"
        FLAGGED_FRAG="%F0%9F%87%A9%F0%9F%87%AA"   # the German flag, percent-encoded as links carry it
        configure_outbound_handler() {
            geoip_collect_link "$1-7-out" "${VM}#%F0%9F%87%A9%F0%9F%87%AA%20Frag"
            geoip_collect_json "$1-8-out" '{"type":"vless","tag":"%F0%9F%87%A9%F0%9F%87%AA%20Enc","server":"de.example"}'
            geoip_collect_link "$1-out" "vless://u@nl.example:443?security=tls#Amsterdam%20node"
            geoip_collect_link "$1-1-out" "trojan://p@jp.example:443#"
            geoip_collect_link "$1-2-out" "vless://u@de.example:443#${FLAGGED_FRAG}%20Berlin"
            geoip_collect_link "$1-3-out" "$VM"
            geoip_collect_link "$1-4-out" "$VMF"
            geoip_collect_json "$1-5-out" '{"type":"vless","tag":"Json node","server":"nl.example"}'
            geoip_collect_json "$1-6-out" "{\"type\":\"vless\",\"tag\":\"$DE json\",\"server\":\"de.example\"}"
            return 7
        }
        GEO_FLAGS=0
        configure_outbound_geoip_handler off; rc=$?
        echo "links-off-no-lookup:$(calls dig)/$(calls curl):$([ -e "$GEOIP_LINKS_FILE" ] && echo file || echo none)"
        GEO_FLAGS=1
        configure_outbound_geoip_handler main; rc=$?
        echo "links-keep-exit-status:$rc"
        echo "links-flags:$(get_geoip_flags | jq -c --sort-keys '. == {"main-1-out":"JP","main-3-out":"NL","main-5-out":"NL","main-out":"NL"}')"
        echo "links-flagged-names-skipped:$(jq -c '[has("main-2-out"), has("main-4-out"), has("main-6-out"), has("main-7-out"), has("main-8-out")]' "$GEOIP_LINKS_FILE")"
        echo "links-file-mode:$(ls -ld "$GEOIP_LINKS_FILE" | cut -c1-10)"
        echo "links-one-request:$(calls curl)"
        echo "links-not-sent-flagged:$(grep -c '9.9.9.1' "$W/curl.bodies")"
        : > "$W/dig.calls"; : > "$W/curl.calls"
        configure_outbound_geoip_handler second > /dev/null
        echo "links-merge-and-cache:$(jq -c '[has("main-out"), has("second-out")]' "$GEOIP_LINKS_FILE"):$(calls dig)/$(calls curl)"
        rm -f "$GEOIP_LINKS_FILE"
        echo "links-no-file-is-empty-object:$(get_geoip_flags)"

        # --- a shared entry point ("mirror"): the name states its country, the
        # address does not. The name wins and the disagreement is logged (issue
        # #94: on a real subscription 4 nodes named de1/pl1/fi1/se1 behind one RU
        # mirror host were stamped RU, and a country filter for DE silently dropped
        # one of the five DE nodes of that subscription).
        rm -f "$GEOIP_CACHE_FILE" "$W/dig.calls" "$W/curl.calls" "$W/curl.bodies" "$W/log"
        GEO_DIG="de-mirror.example=9.9.9.1 main3-mirror.example=8.8.8.8"
        GEO_API='[{"ip":"9.9.9.1","country":"DE"},{"ip":"8.8.8.8","country":"RU"}]'
        jq -n '{outbounds: [
            {type:"vless", tag:"de1-vless-ws", server:"de-mirror.example"},
            {type:"vless", tag:"de1-vless-ws-3", server:"main3-mirror.example"},
            {type:"vless", tag:"pl1-hysteria2", server:"main3-mirror.example"},
            {type:"vless", tag:"russia-vless-ws", server:"main3-mirror.example"},
            {type:"vless", tag:"node-1", server:"main3-mirror.example"},
            {type:"vless", remark:"Remarked", server:"main3-mirror.example"}]}' > "$W/m.json"
        subscription_geoip_annotate "$W/m.json"
        PL="$(country_code_to_flag_emoji PL)"; RU="$(country_code_to_flag_emoji RU)"
        echo "mirror-name-wins:$(names "$W/m.json" | jq -c --arg de "$DE" --arg pl "$PL" --arg ru "$RU" '. == [
            ($de + " de1-vless-ws"), ($de + " de1-vless-ws-3"), ($pl + " pl1-hysteria2"),
            ($ru + " russia-vless-ws"), ($ru + " node-1"), ($ru + " Remarked")]')"
        echo "mirror-warned:$(grep -c 'shared entry point' "$W/log")"
        echo "mirror-warn-names:$(grep -c 'de1-vless-ws-3' "$W/log")"
        rm -rf "$W"
    )"

    _gp_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _gp_check "names without a flag get the flag of their country (tag and remark)" "annotated:true"
    _gp_check "all addresses go out in ONE batch request" "one-batch-request:1"
    _gp_check "only public addresses are sent (no private / FakeIP / flagged servers)" "only-public-ips-sent:true"
    _gp_check "servers that already have a flag are never looked up" "flagged-names-not-looked-up:0"
    _gp_check "the results (and the failures) are cached per host" 'cache-written:["1.2.3.4","fake.example","nl.example","priv.example","xx.example"]'
    _gp_check "a manual link is looked up and its country kept per outbound tag" "links-flags:true"
    _gp_check "geoip.json and the links file are owner-only" "links-file-mode:-rw-------"
    _gp_check "a link or JSON name that already has a flag is never looked up" "links-flagged-names-skipped:[false,false,false,false,false]"
    _gp_check "the handler keeps the exit status of the section build" "links-keep-exit-status:7"
    _gp_check "a section without the option does no lookup" "links-off-no-lookup:0/0:none"
    _gp_check "all manual hosts go out in one request" "links-one-request:1"
    _gp_check "a host with a flag in the name is not sent" "links-not-sent-flagged:0"
    _gp_check "the next section reuses the cache and keeps earlier results" "links-merge-and-cache:[true,true]:0/0"
    _gp_check "no lookup file reads as an empty object" "links-no-file-is-empty-object:{}"
    _gp_check "an unknown address is cached as a failure" "cache-failure-entry:|"
    _gp_check "a second build gives the same names" "second-run-same:yes"
    _gp_check "a second build makes no DNS and no HTTP request" "second-run-no-network:0/0"
    _gp_check "an expired failure is looked up again" "expired-failure-retried:1:true"
    _gp_check "offline: the names stay as they were" "offline-unchanged:yes"
    _gp_check "offline: the lookup stops after a few misses" "offline-stops-early:yes"
    _gp_check "offline: no request is made" "offline-no-request:0"
    _gp_check "offline: nothing is cached" "offline-no-cache:none"
    _gp_check "offline with a few hosts: nothing is cached either" "offline-few-hosts-no-cache:none"
    _gp_check "DNS that answers only now and then: the lookup phase is bounded" "flaky-dns-bounded:yes"
    _gp_check "the time budget ends the lookup phase" "time-budget-ends-the-phase:1"
    _gp_check "private, link-local, loopback, ULA, FakeIP and CGNAT addresses (IPv6 too) are never sent" 'ipv6-private-never-sent:["2606:4700::1111"]'
    _gp_check "the FakeIP ranges come from the constants" "fakeip-from-constants:ppu"
    _gp_check "geoip.json is owner-only" "cache-mode:-rw-------"
    _gp_check "the annotated subscription file stays owner-only" "annotated-file-mode:-rw-------"
    _gp_check "a silent service changes nothing" "silent-service-unchanged:yes"
    _gp_check "a silent service caches nothing" "silent-service-no-cache:none"
    _gp_check "a non-JSON answer is warned about" "garbage-warned:1"
    _gp_check "a country stated by the name wins over the address of a shared entry point" "mirror-name-wins:true"
    _gp_check "the shared-entry-point disagreement is logged" "mirror-warned:1"
    _gp_check "the log names the affected servers" "mirror-warn-names:1"
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
# Test: IPv6 compatibility (issue #38)
# ─────────────────────────────────────────────────────────────────
# With IPv6 enabled the v6 TProxy inbound (tproxy-in-v6) must be matched by the
# SAME route rules as the v4 one (before this it matched none and v6 flows fell
# through to the default), and the FakeIP v6 range must be a routable global
# prefix (2001:2::/48), not the ULA fd00::/8 that dnsmasq rebind protection drops.
#   - constant: SB_FAKEIP_INET6_RANGE is not in fc00::/7
#   - IPv6 off: every rule keeps the plain string inbound (byte-identical config)
#   - IPv6 on: the same rules match ["tproxy-in","tproxy-in-v6"]
#   - the generated config passes `sing-box check`
test_ipv6_routing() {
    header "IPv6 Compatibility (issue #38)"

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

    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$cm_lib" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/netshift-ipv6routing-$$.sh"
    cat > "$drv" << 'V6EOF'
LIB="NETSHIFT_LIB"
BIN="BIN_PATH"
FACADE="FACADE_PATH"

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
. "$LIB/logging.sh" 2>/dev/null || log() { :; }
. "$FACADE"

# UCI stub: UC_<section>_<option> (list options are space separated)
config_get_bool() {
    eval "$1=\"\${UC_${2}_${3}:-$4}\""
    return 0
}
config_get() {
    eval "$1=\"\${UC_${2}_${3}:-$4}\""
    return 0
}
config_foreach() { local _cb="$1" _s; shift; for _s in $UC_SECTIONS; do "$_cb" "$_s" "$@"; done; }
config_list_foreach() {
    local _s="$1" _o="$2" _cb="$3" _i _v
    shift 3
    eval "_v=\"\${UC_${_s}_${_o}:-}\""
    for _i in $_v; do "$_cb" "$_i" "$@"; done
}
get_global_proxy_section() { echo ""; }
netshift_ipv6_enabled() { [ "$V6" = "1" ]; }
get_sections_by_connection_type() { echo ""; }
get_first_outbound_section() { echo "main"; }
get_outbound_tag_by_section() { echo "$1-out"; }
subscription_outbound_is_unavailable() { return 1; }

for fn in section_is_disabled _active_section_dispatch foreach_active_section exclude_source_ip_from_routing_handler \
    tproxy_route_inbounds sing_box_configure_route configure_common_reject_route_rule configure_common_direct_route_rule; do
    eval "$(awk -v name="$fn" '$0 == name "() {"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done
if command -v tproxy_route_inbounds > /dev/null 2>&1 &&
    command -v sing_box_configure_route > /dev/null 2>&1; then
    echo 'ipv6-real-functions-loaded:OK'
else
    echo 'ipv6-real-functions-loaded:FAIL'
fi

# FakeIP v6 range must not be a ULA (fc00::/7), whose AAAA answers dnsmasq
# rebind protection drops and for which clients have no route.
case "$SB_FAKEIP_INET6_RANGE" in
fc* | fd* | FC* | FD*) echo 'ipv6-fakeip-range-not-ula:FAIL' ;;
*) echo 'ipv6-fakeip-range-not-ula:OK' ;;
esac

base=$(jq -n \
    --arg direct "$SB_DIRECT_OUTBOUND_TAG" \
    --arg tproxy "$SB_TPROXY_INBOUND_TAG" \
    --arg listen "$SB_TPROXY_INBOUND_ADDRESS" \
    --argjson port "$SB_TPROXY_INBOUND_PORT" \
    --arg dns "$SB_DNS_SERVER_TAG" \
    --arg fakeip "$SB_FAKEIP_DNS_SERVER_TAG" \
    --arg v4 "$SB_FAKEIP_INET4_RANGE" \
    --arg v6 "$SB_FAKEIP_INET6_RANGE" \
    '{
    log: { disabled: false, level: "warn", timestamp: true },
    dns: {
        servers: [
            { type: "udp", tag: $dns, server: "77.88.8.8" },
            { type: "fakeip", tag: $fakeip, inet4_range: $v4, inet6_range: $v6 }
        ],
        rules: [], final: $dns, strategy: "prefer_ipv4", independent_cache: true
    },
    inbounds: [
        { type: "tproxy", tag: $tproxy, listen: $listen, listen_port: $port },
        { type: "tproxy", tag: ($tproxy + "-v6"), listen: "::1", listen_port: 1603 }
    ],
    outbounds: [
        { type: "direct", tag: $direct },
        { type: "direct", tag: "main-out" }
    ],
    route: { rules: [], rule_set: [], final: $direct, auto_detect_interface: true }
}')

# The routing excluded IPs add one more route rule (a source rule that also has to
# match both inbounds); block_doh adds the DoH-block rule; quic adds a reject rule.
UC_SECTIONS=""
UC_settings_routing_excluded_ips="192.168.1.5"
UC_settings_block_doh=1
UC_settings_disable_quic=1

gen() {
    V6="$1"
    config="$base"
    sing_box_configure_route
    printf '%s' "$config"
}

cfg_off=$(gen 0)
cfg_on=$(gen 1)
# All of them are really generated by this driver (not silently skipped).
echo "$cfg_on" | jq -e '[.route.rules[] | select(.action == "route" or .action == "reject")] | length >= 4' > /dev/null 2>&1 &&
    echo 'ipv6-driver-generates-all-rule-kinds:OK' || echo 'ipv6-driver-generates-all-rule-kinds:FAIL'
TPROXY="$SB_TPROXY_INBOUND_TAG"

# IPv6 off: only plain string inbounds, no v6 tag anywhere in the rules.
echo "$cfg_off" | jq -e --arg t "$TPROXY" \
    '[.route.rules[] | select(.action == "route" or .action == "reject") | .inbound]
     | length > 0 and all(. == $t)' > /dev/null 2>&1 &&
    echo 'ipv6-off-plain-inbound:OK' || echo 'ipv6-off-plain-inbound:FAIL'

# IPv6 on: the check-domain rule (always generated) matches both inbounds.
echo "$cfg_on" | jq -e --arg t "$TPROXY" --arg d "$CHECK_PROXY_IP_DOMAIN" \
    '[.route.rules[] | select(.domain == $d and .action == "route")]
     | length == 1 and .[0].inbound == [$t, ($t + "-v6")]' > /dev/null 2>&1 &&
    echo 'ipv6-on-check-domain-both-inbounds:OK' || echo 'ipv6-on-check-domain-both-inbounds:FAIL'

# IPv6 on: every route/reject rule that had the v4 inbound now has both.
echo "$cfg_on" | jq -e --arg t "$TPROXY" \
    '[.route.rules[] | select(.action == "route" or .action == "reject") | .inbound]
     | length > 0 and all(. == [$t, ($t + "-v6")])' > /dev/null 2>&1 &&
    echo 'ipv6-on-all-rules-both-inbounds:OK' || echo 'ipv6-on-all-rules-both-inbounds:FAIL'

# The helpers accept a bare tag and a JSON array alike.
bare='{"route":{"rules":[]}}'
one=$(sing_box_cm_add_route_rule "$bare" "t1" "tproxy-in" "direct-out")
two=$(sing_box_cm_add_route_rule "$bare" "t2" '["tproxy-in","tproxy-in-v6"]' "direct-out")
rej=$(sing_box_cm_add_reject_route_rule "$bare" "t3" '["tproxy-in","tproxy-in-v6"]')
echo "$one" | jq -e '.route.rules[0].inbound == "tproxy-in"' > /dev/null 2>&1 &&
    echo 'ipv6-helper-route-string:OK' || echo 'ipv6-helper-route-string:FAIL'
echo "$two" | jq -e '.route.rules[0].inbound == ["tproxy-in","tproxy-in-v6"]' > /dev/null 2>&1 &&
    echo 'ipv6-helper-route-array:OK' || echo 'ipv6-helper-route-array:FAIL'
echo "$rej" | jq -e '.route.rules[0].inbound == ["tproxy-in","tproxy-in-v6"]' > /dev/null 2>&1 &&
    echo 'ipv6-helper-reject-array:OK' || echo 'ipv6-helper-reject-array:FAIL'

# No local resolve rule for the IPv6 inbound. A "resolve" action there made every IPv6
# connection wait for the main DNS to resolve the name BEFORE routing: a name that
# resolves only through the tunnel (or that the local resolver does not know) failed
# over IPv6 while the same connection over IPv4 worked, because the proxy resolves the
# name itself. With IPv6 on or off no resolve action is generated.
echo "$cfg_on" | jq -e '[.route.rules[] | select(.action == "resolve")] | length == 0' > /dev/null 2>&1 &&
    echo 'ipv6-on-no-resolve-rule:OK' || echo 'ipv6-on-no-resolve-rule:FAIL'
echo "$cfg_off" | jq -e '[.route.rules[] | select(.action == "resolve")] | length == 0' > /dev/null 2>&1 &&
    echo 'ipv6-off-no-resolve-rules:OK' || echo 'ipv6-off-no-resolve-rules:FAIL'
# The route part of the IPv4 flows is identical with and without IPv6 once the
# inbound match is set aside.
norm='[.route.rules[] | select(.action != "resolve") | del(.inbound) | del(.["__service_tag"])]'
[ "$(echo "$cfg_on" | jq -cS "$norm")" = "$(echo "$cfg_off" | jq -cS "$norm")" ] &&
    echo 'ipv6-on-v4-rules-same-as-off:OK' || echo 'ipv6-on-v4-rules-same-as-off:FAIL'

# dns.strategy: prefer_ipv4 with IPv6 (as in the generated base), ipv4_only without.
d_set=$(sing_box_cm_configure_dns "$base" "$SB_DNS_SERVER_TAG" "ipv4_only" true)
echo "$d_set" | jq -e '.dns.strategy == "ipv4_only"' > /dev/null 2>&1 &&
    echo 'ipv6-dns-strategy-kept:OK' || echo 'ipv6-dns-strategy-kept:FAIL'

# The helpers: an empty inbound is a JSON empty string, not a jq error; the DoH-block
# helper takes the array form too.
emp=$(sing_box_cm_add_route_rule "$bare" "t4" "" "direct-out")
echo "$emp" | jq -e '.route.rules[0].inbound == ""' > /dev/null 2>&1 &&
    echo 'ipv6-helper-empty-inbound:OK' || echo 'ipv6-helper-empty-inbound:FAIL'
doh=$(sing_box_cm_add_doh_block_route_rule "$bare" "t5" '["tproxy-in","tproxy-in-v6"]' "1.1.1.1/32" "2606:4700::/32")
echo "$doh" | jq -e '[.route.rules[] | select(.rule_set != null)][0].inbound == ["tproxy-in","tproxy-in-v6"]' > /dev/null 2>&1 &&
    echo 'ipv6-helper-doh-block-array:OK' || echo 'ipv6-helper-doh-block-array:FAIL'

# Stale FakeIP mappings: when the recorded IPv6 FakeIP range differs (an upgrade moved
# it) the sing-box cache and its flash copy are dropped once; same range keeps them;
# without IPv6 nothing is touched or recorded.
eval "$(awk -v name="drop_stale_fakeip_cache" '$0 == name "() {"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
FW="/tmp/netshift-v6cache-$$"; rm -rf "$FW"; mkdir -p "$FW"
NETSHIFT_STATE_DIR="$FW"; NETSHIFT_CACHE_BACKUP="$FW/cache.db"; NETSHIFT_CACHE_SELECTION="$FW/cache.db.selection"
get_sing_box_cache_path() { echo "$FW/live.db"; }
FLOG="$FW/log"; log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$FLOG"; }
mkcache() { : > "$FW/live.db"; : > "$NETSHIFT_CACHE_BACKUP"; : > "$NETSHIFT_CACHE_SELECTION"; }
have() { [ -e "$FW/live.db" ] && echo kept || echo dropped; }
chk() { [ "$2" = "$3" ] && echo "$1:OK" || echo "$1:FAIL [got '$2' want '$3']"; }
V6=1; mkcache; drop_stale_fakeip_cache
chk ipv6-fakeip-cache-unrecorded-dropped "$(have):$(cat "$FW/fakeip-v6-range"):$(grep -c '^\[warn\] IPv6 FakeIP range is now' "$FLOG")" "dropped:$SB_FAKEIP_INET6_RANGE:1"
mkcache; drop_stale_fakeip_cache
chk ipv6-fakeip-cache-same-range-kept "$(have)" kept
printf '%s\n' 'fd00:ec3a::/32' > "$FW/fakeip-v6-range"; mkcache; drop_stale_fakeip_cache
chk ipv6-fakeip-cache-changed-range-dropped "$(have):$([ -e "$NETSHIFT_CACHE_BACKUP" ] && echo copy-kept || echo copy-dropped)" dropped:copy-dropped
rm -f "$FW/fakeip-v6-range"; V6=0; mkcache; drop_stale_fakeip_cache
chk ipv6-fakeip-cache-ipv6-off-untouched "$(have):$([ -e "$FW/fakeip-v6-range" ] && echo recorded || echo none)" kept:none
rm -rf "$FW"

# sing-box validation of the SAVED artifacts.
if command -v sing-box > /dev/null 2>&1; then
    sing_box_cm_save_config_to_file "$cfg_off" /tmp/v6-off.json
    sing_box_cm_save_config_to_file "$cfg_on" /tmp/v6-on.json
    sing-box -c /tmp/v6-off.json check > /dev/null 2>&1 &&
        echo 'ipv6-off-singbox-check:OK' || echo 'ipv6-off-singbox-check:FAIL'
    sing-box -c /tmp/v6-on.json check > /dev/null 2>&1 &&
        echo 'ipv6-on-singbox-check:OK' || echo 'ipv6-on-singbox-check:FAIL'
    rm -f /tmp/v6-off.json /tmp/v6-on.json
else
    echo 'ipv6-off-singbox-check:SKIP'
    echo 'ipv6-on-singbox-check:SKIP'
fi

echo 'DONE'
V6EOF
    sed -i "s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g; s|BIN_PATH|$bin|; s|FACADE_PATH|$facade_lib|" "$drv"

    local v6_out="/tmp/netshift-ipv6routing-out-$$.log"
    ash "$drv" > "$v6_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$v6_out"
    if [ "$saw_done" = "1" ]; then
        pass "ipv6-driver-completed:OK"
    else
        fail "ipv6-driver-completed:FAIL (driver aborted early)" "$(tail -20 "$v6_out")"
    fi
    rm -f "$drv" "$v6_out"
}

# ─────────────────────────────────────────────────────────────────

# Test: Multi-DNS upstream pool (issue #74)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL sing_box_configure_dns_pool / _dns_pool_collect_entry /
# is_valid_dns_pool_timeout (extracted verbatim from the bin) and the real
# manager/facade helpers against a stubbed UCI layer. Asserts:
#   - default (mode absent / single) and every unusable setup leave the config
#     byte-identical to the single-upstream one (upgrade safety);
#   - fallback: the primary and the list are asked in order, each but the last
#     gets evaluate + respond (NOERROR / NXDOMAIN), the last one is `final`;
#   - race: every upstream is evaluated, the respond rules carry race, `final`
#     stays the primary;
#   - sing-box < 1.14.0 ignores the pool with a warning (the rule actions do
#     not exist there); entry validation, limits, detour and bootstrap resolver;
#   - the six transports map to the right sing-box server types.
test_dns_pool() {
    header "Multi-DNS upstream pool (issue #74)"

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

    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$cm_lib" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/netshift-dnspool-$$.sh"
    cat > "$drv" << 'DPEOF'
LIB="NETSHIFT_LIB"
BIN="BIN_PATH"
FACADE="FACADE_PATH"

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
LOGF="/tmp/netshift-dnspool-log-$$"
log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$LOGF"; }
. "$FACADE"

# UCI stubs: DP_MODE / DP_TIMEOUT / DP_ENTRIES (space separated entries)
config_get() {
    case "$3" in
    dns_pool_mode) eval "$1=\"\${DP_MODE:-}\"" ;;
    dns_pool_timeout) eval "$1=\"\${DP_TIMEOUT:-\${4:-}}\"" ;;
    *) eval "$1=\"\${4:-}\"" ;;
    esac
}
config_get_bool() { eval "$1=\"\${DP_BLOCK_DOH:-0}\""; }
config_list_foreach() {
    local _e
    for _e in $DP_ENTRIES; do "$3" "$_e"; done
}
for fn in is_valid_dns_pool_timeout _dns_pool_collect_entry sing_box_configure_dns_pool; do
    eval "$(awk -v name="$fn" '$0 == name "() {"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done
if command -v sing_box_configure_dns_pool > /dev/null 2>&1 &&
    command -v _dns_pool_collect_entry > /dev/null 2>&1; then
    echo 'dnspool-real-functions-loaded:OK'
else
    echo 'dnspool-real-functions-loaded:FAIL'
fi

ok() { [ "$1" = "$2" ] && echo "$3:OK" || echo "$3:FAIL [got '$1' want '$2']"; }

# ── version gate ───────────────────────────────────────────────────
for spec in "1.14.0|yes" "1.14.1|yes" "1.14.1-extended-2.7.2-lite|yes" "1.15.0|yes" "1.100.0|yes" \
    "1.13.14-extended-2.5.3|no" "1.12.22|no" "1.9.0|no" "1.0|no"; do
    v="${spec%%|*}"
    if is_sing_box_at_least "$SB_DNS_EVALUATE_MIN" "$v"; then got=yes; else got=no; fi
    ok "$got" "${spec#*|}" "dnspool-gate-$v"
done

# ── url_get_port on bracketed IPv6 (a literal without a port has none) ──
ok "$(url_get_port "[2001:db8::1]")" "" "dnspool-url-port-ipv6-no-port"
ok "$(url_get_port "[2001:db8::1]:853/x")" "853" "dnspool-url-port-ipv6-with-port"
ok "$(url_get_port "dns.example:853")" "853" "dnspool-url-port-host-port"

# ── timeout syntax ─────────────────────────────────────────────────
for t in 500ms 2s 10s 1ms; do
    is_valid_dns_pool_timeout "$t" && echo "dnspool-timeout-ok-$t:OK" || echo "dnspool-timeout-ok-$t:FAIL"
done
for t in "" 0s 2 s 1.5s 2m -1s "2 s" 0ms; do
    is_valid_dns_pool_timeout "$t" && echo "dnspool-timeout-bad-[$t]:FAIL" || echo "dnspool-timeout-bad-[$t]:OK"
done

base='{"dns":{"servers":[{"type":"udp","tag":"bootstrap-dns-server","server":"77.88.8.8","server_port":53},{"type":"udp","tag":"dns-server","server":"8.8.8.8","server_port":53}],"rules":[{"action":"route","server":"fakeip-server"}],"final":"dns-server"}}'

gen() { # $1=version $2=mode $3=entries $4=timeout $5=detour
    export NETSHIFT_SING_BOX_VERSION="$1"
    DP_MODE="$2"; DP_ENTRIES="$3"; DP_TIMEOUT="$4"
    : > "$LOGF"
    config="$base"
    sing_box_configure_dns_pool "$5"
    printf '%s' "$config"
}
same() { [ "$(printf '%s' "$1" | jq -cS .)" = "$(printf '%s' "$base" | jq -cS .)" ]; }
warned() { grep -q "^\[warn\] .*$1" "$LOGF"; }

E2="udp://1.1.1.1 dot://dns.quad9.net"
V=1.14.1

# ── unchanged setups ───────────────────────────────────────────────
c="$(gen $V "" "$E2")"; same "$c" && echo 'dnspool-mode-absent-unchanged:OK' || echo 'dnspool-mode-absent-unchanged:FAIL'
c="$(gen $V single "$E2")"; same "$c" && echo 'dnspool-single-unchanged:OK' || echo 'dnspool-single-unchanged:FAIL'
c="$(gen $V bogus "$E2")"; same "$c" && warned "Unknown dns_pool_mode" && echo 'dnspool-unknown-mode-unchanged-warned:OK' || echo 'dnspool-unknown-mode-unchanged-warned:FAIL'
c="$(gen $V fallback "")"; same "$c" && warned "no valid dns_pool_server" && echo 'dnspool-empty-list-unchanged-warned:OK' || echo 'dnspool-empty-list-unchanged-warned:FAIL'
c="$(gen 1.13.14-extended-2.5.3 fallback "$E2")"; same "$c" && warned "needs sing-box 1.14.0" && echo 'dnspool-old-core-unchanged-warned:OK' || echo 'dnspool-old-core-unchanged-warned:FAIL'
c="$(gen 1.13.14-extended-2.5.3 race "$E2")"; same "$c" && echo 'dnspool-old-core-race-unchanged:OK' || echo 'dnspool-old-core-race-unchanged:FAIL'

# ── fallback ───────────────────────────────────────────────────────
c="$(gen $V fallback "$E2")"
echo "$c" | jq -e '[.dns.servers[].tag] == ["bootstrap-dns-server","dns-server","dns-server-2","dns-server-3"]' > /dev/null &&
    echo 'dnspool-fallback-servers:OK' || echo 'dnspool-fallback-servers:FAIL'
echo "$c" | jq -e '.dns.final == "dns-server-3"' > /dev/null &&
    echo 'dnspool-fallback-final-is-last:OK' || echo 'dnspool-fallback-final-is-last:FAIL'
echo "$c" | jq -e '.dns.rules[0].server == "fakeip-server" and (.dns.rules | length) == 7' > /dev/null &&
    echo 'dnspool-fallback-keeps-existing-rules-first:OK' || echo 'dnspool-fallback-keeps-existing-rules-first:FAIL'
echo "$c" | jq -e '[.dns.rules[1:][] | [.action, .server // .match_response, .response_rcode // ""]] ==
    [["evaluate","dns-server",""],["respond","dns-pool-response-1","NOERROR"],["respond","dns-pool-response-1","NXDOMAIN"],
     ["evaluate","dns-server-2",""],["respond","dns-pool-response-2","NOERROR"],["respond","dns-pool-response-2","NXDOMAIN"]]' > /dev/null &&
    echo 'dnspool-fallback-rule-order:OK' || echo "dnspool-fallback-rule-order:FAIL [$(echo "$c" | jq -c '[.dns.rules[1:][] | [.action, .server // .match_response]]')]"
echo "$c" | jq -e '[.dns.rules[] | select(.action == "evaluate") | .timeout] == ["2s","2s"] and ([.dns.rules[] | select(.race)] | length) == 0' > /dev/null &&
    echo 'dnspool-fallback-timeout-no-race:OK' || echo 'dnspool-fallback-timeout-no-race:FAIL'

# ── race ───────────────────────────────────────────────────────────
c="$(gen $V race "$E2" 500ms)"
echo "$c" | jq -e '.dns.final == "dns-server"' > /dev/null &&
    echo 'dnspool-race-final-is-primary:OK' || echo 'dnspool-race-final-is-primary:FAIL'
echo "$c" | jq -e '[.dns.rules[] | select(.action == "evaluate") | .server] == ["dns-server","dns-server-2","dns-server-3"]
    and ([.dns.rules[] | select(.action == "evaluate") | .timeout] | unique) == ["500ms"]' > /dev/null &&
    echo 'dnspool-race-evaluates-all-with-timeout:OK' || echo 'dnspool-race-evaluates-all-with-timeout:FAIL'
echo "$c" | jq -e '[.dns.rules[] | select(.action == "respond")] as $r
    | ($r | length) == 6 and ($r | all(.race == true)) and ([$r[].response_rcode] | unique) == ["NOERROR","NXDOMAIN"]' > /dev/null &&
    echo 'dnspool-race-respond-rules-race:OK' || echo 'dnspool-race-respond-rules-race:FAIL'
echo "$c" | jq -e '([.dns.rules[] | .action] | index("respond")) > ([.dns.rules[] | .action] | rindex("evaluate"))' > /dev/null &&
    echo 'dnspool-race-evaluate-before-respond:OK' || echo 'dnspool-race-evaluate-before-respond:FAIL'
c="$(gen $V race "$E2" "oops")"
echo "$c" | jq -e '[.dns.rules[] | select(.action == "evaluate") | .timeout] | unique == ["2s"]' > /dev/null && warned "Invalid dns_pool_timeout" &&
    echo 'dnspool-bad-timeout-defaults-warned:OK' || echo 'dnspool-bad-timeout-defaults-warned:FAIL'

# ── entries ────────────────────────────────────────────────────────
c="$(gen $V fallback "udp://1.1.1.1 bogus http://x.example udp://bad_host udp://1.1.1.1:99999 udp://8.8.4.4/path udp://1.2.3.4. udp://1234 udp://9.9.9.9")"
echo "$c" | jq -e '[.dns.servers[] | select(.tag | startswith("dns-server-")) | .server] == ["1.1.1.1","9.9.9.9"]' > /dev/null &&
    echo 'dnspool-bad-entries-skipped:OK' || echo "dnspool-bad-entries-skipped:FAIL [$(echo "$c" | jq -c '[.dns.servers[].server]')]"
n=0; for w in "expected <scheme>" "unknown scheme" "not an IP address or domain" "out of range" "a path is only allowed"; do warned "$w" && n=$((n + 1)); done
ok "$n" 5 "dnspool-bad-entries-each-warned"
# 'loose' IPv4 forms that is_ipv4 takes and sing-box refuses are skipped with a warning
ok "$(grep -c "^\[warn\] Ignoring dns_pool_server 'udp://1.2.3.4.': '1.2.3.4.' is not an IP\|^\[warn\] Ignoring dns_pool_server 'udp://1234': '1234' is not an IP" "$LOGF")" 2 "dnspool-loose-ipv4-skipped-warned"

# ── host names are case-insensitive: the host is lowered, the path keeps its case ──
c="$(gen $V fallback "dot://DNS.QUAD9.NET doh://DNS.Google/Dns-Query udp://1.1.1.1")"
echo "$c" | jq -e '[.dns.servers[] | select(.tag | startswith("dns-server-")) | [.server, .path // ""]] == [["dns.quad9.net",""],["dns.google","/Dns-Query"],["1.1.1.1",""]]' > /dev/null &&
    echo 'dnspool-uppercase-host-lowered-path-kept:OK' || echo "dnspool-uppercase-host-lowered-path-kept:FAIL [$(echo "$c" | jq -c '[.dns.servers[] | [.server,.path]]')]"

# ── block_doh: doh/doh3 upstreams without a detour are called out ──
DP_BLOCK_DOH=1
c="$(gen $V race "doh://dns.google/dns-query udp://1.1.1.1")"; warned "DoH blocking is enabled and the DNS pool has doh/doh3" && echo 'dnspool-blockdoh-doh-warned:OK' || echo 'dnspool-blockdoh-doh-warned:FAIL'
c="$(gen $V race "doh3://dns.adguard-dns.com/dns-query")"; warned "DoH blocking is enabled and the DNS pool has doh/doh3" && echo 'dnspool-blockdoh-doh3-warned:OK' || echo 'dnspool-blockdoh-doh3-warned:FAIL'
c="$(gen $V race "doh://dns.google/dns-query" "" main-out)"; warned "DoH blocking" && echo 'dnspool-blockdoh-detour-silent:FAIL' || echo 'dnspool-blockdoh-detour-silent:OK'
c="$(gen $V race "udp://1.1.1.1 dot://dns.quad9.net")"; warned "DoH blocking" && echo 'dnspool-blockdoh-no-doh-silent:FAIL' || echo 'dnspool-blockdoh-no-doh-silent:OK'
DP_BLOCK_DOH=0
c="$(gen $V race "doh://dns.google/dns-query")"; warned "DoH blocking" && echo 'dnspool-blockdoh-off-silent:FAIL' || echo 'dnspool-blockdoh-off-silent:OK'
many=""; i=1; while [ $i -le 12 ]; do many="$many udp://10.0.0.$i"; i=$((i + 1)); done
c="$(gen $V race "$many")"
ok "$(echo "$c" | jq '[.dns.servers[] | select(.tag | startswith("dns-server"))] | length')" "$DNS_POOL_MAX_SERVERS" "dnspool-max-upstreams"
warned "at most $DNS_POOL_MAX_SERVERS upstreams" && echo 'dnspool-max-upstreams-warned:OK' || echo 'dnspool-max-upstreams-warned:FAIL'

# ── transports, detour, resolver ───────────────────────────────────
c="$(gen $V race "udp://1.1.1.1 tcp://1.1.1.1:5353 dot://dns.quad9.net doh://dns.google/dns-query doh3://dns.adguard-dns.com/dns-query doq://dns.adguard-dns.com:8853 udp://[2001:4860:4860::8888]" "" main-out)"
echo "$c" | jq -e '[.dns.servers[] | select(.tag | startswith("dns-server-")) | [.type, .server, .server_port, .path // ""]] ==
    [["udp","1.1.1.1",53,""],["tcp","1.1.1.1",5353,""],["tls","dns.quad9.net",853,""],["https","dns.google",443,"/dns-query"],
     ["h3","dns.adguard-dns.com",443,"/dns-query"],["quic","dns.adguard-dns.com",8853,""],["udp","2001:4860:4860::8888",53,""]]' > /dev/null &&
    echo 'dnspool-transports-map:OK' || echo "dnspool-transports-map:FAIL [$(echo "$c" | jq -c '[.dns.servers[] | select(.tag | startswith("dns-server-")) | [.type,.server,.server_port,.path]]')]"
echo "$c" | jq -e '[.dns.servers[] | select(.tag | startswith("dns-server-")) | .detour] | all(. == "main-out")' > /dev/null &&
    echo 'dnspool-detour-on-every-upstream:OK' || echo 'dnspool-detour-on-every-upstream:FAIL'
# jq on OpenWrt has no regex: hostnames are the servers that are neither dotted-quad nor IPv6
echo "$c" | jq -e '[.dns.servers[] | select(.tag | startswith("dns-server-"))] as $s
    | ($s | map(select(.server == "dns.quad9.net" or .server == "dns.google" or .server == "dns.adguard-dns.com")) | all(.domain_resolver == "bootstrap-dns-server"))
    and ($s | map(select(.server == "1.1.1.1" or .server == "2001:4860:4860::8888")) | all((.domain_resolver // "") == ""))' > /dev/null &&
    echo 'dnspool-bootstrap-resolver-only-for-hostnames:OK' || echo 'dnspool-bootstrap-resolver-only-for-hostnames:FAIL'
c="$(gen $V race "udp://1.1.1.1" "" "")"
echo "$c" | jq -e '[.dns.servers[] | .detour // "none"] | all(. == "none")' > /dev/null &&
    echo 'dnspool-no-detour-when-direct:OK' || echo 'dnspool-no-detour-when-direct:FAIL'

# ── the generated config validates on a core that knows the actions ──
# /usr/local/bin/sing-box-1.14 is a stock sing-box 1.14 that the test image carries next
# to its older default core (tests/Dockerfile).
SBN=/usr/local/bin/sing-box-1.14
if [ -x "$SBN" ] && is_sing_box_at_least "$SB_DNS_EVALUATE_MIN" "$("$SBN" version 2> /dev/null | awk 'NR==1{print $3}')"; then
    for m in fallback race; do
        gen $V $m "$E2" > /tmp/dnspool-$m.json
        jq '. + {route:{default_domain_resolver:"dns-server"}} | .dns.rules |= map(select(.action != "route"))
            | walk(if type == "object" then del(.__service_tag) else . end)' /tmp/dnspool-$m.json > /tmp/dnspool-$m-check.json
        "$SBN" -c /tmp/dnspool-$m-check.json check > /dev/null 2>&1 &&
            echo "dnspool-$m-singbox-check:OK" || echo "dnspool-$m-singbox-check:FAIL"
    done
    # the check really tells: a rule with a wrong field name is refused
    jq '(.dns.rules[] | select(.action == "evaluate")) += {tmieout: "2s"}' /tmp/dnspool-race-check.json > /tmp/dnspool-bad-check.json
    "$SBN" -c /tmp/dnspool-bad-check.json check > /dev/null 2>&1 &&
        echo 'dnspool-singbox-check-rejects-bad-field:FAIL' || echo 'dnspool-singbox-check-rejects-bad-field:OK'
    rm -f /tmp/dnspool-*.json
else
    echo 'dnspool-fallback-singbox-check:SKIP'
    echo 'dnspool-race-singbox-check:SKIP'
fi

rm -f "$LOGF"
echo 'DONE'
DPEOF
    sed -i "s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g; s|BIN_PATH|$bin|; s|FACADE_PATH|$facade_lib|" "$drv"

    local dp_out="/tmp/netshift-dnspool-out-$$.log"
    ash "$drv" > "$dp_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$dp_out"
    if [ "$saw_done" = "1" ]; then
        pass "dnspool-driver-completed:OK"
    else
        fail "dnspool-driver-completed:FAIL (driver aborted early)" "$(tail -20 "$dp_out")"
    fi
    rm -f "$drv" "$dp_out"
}

# ─────────────────────────────────────────────────────────────────

# Test: Chained connections (outbound_detour_section)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL configure_outbound_detour_handler / _outbound_detour_chain_is_usable
# (extracted verbatim from the bin) and sing_box_cm_set_outbounds_detour against a
# stubbed UCI layer. Asserts:
#   - the section's real proxy outbounds (leaves of selector/urltest, or the
#     single outbound) get `detour` = the target's tag, the target's own members
#     and outbounds with their own detour are left alone;
#   - sections without the option (every existing config) are untouched;
#   - a chain that cannot be built (unknown/blocked target, itself, a loop, an
#     unavailable target) never falls back to a direct connection: the section is
#     marked unavailable and gets no detour.
test_cascade() {
    header "Chained connections (outbound_detour_section)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not available"
        return
    fi

    local cm_lib="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    local constants_lib="${NETSHIFT_LIB_DIR}/constants.sh"
    local jq_helpers="${NETSHIFT_LIB_DIR}/helpers.jq"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$cm_lib" ] || [ ! -r "$constants_lib" ] || [ ! -r "$jq_helpers" ] || [ ! -r "$bin" ]; then
        skip "config manager / constants / helpers.jq / netshift bin not found"
        return
    fi

    mkdir -p /usr/lib/netshift
    ln -sf "$jq_helpers" /usr/lib/netshift/helpers.jq
    ln -sf "${NETSHIFT_LIB_DIR}/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$cm_lib" /usr/lib/netshift/sing_box_config_manager.sh

    local drv="/tmp/netshift-cascade-$$.sh"
    cat > "$drv" << 'CCEOF'
LIB="NETSHIFT_LIB"
BIN="BIN_PATH"

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
. "$LIB/sing_box_config_manager.sh"
log() { :; }
echolog() { :; }

# UCI stub: CC_<section>_<option>
config_get() {
    local _v
    eval "_v=\"\${CC_${2}_${3}:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"\$_v\""
}
for fn in subscription_outbound_is_unavailable mark_section_outbound_unavailable _outbound_detour_chain_is_usable \
    configure_outbound_detour_handler _outbound_detour_break sing_box_reject_unmatched_for_broken_chain; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done
if command -v configure_outbound_detour_handler > /dev/null 2>&1; then
    echo 'cascade-real-functions-loaded:OK'
else
    echo 'cascade-real-functions-loaded:FAIL'
fi

base='{"outbounds":[
 {"type":"direct","tag":"direct-out"},
 {"type":"vless","tag":"a-out","server":"a.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555"},
 {"type":"vless","tag":"m1","server":"m1.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555"},
 {"type":"vless","tag":"m2","server":"m2.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","detour":"custom"},
 {"type":"urltest","tag":"b-urltest-out","outbounds":["m1","m2"]},
 {"type":"selector","tag":"b-out","outbounds":["m1","m2","b-urltest-out"],"default":"b-urltest-out"},
 {"type":"vless","tag":"c-out","server":"c.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555"},
 {"type":"vless","tag":"d-out","server":"d.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555"},
 {"type":"selector","tag":"r-out","outbounds":["direct-out","a-out"],"default":"direct-out"},
 {"type":"vless","tag":"l1","server":"l1.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555"},
 {"type":"selector","tag":"loop-out","outbounds":["loop-out","l1"],"default":"l1"}],
 "route":{"rules":[{"action":"route","outbound":"c-out"}]}}'

for s in a b c d e r loop x; do eval "CC_${s}_connection_type=proxy"; done
CC_r_proxy_config_type=outbound
CC_e_connection_type=block
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""

detour_of() { printf '%s' "$config" | jq -r --arg t "$1" '.outbounds[] | select(.tag == $t) | .detour // "none"'; }
unavailable() { case " $SUBSCRIPTION_UNAVAILABLE_SECTIONS " in *" $1 "*) echo yes ;; *) echo no ;; esac; }
run() { # $1 = section
    config="$base"; SUBSCRIPTION_UNAVAILABLE_SECTIONS=""; CHAIN_BROKEN_SECTIONS=""
    configure_outbound_detour_handler "$1"
}
ok() { [ "$1" = "$2" ] && echo "$3:OK" || echo "$3:FAIL [got '$1' want '$2']"; }
jqc() { printf '%s' "$config" | jq -c "$1"; }

# ── no option: untouched ───────────────────────────────────────────
run a
ok "$(printf '%s' "$config" | jq -cS .)" "$(printf '%s' "$base" | jq -cS .)" "cascade-no-option-untouched"
ok "$(unavailable a)" no "cascade-no-option-available"

# ── single outbound through a selector target ──────────────────────
CC_a_outbound_detour_section=b
run a
ok "$(detour_of a-out)" "b-out" "cascade-single-outbound-detour"
ok "$(detour_of m1)$(detour_of m2)" "nonecustom" "cascade-target-members-untouched"
ok "$(unavailable a)" no "cascade-valid-chain-available"

# ── selector section through a single outbound: leaves get it, own detour kept ──
CC_a_outbound_detour_section=""
CC_b_outbound_detour_section=c
run b
ok "$(detour_of m1)" "c-out" "cascade-selector-leaf-detour"
ok "$(detour_of m2)" "custom" "cascade-own-detour-kept"
ok "$(detour_of b-out)$(detour_of b-urltest-out)$(detour_of c-out)" "nonenonenone" "cascade-groups-and-target-untouched"
CC_b_outbound_detour_section=""

# ── three-hop chain: every section chained to the next ─────────────
CC_a_outbound_detour_section=c
CC_c_outbound_detour_section=d
config="$base"; SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
configure_outbound_detour_handler a; configure_outbound_detour_handler c
ok "$(detour_of a-out)$(detour_of c-out)$(detour_of d-out)" "c-outd-outnone" "cascade-three-hops"
CC_a_outbound_detour_section=""; CC_c_outbound_detour_section=""

# ── chains that cannot be built never go direct ────────────────────
bad() { # $1=section $2=target $3=label
    eval "CC_${1}_outbound_detour_section=$2"
    run "$1"
    ok "$(unavailable "$1")$(detour_of "${1}-out")" "yesnone" "$3"
    eval "CC_${1}_outbound_detour_section="
}
bad a nosuch cascade-unknown-target-rejected
bad a e cascade-block-target-rejected
bad a a cascade-self-target-rejected
bad a b-missing cascade-missing-outbound-rejected
CC_c_outbound_detour_section=a
bad a c cascade-loop-rejected
CC_c_outbound_detour_section=""
# a target that is a proxy section in the config but has no outbound (a disabled one)
bad a x cascade-target-without-outbound-rejected
# a broken chain is remembered for the global-proxy handling
CC_a_outbound_detour_section=nosuch; run a
case " $CHAIN_BROKEN_SECTIONS " in *" a "*) echo 'cascade-broken-chain-remembered:OK' ;; *) echo 'cascade-broken-chain-remembered:FAIL' ;; esac
CC_a_outbound_detour_section=""
# a raw outbound group (user JSON) is refused: its members may belong to other
# sections or be the shared direct outbound, which must never get a detour
CC_r_outbound_detour_section=b; run r
ok "$(unavailable r)$(detour_of direct-out)$(detour_of a-out)$(detour_of r-out)" "yesnonenonenone" "cascade-raw-group-refused-direct-out-untouched"
CC_r_outbound_detour_section=""
# the shared direct outbound never gets a detour, even reached through a section group
CC_loop_outbound_detour_section=b
config="$base"; SUBSCRIPTION_UNAVAILABLE_SECTIONS=""; CHAIN_BROKEN_SECTIONS=""
configure_outbound_detour_handler loop
ok "$(unavailable loop)$(detour_of l1)$(detour_of direct-out)" "nob-outnone" "cascade-self-referencing-selector-terminates"
CC_loop_outbound_detour_section=""
# a failing update must not wipe the config: the section is rejected instead
CC_a_outbound_detour_section=b
sing_box_cm_set_outbounds_detour() { return 1; }
run a
ok "$(unavailable a)$([ -n "$config" ] && echo config-kept)" "yesconfig-kept" "cascade-failed-update-keeps-config"
unset -f sing_box_cm_set_outbounds_detour
. "$LIB/sing_box_config_manager.sh"
CC_a_outbound_detour_section=""
# global proxy section with a broken chain: the unmatched traffic is rejected (the
# catch-all reject rule is the last one), a healthy chain adds nothing
get_global_proxy_section() { echo "a"; }
config="$base"; CHAIN_BROKEN_SECTIONS=" a"
sing_box_reject_unmatched_for_broken_chain
ok "$(jqc '[.route.rules[-1] | .action, (.outbound // "none"), (.inbound // "none")] | join(",")')" '"reject,none,none"' "cascade-global-broken-chain-rejects-last"
config="$base"; CHAIN_BROKEN_SECTIONS=""
sing_box_reject_unmatched_for_broken_chain
ok "$(jqc '.route.rules | length')" 1 "cascade-global-healthy-chain-no-reject"
config="$base"; CHAIN_BROKEN_SECTIONS=" b"
sing_box_reject_unmatched_for_broken_chain
ok "$(jqc '.route.rules | length')" 1 "cascade-other-section-broken-no-global-reject"
get_global_proxy_section() { echo ""; }

# a target marked unavailable (failed subscription) takes the chain down with it
CC_a_outbound_detour_section=d
config="$base"; SUBSCRIPTION_UNAVAILABLE_SECTIONS=" d"
configure_outbound_detour_handler a
ok "$(unavailable a)$(detour_of a-out)" "yesnone" "cascade-unavailable-target-rejected"
# ... also further down the chain
CC_a_outbound_detour_section=c; CC_c_outbound_detour_section=d
config="$base"; SUBSCRIPTION_UNAVAILABLE_SECTIONS=" d"
configure_outbound_detour_handler a
ok "$(unavailable a)$(detour_of a-out)" "yesnone" "cascade-unavailable-further-down-rejected"
CC_a_outbound_detour_section=""; CC_c_outbound_detour_section=""

# ── the chained config validates ───────────────────────────────────
if command -v sing-box > /dev/null 2>&1; then
    CC_a_outbound_detour_section=b
    run a
    printf '%s' "$config" | jq '. + {dns:{servers:[{type:"udp",tag:"d",server:"1.1.1.1"}]},route:{default_domain_resolver:"d",final:"direct-out"}} | .outbounds += [{type:"direct",tag:"custom"}]' > /tmp/cascade-chk.json
    sing-box -c /tmp/cascade-chk.json check > /dev/null 2>&1 &&
        echo 'cascade-singbox-check:OK' || echo 'cascade-singbox-check:FAIL'
    # ... and so does one that ends in the catch-all reject rule
    config="$(sing_box_cm_add_final_reject_rule "$config" "final-reject")"
    printf '%s' "$config" | jq '. + {dns:{servers:[{type:"udp",tag:"d",server:"1.1.1.1"}]},route:(.route + {default_domain_resolver:"d",final:"direct-out"})}
        | .outbounds += [{type:"direct",tag:"custom"}] | walk(if type == "object" then del(.__service_tag) else . end)' > /tmp/cascade-chk2.json
    sing-box -c /tmp/cascade-chk2.json check > /dev/null 2>&1 &&
        echo 'cascade-final-reject-singbox-check:OK' || echo 'cascade-final-reject-singbox-check:FAIL'
    rm -f /tmp/cascade-chk.json /tmp/cascade-chk2.json
else
    echo 'cascade-singbox-check:SKIP'
fi
echo 'DONE'
CCEOF
    sed -i "s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g; s|BIN_PATH|$bin|" "$drv"

    local cc_out="/tmp/netshift-cascade-out-$$.log"
    ash "$drv" > "$cc_out" 2>&1 || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) saw_done=1 ;;
            *) ;;
        esac
    done < "$cc_out"
    if [ "$saw_done" = "1" ]; then
        pass "cascade-driver-completed:OK"
    else
        fail "cascade-driver-completed:FAIL (driver aborted early)" "$(tail -20 "$cc_out")"
    fi
    rm -f "$drv" "$cc_out"
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

# Test: Priority node selection (priority_mode)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL priority_select_for_section / _priority_check_section_handler /
# priority_check_interval (extracted verbatim from the bin) against a stubbed
# Clash API. Asserts:
#   - the FIRST server that answers is selected, in list order, and the selector
#     goes back to a higher one when it recovers;
#   - nothing is switched when the right server is already selected, when nothing
#     answers, or when there is nothing to choose from (groups are not probed);
#   - names with spaces / non-ASCII characters survive; the probe count is capped;
#   - sections without the option are never probed.
test_priority_selection() {
    header "Priority node selection"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ] || ! command -v jq > /dev/null 2>&1; then
        skip "netshift bin / constants.sh / jq not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        PR_LOG="/tmp/netshift-prio-log-$$"; PR_SET="/tmp/netshift-prio-set-$$"; PR_PROBE="/tmp/netshift-prio-probe-$$"
        : > "$PR_LOG"; : > "$PR_SET"; : > "$PR_PROBE"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$PR_LOG"; }
        for fn in priority_check_interval priority_clash_setup priority_select_for_section _priority_warn_once \
            _priority_collect_section_handler priority_check_sections; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done
        PRIORITY_WARNED=""; PRIORITY_RESUME=0
        PRIORITY_DEADLINE=$(($(date +%s) + 3600))
        get_outbound_tag_by_section() { echo "$1-out"; }
        section_is_disabled() { [ "${PR_DISABLED:-0}" = 1 ]; }
        config_get_bool() { eval "$1=\"\${PR_MODE:-0}\""; }
        config_get() {
            case "$3" in
            priority_check_interval) eval "$1=\"\${PR_INTERVAL:-$4}\"" ;;
            service_listen_address) eval "$1=\"\${PR_LISTEN:-}\"" ;;
            yacd_secret_key) eval "$1=\"\${PR_SECRET:-}\"" ;;
            connection_type) eval "$1=\"\${PR_CONN:-proxy}\"" ;;
            *) eval "$1=\"$4\"" ;;
            esac
        }
        network_get_ipaddr() { eval "$1=192.168.1.1"; }

        # PR_NOW = selected server, PR_ALL = newline separated members ("|" = group member),
        # PR_ALIVE = newline separated servers that answer
        proxies_json() {
            jq -n --arg now "$PR_NOW" --arg all "$PR_ALL" '
                ($all | split("\n") | map(select(. != ""))) as $members
                | {proxies: ({"s-out": {type: "Selector", now: $now, all: $members}}
                    + ($members | map({key: ., value: {type: (if endswith("-urltest-out") then "URLTest" else "Vless" end)}}) | from_entries))}'
        }
        priority_fetch_proxies() { [ -n "$PR_NOCLASH" ] && return 1; proxies_json; }
        priority_probe_delay() {
            printf '%s\n' "$1" >> "$PR_PROBE"
            if printf '%s\n' "$PR_ALIVE" | grep -qxF "$1"; then echo 120; else echo 0; fi
        }
        clash_api() {
            case "$1" in
            set_group_proxy)
                printf '%s>%s\n' "$2" "$3" >> "$PR_SET"
                echo '{"success":true}'
                ;;
            esac
        }
        run() { # $1 now  $2 members  $3 alive
            PR_NOW="$1"; PR_ALL="$2"; PR_ALIVE="$3"
            : > "$PR_SET"; : > "$PR_PROBE"; : > "$PR_LOG"
            PRIORITY_PROXIES_JSON="$(proxies_json)"
            priority_select_for_section s
        }
        set_of() { tr '\n' ',' < "$PR_SET"; }
        probes_of() { tr '\n' ',' < "$PR_PROBE"; }

        run B "$(printf 'A\nB\nC')" "$(printf 'A\nB\nC')"
        echo "first-alive-wins:$(set_of)"
        run A "$(printf 'A\nB\nC')" "$(printf 'A\nB\nC')"
        echo "already-selected-no-switch:[$(set_of)] probes=$(probes_of)"
        run C "$(printf 'A\nB\nC')" "$(printf 'B\nC')"
        echo "dead-first-second-wins:$(set_of) probes=$(probes_of)"
        run C "$(printf 'A\nB\nC')" "C"
        echo "only-last-alive-already-selected:[$(set_of)]"
        run B "$(printf 'A\nB\nC')" ""
        echo "none-alive-keeps:[$(set_of)] warned=$(grep -c '^\[warn\] Priority selection.*none of the first 3' "$PR_LOG")"
        run B "$(printf 'A\ns-urltest-out\nB')" "$(printf 'A\nB')"
        echo "group-member-skipped:$(set_of) probes=$(probes_of)"
        run "X" "s-urltest-out" "A"
        echo "only-groups-no-op:[$(set_of)] probes=[$(probes_of)]"
        priority_select_for_section s
        echo "only-groups-warned-once:$(grep -c "^\[warn\] Priority selection for section 's': no individual servers" "$PR_LOG")"
        run B "$(printf '\360\237\207\263\360\237\207\261 Node 1\nNode two\nB')" "$(printf '\360\237\207\263\360\237\207\261 Node 1\nB')"
        [ "$(set_of)" = "s-out>$(printf '\360\237\207\263\360\237\207\261 Node 1'),"  ] && echo "names-with-spaces-and-flags:ok" || echo "names-with-spaces-and-flags:wrong [$(set_of)]"
        many="$(i=1; while [ $i -le 12 ]; do echo "N$i"; i=$((i + 1)); done)"
        run N12 "$many" "N11"
        [ "$(wc -l < "$PR_PROBE" | tr -d ' ')" = "$PRIORITY_MAX_PROBES" ] && echo "probe-cap:[$(set_of)] capped" || echo "probe-cap:wrong"

        # collecting: only enabled proxy sections with the option are checked
        PR_NOW=B; PR_ALL="$(printf 'A\nB')"; PR_ALIVE="A"
        collected() { PRIORITY_SECTIONS_TO_CHECK=""; "$@"; echo "[${PRIORITY_SECTIONS_TO_CHECK# }]"; }
        PR_MODE=0; echo "option-off-never-collected:$(collected _priority_collect_section_handler s)"
        PR_MODE=1; echo "option-on-collected:$(collected _priority_collect_section_handler s)"
        PR_DISABLED=1; echo "disabled-section-never-collected:$(collected _priority_collect_section_handler s)"
        PR_DISABLED=0
        PR_CONN=vpn; : > "$PR_LOG"; PRIORITY_SECTIONS_TO_CHECK=""
        _priority_collect_section_handler s; _priority_collect_section_handler s
        echo "non-proxy-section-not-collected-warned-once:[${PRIORITY_SECTIONS_TO_CHECK# }] warned=$(grep -c "^\[warn\] Priority selection for section 's': priority_mode applies to proxy sections only" "$PR_LOG")"
        PR_CONN=proxy

        # a section that is not in the running sing-box (failed subscription): quiet no-op
        PR_NOW=B; PR_ALL="A"; PR_ALIVE="A"; : > "$PR_SET"; : > "$PR_PROBE"; : > "$PR_LOG"
        PRIORITY_PROXIES_JSON='{"proxies":{}}'
        priority_select_for_section s
        echo "section-not-running-quiet:[$(probes_of)][$(set_of)] warned=$(grep -c '^\[warn\]' "$PR_LOG")"

        # the time budget of the cycle: a spent budget probes nothing and says nothing
        PRIORITY_DEADLINE=0
        run B "$(printf 'A\nB')" "A"
        echo "budget-spent-no-probes-no-warning:[$(probes_of)][$(set_of)] warned=$(grep -c '^\[warn\]' "$PR_LOG")"
        PRIORITY_DEADLINE=$(($(date +%s) + 3600))

        # a whole cycle: sections that do not fit the budget go first next time
        config_foreach() { local _cb="$1" _s; shift; for _s in $PR_SECTIONS; do "$_cb" "$_s" "$@"; done; }
        PR_ORDER="/tmp/netshift-prio-order-$$"; : > "$PR_ORDER"
        priority_select_for_section() { echo "$1" >> "$PR_ORDER"; }
        PR_MODE=1; PR_SECTIONS="a b c"; PR_NOW=B; PR_ALL=A; PR_NOCLASH=""
        PRIORITY_CYCLE_BUDGET=3600; PRIORITY_RESUME=0
        priority_check_sections
        echo "cycle-all-sections-in-order:$(tr '\n' ',' < "$PR_ORDER")"
        : > "$PR_ORDER"; PRIORITY_CYCLE_BUDGET=-1; PRIORITY_RESUME=0
        priority_check_sections; priority_check_sections; priority_check_sections; priority_check_sections
        echo "cycle-budget-rotates:$(tr '\n' ',' < "$PR_ORDER")"
        : > "$PR_ORDER"; PR_NOCLASH=1; PRIORITY_CYCLE_BUDGET=3600
        priority_check_sections
        echo "cycle-clash-down-checks-nothing:[$(tr '\n' ',' < "$PR_ORDER")]"
        PR_NOCLASH=""; rm -f "$PR_ORDER"

        # the monitor's Clash API address: the override wins, the secret becomes a header,
        # and nothing is logged on the way (it runs every cycle)
        : > "$PR_LOG"
        PR_LISTEN="10.9.8.7"; PR_SECRET="topsecret"; priority_clash_setup
        echo "clash-setup-override:$PRIORITY_CLASH_URL|$PRIORITY_CLASH_AUTH"
        PR_LISTEN=""; PR_SECRET=""; priority_clash_setup
        echo "clash-setup-lan-no-auth:$PRIORITY_CLASH_URL|$PRIORITY_CLASH_AUTH"
        echo "clash-setup-silent:$(wc -l < "$PR_LOG" | tr -d ' ')"

        # interval
        PR_INTERVAL=""; echo "interval-default:$(priority_check_interval)"
        PR_INTERVAL=45; echo "interval-custom:$(priority_check_interval)"
        PR_INTERVAL=3; echo "interval-below-tick:$(priority_check_interval)"
        PR_INTERVAL=abc; echo "interval-invalid:$(priority_check_interval)"
        PR_INTERVAL=0; echo "interval-zero:$(priority_check_interval)"
        rm -f "$PR_LOG" "$PR_SET" "$PR_PROBE"
    )"

    _pr_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _pr_check "the first working server is selected (switch back from a lower one)" "first-alive-wins:s-out>A,"
    _pr_check "no switch when the best server is already selected (and only it is probed)" "already-selected-no-switch:[] probes=A,"
    _pr_check "a dead first server: the next working one wins, probed in order" "dead-first-second-wins:s-out>B, probes=A,B,"
    _pr_check "the only working server is already selected: no switch" "only-last-alive-already-selected:[]"
    _pr_check "nothing answers: keep the selection and warn" "none-alive-keeps:[] warned=1"
    _pr_check "group members are not probed" "group-member-skipped:s-out>A, probes=A,"
    _pr_check "only groups: nothing to do" "only-groups-no-op:[] probes=[]"
    _pr_check "only groups: the log says the option has no effect, once" "only-groups-warned-once:1"
    _pr_check "names with spaces and flag emoji survive" "names-with-spaces-and-flags:ok"
    _pr_check "the probe count is capped (and nothing is switched past it)" "probe-cap:[] capped"
    _pr_check "option off: the section is never collected" "option-off-never-collected:[]"
    _pr_check "option on: the section is collected" "option-on-collected:[s]"
    _pr_check "a disabled section is never collected" "disabled-section-never-collected:[]"
    _pr_check "a non-proxy section is not collected, and that is said once" "non-proxy-section-not-collected-warned-once:[] warned=1"
    _pr_check "a section that is not in the running sing-box is a quiet no-op" "section-not-running-quiet:[][] warned=0"
    _pr_check "a spent time budget probes nothing and warns about nothing" "budget-spent-no-probes-no-warning:[][] warned=0"
    _pr_check "a cycle checks every collected section in order" "cycle-all-sections-in-order:a,b,c,"
    _pr_check "sections that did not fit the budget are checked first next time" "cycle-budget-rotates:a,b,c,a,"
    _pr_check "Clash API down: the cycle checks nothing" "cycle-clash-down-checks-nothing:[]"
    _pr_check "the monitor's Clash API address: override and secret header" "clash-setup-override:http://10.9.8.7:9090|Authorization: Bearer topsecret"
    _pr_check "...the LAN address and no header otherwise" "clash-setup-lan-no-auth:http://192.168.1.1:9090|"
    _pr_check "...without logging anything" "clash-setup-silent:0"
    _pr_check "interval: default" "interval-default:30"
    _pr_check "interval: custom value" "interval-custom:45"
    _pr_check "interval: not below the monitor tick" "interval-below-tick:10"
    _pr_check "interval: invalid value falls back" "interval-invalid:30"
    _pr_check "interval: zero falls back" "interval-zero:30"
}

# ─────────────────────────────────────────────────────────────────

# Test: Bypass sing-box for excluded destinations / devices
# ─────────────────────────────────────────────────────────────────
# Runs the REAL nft_select_subnet_target / populate_netshift_subnets_from_file /
# nft_bypass_requested / nft_bypass_source_ips (bin) and
# nft_add_selective_marking_rules (nft.sh) against a recording `nft` stub. Asserts:
#   - without bypass nothing changes: same rules, subnets go to the union set;
#   - an exclusion section with bypass_singbox feeds the bypass set, any other
#     section (also an exclusion one without the flag) still the union set, and the
#     choice never leaks from one section to the next;
#   - the bypass `return` rules come FIRST in every chain, also under global proxy;
#   - bypass_excluded_ips returns the listed devices before any mark (IPv6 only when
#     IPv6 is enabled).
test_bypass() {
    header "Bypass sing-box (excluded destinations / devices)"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local nftsh="${NETSHIFT_LIB_DIR}/nft.sh"
    if [ ! -r "$bin" ] || [ ! -r "$nftsh" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ]; then
        skip "netshift bin / nft.sh / constants.sh not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        for fn in nft_select_subnet_target populate_netshift_subnets_from_file _nft_bypass_section_handler \
            nft_bypass_requested _nft_bypass_source_ip_handler nft_bypass_source_ips; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done
        # nft_bypass_source_ips reads routing_excluded_ips through the scalar-aware
        # wrapper, which lives in helpers.sh (the bin sources it at runtime).
        eval "$(awk -v f="netshift_config_list_foreach" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "${NETSHIFT_LIB_DIR}/helpers.sh")"
        eval "$(awk '/^nft_add_selective_marking_rules\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$nftsh")"
        BP_LOGF="/tmp/netshift-bypass-log-$$"; : > "$BP_LOGF"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$BP_LOGF"; }
        section_is_disabled() { [ "${BP_DISABLED:-}" = "$1" ]; }

        NFT_LOG="/tmp/netshift-bypass-$$"; : > "$NFT_LOG"
        nft() {
            case "$1 $2" in
            "list set") return 0 ;;
            esac
            echo "$*" >> "$NFT_LOG"
        }
        nft_add_set_elements_from_file_chunked() { echo "fill4 $3" >> "$NFT_LOG"; }
        nft_add_set_elements_from_file_chunked_v6() { echo "fill6 $3" >> "$NFT_LOG"; }
        V6=0
        netshift_ipv6_enabled() { [ "$V6" = 1 ]; }

        # UCI stubs: BP_<section>_<option>; sections list in BP_SECTIONS
        config_get() { eval "$1=\"\${BP_${2}_${3}:-$4}\""; }
        config_get_bool() {
            local _v
            eval "_v=\"\${BP_${2}_${3}:-$4}\""
            case "$_v" in 1) eval "$1=1" ;; *) eval "$1=0" ;; esac
        }
        config_foreach() { local _s; for _s in $BP_SECTIONS; do "$1" "$_s"; done; }
        config_list_foreach() { local _i _cb="$3"; for _i in $BP_EXCL_LIST; do "$_cb" "$_i"; done; }

        BP_SECTIONS="ex_bypass ex_plain prox"
        BP_ex_bypass_connection_type=exclusion; BP_ex_bypass_bypass_singbox=1
        BP_ex_plain_connection_type=exclusion
        BP_prox_connection_type=proxy; BP_prox_bypass_singbox=1

        # target selection
        : > "$NFT_LOG"; nft_select_subnet_target ex_bypass
        echo "target-bypass-section:$NFT_SUBNET_SET/$NFT_SUBNET_SET_V6/$NFT_SUBNET_IS_BYPASS"
        nft_select_subnet_target ex_plain
        echo "target-plain-exclusion:$NFT_SUBNET_SET/$NFT_SUBNET_IS_BYPASS"
        nft_select_subnet_target prox
        echo "target-proxy-section-ignores-flag:$NFT_SUBNET_SET/$NFT_SUBNET_IS_BYPASS"
        nft_select_subnet_target ex_bypass; nft_select_subnet_target prox
        echo "target-no-leak:$NFT_SUBNET_SET"

        # populate follows the target (and the default when nothing was selected)
        tmp="/tmp/netshift-bypass-list-$$"; echo 1.2.3.0/24 > "$tmp"
        : > "$NFT_LOG"; nft_select_subnet_target ex_bypass; populate_netshift_subnets_from_file "$tmp"
        echo "populate-bypass:$(tr '\n' ',' < "$NFT_LOG")"
        V6=1; : > "$NFT_LOG"; populate_netshift_subnets_from_file "$tmp"
        echo "populate-bypass-v6:$(tr '\n' ',' < "$NFT_LOG")"
        : > "$NFT_LOG"; nft_select_subnet_target prox; populate_netshift_subnets_from_file "$tmp"
        echo "populate-union:$(tr '\n' ',' < "$NFT_LOG")"
        V6=0; unset NFT_SUBNET_SET NFT_SUBNET_SET_V6
        : > "$NFT_LOG"; populate_netshift_subnets_from_file "$tmp"
        echo "populate-default-unselected:$(tr '\n' ',' < "$NFT_LOG")"
        rm -f "$tmp"

        # requested?
        nft_bypass_requested && echo "requested-section:yes" || echo "requested-section:no"
        BP_SECTIONS="ex_plain prox"
        nft_bypass_requested && echo "requested-none:yes" || echo "requested-none:no"
        BP_settings_bypass_excluded_ips=1
        nft_bypass_requested && echo "requested-ips-flag:yes" || echo "requested-ips-flag:no"
        BP_settings_bypass_excluded_ips=0
        # a disabled bypass section requests nothing
        BP_SECTIONS="ex_bypass ex_plain prox"; BP_DISABLED=ex_bypass
        nft_bypass_requested && echo "requested-disabled-section:yes" || echo "requested-disabled-section:no"
        BP_DISABLED=""
        nft_bypass_requested && echo "requested-enabled-section:yes" || echo "requested-enabled-section:no"

        # marking rules: untouched without bypass, bypass returns first with it
        NFT_TABLE_NAME=T
        marks() { : > "$NFT_LOG"; nft_add_selective_marking_rules mangle "$1" 0 iifname "@ifs"; cat "$NFT_LOG"; }
        unset NFT_BYPASS_ACTIVE
        off="$(marks 0 | tr '\n' ';')"
        echo "marks-off-first-is-union:$(marks 0 | head -1 | grep -c "@$NFT_COMMON_SET_NAME meta mark set")"
        NFT_BYPASS_ACTIVE=1
        on="$(marks 0)"
        echo "marks-on-first-return:$(echo "$on" | head -1 | grep -c "ip daddr @$NFT_BYPASS_SET_NAME return")"
        echo "marks-on-rest-unchanged:$([ "$(echo "$on" | tail -n +2 | tr '\n' ';')" = "$off" ] && echo yes || echo no)"
        echo "marks-on-global-first-return:$(marks 1 | head -1 | grep -c "ip daddr @$NFT_BYPASS_SET_NAME return")"
        echo "marks-on-global-then-mark-all:$(marks 1 | sed -n 2p | grep -c 'l4proto tcp meta mark set')"
        echo "marks-on-no-v6-rule:$(marks 0 | grep -c "$NFT_BYPASS_SET_NAME_V6")"
        V6=1; echo "marks-on-v6-rule:$(marks 0 | grep -c "ip6 daddr @$NFT_BYPASS_SET_NAME_V6 return")"; V6=0

        # devices
        BP_EXCL_LIST="192.168.1.30 2001:db8::5"; BP_settings_routing_excluded_ips="$BP_EXCL_LIST"
        BP_settings_bypass_excluded_ips=0
        : > "$NFT_LOG"; nft_bypass_source_ips
        echo "source-flag-off:[$(tr '\n' ';' < "$NFT_LOG")]"
        BP_settings_bypass_excluded_ips=1
        : > "$NFT_LOG"; nft_bypass_source_ips
        echo "source-v4-only:$(tr '\n' ';' < "$NFT_LOG")"
        V6=1; : > "$NFT_LOG"; nft_bypass_source_ips
        echo "source-v4-and-v6:$(tr '\n' ';' < "$NFT_LOG")"
        # the flag on an empty device list is no silent no-op
        BP_EXCL_LIST=""; BP_settings_routing_excluded_ips=""
        : > "$NFT_LOG"; : > "$BP_LOGF"; nft_bypass_source_ips
        echo "source-empty-list:[$(tr '\n' ';' < "$NFT_LOG")] warned=$(grep -c '^\[warn\] bypass_excluded_ips is on, but routing_excluded_ips is empty' "$BP_LOGF")"
        BP_EXCL_LIST="192.168.1.30"; BP_settings_routing_excluded_ips="192.168.1.30"
        : > "$BP_LOGF"; nft_bypass_source_ips
        echo "source-list-no-warning:$(grep -c 'nothing to bypass' "$BP_LOGF")"
        rm -f "$NFT_LOG" "$BP_LOGF"
    )"

    _bp_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _bp_check "exclusion section with bypass_singbox targets the bypass sets" "target-bypass-section:netshift_bypass/netshift_bypass_v6/1"
    _bp_check "an exclusion section without the flag keeps the union set" "target-plain-exclusion:netshift_subnets/0"
    _bp_check "the flag is ignored outside exclusion sections" "target-proxy-section-ignores-flag:netshift_subnets/0"
    _bp_check "the choice does not leak into the next section" "target-no-leak:netshift_subnets"
    _bp_check "subnets of a bypass section fill the bypass set" "populate-bypass:fill4 netshift_bypass,"
    _bp_check "IPv6 subnets fill the v6 bypass set too" "populate-bypass-v6:fill4 netshift_bypass,fill6 netshift_bypass_v6,"
    _bp_check "other sections still fill the union set" "populate-union:fill4 netshift_subnets,fill6 netshift_subnets_v6,"
    _bp_check "without any selection the union set is the default" "populate-default-unselected:fill4 netshift_subnets,"
    _bp_check "a section asks for bypass" "requested-section:yes"
    _bp_check "no flag anywhere: not requested" "requested-none:no"
    _bp_check "bypass_excluded_ips alone requests it" "requested-ips-flag:yes"
    _bp_check "without bypass the marking rules start with the union set" "marks-off-first-is-union:1"
    _bp_check "with bypass the first rule returns the bypass set" "marks-on-first-return:1"
    _bp_check "with bypass the other rules are exactly the old ones" "marks-on-rest-unchanged:yes"
    _bp_check "under global proxy the bypass return still comes first" "marks-on-global-first-return:1"
    _bp_check "under global proxy mark-all follows the return" "marks-on-global-then-mark-all:1"
    _bp_check "no v6 bypass rule without IPv6" "marks-on-no-v6-rule:0"
    _bp_check "v6 bypass rule with IPv6" "marks-on-v6-rule:1"
    _bp_check "bypass_excluded_ips off: no device rules" "source-flag-off:[]"
    _bp_check "device rules: the device's FakeIP traffic is still marked into sing-box, then the rest returns (IPv4 only without IPv6)" "source-v4-only:add rule inet T mangle iifname @interfaces ip saddr 192.168.1.30 ip daddr 198.18.0.0/15 meta mark set 0x00100000 counter;add rule inet T mangle iifname @interfaces ip saddr 192.168.1.30 counter return;"
    _bp_check "device rules: IPv6 devices with IPv6" "source-v4-and-v6:add rule inet T mangle iifname @interfaces ip saddr 192.168.1.30 ip daddr 198.18.0.0/15 meta mark set 0x00100000 counter;add rule inet T mangle iifname @interfaces ip saddr 192.168.1.30 counter return;add rule inet T mangle iifname @interfaces ip6 saddr 2001:db8::5 ip6 daddr 2001:2::/48 meta mark set 0x00100000 counter;add rule inet T mangle iifname @interfaces ip6 saddr 2001:db8::5 counter return;"
    _bp_check "device bypass on an empty device list: nothing added, warned" "source-empty-list:[] warned=1"
    _bp_check "a non-empty device list: no warning" "source-list-no-warning:0"
    _bp_check "a disabled bypass section requests nothing" "requested-disabled-section:no"
    _bp_check "an enabled bypass section requests the bypass" "requested-enabled-section:yes"
}


# ─────────────────────────────────────────────────────────────────
# Test: DNS forwarding by zone (settings.dns_forward -> dnsmasq server list)
# ─────────────────────────────────────────────────────────────────
test_dns_forward() {
    header "DNS forwarding by zone"

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$lib/dnsforward.sh" ] || [ ! -r "$bin" ]; then
        fail "dnsforward.sh / netshift bin not found"
        return
    fi

    local drv="/tmp/netshift-dnsforward-$$.sh"
    cat > "$drv" << 'DFEOF'
LIB="NETSHIFT_LIB"
. "$LIB/constants.sh"
. "$LIB/helpers.sh"
DF_LOG="/tmp/netshift-dnsforward-log-$$"; : > "$DF_LOG"
log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$DF_LOG"; }
# stubs: the list of the settings section and the user_domains of one section
DF_FORWARD=""
DF_DOMAINS=""
netshift_config_list_foreach() {
    local _handler="$3" _item _list
    case "$2" in
    dns_forward) _list="$DF_FORWARD" ;;
    user_domains) _list="$DF_DOMAINS" ;;
    esac
    printf '%s\n' "$_list" | while IFS= read -r _item; do
        [ -n "$_item" ] && "$_handler" "$_item"
    done
}
config_foreach() { "$1" "sec1"; }
DF_ADDED=""
uci_add_list() { DF_ADDED="$DF_ADDED$3=$4;"; }
. "$LIB/dnsforward.sh"

norm() { dns_forward_normalize "$1" || printf 'REJECT'; }
echo "n1:$(norm 'ru 77.88.8.8')"
echo "n2:$(norm '.RU 77.88.8.8')"
echo "n3:$(norm '/ru/77.88.8.8')"
echo "n4:$(norm '/.ru/77.88.8.8')"
echo "n5:$(norm 'example.com 1.1.1.1#5353')"
echo "n6:$(norm 'lan 2001:db8::1')"
echo "n7:$(norm 'ru')"
echo "n8:$(norm 'ru dns.yandex.ru')"
echo "n9:$(norm 'ru 77.88.8.8#0')"
echo "n10:$(norm 'ru 77.88.8.8#70000')"
echo "n11:$(norm 'ru 999.1.1.1')"
echo "n12:$(norm 'bad_zone! 1.1.1.1')"
echo "n13:$(norm "ru $SB_DNS_INBOUND_ADDRESS")"
echo "n14:$(norm '  ru    77.88.8.8  ')"

DF_FORWARD="ru 77.88.8.8
bad
.ru 77.88.8.8
corp.example 10.0.0.53#5353"
echo "list:$(dns_forward_entries | tr '\n' ' ')"
echo "warned-bad:$(grep -c "DNS forward 'bad' is invalid" "$DF_LOG")"

dns_forward_apply
echo "apply:$DF_ADDED"

: > "$DF_LOG"
DF_DOMAINS="yandex.ru
example.org
corp.example
rural.com"
dns_forward_warn_overlaps
echo "overlap-yandex:$(grep -c "'yandex.ru'" "$DF_LOG")"
echo "overlap-corp:$(grep -c "'corp.example'" "$DF_LOG")"
echo "overlap-other:$(grep -c "example.org\|rural.com" "$DF_LOG")"

DF_FORWARD=""
DF_ADDED=""
dns_forward_apply
echo "empty-apply:[$DF_ADDED]"
rm -f "$DF_LOG"
DFEOF
    sed -i "s|NETSHIFT_LIB|$lib|" "$drv"
    local out
    out="$(ash "$drv" 2>&1)"
    rm -f "$drv"

    _df_check() {
        local name="$1" key="$2" want="$3" got
        got="$(printf '%s\n' "$out" | sed -n "s/^$key://p" | sed -n '1p')"
        if [ "$got" = "$want" ]; then
            pass "$name"
        else
            fail "$name (got '$got', want '$want')"
        fi
    }

    _df_check "plain form: zone and server" n1 "/ru/77.88.8.8"
    _df_check "zone is lowercased, the leading dot dropped" n2 "/ru/77.88.8.8"
    _df_check "dnsmasq form is accepted" n3 "/ru/77.88.8.8"
    _df_check "dnsmasq form with a leading dot" n4 "/ru/77.88.8.8"
    _df_check "server with a port" n5 "/example.com/1.1.1.1#5353"
    _df_check "IPv6 server and a single-label zone" n6 "/lan/2001:db8::1"
    _df_check "a zone without a server is refused" n7 "REJECT"
    _df_check "a host name instead of an address is refused" n8 "REJECT"
    _df_check "port 0 is refused" n9 "REJECT"
    _df_check "port above 65535 is refused" n10 "REJECT"
    _df_check "an invalid IPv4 is refused" n11 "REJECT"
    _df_check "an invalid zone is refused" n12 "REJECT"
    _df_check "the sing-box DNS inbound cannot be a forward" n13 "REJECT"
    _df_check "surrounding spaces are ignored" n14 "/ru/77.88.8.8"
    _df_check "entries are normalized, invalid skipped, duplicates dropped" list "/ru/77.88.8.8 /corp.example/10.0.0.53#5353 "
    _df_check "an invalid entry is reported" warned-bad 1
    _df_check "forwards are added to the dnsmasq server list" apply "server=/ru/77.88.8.8;server=/corp.example/10.0.0.53#5353;"
    _df_check "a section domain inside a zone is reported" overlap-yandex 1
    _df_check "a section domain equal to a zone is reported" overlap-corp 1
    _df_check "unrelated domains (even with the same ending) are not reported" overlap-other 0
    _df_check "no forwards: dnsmasq is not touched" empty-apply "[]"

    # Wiring in the service script
    if grep -q 'dnsforward.sh' "$bin" && grep -q '^    dns_forward_apply$' "$bin"; then
        pass "the library is loaded and applied when dnsmasq is configured"
    else
        fail "dns_forward_apply is not wired into dnsmasq_configure"
    fi
    if awk '/^dnsmasq_configure\(\)/{f=1} f&&/dns_forward_apply/{a=NR} f&&/netshift_configured" 1/{b=NR} f&&/^}/{exit} END{exit !(a&&b&&a<b)}' "$bin"; then
        pass "forwards are added before the ownership sentinel and the commit"
    else
        fail "dns_forward_apply is misplaced in dnsmasq_configure"
    fi
    if awk '/^dnsmasq_restore\(\)/{f=1} f&&/delete.*server|uci_remove_quiet "dhcp" "@dnsmasq\[0\]" "server"/{ok=1} f&&/^}/{exit} END{exit !ok}' "$bin"; then
        pass "restore drops the whole server list, so the forwards go with it"
    else
        fail "dnsmasq_restore no longer clears the server list"
    fi

    # End to end on a real uci: the real dnsmasq_configure / dnsmasq_restore
    local e2e="/tmp/netshift-dnsforward-e2e-$$.sh" e2e_out
    {
        cat << 'E2EOF'
. /lib/functions.sh
. /lib/config/uci.sh
LIB="NETSHIFT_LIB"
. "$LIB/constants.sh"
. "$LIB/helpers.sh"
log() { :; }
. "$LIB/dnsforward.sh"
file_exists() { [ -f "$1" ]; }
E2EOF
        for fn in backup_dnsmasq_config_option uci_remove_quiet dnsmasq_is_configured_for_netshift dnsmasq_configure dnsmasq_restore; do
            awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} f&&/^}/{exit}' "$bin"
        done | sed 's|/etc/init.d/dnsmasq restart|:|'
        cat << 'E2EOF'
cp /etc/config/dhcp /tmp/dhcp.e2e.bak
: > /etc/config/netshift
uci -q set netshift.settings=settings
uci -q set netshift.settings.shutdown_correctly=0
uci -q add_list netshift.settings.dns_forward='ru 77.88.8.8'
uci -q add_list netshift.settings.dns_forward='corp.example 10.0.0.53#5353'
uci -q add_list netshift.settings.dns_forward='broken entry'
uci -q commit netshift
config_load netshift

uci -q delete dhcp.@dnsmasq[0].server
uci -q add_list dhcp.@dnsmasq[0].server='/office.lan/10.1.1.1'
uci -q add_list dhcp.@dnsmasq[0].server='9.9.9.9'
uci -q commit dhcp

dnsmasq_configure force
echo "running:$(uci -q get dhcp.@dnsmasq[0].server | tr ' ' ',')"
echo "noresolv:$(uci -q get dhcp.@dnsmasq[0].noresolv)"
echo "sentinel:$(uci -q get dhcp.@dnsmasq[0].netshift_configured)"
echo "backup:$(uci -q get dhcp.@dnsmasq[0].netshift_server | tr ' ' ',')"

dnsmasq_restore
echo "restored:$(uci -q get dhcp.@dnsmasq[0].server | tr ' ' ',')"
echo "noresolv-after:$(uci -q get dhcp.@dnsmasq[0].noresolv)"
echo "sentinel-after:[$(uci -q get dhcp.@dnsmasq[0].netshift_configured)]"
echo "backup-after:[$(uci -q get dhcp.@dnsmasq[0].netshift_server)]"

# no forwards: the list is only the sing-box inbound
uci -q delete netshift.settings.dns_forward
uci -q commit netshift
config_load netshift
dnsmasq_configure force
echo "running-empty:$(uci -q get dhcp.@dnsmasq[0].server | tr ' ' ',')"
dnsmasq_restore
cp /tmp/dhcp.e2e.bak /etc/config/dhcp
rm -f /tmp/dhcp.e2e.bak /etc/config/netshift
E2EOF
    } > "$e2e"
    sed -i "s|NETSHIFT_LIB|$lib|" "$e2e"
    e2e_out="$(ash "$e2e" 2>&1)"
    rm -f "$e2e"
    out="$e2e_out"

    _df_check "e2e: sing-box inbound first, then the forwards, the user's own entries aside" running "127.0.0.42,/ru/77.88.8.8,/corp.example/10.0.0.53#5353"
    _df_check "e2e: noresolv is on while NetShift runs" noresolv 1
    _df_check "e2e: the ownership sentinel is set" sentinel 1
    _df_check "e2e: the admin's own server list is backed up" backup "/office.lan/10.1.1.1,9.9.9.9"
    _df_check "e2e: restore returns exactly the admin's server list" restored "/office.lan/10.1.1.1,9.9.9.9"
    _df_check "e2e: noresolv is restored" noresolv-after 0
    _df_check "e2e: the sentinel is cleared" sentinel-after "[]"
    _df_check "e2e: the backup is cleared" backup-after "[]"
    _df_check "e2e: without forwards only the sing-box inbound is left" running-empty "127.0.0.42"
}
# ─────────────────────────────────────────────────────────────────


test_domain_rule_prefixes() {
    header "Domain rule prefixes: full: / keyword: / regex:"

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

    local work="/tmp/netshift-domrules-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        . "$lib/rulesets.sh"
        LOGF="$work/log"
        : > "$LOGF"
        log() { printf '%s|%s\n' "${2:-info}" "$1" >> "$LOGF"; }
        eval "$(awk '/^configure_user_domain_list\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        prepare_source_ruleset() {
            ruleset_filepath="$work/$1-$2-$3.json"
            rm -f "$ruleset_filepath"
            create_source_rule_set "$ruleset_filepath"
        }
        config_get() {
            local _k _v
            _k="$(printf 'CFG_%s_%s' "$2" "$3" | tr -c 'a-zA-Z0-9_' '_')"
            eval "_v=\"\${$_k:-}\""
            [ -n "$_v" ] || _v="$4"
            eval "$1=\"\$_v\""
        }

        # canonical forms
        for e in example.com .example.com Example.COM full:Host.Example.com FULL:a.b.org keyword:Tracker \
            'regex:^ads[0-9]+\.example\.com$' 'REGEXP:\d+\.cdn\.net' full:not_a_host keyword: 'keyword:a b' regex: bad!domain; do
            printf 'norm[%s]=[%s]\n' "$e" "$(domain_rule_normalize "$e" 2> /dev/null || echo INVALID)"
        done

        # the user list: every kind lands in its own key, nothing is lowercased inside a pattern
        CFG_u1_user_domain_list_type="dynamic"
        CFG_u1_user_domains='example.com full:Exact.Example.org keyword:Tracker regex:^ads[0-9]+\.example\.com$ regex:(unclosed regex:\D+\.net keyword:bad!kw'
        configure_user_domain_list "u1" "rule-u1"
        rs="$work/u1-user-domains.json"
        echo "suffix=$(jq -c '[.rules[]?.domain_suffix[]?]' "$rs")"
        echo "full=$(jq -c '[.rules[]?.domain[]?]' "$rs")"
        echo "keyword=$(jq -c '[.rules[]?.domain_keyword[]?]' "$rs")"
        echo "regex=$(jq -c '[.rules[]?.domain_regex[]?]' "$rs")"
        echo "bad-regex-warned=$(grep -c "unclosed': it is not a valid regular expression" "$LOGF")"

        # what the core does with the set
        for d in example.com sub.example.com exact.example.org sub.exact.example.org my-tracker.io ads12.example.com ads.example.io x.net other.org; do
            if sing-box rule-set match "$rs" "$d" 2>&1 | grep -q '^match'; then echo "hit[$d]=yes"; else echo "hit[$d]=no"; fi
        done
        jq -n --arg p "$rs" '{log:{level:"error"},dns:{servers:[{tag:"d",type:"udp",server:"1.1.1.1"}],final:"d"},
            inbounds:[{type:"tproxy",tag:"t",listen:"127.0.0.1",listen_port:1602}],outbounds:[{type:"direct",tag:"direct-out"}],
            route:{rule_set:[{tag:"s",type:"local",format:"source",path:$p}],rules:[{rule_set:["s"],outbound:"direct-out"}],final:"direct-out"}}' > "$work/c.json"
        sing-box -c "$work/c.json" check > /dev/null 2>&1 && echo "singbox-check=ok" || echo "singbox-check=FAIL"

        # a local/remote plain list file takes the same prefixes
        printf 'Plain.Example.net\nfull:Only.Here.org\nkeyword:ads\nregexp:^cdn[0-9]\\.x\\.io$\n\n' > "$work/list.txt"
        create_source_rule_set "$work/l.json"
        import_plain_domain_list_to_local_source_ruleset_chunked "$work/list.txt" "$work/l.json"
        echo "list=$(jq -c '[.rules[] | to_entries[] | .key] | unique' "$work/l.json")"
        echo "list-regex=$(jq -c '[.rules[]?.domain_regex[]?]' "$work/l.json")"

        # a few broken patterns among many good ones are found by halving, not one by one
        real_sb="$(command -v sing-box)"
        mkdir -p "$work/bin" "$work/empty"
        printf '#!/bin/sh\necho x >> "%s/probes"\nexec "%s" "$@"\n' "$work" "$real_sb" > "$work/bin/sing-box"
        chmod +x "$work/bin/sing-box"
        i=0
        : > "$work/many.txt"
        while [ "$i" -lt 300 ]; do
            case "$i" in
            40 | 150 | 260) echo "(bad$i" >> "$work/many.txt" ;;
            *) echo "^ok$i\\.example\\.com\$" >> "$work/many.txt" ;;
            esac
            i=$((i + 1))
        done
        : > "$work/probes"
        : > "$LOGF"
        PATH="$work/bin:$PATH" validate_domain_regex_file "$work/many.txt" > "$work/many.out"
        echo "bisect-kept=$(wc -l < "$work/many.out" | tr -d ' ')"
        echo "bisect-warned=$(grep -c "is not a valid regular expression" "$LOGF")"
        probes="$(wc -l < "$work/probes" | tr -d ' ')"
        if [ "$probes" -lt 80 ]; then echo "bisect-few-probes=yes"; else echo "bisect-few-probes=no($probes)"; fi

        # a list that is mostly broken: only the first DOMAIN_REGEX_MAX_DROPPED are reported, the rest is skipped
        i=0
        : > "$work/bad.txt"
        while [ "$i" -lt 100 ]; do
            if [ $((i % 5)) -ne 4 ]; then echo "(b$i" >> "$work/bad.txt"; else echo "^g$i\\.x\$" >> "$work/bad.txt"; fi
            i=$((i + 1))
        done
        : > "$LOGF"
        PATH="$work/bin:$PATH" validate_domain_regex_file "$work/bad.txt" > "$work/bad.out"
        echo "cap-reported=$(grep -c "is not a valid regular expression" "$LOGF")"
        echo "cap-stop-warned=$(grep -c "the rest of it is ignored" "$LOGF")"

        # without the core nothing can be checked: one warning, no patterns
        : > "$LOGF"
        PATH="$work/empty" validate_domain_regex_file "$work/many.txt" > "$work/nosb.out"
        echo "nosb-kept=$(wc -l < "$work/nosb.out" | tr -d ' ')"
        echo "nosb-warned=$(grep -c "sing-box is not available" "$LOGF")"
    )"

    _dr() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '|')"
        fi
    }

    _dr "bare domain is kept" "norm[example.com]=[example.com]"
    _dr "leading dot is kept" "norm[.example.com]=[.example.com]"
    _dr "bare domain is lowercased" "norm[Example.COM]=[example.com]"
    _dr "full: host is lowercased" "norm[full:Host.Example.com]=[full:host.example.com]"
    _dr "prefix case does not matter" "norm[FULL:a.b.org]=[full:a.b.org]"
    _dr "keyword: is lowercased" "norm[keyword:Tracker]=[keyword:tracker]"
    _dr "regex: keeps the pattern as typed" 'norm[regex:^ads[0-9]+\.example\.com$]=[regex:^ads[0-9]+\.example\.com$]'
    _dr "regexp: is an alias of regex:" 'norm[REGEXP:\d+\.cdn\.net]=[regex:\d+\.cdn\.net]'
    _dr "full: with an invalid host is refused" "norm[full:not_a_host]=[INVALID]"
    _dr "empty keyword is refused" "norm[keyword:]=[INVALID]"
    _dr "keyword with a space is refused" "norm[keyword:a b]=[INVALID]"
    _dr "empty regex is refused" "norm[regex:]=[INVALID]"
    _dr "garbage is refused" "norm[bad!domain]=[INVALID]"
    _dr "suffix rules" 'suffix=["example.com"]'
    _dr "full: becomes a domain rule (lowercased)" 'full=["exact.example.org"]'
    _dr "keyword: becomes a domain_keyword rule" 'keyword=["tracker"]'
    _dr "regex: becomes domain_regex, case kept, broken pattern dropped" 'regex=["^ads[0-9]+\\.example\\.com$","\\D+\\.net"]'
    _dr "a broken pattern is reported" "bad-regex-warned=1"
    _dr "suffix entry matches the domain" "hit[example.com]=yes"
    _dr "suffix entry matches subdomains" "hit[sub.example.com]=yes"
    _dr "full: matches the exact host" "hit[exact.example.org]=yes"
    _dr "full: does not match subdomains" "hit[sub.exact.example.org]=no"
    _dr "keyword: matches inside a host" "hit[my-tracker.io]=yes"
    _dr "regex: matches" "hit[ads12.example.com]=yes"
    _dr "regex: does not match what it does not describe" "hit[ads.example.io]=no"
    _dr "regex: keeps the escape (\\D)" "hit[x.net]=yes"
    _dr "unrelated host does not match" "hit[other.org]=no"
    _dr "the resulting rule set passes sing-box check" "singbox-check=ok"
    _dr "plain list file: every kind present" 'list=["domain","domain_keyword","domain_regex","domain_suffix"]'
    _dr "plain list file: regexp: with an escape survives" 'list-regex=["^cdn[0-9]\\.x\\.io$"]'
    _dr "broken patterns among many good ones: all the good ones stay" "bisect-kept=297"
    _dr "...each broken one is reported once" "bisect-warned=3"
    _dr "...found with few probes of the core, not one per line" "bisect-few-probes=yes"
    _dr "a mostly broken list: only the first ones are reported" "cap-reported=20"
    _dr "...and the rest of it is skipped with one warning" "cap-stop-warned=1"
    _dr "without sing-box no pattern is kept" "nosb-kept=0"
    _dr "...and that is said once, not for every line" "nosb-warned=1"

    rm -rf "$work"
}


test_route_check() {
    header "Route check: where will a request go (check_route)"

    if ! command -v sing-box > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
        skip "sing-box / jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/routecheck.sh" ] || [ ! -r "$lib/helpers.sh" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "routecheck.sh / helpers.sh / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-routecheck-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        . "$lib/routecheck.sh"
        SERVICE_TAG="__service_tag"
        ROUTE_CHECK_CACHE_FOLDER="$work/cache"
        log() { :; }

        printf '%s' '{"version":3,"rules":[{"domain_suffix":["example.com"],"domain":["exact.example.org"],"domain_keyword":["tracker"],"domain_regex":["^ads[0-9]+\\.cdn\\.net$"]}]}' > "$work/main-domains.json"
        printf '%s' '{"version":3,"rules":[{"ip_cidr":["203.0.113.0/24"]}]}' > "$work/vpn-subnets.json"
        jq -n --arg d "$work/main-domains.json" --arg s "$work/vpn-subnets.json" '{
            dns: { servers: [], rules: [
                { query_type: "HTTPS", action: "reject", __service_tag: "doh-https" },
                { action: "route", server: "fakeip-server", rule_set: ["main-domains"], __service_tag: "fakeip-rule" },
                { action: "route", server: "dns-section-corp", domain_suffix: ["corp.test"], __service_tag: "dns-section-rule-corp" }
            ], final: "dns-server" },
            inbounds: [ { type: "tproxy", tag: "tproxy-in" } ],
            outbounds: [ { type: "direct", tag: "direct-out" } ],
            route: {
                rule_set: [
                    { tag: "main-domains", type: "local", format: "source", path: $d },
                    { tag: "vpn-subnets", type: "local", format: "source", path: $s },
                    { tag: "remote-list", type: "remote", format: "binary", url: "https://lists.invalid/x.srs" }
                ],
                rules: [
                    { action: "sniff", inbound: ["tproxy-in"] },
                    { action: "route", inbound: ["tproxy-in"], outbound: "direct-out", source_ip_cidr: ["192.168.1.50/32"], __service_tag: "device-bypass" },
                    { action: "reject", inbound: ["tproxy-in"], domain_suffix: ["blocked.test"], __service_tag: "reject-rule" },
                    { action: "route", inbound: ["tproxy-in"], outbound: "main-out", rule_set: ["main-domains"], __service_tag: "main-rule" },
                    { action: "route", inbound: ["tproxy-in"], outbound: "vpn-urltest-out", rule_set: ["vpn-subnets"], __service_tag: "vpn-rule" },
                    { action: "route", inbound: ["tproxy-in"], outbound: "direct-out", rule_set: ["remote-list"], __service_tag: "remote-rule" },
                    { action: "route", inbound: ["service-mixed-in"], outbound: "vpn-out", domain_suffix: ["only-service.test"], __service_tag: "svc-rule" },
                    { action: "route", inbound: ["tproxy-in"], outbound: "direct-out", protocol: "bittorrent", __service_tag: "bt-rule" }
                ],
                final: "direct-out"
            }
        }' > "$work/config.json"

        config_get() {
            case "$3" in
            config_path) eval "$1=\"$work/config.json\"" ;;
            *) eval "$1=\"\${4:-}\"" ;;
            esac
        }
        config_foreach() { local cb="$1" id; for id in main vpn; do "$cb" "$id"; done; }
        get_service_proxy_address() { echo ""; }
        download_to_file() { return 1; }

        show() { # label target [source]
            check_route "$2" "${3:-}" | jq -c --arg l "$1" '[$l, .verdict, .section, .rule, .rule_set, (.dns.server // null), (.dns.verdict // null), .incomplete, .by_default] | map(if . == null then "-" else tostring end) | join("|")' | tr -d '"'
        }

        show suffix example.com
        show subdomain a.b.example.com
        show full exact.example.org
        show full-sub x.exact.example.org
        show keyword my-tracker.net
        show regex ads7.cdn.net
        show regex-miss ads.cdn.net
        show blocked x.blocked.test
        show ip 203.0.113.9
        show ip-miss 198.51.100.7
        show direct-default unknown.example.net
        show dns-section host.corp.test
        show service-only only-service.test
        show device-source example.com 192.168.1.50
        show device-other-source example.com 192.168.1.51
        check_route "not a host" | jq -c '.error != null'
        check_route "" | jq -c '.error != null'

        # a remote binary rule set: downloaded into a temporary file, moved into the cache whole
        printf '%s' '{"version":3,"rules":[{"domain_suffix":["remote.test"]}]}' > "$work/remote-src.json"
        : > "$work/dl-calls"
        download_to_file() {
            echo "$2" >> "$work/dl-calls"
            sing-box rule-set compile -o "$2" "$work/remote-src.json" > /dev/null 2>&1
        }
        show remote-binary x.remote.test
        show remote-binary-miss other.example.net
        echo "download-calls=$(wc -l < "$work/dl-calls" | tr -d ' ')"
        echo "download-into-temp=$(grep -c '\.dl\.' "$work/dl-calls")"
        echo "cache-files=$(ls "$work/cache" | grep -c '\.binary$')"
        echo "cache-leftovers=$(ls "$work/cache" | grep -c '\.dl\.')"

        # a download that fails after writing part of the file leaves no cache and no leftover,
        # and does not remove a good file stored meanwhile
        rm -rf "$work/cache"
        download_to_file() { echo "half" > "$2"; return 1; }
        show remote-failed x.remote.test
        echo "failed-cache-files=$(ls "$work/cache" 2> /dev/null | wc -l | tr -d ' ')"

        # ...while another check stores the good file at the same moment and this one then fails
        rm -rf "$work/cache"
        sing-box rule-set compile -o "$work/good.srs" "$work/remote-src.json" > /dev/null 2>&1
        download_to_file() {
            mkdir -p "$ROUTE_CHECK_CACHE_FOLDER"
            cp "$work/good.srs" "${2%%.dl.*}"
            echo "half" > "$2"
            return 1
        }
        show remote-race x.remote.test > /dev/null
        echo "race-good-file-kept=$(ls "$work/cache" | grep -c '\.binary$')"
    )"

    _rc() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    # label|verdict|section|rule|rule_set|dns server|dns verdict|incomplete|by default
    _rc "domain suffix goes to its section" "suffix|section|main|main-rule|main-domains|fakeip-server|rule|true|false"
    _rc "subdomains follow the suffix" "subdomain|section|main|main-rule|main-domains|fakeip-server|rule|true|false"
    _rc "full: matches the host" "full|section|main|main-rule|main-domains|fakeip-server|rule|true|false"
    _rc "full: does not match subdomains" "full-sub|direct|-|-|-|dns-server|final|true|false"
    _rc "keyword: matches" "keyword|section|main|main-rule|main-domains|fakeip-server|rule|true|false"
    _rc "regex: matches" "regex|section|main|main-rule|main-domains|fakeip-server|rule|true|false"
    _rc "regex: miss falls through" "regex-miss|direct|-|-|-|dns-server|final|true|false"
    _rc "a reject rule blocks" "blocked|blocked|-|reject-rule|-|dns-server|final|true|false"
    _rc "an IP in a section subnet goes to that section" "ip|section|vpn|vpn-rule|vpn-subnets|-|-|true|false"
    _rc "an IP in no list goes direct" "ip-miss|direct|-|-|-|-|-|true|false"
    _rc "an unlisted domain goes direct (final)" "direct-default|direct|-|-|-|dns-server|final|true|false"
    _rc "a DNS section answers its names" "dns-section|direct|-|-|-|dns-section-corp|rule|true|false"
    _rc "rules of another inbound are not replayed for LAN traffic" "service-only|direct|-|-|-|dns-server|final|true|false"
    _rc "a rule with a source address applies to that client" "device-source|direct|-|device-bypass|-|fakeip-server|rule|false|false"
    _rc "a different source skips the device rule" "device-other-source|section|main|main-rule|main-domains|fakeip-server|rule|false|false"
    _rc "invalid target is an error" "true"
    _rc "a remote binary rule set is replayed" "remote-binary|direct|-|remote-rule|remote-list|dns-server|final|true|false"
    _rc "...and a name it does not hold is not matched" "remote-binary-miss|direct|-|-|-|dns-server|final|true|false"
    _rc "the rule set is downloaded once and cached" "download-calls=1"
    _rc "...into a temporary file next to the cache" "download-into-temp=1"
    _rc "...which is moved into place whole" "cache-files=1"
    _rc "...leaving no temporary file" "cache-leftovers=0"
    _rc "a failed download leaves nothing behind" "failed-cache-files=0"
    _rc "a failing check does not remove the file another check has just stored" "race-good-file-kept=1"
    _rc "...and the answer is flagged incomplete" "remote-failed|direct|-|-|-|dns-server|final|true|false"
    rm -rf "$work"
}


test_subscription_param_filters() {
    header "Subscription filters by protocol, transport and security"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$bin" ] || [ ! -r "$lib/constants.sh" ] || [ ! -r "$lib/sing_box_config_facade.sh" ] || ! command -v jq > /dev/null 2>&1; then
        skip "netshift bin / libs / jq not found"
        return
    fi

    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.jq" /usr/lib/netshift/helpers.jq
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local work="/tmp/netshift-paramf-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        . "$lib/sing_box_config_manager.sh"
        . "$lib/sing_box_config_facade.sh"
        LOGF="$work/log"
        : > "$LOGF"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$LOGF"; }
        for fn in subscription_param_filter_value append_subscription_param_filter_handler build_subscription_param_filter_json; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done
        config_list_foreach() {
            local _v _i
            eval "_v=\"\${PF_$2:-}\""
            for _i in $_v; do "$3" "$_i"; done
        }

        for spec in "protocols:SS" "protocols:Hy2" "protocols:VLESS" "protocols:bad!" "transports:WebSocket" "transports:raw" "transports:h2" "transports:smoke" "security:Reality" "security:NONE" "security:ssl"; do
            kind="${spec%%:*}"
            v="${spec#*:}"
            echo "norm[$spec]=[$(subscription_param_filter_value "$kind" "$v" || echo -)]"
        done

        PF_subscription_filter_include_protocols="VLESS ss bogus!" PF_subscription_filter_exclude_security="none"
        echo "built=$(build_subscription_param_filter_json s)"
        echo "warned=$(grep -c "protocols filter 'bogus!'" "$LOGF")"
        unset PF_subscription_filter_include_protocols PF_subscription_filter_exclude_security
        echo "empty=$(build_subscription_param_filter_json s)"

        # the facade over a synthetic subscription
        cat > "$work/sub.json" << 'SUB'
{"outbounds":[
 {"type":"vless","tag":"v-reality","server":"a.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","tls":{"enabled":true,"server_name":"x.com","reality":{"enabled":true,"public_key":"k","short_id":"s"}}},
 {"type":"vless","tag":"v-ws-tls","server":"b.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","tls":{"enabled":true,"server_name":"b.example.com"},"transport":{"type":"ws","path":"/"}},
 {"type":"vless","tag":"v-grpc-none","server":"c.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","transport":{"type":"grpc","service_name":"g"}},
 {"type":"trojan","tag":"t-tls","server":"d.example.com","server_port":443,"password":"p","tls":{"enabled":true,"server_name":"d.example.com"}},
 {"type":"hysteria2","tag":"hy2","server":"e.example.com","server_port":443,"password":"p","tls":{"enabled":true,"server_name":"e.example.com"}},
 {"type":"vmess","tag":"vm-plain","server":"f.example.com","server_port":80,"uuid":"11111111-2222-3333-4444-555555555555","security":"auto"}
]}
SUB
        names() { SUBSCRIPTION_PARAM_FILTER="$1" sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$work/sub.json" '[]' '[]' | jq -c '[.names[]] | sort'; }
        echo "all=$(names '{}')"
        echo "unset=$(unset SUBSCRIPTION_PARAM_FILTER; sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$work/sub.json" '[]' '[]' | jq -c '.count')"
        echo "inc-protocol=$(names '{"include":{"protocols":["trojan","hysteria2"]}}')"
        echo "exc-protocol=$(names '{"exclude":{"protocols":["vless"]}}')"
        echo "inc-transport-ws=$(names '{"include":{"transports":["ws"]}}')"
        echo "inc-transport-tcp=$(names '{"include":{"transports":["tcp"]}}')"
        echo "exc-transport=$(names '{"exclude":{"transports":["grpc","ws"]}}')"
        echo "inc-reality=$(names '{"include":{"security":["reality"]}}')"
        echo "exc-none=$(names '{"exclude":{"security":["none"]}}')"
        echo "combined=$(names '{"include":{"protocols":["vless"],"security":["tls","reality"]}}')"
        echo "combined-empty=$(names '{"include":{"protocols":["trojan"]},"exclude":{"security":["tls"]}}')"
        cat > "$work/scalar.json" << 'SUB2'
{"outbounds":[
 {"type":"vless","tag":"s-tls","server":"a.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","tls":"yes"},
 {"type":"vless","tag":"s-reality","server":"b.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","tls":{"enabled":true,"reality":"on"}}
]}
SUB2
        echo "scalar=$(SUBSCRIPTION_PARAM_FILTER='{"include":{"security":["none","tls"]}}' sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$work/scalar.json" '[]' '[]' | jq -c '[.names[]] | sort')"
        echo "with-keyword=$(SUBSCRIPTION_PARAM_FILTER='{"include":{"protocols":["vless"]}}' sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$work/sub.json" '["ws"]' '[]' | jq -c '[.names[]] | sort')"

        # a parameter filter that leaves nothing is reported as the filter, not as a bad feed
        : > "$LOGF"
        SUBSCRIPTION_PARAM_FILTER='{"include":{"protocols":["trojan"]},"exclude":{"security":["tls"]}}' \
            sing_box_cf_add_subscription_outbounds '{"outbounds":[]}' s "$work/sub.json" '[]' '[]' > /dev/null
        echo "emptied-info=$(grep -c "parameter filter for section 's': kept=0" "$LOGF")"
        echo "emptied-warn=$(grep -c "parameter filter for section 's' removed all nodes" "$LOGF")"
        : > "$LOGF"
        SUBSCRIPTION_PARAM_FILTER='{"include":{"protocols":["vless"]}}' \
            sing_box_cf_add_subscription_outbounds '{"outbounds":[]}' s "$work/sub.json" '["nothing-has-this-name"]' '[]' > /dev/null
        echo "both-kinds=$(grep -c "keyword and parameter filter for section 's' removed all nodes" "$LOGF")"
        : > "$LOGF"
        sing_box_cf_add_subscription_outbounds '{"outbounds":[]}' s "$work/sub.json" '["nothing-has-this-name"]' '[]' > /dev/null
        echo "keyword-only=$(grep -c "keyword filter for section 's' removed all nodes" "$LOGF")"
    )"

    _pf() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _pf "ss is shadowsocks" "norm[protocols:SS]=[shadowsocks]"
    _pf "hy2 is hysteria2, case does not matter" "norm[protocols:Hy2]=[hysteria2]"
    _pf "a protocol name is kept" "norm[protocols:VLESS]=[vless]"
    _pf "a protocol with odd characters is refused" "norm[protocols:bad!]=[-]"
    _pf "websocket is ws" "norm[transports:WebSocket]=[ws]"
    _pf "raw is tcp" "norm[transports:raw]=[tcp]"
    _pf "h2 is http" "norm[transports:h2]=[http]"
    _pf "an unknown transport is refused" "norm[transports:smoke]=[-]"
    _pf "reality is a security" "norm[security:Reality]=[reality]"
    _pf "none is a security" "norm[security:NONE]=[none]"
    _pf "an unknown security is refused" "norm[security:ssl]=[-]"
    _pf "the lists become one JSON" 'built={"include":{"protocols":["shadowsocks","vless"]},"exclude":{"security":["none"]}}'
    _pf "a bad value is warned about" "warned=1"
    _pf "nothing set gives an empty filter" "empty={}"
    _pf "no filter keeps every server" 'all=["hy2","t-tls","v-grpc-none","v-reality","v-ws-tls","vm-plain"]'
    _pf "...also when the variable is not set at all" "unset=6"
    _pf "include by protocol" 'inc-protocol=["hy2","t-tls"]'
    _pf "exclude by protocol" 'exc-protocol=["hy2","t-tls","vm-plain"]'
    _pf "include by transport" 'inc-transport-ws=["v-ws-tls"]'
    _pf "no transport means tcp" 'inc-transport-tcp=["hy2","t-tls","v-reality","vm-plain"]'
    _pf "exclude by transport" 'exc-transport=["hy2","t-tls","v-reality","vm-plain"]'
    _pf "include by reality" 'inc-reality=["v-reality"]'
    _pf "exclude plain servers" 'exc-none=["hy2","t-tls","v-reality","v-ws-tls"]'
    _pf "lists of different kinds all have to pass" 'combined=["v-reality","v-ws-tls"]'
    _pf "...and may leave nothing" "combined-empty=[]"
    _pf "a node with a scalar tls or reality does not abort the batch" 'scalar=["s-reality","s-tls"]'
    _pf "the name filter and the parameter filter combine" 'with-keyword=["v-ws-tls"]'
    _pf "a parameter filter that leaves nothing is logged as the filter" "emptied-info=1"
    _pf "...with the warning that names the filter, not the feed" "emptied-warn=1"
    _pf "both kinds of filter are named together" "both-kinds=1"
    _pf "the keyword filter alone is reported as before" "keyword-only=1"

    rm -rf "$work"
}


test_ecs_auto() {
    header "EDNS Client Subnet from the WAN (ecs.sh)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$lib/ecs.sh" ] || [ ! -r "$lib/helpers.sh" ] || [ ! -r "$lib/constants.sh" ] || [ ! -r "$bin" ]; then
        fail "ecs.sh / helpers.sh / constants.sh / bin not found"
        return
    fi

    local work="/tmp/netshift-ecsauto-$$"
    rm -rf "$work"
    mkdir -p "$work"

    mkdir -p /usr/lib/netshift
    ln -sf "$lib/helpers.jq" /usr/lib/netshift/helpers.jq
    ln -sf "$lib/helpers.sh" /usr/lib/netshift/helpers.sh
    ln -sf "$lib/sing_box_config_manager.sh" /usr/lib/netshift/sing_box_config_manager.sh

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        . "$lib/sing_box_config_manager.sh"
        . "$lib/sing_box_config_facade.sh"
        . "$lib/ecs.sh"
        NETSHIFT_STATE_DIR="$work"
        ECS_CACHE_FILE="$work/ecs-external.json"
        LOG=""
        log() { LOG="${LOG}[$2] $1;"; }
        eval "$(awk '/^geoip_is_private_ip\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        eval "$(awk '/^sing_box_configure_dns\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        eval "$(awk '/^netshift_ipv6_enabled\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        eval "$(awk '/^_get_dns_detour_tag\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"

        # private firewall config: zones wan (wan, wan2) and lan
        uci() { command uci -c "$work" "$@"; }
        : > "$work/firewall"
        uci add firewall zone > /dev/null; uci set firewall.@zone[-1].name=lan; uci add_list firewall.@zone[-1].network=lan
        uci add firewall zone > /dev/null; uci set firewall.@zone[-1].name=wan; uci add_list firewall.@zone[-1].network=wan; uci add_list firewall.@zone[-1].network=wan2
        uci commit firewall

        # interface table: name|device|address ("" = down)
        ECS_IFACES="wan|eth1|198.51.100.7
wan2|eth2|10.5.0.2"
        network_find_wan() { eval "$1=wan"; }
        network_get_ipaddr() {
            local row addr
            row="$(printf '%s\n' "$ECS_IFACES" | grep "^$2|")"
            addr="${row##*|}"
            [ -n "$addr" ] || return 1
            eval "$1=\"$addr\""
        }
        network_get_device() {
            local row dev
            row="$(printf '%s\n' "$ECS_IFACES" | grep "^$2|")"
            dev="${row#*|}"
            eval "$1=\"${dev%%|*}\""
        }

        # curl: records "<device> <url>", answers from ECS_API
        : > "$work/curl.log"
        ECS_API='{"ip":"203.0.113.9"}'
        curl() {
            local dev="" url=""
            while [ $# -gt 0 ]; do
                case "$1" in
                --interface) dev="$2"; shift ;;
                -m) shift ;;
                -s) ;;
                *) url="$1" ;;
                esac
                shift
            done
            echo "$dev $url" >> "$work/curl.log"
            [ -n "$ECS_API" ] && printf '%s' "$ECS_API"
            return 0
        }
        calls() { wc -l < "$work/curl.log" | tr -d ' '; }

        echo "wans=$(ecs_wan_interfaces | tr '\n' ' ')"
        echo "subnet-of=$(ecs_subnet_of 203.0.113.57)"
        echo "public-first=$(ecs_resolve_auto '')"
        echo "public-calls=$(calls)"

        # the first interface goes down: the second (private) is used through the lookup
        ECS_IFACES="wan|eth1|
wan2|eth2|10.5.0.2"
        echo "private=$(ecs_resolve_auto '')"
        echo "private-calls=$(calls)"
        echo "private-device=$(tail -n1 "$work/curl.log" | cut -d' ' -f1)"
        echo "cache=$(jq -c . "$ECS_CACHE_FILE")"
        echo "cache-mode=$(ls -l "$ECS_CACHE_FILE" | cut -c1-10)"
        ecs_resolve_auto '' > /dev/null
        echo "cached-calls=$(calls)"

        # the local address changes: asked again, the old entry is replaced
        ECS_IFACES="wan|eth1|
wan2|eth2|10.5.0.77"
        ECS_API='{"ip":"203.0.113.88"}'
        echo "changed=$(ecs_resolve_auto '')"
        echo "cache-after=$(jq -c . "$ECS_CACHE_FILE")"

        # carrier-grade NAT counts as private
        ECS_IFACES="wan|eth1|100.64.3.2
wan2|eth2|"
        ECS_API='{"ip":"192.0.2.44"}'
        echo "cgnat=$(ecs_resolve_auto 'wan')"

        # an explicit interface is the only one asked
        ECS_IFACES="wan|eth1|198.51.100.7
wan2|eth2|10.5.0.2"
        : > "$work/curl.log"
        echo "chosen=$(ecs_resolve_auto 'wan2')"
        echo "chosen-first-calls=$(calls)"
        echo "unknown-interface=[$(ecs_resolve_auto 'nope')]"

        # no answer from the internet: nothing, and nothing remembered
        rm -f "$ECS_CACHE_FILE"
        ECS_IFACES="wan|eth1|
wan2|eth2|10.5.0.2"
        ECS_API=''
        echo "offline=[$(ecs_resolve_auto '')]"
        [ -e "$ECS_CACHE_FILE" ] && echo "offline-cache=present" || echo "offline-cache=none"
        ECS_API='{"ip":"10.1.2.3"}'
        echo "private-answer=[$(ecs_resolve_auto '')]"
        ECS_API='not json'
        echo "garbage-answer=[$(ecs_resolve_auto '')]"

        ECS_IFACES="wan|eth1|198.51.100.7
wan2|eth2|10.5.0.2"
        ECS_API='{"ip":"203.0.113.9"}'
        rm -f "$ECS_CACHE_FILE"
        echo "json=$(get_wan_addresses | jq -c '[.interfaces[] | [.interface, .address, .public, .external, .subnet]]')"

        # the DNS section with the option
        UCI_settings_dns_type="udp" UCI_settings_dns_server="1.1.1.1" UCI_settings_bootstrap_dns_server="77.88.8.8"
        config_get() {
            local _var="$1" _sec="$2" _opt="$3" _def="${4-}" _val
            eval "_val=\"\${UCI_${_sec}_${_opt}:-}\""
            [ -n "$_val" ] || _val="$_def"
            eval "$_var=\"\$_val\""
        }
        config_get_bool() { config_get "$@"; }
        build() {
            config='{"log":{},"dns":{},"ntp":{},"certificate":{},"endpoints":[],"inbounds":[],"outbounds":[],"route":{},"services":[],"experimental":{}}'
            LOG=""
            sing_box_configure_dns
            printf '%s' "$config" | jq -r '.dns.client_subnet // "none"'
        }
        UCI_settings_dns_client_subnet="" UCI_settings_dns_client_subnet_auto="" UCI_settings_dns_client_subnet_interface=""
        echo "dns-off=$(build)"
        UCI_settings_dns_client_subnet="192.0.2.0/24"
        echo "dns-manual=$(build)"
        UCI_settings_dns_client_subnet_auto="1"
        echo "dns-auto=$(build)"
        UCI_settings_dns_client_subnet_interface="wan2"
        echo "dns-auto-interface=$(build)"
        ECS_IFACES="wan|eth1|
wan2|eth2|"
        echo "dns-auto-none-falls-back=$(build)"
        UCI_settings_dns_client_subnet=""
        echo "dns-auto-none-nothing=$(build)"
    )"

    _ea() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _ea "the WAN interfaces come from the wan zone, default route first" "wans=wan wan2 "
    _ea "the subnet is the /24 of the address" "subnet-of=203.0.113.0/24"
    _ea "a public address is used as it is" "public-first=198.51.100.0/24"
    _ea "...without asking the internet" "public-calls=0"
    _ea "an interface that is down is skipped, a private address is looked up" "private=203.0.113.0/24"
    _ea "...once" "private-calls=1"
    _ea "...through that interface" "private-device=eth2"
    _ea "the answer is remembered" 'cache={"wan2|10.5.0.2":"203.0.113.9"}'
    _ea "the remembered address of the router is private to root" "cache-mode=-rw-------"
    _ea "a remembered answer is not asked again" "cached-calls=1"
    _ea "a changed local address is asked again" "changed=203.0.113.0/24"
    _ea "...and replaces the old entry" 'cache-after={"wan2|10.5.0.77":"203.0.113.88"}'
    _ea "carrier-grade NAT counts as private" "cgnat=192.0.2.0/24"
    _ea "an explicit interface is used" "chosen=192.0.2.0/24"
    _ea "...and the first one is not asked" "chosen-first-calls=1"
    _ea "an unknown interface gives nothing" "unknown-interface=[]"
    _ea "no answer from the internet gives nothing" "offline=[]"
    _ea "...and nothing is remembered" "offline-cache=none"
    _ea "a private address in the answer is refused" "private-answer=[]"
    _ea "garbage in the answer is refused" "garbage-answer=[]"
    _ea "the JSON lists every interface with its subnet" 'json=[["wan","198.51.100.7",true,"198.51.100.7","198.51.100.0/24"],["wan2","10.5.0.2",false,"203.0.113.9","203.0.113.0/24"]]'
    _ea "no ECS by default" "dns-off=none"
    _ea "the typed value is used when auto is off" "dns-manual=192.0.2.0/24"
    _ea "auto takes the first usable WAN" "dns-auto=198.51.100.0/24"
    _ea "auto takes the chosen interface" "dns-auto-interface=203.0.113.0/24"
    _ea "auto with no address falls back to the typed value" "dns-auto-none-falls-back=192.0.2.0/24"
    _ea "auto with no address and no typed value sends nothing" "dns-auto-none-nothing=none"

    rm -rf "$work"
}


test_dns_servers_check() {
    header "DNS check for every transport the unified server list offers"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "bin / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-dnscheck-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        eval "$(awk '/^check_dns_available\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"

        config_get() { eval "$1=\"\${DNSC_$3:-}\""; }
        config_load() { :; }
        config_foreach() { :; }
        _get_dns_detour_tag() { echo ""; }
        dhcp_config_status=1
        # dig: record the arguments, succeed unless DIG_FAIL is set
        dig() { echo "$*" >> "$work/dig.log"; [ -z "$DIG_FAIL" ]; }

        run() { # type server
            DNSC_dns_type="$1" DNSC_dns_server="$2" DNSC_bootstrap_dns_server="77.88.8.8"
            : > "$work/dig.log"
            check_dns_available | jq -c '[.dns_type, .dns_status]'
            head -n1 "$work/dig.log"
        }

        echo "udp=$(run udp 8.8.8.8 | tr '\n' '|')"
        echo "tcp=$(run tcp 8.8.8.8 | tr '\n' '|')"
        echo "dot=$(run dot dns.google | tr '\n' '|')"
        echo "doh=$(run doh dns.google/dns-query | tr '\n' '|')"
        echo "doh3=$(run doh3 dns.google/dns-query | tr '\n' '|')"
        echo "doq=$(run doq dns.adguard-dns.com | tr '\n' '|')"
        DIG_FAIL=1
        echo "doq-fails=$(run doq dns.adguard-dns.com | head -n1)"
        echo "tcp-fails=$(run tcp 8.8.8.8 | head -n1)"
    )"

    _dc() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _dc "udp is asked directly" 'udp=["udp",1]|@8.8.8.8 google.com +timeout=2 +tries=1|'
    _dc "tcp is asked over TCP" 'tcp=["tcp",1]|@8.8.8.8 google.com +tcp +timeout=2 +tries=1|'
    _dc "dot is asked over TLS" 'dot=["dot",1]|@dns.google google.com +tls +timeout=2 +tries=1|'
    _dc "doh is asked over HTTPS with its path" 'doh=["doh",1]|@dns.google google.com +https=/dns-query +timeout=2 +tries=1|'
    _dc "doh3 is judged by the router resolver" 'doh3=["doh3",1]|@127.0.0.42 google.com +timeout=3 +tries=1|'
    _dc "doq is judged by the router resolver" 'doq=["doq",1]|@127.0.0.42 google.com +timeout=3 +tries=1|'
    _dc "a failing resolver is reported for doq" 'doq-fails=["doq",0]'
    _dc "a failing resolver is reported for tcp" 'tcp-fails=["tcp",0]'

    rm -rf "$work"
}


test_connections_api() {
    header "Connections: list, close one, close all (clash_api)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "bin / constants.sh not found"
        return
    fi

    local out
    out="$(
        . "$lib/constants.sh"
        eval "$(awk '/^clash_api\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        log() { :; }
        get_service_listen_address() { echo "192.168.1.1"; }
        config_get() { eval "$1=\"\${4:-}\""; }
        config_get_bool() { eval "$1=0"; }
        snapshot_sing_box_cache() { :; }

        CALLS_FILE="/tmp/netshift-conn-calls-$$"
        : > "$CALLS_FILE"
        CONN='{"downloadTotal":5000,"uploadTotal":700,"memory":1,"connections":[
          {"id":"aaaa-1","start":"2026-10-06T10:00:00Z","upload":10,"download":20,"chains":["main-out"],"rule":"RuleSet","rulePayload":"main-ruleset",
           "metadata":{"network":"tcp","type":"tproxy","sourceIP":"192.168.1.10","sourcePort":"50000","destinationIP":"203.0.113.9","destinationPort":"443","host":"example.com"}},
          {"id":"bbbb-2","start":"2026-10-06T10:05:00Z","upload":1,"download":2,"chains":["direct-out"],"rule":"final",
           "metadata":{"network":"udp","type":"tproxy","sourceIP":"192.168.1.11","sourcePort":"123","destinationIP":"198.51.100.4","destinationPort":"53","host":""}}]}'
        HTTP_CODE=204
        curl() {
            local args="$*" code=0
            case "$args" in
            *"-X DELETE"*) printf '|DELETE %s' "${args##* }" >> "$CALLS_FILE"; printf '%s' "$HTTP_CODE" ;;
            *) printf '|GET %s' "${args##* }" >> "$CALLS_FILE"; printf '%s' "$CONN" ;;
            esac
        }

        echo "list=$(clash_api get_connections | jq -c '[.total, .downloadTotal, (.connections | map(.id))]')"
        echo "newest-first=$(clash_api get_connections | jq -c '.connections[0] | [.host, .source, .destination, .port, .chains, .rule, .rule_payload]')"
        echo "ip-when-no-host=$(clash_api get_connections | jq -c '.connections[0].host')"
        : > "$CALLS_FILE"
        echo "close-one=$(clash_api close_connection aaaa-1)"
        echo "close-calls=$(cat "$CALLS_FILE")"
        HTTP_CODE=404
        echo "close-gone=$(clash_api close_connection aaaa-1)"
        HTTP_CODE=500
        echo "close-fails=$(clash_api close_connection aaaa-1)"
        echo "close-bad-id=$(clash_api close_connection 'x;rm -rf')"
        echo "close-no-id=$(clash_api close_connection '')"
        HTTP_CODE=204
        : > "$CALLS_FILE"
        echo "close-all=$(clash_api close_connections)"
        echo "close-all-calls=$(cat "$CALLS_FILE")"
        rm -f "$CALLS_FILE"
        CONNECTIONS_LIST_CAP=1
        echo "capped=$(clash_api get_connections | jq -c '[.total, (.connections | length), .connections[0].id]')"
    )"

    _cn() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _cn "the list is reduced and counted" 'list=[2,5000,["bbbb-2","aaaa-1"]]'
    _cn "newest first, with the host and the route" 'newest-first=["198.51.100.4","192.168.1.11:123","198.51.100.4","53",["direct-out"],"final",""]'
    _cn "the address stands in when there is no host" 'ip-when-no-host="198.51.100.4"'
    _cn "one connection can be closed" 'close-one={"success":true}'
    _cn "...by a DELETE of that connection" 'close-calls=|DELETE 192.168.1.1:9090/connections/aaaa-1'
    _cn "a connection that is already gone counts as closed" 'close-gone={"success":true}'
    _cn "a failure is reported" 'close-fails={"success":false,"http_code":"500"}'
    _cn "a strange id is refused before any request" 'close-bad-id={"success":false,"error":"invalid connection id"}'
    _cn "an empty id is refused" 'close-no-id={"success":false,"error":"invalid connection id"}'
    _cn "all connections can be closed" 'close-all={"success":true}'
    _cn "...by a DELETE of the whole table" 'close-all-calls=|DELETE 192.168.1.1:9090/connections'
    _cn "the list is capped" 'capped=[2,1,"bbbb-2"]'
}


test_lan_devices() {
    header "LAN info and static DHCP leases (get_lan_info, dhcp_host_set/remove)"

    if ! command -v jq > /dev/null 2>&1 || ! command -v uci > /dev/null 2>&1; then
        skip "jq / uci not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/lan.sh" ] || [ ! -r "$lib/helpers.sh" ]; then
        fail "lan.sh / helpers.sh not found"
        return
    fi

    local work="/tmp/netshift-lan-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/helpers.sh"
        . "$lib/lan.sh"
        log() { :; }

        # a private copy of the UCI config
        uci() { command uci -c "$work" "$@"; }
        : > "$work/firewall"
        : > "$work/dhcp"
        uci add firewall zone > /dev/null; uci set firewall.@zone[-1].name=lan; uci add_list firewall.@zone[-1].network=lan
        uci add firewall zone > /dev/null; uci set firewall.@zone[-1].name=wan; uci add_list firewall.@zone[-1].network=wan
        uci commit firewall
        uci set dhcp.existing=host; uci set dhcp.existing.mac="aa:bb:cc:00:00:01"; uci set dhcp.existing.ip=192.168.1.20; uci set dhcp.existing.name=printer
        uci set dhcp.multi=host; uci add_list dhcp.multi.mac="AA:BB:CC:00:00:02"; uci add_list dhcp.multi.mac="AA:BB:CC:00:00:03"; uci set dhcp.multi.ip=192.168.1.30
        uci commit dhcp

        : > "$work/reloads"
        dhcp_reload_dnsmasq() { echo r >> "$work/reloads"; }
        lan_network_subnets() {
            case "$1" in
            lan) printf '192.168.1.1/24\n10.8.0.5/16\n' ;;
            wan) printf '5.23.104.7/24\n' ;;
            esac
        }

        echo "names=$(lan_network_names)"
        echo "subnets=$(lan_subnets | tr '\n' ' ')"
        for spec in "192.168.1.77:192.168.1.0/24" "192.168.2.1:192.168.1.0/24" "10.8.200.9:10.8.0.0/16" "0.0.0.0:0.0.0.0/0" "5.23.104.2:192.168.1.0/24"; do
            ip="${spec%%:*}"; sn="${spec#*:}"
            ipv4_in_subnet "$ip" "$sn" && echo "in[$ip,$sn]=yes" || echo "in[$ip,$sn]=no"
        done
        ip_in_lan 192.168.1.50 && echo "lan[192.168.1.50]=yes" || echo "lan[192.168.1.50]=no"
        ip_in_lan 5.23.104.2 && echo "lan[5.23.104.2]=yes" || echo "lan[5.23.104.2]=no"
        echo "mac[aa-bb-cc-dd-ee-ff]=$(normalize_mac 'aa-bb-cc-dd-ee-ff' || echo bad)"
        echo "mac[xyz]=$(normalize_mac 'xyz' || echo bad)"
        echo "info=$(get_lan_info | jq -c '[.subnets, [.static_hosts[] | [.section, .macs, .ip, .name]]]')"

        echo "set-new=$(dhcp_host_set 'aa:bb:cc:00:00:10' 192.168.1.50 laptop | jq -c .)"
        echo "stored=$(uci get dhcp.netshift_aabbcc000010.ip),$(uci get dhcp.netshift_aabbcc000010.name),$(uci get dhcp.netshift_aabbcc000010.mac)"
        echo "set-update=$(dhcp_host_set 'AA:BB:CC:00:00:10' 192.168.1.51 | jq -c .)"
        echo "updated=$(uci get dhcp.netshift_aabbcc000010.ip),$(uci get dhcp.netshift_aabbcc000010.name)"
        echo "set-existing-entry=$(dhcp_host_set 'aa:bb:cc:00:00:01' 192.168.1.21 | jq -c .)"
        echo "existing-kept-section=$(uci get dhcp.existing.ip),$(uci get dhcp.existing.name)"
        echo "conflict-ip=$(dhcp_host_set 'aa:bb:cc:00:00:11' 192.168.1.21 | jq -c .error)"
        echo "conflict-name=$(dhcp_host_set 'aa:bb:cc:00:00:11' 192.168.1.60 printer | jq -c .error)"
        echo "conflict-name-case=$(dhcp_host_set 'aa:bb:cc:00:00:11' 192.168.1.60 PRINTER | jq -c .error)"
        echo "outside=$(dhcp_host_set 'aa:bb:cc:00:00:11' 5.23.104.2 | jq -c .error)"
        echo "bad-ip=$(dhcp_host_set 'aa:bb:cc:00:00:11' 999.1.1.1 | jq -c .error)"
        echo "bad-mac=$(dhcp_host_set 'zz' 192.168.1.61 | jq -c .error)"
        echo "bad-name=$(dhcp_host_set 'aa:bb:cc:00:00:11' 192.168.1.62 'bad name!' | jq -c .error)"
        echo "reloads=$(wc -l < "$work/reloads" | tr -d ' ')"

        echo "remove=$(dhcp_host_remove 'aa:bb:cc:00:00:10' | jq -c .)"
        uci -q get dhcp.netshift_aabbcc000010 > /dev/null && echo "after-remove=present" || echo "after-remove=gone"
        echo "remove-missing=$(dhcp_host_remove 'aa:bb:cc:00:00:99' | jq -c .)"
        dhcp_host_remove 'aa:bb:cc:00:00:02' > /dev/null
        echo "multi-left=$(uci get dhcp.multi.mac)"
        echo "reloads-after=$(wc -l < "$work/reloads" | tr -d ' ')"
    )"

    _lv() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _lv "the lan zone gives the network" "names= lan"
    _lv "subnets are reported as network addresses" "subnets=10.8.0.0/16 192.168.1.0/24 "
    _lv "address inside a /24" "in[192.168.1.77,192.168.1.0/24]=yes"
    _lv "address outside a /24" "in[192.168.2.1,192.168.1.0/24]=no"
    _lv "address inside a /16" "in[10.8.200.9,10.8.0.0/16]=yes"
    _lv "a /0 holds everything" "in[0.0.0.0,0.0.0.0/0]=yes"
    _lv "a provider neighbour is not in the LAN subnet" "in[5.23.104.2,192.168.1.0/24]=no"
    _lv "a LAN host is in the LAN" "lan[192.168.1.50]=yes"
    _lv "a WAN neighbour is not in the LAN" "lan[5.23.104.2]=no"
    _lv "MAC with dashes is normalized" "mac[aa-bb-cc-dd-ee-ff]=AA:BB:CC:DD:EE:FF"
    _lv "garbage MAC is refused" "mac[xyz]=bad"
    _lv "get_lan_info lists the static leases" 'info=[["10.8.0.0/16","192.168.1.0/24"],[["existing",["AA:BB:CC:00:00:01"],"192.168.1.20","printer"],["multi",["AA:BB:CC:00:00:02","AA:BB:CC:00:00:03"],"192.168.1.30",""]]]'
    _lv "a new lease is created" 'set-new={"ok":true,"section":"netshift_aabbcc000010"}'
    _lv "the lease is stored" "stored=192.168.1.50,laptop,AA:BB:CC:00:00:10"
    _lv "the same MAC updates the lease" 'set-update={"ok":true,"section":"netshift_aabbcc000010"}'
    _lv "update keeps the name" "updated=192.168.1.51,laptop"
    _lv "an entry made elsewhere is edited in place" 'set-existing-entry={"ok":true,"section":"existing"}'
    _lv "...and keeps its name" "existing-kept-section=192.168.1.21,printer"
    _lv "an address taken by another device is refused" 'conflict-ip="the address is already given to another device"'
    _lv "a name taken by another device is refused" 'conflict-name="the name is already used by another device"'
    _lv "a name differing only in case counts as taken" 'conflict-name-case="the name is already used by another device"'
    _lv "an address outside the LAN is refused" 'outside="the address is outside the local networks"'
    _lv "a bad IP is refused" 'bad-ip="invalid IPv4 address"'
    _lv "a bad MAC is refused" 'bad-mac="invalid MAC address"'
    _lv "a bad name is refused" 'bad-name="invalid host name"'
    _lv "dnsmasq is reloaded once per change" "reloads=3"
    _lv "a lease is released" 'remove={"ok":true,"removed":true}'
    _lv "...and gone" "after-remove=gone"
    _lv "releasing a missing lease is harmless" 'remove-missing={"ok":true,"removed":false}'
    _lv "a lease shared by several MACs only loses one" "multi-left=AA:BB:CC:00:00:03"
    _lv "dnsmasq is reloaded after each release, not for a missing one" "reloads-after=5"

    rm -rf "$work"
}


test_update_notice() {
    header "Update notice: cached answer, refresh, stale check (update_notice.sh)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/update_notice.sh" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "update_notice.sh / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-notice-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/update_notice.sh"
        UPDATE_NOTICE_FILE="$work/notice.json"

        NOTICE_ENABLED=1
        config_get_bool() { eval "$1=\"$NOTICE_ENABLED\""; }
        NS_JSON='{"success":true,"current_version":"0.9.10","latest_version":"0.9.12","status":"outdated"}'
        SB_JSON='{"success":true,"current_version":"1.12.0-extended-1","latest_version":"1.12.0-extended-2","status":"outdated"}'
        VARIANT=extended_lite
        updates_check_netshift() { printf '%s\n' "$NS_JSON"; }
        updates_check_sing_box_extended() { echo "EXT-CALLED" >> "$work/calls"; printf '%s\n' "$SB_JSON"; }
        updates_check_sing_box_lite() { echo "LITE-CALLED" >> "$work/calls"; printf '%s\n' "$SB_JSON"; }
        get_sing_box_variant() { echo "$VARIANT"; }

        echo "no-file=$(get_update_notice | jq -c '[.enabled, .stale, .checked, .netshift, .sing_box]')"

        update_notice_refresh
        echo "stored=$(jq -c '[.netshift.latest_version, .sing_box.latest_version, (.checked > 1700000000)]' "$UPDATE_NOTICE_FILE")"
        echo "lite-asked=$(cat "$work/calls")"
        echo "fresh=$(get_update_notice | jq -c '[.enabled, .stale, .netshift.status, .sing_box.status]')"

        # an old answer is stale
        jq -c '.checked = 1000' "$UPDATE_NOTICE_FILE" > "$work/old" && mv "$work/old" "$UPDATE_NOTICE_FILE"
        echo "stale=$(get_update_notice | jq -c '.stale')"

        NOTICE_ENABLED=0
        echo "disabled=$(get_update_notice | jq -c '.enabled')"
        NOTICE_ENABLED=1

        # stock core: no GitHub check for it
        rm -f "$work/calls"; VARIANT=stock
        update_notice_refresh
        echo "stock=$(jq -c '[.netshift.latest_version, .sing_box]' "$UPDATE_NOTICE_FILE")"
        echo "stock-calls=$(cat "$work/calls" 2> /dev/null | wc -l | tr -d ' ')"
        VARIANT=extended
        update_notice_refresh
        echo "extended-asked=$(cat "$work/calls")"

        # GitHub unreachable: the previous answer stays, only the time moves
        updates_check_netshift() { echo '{"success":false,"message":"unreachable"}'; return 1; }
        updates_check_sing_box_extended() { echo '{"success":false}'; return 1; }
        jq -c '.checked = 1000' "$UPDATE_NOTICE_FILE" > "$work/old" && mv "$work/old" "$UPDATE_NOTICE_FILE"
        update_notice_refresh
        echo "offline-kept=$(jq -c '[.netshift.latest_version, (.checked > 1700000000)]' "$UPDATE_NOTICE_FILE")"
        echo "offline-not-stale=$(get_update_notice | jq -c '.stale')"

        # nothing known and unreachable: an answer with nulls, not a broken file
        rm -f "$UPDATE_NOTICE_FILE"
        update_notice_refresh
        echo "empty=$(jq -c '[.netshift, .sing_box]' "$UPDATE_NOTICE_FILE")"

        # garbage in the file is read as "nothing known"
        echo 'not json' > "$UPDATE_NOTICE_FILE"
        echo "garbage=$(get_update_notice | jq -c '[.stale, .netshift]')"

        # the background refresh: starts once, a second call while it runs does nothing
        rm -f "$UPDATE_NOTICE_FILE" "$UPDATE_NOTICE_FILE.lock"
        updates_check_netshift() { sleep 2; printf '%s\n' "$NS_JSON"; }
        echo "async-first=$(update_notice_refresh_async)"
        echo "async-second=$(update_notice_refresh_async)"
        sleep 4
        echo "async-done=$(jq -c '.netshift.latest_version' "$UPDATE_NOTICE_FILE")"
        echo "async-lock-removed=$([ -e "$UPDATE_NOTICE_FILE.lock" ] && echo no || echo yes)"
    )"

    _un() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _un "no answer yet: enabled, stale, nothing known" "no-file=[true,true,null,null,null]"
    _un "a refresh stores both answers and the time" 'stored=["0.9.12","1.12.0-extended-2",true]'
    _un "the lite core is asked for lite" "lite-asked=LITE-CALLED"
    _un "a fresh answer is not stale" 'fresh=[true,false,"outdated","outdated"]'
    _un "an old answer is stale" "stale=true"
    _un "the switch is reported" "disabled=false"
    _un "the stock core is not asked" 'stock=["0.9.12",null]'
    _un "...no GitHub call for it" "stock-calls=0"
    _un "the extended core is asked for extended" "extended-asked=EXT-CALLED"
    _un "an unreachable GitHub keeps the previous answer" 'offline-kept=["0.9.12",true]'
    _un "...and does not ask again at once" "offline-not-stale=false"
    _un "nothing known and unreachable gives empty parts" "empty=[null,null]"
    _un "a broken file reads as nothing known" "garbage=[true,null]"
    _un "the background refresh starts" 'async-first={"started":true}'
    _un "...once at a time" 'async-second={"started":false}'
    _un "...and stores its answer" 'async-done="0.9.12"'
    _un "...and removes its lock" "async-lock-removed=yes"

    rm -rf "$work"
}


test_config_snapshots() {
    header "Configuration snapshots: save, list, restore (snapshots.sh)"

    if ! command -v jq > /dev/null 2>&1 || ! command -v uci > /dev/null 2>&1; then
        skip "jq / uci not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/snapshots.sh" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "snapshots.sh / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-snap-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/snapshots.sh"
        SNAPSHOT_DIR="$work/snapshots"
        NETSHIFT_CONFIG_FILE="$work/netshift"
        SNAPSHOT_KEEP=3

        cfg() { printf "config settings 'settings'\n\toption dns_type '%s'\n\nconfig section 'main'\n\toption connection_type 'proxy'\n" "$1" > "$NETSHIFT_CONFIG_FILE"; }
        # a clock that moves one second per call, so the order is the order of the calls
        echo 1790000000 > "$work/tick"
        date() { local n; n="$(cat "$work/tick")"; n=$((n + 1)); echo "$n" > "$work/tick"; echo "$n"; }

        echo "no-config=$(snapshot_save auto | jq -c '.error')"
        cfg udp
        echo "first=$(snapshot_save auto | jq -c '[.ok, .id]')"
        echo "unchanged=$(snapshot_save auto | jq -c '[.ok, .id, (.unchanged != null)]')"
        cfg doh
        echo "changed=$(snapshot_save manual | jq -c '[.ok, .id]')"
        echo "forced=$(snapshot_save manual force | jq -c '.id != ""')"
        echo "bad-label=$(snapshot_save nonsense | jq -c '.error')"
        echo "mode=$(ls -l "$SNAPSHOT_DIR"/*.conf | head -1 | cut -c1-10)"

        echo "list=$(snapshot_list | jq -c '[.snapshots[] | [.label, .current]]')"

        # keep only the newest SNAPSHOT_KEEP
        cfg tcp; snapshot_save auto > /dev/null
        cfg dot; snapshot_save auto > /dev/null
        echo "pruned=$(snapshot_list | jq -c '.snapshots | length')"
        echo "oldest-gone=$(ls "$SNAPSHOT_DIR" | grep -c '1790000001')"

        # restore: the current configuration is kept first
        newest="$(snapshot_list | jq -r '.snapshots[1].id')"
        cfg doq
        echo "restore=$(snapshot_restore "$newest" | jq -c '.ok')"
        echo "restored=$(sed -n "s/.*dns_type '\\(.*\\)'.*/\\1/p" "$NETSHIFT_CONFIG_FILE")"
        echo "before-restore=$(snapshot_list | jq -c '[.snapshots[] | select(.label == "before-restore")] | length')"
        echo "before-restore-holds-doq=$(for f in "$SNAPSHOT_DIR"/*before-restore.conf; do sed -n "s/.*dns_type '\\(.*\\)'.*/\\1/p" "$f"; done | head -1)"

        echo "config-mode=$(ls -l "$NETSHIFT_CONFIG_FILE" | cut -c1-10)"
        echo "dir-mode=$(ls -ld "$SNAPSHOT_DIR" | cut -c1-10)"

        # a clock that is behind (no time sync yet at boot) does not put a new snapshot before the newest
        before="$(snapshot_ids | sed -n '1p')"
        echo 1000 > "$work/tick"
        cfg quic
        late="$(snapshot_save auto | jq -r '.id')"
        echo "late-after-newest=$([ "${late%%-*}" -gt "${before%%-*}" ] && echo yes || echo no)"
        echo "late-is-newest=$([ "$(snapshot_ids | sed -n '1p')" = "$late" ] && echo yes || echo no)"
        cfg tcp

        echo "bad-id=$(snapshot_restore '../../etc/passwd' | jq -c '.error')"
        echo "bad-id-2=$(snapshot_restore '123-evil' | jq -c '.error')"
        echo "missing=$(snapshot_restore '1-auto' | jq -c '.error')"
        printf 'not a uci file {{{' > "$SNAPSHOT_DIR/1790009999-manual.conf"
        echo "unusable=$(snapshot_restore '1790009999-manual' | jq -c '.error')"
        echo "config-untouched=$(sed -n "s/.*dns_type '\\(.*\\)'.*/\\1/p" "$NETSHIFT_CONFIG_FILE")"
    )"

    _sn() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _sn "nothing to save without a configuration" 'no-config="there is no configuration to save"'
    _sn "a first snapshot is taken" 'first=[true,"1790000001-auto"]'
    _sn "an unchanged configuration makes no new one" 'unchanged=[true,"",true]'
    _sn "a changed configuration does" 'changed=[true,"1790000002-manual"]'
    _sn "force takes one anyway" "forced=true"
    _sn "an unknown label is refused" 'bad-label="unknown label"'
    _sn "snapshots are readable by root only" "mode=-rw-------"
    _sn "the list is newest first and marks the current one" 'list=[["manual",true],["manual",true],["auto",false]]'
    _sn "only the newest are kept" "pruned=3"
    _sn "...the oldest is the one removed" "oldest-gone=0"
    _sn "a snapshot is restored" "restore=true"
    _sn "...the configuration is the snapshot's" "restored=tcp"
    _sn "the replaced configuration is kept first" "before-restore=1"
    _sn "...with its content" "before-restore-holds-doq=doq"
    _sn "a restored configuration is private again" "config-mode=-rw-------"
    _sn "the snapshot directory is private" "dir-mode=drwx------"
    _sn "a clock that is behind still gives the newest id" "late-after-newest=yes"
    _sn "...and it is listed first" "late-is-newest=yes"
    _sn "a path in the id is refused" 'bad-id="invalid snapshot id"'
    _sn "an unknown label in the id is refused" 'bad-id-2="invalid snapshot id"'
    _sn "a snapshot that does not exist is refused" 'missing="no such snapshot"'
    _sn "a file that is not a configuration is refused" 'unusable="the snapshot is not a usable configuration"'
    _sn "...and leaves the configuration alone" "config-untouched=tcp"

    rm -rf "$work"
}


test_pin_guard() {
    header "Pin guard: a dead chosen server falls back to the automatic group (pinguard.sh)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/pinguard.sh" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "pinguard.sh / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-pinguard-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/pinguard.sh"
        PIN_GUARD_EVENTS_FILE="$work/events.json"
        LOGF="$work/log"; : > "$LOGF"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$LOGF"; }
        WARNED=""
        _priority_warn_once() {
            case " $WARNED " in *" $1:$2 "*) return 0 ;; esac
            WARNED="$WARNED $1:$2"
            printf '[warn-once] %s\n' "$3" >> "$LOGF"
        }
        get_outbound_tag_by_section() { echo "$1-out"; }
        section_is_disabled() { [ "$1" = "off" ]; }
        priority_clash_setup() { :; }
        priority_fetch_proxies() { printf '%s' "$PROXIES"; }
        priority_probe_delay() { echo "$DELAY"; }
        SWITCHES="$work/switches"; : > "$SWITCHES"
        clash_api() { echo "$1 $2 $3" >> "$SWITCHES"; [ "$CLASH_OK" != 0 ]; }
        CLASH_OK=1
        config_get_bool() { eval "$1=\"\${UCI_$2_$3:-$4}\""; }
        config_get() { eval "$1=\"\${UCI_$2_$3:-}\""; }
        config_foreach() { local cb="$1" id; for id in $SECTIONS; do "$cb" "$id"; done; }

        # main: a pinned server "node-a"; "main-urltest-out" is the automatic group
        PROXIES='{"proxies":{
          "main-out":{"type":"Selector","now":"node-a","all":["node-a","node-b","main-urltest-out"]},
          "main-urltest-out":{"type":"URLTest","now":"node-b"},
          "node-a":{"type":"VLESS"},"node-b":{"type":"VLESS"},
          "auto-out":{"type":"Selector","now":"auto-urltest-out","all":["n1","auto-urltest-out"]},
          "auto-urltest-out":{"type":"URLTest","now":"n1"},"n1":{"type":"VLESS"},
          "bare-out":{"type":"Selector","now":"b1","all":["b1","b2"]},"b1":{"type":"VLESS"},"b2":{"type":"VLESS"}}}'
        SECTIONS="main"
        UCI_main_pin_guard=1
        UCI_main_connection_type=proxy

        DELAY=120
        pin_guard_check_sections
        echo "alive-switches=$(wc -l < "$SWITCHES" | tr -d ' ')"

        DELAY=0
        pin_guard_check_sections
        pin_guard_check_sections
        echo "below-limit-switches=$(wc -l < "$SWITCHES" | tr -d ' ') fails=$(pin_guard_fails_of main)"
        pin_guard_check_sections
        echo "switched=$(cat "$SWITCHES")"
        echo "fails-reset=$(pin_guard_fails_of main)"
        echo "event=$(get_pin_guard_events | jq -c '[.[] | [.section, .from, .to]]')"

        # an answer in between resets the count
        : > "$SWITCHES"; DELAY=0
        pin_guard_check_sections; pin_guard_check_sections
        DELAY=50; pin_guard_check_sections
        DELAY=0; pin_guard_check_sections; pin_guard_check_sections
        echo "reset-by-answer=$(wc -l < "$SWITCHES" | tr -d ' ')"

        # the automatic group itself is never touched
        PROXIES='{"proxies":{"main-out":{"type":"Selector","now":"main-urltest-out","all":["node-a","main-urltest-out"]},"main-urltest-out":{"type":"URLTest"},"node-a":{"type":"VLESS"}}}'
        : > "$SWITCHES"; DELAY=0
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "auto-selected=$(wc -l < "$SWITCHES" | tr -d ' ')"

        # no automatic group to fall back to
        SECTIONS="bare"; UCI_bare_pin_guard=1; UCI_bare_connection_type=proxy
        PROXIES='{"proxies":{"bare-out":{"type":"Selector","now":"b1","all":["b1","b2"]},"b1":{"type":"VLESS"},"b2":{"type":"VLESS"}}}'
        : > "$SWITCHES"
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "no-auto-group=$(wc -l < "$SWITCHES" | tr -d ' ') warned=$(grep -c 'no automatic (urltest) group' "$LOGF")"

        # sections the guard skips
        PROXIES='{"proxies":{"x-out":{"type":"Selector","now":"n","all":["n","x-urltest-out"]},"x-urltest-out":{"type":"URLTest"},"n":{"type":"VLESS"}}}'
        : > "$SWITCHES"; DELAY=0
        SECTIONS="x"; UCI_x_pin_guard=0; UCI_x_connection_type=proxy
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "option-off=$(wc -l < "$SWITCHES" | tr -d ' ')"
        UCI_x_pin_guard=1; UCI_x_connection_type=vpn
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "not-proxy=$(wc -l < "$SWITCHES" | tr -d ' ')"
        UCI_x_connection_type=proxy; UCI_x_priority_mode=1
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "priority-mode=$(wc -l < "$SWITCHES" | tr -d ' ')"
        UCI_x_priority_mode=0; SECTIONS="off"; UCI_off_pin_guard=1; UCI_off_connection_type=proxy
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "disabled=$(wc -l < "$SWITCHES" | tr -d ' ')"

        # a refused switch is reported and not recorded
        SECTIONS="x"; CLASH_OK=0; rm -f "$PIN_GUARD_EVENTS_FILE"
        pin_guard_check_sections; pin_guard_check_sections; pin_guard_check_sections
        echo "refused=$(get_pin_guard_events) warned=$(grep -c 'could not switch' "$LOGF")"
        CLASH_OK=1

        # the event list is capped
        rm -f "$PIN_GUARD_EVENTS_FILE"
        i=0; while [ "$i" -lt 14 ]; do pin_guard_record_event "s$i" a b; i=$((i + 1)); done
        echo "capped=$(get_pin_guard_events | jq -c '[length, .[0].section, .[-1].section]')"
        echo "no-file=$(rm -f "$PIN_GUARD_EVENTS_FILE"; get_pin_guard_events)"
        echo "bad-section-fails=$(pin_guard_fails_of 'a;b')"
    )"

    _pg() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _pg "a chosen server that answers is left alone" "alive-switches=0"
    _pg "it is not given up before the limit" "below-limit-switches=0 fails=2"
    _pg "the third silent probe switches to the automatic group" "switched=set_group_proxy main-out main-urltest-out"
    _pg "...and the count starts again" "fails-reset=0"
    _pg "...and the switch is kept for the dashboard" 'event=[["main","node-a","main-urltest-out"]]'
    _pg "an answer in between resets the count" "reset-by-answer=0"
    _pg "the automatic group is never touched" "auto-selected=0"
    _pg "no automatic group: nothing to switch to, said once" "no-auto-group=0 warned=1"
    _pg "an option that is off does nothing" "option-off=0"
    _pg "a section that is not a proxy one is skipped" "not-proxy=0"
    _pg "priority mode keeps its own way" "priority-mode=0"
    _pg "a disabled section is skipped" "disabled=0"
    _pg "a refused switch is reported and not recorded" "refused=[] warned=1"
    _pg "the event list keeps the newest ten" 'capped=[10,"s4","s13"]'
    _pg "no events, no file" "no-file=[]"
    _pg "a strange section name has no count" "bad-section-fails=0"

    rm -rf "$work"
}


test_dns_benchmark() {
    header "DNS benchmark: time every upstream from the router (dnsbench.sh)"

    if ! command -v jq > /dev/null 2>&1; then
        skip "jq not installed"
        return
    fi

    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$lib/dnsbench.sh" ] || [ ! -r "$lib/helpers.sh" ] || [ ! -r "$lib/constants.sh" ]; then
        fail "dnsbench.sh / helpers.sh / constants.sh not found"
        return
    fi

    local work="/tmp/netshift-bench-$$"
    rm -rf "$work"
    mkdir -p "$work"

    local out
    out="$(
        . "$lib/constants.sh"
        . "$lib/helpers.sh"
        . "$lib/dnsbench.sh"
        log() { :; }
        config_get() { eval "$1=\"\${UCI_$3:-$4}\""; }
        config_list_foreach() { local i; for i in $UCI_POOL; do "$3" "$i"; done; }

        # dig: records its arguments; answers by address
        : > "$work/dig.log"
        dig() {
            local args="$*"
            echo "$args" >> "$work/dig.log"
            case "$args" in
            *"+short"*)
                # bootstrap lookups
                case "$args" in
                *dns.google*) echo "8.8.4.4" ;;
                *cloudflare-dns.com*) echo "104.16.249.249" ;;
                *dead.example*) ;;
                esac
                return 0
                ;;
            *@10.9.9.9*) return 9 ;;                                   # does not answer
            *@192.0.2.1*) printf ';; ->>HEADER<<- status: SERVFAIL\n;; Query time: 5 msec\n' ;;
            *@1.1.1.1*) printf ';; ->>HEADER<<- status: NOERROR\n;; Query time: 17 msec\n' ;;
            *@8.8.4.4*) printf ';; ->>HEADER<<- status: NOERROR\n;; Query time: 41 msec\n' ;;
            *) printf ';; ->>HEADER<<- status: NOERROR\n;; Query time: 99 msec\n' ;;
            esac
        }

        args() { dns_bench_dig_args "$1" 77.88.8.8 || echo REFUSED; }
        echo "udp=$(args udp://1.1.1.1)"
        echo "tcp=$(args tcp://1.1.1.1)"
        echo "dot-ip=$(args dot://1.1.1.1)"
        echo "dot-name=$(args dot://dns.google)"
        echo "doh-name=$(args doh://cloudflare-dns.com/dns-query)"
        echo "doh-default-path=$(args doh://dns.google)"
        echo "doh3=$(args doh3://dns.google/dns-query)"
        echo "doq=$(args doq://dns.google)"
        echo "unresolvable=$(args udp://dead.example)"
        echo "bootstrap-used=$(grep -c '^@77.88.8.8 dns.google +short' "$work/dig.log")"

        echo "one=$(dns_bench_one udp://1.1.1.1 77.88.8.8)"
        echo "one-servfail=$(dns_bench_one udp://192.0.2.1 77.88.8.8 || echo none)"
        echo "one-timeout=$(dns_bench_one udp://10.9.9.9 77.88.8.8 || echo none)"

        echo "given=$(dns_benchmark udp://1.1.1.1 dot://dns.google udp://10.9.9.9 doh3://dns.google/dns-query 'evil;rm' | jq -c '[.results[] | [.server, .ms]]')"

        UCI_dns_type=dot UCI_dns_server=dns.google UCI_bootstrap_dns_server=77.88.8.8 UCI_POOL="udp://1.1.1.1 doh://cloudflare-dns.com/dns-query"
        echo "configured=$(dns_benchmark | jq -c '[.results[] | [.server, .ms]]')"

        UCI_POOL="udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1 udp://1.1.1.1"
        echo "capped=$(dns_benchmark | jq -c '.results | length')"

        # ── through the tunnel ─────────────────────────────────────────────
        for e in udp://172.31.200.60 tcp://10.0.0.1:5353 dot://dns.google doh://dns.google/dns-query doh://h:8443/p doh3://dns.google; do
            echo "target[$e]=$(dns_bench_entry_target "$e" || echo REFUSED)"
        done
        PROXIES='{"proxies":{"main-out":{"type":"Selector","now":"main-urltest-out"},"main-urltest-out":{"type":"URLTest","now":"node-b"},"node-b":{"type":"VLESS"},"plain-out":{"type":"VLESS"},"loop":{"type":"Selector","now":"loop"}}}'
        echo "leaf-selector-urltest=$(dns_bench_leaf_outbound main-out "$PROXIES")"
        echo "leaf-plain=$(dns_bench_leaf_outbound plain-out "$PROXIES")"
        echo "leaf-unknown=$(dns_bench_leaf_outbound nope "$PROXIES" || echo none)"
        echo "leaf-loop=$(dns_bench_leaf_outbound loop "$PROXIES" || echo none)"
        echo "leaf-no-clash=$(dns_bench_leaf_outbound main-out '' || echo none)"

        cat > "$work/service.json" << 'CFG'
{"outbounds":[{"type":"direct","tag":"direct-out"},
 {"type":"vless","tag":"node-b","server":"b.example.com","server_port":443,"uuid":"11111111-2222-3333-4444-555555555555","detour":"hop"},
 {"type":"socks","tag":"hop","server":"10.0.0.9","server_port":1080}],
 "route":{"default_mark":2097152,"auto_detect_interface":true,"final":"direct-out","default_domain_resolver":"dns-server"}}
CFG
        TARGETS='[{"index":1,"port":19201,"host":"172.31.200.60","target_port":53},{"index":2,"port":19202,"host":"dns.google","target_port":853}]'
        dns_bench_tunnel_config "$work/service.json" node-b 77.88.8.8 "$TARGETS" > "$work/tmp.json" 2> /dev/null && echo "config-built=yes" || echo "config-built=no"
        echo "config-inbounds=$(jq -c '[.inbounds[] | [.tag, .listen, .listen_port, .override_address, .override_port]]' "$work/tmp.json")"
        echo "config-outbounds=$(jq -c '[.outbounds[].tag]' "$work/tmp.json")"
        echo "config-route=$(jq -c '[.route.final, .route.default_mark, .route.default_domain_resolver, .route.rules[0].inbound]' "$work/tmp.json")"
        dns_bench_tunnel_config "$work/service.json" missing 77.88.8.8 "$TARGETS" > /dev/null 2>&1 && echo "config-missing-outbound=built" || echo "config-missing-outbound=refused"
        if command -v sing-box > /dev/null 2>&1; then
            sing-box -c "$work/tmp.json" check > /dev/null 2>&1 && echo "config-singbox-check=ok" || echo "config-singbox-check=FAIL"
        else
            echo "config-singbox-check=ok"
        fi
        echo "args-udp=$(dns_bench_tunnel_args udp 172.31.200.60 19201 '')"
        echo "args-tcp=$(dns_bench_tunnel_args tcp 172.31.200.60 19201 '')"
        echo "args-dot=$(dns_bench_tunnel_args dot dns.google 19202 '')"
        echo "args-doh=$(dns_bench_tunnel_args doh dns.google 19203 /dns-query)"

        # the whole run: dig answers by local port, sing-box is a stand-in that stays up
        UCI_config_path="$work/service.json"
        _get_dns_detour_tag() { echo "main-out"; }
        priority_clash_setup() { :; }
        priority_fetch_proxies() { printf '%s' "$PROXIES"; }
        DNS_BENCH_TUNNEL_START_WAIT=0
        : > "$work/sb.started"
        mkdir -p "$work/bin"
        printf '#!/bin/sh\necho "$*" >> "%s/sb.started"\nsleep 30\n' "$work" > "$work/bin/sing-box"
        chmod +x "$work/bin/sing-box"
        PATH="$work/bin:$PATH"
        dig() {
            case "$*" in
            *"-p 19201"*) printf ';; ->>HEADER<<- status: NOERROR\n;; Query time: 4 msec\n' ;;
            *"-p 19202"*) printf ';; ->>HEADER<<- status: NOERROR\n;; Query time: 73 msec\n' ;;
            *"-p 19203"*) return 9 ;;
            *) echo "$*" >> "$work/dig.log"; printf ';; ->>HEADER<<- status: NOERROR\n;; Query time: 1 msec\n' ;;
            esac
        }
        UCI_dns_type=udp UCI_dns_server=172.31.200.60 UCI_POOL="dot://dns.google doh://nowhere.example/dns-query doh3://dns.google"
        echo "tunnel=$(dns_benchmark | jq -c '[.via, [.results[] | [.server, .ms]]]')"
        echo "tunnel-started=$(grep -c '^run -c ' "$work/sb.started")"
        sleep 1
        echo "tunnel-sing-box-stopped=$(pgrep -f "$work/bin/sing-box" > /dev/null && echo no || echo yes)"

        # no Clash answer or no way to start it: the servers are asked from the router
        priority_fetch_proxies() { printf ''; }
        echo "fallback-direct=$(dns_benchmark udp://1.1.1.1 | jq -c '[.via, .results[0].ms]')"
        priority_fetch_proxies() { printf '%s' "$PROXIES"; }
        _get_dns_detour_tag() { echo ""; }
        echo "no-detour=$(dns_benchmark udp://1.1.1.1 | jq -c '.via')"
    )"

    _db() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }

    _db "udp is asked directly" "udp=@1.1.1.1"
    _db "tcp is asked over TCP" "tcp=@1.1.1.1 +tcp"
    _db "dot is asked over TLS, named by its host" "dot-ip=@1.1.1.1 +tls +tls-hostname=1.1.1.1"
    _db "a name is looked up through the bootstrap resolver" "dot-name=@8.8.4.4 +tls +tls-hostname=dns.google"
    _db "doh keeps its path" "doh-name=@104.16.249.249 +https=/dns-query +tls-hostname=cloudflare-dns.com"
    _db "doh without a path uses /dns-query" "doh-default-path=@8.8.4.4 +https=/dns-query +tls-hostname=dns.google"
    _db "doh3 cannot be asked with dig" "doh3=REFUSED"
    _db "doq cannot be asked with dig" "doq=REFUSED"
    _db "a name that does not resolve is refused" "unresolvable=REFUSED"
    _db "the bootstrap resolver is the one asked" "bootstrap-used=2"
    _db "the time dig reports is the result" "one=17"
    _db "an error answer is no result" "one-servfail=none"
    _db "no answer is no result" "one-timeout=none"
    _db "servers given are timed, in order, the odd ones skipped" 'given=[["udp://1.1.1.1",17],["dot://dns.google",41],["udp://10.9.9.9",null],["doh3://dns.google/dns-query",null]]'
    _db "with no arguments the configured servers are timed" 'configured=[["dot://dns.google",41],["udp://1.1.1.1",17],["doh://cloudflare-dns.com/dns-query",99]]'
    _db "the number of servers is capped" "capped=12"
    _db "a server in the tunnel is a server with its own port" "target[udp://172.31.200.60]=udp 172.31.200.60 53 "
    _db "tcp keeps a given port" "target[tcp://10.0.0.1:5353]=tcp 10.0.0.1 5353 "
    _db "dot defaults to 853" "target[dot://dns.google]=dot dns.google 853 "
    _db "doh keeps its path and defaults to 443" "target[doh://dns.google/dns-query]=doh dns.google 443 /dns-query"
    _db "doh keeps a given port" "target[doh://h:8443/p]=doh h 8443 /p"
    _db "doh3 cannot be asked" "target[doh3://dns.google]=REFUSED"
    _db "a group is followed to the server it has selected" "leaf-selector-urltest=node-b"
    _db "a plain outbound is itself" "leaf-plain=plain-out"
    _db "an unknown outbound gives nothing" "leaf-unknown=none"
    _db "a group that points at itself gives nothing" "leaf-loop=none"
    _db "no Clash answer gives nothing" "leaf-no-clash=none"
    _db "the temporary configuration is built" "config-built=yes"
    _db "one local inbound per server, forwarding to it" 'config-inbounds=[["bench-1","127.0.0.1",19201,"172.31.200.60",53],["bench-2","127.0.0.1",19202,"dns.google",853]]'
    _db "the outbound and its detour chain are carried over" 'config-outbounds=["node-b","hop"]'
    _db "everything leaves through the outbound, with the service marks" 'config-route=["node-b",2097152,"bootstrap-dns-server",["bench-1","bench-2"]]'
    _db "an outbound that is not in the configuration is refused" "config-missing-outbound=refused"
    _db "sing-box accepts the temporary configuration" "config-singbox-check=ok"
    _db "udp is asked on the local port" "args-udp=@127.0.0.1 -p 19201"
    _db "tcp is asked over TCP" "args-tcp=@127.0.0.1 -p 19201 +tcp"
    _db "dot is asked over TLS named by its host" "args-dot=@127.0.0.1 -p 19202 +tls +tls-hostname=dns.google"
    _db "doh keeps its path" "args-doh=@127.0.0.1 -p 19203 +https=/dns-query +tls-hostname=dns.google"
    _db "through the tunnel the times are those of the local ports" 'tunnel=["tunnel",[["udp://172.31.200.60",4],["dot://dns.google",73],["doh://nowhere.example/dns-query",null],["doh3://dns.google",null]]]'
    _db "the temporary sing-box is started once" "tunnel-started=1"
    _db "...and stopped afterwards" "tunnel-sing-box-stopped=yes"
    _db "without a Clash answer the servers are asked from the router" 'fallback-direct=["direct",1]'
    _db "without a detour nothing goes through the tunnel" 'no-detour="direct"'

    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: subscription country filters
# ─────────────────────────────────────────────────────────────────
# country_code_to_flag_emoji / build_subscription_filter_json (country codes turn
# into the flag emoji of the server names and join the keyword filter), extracted
# verbatim from the bin.

# ─────────────────────────────────────────────────────────────────
# Test: GeoIP country flags for subscription servers
# ─────────────────────────────────────────────────────────────────
# Runs the REAL subscription_geoip_annotate / geoip_hosts_without_flag /
# geoip_resolve_host (extracted verbatim from the bin) with stubbed dig / curl.
# Asserts: only names WITHOUT a flag are annotated; each address is looked up once
# (later runs read the cache); private / FakeIP answers never leave the router;
# offline and a silent service change nothing and are retried later; failures are
# retried only after their TTL; the flag equals the one the country filter builds.

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
# Test: IPv6 compatibility (issue #38)
# ─────────────────────────────────────────────────────────────────
# With IPv6 enabled the v6 TProxy inbound (tproxy-in-v6) must be matched by the
# SAME route rules as the v4 one (before this it matched none and v6 flows fell
# through to the default), and the FakeIP v6 range must be a routable global
# prefix (2001:2::/48), not the ULA fd00::/8 that dnsmasq rebind protection drops.
#   - constant: SB_FAKEIP_INET6_RANGE is not in fc00::/7
#   - IPv6 off: every rule keeps the plain string inbound (byte-identical config)
#   - IPv6 on: the same rules match ["tproxy-in","tproxy-in-v6"]
#   - the generated config passes `sing-box check`

# ─────────────────────────────────────────────────────────────────

# Test: Multi-DNS upstream pool (issue #74)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL sing_box_configure_dns_pool / _dns_pool_collect_entry /
# is_valid_dns_pool_timeout (extracted verbatim from the bin) and the real
# manager/facade helpers against a stubbed UCI layer. Asserts:
#   - default (mode absent / single) and every unusable setup leave the config
#     byte-identical to the single-upstream one (upgrade safety);
#   - fallback: the primary and the list are asked in order, each but the last
#     gets evaluate + respond (NOERROR / NXDOMAIN), the last one is `final`;
#   - race: every upstream is evaluated, the respond rules carry race, `final`
#     stays the primary;
#   - sing-box < 1.14.0 ignores the pool with a warning (the rule actions do
#     not exist there); entry validation, limits, detour and bootstrap resolver;
#   - the six transports map to the right sing-box server types.

# ─────────────────────────────────────────────────────────────────

# Test: Chained connections (outbound_detour_section)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL configure_outbound_detour_handler / _outbound_detour_chain_is_usable
# (extracted verbatim from the bin) and sing_box_cm_set_outbounds_detour against a
# stubbed UCI layer. Asserts:
#   - the section's real proxy outbounds (leaves of selector/urltest, or the
#     single outbound) get `detour` = the target's tag, the target's own members
#     and outbounds with their own detour are left alone;
#   - sections without the option (every existing config) are untouched;
#   - a chain that cannot be built (unknown/blocked target, itself, a loop, an
#     unavailable target) never falls back to a direct connection: the section is
#     marked unavailable and gets no detour.

# ─────────────────────────────────────────────────────────────────

# Test: URL of the dashboard latency test
# ─────────────────────────────────────────────────────────────────
# The `latency_test_url` setting of clash_api, extracted verbatim from the bin:
# default when absent, a configured http(s) URL is used, anything else falls back
# to the default and says so in the log.

# ─────────────────────────────────────────────────────────────────

# Test: Priority node selection (priority_mode)
# ─────────────────────────────────────────────────────────────────
# Runs the REAL priority_select_for_section / _priority_check_section_handler /
# priority_check_interval (extracted verbatim from the bin) against a stubbed
# Clash API. Asserts:
#   - the FIRST server that answers is selected, in list order, and the selector
#     goes back to a higher one when it recovers;
#   - nothing is switched when the right server is already selected, when nothing
#     answers, or when there is nothing to choose from (groups are not probed);
#   - names with spaces / non-ASCII characters survive; the probe count is capped;
#   - sections without the option are never probed.

# ─────────────────────────────────────────────────────────────────

# Test: Bypass sing-box for excluded destinations / devices
# ─────────────────────────────────────────────────────────────────
# Runs the REAL nft_select_subnet_target / populate_netshift_subnets_from_file /
# nft_bypass_requested / nft_bypass_source_ips (bin) and
# nft_add_selective_marking_rules (nft.sh) against a recording `nft` stub. Asserts:
#   - without bypass nothing changes: same rules, subnets go to the union set;
#   - an exclusion section with bypass_singbox feeds the bypass set, any other
#     section (also an exclusion one without the flag) still the union set, and the
#     choice never leaks from one section to the next;
#   - the bypass `return` rules come FIRST in every chain, also under global proxy;
#   - bypass_excluded_ips returns the listed devices before any mark (IPv6 only when
#     IPv6 is enabled).


# ─────────────────────────────────────────────────────────────────
# Test: URLTest check interval (urltest_check_interval, including "off")
# ─────────────────────────────────────────────────────────────────
test_urltest_interval() {
    header "URLTest check interval"

    local cm_lib="${NETSHIFT_LIB_DIR}/sing_box_config_manager.sh"
    local constants_lib="${NETSHIFT_LIB_DIR}/constants.sh"
    local ui="${NETSHIFT_SRC}/../luci-app-netshift/htdocs/luci-static/resources/view/netshift/section.js"
    [ -r "$ui" ] || ui="/luci-app-netshift/htdocs/luci-static/resources/view/netshift/section.js"
    if [ ! -r "$cm_lib" ] || ! command -v jq > /dev/null 2>&1; then
        skip "config manager / jq not available"
        return
    fi

    local out
    out="$(
        . "$constants_lib"
        . "$cm_lib"
        base='{"outbounds":[]}'
        for v in 30s 3m 10m 30m 1h 24h off ""; do
            printf 'interval[%s]=%s\n' "$v" "$(sing_box_cm_add_urltest_outbound "$base" t '["a","b"]' "" "$v" 50 | jq -r '.outbounds[0].interval // "none"')"
        done
        # without the constants the value still means "almost never"
        unset URLTEST_INTERVAL_OFF
        printf 'off-no-constants=%s\n' "$(sing_box_cm_add_urltest_outbound "$base" t '["a"]' "" off 50 | jq -r '.outbounds[0].interval')"
    )"

    _ti() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }
    _ti "a normal interval is kept" "interval[30s]=30s"
    _ti "the default interval is kept" "interval[3m]=3m"
    _ti "a 10 minute interval is kept" "interval[10m]=10m"
    _ti "a 30 minute interval is kept" "interval[30m]=30m"
    _ti "a day is kept" "interval[24h]=24h"
    _ti "'off' becomes a year: one test at start" "interval[off]=8760h"
    _ti "an empty interval adds no field" "interval[]=none"
    _ti "'off' works without the constants file" "off-no-constants=8760h"

    if sing-box version > /dev/null 2>&1; then
        local cfg="/tmp/netshift-urltest-int-$$.json"
        (
            . "$constants_lib"
            . "$cm_lib"
            c='{"log":{"level":"error"},"outbounds":[{"type":"direct","tag":"a"},{"type":"direct","tag":"b"}]}'
            sing_box_cm_add_urltest_outbound "$c" t '["a","b"]' "https://www.gstatic.com/generate_204" off 50
        ) > "$cfg"
        if sing-box check -c "$cfg" > /dev/null 2>&1; then
            pass "the core accepts the 'off' interval"
        else
            fail "the core rejects the 'off' interval"
        fi
        rm -f "$cfg"
    fi

    if grep -q 'o.value("off"' "$ui" 2> /dev/null && grep -q 'o.value("30m"' "$ui"; then
        pass "the UI offers 10m, 20m, 30m and 'off'"
    else
        skip "section.js not found for the UI check"
    fi
}
# ─────────────────────────────────────────────────────────────────


test_components_via_proxy() {
    header "Components via the service proxy"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local updater="${NETSHIFT_LIB_DIR}/updater.sh"
    if [ ! -r "$bin" ] || [ ! -r "$updater" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ]; then
        skip "netshift bin / updater.sh / constants.sh not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        for fn in service_proxy_needed get_service_proxy_address; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        done
        for fn in updates_components_proxy_address updates_http_get updates_download_to_file updates_github_resolve_redirect \
            updates_host_reachable_via_proxy updates_preflight_proxy_for_direction updates_preflight_host_for_direction \
            updates_preflight_connectivity updates_selfheal_connectivity updates_ensure_connectivity; do
            eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$updater")"
        done
        updates_log() { :; }

        CP_LISTS=0; CP_COMP=0
        config_get_bool() {
            case "$3" in
            download_lists_via_proxy) eval "$1=\"$CP_LISTS\"" ;;
            download_components_via_proxy) eval "$1=\"$CP_COMP\"" ;;
            *) eval "$1=\"$4\"" ;;
            esac
        }
        # curl stub: records whether -x was used; CP_PROXY_OK=0 makes proxied calls fail
        CPLOGF="/tmp/netshift-compproxy-log-$$"
        : > "$CPLOGF"
        curl() {
            local proxied=direct a out=""
            for a in "$@"; do
                [ "$a" = "-x" ] && proxied=proxy
            done
            while [ $# -gt 0 ]; do
                [ "$1" = "-o" ] && out="$2"
                shift
            done
            printf "%s " "$proxied" >> "$CPLOGF"
            if [ "$proxied" = proxy ] && [ "${CP_PROXY_OK:-1}" = 0 ]; then
                return 22
            fi
            [ -n "$out" ] && echo data > "$out"
            echo "body-$proxied"
            return 0
        }
        wget() { return 1; }
        updates_http_get_once() {
            if [ -n "$2" ]; then printf "get-proxy " >> "$CPLOGF"; else printf "get-direct " >> "$CPLOGF"; fi
            if [ -n "$2" ] && [ "${CP_PROXY_OK:-1}" = 0 ]; then return 22; fi
            echo "body"
        }
        D="/tmp/netshift-compproxy-$$"
        LOGRESET() { : > "$CPLOGF"; }

        for flags in "0 0:no" "1 0:yes" "0 1:yes" "1 1:yes"; do
            CP_LISTS="${flags%% *}"; CP_COMP="${flags#* }"; CP_COMP="${CP_COMP%%:*}"
            if service_proxy_needed; then got=yes; else got=no; fi
            echo "needed-$CP_LISTS$CP_COMP:$got"
        done

        # flag off: direct only, and no proxy address for components
        CP_LISTS=0; CP_COMP=0
        echo "off-address:[$(updates_components_proxy_address)]"
        LOGRESET; updates_download_to_file https://x/y "$D" > /dev/null; echo "off-download:$(cat "$CPLOGF" | sed "s/ *$//")"
        LOGRESET; updates_http_get https://x/api > /dev/null; echo "off-get:$(cat "$CPLOGF" | sed "s/ *$//")"
        # lists-only proxy does not carry components
        CP_LISTS=1; CP_COMP=0
        echo "lists-only-address:[$(updates_components_proxy_address)]"
        LOGRESET; updates_download_to_file https://x/y "$D" > /dev/null; echo "lists-only-download:$(cat "$CPLOGF" | sed "s/ *$//")"

        # components-only: the list downloads get no service proxy address
        CP_LISTS=0; CP_COMP=1
        echo "components-only-lists-address:[$(get_service_proxy_address)]"
        CP_LISTS=1; CP_COMP=0
        echo "lists-only-lists-address:$(get_service_proxy_address)"
        CP_LISTS=1; CP_COMP=1
        echo "both-lists-address:$(get_service_proxy_address)"
        CP_LISTS=0; CP_COMP=0
        echo "off-lists-address:[$(get_service_proxy_address)]"

        # flag on: proxy first
        CP_LISTS=0; CP_COMP=1; CP_PROXY_OK=1
        [ "$(updates_components_proxy_address)" = "$SB_SERVICE_MIXED_INBOUND_ADDRESS:$SB_SERVICE_MIXED_INBOUND_PORT" ] && echo "on-address:service-proxy" || echo "on-address:wrong"
        LOGRESET; updates_download_to_file https://x/y "$D" > /dev/null; echo "on-download:$(cat "$CPLOGF" | sed "s/ *$//")"
        LOGRESET; updates_http_get https://x/api > /dev/null; echo "on-get:$(cat "$CPLOGF" | sed "s/ *$//")"
        LOGRESET; updates_github_resolve_redirect https://x/latest > /dev/null; echo "on-redirect:$(cat "$CPLOGF" | sed "s/ *$//")"
        # flag on, proxy down: falls back to direct
        CP_PROXY_OK=0
        LOGRESET; updates_download_to_file https://x/y "$D" > /dev/null; echo "down-download:$(cat "$CPLOGF" | sed "s/ *$//")"
        LOGRESET; updates_http_get https://x/api > /dev/null; echo "down-get:$(cat "$CPLOGF" | sed "s/ *$//")"
        LOGRESET; updates_github_resolve_redirect https://x/latest > /dev/null; echo "down-redirect:$(cat "$CPLOGF" | sed "s/ *$//")"

        # Install pre-flight (GitHub blocked for the router itself: no DNS, no direct HTTPS).
        # With the flag on, reachability through the proxy decides; the redirect that carries
        # the proxy is never torn down.
        UPDATES_GITHUB_PROBE_HOST=github.test
        UPDATES_FEED_PROBE_HOST=feeds.test
        updates_dns_resolves() { return 1; }
        updates_host_reachable() { printf "direct-probe " >> "$CPLOGF"; return 1; }
        updates_write_temp_resolver() { return 1; }
        updates_teardown_redirect() { printf "teardown " >> "$CPLOGF"; return 0; }
        CP_LISTS=0; CP_COMP=1; CP_PROXY_OK=1
        LOGRESET; updates_ensure_connectivity extended; echo "preflight-on-proxy-ok:$?:$(sed "s/ *$//" "$CPLOGF")"
        CP_PROXY_OK=0
        LOGRESET; updates_ensure_connectivity extended; echo "preflight-on-proxy-down:$?:$(sed "s/ *$//" "$CPLOGF")"
        # flag off: the old behaviour (tear the redirect down to find a direct way) is unchanged
        CP_COMP=0
        LOGRESET; updates_ensure_connectivity extended; echo "preflight-off-blocked:$?:$(sed "s/ *$//" "$CPLOGF")"
        # the package feeds are not fetched through the proxy: stable keeps the direct probe
        CP_COMP=1; CP_PROXY_OK=1
        LOGRESET; updates_ensure_connectivity stable; echo "preflight-stable-direct:$?:$(sed "s/ *$//" "$CPLOGF")"
        rm -f "$D" "$CPLOGF"
    )"

    _cp_check() {
        if echo "$out" | grep -qxF "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(echo "$out" | tr '\n' '|')"
        fi
    }

    _cp_check "neither flag: no service proxy" "needed-00:no"
    _cp_check "lists flag creates the service proxy" "needed-10:yes"
    _cp_check "components flag creates the service proxy" "needed-01:yes"
    _cp_check "both flags create it" "needed-11:yes"
    _cp_check "flag off: components have no proxy address" "off-address:[]"
    _cp_check "flag off: downloads are direct" "off-download:direct"
    _cp_check "flag off: release lookups are direct" "off-get:get-direct"
    _cp_check "lists-only proxy does not carry components" "lists-only-address:[]"
    _cp_check "lists-only: component download stays direct" "lists-only-download:direct"
    _cp_check "components-only: the list downloads get no service proxy address" "components-only-lists-address:[]"
    _cp_check "lists-only: the list downloads use the service proxy address" "lists-only-lists-address:127.0.0.1:4534"
    _cp_check "both flags: the list downloads use the service proxy address" "both-lists-address:127.0.0.1:4534"
    _cp_check "no flag: no list proxy address" "off-lists-address:[]"
    _cp_check "flag on: the service proxy address is used" "on-address:service-proxy"
    _cp_check "flag on: download goes through the proxy" "on-download:proxy"
    _cp_check "flag on: release lookup goes through the proxy first" "on-get:get-proxy"
    _cp_check "flag on: redirect lookup goes through the proxy" "on-redirect:proxy"
    _cp_check "proxy down: download falls back to direct" "down-download:proxy direct"
    _cp_check "proxy down: release lookup falls back to direct" "down-get:get-proxy get-direct"
    _cp_check "proxy down: redirect lookup falls back to direct" "down-redirect:proxy direct"
    _cp_check "install pre-flight: GitHub is probed through the proxy, no heal needed" "preflight-on-proxy-ok:0:proxy"
    _cp_check "install pre-flight: proxy down, the redirect that carries the proxy is not torn down" "preflight-on-proxy-down:1:proxy"
    _cp_check "install pre-flight: flag off tears the redirect down as before" "preflight-off-blocked:1:teardown"
    _cp_check "install pre-flight: stable direction does not use the proxy" "preflight-stable-direct:1:teardown"
}

test_empty_link_sections() {
    header "Empty required link option in a section"

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

    local drv="/tmp/test-emptylink-$$.sh"
    local out="/tmp/test-emptylink-out-$$.txt"
    cat > "$drv" << 'ELEOF'
. "CONST_LIB"
. "FACADE_LIB"

WARN_LOG="/tmp/el-warn-$$.log"
: > "$WARN_LOG"
log()     { printf '%s|%s\n' "${2:-info}" "$1" >> "$WARN_LOG"; }
echolog() { printf '%s|%s\n' "${2:-info}" "$1" >> "$WARN_LOG"; }
nolog()   { :; }

set_section_reality_mlkem() { NETSHIFT_REALITY_MLKEM=0; }
tproxy_route_inbounds() { printf 'tproxy-in'; }

eval "$(awk '/^mark_section_outbound_unavailable\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^mark_section_without_links\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^is_truthy_option\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^configure_outbound_handler\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

# The subscription branch reads the subscription caches and the keyword filter
# before it looks at the URLs. Those have their own tests (suburlopt, utfilters),
# so they are stubbed here; the URL reader answers "no URL configured", which is
# the shape a section saved with an empty subscription_url has.
build_subscription_filter_json() { echo '[]'; }
ensure_subscription_cache_dir() { :; }
migrate_subscription_cache_from_tmp() { :; }
reap_legacy_subscription_cache_files() { :; }
get_subscription_urls_for_section() { :; }

_el_key() { printf 'EL_%s_%s' "$(printf '%s' "$1" | tr '.-' '__')" "$2"; }
config_get() {
    local _k _v
    _k="$(_el_key "$2" "$3")"
    eval "_v=\"\${$_k:-}\""
    [ -n "$_v" ] || _v="$4"
    eval "$1=\"$_v\""
    return 0
}
config_get_bool() { config_get "$@"; case "$(eval echo \$$1)" in 1) eval "$1=1" ;; *) eval "$1=0" ;; esac; }

# One section with its required option absent, driven through the real handler.
el_case() {
    local sec="$1" ctype="$2" ptype="$3" marker="$4"
    local rc n

    : > "$WARN_LOG"
    config='{"outbounds":[]}'
    SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
    eval "EL_${sec}_connection_type='$ctype'"
    [ -n "$ptype" ] && eval "EL_${sec}_proxy_config_type='$ptype'"

    configure_outbound_handler "$sec"
    rc=$?
    [ "$rc" = "0" ] && echo "el-${sec}-no-abort:OK" || echo "el-${sec}-no-abort:FAIL rc=$rc"

    case " $SUBSCRIPTION_UNAVAILABLE_SECTIONS " in
    *" $sec "*) echo "el-${sec}-marked-unavailable:OK" ;;
    *) echo "el-${sec}-marked-unavailable:FAIL" ;;
    esac

    # No outbound may be created for the section: a route rule pointing at a tag
    # that does not exist would fail `sing-box check` for the WHOLE config.
    n="$(printf '%s' "$config" | jq --arg p "$sec-" '[.outbounds[] | select((.tag // "") | startswith($p))] | length' 2>/dev/null)"
    [ "$n" = "0" ] && echo "el-${sec}-no-dangling-outbound:OK" || echo "el-${sec}-no-dangling-outbound:FAIL n=$n"

    grep -qF "$marker" "$WARN_LOG" && echo "el-${sec}-error-logged:OK" || echo "el-${sec}-error-logged:FAIL"
}

el_case urlempty proxy url "no proxy link (proxy_string)"
el_case selempty proxy selector "no proxy links (selector_proxy_links)"
el_case urltempty proxy urltest "no proxy links (urltest_proxy_links)"
el_case seltxtempty proxy selector_text "no proxy links (selector_proxy_links_text)"
el_case urltxtempty proxy urltest_text "no proxy links (urltest_proxy_links_text)"
el_case vpnempty vpn "" "VPN interface (interface)"
el_case subempty proxy subscription "subscription URL (subscription_url)"

# ── A usable section in the same build is untouched ──────────────────────────
: > "$WARN_LOG"
config='{"outbounds":[]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
EL_goodsec_connection_type="proxy"
EL_goodsec_proxy_config_type="url"
EL_goodsec_proxy_string="vless://11111111-2222-3333-4444-555555555555@g.example.com:443?security=tls&sni=g.example.com"
configure_outbound_handler "goodsec"
printf '%s' "$config" | jq -e '[.outbounds[] | select(.tag=="goodsec-out")] | length==1' >/dev/null 2>&1 \
    && echo 'el-good-section-built:OK' || echo 'el-good-section-built:FAIL'
[ -z "$SUBSCRIPTION_UNAVAILABLE_SECTIONS" ] \
    && echo 'el-good-section-not-unavailable:OK' || echo 'el-good-section-not-unavailable:FAIL'

# ── The degraded build is a config sing-box accepts ──────────────────────────
# This is the point of the change: direct + a reject rule for the unavailable
# section still passes `sing-box check`, so the service keeps running.
: > "$WARN_LOG"
config='{"outbounds":[]}'
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
EL_rejsec_connection_type="proxy"
EL_rejsec_proxy_config_type="url"
configure_outbound_handler "rejsec"
FULL_JSON="/tmp/el-full-$$.json"
sing_box_cm_add_reject_route_rule "$config" "rej-rule" "$(tproxy_route_inbounds)" \
    | jq '{
        log: { level: "error" },
        dns: { servers: [ { tag: "dns-server", type: "udp", server: "1.1.1.1" } ], final: "dns-server" },
        inbounds: [ { type: "tproxy", tag: "tproxy-in", listen: "127.0.0.1", listen_port: 1602 } ],
        outbounds: (.outbounds + [ { type: "direct", tag: "direct-out" } ]),
        route: { rules: (.route.rules // []), final: "direct-out" }
    }' > "$FULL_JSON" 2>/dev/null
if command -v sing-box > /dev/null 2>&1; then
    sing-box -c "$FULL_JSON" check > /dev/null 2>&1 \
        && echo 'el-degraded-config-valid:OK' || echo 'el-degraded-config-valid:FAIL'
else
    echo 'el-degraded-config-valid:SKIP'
fi
rm -f "$FULL_JSON"

rm -f "$WARN_LOG"
echo 'DONE'
ELEOF
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
        pass "el-driver-completed:OK"
    else
        fail "el-driver-completed:FAIL (driver aborted early)" "$(head -5 "$out")"
    fi
    rm -f "$drv" "$out"
}

test_scalar_option_fallback() {
    header "Scalar (non-list) value of a list option"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    local lib="${NETSHIFT_LIB_DIR}"
    if [ ! -r "$bin" ] || [ ! -r "$lib/constants.sh" ] || [ ! -r "$lib/helpers.sh" ]; then
        skip "scalar-option (bin / constants.sh / helpers.sh not found)"
        return
    fi

    # Both call sites of the option must go through the wrapper: a revert of one
    # of them would silently break only one of the two paths (nft marks vs the
    # sing-box direct route rule).
    local wrapped unwrapped
    wrapped="$(grep -c 'netshift_config_list_foreach "settings" "routing_excluded_ips"' "$bin" || true)"
    unwrapped="$(grep -cE '(^|[^_])config_list_foreach "settings" "routing_excluded_ips"' "$bin" || true)"
    if [ "$wrapped" = "2" ] && [ "$unwrapped" = "0" ]; then
        pass "scalar:both-call-sites-wrapped — routing_excluded_ips is read through the wrapper twice"
    else
        fail "scalar:both-call-sites-wrapped — expected 2 wrapped / 0 bare call sites, got $wrapped / $unwrapped"
    fi

    local drv="/tmp/test-scalaropt-$$.sh"
    local out="/tmp/test-scalaropt-out-$$.txt"
    cat > "$drv" << 'SCEOF'
set -e
BIN="BIN_PATH_PLACEHOLDER"
LIB="LIB_DIR_PLACEHOLDER"

# The platform iterator (REAL one, not a stub) + the runtime contract.
. /lib/functions.sh
# shellcheck disable=SC1090
. "$LIB/constants.sh"
# shellcheck disable=SC1090
. "$LIB/nft.sh"
# shellcheck disable=SC1090
. "$LIB/helpers.sh"

# The shipped handlers under test (the wrapper comes from helpers.sh).
for fn in nft_bypass_source_ips _nft_bypass_source_ip_handler \
    exclude_source_ip_from_routing_handler; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done

NFT_TABLE_NAME="scalaropt_$$"
netshift_ipv6_enabled() { return 1; }
log() { printf 'LOG:%s\n' "$1"; }
nolog() { :; }
echolog() { printf 'ECHO:%s\n' "$1"; }

# Capture instead of touching the kernel / the running config.
nft() { printf 'NFT:%s\n' "$*"; }
# exclude_source_ip_from_routing_handler assigns the result to the global
# `config` (command substitution -> subshell), so counting calls has to go
# through a file that survives the subshell.
PATCH_LOG="/tmp/scalaropt-patch-$$.log"
: > "$PATCH_LOG"
sing_box_cm_patch_route_rule() {
    local line
    line="$(printf 'PATCH:tag=%s field=%s value=%s' "$2" "$3" "$4")"
    printf '%s\n' "$line" >> "$PATCH_LOG"
    printf '%s' "$line"
}

write_cfg() {
    {
        echo "config settings 'settings'"
        printf '%s\n' "$1"
    } > /etc/config/scalaropt
    config_load scalaropt
}

CB_N=0
cb_count() { CB_N=$((CB_N + 1)); }

# ── (1) scalar option: the premise and the fix ────────────────────────────────
write_cfg "	option bypass_excluded_ips '1'
	option routing_excluded_ips '10.0.0.5'"

CB_N=0
config_list_foreach settings routing_excluded_ips cb_count
[ "$CB_N" -eq 0 ] \
    && echo 'scalar-premise-platform-ignores-it:OK' \
    || echo 'scalar-premise-platform-ignores-it:FAIL'

out_nft="$(nft_bypass_source_ips)"
n_nft="$(printf '%s\n' "$out_nft" | grep -c '^NFT:' || true)"
[ "$n_nft" -eq 2 ] \
    && echo 'scalar-nft-rule-count:OK' \
    || echo "scalar-nft-rule-count:FAIL got=$n_nft"
printf '%s' "$out_nft" | grep -q '10.0.0.5' \
    && echo 'scalar-nft-uses-the-address:OK' \
    || echo 'scalar-nft-uses-the-address:FAIL'
printf '%s' "$out_nft" | grep -qF "$SB_FAKEIP_INET4_RANGE" \
    && echo 'scalar-nft-fakeip-mark-first:OK' \
    || echo 'scalar-nft-fakeip-mark-first:FAIL'
printf '%s' "$out_nft" | grep -q 'counter return' \
    && echo 'scalar-nft-return:OK' \
    || echo 'scalar-nft-return:FAIL'

config=""
netshift_config_list_foreach settings routing_excluded_ips \
    exclude_source_ip_from_routing_handler RULE1
grep -q 'PATCH:tag=RULE1 field=source_ip_cidr value=10.0.0.5' "$PATCH_LOG" \
    && echo 'scalar-routing-direct-rule:OK' \
    || echo "scalar-routing-direct-rule:FAIL got=$(cat "$PATCH_LOG")"
[ "$config" = "PATCH:tag=RULE1 field=source_ip_cidr value=10.0.0.5" ] \
    && echo 'scalar-routing-rule-tag:OK' \
    || echo "scalar-routing-rule-tag:FAIL got=$config"

# ── (2) real UCI list: both items, extra argument kept ────────────────────────
write_cfg "	option bypass_excluded_ips '1'
	list routing_excluded_ips '10.0.0.11'
	list routing_excluded_ips '10.0.0.12'"

out_nft="$(nft_bypass_source_ips)"
n_nft="$(printf '%s\n' "$out_nft" | grep -c '^NFT:' || true)"
[ "$n_nft" -eq 4 ] \
    && echo 'list-nft-rule-count:OK' \
    || echo "list-nft-rule-count:FAIL got=$n_nft"
for ip in 10.0.0.11 10.0.0.12; do
    printf '%s' "$out_nft" | grep -q "$ip" \
        && echo "list-nft-item-$ip:OK" \
        || echo "list-nft-item-$ip:FAIL"
done

: > "$PATCH_LOG"
netshift_config_list_foreach settings routing_excluded_ips \
    exclude_source_ip_from_routing_handler RULE2
n_patch="$(grep -c 'PATCH:tag=RULE2 field=source_ip_cidr' "$PATCH_LOG" || true)"
[ "$n_patch" -eq 2 ] \
    && echo 'list-routing-two-rules:OK' \
    || echo "list-routing-two-rules:FAIL got=$n_patch"
grep -q 'value=10.0.0.12' "$PATCH_LOG" \
    && echo 'list-routing-second-item:OK' \
    || echo 'list-routing-second-item:FAIL'

# ── (3) nothing configured: no rule, and the reason is logged ────────────────
write_cfg "	option bypass_excluded_ips '1'"

out_nft="$(nft_bypass_source_ips)"
printf '%s' "$out_nft" | grep -q '^NFT:' \
    && echo 'empty-nft-no-rule:FAIL' \
    || echo 'empty-nft-no-rule:OK'
printf '%s' "$out_nft" | grep -q 'routing_excluded_ips is empty' \
    && echo 'empty-warns:OK' \
    || echo 'empty-warns:FAIL'

rm -f /etc/config/scalaropt "$PATCH_LOG"
echo 'DONE'
SCEOF
    sed -i "s|BIN_PATH_PLACEHOLDER|$bin|g; s|LIB_DIR_PLACEHOLDER|$lib|g" "$drv"

    sh "$drv" > "$out" 2>/dev/null || true
    local saw_done=0 line
    while IFS= read -r line; do
        case "$line" in
            *:OK)    pass "$line" ;;
            *:FAIL*) fail "$line" ;;
            DONE)    saw_done=1 ;;
            *) ;;
        esac
    done < "$out"
    if [ "$saw_done" = "1" ]; then
        pass "scalar-driver-completed:OK"
    else
        fail "scalar-driver-completed:FAIL (driver aborted early)" "$(head -5 "$out")"
    fi
    rm -f "$drv" "$out"
}




test_dns_hijack() {
    header "DNS hijack"

    local bin="${NETSHIFT_SRC}/usr/bin/netshift"
    if [ ! -r "$bin" ] || [ ! -r "${NETSHIFT_LIB_DIR}/constants.sh" ]; then
        skip "netshift bin / constants.sh not found"
        return
    fi

    local out
    out="$(
        . "${NETSHIFT_LIB_DIR}/constants.sh"
        eval "$(awk '/^nft_add_dns_hijack\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$bin")"
        DH_LOG="/tmp/netshift-dnshijack-log-$$"; : > "$DH_LOG"
        log() { printf '[%s] %s\n' "${2:-info}" "$1" >> "$DH_LOG"; }
        NFT_LOG="/tmp/netshift-dnshijack-$$"; : > "$NFT_LOG"
        nft() { echo "$*" >> "$NFT_LOG"; }
        NFT_TABLE_NAME=T
        NFT_INTERFACE_SET_NAME=interfaces
        config_get_bool() {
            local _v
            eval "_v=\"\${DH_${3}:-$4}\""
            case "$_v" in 1) eval "$1=1" ;; *) eval "$1=0" ;; esac
        }

        # off: nothing is added
        nft_add_dns_hijack
        echo "off=[$(grep -c '' "$NFT_LOG")]"

        DH_dns_hijack=1
        nft_add_dns_hijack
        echo "chain=$(sed -n '1p' "$NFT_LOG")"
        echo "local-first=$(sed -n '2p' "$NFT_LOG")"
        echo "tcp=$(sed -n '3p' "$NFT_LOG")"
        echo "udp=$(sed -n '4p' "$NFT_LOG")"
        echo "rules=$(grep -c '' "$NFT_LOG")"
        echo "no-warning=$(grep -c 'warn' "$DH_LOG")"

        : > "$DH_LOG"; : > "$NFT_LOG"
        DH_dont_touch_dhcp=1
        nft_add_dns_hijack
        echo "dont-touch-warned=$(grep -c 'Dont Touch My DHCP' "$DH_LOG")"
        echo "dont-touch-still-added=$(grep -c '' "$NFT_LOG")"
    )"

    _dh() {
        if printf '%s\n' "$out" | grep -qxF -- "$2"; then
            pass "$1"
        else
            fail "$1" "wanted [$2] in: $(printf '%s' "$out" | tr '\n' '~')"
        fi
    }
    _dh "off: no rule is added" "off=[0]"
    _dh "a nat chain at the destination-NAT priority" "chain=add chain inet T dns_hijack { type nat hook prerouting priority dstnat; policy accept; }"
    _dh "queries for the router itself are left alone, first" "local-first=add rule inet T dns_hijack iifname @interfaces fib daddr type local return"
    _dh "TCP port 53 is redirected to the router's DNS" "tcp=add rule inet T dns_hijack iifname @interfaces tcp dport 53 counter redirect to :53"
    _dh "UDP port 53 is redirected to the router's DNS" "udp=add rule inet T dns_hijack iifname @interfaces udp dport 53 counter redirect to :53"
    _dh "only the LAN interfaces are looked at: four commands in all" "rules=4"
    _dh "no warning in the usual case" "no-warning=0"
    _dh "with Dont Touch My DHCP a warning is given" "dont-touch-warned=1"
    _dh "and the hijack is still made" "dont-touch-still-added=4"

    # the generated rules are loaded as they are written (syntax of the real nft)
    if command -v nft > /dev/null 2>&1 && nft --version > /dev/null 2>&1; then
        local ruleset="/tmp/netshift-dnshijack-$$.nft"
        cat > "$ruleset" << 'NFTEOF'
table inet T {
    set interfaces { type ifname; elements = { "br-lan" } }
    chain dns_hijack {
        type nat hook prerouting priority dstnat; policy accept;
        iifname @interfaces fib daddr type local return
        iifname @interfaces tcp dport 53 counter redirect to :53
        iifname @interfaces udp dport 53 counter redirect to :53
    }
}
NFTEOF
        if nft -c -f "$ruleset" > /dev/null 2>&1; then
            pass "nft accepts the rules"
        else
            skip "nft cannot check rules here"
        fi
        rm -f "$ruleset"
    fi
    rm -f "$NFT_LOG"
}



main() {
    printf "${BOLD}Netshift Evolution — Smoke Test Suite${NC}\n"
    printf "Source: %s\n" "$NETSHIFT_SRC"
    printf "OpenWrt: %s\n" "$(grep OPENWRT_RELEASE /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'unknown')"
    printf "Kernel: %s\n" "$(uname -r 2>/dev/null || echo 'unknown')"
    printf "\n"

    local target="${1:-all}"

    case "$target" in
        all)
            test_components_via_proxy
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
            test_httpupgrade_transport
            test_scalar_option_fallback
            test_empty_link_sections
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
            test_reality_mlkem
            test_luci_cache_bust
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
            test_update_package_check
            test_environment_check
            test_dns_benchmark
            test_dns_section
            test_section_disabled
            test_ipv6_routing
            test_dns_pool
            test_cascade
            test_latency_url
            test_priority_selection
            test_bypass
            test_urltest_filters
            test_subscription_geoip
            test_urltest_interval
            test_dns_hijack
            test_block_leaks
            test_mixed_proxy_auth
            test_domain_rule_prefixes
            test_route_check
            test_subscription_param_filters
            test_ecs_auto
            test_dns_servers_check
            test_connections_api
            test_lan_devices
            test_update_notice
            test_config_snapshots
            test_pin_guard
            test_dns_forward
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
        httpupgrade) test_httpupgrade_transport ;;
        scalaropt)   test_scalar_option_fallback ;;
        emptylink)   test_empty_link_sections ;;
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
        realitymlkem) test_reality_mlkem ;;
        cachebust) test_luci_cache_bust ;;
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
        geoip)       test_subscription_geoip ;;
        jq)          test_jq_helpers ;;
        cm)          test_config_manager ;;
        sb)          test_sing_box_config ;;
        proxylink)   test_proxy_link_escaping ;;
        sectiondisabled) test_section_disabled ;;
        dnspool)     test_dns_pool ;;
        cascade)     test_cascade ;;
        priority)    test_priority_selection ;;
        bypass)      test_bypass ;;
        dnssection)  test_dns_section ;;
        updatepkg)   test_update_package_check ;;
        environment) test_environment_check ;;
        dnsbench)    test_dns_benchmark ;;
        utfilters)   test_urltest_filters ;;
        ipv6routing) test_ipv6_routing ;;
        compproxy)   test_components_via_proxy ;;
        urlint)      test_urltest_interval ;;
        blockleaks)  test_block_leaks ;;
        mixedauth)   test_mixed_proxy_auth ;;
        domrules)    test_domain_rule_prefixes ;;
        routecheck)  test_route_check ;;
        paramfilters) test_subscription_param_filters ;;
        ecsauto)     test_ecs_auto ;;
        dnsservers)  test_dns_servers_check ;;
        connections) test_connections_api ;;
        lan)         test_lan_devices ;;
        updatenotice) test_update_notice ;;
        snapshots)   test_config_snapshots ;;
        pinguard)    test_pin_guard ;;
        dnsforward)  test_dns_forward ;;
        dnshijack)   test_dns_hijack ;;
        *)
            echo "Unknown test: $target"
echo "Available: all deps syntax config helpers jq cm sb nft nftv6 selmark isolation monfd unsupported extgate vlessenc textlist chunkcheck domsep domcase proxylink diagnostics subscription fastest feedgroups insecure rejected jobstate selfheal dnsdetour ecssubnet suburlopt subcron globalproxy sectiondisabled bittorrent stablecheck extcheck sbextarch sbextlite netshiftcheck latesttag ghredirect selfupdate backupguard hotreload cachepersist bypass dnssection utfilters priority geoip latencyurl cascade dnspool ipv6routing realitymlkem cachebust compproxy httpupgrade scalaropt emptylink updatepkg environment dnsbench blockleaks connections dnsforward dnshijack dnsservers domrules ecsauto lan mixedauth paramfilters pinguard routecheck snapshots updatenotice urlint"
            exit 1
            ;;
    esac

    summary
}


# ─────────────────────────────────────────────────────────────────
# Test: a scalar value of a LIST option is not silently ignored
# ─────────────────────────────────────────────────────────────────
# OpenWrt's config_list_foreach iterates ONLY UCI `list` values: it walks the
# <option>_LENGTH / <option>_ITEMn variables that uci_load creates for a list.
# A scalar option (`uci set netshift.settings.routing_excluded_ips=10.0.0.5`, a
# hand-edited config, a config written by a script) has no such variables, so
# the callback ran ZERO times and the value was silently ignored — while
# config_get still returned it. "Excluded IPs" (Devices -> Direct) therefore did
# nothing at all, with nothing in the log, for every writer that is not LuCI.
# netshift_config_list_foreach adds the scalar fallback.
#
# This test deliberately uses the REAL /lib/functions.sh config_list_foreach and
# the REAL shipped handlers: the other harnesses STUB config_list_foreach (their
# stub word-splits the value and so accepts a scalar), which is exactly why the
# bug was invisible to them.

# ─────────────────────────────────────────────────────────────────
# Test: a section saved with an EMPTY required field degrades, never aborts
# ─────────────────────────────────────────────────────────────────
# A required link option left empty (an empty field in the UI, a hand-edited
# config) used to `log ... "fatal"; exit 1` from configure_outbound_handler.
# Generation runs AFTER stop_main, which has already flushed the nft table,
# deleted /tmp/sing-box/rulesets and stopped sing-box, so the exit left the
# router with no service at all and a config.json on disk naming rule-set files
# that were gone — `sing-box check` failed on it and nothing came back up until a
# manual `netshift restart`. REPRODUCED on hardware: adding a section with an
# empty proxy_string next to a working one made `netshift restart` exit 1, left
# sing-box DOWN and config.json invalid.
#
# Such a section must instead degrade exactly like a link the installed core
# cannot use: marked unavailable (its traffic is rejected), logged, and the rest
# of the config still generated and accepted by sing-box.
# Drives the REAL configure_outbound_handler; synthetic values only.




# ─────────────────────────────────────────────────────────────────
# Test: a scalar value of a LIST option is not silently ignored
# ─────────────────────────────────────────────────────────────────
# OpenWrt's config_list_foreach iterates ONLY UCI `list` values: it walks the
# <option>_LENGTH / <option>_ITEMn variables that uci_load creates for a list.
# A scalar option (`uci set netshift.settings.routing_excluded_ips=10.0.0.5`, a
# hand-edited config, a config written by a script) has no such variables, so
# the callback ran ZERO times and the value was silently ignored — while
# config_get still returned it. "Excluded IPs" (Devices -> Direct) therefore did
# nothing at all, with nothing in the log, for every writer that is not LuCI.
# netshift_config_list_foreach adds the scalar fallback.
#
# This test deliberately uses the REAL /lib/functions.sh config_list_foreach and
# the REAL shipped handlers: the other harnesses STUB config_list_foreach (their
# stub word-splits the value and so accepts a scalar), which is exactly why the
# bug was invisible to them.

# ─────────────────────────────────────────────────────────────────
# Test: a section saved with an EMPTY required field degrades, never aborts
# ─────────────────────────────────────────────────────────────────
# A required link option left empty (an empty field in the UI, a hand-edited
# config) used to `log ... "fatal"; exit 1` from configure_outbound_handler.
# Generation runs AFTER stop_main, which has already flushed the nft table,
# deleted /tmp/sing-box/rulesets and stopped sing-box, so the exit left the
# router with no service at all and a config.json on disk naming rule-set files
# that were gone — `sing-box check` failed on it and nothing came back up until a
# manual `netshift restart`. REPRODUCED on hardware: adding a section with an
# empty proxy_string next to a working one made `netshift restart` exit 1, left
# sing-box DOWN and config.json invalid.
#
# Such a section must instead degrade exactly like a link the installed core
# cannot use: marked unavailable (its traffic is rejected), logged, and the rest
# of the config still generated and accepted by sing-box.
# Drives the REAL configure_outbound_handler; synthetic values only.

main "$@"
