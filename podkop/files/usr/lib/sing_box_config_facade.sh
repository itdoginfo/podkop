PODKOP_LIB="/usr/lib/podkop"
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/sing_box_config_manager.sh"

sing_box_cf_add_dns_server() {
    local config="$1"
    local type="$2"
    local tag="$3"
    local server="$4"
    local domain_resolver="$5"
    local detour="$6"

    local server_address server_port
    server_address=$(url_get_host "$server")
    server_port=$(url_get_port "$server")

    case "$type" in
    udp)
        [ -z "$server_port" ] && server_port=53
        config=$(sing_box_cm_add_udp_dns_server "$config" "$tag" "$server_address" "$server_port" "$domain_resolver" \
            "$detour")
        ;;
    dot)
        [ -z "$server_port" ] && server_port=853
        config=$(sing_box_cm_add_tls_dns_server "$config" "$tag" "$server_address" "$server_port" "$domain_resolver" \
            "$detour")
        ;;
    doh)
        [ -z "$server_port" ] && server_port=443
        local path headers
        path=$(url_get_path "$server")
        headers="" # TODO(ampetelin): implement it if necessary
        config=$(sing_box_cm_add_https_dns_server "$config" "$tag" "$server_address" "$server_port" "$path" "$headers" \
            "$domain_resolver" "$detour")
        ;;
    *)
        log "Unsupported DNS server type: $type. Aborted." "fatal"
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
    url=$(url_strip_fragment "$url")

    local scheme
    scheme="$(url_get_scheme "$url")"
    case "$scheme" in
    socks4 | socks4a | socks5)
        local tag host port version userinfo username password udp_over_tcp

        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        version="${scheme#socks}"
        if [ "$scheme" = "socks5" ]; then
            userinfo=$(url_get_userinfo "$url")
            if [ -n "$userinfo" ]; then
                username="${userinfo%%:*}"
                password="${userinfo#*:}"
            fi
        fi
        config="$(sing_box_cm_add_socks_outbound \
            "$config" \
            "$tag" \
            "$host" \
            "$port" \
            "$version" \
            "$username" \
            "$password" \
            "" \
            "$([ "$udp_over_tcp" == "1" ] && echo 2)" # if udp_over_tcp is enabled, enable version 2
        )"
        ;;
    vless)
        local tag host port uuid flow packet_encoding
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        uuid=$(url_get_userinfo "$url")
        flow=$(url_get_query_param "$url" "flow")
        packet_encoding=$(url_get_query_param "$url" "packetEncoding")

        config=$(sing_box_cm_add_vless_outbound "$config" "$tag" "$host" "$port" "$uuid" "$flow" "" "$packet_encoding")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        config=$(_add_outbound_transport "$config" "$tag" "$url")
        ;;
    ss)
        local userinfo tag host port method password udp_over_tcp

        userinfo=$(url_get_userinfo "$url")
        if ! is_shadowsocks_userinfo_format "$userinfo"; then
            userinfo=$(base64_decode "$userinfo")
            if [ $? -ne 0 ]; then
                log "Cannot decode shadowsocks userinfo or it does not match the expected format. Aborted." "fatal"
                exit 1
            fi
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
    trojan)
        local tag host port password
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port=$(url_get_port "$url")
        password=$(url_get_userinfo "$url")

        config=$(sing_box_cm_add_trojan_outbound "$config" "$tag" "$host" "$port" "$password")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        config=$(_add_outbound_transport "$config" "$tag" "$url")
        ;;
    hysteria2 | hy2)
        local tag host port password obfuscator_type obfuscator_password upload_mbps download_mbps
        tag=$(get_outbound_tag_by_section "$section")
        host=$(url_get_host "$url")
        port="$(url_get_port "$url")"
        password=$(url_get_userinfo "$url")
        obfuscator_type=$(url_get_query_param "$url" "obfs")
        obfuscator_password=$(url_get_query_param "$url" "obfs-password")
        upload_mbps=$(url_get_query_param "$url" "upmbps")
        download_mbps=$(url_get_query_param "$url" "downmbps")

        config=$(sing_box_cm_add_hysteria2_outbound "$config" "$tag" "$host" "$port" "$password" "$obfuscator_type" \
            "$obfuscator_password" "$upload_mbps" "$download_mbps")
        config=$(_add_outbound_security "$config" "$tag" "$url")
        ;;
    *)
        log "Unsupported proxy $scheme type. Aborted." "fatal"
        exit 1
        ;;
    esac

    echo "$config"
}

