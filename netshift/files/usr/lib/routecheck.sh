# shellcheck shell=ash
#
# "Where will a request go": replays the routing rules of the generated sing-box
# configuration for one domain or IP address and says which section (or the
# direct path, or a block) takes it, and which DNS server answers it.
#
# Domain/IP matching is delegated to the core itself (`sing-box rule-set match`),
# so every kind of condition the core knows (suffix, full, keyword, regex, CIDR,
# binary and source rule sets) behaves exactly as at run time. Conditions that
# depend on live traffic (protocol sniffing, ports, process names...) cannot be
# replayed: a rule that has one is skipped and the result is flagged incomplete.

ROUTE_CHECK_CACHE_FOLDER="/tmp/netshift-route-check"

# Prints "match" status for one target against a rule-set file:
#   $1 - rule-set path, $2 - format (source|binary), $3 - target (domain or IP)
route_check_rule_set_hit() {
    local path="$1"
    local format="$2"
    local target="$3"

    sing-box rule-set match -f "$format" "$path" "$target" 2>&1 | grep -q '^match'
}

# Resolves a rule-set tag of the configuration to a local file the core can read.
# Local rule sets are used in place; remote ones are downloaded once into a cache
# (the core keeps its own copy in a database that cannot be read from outside).
# Prints "<path> <format>"; non-zero when the file is not available.
route_check_rule_set_file() {
    local config_file="$1"
    local tag="$2"
    local entry type format path url proxy cache_file tmp_file

    entry="$(jq -c --arg tag "$tag" '[.route.rule_set[]? | select(.tag == $tag)] | first // empty' "$config_file")"
    [ -n "$entry" ] || return 1

    type="$(printf '%s' "$entry" | jq -r '.type // "local"')"
    format="$(printf '%s' "$entry" | jq -r '.format // "source"')"
    case "$type" in
    local)
        path="$(printf '%s' "$entry" | jq -r '.path // empty')"
        [ -n "$path" ] && [ -s "$path" ] || return 1
        printf '%s %s\n' "$path" "$format"
        ;;
    remote)
        url="$(printf '%s' "$entry" | jq -r '.url // empty')"
        [ -n "$url" ] || return 1
        mkdir -p "$ROUTE_CHECK_CACHE_FOLDER"
        cache_file="$ROUTE_CHECK_CACHE_FOLDER/$(printf '%s' "$url" | md5sum | cut -d' ' -f1).$format"
        if [ ! -s "$cache_file" ]; then
            proxy="$(get_service_proxy_address)"
            # Downloaded next to the cache file and moved into place: two checks at once never
            # read a half-written file, an interrupted download leaves nothing that looks like
            # a cache, and a failed run cannot remove the file another run has just stored.
            # One attempt: the request is interactive.
            tmp_file="$cache_file.dl.$$"
            if download_to_file "$url" "$tmp_file" "$proxy" 1 1 15 > /dev/null 2>&1 && [ -s "$tmp_file" ]; then
                mv "$tmp_file" "$cache_file"
            else
                rm -f "$tmp_file"
                return 1
            fi
        fi
        [ -s "$cache_file" ] || return 1
        printf '%s %s\n' "$cache_file" "$format"
        ;;
    *) return 1 ;;
    esac
}

