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
#   - rebuilt ATOMICALLY (a single nft transaction) from the union subnet set
#     NetShiftTable just populated, so it cannot drift from the marking model;
#   - left in place by stop_main, so the previous revision keeps blocking across
#     a restart, until the new one is swapped in at the end of start_main;
#   - removed when the option is off (and on package removal, via prerm).
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
kill_switch_enabled() {
    local block_leaks

    config_get_bool block_leaks "settings" "block_leaks" 0
    [ "$block_leaks" -eq 1 ]
}

# Remove the guard table (idempotent, a no-op when it is absent).
kill_switch_delete() {
    if nft list table inet "$NFT_GUARD_TABLE_NAME" > /dev/null 2>&1; then
        log "block_leaks: removing $NFT_GUARD_TABLE_NAME" "info"
        nft delete table inet "$NFT_GUARD_TABLE_NAME"
    fi
    rm -f "$TMP_SING_BOX_FOLDER/guard.nft"
    rm -f "$TMP_SING_BOX_FOLDER"/guard-data.*
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

# Print `add element` lines (chunked) for the contents of data file $3 into the
# set $2. Written to stdout so the caller can drop them into the nft program.
kill_switch_emit_elements() {
    local set="$1" data="$2"
    local chunk="" count=0 element

    [ -f "$data" ] || return 0

    while IFS= read -r element; do
        [ -n "$element" ] || continue
        chunk="${chunk:+$chunk,}$element"
        count=$((count + 1))
        if [ "$count" -ge 5000 ]; then
            echo "add element inet $NFT_GUARD_TABLE_NAME $set { $chunk }"
            chunk=""
            count=0
        fi
    done < "$data"

    if [ -n "$chunk" ]; then
        echo "add element inet $NFT_GUARD_TABLE_NAME $set { $chunk }"
    fi

    return 0
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

# Rebuild the guard table atomically, or remove it when the option is off.
kill_switch_apply() {
    if ! kill_switch_enabled; then
        kill_switch_delete
        return 0
    fi

    local tmp="$TMP_SING_BOX_FOLDER"
    local data_sub4="$tmp/guard-data.sub4"
    local data_sub6="$tmp/guard-data.sub6"
    local data_src4="$tmp/guard-data.src4"
    local data_src6="$tmp/guard-data.src6"
    local data_lan="$tmp/guard-data.lan"
    local program="$tmp/guard.nft"
    local v6=0 mark_all=0 interface source_network_interfaces

    mkdir -p "$tmp"
    rm -f "$program" "$data_sub4" "$data_sub6" "$data_src4" "$data_src6" "$data_lan"

    # Same union set the marking model uses — read back from the live table so
    # the two cannot drift apart.
    kill_switch_read_set "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" > "$data_sub4"
    if netshift_ipv6_enabled; then
        v6=1
        kill_switch_read_set "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME_V6" > "$data_sub6"
    else
        : > "$data_sub6"
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

    : > "$data_lan"
    config_get source_network_interfaces "settings" "source_network_interfaces" "br-lan"
    for interface in $source_network_interfaces; do
        [ -n "$interface" ] || continue
        # Positive allowlist: a name that would break nft tokenization must not
        # make the single guard transaction fail (same fail-open as above).
        case "$interface" in
        *[!A-Za-z0-9_.:@-]*)
            log "block_leaks: skipping invalid interface name '$interface'" "warn"
            continue
            ;;
        esac
        echo "$interface" >> "$data_lan"
    done

    [ -n "$(get_global_proxy_section)" ] && mark_all=1

    log "block_leaks: rebuilding $NFT_GUARD_TABLE_NAME (global_proxy=$mark_all, ipv6=$v6)" "info"

    # One nft transaction: the old table stays in place until the final commit,
    # so there is never a moment without a guard (the bare `table` line first
    # makes `delete` succeed on the very first run).
    {
        echo "table inet $NFT_GUARD_TABLE_NAME"
        echo "delete table inet $NFT_GUARD_TABLE_NAME"
        echo "table inet $NFT_GUARD_TABLE_NAME {"
        echo "    set $NFT_GUARD_INTERFACE_SET_NAME { type ifname; }"
        echo "    set $NFT_GUARD_SUBNET_SET_NAME { type ipv4_addr; flags interval; auto-merge; }"
        echo "    set $NFT_GUARD_SOURCE_SET_NAME { type ipv4_addr; flags interval; auto-merge; }"
        if [ "$v6" -eq 1 ]; then
            echo "    set $NFT_GUARD_SUBNET_SET_NAME_V6 { type ipv6_addr; flags interval; auto-merge; }"
            echo "    set $NFT_GUARD_SOURCE_SET_NAME_V6 { type ipv6_addr; flags interval; auto-merge; }"
        fi
        echo ""
        echo "    chain forward_guard {"
        echo "        type filter hook forward priority -150; policy accept;"
        echo "        ct state established,related accept"
        echo "        oifname \"lo\" accept"
        echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME oifname @$NFT_GUARD_INTERFACE_SET_NAME accept"
        echo "        meta mark & $NFT_FAKEIP_MARK == $NFT_FAKEIP_MARK accept"
        if [ "$mark_all" -eq 1 ]; then
            # global_proxy: every LAN tcp/udp flow belongs in the tunnel.
            echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME meta l4proto { tcp, udp } drop"
        else
            echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME ip saddr @$NFT_GUARD_SOURCE_SET_NAME drop"
            echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME ip daddr @$NFT_GUARD_SUBNET_SET_NAME drop"
            echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME ip daddr $SB_FAKEIP_INET4_RANGE drop"
            if [ "$v6" -eq 1 ]; then
                echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME ip6 saddr @$NFT_GUARD_SOURCE_SET_NAME_V6 drop"
                echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME ip6 daddr @$NFT_GUARD_SUBNET_SET_NAME_V6 drop"
                echo "        iifname @$NFT_GUARD_INTERFACE_SET_NAME ip6 daddr $SB_FAKEIP_INET6_RANGE drop"
            fi
        fi
        echo "    }"
        echo ""
        echo "    chain output_guard {"
        echo "        type filter hook output priority -140; policy accept;"
        echo "        oifname \"lo\" accept"
        echo "        oifname @$NFT_GUARD_INTERFACE_SET_NAME accept"
        echo "        meta mark & $NFT_OUTBOUND_MARK == $NFT_OUTBOUND_MARK accept"
        echo "        meta mark & $NFT_FAKEIP_MARK == $NFT_FAKEIP_MARK accept"
        echo "        ct state established,related accept"
        if [ "$mark_all" -eq 1 ]; then
            echo "        meta l4proto { tcp, udp } drop"
        else
            echo "        ip daddr @$NFT_GUARD_SUBNET_SET_NAME drop"
            echo "        ip daddr $SB_FAKEIP_INET4_RANGE drop"
            if [ "$v6" -eq 1 ]; then
                echo "        ip6 daddr @$NFT_GUARD_SUBNET_SET_NAME_V6 drop"
                echo "        ip6 daddr $SB_FAKEIP_INET6_RANGE drop"
            fi
        fi
        echo "    }"
        echo "}"

        kill_switch_emit_elements "$NFT_GUARD_INTERFACE_SET_NAME" "$data_lan"
        kill_switch_emit_elements "$NFT_GUARD_SUBNET_SET_NAME" "$data_sub4"
        kill_switch_emit_elements "$NFT_GUARD_SOURCE_SET_NAME" "$data_src4"
        if [ "$v6" -eq 1 ]; then
            kill_switch_emit_elements "$NFT_GUARD_SUBNET_SET_NAME_V6" "$data_sub6"
            kill_switch_emit_elements "$NFT_GUARD_SOURCE_SET_NAME_V6" "$data_src6"
        fi
    } > "$program"

    if ! nft -f "$program"; then
        log "block_leaks: failed to rebuild $NFT_GUARD_TABLE_NAME" "error"
        rm -f "$program"
        return 1
    fi

    rm -f "$program" "$data_sub4" "$data_sub6" "$data_src4" "$data_src6" "$data_lan"
    return 0
}
