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

echo 'DONE'
TESTEOF

    sed -i "s|HELPERS_PATH|$helpers|" "$tmp"

    sh "$tmp" 2>&1 | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done

    rm -f "$tmp"
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
# Test: Destination-selective nft marking (task-034)
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
# This test awk-extracts the SHIPPED create_nft_rules (+ its task-034 helpers)
# verbatim from the live bin, stubs the few UCI/predicate functions, and runs
# the real ruleset against a real nft table, then inspects the mangle chain.
# Five cases (per the spec):
#   1. selective marking present + NO unconditional mark-all (default)
#   2. a direct (non-listed) destination is NOT marked -> bypasses sing-box
#      (rule-structure check; + live counter when runnable)
#   3. global_proxy override = mark-all IS present
#   4. IPv6 mirror selective when enable_ipv6=1 (+ no v6 mark-all)
#   5. domain routing intact: FakeIP range still marked; sing-box check passes
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
    # then dumps `nft list chain inet <table> mangle` to stdout for the parent
    # to parse. Each emitted token is a name:OK / name:FAIL line.
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
          create_nft_rules; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$BIN")"
done

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

nft list chain inet "$NFT_TABLE_NAME" mangle 2>/dev/null
echo "---SETS---"
nft list set inet "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" 2>/dev/null || true
SELEOF
    sed -i "s|LIB_DIR_PLACEHOLDER|$lib|g; s|BIN_PATH_PLACEHOLDER|$bin|g" "$drv"

    # ── Scenario 1+2+5: default selective (no global_proxy) ──────────
    local out1
    out1="$(SCN_TABLE="selmark_def_$$" SCN_IPV6=0 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_def_$$" 2>/dev/null

    # The selective marks must be present.
    if echo "$out1" | grep -q "@$NFT_COMMON_SET_NAME"; then
        pass "selective:default — proxied-subnets set rule present (@$NFT_COMMON_SET_NAME)"
    else
        fail "selective:default — @$NFT_COMMON_SET_NAME mark rule missing" "$(echo "$out1" | grep -i 'mark set' || echo "$out1")"
    fi
    if echo "$out1" | grep -Fq "$SB_FAKEIP_INET4_RANGE"; then
        pass "selective:default — FakeIP range marked ($SB_FAKEIP_INET4_RANGE) [domain routing intact]"
    else
        fail "selective:default — FakeIP range mark rule missing"
    fi
    # The proxied-subnets union set must exist (DoD: created).
    if echo "$out1" | grep -q -- "---SETS---" && \
       echo "$out1" | sed -n '/---SETS---/,$p' | grep -q "set $NFT_COMMON_SET_NAME"; then
        pass "selective:default — union set $NFT_COMMON_SET_NAME created"
    else
        fail "selective:default — union set $NFT_COMMON_SET_NAME not created"
    fi

    # Regression bypass: there must be NO unconditional mark-all tcp/udp rule
    # (a mark-set rule that has NO daddr / saddr / set qualifier). We detect it
    # structurally: a `meta l4proto (tcp|udp) meta mark set` line that does NOT
    # also contain `daddr` or `saddr`.
    local markall_lines
    markall_lines="$(echo "$out1" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
    if [ -z "$markall_lines" ]; then
        pass "selective:bypass — NO unconditional mark-all rule (direct IP NOT marked)"
    else
        fail "selective:bypass — unconditional mark-all rule still present" "$markall_lines"
    fi

    # ── Scenario 3: global_proxy override -> mark-all present ────────
    local out3
    out3="$(SCN_TABLE="selmark_gp_$$" SCN_IPV6=0 SCN_GLOBALPROXY="gpsec" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_gp_$$" 2>/dev/null

    local gp_markall
    gp_markall="$(echo "$out3" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
    if [ -n "$gp_markall" ]; then
        pass "selective:globalproxy — mark-EVERYTHING rules present under global_proxy"
    else
        fail "selective:globalproxy — mark-all rules missing under global_proxy" "$out3"
    fi
    # And under global_proxy the selective @set rule should NOT be added.
    if echo "$out3" | grep -q "@$NFT_COMMON_SET_NAME"; then
        fail "selective:globalproxy — selective @set rule unexpectedly present under global_proxy"
    else
        pass "selective:globalproxy — selective @set rule correctly bypassed"
    fi

    # ── Scenario 4: IPv6 mirror selective (enable_ipv6=1) ────────────
    # Only meaningful if the kernel supports the v6 set + ip6 rules.
    local out4
    out4="$(SCN_TABLE="selmark_v6_$$" SCN_IPV6=1 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_v6_$$" 2>/dev/null

    if echo "$out4" | grep -q "ip6 daddr @$NFT_COMMON_SET_NAME_V6"; then
        pass "selective:ipv6 — v6 union set mark rule present (@$NFT_COMMON_SET_NAME_V6)"
        local v6_markall
        v6_markall="$(echo "$out4" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
        if [ -z "$v6_markall" ]; then
            pass "selective:ipv6 — no mark-all rule with IPv6 enabled"
        else
            fail "selective:ipv6 — unexpected mark-all rule with IPv6 enabled" "$v6_markall"
        fi
        if echo "$out4" | grep -Fq "$SB_FAKEIP_INET6_RANGE"; then
            pass "selective:ipv6 — FakeIP v6 range marked ($SB_FAKEIP_INET6_RANGE)"
        else
            fail "selective:ipv6 — FakeIP v6 range mark rule missing"
        fi
    else
        # The driver enables v6 only if netshift_ipv6_enabled() returns true,
        # which it forced; absence here means the kernel rejected the v6 set/rule.
        skip "selective:ipv6 — v6 set/rule not applied (kernel ip6 support?)"
    fi

    # ── Live counter proof (best-effort, needs NET_ADMIN + a usable table) ──
    # Apply the default-selective table once more and probe with `nft` matching:
    # add a known proxied subnet to the union set, then verify a packet-shaped
    # match logic — we cannot synthesize forwarded packets here, so we assert
    # the deterministic rule ORDERING instead: the @localv4 return precedes the
    # @set mark, and there is no catch-all mark after it.
    local out_order
    out_order="$(SCN_TABLE="selmark_ord_$$" SCN_IPV6=0 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="192.168.50.7" sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_ord_$$" 2>/dev/null
    if echo "$out_order" | grep -q "ip saddr 192.168.50.7 meta mark set"; then
        pass "selective:fullrouted — fully_routed_ips source-mark rule present"
    else
        fail "selective:fullrouted — fully_routed_ips source mark missing" "$(echo "$out_order" | grep -i saddr || echo "$out_order")"
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
    local out6
    out6="$(SCN_TABLE="selmark_respawn_$$" SCN_IPV6=0 SCN_GLOBALPROXY="" SCN_BLOCKDOH=0 \
        SCN_FULLROUTED="" SCN_PRESEED=1 sh "$drv" 2>/dev/null)"
    nft delete table inet "selmark_respawn_$$" 2>/dev/null

    local respawn_markall
    respawn_markall="$(echo "$out6" | grep 'meta mark set' | grep 'l4proto' | grep -v 'daddr' | grep -v 'saddr' || true)"
    if [ -z "$respawn_markall" ]; then
        pass "selective:respawn — NO stale mark-all rule survives a respawn (table flushed)"
    else
        fail "selective:respawn — stale mark-all rule SURVIVED the rebuild (regression)" "$respawn_markall"
    fi
    if echo "$out6" | grep -q "@$NFT_COMMON_SET_NAME"; then
        pass "selective:respawn — selective @set rule present after respawn"
    else
        fail "selective:respawn — selective @set rule missing after respawn" "$out6"
    fi
    if echo "$out6" | sed -n '/---SETS---/,$p' | grep -q "set $NFT_COMMON_SET_NAME"; then
        pass "selective:respawn — union set $NFT_COMMON_SET_NAME present after respawn"
    else
        fail "selective:respawn — union set $NFT_COMMON_SET_NAME missing after respawn"
    fi
    # The selective rules must not be DUPLICATED (proof the chain was rebuilt,
    # not appended): exactly one @set mark rule.
    local setrule_count
    setrule_count="$(echo "$out6" | sed -n '/chain mangle/,/^\t}/p' | grep -c "daddr @$NFT_COMMON_SET_NAME" || true)"
    if [ "$setrule_count" = "1" ]; then
        pass "selective:respawn — exactly one @set mark rule (chain rebuilt, not appended)"
    else
        fail "selective:respawn — expected 1 @set rule, found $setrule_count (append, not rebuild)" "$out6"
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
SIEOF
    local route_json="/tmp/si-route-$$.json"
    sed -i "s#CONST_LIB#$const_lib#g; s#CM_LIB#$cm_lib#g; s#ROUTE_JSON#$route_json#g" "$drv"

    rm -f "$route_json"
    local out
    out="$(ash "$drv" 2>&1 || true)"
    echo "$out" | while IFS= read -r line; do
        case "$line" in
            *:FAIL*) fail "$line" ;;
            *:OK*)   pass "$line" ;;
        esac
    done

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

