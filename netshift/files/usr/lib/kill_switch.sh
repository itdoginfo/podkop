# shellcheck shell=ash
# ── block_leaks: fail-closed "kill switch" ──────────────────────────────────
#
# NetShift intercepts proxied destinations by marking them in NetShiftTable and
# letting `ip rule ... lookup netshift` send the marked packets into the tproxy
# inbound. While that table is in place marked traffic never reaches the WAN:
# when sing-box is down the packets are delivered locally to a dead port and the
# connection fails (fail-closed).
#
# The leak window is everything that runs withOUT that table:
#   - stop_main deletes NetShiftTable (and the ip rule/local route) before a
#     restart, reload or crash recovery;
#   - create_nft_rules rebuilds the table with EMPTY sets, and only fills them
#     later during config generation;
#   - the monitor's recovery goes through the same stop_main/start_main pair.
# In any of these the destination marking is gone, so proxied traffic would go
# straight out the WAN.
#
# With settings.block_leaks=1 NetShift keeps a SECOND, independent table
# (NFT_GUARD_TABLE_NAME) whose only job is to drop exactly that traffic while
# the interception is missing. It is:
#   - rebuilt by start_main AFTER config generation has filled the union subnet
#     set (create_nft_rules leaves it empty), from the live NetShiftTable sets;
#   - kept in step afterwards: every batch added to the union / bypass sets is
#     mirrored into the guard at the single place those sets grow
#     (populate_netshift_subnets_from_file), so list updates and hot reloads
#     reach the guard without another rebuild;
#   - left in place by stop_main, so the previous revision keeps blocking across
#     a restart, until the next start_main replaces it;
#   - removed when the option is off or released (package removal, self-heal).
#
# The guard drops only what the marking model would have MARKED. Everything the
# mangle chains return before marking — DNAT-ed flows, local/reserved
# destinations, bypass destinations and bypassed devices, NTP with exclude_ntp —
# is accepted here too, from the same constants and UCI options. Otherwise a
# packet that NetShift sends directly on purpose would be dropped for good, not
# just during a restart.
#
# The rebuild swaps the table structure in ONE nft transaction and then loads
# the subnets in chunks (a single transaction with tens of thousands of elements
# is a RAM spike on a 128 MB router). The sets are briefly incomplete, which is
# safe at that point: NetShiftTable is fully populated and sing-box is not
# running yet, so the traffic is marked and fails closed on its own.
#
# NOT covered: boot before the service's first start. The guard is created by
# start_main and the kernel drops all nft state on reboot, so until NetShift
# starts there is no table to drop with. Closing that window would also require
# dnsmasq to be pointed at sing-box before the service runs, which it is not,
# so it is intentionally out of scope.
#
# Combined with dnsmasq_should_be_restored() refusing to hand DNS back to the
# direct resolvers while sing-box is down, this makes proxied traffic — both
# subnet- and domain-routed — wait instead of leaking.

# Is the kill switch switched on?
#
# NETSHIFT_BLOCK_LEAKS_RELEASE=1 releases it for ONE invocation without touching
# the stored option: the caller needs a direct path right now (package removal,
# the updater's self-heal, the installer) and the next ordinary start arms the
# guard again.
kill_switch_enabled() {
    local block_leaks

    [ "${NETSHIFT_BLOCK_LEAKS_RELEASE:-0}" = "1" ] && return 1

    config_get_bool block_leaks "settings" "block_leaks" 0
    [ "$block_leaks" -eq 1 ]
}

# Remove the guard table (idempotent, a no-op when it is absent).
kill_switch_delete() {
    if nft list table inet "$NFT_GUARD_TABLE_NAME" > /dev/null 2>&1; then
        log "block_leaks: removing $NFT_GUARD_TABLE_NAME" "info"
        nft delete table inet "$NFT_GUARD_TABLE_NAME"
    fi
}

