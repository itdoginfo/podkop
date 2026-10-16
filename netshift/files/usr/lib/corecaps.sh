# shellcheck shell=ash
#
# What the installed sing-box core can do, for the pages that must not offer what
# it cannot carry. The answer is built from the version, the variant and the build
# tags the core reports; a core that does not report its tags is treated as able
# (see core_has_tag). The features that every config build checks itself (see the
# facade) are the same ones listed here.

# Prints a JSON object: the core, its tags, and one flag per feature.
get_core_capabilities() {
    local version variant tags tags_known quic utls naive_core naive_client dns_pool extended
    local vless_encryption reality_mlkem

    version="$(get_sing_box_version)"
    variant="$(get_sing_box_variant "$version")"
    tags="$(get_sing_box_tags)"
    tags_known=false
    [ -z "$tags" ] || tags_known=true

    quic=false
    core_has_tag with_quic && quic=true
    utls=false
    core_has_tag with_utls && utls=true
    naive_core=false
    core_has_tag_strict with_naive_outbound && naive_core=true
    naive_client=false
    naive_binary > /dev/null 2>&1 && naive_client=true
    dns_pool=false
    is_sing_box_at_least "$SB_DNS_EVALUATE_MIN" "$version" && dns_pool=true
    extended=false
    is_sing_box_extended "$version" && extended=true
    vless_encryption=false
    is_sing_box_extended_at_least "$SB_EXTENDED_VLESS_ENCRYPTION_MIN" "$version" && vless_encryption=true
    reality_mlkem=false
    is_sing_box_extended_at_least "$SB_EXTENDED_REALITY_MLKEM_MIN" "$version" && reality_mlkem=true

    jq -n -c \
        --arg version "$version" --arg variant "$variant" --arg tags "$tags" \
        --argjson tags_known "$tags_known" --argjson quic "$quic" --argjson utls "$utls" \
        --argjson naive_core "$naive_core" --argjson naive_client "$naive_client" \
        --argjson dns_pool "$dns_pool" --argjson extended "$extended" \
        --argjson vless_encryption "$vless_encryption" --argjson reality_mlkem "$reality_mlkem" \
        '{
            version: $version,
            variant: $variant,
            tags: ($tags | split(",") | map(select(length > 0))),
            tags_known: $tags_known,
            quic: $quic,
            utls: $utls,
            naive: ($naive_core or $naive_client),
            naive_core: $naive_core,
            naive_client: $naive_client,
            dns_pool: $dns_pool,
            extended: $extended,
            vmess: $extended,
            xhttp: $extended,
            vless_encryption: $vless_encryption,
            reality_mlkem: $reality_mlkem
        }'
}
