# shellcheck shell=ash
#
# NaiveProxy links: naive+https://user:pass@host[:port], naive+quic://..., or a
# plain https://user:pass@host[:port] (an https link with a login is a NaiveProxy
# server; a link without one is not).
#
# Two ways to carry them, the first that is possible is used:
#   1. the sing-box core has the `naive` outbound (sing-box 1.13+, built with the
#      with_naive_outbound tag and the Chromium network stack: only some builds,
#      such as the official musl ones);
#   2. the original `naive` client (klzgrad/naiveproxy, an OpenWrt build exists) runs
#      beside sing-box as a local SOCKS5 server and sing-box sends the traffic to it.
#      It works with any sing-box build. The clients are started by the
#      netshift-naive init script from a list the configuration builder writes.

# Sets CONFIG_BUILD_PID to the pid of the shell that runs this ($$ is always the main shell, a
# subshell has a pid of its own). Not a command substitution: that would be one more subshell.
config_build_pid() {
    local file="${CONFIG_BUILD_LOCK_DIR%/*}/.netshift-build-pid.$$"

    sh -c 'echo $PPID > "$1"' sh "$file" 2> /dev/null
    read -r CONFIG_BUILD_PID < "$file" 2> /dev/null
    rm -f "$file"
}

# Moves a lock whose owner is gone out of the way. $1 is the owner that was seen dead; if the
# directory that was moved belongs to somebody else (a new lock taken in between) it goes back.
_config_build_lock_takeover() {
    local stale="$CONFIG_BUILD_LOCK_DIR.stale.$$"

    mv "$CONFIG_BUILD_LOCK_DIR" "$stale" 2> /dev/null || return 0
    if [ "$(cat "$stale/pid" 2> /dev/null)" = "$1" ]; then
        rm -rf "$stale"
    else
        [ -e "$CONFIG_BUILD_LOCK_DIR" ] || mv "$stale" "$CONFIG_BUILD_LOCK_DIR" 2> /dev/null || rm -rf "$stale"
    fi
}

# Takes the build lock, waiting up to CONFIG_BUILD_LOCK_WAIT seconds for a build that is
# running. Returns 1 when it could not (the build goes on without the lock).
config_build_lock_acquire() {
    local me owner waited=0 blank=0

    config_build_pid
    me="$CONFIG_BUILD_PID"
    mkdir -p "${CONFIG_BUILD_LOCK_DIR%/*}" 2> /dev/null
    while ! mkdir "$CONFIG_BUILD_LOCK_DIR" 2> /dev/null; do
        owner="$(cat "$CONFIG_BUILD_LOCK_DIR/pid" 2> /dev/null)"
        if [ -z "$owner" ]; then
            # just created and not signed yet; a lock that stays unsigned was left by a dead build
            blank=$((blank + 1))
            [ "$blank" -le 5 ] || _config_build_lock_takeover ""
        elif [ "$owner" = "$me" ]; then
            return 0
        elif ! kill -0 "$owner" 2> /dev/null; then
            _config_build_lock_takeover "$owner"
            continue
        fi
        [ "$waited" -lt "$CONFIG_BUILD_LOCK_WAIT" ] || return 1
        sleep 1
        waited=$((waited + 1))
    done
    echo "$me" > "$CONFIG_BUILD_LOCK_DIR/pid" 2> /dev/null || {
        rm -rf "$CONFIG_BUILD_LOCK_DIR"
        return 1
    }
    return 0
}

# Gives the lock back (only when it is this shell's).
config_build_lock_release() {
    config_build_pid
    [ "$(cat "$CONFIG_BUILD_LOCK_DIR/pid" 2> /dev/null)" = "$CONFIG_BUILD_PID" ] && rm -rf "$CONFIG_BUILD_LOCK_DIR"
    return 0
}

# Does the running core carry the naive outbound?
naive_core_supported() {
    core_has_tag_strict with_naive_outbound
}

# The path of the naive client, nothing when it is not installed.
naive_binary() {
    local candidate

    for candidate in "$(command -v naive 2> /dev/null)" /usr/bin/naive /usr/bin/naiveproxy /opt/bin/naive; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Is a naive client running? Matched by the path the init script started (the client
# may be installed as naive or naiveproxy), not by a fixed process name.
naive_running() {
    local binary

    binary="$(naive_binary)" || return 1
    pgrep -f "$binary --listen=socks://" > /dev/null 2>&1
}

# A new, empty list of clients: called when a configuration build starts.
naive_sidecars_reset() {
    : > "$NAIVE_LIST_FILE"
    : > "$NAIVE_LIST_FILE.urls"
    chmod 600 "$NAIVE_LIST_FILE" "$NAIVE_LIST_FILE.urls" 2> /dev/null
}

# Adds a client for a proxy URL ("https://user:pass@host:port" or "quic://...") and
# prints the local port that serves it. The same URL gets the same port again.
naive_register() {
    local proxy_url="$1"
    local line port count

    [ -f "$NAIVE_LIST_FILE" ] || naive_sidecars_reset

    line="$(grep -F -n -x -- "$proxy_url" "$NAIVE_LIST_FILE.urls" 2> /dev/null | sed -n '1p')"
    if [ -n "$line" ]; then
        printf '%s\n' "$((NAIVE_PORT_BASE + ${line%%:*} - 1))"
        return 0
    fi

    count="$(grep -c '' "$NAIVE_LIST_FILE.urls" 2> /dev/null)"
    count="${count:-0}"
    port=$((NAIVE_PORT_BASE + count))
    printf '%s\n' "$proxy_url" >> "$NAIVE_LIST_FILE.urls"
    printf '%s|%s\n' "$port" "$proxy_url" >> "$NAIVE_LIST_FILE"
    chmod 600 "$NAIVE_LIST_FILE" "$NAIVE_LIST_FILE.urls" 2> /dev/null
    printf '%s\n' "$port"
}

# Starts, restarts (the list changed) or stops the clients to match the list.
naive_sidecars_apply() {
    if [ ! -s "$NAIVE_LIST_FILE" ]; then
        naive_sidecars_stop
        return 0
    fi

    if cmp -s "$NAIVE_LIST_FILE" "$NAIVE_RUNNING_FILE" 2> /dev/null && naive_running; then
        return 0
    fi

    cp "$NAIVE_LIST_FILE" "$NAIVE_RUNNING_FILE"
    chmod 600 "$NAIVE_RUNNING_FILE" 2> /dev/null
    "$NAIVE_INIT" restart > /dev/null 2>&1 || log "Could not start the NaiveProxy clients" "error"
    # procd starts the clients in the background: a client that dies at once (a missing library,
    # a bad option) would otherwise show up only as a section that talks to a dead port
    sleep 1
    naive_running || log "The NaiveProxy client is not running after the start; see the system log (logread -e naive)" "error"
}

naive_sidecars_stop() {
    [ -x "$NAIVE_INIT" ] && "$NAIVE_INIT" stop > /dev/null 2>&1
    rm -f "$NAIVE_RUNNING_FILE"
    return 0
}
