#
# Module: sing_box_config_manager.sh
#
# Purpose:
#   This script provides a set of helper functions to simplify creation and management
#   of sing-box configuration.
#
# Conventions:
#   - All functions are prefixed with: sing_box_cm_*
#   - "cm" stands for "config manager", shortened by convention
#
# Usage:
#   Include this script in your ash script with:
#     . /usr/lib/podkop/sing_box_config_manager.sh
#
#   After that, sing_box_cm_* functions are available for generating
#   and modifying sing-box JSON configuration.

SERVICE_TAG="__service_tag"

#######################################
# Configure the logging section of a sing-box JSON configuration.
# Arguments:
#   config: string, JSON configuration
#   disabled: boolean, true to disable logging
#   level: string, log level. One of: trace debug info warn error fatal panic.
#   timestamp: boolean, true to include timestamps
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_configure_log "$CONFIG" false "info" true)
#######################################
sing_box_cm_configure_log() {
    local config="$1"
    local disabled="$2"
    local level="$3"
    local timestamp="$4"

    echo "$config" | jq \
        --argjson disabled "$disabled" \
        --arg level "$level" \
        --argjson timestamp "$timestamp" \
        '.log = {
			disabled: $disabled,
			level: $level,
			timestamp: $timestamp
		}'
}

#######################################
# Configure the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   final: string, default dns server tag
#   strategy: string, default domain strategy for resolving the domain names
#   independent_cache: boolean, whether to use an independent DNS cache
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_configure_dns "$CONFIG" "direct-out" "ipv4_only" true)
#######################################
sing_box_cm_configure_dns() {
    local config="$1"
    local final="$2"
    local strategy="$3"
    local independent_cache="$4"

    echo "$config" | jq \
        --arg final "$final" \
        --arg strategy "$strategy" \
        --argjson independent_cache "$independent_cache" \
        '.dns = {
			servers: (.dns.servers // []),
			rules: (.dns.rules // []),
			final: $final,
			strategy: $strategy,
			independent_cache: $independent_cache
		}'

}

#######################################
# Add a UDP DNS server to the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the DNS server
#   server_address: string, IP address or hostname of the DNS server
#   server_port: string or integer, port of the DNS server
#   domain_resolver: string, domain resolver to use for resolving domain names (optional)
#   detour: string, tag of the upstream outbound (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_udp_dns_server "$CONFIG" "udp-server" "8.8.8.8" 53)
#######################################
sing_box_cm_add_udp_dns_server() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local domain_resolver="$5"
    local detour="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg domain_resolver "$domain_resolver" \
        --arg detour "$detour" \
        '.dns.servers += [(
            {
                type: "udp",
                tag: $tag,
                server: $server_address,
                server_port: ($server_port | tonumber)
		    }
            + (if $detour != "" then { detour: $detour } else {} end)
		    + (if $domain_resolver != "" then { domain_resolver: $domain_resolver } else {} end)
		)]'
}

#######################################
# Add a TLS DNS server to the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the DNS server
#   server_address: string, IP address or hostname of the DNS server
#   server_port: string or integer, port of the DNS server
#   domain_resolver: string, domain resolver to use for resolving domain names (optional)
#   detour: string, tag of the upstream outbound (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_tls_dns_server "$CONFIG" "dot-server" "1.1.1.1" 853)
#######################################
sing_box_cm_add_tls_dns_server() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local domain_resolver="$5"
    local detour="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg domain_resolver "$domain_resolver" \
        --arg detour "$detour" \
        '.dns.servers += [(
            {
			    type: "tls",
			    tag: $tag,
			    server: $server_address,
			    server_port: ($server_port | tonumber)
		    }
            + (if $detour != "" then { detour: $detour } else {} end)
		    + (if $domain_resolver != "" then { domain_resolver: $domain_resolver } else {} end)
		)]'
}

#######################################
# Add an HTTPS DNS server to the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the DNS server
#   server_address: string, IP address or hostname of the DNS server
#   server_port: string or integer, port of the DNS server
#   path: string, URL path for HTTPS DNS requests (optional)
#   headers: string, additional headers for HTTPS DNS requests (optional)
#   domain_resolver: string, domain resolver to use for resolving domain names (optional)
#   detour: string, tag of the upstream outbound (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_https_dns_server "$CONFIG" "doh-server" "1.1.1.1" 443)
#######################################
sing_box_cm_add_https_dns_server() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local path="$5"
    local headers="$6"
    local domain_resolver="$7"
    local detour="$8"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg path "$path" \
        --arg headers "$headers" \
        --arg domain_resolver "$domain_resolver" \
        --arg detour "$detour" \
        '.dns.servers += [(
			{
				type: "https",
				tag: $tag,
				server: $server_address,
				server_port: ($server_port |tonumber)
			}
			+ (if $path != "" then { path: $path } else {} end)
			+ (if $headers != "" then { headers: $headers } else {} end)
            + (if $detour != "" then { detour: $detour } else {} end)
			+ (if $domain_resolver != "" then { domain_resolver: $domain_resolver } else {} end)
		)]'
}