# Mirror a batch that was just added to a NetShiftTable set ($2: the IPv4 set
# name) into the matching guard set. No-op when the option is off, the guard
# does not exist yet (first start) or a rebuild is about to replace it anyway.
kill_switch_mirror_file() {
    local filepath="$1" source_set="$2"
    local guard_v4 guard_v6

    [ "${KILL_SWITCH_MIRROR_SUSPENDED:-0}" = "1" ] && return 0
    kill_switch_enabled || return 0

    case "$source_set" in
    "$NFT_COMMON_SET_NAME")
        guard_v4="$NFT_GUARD_SUBNET_SET_NAME"
        guard_v6="$NFT_GUARD_SUBNET_SET_NAME_V6"
        ;;
    "$NFT_BYPASS_SET_NAME")
        guard_v4="$NFT_GUARD_BYPASS_SET_NAME"
        guard_v6="$NFT_GUARD_BYPASS_SET_NAME_V6"
        ;;
    *) return 0 ;;
    esac

    if nft list set inet "$NFT_GUARD_TABLE_NAME" "$guard_v4" > /dev/null 2>&1; then
        nft_add_set_elements_from_file_chunked "$filepath" "$NFT_GUARD_TABLE_NAME" "$guard_v4"
    fi

    if netshift_ipv6_enabled &&
        nft list set inet "$NFT_GUARD_TABLE_NAME" "$guard_v6" > /dev/null 2>&1; then
        nft_add_set_elements_from_file_chunked_v6 "$filepath" "$NFT_GUARD_TABLE_NAME" "$guard_v6"
    fi

    return 0
}

# Elements of an existing set, one per line (empty when the set is absent).
kill_switch_read_set() {
    nft list set inet "$1" "$2" 2> /dev/null |
        sed -n '/elements = {/,/}/p' |
        tr -d ' \t' |
        sed -e 's/^elements={//' -e 's/}$//' -e 's/,$//' |
        tr ',' '\n' |
        sed '/^$/d'
}

# Print one `add element` line with the contents of data file $2 for the set
# $1. For the SMALL sets only (interfaces, client addresses): they go into the
# same transaction as the table structure.
kill_switch_emit_elements() {
    local set="$1" data="$2"
    local chunk="" element

    [ -f "$data" ] || return 0

    while IFS= read -r element; do
        [ -n "$element" ] || continue
        chunk="${chunk:+$chunk,}$element"
    done < "$data"

    if [ -n "$chunk" ]; then
        echo "add element inet $NFT_GUARD_TABLE_NAME $set { $chunk }"
    fi

    return 0
}

# Load data file $2 into the guard set $1, one nft transaction per chunk. The
# elements come from `nft list set`, so they may be ranges (a-b) that the
# CIDR-only chunked helper of nft.sh would skip; they are fed through stdin
# because a chunk of ranges does not fit a single command-line argument.
kill_switch_load_elements() {
    local set="$1" data="$2"
    local chunk="" count=0 element rc=0

    [ -s "$data" ] || return 0

    while IFS= read -r element; do
        [ -n "$element" ] || continue
        chunk="${chunk:+$chunk,}$element"
        count=$((count + 1))
        if [ "$count" -ge 5000 ]; then
            echo "add element inet $NFT_GUARD_TABLE_NAME $set { $chunk }" | nft -f - || rc=1
            chunk=""
            count=0
        fi
    done < "$data"

    if [ -n "$chunk" ]; then
        echo "add element inet $NFT_GUARD_TABLE_NAME $set { $chunk }" | nft -f - || rc=1
    fi

    return "$rc"
}

# Collect every section's fully_routed_ips into $_kill_switch_source_out4 (IPv4)
# and $_kill_switch_source_out6 (IPv6). Mirrors nft_mark_fully_routed_source_ips
# (same sections, same list/option duality), so the guard covers exactly the
# clients whose whole traffic the marking model forces into the tunnel.
_kill_switch_source_item() {
    local ip="$1"

    _kill_switch_source_seen=1
    [ -n "$ip" ] || return 0

    # The whole guard is rebuilt in ONE nft transaction, so a single malformed
    # value (a hostname, a typo) would abort the batch and leave no guard at all
    # — fail-open, the opposite of what this option promises. Validate first and
    # skip bad rows (the per-rule marking path degrades the same way, one rule
    # at a time). is_ip_or_ip_prefix accepts a bare address or a prefix, IPv4 or
    # IPv6, which is exactly what `fully_routed_ips` may hold.
    if ! is_ip_or_ip_prefix "$ip"; then
        log "block_leaks: skipping invalid fully_routed_ips entry '$ip'" "warn"
        return 0
    fi

    case "$ip" in
    *:*) echo "$ip" >> "$_kill_switch_source_out6" ;;
    *) echo "$ip" >> "$_kill_switch_source_out4" ;;
    esac
}

_kill_switch_source_section() {
    local section="$1" connection_type fully_routed_ips ip

    config_get connection_type "$section" "connection_type"
    case "$connection_type" in
    proxy | vpn) ;;
    *) return 0 ;;
    esac

    config_get fully_routed_ips "$section" "fully_routed_ips"
    [ -n "$fully_routed_ips" ] || return 0

    _kill_switch_source_seen=""
    config_list_foreach "$section" "fully_routed_ips" _kill_switch_source_item
    # Fallback for option-form (space-separated) values.
    if [ -z "$_kill_switch_source_seen" ]; then
        for ip in $fully_routed_ips; do
            _kill_switch_source_item "$ip"
        done
    fi
}

