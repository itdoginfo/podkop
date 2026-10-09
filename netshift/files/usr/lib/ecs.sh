# shellcheck shell=ash
#
# Automatic EDNS Client Subnet (ECS): the subnet sent with DNS queries is taken
# from a WAN interface of the router instead of being typed by hand.
#
# A public address on the interface is used as it is. When the interface has a
# private or carrier-grade NAT address, the address the internet sees is looked
# up once through that interface and remembered together with the local address
# it was seen for: it is asked again only when the local address changes.
# IPv4 only: the subnet is the /24 of the address, the usual ECS granularity.

ECS_CACHE_FILE="$NETSHIFT_STATE_DIR/ecs-external.json"
ECS_EXTERNAL_IP_URLS="https://api.country.is https://api.ipify.org?format=json"
ECS_EXTERNAL_IP_TIMEOUT=5

# WAN interface names, the one that carries the default route first.
ecs_wan_interfaces() {
    local default_wan="" index=0 zone_name networks seen=""

    network_find_wan default_wan 2> /dev/null
    [ -n "$default_wan" ] && seen="$default_wan"

    while uci -q get "firewall.@zone[$index]" > /dev/null 2>&1; do
        zone_name="$(uci -q get "firewall.@zone[$index].name")"
        if [ "$zone_name" = "wan" ]; then
            networks="$(uci -q get "firewall.@zone[$index].network")"
            for network in $networks; do
                case " $seen " in
                *" $network "*) ;;
                *) seen="$seen $network" ;;
                esac
            done
        fi
        index=$((index + 1))
    done

    # IPv6-only twins of the same WAN ("wan6") have no IPv4 address: harmless, skipped later
    printf '%s\n' $seen
}

# Prints "<device> <ipv4>" of an interface that is up and has an IPv4 address.
ecs_interface_address() {
    local interface="$1"
    local address device

    network_get_ipaddr address "$interface" 2> /dev/null
    [ -n "$address" ] || return 1
    network_get_device device "$interface" 2> /dev/null
    printf '%s %s\n' "$device" "$address"
}

# "203.0.113.57" -> "203.0.113.0/24"
ecs_subnet_of() {
    local ip="$1"

    is_ipv4 "$ip" || return 1
    printf '%s.0/24\n' "${ip%.*}"
}

# The address the internet sees for traffic leaving through a device.
ecs_fetch_external_ip() {
    local device="$1"
    local url body ip

    for url in $ECS_EXTERNAL_IP_URLS; do
        if [ -n "$device" ]; then
            body="$(curl -s -m "$ECS_EXTERNAL_IP_TIMEOUT" --interface "$device" "$url" 2> /dev/null)"
        else
            body="$(curl -s -m "$ECS_EXTERNAL_IP_TIMEOUT" "$url" 2> /dev/null)"
        fi
        ip="$(printf '%s' "$body" | jq -r '.ip // empty' 2> /dev/null)"
        if [ -n "$ip" ] && is_ipv4 "$ip" && ! geoip_is_private_ip "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

# The external address of an interface with a private address, from the cache or
# (once) from the internet. $1 interface, $2 device, $3 local address.
ecs_external_ip() {
    local interface="$1"
    local device="$2"
    local local_address="$3"
    local key="$interface|$local_address"
    local cached external

    cached="$(jq -r --arg key "$key" '.[$key] // empty' "$ECS_CACHE_FILE" 2> /dev/null)"
    if [ -n "$cached" ]; then
        printf '%s\n' "$cached"
        return 0
    fi

    external="$(ecs_fetch_external_ip "$device")" || return 1

    # keep one entry per interface: a changed local address replaces the old one
    # the file holds the public address of the router: private from the first byte
    mkdir -p "$(dirname "$ECS_CACHE_FILE")" 2> /dev/null
    (
        umask 077
        {
            jq -c --arg interface "$interface" --arg key "$key" --arg external "$external" \
                '(. // {}) | with_entries(select(.key | startswith($interface + "|") | not)) | .[$key] = $external' \
                "$ECS_CACHE_FILE" 2> /dev/null || jq -n -c --arg key "$key" --arg external "$external" '{($key): $external}'
        } > "$ECS_CACHE_FILE.tmp"
    ) && mv "$ECS_CACHE_FILE.tmp" "$ECS_CACHE_FILE"

    printf '%s\n' "$external"
}

# One JSON object per usable WAN interface:
# {interface, device, address, public, external, subnet}
# external is the address the internet sees (the address itself when public).
# $1 - only this interface (empty: all), $2 - "first": stop at the first usable one,
# so that no lookup is made for interfaces that are not going to be used.
ecs_collect_json() {
    local wanted="$1"
    local first_only="$2"
    local interface line device address public external subnet result="[]"

    for interface in $(ecs_wan_interfaces); do
        [ -z "$wanted" ] || [ "$interface" = "$wanted" ] || continue
        line="$(ecs_interface_address "$interface")" || continue
        device="${line% *}"
        address="${line#* }"

        if geoip_is_private_ip "$address"; then
            public=false
            external="$(ecs_external_ip "$interface" "$device" "$address")" || external=""
        else
            public=true
            external="$address"
        fi

        subnet=""
        [ -n "$external" ] && subnet="$(ecs_subnet_of "$external")"

        result="$(printf '%s' "$result" | jq -c \
            --arg interface "$interface" --arg device "$device" --arg address "$address" \
            --argjson public "$public" --arg external "$external" --arg subnet "$subnet" \
            '. + [{interface: $interface, device: $device, address: $address, public: $public,
                   external: (if $external == "" then null else $external end),
                   subnet: (if $subnet == "" then null else $subnet end)}]')"

        [ "$first_only" = "first" ] && [ -n "$subnet" ] && break
    done

    printf '%s\n' "$result"
}

# JSON for the settings page.
get_wan_addresses() {
    jq -n -c --argjson interfaces "$(ecs_collect_json)" '{interfaces: $interfaces}'
}

# The subnet to send as ECS: from the chosen interface, or from the first one that
# yields an address. Prints nothing when none does.
# $1 - interface name or empty for "the first that works"
ecs_resolve_auto() {
    local wanted="$1"

    ecs_collect_json "$wanted" first | jq -r '[.[] | select(.subnet != null)] | first | .subnet // empty'
}