_add_outbound_security() {
    local config="$1"
    local outbound_tag="$2"
    local url="$3"

    local security scheme
    security=$(url_get_query_param "$url" "security")
    if [ -z "$security" ]; then
        scheme="$(url_get_scheme "$url")"
        if [ "$scheme" = "hysteria2" ] || [ "$scheme" = "hy2" ]; then
            security="tls"
        fi
    fi

    case "$security" in
    tls | reality)
        local sni insecure alpn fingerprint public_key short_id
        sni=$(url_get_query_param "$url" "sni")
        insecure=$(_get_insecure_query_param_from_url "$url")
        alpn=$(comma_string_to_json_array "$(url_get_query_param "$url" "alpn")")
        fingerprint=$(url_get_query_param "$url" "fp")
        public_key=$(url_get_query_param "$url" "pbk")
        short_id=$(url_get_query_param "$url" "sid")

        config=$(
            sing_box_cm_set_tls_for_outbound \
                "$config" \
                "$outbound_tag" \
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

    echo "$config"
}

_get_insecure_query_param_from_url() {
    local url="$1"

    local insecure
    insecure=$(url_get_query_param "$url" "allowInsecure")
    if [ -z "$insecure" ]; then
        insecure=$(url_get_query_param "$url" "insecure")
    fi

    echo "$insecure"
}

_add_outbound_transport() {
    local config="$1"
    local outbound_tag="$2"
    local url="$3"

    local transport
    transport=$(url_get_query_param "$url" "type")
    case "$transport" in
    tcp | raw) ;;
    ws)
        local ws_path ws_host ws_early_data
        ws_path=$(url_get_query_param "$url" "path")
        ws_host=$(url_get_query_param "$url" "host")
        ws_early_data=$(url_get_query_param "$url" "ed")

        config=$(
            sing_box_cm_set_ws_transport_for_outbound "$config" "$outbound_tag" "$ws_path" "$ws_host" "$ws_early_data"
        )
        ;;
    grpc)
        # TODO(ampetelin): Add handling of optional gRPC parameters; example links are needed.
        local grpc_service_name
        grpc_service_name=$(url_get_query_param "$url" "serviceName")

        config=$(
            sing_box_cm_set_grpc_transport_for_outbound "$config" "$outbound_tag" "$grpc_service_name"
        )
        ;;
    *)
        log "Unknown transport '$transport' detected." "error"
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

sing_box_cf_add_single_key_reject_rule() {
    local config="$1"
    local inbound="$2"
    local key="$3"
    local value="$4"

    tag="$(gen_id)"
    config=$(sing_box_cm_add_reject_route_rule "$config" "$tag" "$inbound")
    config=$(sing_box_cm_patch_route_rule "$config" "$tag" "$key" "$value")

    echo "$config"
}