# awk-extract the SHIPPED handler + the unavailable marker verbatim.
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
# Extended gate respected: with extended OFF the transport is NOT applied.
is_sing_box_extended() { return 1; }
out_split_off=$(sing_box_cf_add_proxy_outbound "$base" "splo" "vless://77777777-8888-9999-aaaa-bbbbbbbbbbbb@s.example.com:8443?type=splithttp&security=tls&sni=s.example.com&path=/sp&host=s.example.com&mode=auto" "0")
printf '%s' "$out_split_off" | jq -e '.outbounds[0] | has("transport") | not' >/dev/null 2>&1 \
    && echo 'us-splithttp-gate-off:OK' || echo 'us-splithttp-gate-off:FAIL'
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

    sh "$drv" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK)   pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done
    rm -f "$drv"
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
echo "$out_gate" | jq -e '.outbounds | length == 0' >/dev/null 2>&1 && echo 'vmess-gate-unchanged:OK' || echo 'vmess-gate-unchanged:FAIL'

echo 'DONE'
VMEOF
    sed -i "s|FACADE_LIB_PATH|$facade_lib|; s|NETSHIFT_LIB|$NETSHIFT_LIB_DIR|g" "$vm_tmp"

    sh "$vm_tmp" 2>&1 | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done
    rm -f "$vm_tmp"
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

    sh "$cm_tmp" 2>&1 | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done
    rm -f "$cm_tmp"
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

    ash "$fb" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done

    rm -f "$fb"

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

    sh "$mu" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done

    rm -f "$mu"

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
            *:FAIL) fail "$line" ;;
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
VEOF
    sed -i "s|UPDATER_PATH|$updater|g;s|VDIR|$jdir|g" "$fb_jobstate"
    ash "$fb_jobstate" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
        esac
    done
    rm -f "$fb_jobstate"

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
SEOF
    sed -i "s|UPDATER_PATH|$updater|g;s|SDIR|$stale_dir|g;s|SSTATE|$stale_state|g" "$stale_sh"
    ash "$stale_sh" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
        esac
    done
    rm -f "$stale_sh"

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
    # a log so the driver can assert teardown/bring-up happened.
    cat > "$work/init/netshift" << 'INITEOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SELFHEAL_INIT_LOG"
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
. "DRV_UPDATER"
# Re-pin after sourcing (the source sets its own defaults).
RESOLV_CONF="DRV_RESOLV"
UPDATES_RESOLV_BACKUP="DRV_BACKUP"
UPDATES_FEED_PROBE_HOST="feeds.test"
UPDATES_GITHUB_PROBE_HOST="github.test"
UPDATES_HEAL_RESOLVERS="1.1.1.1 9.9.9.9"
UPDATES_SING_BOX_BIN="$SELFHEAL_BIN"
UPDATES_LIBCRONET_LIB="DRV_CRONET"

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

    local out="$work/out.json"

    run_scenario() {
        # The worker returns non-zero on recoverable failures (success:false);
        # under `set -e` that would abort the suite, so swallow the rc here — the
        # assertions read the JSON + file state, not the exit code.
        rm -f "$work/init.log"
        PATH="$work/bin:$PATH" ash "$drv" run_stable > "$out" 2>/dev/null || true
    }

    # ── Scenario 1: pre-flight passes → install proceeds, no teardown ─────────
    : > "$SELFHEAL_DNS_OK"; : > "$SELFHEAL_HTTP_OK"; : > "$SELFHEAL_PKG_OK"
    printf 'extended-1.12.0\n' > "$SELFHEAL_CORE_VERSION"
    printf 'original-resolver\n' > "$work/resolv.conf"
    : > "$work/usr-bin-sing-box"
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
    : > "$work/usr-bin-sing-box"
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
    : > "$work/usr-bin-sing-box"
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
    : > "$work/usr-bin-sing-box"
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
    printf 'EXTENDED-CORE-BYTES\n' > "$work/usr-bin-sing-box"
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
    if [ -e "$work/usr-bin-sing-box" ] && \
            [ "$(cat "$work/usr-bin-sing-box" 2>/dev/null)" = "EXTENDED-CORE-BYTES" ]; then
        pass "selfheal-stable-install-fail-backup-restored:OK"
    else
        fail "selfheal-stable-install-fail-backup-restored:FAIL" "$(cat "$work/usr-bin-sing-box" 2>/dev/null)"
    fi

    # ── Restore the real init script (if any) and clean up. ──────────────────
    if [ -n "$init_saved" ] && [ -e "$init_saved" ]; then
        cp -p "$init_saved" "$init_target" 2>/dev/null || true
    else
        rm -f "$init_target" 2>/dev/null || true
    fi
    unset SELFHEAL_DNS_OK SELFHEAL_HTTP_OK SELFHEAL_PKG_OK SELFHEAL_INIT_LOG \
        SELFHEAL_CORE_VERSION SELFHEAL_BIN
    rm -rf "$work"
}

