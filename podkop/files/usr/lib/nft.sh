# Create an nftables table in the inet family
nft_create_table() {
    local name="$1"

    nft add table inet "$name"
}

# Create a set within a table for storing IPv4 addresses
nft_create_ipv4_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ipv4_addr; flags interval; auto-merge; }'
}

# Create a set within a table for storing IPv6 addresses
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
    # IPv6 entries go to the companion set "<name>6" (e.g. podkop_subnets6)
    local nft_set6_name="${nft_set_name}6"

    local array count array6 count6
    count=0
    count6=0
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        if is_ipv4 "$line" || is_ipv4_cidr "$line"; then
            array="${array:+$array,}$line"
            count=$((count + 1))
        elif is_ipv6 "$line" || is_ipv6_cidr "$line"; then
            array6="${array6:+$array6,}$line"
            count6=$((count6 + 1))
        else
            log "'$line' is not IPv4/IPv6 or CIDR" "debug"
            continue
        fi

        if [ "$count" = "$chunk_size" ]; then
            log "Adding $count elements to nft set $nft_set_name" "debug"
            nft_add_set_elements "$nft_table_name" "$nft_set_name" "$array"
            array=""
            count=0
        fi

        if [ "$count6" = "$chunk_size" ]; then
            log "Adding $count6 elements to nft set $nft_set6_name" "debug"
            nft_add_set_elements "$nft_table_name" "$nft_set6_name" "$array6"
            array6=""
            count6=0
        fi
    done < "$filepath"

    if [ -n "$array" ]; then
        log "Adding $count elements to nft set $nft_set_name" "debug"
        nft_add_set_elements "$nft_table_name" "$nft_set_name" "$array"
    fi

    if [ -n "$array6" ]; then
        if nft list set inet "$nft_table_name" "$nft_set6_name" > /dev/null 2>&1; then
            log "Adding $count6 elements to nft set $nft_set6_name" "debug"
            nft_add_set_elements "$nft_table_name" "$nft_set6_name" "$array6"
        else
            log "IPv6 entries skipped: nft set $nft_set6_name does not exist" "warn"
        fi
    fi
}
