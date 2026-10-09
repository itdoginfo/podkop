# shellcheck shell=ash
#
# DNS server benchmark: how fast each upstream answers from THIS router (the answer
# depends on the provider and the route, not on a table of "best" servers). Every
# server is asked one question with dig, all at the same time, so the whole run takes
# about as long as the slowest one (DNS_BENCH_TIMEOUT seconds at most). The result is
# a list of milliseconds, null for a server that did not answer or cannot be tested
# with dig (doh3, doq). Nothing is changed.
#
# With "Route main DNS through proxy/VPN" the servers are not reached from the router
# but from the exit of the tunnel (a resolver inside the tunnel, such as 172.31.x.x,
# does not exist for the router at all). Then a short-lived second sing-box is
# started: it carries one local "direct" inbound per server, each forwarding to that
# server through the very outbound the main DNS uses, and dig asks those local ports.
# The measurement therefore includes the tunnel, as it does for real queries.

DNS_BENCH_TIMEOUT=3
DNS_BENCH_DOMAIN="google.com"
DNS_BENCH_MAX_SERVERS=12
DNS_BENCH_TUNNEL_PORT_BASE=19200
DNS_BENCH_TUNNEL_START_WAIT=2

# "doh://dns.google/dns-query" -> prints the dig arguments "@<address> <flags>" or
# fails for a server dig cannot ask. The address is the one found through the
# bootstrap resolver ($2), so the lookup of the server's own name does not depend
# on the resolver that is being measured. $1 - server URL, $2 - bootstrap address.
dns_bench_dig_args() {
    local entry="$1"
    local bootstrap="$2"
    local scheme rest host path address

    scheme="${entry%%://*}"
    case "$scheme" in
    udp | tcp | dot | doh) ;;
    *) return 1 ;;
    esac
    rest="${entry#*://}"
    path="/${rest#*/}"
    [ "$path" = "/$rest" ] && path=""
    rest="${rest%%/*}"
    host="$(url_get_host "$rest")"
    [ -n "$host" ] || return 1

    if is_ipv4 "$host" || is_ipv6 "$host"; then
        address="$host"
    else
        address="$(dig @"$bootstrap" "$host" +short +time=2 +tries=1 2> /dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sed -n '1p')"
        [ -n "$address" ] || return 1
    fi

    case "$scheme" in
    udp) echo "@$address" ;;
    tcp) echo "@$address +tcp" ;;
    dot) echo "@$address +tls +tls-hostname=$host" ;;
    doh) echo "@$address +https=${path:-/dns-query} +tls-hostname=$host" ;;
    esac
}

# Milliseconds one server needs to answer, or nothing. $1 - server URL, $2 - bootstrap.
dns_bench_one() {
    local args output ms

    args="$(dns_bench_dig_args "$1" "$2")" || return 1
    # shellcheck disable=SC2086
    output="$(dig $args "$DNS_BENCH_DOMAIN" A +time="$DNS_BENCH_TIMEOUT" +tries=1 2> /dev/null)" || return 1
    printf '%s' "$output" | grep -q 'status: NOERROR' || return 1
    ms="$(printf '%s' "$output" | sed -n 's/^;; Query time: \([0-9]*\) msec.*/\1/p' | sed -n '1p')"
    [ -n "$ms" ] || return 1
    echo "$ms"
}

# Prints "<scheme> <host> <port> <path>" of a server URL, with the default port of
# its scheme; fails for a server that cannot be asked with dig.
dns_bench_entry_target() {
    local entry="$1"
    local scheme rest host port path

    scheme="${entry%%://*}"
    case "$scheme" in
    udp | tcp | dot | doh) ;;
    *) return 1 ;;
    esac
    rest="${entry#*://}"
    path="/${rest#*/}"
    [ "$path" = "/$rest" ] && path=""
    rest="${rest%%/*}"
    host="$(url_get_host "$rest")"
    port="$(url_get_port "$rest")"
    [ -n "$host" ] || return 1
    if [ -z "$port" ]; then
        case "$scheme" in
        udp | tcp) port=53 ;;
        dot) port=853 ;;
        doh) port=443 ;;
        esac
    fi
    case "$port" in
    *[!0-9]*) return 1 ;;
    esac

    echo "$scheme $host $port $path"
}