#######################################
# Add a FakeIP DNS server to the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the DNS server
#   inet4_range: string, IPv4 range used for fake IP mapping
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_fakeip_dns_server "$CONFIG" "fakeip-server" "198.18.0.0/15")
#######################################
sing_box_cm_add_fakeip_dns_server() {
    local config="$1"
    local tag="$2"
    local inet4_range="$3"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg inet4_range "$inet4_range" \
        '.dns.servers += [{
			type: "fakeip",
			tag: $tag,
			inet4_range: $inet4_range,
		}]'
}

#######################################
# Add a DNS routing rule to the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   server: string, target DNS server for the rule
#   tag: string, identifier for the route rule
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_dns_route_rule "$CONFIG" "fakeip-server" "fakeip-dns-rule-id")
#######################################
sing_box_cm_add_dns_route_rule() {
    local config="$1"
    local server="$2"
    local tag="$3"

    echo "$config" | jq \
        --arg server "$server" \
        --arg service_tag "$SERVICE_TAG" \
        --arg tag "$tag" \
        '.dns.rules += [{
            action: "route",
            server: $server,
            $service_tag: $tag
        }]'
}

#######################################
# Patch a DNS routing rule in the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the rule to patch
#   key: string, the key in the rule to update or add
#   value: string, JSON value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_patch_dns_route_rule "$CONFIG" "fakeip-dns-rule-id" "rule_set" "main")
#   CONFIG=$(sing_box_cm_patch_dns_route_rule "$CONFIG" "fakeip-dns-rule-id" "rule_set" '["main","second"]')
#   CONFIG=$(sing_box_cm_patch_dns_route_rule "$CONFIG" "fakeip-dns-rule-id" "domain" "example.com")
#######################################
sing_box_cm_patch_dns_route_rule() {
    local config="$1"
    local tag="$2"
    local key="$3"
    local value="$4"

    value=$(_normalize_arg "$value")

    echo "$config" | jq \
        --arg service_tag "$SERVICE_TAG" \
        --arg tag "$tag" \
        --arg key "$key" \
        --argjson value "$value" \
        'import "helpers" as h {"search": "/usr/lib/podkop"};
        .dns.rules |= map(
            if .[$service_tag] == $tag then
                if has($key) then
                    .[$key] |= h::extend_key_value(.; $value)
                else
                    . + { ($key): $value }
                end
            else
                .
            end
        )'
}

#######################################
# Add a DNS reject rule to the DNS section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   key: string, the key to set for the reject rule
#   value: string, JSON value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_dns_reject_rule "$CONFIG" "query_type" "HTTPS")
#######################################
sing_box_cm_add_dns_reject_rule() {
    local config="$1"
    local key="$2"
    local value="$3"

    value=$(_normalize_arg "$value")

    echo "$config" | jq \
        --arg key "$key" \
        --argjson value "$value" \
        '.dns.rules += [{
            action: "reject",
            ($key): $value
        }]'
}

#######################################
# Add a TProxy inbound to the inbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the inbound
#   listen_address: string, IP address to listen on
#   listen_port: integer, port to listen on
#   tcp_fast_open: boolean, enable or disable TCP Fast Open
#   udp_fragment: boolean, enable or disable UDP fragmentation
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_tproxy_inbound "$CONFIG" "tproxy-in" "127.0.0.1" 6969 true true)
#######################################
sing_box_cm_add_tproxy_inbound() {
    local config="$1"
    local tag="$2"
    local listen_address="$3"
    local listen_port="$4"
    local tcp_fast_open="$5"
    local udp_fragment="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --argjson tcp_fast_open "$tcp_fast_open" \
        --argjson udp_fragment "$udp_fragment" \
        '.inbounds += [{
    		type: "tproxy",
			tag: $tag,
			listen: $listen_address,
    		listen_port: $listen_port,
    		tcp_fast_open: $tcp_fast_open,
    		udp_fragment: $udp_fragment
		}]'
}

#######################################
# Add a Direct inbound to the inbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the inbound
#   listen_address: string, IP address to listen on
#   listen_port: integer, port to listen on
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_direct_inbound "$CONFIG" "dns-in" "127.0.0.42" 53)
#######################################
sing_box_cm_add_direct_inbound() {
    local config="$1"
    local tag="$2"
    local listen_address="$3"
    local listen_port="$4"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        '.inbounds += [{
			type: "direct",
			tag: $tag,
			listen: $listen_address,
			listen_port: $listen_port,
		}]'
}

