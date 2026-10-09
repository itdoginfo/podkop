# shellcheck shell=ash
#
# LAN facts for the Devices page: which subnets are the local network, and the
# static DHCP leases (config host sections of /etc/config/dhcp) with the commands
# to pin or release an address. Static leases are plain dnsmasq host entries, the
# same ones LuCI shows under Network - DHCP and DNS - Static Leases.

# Names of the networks of the "lan" firewall zone; falls back to the networks
# that have a DHCP server, then to "lan".
lan_network_names() {
    local index=0 zone_name networks sid ignored interface found=""

    while uci -q get "firewall.@zone[$index]" > /dev/null 2>&1; do
        zone_name="$(uci -q get "firewall.@zone[$index].name")"
        if [ "$zone_name" = "lan" ]; then
            networks="$(uci -q get "firewall.@zone[$index].network")"
            found="$found $networks"
        fi
        index=$((index + 1))
    done

    if [ -z "$(echo "$found" | tr -d ' ')" ]; then
        for sid in $(uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dhcp$/\1/p'); do
            ignored="$(uci -q get "dhcp.$sid.ignore")"
            [ "$ignored" = "1" ] && continue
            interface="$(uci -q get "dhcp.$sid.interface")"
            [ -n "$interface" ] && found="$found $interface"
        done
    fi

    [ -n "$(echo "$found" | tr -d ' ')" ] || found="lan"
    echo "$found"
}

# IPv4 subnets ("192.168.1.1/24") of one network, one per line.
lan_network_subnets() {
    local network="$1"
    local subnets

    network_get_subnets subnets "$network" 2> /dev/null || return 0
    printf '%s\n' $subnets
}

# Prints the LAN IPv4 subnets as network addresses ("192.168.1.0/24"), one per line.
lan_subnets() {
    local network address prefix

    for network in $(lan_network_names); do
        lan_network_subnets "$network" | while IFS= read -r address; do
            [ -n "$address" ] || continue
            prefix="${address#*/}"
            ipv4_network_address "${address%/*}" "$prefix"
        done
    done | sort -u
}

# "192.168.1.77" 24 -> "192.168.1.0/24"
ipv4_network_address() {
    local ip="$1"
    local prefix="$2"
    local a b c d value mask network

    is_ipv4 "$ip" || return 1
    case "$prefix" in
    '' | *[!0-9]*) return 1 ;;
    esac
    [ "$prefix" -le 32 ] || return 1

    a="${ip%%.*}"
    ip="${ip#*.}"
    b="${ip%%.*}"
    ip="${ip#*.}"
    c="${ip%%.*}"
    d="${ip#*.}"
    value=$(((a << 24) | (b << 16) | (c << 8) | d))
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    fi
    network=$((value & mask))

    printf '%d.%d.%d.%d/%d\n' $(((network >> 24) & 255)) $(((network >> 16) & 255)) $(((network >> 8) & 255)) $((network & 255)) "$prefix"
}

# Is the IPv4 address inside the subnet ("192.168.1.0/24")?
ipv4_in_subnet() {
    local ip="$1"
    local subnet="$2"
    local prefix="${subnet#*/}"

    [ "$(ipv4_network_address "$ip" "$prefix")" = "$subnet" ]
}

# Is the IPv4 address inside one of the LAN subnets?
ip_in_lan() {
    local ip="$1"
    local subnet

    for subnet in $(lan_subnets); do
        ipv4_in_subnet "$ip" "$subnet" && return 0
    done
    return 1
}

# Upper-case colon form of a MAC address; fails for anything else.
normalize_mac() {
    local mac
    mac="$(printf '%s' "$1" | tr 'a-f-' 'A-F:')"

    printf '%s' "$mac" | grep -Eq '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' || return 1
    printf '%s\n' "$mac"
}

# Section ids of the static leases, one per line.
dhcp_host_sections() {
    uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=host$/\1/p'
}

# The section id of the static lease that carries this MAC (empty when none).
dhcp_host_section_of_mac() {
    local mac="$1"
    local sid sid_mac

    for sid in $(dhcp_host_sections); do
        for sid_mac in $(uci -q get "dhcp.$sid.mac" | tr 'a-f' 'A-F'); do
            if [ "$sid_mac" = "$mac" ]; then
                printf '%s\n' "$sid"
                return 0
            fi
        done
    done
    return 1
}