# Does the rule match? Prints nothing; exit status: 0 match, 1 no match,
# 2 the rule has a condition that cannot be replayed.
#   $1 - config file, $2 - rule (JSON), $3 - target, $4 - target kind (domain|ip),
#   $5 - source address (may be empty), $6 - inbound tag the traffic arrives on
route_check_rule_hit() {
    local config_file="$1"
    local rule="$2"
    local target="$3"
    local kind="$4"
    local source_ip="$5"
    local inbound="$6"
    local unknown inline probe tag file format
    local rc_set

    # Conditions that are replayed here. Everything else on a rule makes it unknown.
    unknown="$(printf '%s' "$rule" | jq -r --arg service_tag "$SERVICE_TAG" '
        keys - ["action", "outbound", "server", "tag", "method", "timeout", "strategy", "rewrite_ttl",
                "disable_cache", "client_subnet", "inbound", "domain", "domain_suffix", "domain_keyword",
                "domain_regex", "ip_cidr", "rule_set", "query_type", "source_ip_cidr", "invert", $service_tag]
        | join(",")')"
    [ -z "$unknown" ] || return 2
    [ "$(printf '%s' "$rule" | jq -r '.invert // false')" = "false" ] || return 2

    # inbound: only the transparent-proxy inbounds carry LAN traffic
    if [ "$(printf '%s' "$rule" | jq -r 'has("inbound")')" = "true" ]; then
        printf '%s' "$rule" | jq -e --arg inbound "$inbound" '
            .inbound | (if type == "array" then . else [.] end) | index($inbound) != null' > /dev/null || return 1
    fi

    # query_type: the check asks for an address (A)
    if [ "$(printf '%s' "$rule" | jq -r 'has("query_type")')" = "true" ]; then
        printf '%s' "$rule" | jq -e '.query_type | (if type == "array" then . else [.] end)
            | any(. == "A" or . == 1 or . == "a")' > /dev/null || return 1
    fi

    # source addresses
    if [ "$(printf '%s' "$rule" | jq -r 'has("source_ip_cidr")')" = "true" ]; then
        [ -n "$source_ip" ] || return 2
        probe="$(mktemp)"
        printf '%s' "$rule" | jq '{version: 3, rules: [{ip_cidr: (.source_ip_cidr | if type == "array" then . else [.] end)}]}' > "$probe"
        route_check_rule_set_hit "$probe" source "$source_ip" || {
            rm -f "$probe"
            return 1
        }
        rm -f "$probe"
    fi

    # destination conditions of the rule itself
    inline="$(printf '%s' "$rule" | jq -c '{domain, domain_suffix, domain_keyword, domain_regex, ip_cidr} | with_entries(select(.value != null))')"
    if [ "$inline" != "{}" ]; then
        probe="$(mktemp)"
        printf '%s' "$inline" | jq '{version: 3, rules: [with_entries(.value |= (if type == "array" then . else [.] end))]}' > "$probe"
        if ! route_check_rule_set_hit "$probe" source "$target"; then
            rm -f "$probe"
            return 1
        fi
        rm -f "$probe"
    fi

    # rule sets: any of them
    if [ "$(printf '%s' "$rule" | jq -r 'has("rule_set")')" = "true" ]; then
        rc_set=1
        for tag in $(printf '%s' "$rule" | jq -r '.rule_set | (if type == "array" then . else [.] end)[]'); do
            if ! file="$(route_check_rule_set_file "$config_file" "$tag")"; then
                rc_set=2
                continue
            fi
            format="${file#* }"
            file="${file% *}"
            if route_check_rule_set_hit "$file" "$format" "$target"; then
                ROUTE_CHECK_MATCHED_SET="$tag"
                return 0
            fi
        done
        return $rc_set
    fi

    # no destination condition at all: the rule is a catch-all for this inbound
    return 0
}

# Finds the section a sing-box outbound tag belongs to (section ids prefix their
# outbound tags: "<section>-out", "<section>-urltest-out", "<section>-2-out"...).
route_check_section_of_outbound() {
    local outbound="$1"
    local best=""

    _route_check_section_probe() {
        case "$outbound" in
        "$1"-*) [ "${#1}" -gt "${#best}" ] && best="$1" ;;
        esac
    }
    config_foreach _route_check_section_probe "section"
    printf '%s' "$best"
}

