# shellcheck shell=ash
#
# DNS forwarding by zone: queries for a zone (".ru") go to a chosen DNS server
# instead of through sing-box, the way `list server '/ru/77.88.8.8'` does in the
# stock dnsmasq config. NetShift moves the dnsmasq `server` list aside while it
# runs, so such entries used to need "Dont Touch My DHCP"; here they are kept in
# the NetShift config (settings.dns_forward) and added to dnsmasq on start.
#
# An entry is "<zone> <server>" (or the dnsmasq form "/<zone>/<server>"); the
# server is an IP address with an optional "#port". A zone covers itself and all
# its subdomains, and the most specific one wins. The answers are real addresses,
# not FakeIP: the names of a forwarded zone are not routed by domain.

# Prints "/<zone>/<server>" for a valid entry, fails for anything else.
dns_forward_normalize() {
    local entry="$1"
    local zone server address port

    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$entry" in
    /*)
        zone="${entry#/}"
        zone="${zone%%/*}"
        server="${entry#/*/}"
        ;;
    *[[:space:]]*)
        zone="${entry%%[[:space:]]*}"
        server="${entry#*[[:space:]]}"
        ;;
    *) return 1 ;;
    esac

    server="$(printf '%s' "$server" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    zone="$(normalize_domain_case "${zone#.}")"
    is_domain "$zone" || return 1

    address="${server%%#*}"
    port=""
    case "$server" in
    *"#"*) port="${server#*#}" ;;
    esac
    if [ -n "$port" ]; then
        case "$port" in
        *[!0-9]*) return 1 ;;
        esac
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    fi

    case "$address" in
    *.*.*.*) is_ipv4 "$address" || return 1 ;;
    *:*) is_ipv6 "$address" || return 1 ;;
    *) return 1 ;;
    esac
    [ "$address" = "$SB_DNS_INBOUND_ADDRESS" ] && return 1

    printf '/%s/%s\n' "$zone" "$server"
}

_dns_forward_collect_handler() {
    local entry="$1"
    local normalized

    if normalized="$(dns_forward_normalize "$entry")"; then
        printf '%s\n' "$normalized"
    else
        log "DNS forward '$entry' is invalid, skipping" "warn"
    fi
}

# The valid entries of the config in dnsmasq form, one per line, duplicates dropped.
dns_forward_entries() {
    netshift_config_list_foreach "settings" "dns_forward" _dns_forward_collect_handler | awk '!seen[$0]++'
}

# Is the domain inside the zone (equal to it or its subdomain)?
dns_forward_zone_covers() {
    local zone="$1"
    local domain="$2"

    case "$domain" in
    "$zone" | *".$zone") return 0 ;;
    esac
    return 1
}

_dns_forward_overlap_domain_handler() {
    local domain zone

    domain="$(normalize_domain_case "${1#.}")"
    domain="${domain#full:}"
    [ -n "$domain" ] || return 0

    for zone in $DNS_FORWARD_ZONES; do
        if dns_forward_zone_covers "$zone" "$domain"; then
            log "Domain '$domain' of a section is inside the DNS forward zone '$zone': its queries bypass sing-box, so the domain is not routed by name" "warn"
        fi
    done
}

_dns_forward_overlap_section() {
    netshift_config_list_foreach "$1" "user_domains" _dns_forward_overlap_domain_handler
}

# Warns about the domains typed into the sections that a forwarded zone swallows.
dns_forward_warn_overlaps() {
    DNS_FORWARD_ZONES="$(dns_forward_entries | sed 's|^/\([^/]*\)/.*|\1|' | tr '\n' ' ')"
    [ -n "$(printf '%s' "$DNS_FORWARD_ZONES" | tr -d ' ')" ] || return 0

    config_foreach _dns_forward_overlap_section "section"
}

# Adds the forwards to the dnsmasq server list (called while dnsmasq is being
# configured; the caller commits and restarts).
dns_forward_apply() {
    local entry count=0

    for entry in $(dns_forward_entries); do
        uci_add_list "dhcp" "@dnsmasq[0]" "server" "$entry"
        count=$((count + 1))
    done

    [ "$count" -eq 0 ] || log "Added $count DNS forward(s) by zone to dnsmasq"
    dns_forward_warn_overlaps
}
