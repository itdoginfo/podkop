# shellcheck shell=ash
#
# The answers the LuCI pages ask for over and over - the log every 3 seconds, the state of the
# service, what the core can do on every visit - that need none of the other libraries. Loading
# them all costs more than the answer itself (about 0.3 s per call on a slow router), so
# /usr/bin/netshift answers these before it loads anything else (see netshift_quick). The
# functions are the same ones the full command line uses.

get_status() {
    local enabled=0
    local status=""

    # Check if service is enabled
    if [ -x /etc/rc.d/S99netshift ]; then
        enabled=1
        status="enabled"
    else
        status="disabled"
    fi

    echo "{\"enabled\":$enabled,\"status\":\"$status\"}"
}

get_sing_box_status() {
    local running=0
    local enabled=0
    local status=""
    local version=""
    local dns_configured=0

    # Check if service is enabled
    if [ -x /etc/rc.d/S99sing-box ]; then
        enabled=1
    fi

    # Check if service is running
    if pgrep -f "sing-box" > /dev/null; then
        running=1
        version=$(sing-box version | head -n 1 | awk '{print $3}')
    fi

    # Check DNS configuration
    local dns_server
    dns_server=$(uci get dhcp.@dnsmasq[0].server 2> /dev/null)
    if [ "$dns_server" = "127.0.0.42" ]; then
        dns_configured=1
    fi

    # Format status message
    if [ $running -eq 1 ]; then
        if [ $enabled -eq 1 ]; then
            status="running & enabled"
        else
            status="running but disabled"
        fi
    else
        if [ $enabled -eq 1 ]; then
            status="stopped but enabled"
        else
            status="stopped & disabled"
        fi
    fi

    echo "{\"running\":$running,\"enabled\":$enabled,\"status\":\"$status\",\"dns_configured\":$dns_configured}"
}

check_logs() {
    if ! command -v logread > /dev/null 2>&1; then
        nolog "Error: logread command not found"
        return 1
    fi

    local logs
    logs=$(logread | grep -E "netshift|sing-box")

    if [ -z "$logs" ]; then
        nolog "Logs not found"
        return 1
    fi

    # Find the last occurrence of "Starting netshift"
    local start_line
    start_line=$(echo "$logs" | grep -n "netshift.*Starting netshift" | tail -n 1 | cut -d: -f1)

    if [ -n "$start_line" ]; then
        echo "$logs" | tail -n +"$start_line"
    else
        nolog "No 'Starting netshift' message found, showing last 100 lines"
        echo "$logs" | tail -n 100
    fi
}

# A fingerprint of the installed cores: the size and the time of every file the answer of
# get_core_capabilities depends on (the sing-box binary or its lite wrapper and core, the
# naive client). Another core, an update or a removal changes it.
core_capabilities_key() {
    ls -lnL /usr/bin/sing-box "$UPDATES_SING_BOX_LITE_CORE_BIN" "${NAIVE_BIN:-/usr/bin/naive}" \
        /usr/bin/naive /usr/bin/naiveproxy /opt/bin/naive 2> /dev/null | awk '{print $5, $6, $7, $8, $9}'
    command -v naive 2> /dev/null
    return 0
}

# Prints the cached answer of get_core_capabilities when it was made for the cores installed now.
core_capabilities_cached() {
    [ -s "$CORE_CAPABILITIES_CACHE" ] && [ -s "$CORE_CAPABILITIES_CACHE.key" ] || return 1
    [ "$(core_capabilities_key)" = "$(cat "$CORE_CAPABILITIES_CACHE.key" 2> /dev/null)" ] || return 1
    cat "$CORE_CAPABILITIES_CACHE"
}

# Keeps the answer ($1) for the next call.
core_capabilities_store() {
    local tmp="$CORE_CAPABILITIES_CACHE.$$"

    printf '%s\n' "$1" > "$tmp" && core_capabilities_key > "$tmp.key" &&
        mv -f "$tmp.key" "$CORE_CAPABILITIES_CACHE.key" && mv -f "$tmp" "$CORE_CAPABILITIES_CACHE" ||
        rm -f "$tmp" "$tmp.key"
}

# 0 when the command was answered here (its exit status in NETSHIFT_QUICK_RC), 1 when the full
# command line has to answer it.
netshift_quick() {
    NETSHIFT_QUICK_RC=0
    case "${1:-}" in
    get_status)
        get_status
        NETSHIFT_QUICK_RC=$?
        ;;
    get_sing_box_status)
        get_sing_box_status
        NETSHIFT_QUICK_RC=$?
        ;;
    check_logs)
        check_logs
        NETSHIFT_QUICK_RC=$?
        ;;
    get_core_capabilities)
        core_capabilities_cached || return 1
        ;;
    *)
        return 1
        ;;
    esac
    return 0
}