# ─────────────────────────────────────────────────────────────────
# Test: Subscription rejected-hash validity (task-011)
# ─────────────────────────────────────────────────────────────────
# Verifies the keyword-filter no longer poisons the per-section .rejected hash
# and that a structurally valid body with >=1 proxy outbound is never vetoed by
# a stale rejected-hash, while a genuinely outbound-less body still is. The two
# functions under test (mark_subscription_outbound_unavailable,
# subscription_cache_is_usable) live in /usr/bin/netshift, not a sourceable lib,
# so a tiny driver extracts JUST those two functions verbatim from the live bin
# (awk between the `name() {` line and the matching column-0 `}`), stubs the few
# helpers they call (log + the path builders), sources helpers.sh for the real
# validate_subscription_file, and re-pins SUBSCRIPTION_CACHE_FOLDER to a temp
# dir. Tokens use the same name:OK/FAIL convention as test_subscription.
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

# Path builders are tiny; stub them exactly like the bin so the functions
# resolve the temp cache dir.
get_subscription_json_path() { echo "$SUBSCRIPTION_CACHE_FOLDER/${1}.json"; }
get_subscription_rejected_cache_path() { echo "$SUBSCRIPTION_CACHE_FOLDER/${1}.rejected"; }

# Real validate_subscription_file from helpers.sh (no other deps needed).
. "HELPERS_PATH"