# $1 - domain or IP address, $2 - source address of the client (optional).
# Prints one JSON object.
check_route() {
    local target source_ip kind config_path_value config_file inbound
    local rules rule index count rc verdict outbound section action rule_tag matched_set
    local incomplete skipped dns_server dns_rule dns_verdict dns_rules dns_index dns_count notes
    local final proxy_final snapshot_file

    target="$(normalize_domain_case "$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")"
    source_ip="$2"

    if [ -z "$target" ]; then
        jq -n '{error: "empty target"}'
        return 1
    fi
    if is_ipv4 "$target" || is_ipv6 "$target"; then
        kind="ip"
    elif is_domain "$target"; then
        kind="domain"
    else
        jq -n --arg target "$target" '{error: "not a domain or an IP address", target: $target}'
        return 1
    fi
    if [ -n "$source_ip" ] && ! is_ipv4 "$source_ip" && ! is_ipv6 "$source_ip"; then
        jq -n --arg source "$source_ip" '{error: "the source is not an IP address", source: $source}'
        return 1
    fi

    config_get config_path_value "settings" "config_path"
    config_file="$config_path_value"
    if [ ! -s "$config_file" ] || ! command -v sing-box > /dev/null 2>&1; then
        jq -n --arg target "$target" '{error: "sing-box configuration is not available (is the service started?)", target: $target}'
        return 1
    fi

    # One generation of the rules for the whole answer: a rebuild of the configuration
    # while the check runs must not mix two generations into one verdict.
    snapshot_file="$(mktemp)" || snapshot_file=""
    if [ -n "$snapshot_file" ] && cp "$config_file" "$snapshot_file" 2> /dev/null && [ -s "$snapshot_file" ]; then
        config_file="$snapshot_file"
    fi

    inbound="$SB_TPROXY_INBOUND_TAG"
    incomplete=false
    skipped=""
    ROUTE_CHECK_MATCHED_SET=""

    # DNS: which server answers the name
    dns_server=""
    dns_verdict="final"
    if [ "$kind" = "domain" ]; then
        dns_count="$(jq '[.dns.rules[]?] | length' "$config_file")"
        dns_index=0
        while [ "$dns_index" -lt "$dns_count" ]; do
            dns_rule="$(jq -c --argjson i "$dns_index" '.dns.rules[$i]' "$config_file")"
            dns_index=$((dns_index + 1))
            action="$(printf '%s' "$dns_rule" | jq -r '.action // "route"')"
            case "$action" in
            route | reject | predefined) ;;
            *) continue ;;
            esac
            # DNS rules do not look at the inbound of the connection
            ROUTE_CHECK_MATCHED_SET=""
            route_check_rule_hit "$config_file" "$(printf '%s' "$dns_rule" | jq -c 'del(.inbound)')" "$target" domain "" "$inbound"
            rc=$?
            if [ "$rc" -eq 2 ]; then
                incomplete=true
                continue
            fi
            [ "$rc" -eq 0 ] || continue
            if [ "$action" = "reject" ]; then
                dns_verdict="blocked"
                dns_server=""
            else
                dns_server="$(printf '%s' "$dns_rule" | jq -r '.server // empty')"
                dns_verdict="rule"
            fi
            break
        done
        if [ "$dns_verdict" = "final" ]; then
            dns_server="$(jq -r '.dns.final // empty' "$config_file")"
        fi
    fi

    # Routing: first rule that ends in a route/reject/direct action
    verdict="unmatched"
    outbound=""
    rule_tag=""
    count="$(jq '[.route.rules[]?] | length' "$config_file")"
    index=0
    while [ "$index" -lt "$count" ]; do
        rule="$(jq -c --argjson i "$index" '.route.rules[$i]' "$config_file")"
        index=$((index + 1))
        action="$(printf '%s' "$rule" | jq -r '.action // "route"')"
        case "$action" in
        route | reject | direct | route-options) ;;
        *) continue ;;
        esac
        [ "$action" = "route-options" ] && continue
        ROUTE_CHECK_MATCHED_SET=""
        route_check_rule_hit "$config_file" "$rule" "$target" "$kind" "$source_ip" "$inbound"
        rc=$?
        if [ "$rc" -eq 2 ]; then
            incomplete=true
            skipped="$skipped $(printf '%s' "$rule" | jq -r --arg key "$SERVICE_TAG" '.[$key] // "rule"')"
            continue
        fi
        [ "$rc" -eq 0 ] || continue

        rule_tag="$(printf '%s' "$rule" | jq -r --arg key "$SERVICE_TAG" '.[$key] // empty')"
        matched_set="$ROUTE_CHECK_MATCHED_SET"
        if [ "$action" = "reject" ]; then
            verdict="blocked"
        else
            outbound="$(printf '%s' "$rule" | jq -r '.outbound // empty')"
            if [ "$outbound" = "$SB_DIRECT_OUTBOUND_TAG" ]; then
                verdict="direct"
            else
                verdict="section"
            fi
        fi
        break
    done

    if [ "$verdict" = "unmatched" ]; then
        final="$(jq -r '.route.final // empty' "$config_file")"
        outbound="$final"
        if [ -z "$final" ] || [ "$final" = "$SB_DIRECT_OUTBOUND_TAG" ]; then
            verdict="direct"
        else
            verdict="section"
            proxy_final=true
        fi
    fi

    section=""
    if [ "$verdict" = "section" ]; then
        section="$(route_check_section_of_outbound "$outbound")"
    fi

    [ -z "$snapshot_file" ] || rm -f "$snapshot_file"

    jq -n \
        --arg target "$target" \
        --arg kind "$kind" \
        --arg source "$source_ip" \
        --arg verdict "$verdict" \
        --arg outbound "$outbound" \
        --arg section "$section" \
        --arg rule "$rule_tag" \
        --arg rule_set "$matched_set" \
        --arg dns_server "$dns_server" \
        --arg dns_verdict "$dns_verdict" \
        --argjson incomplete "$incomplete" \
        --argjson final "${proxy_final:-false}" \
        --arg skipped "$skipped" \
        '{
            target: $target,
            kind: $kind,
            source: (if $source == "" then null else $source end),
            verdict: $verdict,
            outbound: (if $outbound == "" then null else $outbound end),
            section: (if $section == "" then null else $section end),
            rule: (if $rule == "" then null else $rule end),
            rule_set: (if $rule_set == "" then null else $rule_set end),
            by_default: $final,
            dns: (if $kind == "domain" then {
                server: (if $dns_server == "" then null else $dns_server end),
                verdict: $dns_verdict
            } else null end),
            incomplete: $incomplete,
            skipped_rules: ($skipped | split(" ") | map(select(length > 0)))
        }'
}
