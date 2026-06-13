# shellcheck shell=ash
# Create an nftables table in the inet family
nft_create_table() {
    local name="$1"

    nft add table inet "$name"
}

# Delete an nftables inet table if it exists (idempotent, fail-open).
# create_nft_rules rebuilds the whole table from scratch, so it MUST start from
# a clean slate: `nft add table` is idempotent but `nft add rule`/`nft add
# chain` only ever APPEND. Without this flush, a table left behind by a previous
# start that was not cleanly stopped (a procd respawn, an in-place package
# upgrade, or a crash) keeps its stale rules and the freshly-added rules pile on
# top of them. In particular a stale mark-EVERYTHING rule (from global_proxy or
# an older mark-all build) would sit at the top of the prerouting chain and mark
# all traffic before the new destination-selective rules are ever evaluated,
# silently re-introducing the "everything proxied / 100% CPU" regression.
nft_delete_table() {
    local name="$1"

    if nft list table inet "$name" > /dev/null 2>&1; then
        nft delete table inet "$name" 2>/dev/null
    fi
}

# Create a set within a table for storing IPv4 addresses
nft_create_ipv4_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ipv4_addr; flags interval; auto-merge; }'
}

nft_create_ipv6_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ipv6_addr; flags interval; auto-merge; }'
}

nft_create_ifname_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ifname; flags interval; }'
}

# Add one or more elements to a set
nft_add_set_elements() {
    local table="$1"
    local set="$2"
    local elements="$3"

    nft add element inet "$table" "$set" "{ $elements }"
}

nft_add_set_elements_from_file_chunked() {
    local filepath="$1"
    local nft_table_name="$2"
    local nft_set_name="$3"
    local chunk_size="${4:-5000}"

    local array count
    count=0
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        if ! is_ipv4 "$line" && ! is_ipv4_cidr "$line"; then
            log "'$line' is not IPv4 or IPv4 CIDR" "debug"
            continue
        fi

        if [ -z "$array" ]; then
            array="$line"
        else
            array="$array,$line"
        fi

        count=$((count + 1))

        if [ "$count" = "$chunk_size" ]; then
            log "Adding $count elements to nft set $nft_set_name" "debug"
            nft_add_set_elements "$nft_table_name" "$nft_set_name" "$array"
            array=""
            count=0
        fi
    done < "$filepath"

    if [ -n "$array" ]; then
        log "Adding $count elements to nft set $nft_set_name" "debug"
        nft_add_set_elements "$nft_table_name" "$nft_set_name" "$array"
    fi
}

# IPv6 counterpart of nft_add_set_elements_from_file_chunked. Adds only the
# IPv6 / IPv6-CIDR lines from the file into an ipv6_addr set. A line is treated
# as IPv6 when it contains a ':' (after trimming); anything else (IPv4, blank,
# comment) is skipped. Fail-open: a malformed line is simply not added, so the
# corresponding traffic goes direct rather than blackholing.
nft_add_set_elements_from_file_chunked_v6() {
    local filepath="$1"
    local nft_table_name="$2"
    local nft_set_name="$3"
    local chunk_size="${4:-5000}"

    local array count
    count=0
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        case "$line" in
        *:*) ;;
        *)
            log "'$line' is not IPv6 or IPv6 CIDR" "debug"
            continue
            ;;
        esac

        if [ -z "$array" ]; then
            array="$line"
        else
            array="$array,$line"
        fi

        count=$((count + 1))

        if [ "$count" = "$chunk_size" ]; then
            log "Adding $count elements to nft set $nft_set_name" "debug"
            nft_add_set_elements "$nft_table_name" "$nft_set_name" "$array"
            array=""
            count=0
        fi
    done < "$filepath"

    if [ -n "$array" ]; then
        log "Adding $count elements to nft set $nft_set_name" "debug"
        nft_add_set_elements "$nft_table_name" "$nft_set_name" "$array"
    fi
}
