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

# Adds the valid IPv4 addresses and subnets from a file to a set, one nft call per chunk_size elements
nft_add_set_elements_from_file_chunked() {
    local filepath="$1"
    local nft_table_name="$2"
    local nft_set_name="$3"
    local chunk_size="${4:-5000}"

    local valid_filepath chunks_dir chunk_filepath
    valid_filepath=$(mktemp)
    if ! filter_plain_list_file "$filepath" "subnets" "$valid_filepath"; then
        rm -f "$valid_filepath"
        return 1
    fi

    if [ -s "$valid_filepath" ]; then
        log "Adding $(wc -l < "$valid_filepath") elements to nft set $nft_set_name" "debug"

        # Every chunk is written as a separate nft script, so a rejected chunk does not affect the others
        chunks_dir=$(mktemp -d)
        awk -v dir="$chunks_dir" -v size="$chunk_size" -v table="$nft_table_name" -v set="$nft_set_name" '
            (NR - 1) % size == 0 {
                if (file != "") {
                    print " }" > file
                    close(file)
                }
                file = sprintf("%s/%08d", dir, NR)
                printf "add element inet %s %s { %s", table, set, $0 > file
                next
            }
            { printf ",%s", $0 > file }
            END { if (file != "") print " }" > file }' "$valid_filepath"

        for chunk_filepath in "$chunks_dir"/*; do
            [ -f "$chunk_filepath" ] && nft -f "$chunk_filepath"
        done
        rm -rf "$chunks_dir"
    fi

    rm -f "$valid_filepath"
}