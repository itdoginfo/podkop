PODKOP_LIB="/usr/lib/podkop"
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/sing_box_config_manager.sh"

sing_box_cf_add_dns_server() {
    local config="$1"
    local type="$2"
    local tag="$3"
    local server_address="$4"
    local path="$5"
    local headers="$6"
    local domain_resolver="$7"
    local detour="$8"

    case "$type" in
    udp)
        config=$(sing_box_cm_add_udp_dns_server "$config" "$tag" "$server_address" 53 "$domain_resolver" "$detour")
        ;;
    dot)
        config=$(sing_box_cm_add_tls_dns_server "$config" "$tag" "$server_address" 853 "$domain_resolver" "$detour")
        ;;
    doh)
        config=$(
            sing_box_cm_add_https_dns_server "$config" "$tag" "$server_address" 443 "$path" "$headers" \
                "$domain_resolver" "$detour"
        )
        ;;
    *)
        log "Unsupported DNS server type: $type"
        exit 1
        ;;
    esac

    echo "$config"
}

sing_box_cf_add_mixed_inbound_and_route_rule() {
    local config="$1"
    local tag="$2"
    local listen_address="$3"
    local listen_port="$4"
    local outbound="$5"

    config=$(sing_box_cm_add_mixed_inbound "$config" "$tag" "$listen_address" "$listen_port")
    config=$(sing_box_cm_add_route_rule "$config" "" "$tag" "$outbound")

    echo "$config"
}

sing_box_cf_add_proxy_outbound() {
    local config="$1"
    local section="$2"
    local url="$3"
    local udp_over_tcp="$4"

    url=$(url_decode "$url")

    local scheme="${url%%://*}"
    case "$scheme" in
    vless)
        local tag host port uuid flow
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        uuid=$(url_get_userinfo "$url")
        flow=$(url_get_query_param "$url" "flow")

        config=$(sing_box_cm_add_vless_outbound "$config" "$tag" "$host" "$port" "$uuid" "$flow")

        local transport
        transport=$(url_get_query_param "$url" "type")
        case "$transport" in
        tcp | raw) ;;
        ws)
            local ws_path ws_host ws_early_data
            ws_path=$(url_get_query_param "$url" "path")
            ws_host=$(url_get_query_param "$url" "host")
            ws_early_data=$(url_get_query_param "$url" "ed")

            config=$(sing_box_cm_set_vless_ws_transport "$config" "$tag" "$ws_path" "$ws_host" "$ws_early_data")
            ;;
        grpc)
            # TODO(ampetelin): Add handling of optional gRPC parameters; example links are needed.
            config=$(sing_box_cm_set_vless_grpc_transport "$config" "$tag")
            ;;
        *)
            log "Unknown transport '$transport' detected." "error"
            ;;
        esac

        local security
        security=$(url_get_query_param "$url" "security")
        case "$security" in
        tls | reality)
            local sni insecure alpn fingerprint public_key short_id
            sni=$(url_get_query_param "$url" "sni")
            insecure=$(url_get_query_param "$url" "allowInsecure")
            alpn=$(comma_string_to_json_array "$(url_get_query_param "$url" "alpn")")
            fingerprint=$(url_get_query_param "$url" "fp")
            public_key=$(url_get_query_param "$url" "pbk")
            short_id=$(url_get_query_param "$url" "sid")

            config=$(
                sing_box_cm_set_vless_tls \
                    "$config" \
                    "$tag" \
                    "$sni" \
                    "$([ "$insecure" == "1" ] && echo true)" \
                    "$([ "$alpn" == "[]" ] && echo null || echo "$alpn")" \
                    "$fingerprint" \
                    "$public_key" \
                    "$short_id"
            )
            ;;
        none) ;;
        *)
            log "Unknown security '$security' detected." "error"
            ;;
        esac
        ;;
    ss)
        local userinfo tag host port method password udp_over_tcp

        userinfo=$(url_get_userinfo "$url")
        if is_base64 "$userinfo"; then
            userinfo=$(base64_decode "$userinfo")
        fi

        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        method="${userinfo%%:*}"
        password="${userinfo#*:}"

        config=$(
            sing_box_cm_add_shadowsocks_outbound \
                "$config" \
                "$tag" \
                "$host" \
                "$port" \
                "$method" \
                "$password" \
                "" \
                "$([ "$udp_over_tcp" == "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
        )
        ;;
    *)
        log "Unsupported proxy $scheme type"
        exit 1
        ;;
    esac

    echo "$config"
}

sing_box_cf_add_json_outbound() {
    local config="$1"
    local section="$2"
    local json_outbound="$3"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    config=$(sing_box_cm_add_raw_outbound "$config" "$tag" "$json_outbound")

    echo "$config"
}

sing_box_cf_add_interface_outbound() {
    local config="$1"
    local section="$2"
    local interface_name="$3"

    local tag
    tag=$(get_outbound_tag_by_section "$section")

    config=$(sing_box_cm_add_interface_outbound "$config" "$tag" "$interface_name")

    echo "$config"
}

sing_box_cf_proxy_domain() {
    local config="$1"
    local inbound="$2"
    local domain="$3"
    local outbound="$4"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_route_rule "$config" "$tag" "$inbound" "$outbound")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "domain" "$domain")

    echo "$config"
}

sing_box_cf_override_domain_port() {
    local config="$1"
    local domain="$2"
    local port="$3"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_options_route_rule "$config" "$tag")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "domain" "$domain")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "override_port" "$port")

    echo "$config"
}

sing_box_cf_add_remote_ruleset_with_dns_and_route_rule() {
    local config="$1"
}