# The outbound that really carries a section's traffic now: a selector or urltest
# group is followed to the server it has selected (Clash API). $1 - outbound tag,
# $2 - the proxies JSON of the Clash API. Prints the tag, fails when it cannot be told.
dns_bench_leaf_outbound() {
    local tag="$1"
    local proxies="$2"
    local depth=0 type next

    while [ "$depth" -lt 6 ]; do
        type="$(printf '%s' "$proxies" | jq -r --arg tag "$tag" '.proxies[$tag].type // empty' 2> /dev/null)"
        case "$type" in
        Selector | URLTest | Fallback | LoadBalance)
            next="$(printf '%s' "$proxies" | jq -r --arg tag "$tag" '.proxies[$tag].now // empty' 2> /dev/null)"
            [ -n "$next" ] || return 1
            tag="$next"
            ;;
        "") return 1 ;;
        *)
            echo "$tag"
            return 0
            ;;
        esac
        depth=$((depth + 1))
    done
    return 1
}

# The configuration of the short-lived sing-box.
# $1 - sing-box config of the running service, $2 - leaf outbound tag, $3 - bootstrap
# address, $4 - JSON array of {index, port, host, target_port}. Prints the JSON.
dns_bench_tunnel_config() {
    jq -n --slurpfile cfg "$1" --arg leaf "$2" --arg bootstrap "$3" --argjson targets "$4" '
        ($cfg[0].outbounds // []) as $all
        | def chain($tag): ([$all[] | select(.tag == $tag)] | first) as $o
            | if $o == null then error("outbound " + $tag + " is not in the configuration")
              else [$o] + (if (($o.detour // "") != "") then chain($o.detour) else [] end) end;
        {
            log: {level: "error"},
            dns: {servers: [{type: "udp", tag: "bootstrap-dns-server", server: $bootstrap}]},
            inbounds: [$targets[] | {
                type: "direct", tag: ("bench-" + (.index | tostring)),
                listen: "127.0.0.1", listen_port: .port,
                override_address: .host, override_port: .target_port}],
            outbounds: chain($leaf),
            route: ({
                rules: [{inbound: [$targets[] | "bench-" + (.index | tostring)], action: "route", outbound: $leaf}],
                final: $leaf,
                default_domain_resolver: "bootstrap-dns-server"
            } + (($cfg[0].route // {}) | {default_mark, auto_detect_interface, default_interface}
                 | with_entries(select(.value != null))))
        }'
}

# dig arguments for a server reached through its local port. $1 scheme, $2 host, $3 port, $4 path.
dns_bench_tunnel_args() {
    case "$1" in
    udp) echo "@127.0.0.1 -p $3" ;;
    tcp) echo "@127.0.0.1 -p $3 +tcp" ;;
    dot) echo "@127.0.0.1 -p $3 +tls +tls-hostname=$2" ;;
    doh) echo "@127.0.0.1 -p $3 +https=${4:-/dns-query} +tls-hostname=$2" ;;
    esac
}

# Times the given servers (URLs) through the tunnel. Prints "<index> <ms>" lines for the
# ones that answered. Fails (printing nothing) when the tunnel cannot be set up, so the
# caller can fall back to asking from the router.
dns_bench_through_tunnel() {
    local detour="$1"
    local bootstrap="$2"
    shift 2
    local config_file proxies leaf dir index=0 targets="[]" server target pid args pids output ms

    config_file=""
    config_get config_file "settings" "config_path"
    [ -s "$config_file" ] || return 1
    command -v sing-box > /dev/null 2>&1 || return 1

    priority_clash_setup
    proxies="$(priority_fetch_proxies)"
    leaf="$(dns_bench_leaf_outbound "$detour" "$proxies")" || return 1

    dir="$(mktemp -d)" || return 1
    for server in "$@"; do
        index=$((index + 1))
        target="$(dns_bench_entry_target "$server")" || continue
        set -- $target
        targets="$(printf '%s' "$targets" | jq -c --argjson index "$index" --argjson port "$((DNS_BENCH_TUNNEL_PORT_BASE + index))" \
            --arg host "$2" --argjson target_port "$3" '. + [{index: $index, port: $port, host: $host, target_port: $target_port}]')"
        printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$dir/$index.target"
    done
    [ "$targets" != "[]" ] || { rm -rf "$dir"; return 1; }

    dns_bench_tunnel_config "$config_file" "$leaf" "$bootstrap" "$targets" > "$dir/config.json" 2> /dev/null || { rm -rf "$dir"; return 1; }
    sing-box run -c "$dir/config.json" > /dev/null 2>&1 &
    pid=$!
    sleep "$DNS_BENCH_TUNNEL_START_WAIT"
    if ! kill -0 "$pid" 2> /dev/null; then
        rm -rf "$dir"
        return 1
    fi

    pids=""
    for index in $(seq 1 "$DNS_BENCH_MAX_SERVERS"); do
        [ -f "$dir/$index.target" ] || continue
        (
            set -- $(cat "$dir/$index.target")
            args="$(dns_bench_tunnel_args "$1" "$2" "$((DNS_BENCH_TUNNEL_PORT_BASE + index))" "$4")"
            # shellcheck disable=SC2086
            output="$(dig $args "$DNS_BENCH_DOMAIN" A +time="$DNS_BENCH_TIMEOUT" +tries=1 2> /dev/null)" || exit 0
            printf '%s' "$output" | grep -q 'status: NOERROR' || exit 0
            ms="$(printf '%s' "$output" | sed -n 's/^;; Query time: \([0-9]*\) msec.*/\1/p' | sed -n '1p')"
            [ -n "$ms" ] && printf '%s\n' "$ms" > "$dir/$index.ms"
        ) &
        pids="$pids $!"
    done
    # shellcheck disable=SC2086
    wait $pids 2> /dev/null
    kill "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null

    for index in $(seq 1 "$DNS_BENCH_MAX_SERVERS"); do
        [ -s "$dir/$index.ms" ] && printf '%s %s\n' "$index" "$(cat "$dir/$index.ms")"
    done
    rm -rf "$dir"
    return 0
}

# dns_benchmark <server>...: with no arguments, the servers of the settings (the main
# one and the pool). Prints {"results":[{"server","ms"}]} in the order asked.
dns_benchmark() {
    local bootstrap dir server index=0 result="[]" ms dns_type dns_server detour via valid_count=0 line

    config_get bootstrap "settings" "bootstrap_dns_server" "77.88.8.8"

    if [ "$#" -eq 0 ]; then
        config_get dns_type "settings" "dns_type" "udp"
        config_get dns_server "settings" "dns_server" "8.8.8.8"
        set -- "$dns_type://$dns_server"
        DNS_BENCH_POOL=""
        config_list_foreach "settings" "dns_pool_server" _dns_bench_collect_pool
        # shellcheck disable=SC2086
        set -- "$@" $DNS_BENCH_POOL
    fi

    # Only what looks like one server URL goes any further, and no more than the cap.
    # (a stranger's string must not reach the command line as anything but one URL)
    set -- $(for server in "$@"; do
        index=$((index + 1))
        [ "$index" -le "$DNS_BENCH_MAX_SERVERS" ] || break
        case "$server" in
        udp://* | tcp://* | dot://* | doh://* | doh3://* | doq://*) ;;
        *) continue ;;
        esac
        case "$server" in
        *[!A-Za-z0-9:/._@-]*) continue ;;
        esac
        printf '%s\n' "$server"
    done)
    valid_count=$#

    dir="$(mktemp -d)" || return 1

    # The servers of the main DNS are reached through the tunnel when DNS goes through
    # an outbound: from the router itself a resolver inside the tunnel does not exist.
    via="direct"
    detour=""
    if command -v _get_dns_detour_tag > /dev/null 2>&1; then
        detour="$(_get_dns_detour_tag 2> /dev/null)"
    fi
    if [ -n "$detour" ] && [ "$valid_count" -gt 0 ]; then
        if dns_bench_through_tunnel "$detour" "$bootstrap" "$@" > "$dir/tunnel.out" 2> /dev/null; then
            via="tunnel"
            while read -r index ms; do
                printf '%s\n' "$ms" > "$dir/$index.ms"
            done < "$dir/tunnel.out"
        fi
    fi

    if [ "$via" = "direct" ]; then
        index=0
        for server in "$@"; do
            index=$((index + 1))
            (
                ms="$(dns_bench_one "$server" "$bootstrap")" || ms=""
                printf '%s\n' "$ms" > "$dir/$index.ms"
            ) &
        done
        wait
    fi

    index=0
    for server in "$@"; do
        index=$((index + 1))
        ms="$(cat "$dir/$index.ms" 2> /dev/null)"
        case "$ms" in
        '' | *[!0-9]*) ms="" ;;
        esac
        result="$(printf '%s' "$result" | jq -c --arg server "$server" --arg ms "$ms" \
            '. + [{server: $server, ms: (if $ms == "" then null else ($ms | tonumber) end)}]')"
    done
    rm -rf "$dir"

    jq -n -c --argjson results "$result" --arg via "$via" '{via: $via, results: $results}'
}

_dns_bench_collect_pool() {
    DNS_BENCH_POOL="$DNS_BENCH_POOL $1"
}
