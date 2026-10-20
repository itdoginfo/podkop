# shellcheck shell=ash
#
# DNS server benchmark: how fast each upstream answers from THIS router (the answer
# depends on the provider and the route, not on a table of "best" servers). Every
# server is asked one question with dig, all at the same time, so the whole run takes
# about as long as the slowest one (DNS_BENCH_TIMEOUT seconds at most). The result is
# a list of milliseconds, null for a server that did not answer or cannot be tested
# with dig (doh3, doq). Nothing is changed.
#
# A server whose route goes through a proxy/VPN section (its own entry of dns_server_route, or
# the global "Route main DNS through proxy/VPN" switch) is not reached from the router but from
# the exit of the tunnel (a resolver inside the tunnel, such as 172.31.x.x, does not exist for
# the router at all). The servers are grouped by the outbound they go through, and for each
# group a short-lived extra sing-box is started: it carries one local "direct" inbound per
# server, each forwarding to that server through that outbound, and dig asks those local ports.
# The measurement therefore includes the tunnel, as it does for real queries.

DNS_BENCH_TIMEOUT=3
DNS_BENCH_DOMAIN="google.com"
DNS_BENCH_MAX_SERVERS=12
DNS_BENCH_TUNNEL_PORT_BASE=19200
DNS_BENCH_TUNNEL_START_WAIT=2
# The groups are timed at the same time, each on its own window of DNS_BENCH_MAX_SERVERS local
# ports. The windows stop short of the NaiveProxy sidecars (NAIVE_PORT_BASE and up), so their
# number follows from the constants: 8 windows fill 19201-19296 for the default 19300. A route
# section beyond that is timed from the router (and says so: via "direct").
DNS_BENCH_MAX_GROUPS=$(((${NAIVE_PORT_BASE:-19300} - DNS_BENCH_TUNNEL_PORT_BASE) / DNS_BENCH_MAX_SERVERS))
# At most this many extra sing-box processes run at once: a router with 128 MB cannot carry
# eight of them, and the page starts this test every time it is opened.
DNS_BENCH_PARALLEL_GROUPS=3
# Local ports of one group of servers start at DNS_BENCH_TUNNEL_PORT_BASE + DNS_BENCH_PORT_OFFSET,
# so that groups timed at the same time (one sing-box each) never share a port.
DNS_BENCH_PORT_OFFSET=0
# One run at a time: two runs share the local ports, and the one that loses is timed from the
# router and mislabelled. A second caller waits (at most DNS_BENCH_LOCK_WAIT seconds) for the
# first; a lock whose owner is gone is taken over.
DNS_BENCH_LOCK="/tmp/netshift-dnsbench.lock"
# (the page waits for the answer for about as long as rpcd lets a call live, 30 seconds)
DNS_BENCH_LOCK_WAIT=20

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
        targets="$(printf '%s' "$targets" | jq -c --argjson index "$index" --argjson port "$((DNS_BENCH_TUNNEL_PORT_BASE + DNS_BENCH_PORT_OFFSET + index))" \
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
            args="$(dns_bench_tunnel_args "$1" "$2" "$((DNS_BENCH_TUNNEL_PORT_BASE + DNS_BENCH_PORT_OFFSET + index))" "$4")"
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

# 0 when this process holds the lock now.
dns_bench_lock_acquire() {
    local waited=0 owner stale

    while :; do
        if mkdir "$DNS_BENCH_LOCK" 2> /dev/null; then
            echo "$$" > "$DNS_BENCH_LOCK/pid"
            return 0
        fi
        owner="$(cat "$DNS_BENCH_LOCK/pid" 2> /dev/null)"
        if [ -z "$owner" ]; then
            # the directory exists, but its owner has not written its pid yet (or is gone):
            # give it a moment before it is taken for abandoned
            sleep 1
            owner="$(cat "$DNS_BENCH_LOCK/pid" 2> /dev/null)"
        fi
        if [ -z "$owner" ] || ! kill -0 "$owner" 2> /dev/null; then
            # Nobody holds it any more. It is taken away by a rename, which only one of the
            # callers that find it abandoned can win; and what was moved is looked at again:
            # it may be the fresh lock of a caller that was quicker.
            stale="$DNS_BENCH_LOCK.stale.$$"
            if mv "$DNS_BENCH_LOCK" "$stale" 2> /dev/null; then
                owner="$(cat "$stale/pid" 2> /dev/null)"
                if [ -n "$owner" ] && kill -0 "$owner" 2> /dev/null; then
                    # a live owner after all: it keeps the lock (it is put back when nobody has
                    # made a new one meanwhile) and this caller waits like the others
                    [ -e "$DNS_BENCH_LOCK" ] || mv "$stale" "$DNS_BENCH_LOCK" 2> /dev/null
                fi
                rm -rf "$stale"
            fi
            continue
        fi
        [ "$waited" -lt "$DNS_BENCH_LOCK_WAIT" ] || return 1
        sleep 1
        waited=$((waited + 1))
    done
}

dns_bench_lock_release() {
    rm -rf "$DNS_BENCH_LOCK"
}

# dns_benchmark <server>...: one run at a time (see DNS_BENCH_LOCK). A run that could not get the
# lock in time goes on without it rather than answer nothing.
dns_benchmark() {
    local held=0 rc

    dns_bench_lock_acquire && held=1
    _dns_benchmark_run "$@"
    rc=$?
    [ "$held" -eq 0 ] || dns_bench_lock_release
    return "$rc"
}

