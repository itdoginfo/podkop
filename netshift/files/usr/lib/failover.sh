# shellcheck shell=ash
#
# Failover to direct: with failover_direct '1' on a proxy section, the traffic of the
# section goes out directly (and is picked up there by whatever handles direct traffic,
# for example zapret) while none of its servers answers, and goes back to the section as
# soon as one does.
#
# sing-box has no fallback outbound, so the section's group (<section>-out, the one the
# dashboard shows) is wrapped in a selector <section>-out-failover with the members
# [<section>-out, direct-out], and everything that pointed to the group (route rules, the
# final route, detours) points to the selector. The monitor probes the servers of the
# group every check cycle (the Clash API probe and the interval of priority selection) and
# moves the selector: FAILOVER_FAILURES failed cycles in a row - to direct-out, the first
# cycle with an answering server - back to the group. Nothing but this monitor moves the
# selector (the interface only sets <section>-out), and sing-box restores its choice from
# the cache after a restart or a reboot: a selector found on direct-out is therefore always
# the monitor's own doing, whether or not this process remembers it.

# Wraps the group of the section. $1 config, $2 group tag, $3 selector tag, $4 direct tag.
# Prints the new config. The detours of OTHER outbounds that chain through the group are left
# alone: a section that connects through this one must not silently turn into a direct
# connection when this one goes direct (that would skip the first hop); it stops working
# until the group answers, as it always did.
failover_wrap_config() {
    printf '%s' "$1" | jq -c --arg t "$2" --arg n "$3" --arg d "$4" '
        .route.rules |= ((. // []) | map(if (type == "object") and .outbound? == $t then .outbound = $n else . end))
        | (if .route.final? == $t then .route.final = $n else . end)
        | (if .dns.servers? then .dns.servers |= map(if .detour? == $t then .detour = $n else . end) else . end)
        | (if .route.rule_set? then .route.rule_set |= map(if .download_detour? == $t then .download_detour = $n else . end) else . end)
        | .outbounds += [{type: "selector", tag: $n, outbounds: [$t, $d], default: $t, interrupt_exist_connections: false}]'
}

# config_foreach callback of the config pass; works on the global $config.
_failover_configure_section_handler() {
    local section="$1"
    local failover connection_type tag selector exists wrapped block_leaks

    config_get_bool failover "$section" "failover_direct" 0
    [ "$failover" -eq 1 ] || return 0
    section_is_disabled "$section" && return 0

    config_get connection_type "$section" "connection_type"
    if [ "$connection_type" != "proxy" ]; then
        log "Failover to direct for section '$section': it applies to proxy sections only; ignoring it" "warn"
        return 0
    fi

    tag="$(get_outbound_tag_by_section "$section")"
    selector="$tag$FAILOVER_TAG_SUFFIX"
    exists="$(printf '%s' "$config" | jq -r --arg t "$tag" '[.outbounds[]? | select(.tag == $t)] | length' 2> /dev/null)"
    if [ "${exists:-0}" -eq 0 ]; then
        log "Failover to direct for section '$section': it has no outbound in the configuration (no servers); ignoring it" "warn"
        return 0
    fi

    config_get_bool block_leaks "settings" "block_leaks" 0
    if [ "$block_leaks" -eq 1 ]; then
        log "Failover to direct for section '$section': 'Block leaks' is on, but this option sends the section's traffic out directly while no server answers; turn one of them off if that is not what you want" "warn"
    fi

    wrapped="$(failover_wrap_config "$config" "$tag" "$selector" "$SB_DIRECT_OUTBOUND_TAG")"
    if [ -z "$wrapped" ]; then
        log "Failover to direct for section '$section': the configuration could not be changed; the option is ignored" "warn"
        return 0
    fi
    config="$wrapped"
    log "Failover to direct for section '$section': '$tag' is wrapped in '$selector'" "debug"
}

# Wraps the groups of all the sections that ask for it (the global $config).
failover_configure() {
    config_foreach _failover_configure_section_handler "section"
}

# The state of a section lives in shell variables named after it. A UCI section id may hold
# characters a variable name cannot, so they are folded into "_".
_failover_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_'
}

failover_var_get() {
    local value key

    key="$(_failover_key "$2")"
    eval "value=\"\${FAILOVER_$1_$key:-0}\""
    echo "$value"
}

failover_var_set() {
    local key

    key="$(_failover_key "$2")"
    eval "FAILOVER_$1_$key=\"$3\""
}

# The servers to probe for the group $1 in the running sing-box, the one in use first:
# one per line. Groups inside the group (country groups) are opened one level. For
# something that is not a group, the tag itself.
failover_probe_candidates() {
    printf '%s' "$FAILOVER_PROXIES_JSON" | jq -r --arg tag "$1" '
        .proxies as $p
        | def isgroup: (($p[.].type // "") as $t | ["Selector", "URLTest", "Fallback", "LoadBalance"] | index($t)) != null;
        def inside: [($p[.].now // "")] + ($p[.].all // []) | map(select(. != ""));
        (if ($tag | isgroup) then
            ($tag | inside)
            | map(if isgroup then (inside | map(select(isgroup | not))) else [.] end)
            | flatten
        else [$tag] end)
        | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)
        | .[]' 2> /dev/null
}

# Prints 1 when one of the servers of the group $1 answers, 0 when none does, 2 when it could
# not be told: the time of the cycle was already used up (the caller sets FAILOVER_BUDGET_HIT:
# this runs in a command substitution, a variable set here would not reach it). "Out of time" is not "dead": the
# caller leaves the section as it is. The servers are probed at the same time (one probe of a
# dead server takes seconds), so a section with many dead servers needs the time of one probe,
# not of all of them, and the sections after it still get their turn.
failover_group_alive() {
    local dir member n=0 alive=0 pids=""

    if [ "$(date +%s)" -ge "$FAILOVER_DEADLINE" ]; then
        echo 2
        return 0
    fi
    dir="$(mktemp -d)" || {
        echo 2
        return 0
    }
    failover_probe_candidates "$1" | sed -n "1,${PRIORITY_MAX_PROBES}p" > "$dir/members"
    # nothing to probe (the group is empty or not in the running sing-box): not a failure
    if [ ! -s "$dir/members" ]; then
        rm -rf "$dir"
        echo 1
        return 0
    fi
    # a server name may hold spaces: one name per line, never split
    while IFS= read -r member; do
        n=$((n + 1))
        (
            [ "$(priority_probe_delay "$member")" -gt 0 ] && : > "$dir/ok.$n"
        ) < /dev/null &
        pids="$pids $!"
    done < "$dir/members"
    # only the probes: another background job of the monitor (a list update) must not be waited for
    # shellcheck disable=SC2086
    wait $pids
    ls "$dir"/ok.* > /dev/null 2>&1 && alive=1
    rm -rf "$dir"
    echo "$alive"
}

# $1 - section; FAILOVER_PROXIES_JSON holds the proxies of this cycle.
failover_check_section() {
    local section="$1"
    local tag selector now fails alive

    tag="$(get_outbound_tag_by_section "$section")"
    selector="$tag$FAILOVER_TAG_SUFFIX"
    now="$(printf '%s' "$FAILOVER_PROXIES_JSON" | jq -r --arg tag "$selector" '.proxies[$tag].now // empty' 2> /dev/null)"
    # not in the running sing-box (the option was set after the last start): nothing to do
    [ -n "$now" ] || return 0

    fails="$(failover_var_get FAILS "$section")"

    if [ "$now" = "$tag" ]; then
        # the group is in use: the usual state (a restart of sing-box lands here too)
        failover_var_set ACTIVE "$section" 0
        alive="$(failover_group_alive "$tag")"
        [ "$alive" != 2 ] || FAILOVER_BUDGET_HIT=1
        case "$alive" in
        1)
            failover_var_set FAILS "$section" 0
            return 0
            ;;
        2) return 0 ;;
        esac
        fails=$((fails + 1))
        if [ "$fails" -lt "$FAILOVER_FAILURES" ]; then
            failover_var_set FAILS "$section" "$fails"
            log "Failover to direct for section '$section': no server answers ($fails/$FAILOVER_FAILURES)" "info"
            return 0
        fi
        failover_var_set FAILS "$section" 0
        if clash_api set_group_proxy "$selector" "$SB_DIRECT_OUTBOUND_TAG" > /dev/null 2>&1; then
            failover_var_set ACTIVE "$section" 1
            log "Failover to direct for section '$section': no server answers, its traffic goes out directly" "warn"
        else
            log "Failover to direct for section '$section': could not switch to direct" "warn"
        fi
        return 0
    fi

    if [ "$now" = "$SB_DIRECT_OUTBOUND_TAG" ]; then
        # The selector is on direct-out: our own switch, also when this process does not remember
        # it - the monitor restarts with every start of the service, and sing-box brings its
        # choice back from the cache after a restart or a reboot. Left alone it would stay there
        # for good, so it is taken over (the interface cannot set this selector).
        failover_var_set ACTIVE "$section" 1
        # only a real answer brings the traffic back: "could not tell" keeps it going out directly
        alive="$(failover_group_alive "$tag")"
        [ "$alive" != 2 ] || FAILOVER_BUDGET_HIT=1
        if [ "$alive" -eq 1 ]; then
            if clash_api set_group_proxy "$selector" "$tag" > /dev/null 2>&1; then
                failover_var_set ACTIVE "$section" 0
                log "Failover to direct for section '$section': a server answers again, its traffic goes back to the section" "info"
            else
                log "Failover to direct for section '$section': could not switch back to '$tag'" "warn"
            fi
        fi
        return 0
    fi

    # neither of the two members (cannot happen with the selector made here): nothing to do
    failover_var_set ACTIVE "$section" 0
    failover_var_set FAILS "$section" 0
}

_failover_collect_section_handler() {
    local section="$1"
    local failover connection_type

    config_get_bool failover "$section" "failover_direct" 0
    [ "$failover" -eq 1 ] || return 0
    section_is_disabled "$section" && return 0
    config_get connection_type "$section" "connection_type"
    [ "$connection_type" = "proxy" ] || return 0

    FAILOVER_SECTIONS_TO_CHECK="$FAILOVER_SECTIONS_TO_CHECK $section"
}

# One cycle, called from the monitor next to the priority check. The cycle has a time budget
# (PRIORITY_CYCLE_BUDGET) so that it cannot hold the crash supervision for long: a section the
# time did not reach is checked first in the next cycle (FAILOVER_RESUME), and one that ran out
# of time while being probed is left as it is.
failover_check_sections() {
    local count position i section

    FAILOVER_SECTIONS_TO_CHECK=""
    config_foreach _failover_collect_section_handler "section"
    [ -n "$FAILOVER_SECTIONS_TO_CHECK" ] || return 0

    FAILOVER_DEADLINE=$(($(date +%s) + PRIORITY_CYCLE_BUDGET))
    FAILOVER_BUDGET_HIT=0
    priority_clash_setup
    FAILOVER_PROXIES_JSON="$(priority_fetch_proxies)"
    [ -n "$FAILOVER_PROXIES_JSON" ] || return 0

    # shellcheck disable=SC2086
    set -- $FAILOVER_SECTIONS_TO_CHECK
    count=$#
    [ "${FAILOVER_RESUME:-0}" -lt "$count" ] || FAILOVER_RESUME=0

    i=0
    while [ "$i" -lt "$count" ]; do
        position=$(((FAILOVER_RESUME + i) % count))
        if [ "$i" -gt 0 ] && [ "$(date +%s)" -ge "$FAILOVER_DEADLINE" ]; then
            FAILOVER_RESUME="$position"
            return 0
        fi
        eval "section=\${$((position + 1))}"
        failover_check_section "$section"
        i=$((i + 1))
        # the section that used up the time is not asked again: the next one goes first next time
        if [ "$FAILOVER_BUDGET_HIT" -eq 1 ] && [ "$i" -lt "$count" ]; then
            FAILOVER_RESUME=$(((position + 1) % count))
            return 0
        fi
    done
    FAILOVER_RESUME=0
}