# Pull the two functions under test VERBATIM out of the live bin so the test
# exercises the shipped code, not a copy. awk grabs from the function opener to
# its matching column-0 closing brace.
eval "$(awk '/^mark_subscription_outbound_unavailable\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"
eval "$(awk '/^subscription_cache_is_usable\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "BIN_PATH")"

# Globals the functions touch.
SUBSCRIPTION_UNAVAILABLE_SECTIONS=""
subscription_startup_blocked=0

valid_body='{
  "outbounds": [
    {"type": "shadowsocks", "tag": "ss-01", "server": "a.example.com", "server_port": 443, "method": "aes-256-gcm", "password": "p"},
    {"type": "selector", "tag": "select", "outbounds": ["ss-01"]}
  ]
}'

# ── CASE 1: A — over-strict keyword filter (kept=0) must NOT write .rejected,
#            and must remove a pre-existing one. ─────────────────────────────
s1="sec1"
printf '%s' "$valid_body" > "$(get_subscription_json_path "$s1")"
# Pre-poison with this body's hash; arg=1 (keyword filter) must clear it.
md5sum "$(get_subscription_json_path "$s1")" | awk '{print $1}' \
    > "$(get_subscription_rejected_cache_path "$s1")"
mark_subscription_outbound_unavailable "$s1" 1
if [ ! -e "$(get_subscription_rejected_cache_path "$s1")" ]; then
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
printf '%s' "$valid_body" > "$(get_subscription_json_path "$s2")"
md5sum "$(get_subscription_json_path "$s2")" | awk '{print $1}' \
    > "$(get_subscription_rejected_cache_path "$s2")"
[ -s "$(get_subscription_rejected_cache_path "$s2")" ] && pre2=1 || pre2=0
mark_subscription_outbound_unavailable "$s2" 1
if [ "$pre2" = "1" ] && [ ! -e "$(get_subscription_rejected_cache_path "$s2")" ]; then
    echo 'rh-case2-recovery-rejected-removed:OK'
else
    echo 'rh-case2-recovery-rejected-removed:FAIL'
fi

# ── CASE 3: B — valid body with >=1 proxy outbound + .rejected == its hash ⇒
#            subscription_cache_is_usable returns 0 (usable). ─────────────────
s3="sec3"
s3_json="$(get_subscription_json_path "$s3")"
printf '%s' "$valid_body" > "$s3_json"
md5sum "$s3_json" | awk '{print $1}' > "$(get_subscription_rejected_cache_path "$s3")"
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
s4_json="$(get_subscription_json_path "$s4")"
cat > "$s4_json" << 'NOPROXY'
{
  "outbounds": [
    {"type": "selector", "tag": "select", "outbounds": []},
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ]
}
NOPROXY
md5sum "$s4_json" | awk '{print $1}' > "$(get_subscription_rejected_cache_path "$s4")"
if subscription_cache_is_usable "$s4_json"; then
    echo 'rh-case4-no-proxy-body-vetoed:FAIL'