# the run itself: with no arguments, the servers of the settings (the main
# one and the pool). Prints {"results":[{"server","ms"}]} in the order asked.
_dns_benchmark_run() {
    local bootstrap dir server index=0 result="[]" ms dns_type dns_server via valid_count=0 line
    local tag tunnel_servers tunnel_positions tunnel_done tunnel_count position group n

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

    # A server that goes through the tunnel (the global switch, or its own entry in
    # dns_server_route) is timed through it: from the router itself a resolver inside
    # the tunnel does not exist. The others are asked from the router. Servers that go
    # through DIFFERENT outbounds (via:<section> of different sections) are timed in
    # groups, one short-lived sing-box per outbound, so that each is measured by its own way.
    : > "$dir/tunnel.map"
    if command -v dns_routes_init > /dev/null 2>&1; then
        dns_routes_init
        index=0
        for server in "$@"; do
            index=$((index + 1))
            tag="$(dns_server_detour_tag "$server")"
            [ -n "$tag" ] || continue
            printf '%s\t%s\t%s\n' "$index" "$tag" "$server" >> "$dir/tunnel.map"
        done
    fi

    # The groups are timed at the same time, each by its own short-lived sing-box on its own
    # range of local ports, and together with the servers asked from the router: the whole
    # run takes about as long as one group (an rpcd call lives about 30 seconds, and with
    # one group after another a handful of sections would not fit).
    tunnel_done=""
    group=0
    if [ -s "$dir/tunnel.map" ] && [ "$valid_count" -gt 0 ]; then
        cut -f2 "$dir/tunnel.map" | awk '!seen[$0]++' > "$dir/tunnel.tags"
        while IFS= read -r tag; do
            if [ "$group" -ge "$DNS_BENCH_MAX_GROUPS" ]; then
                log "DNS benchmark: more than $DNS_BENCH_MAX_GROUPS routes through different sections; the servers of '$tag' are timed from the router" "warn"
                continue
            fi
            group=$((group + 1))
            tunnel_servers=""
            tunnel_positions=""
            while IFS="$(printf '\t')" read -r position row_tag server; do
                [ "$row_tag" = "$tag" ] || continue
                tunnel_servers="$tunnel_servers $server"
                tunnel_positions="$tunnel_positions $position"
            done < "$dir/tunnel.map"
            (
                DNS_BENCH_PORT_OFFSET=$(((group - 1) * DNS_BENCH_MAX_SERVERS))
                # shellcheck disable=SC2086
                dns_bench_through_tunnel "$tag" "$bootstrap" $tunnel_servers > "$dir/g$group.out" 2> /dev/null < /dev/null || exit 0
                while read -r index ms; do
                    position="$(printf '%s\n' $tunnel_positions | sed -n "${index}p")"
                    [ -n "$position" ] || continue
                    printf '%s\n' "$ms" > "$dir/$position.ms"
                done < "$dir/g$group.out"
                printf '%s\n' "$tunnel_positions" > "$dir/g$group.done"
            ) &
            tunnel_done="$tunnel_done $tunnel_positions"
            # a full batch of extra sing-box processes finishes before the next one starts
            [ $((group % DNS_BENCH_PARALLEL_GROUPS)) -ne 0 ] || wait
        done < "$dir/tunnel.tags"
    fi

    # The servers that go through a tunnel are measured by their group: a group that could not
    # be set up leaves them to be asked from the router below.
    index=0
    for server in "$@"; do
        index=$((index + 1))
        case " $tunnel_done " in
        *" $index "*) continue ;;
        esac
        (
            ms="$(dns_bench_one "$server" "$bootstrap")" || ms=""
            printf '%s\n' "$ms" > "$dir/$index.ms"
        ) &
    done
    wait

    # A group that did not set up its tunnel has no .done file: its servers are asked from the
    # router now (the answer says via "direct" for them, as before).
    tunnel_done=""
    n=0
    while [ "$n" -lt "$group" ]; do
        n=$((n + 1))
        [ -f "$dir/g$n.done" ] && tunnel_done="$tunnel_done $(cat "$dir/g$n.done")"
    done
    index=0
    for server in "$@"; do
        index=$((index + 1))
        case " $tunnel_done " in
        *" $index "*) continue ;;
        esac
        [ -f "$dir/$index.ms" ] && continue
        (
            ms="$(dns_bench_one "$server" "$bootstrap")" || ms=""
            printf '%s\n' "$ms" > "$dir/$index.ms"
        ) &
    done
    wait

    index=0
    tunnel_count=0
    for server in "$@"; do
        index=$((index + 1))
        ms="$(cat "$dir/$index.ms" 2> /dev/null)"
        case "$ms" in
        '' | *[!0-9]*) ms="" ;;
        esac
        via="direct"
        case " $tunnel_done " in
        *" $index "*)
            via="tunnel"
            tunnel_count=$((tunnel_count + 1))
            ;;
        esac
        result="$(printf '%s' "$result" | jq -c --arg server "$server" --arg ms "$ms" --arg via "$via" \
            '. + [{server: $server, ms: (if $ms == "" then null else ($ms | tonumber) end), via: $via}]')"
    done
    rm -rf "$dir"

    if [ "$tunnel_count" -eq 0 ]; then
        via="direct"
    elif [ "$tunnel_count" -eq "$valid_count" ]; then
        via="tunnel"
    else
        via="mixed"
    fi

    jq -n -c --argjson results "$result" --arg via "$via" '{via: $via, results: $results}'
}

_dns_bench_collect_pool() {
    DNS_BENCH_POOL="$DNS_BENCH_POOL $1"
}