kill_switch_collect_sources() {
    _kill_switch_source_out4="$1"
    _kill_switch_source_out6="$2"

    : > "$_kill_switch_source_out4"
    : > "$_kill_switch_source_out6"

    foreach_active_section _kill_switch_source_section "section"
}

# Devices the marking model returns before any mark (routing_excluded_ips with
# settings.bypass_excluded_ips, see nft_bypass_source_ips): their non-FakeIP
# traffic goes out directly on purpose, so the guard must let it through.
_kill_switch_bypass_source_item() {
    local ip="$1"

    [ -n "$ip" ] || return 0

    if ! is_ip_or_ip_prefix "$ip"; then
        log "block_leaks: skipping invalid routing_excluded_ips entry '$ip'" "warn"
        return 0
    fi

    case "$ip" in
    *:*) echo "$ip" >> "$_kill_switch_source_out6" ;;
    *) echo "$ip" >> "$_kill_switch_source_out4" ;;
    esac
}

kill_switch_collect_bypass_sources() {
    local excluded_ips

    _kill_switch_source_out4="$1"
    _kill_switch_source_out6="$2"

    : > "$_kill_switch_source_out4"
    : > "$_kill_switch_source_out6"

    config_get_bool excluded_ips "settings" "bypass_excluded_ips" 0
    [ "$excluded_ips" -eq 1 ] || return 0

    config_list_foreach "settings" "routing_excluded_ips" _kill_switch_bypass_source_item
}

# The accept rules shared by both guard chains: what the mangle chains return
# before marking, so the guard never drops it. $1: selector that scopes a rule
# to LAN traffic in the forward chain (empty for the output chain), $2: IPv6.
_kill_switch_emit_unmarked_accepts() {
    local scope="$1" v6="$2"

    echo "        ${scope}ip daddr { $NFT_LOCALV4_ELEMENTS } accept"
    echo "        ${scope}ip daddr @$NFT_GUARD_BYPASS_SET_NAME accept"
    if [ "$v6" -eq 1 ]; then
        echo "        ${scope}ip6 daddr { $NFT_LOCALV6_ELEMENTS } accept"
        echo "        ${scope}ip6 daddr @$NFT_GUARD_BYPASS_SET_NAME_V6 accept"
    fi
}

# The drop rules shared by both guard chains: what the marking model marks.
# $1: scope selector (as above), $2: global_proxy, $3: IPv6, $4: block_doh.
_kill_switch_emit_drops() {
    local scope="$1" mark_all="$2" v6="$3" block_doh="$4"
    local doh4 doh6

    if [ "$mark_all" -eq 1 ]; then
        # global_proxy: every tcp/udp flow belongs in the tunnel.
        echo "        ${scope}meta l4proto { tcp, udp } counter drop"
        return 0
    fi

    echo "        ${scope}ip daddr @$NFT_GUARD_SUBNET_SET_NAME counter drop"
    echo "        ${scope}ip daddr $SB_FAKEIP_INET4_RANGE counter drop"
    if [ "$v6" -eq 1 ]; then
        echo "        ${scope}ip6 daddr @$NFT_GUARD_SUBNET_SET_NAME_V6 counter drop"
        echo "        ${scope}ip6 daddr $SB_FAKEIP_INET6_RANGE counter drop"
    fi

    # block_doh marks the DoH resolvers into sing-box (which rejects them). With
    # the interception gone a client's DoH would resolve the REAL addresses of
    # proxied domains and connect to them directly, so hold those too.
    if [ "$block_doh" -eq 1 ]; then
        doh4="$(printf '%s' "$DOH_BLOCK_IPV4_CIDRS" | tr -s ' \n\t' ',,,')"
        [ -n "$doh4" ] && echo "        ${scope}ip daddr { $doh4 } counter drop"
        if [ "$v6" -eq 1 ]; then
            doh6="$(printf '%s' "$DOH_BLOCK_IPV6_CIDRS" | tr -s ' \n\t' ',,,')"
            [ -n "$doh6" ] && echo "        ${scope}ip6 daddr { $doh6 } counter drop"
        fi
    fi

    return 0
}