#######################################
# Parse a sing-box subscription JSON and add all proxy outbounds to the configuration.
# Filters out non-proxy types (selector, urltest, direct, dns, block).
# Uses 'tag' field (or 'remark' if present) as display name for each outbound.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   section: string, the UCI section name
#   subscription_json_path: string, path to the downloaded subscription JSON file
# Outputs:
#   Writes updated JSON configuration to stdout
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS (comma-separated list of tags)
#   Sets global variable SUBSCRIPTION_OUTBOUND_TAGS_JSON (JSON array of tags, ASCII-escaped)
#   Sets global variable SUBSCRIPTION_OUTBOUND_NAMES (newline-separated list of display names)
#######################################
sing_box_cf_add_subscription_outbounds() {
    local config="$1"
    local section="$2"
    local subscription_json_path="$3"

    SUBSCRIPTION_OUTBOUND_TAGS=""
    SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
    SUBSCRIPTION_OUTBOUND_NAMES=""
    SING_BOX_CF_LAST_CONFIG="$config"

    if [ ! -f "$subscription_json_path" ]; then
        log "Subscription JSON file not found: $subscription_json_path" "error"
        echo "$config"
        return 1
    fi

    # Extract proxy outbounds from subscription JSON
    # Filter out non-proxy types: selector, urltest, direct, dns, block
    local outbounds_count
    outbounds_count=$(jq -r '[.outbounds[] | select(
        .type != "selector" and
        .type != "urltest" and
        .type != "direct" and
        .type != "dns" and
        .type != "block"
    )] | length' "$subscription_json_path" 2>/dev/null)

    if [ -z "$outbounds_count" ] || [ "$outbounds_count" -eq 0 ]; then
        log "No proxy outbounds found in subscription JSON" "error"
        echo "$config"
        return 1
    fi

    log "Found $outbounds_count proxy outbounds in subscription" "info"

    local i=1
    local added_count=0
    local outbound_json display_name outbound_tag outbound_type outbound_tls_enabled preferred_tag base_tag tag_suffix

    while [ "$i" -le "$outbounds_count" ]; do
        # Extract the i-th proxy outbound as raw JSON
        outbound_json=$(jq -c "[.outbounds[] | select(
            .type != \"selector\" and
            .type != \"urltest\" and
            .type != \"direct\" and
            .type != \"dns\" and
            .type != \"block\"
        )][$i - 1]" "$subscription_json_path" 2>/dev/null)

        if [ -z "$outbound_json" ] || [ "$outbound_json" = "null" ]; then
            i=$((i + 1))
            continue
        fi

        # Get display name: prefer remark, then tag, then fallback
        display_name=$(echo "$outbound_json" | jq -r '.remark // .tag // "server-'"$i"'"' 2>/dev/null)

        outbound_type=$(echo "$outbound_json" | jq -r '.type // ""' 2>/dev/null)
        outbound_tls_enabled=$(echo "$outbound_json" | jq -r '.tls.enabled // false' 2>/dev/null)

        # sing-box does not support top-level tls field for shadowsocks outbound.
        if [ "$outbound_type" = "shadowsocks" ] && [ "$outbound_tls_enabled" = "true" ]; then
            log "Skip unsupported Shadowsocks outbound with tls: '$display_name'" "warn"
            i=$((i + 1))
            continue
        fi

        # Keep original tag from the subscription for dashboard readability.
        preferred_tag=$(echo "$outbound_json" | jq -r '.tag // .remark // "server-'"$i"'"' 2>/dev/null)
        if [ -z "$preferred_tag" ] || [ "$preferred_tag" = "null" ]; then
            preferred_tag="server-$i"
        fi

        base_tag="$preferred_tag"
        outbound_tag="$base_tag"
        tag_suffix=1
        while printf '%s' "$config" | jq -e --arg tag "$outbound_tag" '.outbounds[]? | select(.tag == $tag)' > /dev/null 2>&1; do
            outbound_tag="${base_tag}-$tag_suffix"
            tag_suffix=$((tag_suffix + 1))
        done

        # Remove tag from raw outbound (it will be set by sing_box_cm_add_raw_outbound)
        local clean_outbound
        clean_outbound=$(echo "$outbound_json" | jq -c 'del(.tag) | del(.remark)' 2>/dev/null)

        local updated_config
        updated_config=$(sing_box_cm_add_raw_outbound "$config" "$outbound_tag" "$clean_outbound" 2>/dev/null)
        if [ -z "$updated_config" ]; then
            log "Skip invalid outbound from subscription: '$display_name'" "warn"
            i=$((i + 1))
            continue
        fi

        # Validate against current sing-box version and skip unsupported outbounds.
        local validation_tmp
        validation_tmp="$(mktemp)"
        sing_box_cm_save_config_to_file "$updated_config" "$validation_tmp"
        if ! sing-box -c "$validation_tmp" check > /dev/null 2>&1; then
            rm -f "$validation_tmp"
            log "Skip unsupported outbound for current sing-box: '$display_name'" "warn"
            i=$((i + 1))
            continue
        fi
        rm -f "$validation_tmp"

        config="$updated_config"

        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS="$outbound_tag"
        else
            SUBSCRIPTION_OUTBOUND_TAGS="$SUBSCRIPTION_OUTBOUND_TAGS,$outbound_tag"
        fi

        # Keep a JSON representation to avoid Unicode corruption in shell string processing.
        SUBSCRIPTION_OUTBOUND_TAGS_JSON=$(
            printf '%s' "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" | jq -ac --arg tag "$outbound_tag" '. + [$tag]' 2>/dev/null
        )
        if [ -z "$SUBSCRIPTION_OUTBOUND_TAGS_JSON" ]; then
            SUBSCRIPTION_OUTBOUND_TAGS_JSON="[]"
        fi

        if [ -z "$SUBSCRIPTION_OUTBOUND_NAMES" ]; then
            SUBSCRIPTION_OUTBOUND_NAMES="$display_name"
        else
            SUBSCRIPTION_OUTBOUND_NAMES="$(printf '%s\n%s' "$SUBSCRIPTION_OUTBOUND_NAMES" "$display_name")"
        fi

        added_count=$((added_count + 1))
        i=$((i + 1))
    done

    log "Added $added_count subscription outbounds for section '$section'" "info"
    SING_BOX_CF_LAST_CONFIG="$config"

    echo "$config"
}