#######################################
# Add a Mixed inbound to the inbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the inbound
#   listen_address: string, IP address to listen on
#   listen_port: integer, port to listen on
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_mixed_inbound "$CONFIG" "tproxy-in" "192.168.1.1" 2080)
#######################################
sing_box_cm_add_mixed_inbound() {
    local config="$1"
    local tag="$2"
    local listen_address="$3"
    local listen_port="$4"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        '.inbounds += [{
			type: "mixed",
			tag: $tag,
			listen: $listen_address,
			listen_port: $listen_port,
		}]'
}

#######################################
# Add a Direct outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_direct_outbound "$CONFIG" "direct-out")
#######################################
sing_box_cm_add_direct_outbound() {
    local config="$1"
    local tag="$2"

    echo "$config" | jq \
        --arg tag "$tag" \
        '.outbounds += [{
            type: "direct",
            tag: $tag
        }]'
}

#######################################
# Add a SOCKS outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   server_address: string, IP address or hostname of the SOCKS server
#   server_port: integer, port of the SOCKS server
#   version: string, SOCKS version (optional)
#   username: string, username for authentication (optional)
#   password: string, password for authentication (optional)
#   network: string, network type (e.g., "tcp") (optional)
#   udp_over_tcp: integer, version for UDP over TCP (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_socks_outbound "$CONFIG" "socks5-out" "192.168.1.10" 1080)
#######################################
sing_box_cm_add_socks_outbound() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local version="$5"
    local username="$6"
    local password="$7"
    local network="$8"
    local udp_over_tcp="$9"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg version "$version" \
        --arg username "$username" \
        --arg password "$password" \
        --arg network "$network" \
        --arg udp_over_tcp "$udp_over_tcp" \
        '.outbounds += [(
            {
              type: "socks",
              tag: $tag,
              server: $server_address,
              server_port: ($server_port | tonumber)
            }
            + (if $version != "" then {version: $version} else {} end)
            + (if $username != "" then {username: $username} else {} end)
            + (if $password != "" then {password: $password} else {} end)
            + (if $network != "" then {network: $network} else {} end)
            + (if $udp_over_tcp != "" then {
                udp_over_tcp: {
                    enabled: true,
                    version: ($udp_over_tcp | tonumber)
                }
            } else {} end)

        )]'
}

#######################################
# Add a Shadowsocks outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   server_address: string, IP address or hostname of the Shadowsocks server
#   server_port: integer, port of the Shadowsocks server
#   method: string, encryption method
#   password: string, password for encryption
#   network: string, network type (e.g., "tcp") (optional)
#   udp_over_tcp: integer, version for UDP over TCP (optional)
#   plugin: string, plugin name (optional)
#   plugin_opts: string, plugin options (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(
#       sing_box_cm_add_shadowsocks_outbound "$CONFIG" "ss-out" "127.0.0.1" 443 \
#       "2022-blake3-aes-128-gcm" "8JCsPssfgS8tiRwiMlhARg=="
#   )
#######################################
sing_box_cm_add_shadowsocks_outbound() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local method="$5"
    local password="$6"
    local network="$7"
    local udp_over_tcp="$8"
    local plugin="$9"
    local plugin_opts="${10}"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg method "$method" \
        --arg password "$password" \
        --arg plugin "$plugin" \
        --arg plugin_opts "$plugin_opts" \
        --arg network "$network" \
        --arg udp_over_tcp "$udp_over_tcp" \
        '.outbounds += [(
            {
              type: "shadowsocks",
              tag: $tag,
              server: $server_address,
              server_port: ($server_port | tonumber),
              method: $method,
              password: $password
            }
            + (if $plugin != "" then {plugin: $plugin} else {} end)
            + (if $plugin_opts != "" then {plugin_opts: $plugin_opts} else {} end)
            + (if $network != "" then {network: $network} else {} end)
            + (if $udp_over_tcp != "" then {
                udp_over_tcp: {
                    enabled: true,
                    version: ($udp_over_tcp | tonumber)
                }
            } else {} end)
        )]'
}