# Rebuild the guard table from the live NetShiftTable sets, or remove it when
# the option is off. Call it only once those sets are populated (see the header).
kill_switch_apply() {
    if ! kill_switch_enabled; then
        kill_switch_delete
        return 0
    fi

    local tmp data_sub4 data_sub6 data_byp4 data_byp6 data_src4 data_src6
    local data_bsrc4 data_bsrc6 data_lan program
    local v6=0 mark_all=0 block_doh=0 exclude_ntp=0 rc=0
    local interface source_network_interfaces lan="iifname @$NFT_GUARD_INTERFACE_SET_NAME "

    # A private scratch directory per call: a start and a monitor recovery may
    # overlap, and fixed names would let them overwrite each other's program.
    mkdir -p "$TMP_SING_BOX_FOLDER"
    tmp="$(mktemp -d "$TMP_SING_BOX_FOLDER/guard.XXXXXX")" || {
        log "block_leaks: cannot create a scratch directory in $TMP_SING_BOX_FOLDER" "error"
        return 1
    }
    data_sub4="$tmp/sub4"
    data_sub6="$tmp/sub6"
    data_byp4="$tmp/byp4"
    data_byp6="$tmp/byp6"
    data_src4="$tmp/src4"
    data_src6="$tmp/src6"
    data_bsrc4="$tmp/bsrc4"
    data_bsrc6="$tmp/bsrc6"
    data_lan="$tmp/lan"
    program="$tmp/guard.nft"

    # Same sets the marking model uses — read back from the live table so the
    # two cannot drift apart.
    kill_switch_read_set "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" > "$data_sub4"
    kill_switch_read_set "$NFT_TABLE_NAME" "$NFT_BYPASS_SET_NAME" > "$data_byp4"
    : > "$data_sub6"
    : > "$data_byp6"
    if netshift_ipv6_enabled; then
        v6=1
        kill_switch_read_set "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME_V6" > "$data_sub6"
        kill_switch_read_set "$NFT_TABLE_NAME" "$NFT_BYPASS_SET_NAME_V6" > "$data_byp6"
    fi

    # A non-empty union set that parses to nothing means the read-back failed
    # (an nft output format change): the guard would be rebuilt with no proxied
    # subnets and silently cover less. Warn instead of failing quietly.
    if [ ! -s "$data_sub4" ] &&
        nft list set inet "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" 2> /dev/null |
        grep -Eq 'elements = \{[[:space:]]*[^[:space:]}]'; then
        log "block_leaks: $NFT_COMMON_SET_NAME is not empty but parsed to nothing; guard subnets will be empty" "warn"
    fi

    kill_switch_collect_sources "$data_src4" "$data_src6"
    kill_switch_collect_bypass_sources "$data_bsrc4" "$data_bsrc6"

    : > "$data_lan"
    config_get source_network_interfaces "settings" "source_network_interfaces" "br-lan"
    for interface in $source_network_interfaces; do
        [ -n "$interface" ] || continue
        # Positive allowlist: a name that would break nft tokenization must not
        # make the guard transaction fail (same fail-open as above).
        case "$interface" in
        *[!A-Za-z0-9_.:@-]*)
            log "block_leaks: skipping invalid interface name '$interface'" "warn"
            continue
            ;;
        esac
        echo "$interface" >> "$data_lan"
    done

    [ -n "$(get_global_proxy_section)" ] && mark_all=1
    config_get_bool block_doh "settings" "block_doh" 0
    config_get_bool exclude_ntp "settings" "exclude_ntp" 0

    log "block_leaks: rebuilding $NFT_GUARD_TABLE_NAME (global_proxy=$mark_all, ipv6=$v6)" "info"

    # One nft transaction for the structure: the old table stays in place until
    # the commit, so there is never a moment without a guard table (the bare
    # `table` line first makes `delete` succeed on the very first run).
    {
        echo "table inet $NFT_GUARD_TABLE_NAME"
        echo "delete table inet $NFT_GUARD_TABLE_NAME"
        echo "table inet $NFT_GUARD_TABLE_NAME {"
        echo "    set $NFT_GUARD_INTERFACE_SET_NAME { type ifname; }"
        echo "    set $NFT_GUARD_SUBNET_SET_NAME { type ipv4_addr; flags interval; auto-merge; }"
        echo "    set $NFT_GUARD_SOURCE_SET_NAME { type ipv4_addr; flags interval; auto-merge; }"
        echo "    set $NFT_GUARD_BYPASS_SET_NAME { type ipv4_addr; flags interval; auto-merge; }"
        echo "    set $NFT_GUARD_BYPASS_SOURCE_SET_NAME { type ipv4_addr; flags interval; auto-merge; }"
        if [ "$v6" -eq 1 ]; then
            echo "    set $NFT_GUARD_SUBNET_SET_NAME_V6 { type ipv6_addr; flags interval; auto-merge; }"
            echo "    set $NFT_GUARD_SOURCE_SET_NAME_V6 { type ipv6_addr; flags interval; auto-merge; }"
            echo "    set $NFT_GUARD_BYPASS_SET_NAME_V6 { type ipv6_addr; flags interval; auto-merge; }"
            echo "    set $NFT_GUARD_BYPASS_SOURCE_SET_NAME_V6 { type ipv6_addr; flags interval; auto-merge; }"
        fi
        echo ""
        echo "    chain forward_guard {"
        echo "        type filter hook forward priority -150; policy accept;"
        echo "        ct state established,related accept"
        echo "        oifname \"lo\" accept"
        echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME oifname @$NFT_GUARD_INTERFACE_SET_NAME accept"
        echo "        meta mark & $NFT_FAKEIP_MARK == $NFT_FAKEIP_MARK accept"
        # Not marked by design (mangle returns these first) — never dropped.
        echo "        ct status dnat accept"
        [ "$exclude_ntp" -eq 1 ] && echo "        udp dport 123 accept"
        _kill_switch_emit_unmarked_accepts "$lan" "$v6"
        echo "        ${lan}ip saddr @$NFT_GUARD_BYPASS_SOURCE_SET_NAME ip daddr != $SB_FAKEIP_INET4_RANGE accept"
        if [ "$v6" -eq 1 ]; then
            echo "        ${lan}ip6 saddr @$NFT_GUARD_BYPASS_SOURCE_SET_NAME_V6 ip6 daddr != $SB_FAKEIP_INET6_RANGE accept"
        fi
        # Marked by the model, so held while the interception is missing.
        if [ "$mark_all" -eq 0 ]; then
            echo "        ${lan}ip saddr @$NFT_GUARD_SOURCE_SET_NAME counter drop"
            if [ "$v6" -eq 1 ]; then
                echo "        ${lan}ip6 saddr @$NFT_GUARD_SOURCE_SET_NAME_V6 counter drop"
            fi
        fi
        _kill_switch_emit_drops "$lan" "$mark_all" "$v6" "$block_doh"
        echo "    }"
        echo ""
        echo "    chain output_guard {"
        echo "        type filter hook output priority -140; policy accept;"
        echo "        oifname \"lo\" accept"
        echo "        oifname @$NFT_GUARD_INTERFACE_SET_NAME accept"
        echo "        meta mark & $NFT_OUTBOUND_MARK == $NFT_OUTBOUND_MARK accept"
        echo "        meta mark & $NFT_FAKEIP_MARK == $NFT_FAKEIP_MARK accept"
        echo "        ct state established,related accept"
        _kill_switch_emit_unmarked_accepts "" "$v6"
        _kill_switch_emit_drops "" "$mark_all" "$v6" "$block_doh"
        echo "    }"
        echo "}"

        kill_switch_emit_elements "$NFT_GUARD_INTERFACE_SET_NAME" "$data_lan"
        kill_switch_emit_elements "$NFT_GUARD_SOURCE_SET_NAME" "$data_src4"
        kill_switch_emit_elements "$NFT_GUARD_BYPASS_SOURCE_SET_NAME" "$data_bsrc4"
        if [ "$v6" -eq 1 ]; then
            kill_switch_emit_elements "$NFT_GUARD_SOURCE_SET_NAME_V6" "$data_src6"
            kill_switch_emit_elements "$NFT_GUARD_BYPASS_SOURCE_SET_NAME_V6" "$data_bsrc6"
        fi
    } > "$program"

    if ! nft -f "$program"; then
        log "block_leaks: failed to rebuild $NFT_GUARD_TABLE_NAME" "error"
        rm -rf "$tmp"
        return 1
    fi

    # The big sets, chunk by chunk (see the header for why this is safe here).
    kill_switch_load_elements "$NFT_GUARD_SUBNET_SET_NAME" "$data_sub4" || rc=1
    kill_switch_load_elements "$NFT_GUARD_BYPASS_SET_NAME" "$data_byp4" || rc=1
    if [ "$v6" -eq 1 ]; then
        kill_switch_load_elements "$NFT_GUARD_SUBNET_SET_NAME_V6" "$data_sub6" || rc=1
        kill_switch_load_elements "$NFT_GUARD_BYPASS_SET_NAME_V6" "$data_byp6" || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
        log "block_leaks: $NFT_GUARD_TABLE_NAME was rebuilt, but not every subnet could be loaded" "error"
    fi

    rm -rf "$tmp"
    return "$rc"
}