# JSON for the Devices page: the LAN subnets and the static leases.
get_lan_info() {
    local subnets_json hosts_json sid mac ip name

    subnets_json="$(lan_subnets | jq -R -s -c 'split("\n") | map(select(length > 0))')"

    hosts_json="[]"
    for sid in $(dhcp_host_sections); do
        mac="$(uci -q get "dhcp.$sid.mac" | tr 'a-f' 'A-F')"
        ip="$(uci -q get "dhcp.$sid.ip")"
        name="$(uci -q get "dhcp.$sid.name")"
        hosts_json="$(printf '%s' "$hosts_json" | jq -c --arg section "$sid" --arg mac "$mac" --arg ip "$ip" --arg name "$name" \
            '. + [{section: $section, macs: ($mac | split(" ") | map(select(length > 0))), ip: $ip, name: $name}]')"
    done

    jq -n -c --argjson subnets "$subnets_json" --argjson hosts "$hosts_json" '{subnets: $subnets, static_hosts: $hosts}'
}

# Reloads dnsmasq so that a changed static lease is served.
dhcp_reload_dnsmasq() {
    /etc/init.d/dnsmasq reload > /dev/null 2>&1 || true
}

# Pins an address to a MAC: dhcp_host_set <mac> <ip> [name]. Creates or updates
# the static lease (an empty name keeps the current one). Prints {"ok":true} or {"error":"..."}.
dhcp_host_set() {
    local mac ip name sid other other_ip other_name other_macs

    mac="$(normalize_mac "$1")" || {
        jq -n -c '{error: "invalid MAC address"}'
        return 1
    }
    ip="$2"
    name="$3"

    if ! is_ipv4 "$ip"; then
        jq -n -c '{error: "invalid IPv4 address"}'
        return 1
    fi
    if ! ip_in_lan "$ip"; then
        jq -n -c '{error: "the address is outside the local networks"}'
        return 1
    fi
    if [ -n "$name" ]; then
        case "$name" in
        *[!A-Za-z0-9-]* | -* | *-)
            jq -n -c '{error: "invalid host name"}'
            return 1
            ;;
        esac
        [ "${#name}" -le 63 ] || {
            jq -n -c '{error: "invalid host name"}'
            return 1
        }
    fi

    sid="$(dhcp_host_section_of_mac "$mac")"
    for other in $(dhcp_host_sections); do
        [ "$other" = "$sid" ] && continue
        other_ip="$(uci -q get "dhcp.$other.ip")"
        other_name="$(uci -q get "dhcp.$other.name")"
        other_macs="$(uci -q get "dhcp.$other.mac")"
        if [ "$other_ip" = "$ip" ]; then
            jq -n -c --arg mac "$other_macs" '{error: "the address is already given to another device", conflict: $mac}'
            return 1
        fi
        # dnsmasq host names are case-insensitive
        if [ -n "$name" ] && [ "$(printf '%s' "$other_name" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" ]; then
            jq -n -c --arg mac "$other_macs" '{error: "the name is already used by another device", conflict: $mac}'
            return 1
        fi
    done

    if [ -z "$sid" ]; then
        sid="netshift_$(printf '%s' "$mac" | tr -d ':' | tr 'A-F' 'a-f')"
        uci -q set "dhcp.$sid=host"
        uci -q set "dhcp.$sid.mac=$mac"
    fi
    uci -q set "dhcp.$sid.ip=$ip"
    if [ -n "$name" ]; then
        uci -q set "dhcp.$sid.name=$name"
    fi
    uci -q commit dhcp
    dhcp_reload_dnsmasq

    jq -n -c --arg section "$sid" '{ok: true, section: $section}'
}

# Releases the static lease of a MAC. A lease shared by several MACs only loses
# this one.
dhcp_host_remove() {
    local mac sid remaining other_mac

    mac="$(normalize_mac "$1")" || {
        jq -n -c '{error: "invalid MAC address"}'
        return 1
    }
    sid="$(dhcp_host_section_of_mac "$mac")"
    if [ -z "$sid" ]; then
        jq -n -c '{ok: true, removed: false}'
        return 0
    fi

    remaining="$(uci -q get "dhcp.$sid.mac" | tr 'a-f' 'A-F' | tr ' ' '\n' | grep -vxF "$mac" | tr '\n' ' ')"
    if [ -n "$(echo "$remaining" | tr -d ' ')" ]; then
        uci -q delete "dhcp.$sid.mac"
        for other_mac in $remaining; do
            uci -q add_list "dhcp.$sid.mac=$other_mac"
        done
    else
        uci -q delete "dhcp.$sid"
    fi
    uci -q commit dhcp
    dhcp_reload_dnsmasq

    jq -n -c '{ok: true, removed: true}'
}