#######################################
# Add a VLESS outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   server_address: string, IP address or hostname of the VLESS server
#   server_port: integer, port of the VLESS server
#   uuid: string, user UUID
#   flow: string, flow setting (optional)
#   network: string, network type (e.g., "tcp") (optional)
#   packet_encoding: string, packet encoding method (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(
#       sing_box_cm_add_vless_outbound "$CONFIG" "vless-reality-out" "example.com" 443 \
#       "bf000d23-0752-40b4-affe-68f7707a9661" "xtls-rprx-vision"
#   )
#######################################
sing_box_cm_add_vless_outbound() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local uuid="$5"
    local flow="$6"
    local network="$7"
    local packet_encoding="$8"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg uuid "$uuid" \
        --arg flow "$flow" \
        --arg network "$network" \
        --arg packet_encoding "$packet_encoding" \
        '.outbounds += [(
            {
              type: "vless",
              tag: $tag,
              server: $server_address,
              server_port: ($server_port | tonumber),
              uuid: $uuid
            }
            + (if $flow != "" then {flow: $flow} else {} end)
            + (if $network != "" then {network: $network} else {} end)
            + (if $packet_encoding != "" then {packet_encoding: $packet_encoding} else {} end)
        )]'
}

#######################################
# Add a Trojan outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   server_address: string, IP address or hostname of the Trojan server
#   server_port: integer, port of the Trojan server
#   password: string, password for authentication
#   network: string, network type (e.g., "tcp") (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_trojan_outbound "$CONFIG" "trojan-out" "example.com" 443 "supersecretpassword" "tcp")
#######################################
sing_box_cm_add_trojan_outbound() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local password="$5"
    local network="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg password "$password" \
        --arg network "$network" \
        '.outbounds += [(
        {
          type: "trojan",
          tag: $tag,
          server: $server_address,
          server_port: ($server_port | tonumber),
          password: $password
        }
        + (if $network != "" then {network: $network} else {} end)
    )]'
}

#######################################
# Add a Hysteria2 outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   server_address: string, IP address or hostname of the Hysteria2 server
#   server_port: integer, port of the Hysteria2 server
#   password: string, password for authentication
#   obfuscator_type: string, obfuscation type (optional)
#   obfuscator_password: string, obfuscation password (optional)
#   upload_mbps: integer, upload bandwidth limit in Mbps (optional)
#   download_mbps: integer, download bandwidth limit in Mbps (optional)
#   network: string, network type (e.g., "udp") (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_hysteria2_outbound "$CONFIG" "hysteria2-out" "example.com" 443 "supersecret" \
#       "salamander" "obfs-pass" "50" "200" "udp")
#######################################
sing_box_cm_add_hysteria2_outbound() {
    local config="$1"
    local tag="$2"
    local server_address="$3"
    local server_port="$4"
    local password="$5"
    local obfuscator_type="$6"
    local obfuscator_password="$7"
    local upload_mbps="$8"
    local download_mbps="$9"
    local network="${10}"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg password "$password" \
        --arg obfuscator_type "$obfuscator_type" \
        --arg obfuscator_password "$obfuscator_password" \
        --arg upload_mbps "$upload_mbps" \
        --arg download_mbps "$download_mbps" \
        --arg network "$network" \
        '.outbounds += [(
        {
          type: "hysteria2",
          tag: $tag,
          server: $server_address,
          server_port: ($server_port | tonumber),
          password: $password
        }
        + (if $obfuscator_type != "" and $obfuscator_password != "" then {
            obfs: {
                type: $obfuscator_type,
                password: $obfuscator_password
            }
        } else {} end)
        + (if $upload_mbps != "" then {up_mbps: ($upload_mbps | tonumber)} else {} end)
        + (if $download_mbps != "" then {down_mbps: ($download_mbps | tonumber)} else {} end)
        + (if $network != "" then {network: $network} else {} end)
    )]'
}

#######################################
# Set gRPC transport settings for an outbound in a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the outbound to modify
#   service_name: string, gRPC service name (optional)
#   idle_timeout: string or integer, idle timeout (optional)
#   ping_timeout: string or integer, ping timeout (optional)
#   permit_without_stream: boolean, flag for permitting without stream (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_set_grpc_transport_for_outbound "$CONFIG" "vless-tls-grpc-out")
#######################################
sing_box_cm_set_grpc_transport_for_outbound() {
    local config="$1"
    local tag="$2"
    local service_name="$3"
    local idle_timeout="$4"
    local ping_timeout="$5"
    local permit_without_stream="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg service_name "$service_name" \
        --arg idle_timeout "$idle_timeout" \
        --arg ping_timeout "$ping_timeout" \
        --arg permit_without_stream "$permit_without_stream" \
        '.outbounds |= map(
            if .tag == $tag then
                . + {
                    transport: (
                        { type: "grpc" }
                        + (if $service_name != "" then {service_name: $service_name} else {} end)
                        + (if $idle_timeout != "" then {idle_timeout: $idle_timeout} else {} end)
                        + (if $ping_timeout != "" then {ping_timeout: $ping_timeout} else {} end)
                        + (if $permit_without_stream != "" then {permit_without_stream: $permit_without_stream} else {} end)
                    )
                }
            else
                .
            end
        )'
}

