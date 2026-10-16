# shellcheck shell=ash
#
# A report for support: what a person who is asked "what do you have there" would otherwise
# have to collect by hand (versions, the configuration, the generated sing-box config, the
# state of the services and nft, the logs), with the secrets taken out. Everything that
# identifies the user is masked before the text leaves the router: passwords, keys, uuids and
# tokens, whole proxy and subscription links, the lists of domains, subnets and devices (only
# their number is kept), and every server address of the configuration (host-1, host-2 ... the
# same name each time it comes up, in the config and in the logs). The logs themselves are only
# masked where the report knows the shape: links, web addresses, the DNS servers with an id of
# the user, the destination of a failed connection. A domain a log line carries in another
# place is NOT removed: look through the report before it is sent.

SUPPORT_LOG_LINES=120
SUPPORT_ERROR_LINES=80
SUPPORT_CRASH_LINES=60

# The UCI configuration of netshift as JSON ({"values": {...}}). A function of its own so that
# a test can put a fixture in its place.
support_uci_json() {
    ubus call uci get '{"config":"netshift"}' 2> /dev/null
}

# stdin: the UCI JSON; $1: the JSON array of hidden server names. stdout: the same, masked.
support_mask_uci() {
    jq -c --argjson hosts "${1:-[]}" '
        def count_or_hide: if type == "array" then ["<\(length) entries>"] else "<hidden>" end;
        def link_scheme: if type == "string" and contains("://") then (split("://")[0] | split(" ") | last) + "://<hidden>" else "<hidden>" end;
        def mask_links: if type == "array" then map(link_scheme)
            elif type == "string" then ([split("\n")[] | split(" ")[] | select(length > 0) | link_scheme]) else "<hidden>" end;
        # a word of the option name (password, secret, key ...): "public_key" is secret, "keywords" is not
        def secret_name: (ascii_downcase | split("_")) as $words
            | any($words[]; IN("password", "passwd", "secret", "token", "uuid", "auth", "psk", "hwid", "private", "pubkey", "key", "sid", "username"));
        def link_options: ["proxy_string", "selector_proxy_links", "urltest_proxy_links", "selector_proxy_links_text", "urltest_proxy_links_text"];
        def data_options: ["user_domains", "user_domains_text", "user_subnets", "user_subnets_text", "fully_routed_ips", "routing_excluded_ips",
                           "local_domain_lists", "local_subnet_lists", "remote_domain_lists", "remote_subnet_lists", "source_network_interfaces",
                           "subscription_url", "outbound_json", "dns_hijack_ips",
                           "dns_client_subnet"];
        .values // {}
        | with_entries(.value |= (
            with_entries(
                .key as $k
                | if ($k | startswith(".")) then .
                elif (link_options | index($k)) != null then .value |= mask_links
                elif (data_options | index($k)) != null then .value |= count_or_hide
                elif ($k | secret_name) then .value = "<hidden>"
                else . end)))
        | ([range(0; $hosts | length)] | sort_by(-($hosts[.] | length))) as $longest_first
        | walk(if type == "string" then (reduce $longest_first[] as $i (.; split($hosts[$i]) | join("host-\($i + 1)"))) else . end)' 2> /dev/null
}