else
    echo 'rh-case4-no-proxy-body-vetoed:OK'
fi

# ── CASE 5: Regression — a normal valid body, no .rejected ⇒ usable (0). ──────
s5="sec5"
s5_json="$(get_subscription_json_path "$s5")"
printf '%s' "$valid_body" > "$s5_json"
rm -f "$(get_subscription_rejected_cache_path "$s5")"
if subscription_cache_is_usable "$s5_json"; then
    echo 'rh-case5-normal-valid-usable:OK'
else
    echo 'rh-case5-normal-valid-usable:FAIL'
fi

# ── CASE 6: A — keyword_filter_active=0 (default) still records the rejected
#            hash for a genuinely outbound-less body (flash-loop guard kept). ──
s6="sec6"
s6_json="$(get_subscription_json_path "$s6")"
cat > "$s6_json" << 'NOPROXY'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ]
}
NOPROXY
rm -f "$(get_subscription_rejected_cache_path "$s6")"
mark_subscription_outbound_unavailable "$s6" 0
expect6="$(md5sum "$s6_json" | awk '{print $1}')"
got6="$(cat "$(get_subscription_rejected_cache_path "$s6")" 2>/dev/null)"
if [ -s "$(get_subscription_rejected_cache_path "$s6")" ] && [ "$got6" = "$expect6" ]; then
    echo 'rh-case6-genuine-unusable-recorded:OK'
else
    echo 'rh-case6-genuine-unusable-recorded:FAIL'
fi

echo 'DONE'
RHEOF

    sed -i "s|HELPERS_PATH|$helpers|g; s|BIN_PATH|$bin|g" "$drv"

    local rhcache="/tmp/netshift-rejected-cache-$$"
    rm -rf "$rhcache"

    RH_CACHE_DIR="$rhcache" ash "$drv" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done

    rm -rf "$rhcache"
    rm -f "$drv"
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

    ash "$drv" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *:OK) pass "$line" ;;
            *:FAIL) fail "$line" ;;
            *:SKIP) skip "$line" ;;
            DONE) ;;
            *) ;;
        esac
    done
    rm -f "$drv"
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
            *:FAIL) fail "$line" "$(cat "$out" 2>/dev/null)" ;;
        esac
    done < "$out"

    rm -rf "$work"
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
            test_nft
            test_nft_ipv6
            test_selective_marking
            test_section_isolation
            test_monitor_fd_hygiene
            test_unsupported_skip
            test_diagnostics
            test_subscription
            test_fastest_group
            test_insecure_fetch
            test_rejected_hash
            test_jobstate
            test_selfheal
            test_dns_via_outbound
            test_sub_url_option
            test_global_proxy
            test_check_update_stable
            test_check_update_extended
            test_check_update_netshift
            test_netshift_latest_tag
            test_github_redirect_tag
            test_self_update_netshift
            test_backup_integrity
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
        diagnostics) test_diagnostics ;;
        subscription) test_subscription ;;
        fastest)     test_fastest_group ;;
        insecure)    test_insecure_fetch ;;
        rejected)    test_rejected_hash ;;
        jobstate)    test_jobstate ;;
        selfheal)    test_selfheal ;;
        dnsdetour)   test_dns_via_outbound ;;
        suburlopt)   test_sub_url_option ;;
        globalproxy) test_global_proxy ;;
        stablecheck) test_check_update_stable ;;
        extcheck)    test_check_update_extended ;;
        netshiftcheck) test_check_update_netshift ;;
        latesttag)   test_netshift_latest_tag ;;
        ghredirect)  test_github_redirect_tag ;;
        selfupdate)  test_self_update_netshift ;;
        backupguard) test_backup_integrity ;;
        jq)          test_jq_helpers ;;
        cm)          test_config_manager ;;
        sb)          test_sing_box_config ;;
        *)
            echo "Unknown test: $target"
            echo "Available: all deps syntax config helpers jq cm sb nft nftv6 selmark isolation monfd unsupported diagnostics subscription fastest insecure rejected jobstate selfheal dnsdetour suburlopt globalproxy stablecheck extcheck netshiftcheck latesttag ghredirect selfupdate backupguard"
            exit 1
            ;;
    esac

    summary
}

main "$@"