#######################################
# Set WebSocket transport settings for an outbound in a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the outbound to modify
#   path: string, WebSocket path
#   host: string, Host header for WebSocket (optional)
#   max_early_data: integer, maximum early data (optional)
#   early_data_header_name: string, header name for early data (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_set_ws_transport_for_outbound "$CONFIG" "vless-tls-ws-out" "/path" "example.com")
#######################################
sing_box_cm_set_ws_transport_for_outbound() {
    local config="$1"
    local tag="$2"
    local path="$3"
    local host="$4"
    local max_early_data="$5"
    local early_data_header_name="$6"

    # Not sure if the "Host" parameter in headers is correct — needs verification
    echo "$config" | jq \
        --arg tag "$tag" \
        --arg path "$path" \
        --arg host "$host" \
        --arg max_early_data "$max_early_data" \
        --arg early_data_header_name "$early_data_header_name" \
        '.outbounds |= map(
            if .tag == $tag then
                . + {
                    transport: (
                        {
                            type: "ws",
                            path: $path
                        }
                        + (if $host != "" then {headers: {Host: $host}} else {} end)
                        + (if $max_early_data != "" then {max_early_data: $max_early_data | tonumber} else {} end)
                        + (if $early_data_header_name != "" then
                            {early_data_header_name: $early_data_header_name}
                        else {} end)
                    )
                }
            else
                .
            end
        )'
}

#######################################
# Set TLS settings for an outbound in a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the outbound to modify
#   server_name: string, used to verify the hostname on the returned certificates (optional)
#   insecure: boolean, accept any server certificate (optional)
#   alpn: string, JSON value, supported application level protocols (optional)
#   utls_fingerprint: string, uTLS fingerprint (optional)
#   reality_public_key: string, Reality public key (optional)
#   reality_short_id: string, Reality short ID (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(
#       sing_box_cm_set_tls_for_outbound "$CONFIG" "vless-reality-out" "example.com" false null "chrome" \
#       "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0" "0123456789abcdef"
#   )
#######################################
sing_box_cm_set_tls_for_outbound() {
    local config="$1"
    local tag="$2"
    local server_name="$3"
    local insecure="$4"
    local alpn="$5"
    local utls_fingerprint="$6"
    local reality_public_key="$7"
    local reality_short_id="$8"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg server_name "$server_name" \
        --arg insecure "$insecure" \
        --argjson alpn "$alpn" \
        --arg utls_fingerprint "$utls_fingerprint" \
        --arg reality_public_key "$reality_public_key" \
        --arg reality_short_id "$reality_short_id" \
        '.outbounds |= map(
            if .tag == $tag then
                . + {
                    tls: (
                        { enabled: true }
                        + (if $server_name != "" then {server_name: $server_name} else {} end)
                        + (if $insecure == "true" then {insecure: true} else {} end)
                        + (if $alpn != null then {alpn: $alpn} else {} end)
                        + (if $utls_fingerprint != "" then {
                            utls: {
                                enabled: true,
                                fingerprint: $utls_fingerprint
                            }
                        } else {} end)
                        + (if $reality_public_key != "" then {
                            reality: {
                                enabled: true,
                                public_key: $reality_public_key,
                                short_id: $reality_short_id
                            }
                        } else {} end)
                    )
                }
            else
                .
            end
        )'
}

#######################################
# Add a Direct outbound with a specific network interface to a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   interface: string, network interface to bind the outbound
#   domain_resolver: string, tag of the domain resolver to be used for this outbound (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_interface_outbound "$CONFIG" "warp-out" "awg0")
#######################################
sing_box_cm_add_interface_outbound() {
    local config="$1"
    local tag="$2"
    local interface="$3"
    local domain_resolver="$4"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg interface "$interface" \
        --arg domain_resolver "$domain_resolver" \
        '.outbounds += [
            {
                type: "direct",
                tag: $tag,
                bind_interface: $interface
            }
            + (if $domain_resolver != "" then {domain_resolver: $domain_resolver} else {} end)
        ]'
}

#######################################
# Add a raw outbound JSON object to the outbounds section of a sing-box configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the outbound
#   raw_outbound: string, JSON object, the raw outbound configuration to add
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_raw_outbound "$CONFIG" "raw-out" '{"type":"trojan","tag":"trojan-out","server":"127.0.0.1","server_port":1080,"password":"8JCsPssfgS8tiRwiMlhARg==","network":"tcp"}')
#######################################
sing_box_cm_add_raw_outbound() {
    local config="$1"
    local tag="$2"
    local raw_outbound="$3"

    echo "$config" | jq \
        --arg tag "$tag" \
        --argjson raw_outbound "$raw_outbound" \
        '.outbounds += [(
            $raw_outbound + {tag: $tag}
        )]'
}