# stdin: the sing-box config. $1: the JSON array of server names. stdout: the config with the
# secrets and the lists of the user taken out.
support_mask_singbox() {
    jq --argjson hosts "${1:-[]}" '
        def secret_key: ["uuid", "password", "passwd", "secret", "token", "private_key", "public_key", "short_id", "pre_shared_key",
                         "psk", "username", "auth_str", "auth", "key", "pin_sha256", "certificate_public_key_sha256",
                         "client_subnet", "path"];
        def list_key: ["domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "source_ip_cidr", "package_name"];
        def host_key: ["server", "server_name", "host", "Host", "address"];
        def test_ip: type == "string" and (split(".") | all(length > 0 and (tostring | explode | all(. >= 48 and . <= 57))));
        # the first label of a DNS server name with an id in it (id.dns.nextdns.io); a public
        # resolver (dns.google, dns.nextdns.io) keeps its name
        def dns_id_host: if type == "string" and ((split(".") | length) >= 4) and (test_ip | not)
            then "<hidden>." + (split(".")[1:] | join(".")) else . end;
        walk(
            if type == "object" then
                with_entries(
                    .key as $k | .value as $v
                    | if (secret_key | index($k)) != null and ($v | type) != "object" then .value = "<hidden>"
                    elif (list_key | index($k)) != null and ($v | type) == "array" then .value = ["<\($v | length) entries>"]
                    elif (host_key | index($k)) != null and ($v | type) == "string" and ($hosts | index($v)) != null
                        then .value = "host-\($hosts | index($v) + 1)"
                    else . end)
            else . end)
        | (if .dns.servers? then .dns.servers |= map(if (type == "object") and (.server? | type) == "string" then .server |= dns_id_host else . end) else . end)' 2> /dev/null
}

# The server addresses of the sing-box config (the servers of the outbounds and the names in
# their TLS settings and the Host header of their transport), as a sorted JSON array: the key of the masking of everything else. The DNS
# servers are not among them (see support_mask_singbox).
support_hosts() {
    local config_file="$1"

    [ -r "$config_file" ] || { echo '[]'; return 0; }
    # the servers of the user's outbounds and the names in their TLS settings; the DNS servers are
    # public resolvers and stay readable
    jq -c '[(.outbounds // [])[] | (.server?, .tls?.server_name?, .transport?.headers?.Host?) | strings | select(length > 0)] | unique' "$config_file" 2> /dev/null || echo '[]'
}

# A sed script that puts host-N in place of every server address.
support_hosts_sed() {
    local hosts_json="$1"
    local index host escaped

    # host-N is the position in the sorted list (the same N as in the settings and the config),
    # but a name that is a part of another one ("example.org" in "srv.example.org") must be
    # replaced after it: the longest names go first
    printf '%s' "$hosts_json" | jq -r 'to_entries | sort_by(-(.value | length))[] | "\(.key + 1)\t\(.value)"' 2> /dev/null | while IFS="$(printf '\t')" read -r index host; do
        escaped="$(printf '%s' "$host" | tr -d '\n' | sed 's/[][\.*^$/|]/\\&/g')"
        printf 's/%s/host-%s/g\n' "$escaped" "$index"
    done
}

# The links and web addresses that a log line may carry.
support_mask_text() {
    sed -e 's#\(vless\|vmess\|ss\|trojan\|hysteria2\|hy2\|tuic\|anytls\|socks5\|socks4\|naive+https\|naive+quic\)://[^ "]*#\1://<hidden>#g' \
        -e 's#\(https\?://\)[^/ ?"]*@#\1<hidden>@#g' \
        -e 's#\(https\?://[^/ ?"]*\)[/?][^ "]*#\1/<hidden>#g' \
        -e 's#\(doh3\?://[^/ ?"]*\)[/?][^ "]*#\1/<hidden>#g' \
        -e 's#\(doh3\?\|dot\|doq\|h3\|tls\|quic\)://[^ ".:/]*\.\([^ ".:/]*\.[^ ".:/]*\.[^ ".:/]*\)#\1://<hidden>.\2#g' \
        -e "s#\\(connection to \\)[^ ]*#\\1<hidden>#g" \
        -e "s#\\(the domain '\\)[^']*#\\1<hidden>#g"
}

# The last crash of sing-box from the system log: the panic or fatal error line and the lines
# after it (the stack trace). A router keeps the log in RAM only, so this is what is still there.
get_sing_box_crash_log() {
    command -v logread > /dev/null 2>&1 || return 0
    logread -e sing-box 2> /dev/null | awk -v after="$SUPPORT_CRASH_LINES" '
        /panic:|fatal error:|SIGSEGV|SIGABRT/ { buf = $0 "\n"; n = 1; on = 1; next }
        on { buf = buf $0 "\n"; n++; if (n >= after) on = 0 }
        END { printf "%s", buf }'
}

support_section() {
    printf '\n===== %s =====\n' "$1"
}

# The report itself, on stdout.
support_report() {
    local config_file hosts_json sed_script tmp version variant tags local_crash

    config_file="$(config_get_value_or_default config_path /etc/sing-box/config.json)"
    hosts_json="$(support_hosts "$config_file")"
    sed_script="$(mktemp)" || return 1
    tmp="$(mktemp)" || { rm -f "$sed_script"; return 1; }
    # an interrupted call (the interface gives up after its timeout) leaves nothing in /tmp
    trap 'rm -f "$sed_script" "$tmp"' EXIT INT TERM
    support_hosts_sed "$hosts_json" > "$sed_script"

    {
        printf 'NetShift support report\n'
        printf 'Generated: %s (UTC)\n' "$(date -u '+%Y-%m-%d %H:%M:%S' 2> /dev/null)"
        printf 'Servers of the configuration are shown as host-N, links and lists as <hidden>.\n'

        support_section "NetShift"
        printf 'Version: %s\n' "${NETSHIFT_VERSION:-unknown}"
        printf 'Update source: %s\n' "$(config_get_value_or_default update_repo upstream)"

        support_section "System"
        sed -n 's/^DISTRIB_DESCRIPTION=//p' /etc/openwrt_release 2> /dev/null | tr -d "'\"" | sed 's/^/OpenWrt: /'
        printf 'Kernel: %s\n' "$(uname -r 2> /dev/null)"
        printf 'Architecture: %s\n' "$(uname -m 2> /dev/null)"
        [ -r /tmp/sysinfo/model ] && printf 'Model: %s\n' "$(cat /tmp/sysinfo/model)"
        printf 'Uptime: %s\n' "$(uptime 2> /dev/null | sed 's/^ *//')"
        free 2> /dev/null | sed -n '1,2p'
        df -h /overlay /tmp 2> /dev/null

        support_section "sing-box"
        version="$(get_sing_box_version 2> /dev/null)"
        variant="$(get_sing_box_variant "$version" 2> /dev/null)"
        tags="$(get_sing_box_tags 2> /dev/null)"
        printf 'Version: %s\nVariant: %s\nTags: %s\n' "$version" "$variant" "${tags:-not reported}"
        # the lite core runs as sing-box-core (the /usr/bin/sing-box wrapper execs it)
        printf 'Running: %s\n' "$(pidof sing-box sing-box-core > /dev/null 2>&1 && echo yes || echo no)"
        printf 'NaiveProxy client: %s\n' "$(naive_binary 2> /dev/null || echo 'not installed')"

        support_section "Settings (UCI, masked)"
        support_uci_json | support_mask_uci "$hosts_json" | jq . 2> /dev/null

        support_section "sing-box configuration (masked)"
        if [ -r "$config_file" ]; then
            support_mask_singbox "$hosts_json" < "$config_file" || echo "(the configuration could not be read)"
        else
            echo "(no configuration at $config_file)"
        fi

        support_section "Warnings of the configuration"
        # the warnings name the domains the user typed: they are counted out like the lists
        get_config_warnings 2> /dev/null | jq -c 'walk(if type == "object" and has("domain") then .domain = "<hidden>" else . end)' 2> /dev/null || echo "[]"

        support_section "nftables"
        nft list tables 2> /dev/null | grep -F "$NFT_TABLE_NAME" || echo "(no NetShift table)"

        support_section "Last crash of sing-box"
        local_crash="$(get_sing_box_crash_log)"
        [ -n "$local_crash" ] && printf "%s\n" "$local_crash" || echo "(none in the log)"

        support_section "Log of netshift (last $SUPPORT_LOG_LINES lines)"
        logread -e netshift 2> /dev/null | tail -n "$SUPPORT_LOG_LINES"

        support_section "Errors of sing-box (last $SUPPORT_ERROR_LINES lines)"
        logread -e sing-box 2> /dev/null | grep -iE "error|fatal|panic|warn" | tail -n "$SUPPORT_ERROR_LINES"
    } 2>&1 | support_mask_text | sed -f "$sed_script" > "$tmp"

    cat "$tmp"
    rm -f "$sed_script" "$tmp"
    trap - EXIT INT TERM
}

# A setting of the "settings" section, or the default.
config_get_value_or_default() {
    local value

    config_get value "settings" "$1" "$2"
    printf '%s' "$value"
}
