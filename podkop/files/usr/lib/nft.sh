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