#######################################
# Add a URLTest outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the URLTest outbound
#   outbounds: string, JSON array of outbound tags to test
#   url: string, URL to probe (optional)
#   interval: string, test interval (e.g., "10s") (optional)
#   tolerance: string or integer, max latency difference tolerated (optional)
#   idle_timeout: string or integer, idle timeout duration (optional)
#   interrupt_exist_connections: boolean, flag to interrupt existing connections ("true"/"false") (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_urltest_outbound "$CONFIG" "auto-select" '["proxy1","proxy2"]')
#######################################
sing_box_cm_add_urltest_outbound() {
    local config="$1"
    local tag="$2"
    local outbounds="$3"
    local url="$4"
    local interval="$5"
    local tolerance="$6"
    local idle_timeout="$7"
    local interrupt_exist_connections="$8"

    echo "$config" | jq \
        --arg tag "$tag" \
        --argjson outbounds "$outbounds" \
        --arg url "$url" \
        --arg interval "$interval" \
        --arg tolerance "$tolerance" \
        --arg idle_timeout "$idle_timeout" \
        --arg interrupt_exist_connections "$interrupt_exist_connections" \
        '.outbounds += [
            {
                type: "urltest",
                tag: $tag,
                outbounds: $outbounds
            }
            + (if $url != "" then {url: $url} else {} end)
            + (if $interval != "" then {interval: $interval} else {} end)
            + (if $tolerance != "" then {tolerance: ($tolerance | tonumber)} else {} end)
            + (if $idle_timeout != "" then {idle_timeout: $idle_timeout} else {} end)
            + (if $interrupt_exist_connections == "true" then {interrupt_exist_connections: true} else {} end)
        ]'
}

#######################################
# Add a Selector outbound to the outbounds section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the Selector outbound
#   outbounds: string (JSON), array of outbound tags to choose from
#   default: string, default outbound tag if none selected
#   interrupt_exist_connections: boolean, flag to interrupt existing connections ("true"/"false") (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_selector_outbound "$CONFIG" "select-proxy" '["proxy1","proxy2"]')
#######################################
sing_box_cm_add_selector_outbound() {
    local config="$1"
    local tag="$2"
    local outbounds="$3"
    local default="$4"
    local interrupt_exist_connections="$5"

    echo "$config" | jq \
        --arg tag "$tag" \
        --argjson outbounds "$outbounds" \
        --arg default "$default" \
        --arg interrupt_exist_connections "$interrupt_exist_connections" \
        '.outbounds += [
            {
                type: "selector",
                tag: $tag,
                outbounds: $outbounds,
                default: $default
            }
            + (if $interrupt_exist_connections == "true" then {interrupt_exist_connections: true} else {} end)
        ]'
}

#######################################
# Configure the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   final: string, final outbound tag for unmatched traffic
#   auto_detect_interface: boolean, enable or disable automatic interface detection
#   default_domain_resolver: string, default DNS resolver for domain-based routing
#   default_interface: string, default network interface to use when auto detection is disabled (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_configure_route "$CONFIG" "direct-out" true "udp-server")
#######################################
sing_box_cm_configure_route() {
    local config="$1"
    local final="$2"
    local auto_detect_interface="$3"
    local default_domain_resolver="$4"
    local default_interface="$5"

    echo "$config" | jq \
        --arg final "$final" \
        --argjson auto_detect_interface "$auto_detect_interface" \
        --arg default_domain_resolver "$default_domain_resolver" \
        --arg default_interface "$default_interface" \
        '.route = {
            rules: (.route.rules // []),
            rule_set: (.route.rule_set // []),
            final: $final,
            auto_detect_interface: $auto_detect_interface,
            default_domain_resolver: $default_domain_resolver
        }
        + (if $default_interface != "" then { default_interface: $default_interface } else {} end)
        '
}

#######################################
# Add a routing rule to the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the route rule
#   inbound: string, inbound tag to match
#   outbound: string, outbound tag to route matched traffic to
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_route_rule "$CONFIG" "main-route-rule" "tproxy-in" "main")
#######################################
sing_box_cm_add_route_rule() {
    local config="$1"
    local tag="$2"
    local inbound="$3"
    local outbound="$4"

    echo "$config" | jq \
        --arg service_tag "$SERVICE_TAG" \
        --arg tag "$tag" \
        --arg inbound "$inbound" \
        --arg outbound "$outbound" \
        '.route.rules += [{
            action: "route",
            inbound: $inbound,
            outbound: $outbound,
            $service_tag: $tag
        }]'
}

#######################################
# Patch a routing rule in the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the route rule to patch
#   key: string, the key in the rule to update or add
#   value: string (JSON), value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_patch_route_rule "$CONFIG" "main-route-rule" "rule_set" "inline-ruleset")
#######################################
sing_box_cm_patch_route_rule() {
    local config="$1"
    local tag="$2"
    local key="$3"
    local value="$4"

    value=$(_normalize_arg "$value")

    echo "$config" | jq \
        --arg service_tag "$SERVICE_TAG" \
        --arg tag "$tag" \
        --arg key "$key" \
        --argjson value "$value" \
        'import "helpers" as h {"search": "/usr/lib/podkop"};
        .route.rules |= map(
            if .[$service_tag] == $tag then
                if has($key) then
                    .[$key] |= h::extend_key_value(.; $value)
                else
                    . + { ($key): $value }
                end
            else
                .
            end
        )'
}

#######################################
# Add a reject rule to the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   key: string, the key to set for the reject rule
#   value: string (JSON), value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_reject_route_rule "$CONFIG" "reject-rule-tag")
#######################################
sing_box_cm_add_reject_route_rule() {
    local config="$1"
    local tag="$2"
    local inbound="$3"

    echo "$config" | jq \
        --arg service_tag "$SERVICE_TAG" \
        --arg tag "$tag" \
        --arg inbound "$inbound" \
        '.route.rules += [{
            action: "reject",
            inbound: $inbound,
            $service_tag: $tag
        }]'
}

#######################################
# Add a hijack-dns rule to the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   key: string, the key to set for the hijack-dns rule
#   value: string (JSON), value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_hijack_dns_route_rule "$CONFIG" "protocol" "dns")
#######################################
sing_box_cm_add_hijack_dns_route_rule() {
    local config="$1"
    local key="$2"
    local value="$3"

    value=$(_normalize_arg "$value")

    echo "$config" | jq \
        --arg key "$key" \
        --argjson value "$value" \
        '.route.rules += [{
            action: "hijack-dns",
            ($key): $value
        }]'
}

#######################################
# Add a route-options rule to the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the route-options rule
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_options_route_rule "$CONFIG" "override-fakeip-port")
#######################################
sing_box_cm_add_options_route_rule() {
    local config="$1"
    local tag="$2"

    echo "$config" | jq \
        --arg service_tag "$SERVICE_TAG" \
        --arg tag "$tag" \
        '.route.rules += [{
            action: "route-options",
            $service_tag: $tag
        }]'
}

#######################################
# Add a sniff rule to the route section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   key: string, the key to set for the sniff rule
#   value: string (JSON), value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_sniff_route_rule "$CONFIG" "inbound" "tproxy-in")
#   CONFIG=$(sing_box_cm_sniff_route_rule "$CONFIG" "inbound" '["tproxy-in","dns-in"]')
#######################################
sing_box_cm_sniff_route_rule() {
    local config="$1"
    local key="$2"
    local value="$3"

    value=$(_normalize_arg "$value")

    echo "$config" | jq \
        --arg key "$key" \
        --argjson value "$value" \
        '.route.rules += [{
            action: "sniff",
            ($key): $value
        }]'
}

#######################################
# Add an inline ruleset to the route.rule_set section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the inline ruleset
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_inline_ruleset "$CONFIG" "inline-ruleset")
#######################################
sing_box_cm_add_inline_ruleset() {
    local config="$1"
    local tag="$2"

    echo "$config" | jq \
        --arg tag "$tag" \
        '.route.rule_set += [{
            type: "inline",
            tag: $tag
        }]'
}

#######################################
# Add or update a rule in an inline ruleset within the route.rule_set section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier of the inline ruleset
#   key: string, the key in the ruleset to update or add
#   value: string (JSON), value to assign to the key
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_inline_ruleset_rule "$CONFIG" "inline-ruleset" "domain_suffix" "telegram.org")
#   CONFIG=$(sing_box_cm_add_inline_ruleset_rule "$CONFIG" "inline-ruleset" "domain_suffix" "discord.com")
#   CONFIG=$(sing_box_cm_add_inline_ruleset_rule "$CONFIG" "inline-ruleset" "ip_cidr" "111.111.111.111/32")
#######################################
sing_box_cm_add_inline_ruleset_rule() {
    local config="$1"
    local tag="$2"
    local key="$3"
    local value="$4"

    value=$(_normalize_arg "$value")

    echo "$config" | jq -L /usr/lib/podkop \
        --arg tag "$tag" \
        --arg key "$key" \
        --argjson value "$value" \
        'import "helpers" as h {"search": "/usr/lib/podkop"};
        .route.rule_set |= map(
            if .tag == $tag then
                if has($key) then
                    .[$key] |= h::extend_key_value(.; $value)
                else
                    . + { ($key): $value }
                end
            else
                .
            end
        )'
}

#######################################
# Add a local ruleset to the route.rule_set section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the local ruleset
#   format: string, format of the local ruleset ("source" or "binary")
#   path: string, file path to the local ruleset
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_local_ruleset "$CONFIG" "local-source-ruleset" "source" "/tmp/local-ruleset.json")
#   CONFIG=$(sing_box_cm_add_local_ruleset "$CONFIG" "local-binary-ruleset" "binary" "/tmp/local-ruleset.srs")
#######################################
sing_box_cm_add_local_ruleset() {
    local config="$1"
    local tag="$2"
    local format="$3"
    local path="$4"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg format "$format" \
        --arg path "$path" \
        '.route.rule_set += [{
            type: "local",
            tag: $tag,
            format: $format,
            path: $path
        }]'
}

#######################################
# Add a remote ruleset to the route.rule_set section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   tag: string, identifier for the remote ruleset
#   format: string, format of the remote ruleset ("source" or "binary")
#   url: string, URL to download the ruleset from
#   download_detour: string, detour tag for downloading (optional)
#   update_interval: string, update interval for the ruleset (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_add_remote_ruleset "$CONFIG" "remote-source-ruleset" "source" "https://example.com/telegram.json")
#######################################
sing_box_cm_add_remote_ruleset() {
    local config="$1"
    local tag="$2"
    local format="$3"
    local url="$4"
    local download_detour="$5"
    local update_interval="$6"

    echo "$config" | jq \
        --arg tag "$tag" \
        --arg format "$format" \
        --arg url "$url" \
        --arg download_detour "$download_detour" \
        --arg update_interval "$update_interval" \
        '.route.rule_set += [(
            {
                type: "remote",
                tag: $tag,
                format: $format,
                url: $url
            }
            + (if $download_detour != "" then { download_detour: $download_detour } else {} end)
            + (if $update_interval != "" then { update_interval: $update_interval } else {} end)
        )]'

}

#######################################
# Configure the experimental cache_file section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   enabled: boolean, enable or disable file caching
#   path: string, file path for cache storage
#   store_fakeip: boolean, whether to store fake IPs in the cache
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_configure_cache_file "$CONFIG" true "/tmp/cache.db" true)
#######################################
sing_box_cm_configure_cache_file() {
    local config="$1"
    local enabled="$2"
    local path="$3"
    local store_fakeip="$4"

    echo "$config" | jq \
        --argjson enabled "$enabled" \
        --arg path "$path" \
        --argjson store_fakeip "$store_fakeip" \
        '.experimental.cache_file = {
            enabled: $enabled,
            path: $path,
            store_fakeip: $store_fakeip
        }'
}

#######################################
# Configure the experimental clash_api section of a sing-box JSON configuration.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   external_controller: string, API listening address; Clash API will be disabled if empty
#   external_ui: string, path to static web resources to serve at http://{{external-controller}}/ui (optional)
#   secret: string, secret for the RESTful API Authenticate by specifying HTTP header (optional)
# Outputs:
#   Writes updated JSON configuration to stdout
# Example:
#   CONFIG=$(sing_box_cm_configure_clash_api "$CONFIG" "192.168.1.1:9090" "ui")
#######################################
sing_box_cm_configure_clash_api() {
    local config="$1"
    local external_controller="$2"
    local external_ui="$3"
    local secret="$4"

    echo "$config" | jq \
        --arg external_controller "$external_controller" \
        --arg external_ui "$external_ui" \
        --arg secret "$secret" \
        '.experimental.clash_api = {
            external_controller: $external_controller,
        }
        + (if $external_ui != "" then { external_ui: $external_ui } else {} end)
        + (if $secret != "" then { secret: $secret } else {} end)'
}

#######################################
# Save a sing-box JSON configuration to a file, removing service-specific tags.
# Arguments:
#   config: string (JSON), sing-box configuration to modify
#   file_path: string, path to save the configuration file
# Outputs:
#   Writes the cleaned JSON configuration to the specified file
# Example:
#   sing_box_cm_save_config_to_file "$CONFIG" "/tmp/sing-box-config.json"
#######################################
sing_box_cm_save_config_to_file() {
    local config="$1"
    local filepath="$2"

    echo "$config" | jq \
        --arg tag "$SERVICE_TAG" \
        'walk(if type == "object" then del(.[$tag]) else . end)' \
        > "$filepath"
}

_normalize_arg() {
    local value="$1"
    if echo "$value" | jq -e . > /dev/null 2>&1; then
        printf '%s' "$value"
    else
        printf '%s' "$value" | jq -R .
    fi
}
