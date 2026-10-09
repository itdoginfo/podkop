# shellcheck shell=ash
#
# Pin guard: a server chosen by hand in a section's selector stays chosen even when
# it stops answering, and the section is then dead until someone notices. With
# pin_guard '1' on a proxy section the monitor probes the chosen server on every
# check cycle (the same Clash API probe and interval as priority selection); after
# PIN_GUARD_FAILURES failed probes in a row the selector goes back to the section's
# automatic group (the fastest server), the event is logged and kept for the
# dashboard. A selection that is the automatic group itself is never touched, and a
# section with priority_mode is left to that mode.

# The failed probes in a row of a section (0 when none). $1 - section
pin_guard_fails_of() {
    local value

    case "$1" in
    "" | *[!A-Za-z0-9_]*)
        echo 0
        return 0
        ;;
    esac

    eval "value=\"\${PIN_GUARD_FAILS_$1:-0}\""
    echo "$value"
}

pin_guard_set_fails() {
    # section ids are [A-Za-z0-9_] in UCI; anything else is not worth a variable
    case "$1" in
    "" | *[!A-Za-z0-9_]*) return 0 ;;
    esac
    eval "PIN_GUARD_FAILS_$1=\"$2\""
}

# Remembers a switch for the dashboard: the last PIN_GUARD_EVENTS_KEEP of them.
# $1 section, $2 server it left, $3 group it went to
pin_guard_record_event() {
    local tmp

    tmp="$PIN_GUARD_EVENTS_FILE.tmp.$$"
    {
        jq -c --arg section "$1" --arg from "$2" --arg to "$3" --argjson time "$(date +%s)" --argjson keep "$PIN_GUARD_EVENTS_KEEP" \
            '((. // []) + [{time: $time, section: $section, from: $from, to: $to}]) | .[-$keep:]' "$PIN_GUARD_EVENTS_FILE" 2> /dev/null ||
            jq -n -c --arg section "$1" --arg from "$2" --arg to "$3" --argjson time "$(date +%s)" '[{time: $time, section: $section, from: $from, to: $to}]'
    } > "$tmp" && mv "$tmp" "$PIN_GUARD_EVENTS_FILE"
}

# The events, newest last. Prints a JSON array.
get_pin_guard_events() {
    if [ -s "$PIN_GUARD_EVENTS_FILE" ] && jq -e 'type == "array"' "$PIN_GUARD_EVENTS_FILE" > /dev/null 2>&1; then
        jq -c . "$PIN_GUARD_EVENTS_FILE"
    else
        echo "[]"
    fi
}

# $1 - section; PIN_GUARD_PROXIES_JSON holds the proxies of this cycle.
pin_guard_check_section() {
    local section="$1"
    local tag current type auto fails

    tag="$(get_outbound_tag_by_section "$section")"
    current="$(printf '%s' "$PIN_GUARD_PROXIES_JSON" | jq -r --arg tag "$tag" '.proxies[$tag].now // empty' 2> /dev/null)"
    [ -n "$current" ] || return 0

    # only an individual server counts as "pinned"; a group is the automatic choice
    type="$(printf '%s' "$PIN_GUARD_PROXIES_JSON" | jq -r --arg name "$current" '.proxies[$name].type // empty' 2> /dev/null)"
    case "$type" in
    Selector | URLTest | Fallback | LoadBalance)
        pin_guard_set_fails "$section" 0
        return 0
        ;;
    esac

    auto="$(printf '%s' "$PIN_GUARD_PROXIES_JSON" | jq -r --arg tag "$tag" '
        .proxies as $p | ($p[$tag].all // [])[] | select(($p[.].type // "") == "URLTest")' 2> /dev/null | sed -n '1p')"
    if [ -z "$auto" ]; then
        _priority_warn_once "$section" no-auto-group "Pin guard for section '$section': it has no automatic (urltest) group to fall back to; the option has no effect here"
        return 0
    fi

    if [ "$(priority_probe_delay "$current")" -gt 0 ]; then
        pin_guard_set_fails "$section" 0
        return 0
    fi

    fails=$(($(pin_guard_fails_of "$section") + 1))
    if [ "$fails" -lt "$PIN_GUARD_FAILURES" ]; then
        pin_guard_set_fails "$section" "$fails"
        log "Pin guard for section '$section': the chosen server '$current' did not answer ($fails/$PIN_GUARD_FAILURES)" "info"
        return 0
    fi

    pin_guard_set_fails "$section" 0
    if clash_api set_group_proxy "$tag" "$auto" > /dev/null 2>&1; then
        log "Pin guard for section '$section': the chosen server '$current' stopped answering, switched to the automatic group '$auto'" "warn"
        pin_guard_record_event "$section" "$current" "$auto"
    else
        log "Pin guard for section '$section': could not switch from '$current' to '$auto'" "warn"
    fi
}

# config_foreach callback: collects the sections the guard applies to.
_pin_guard_collect_section_handler() {
    local section="$1"
    local pin_guard priority_mode connection_type

    config_get_bool pin_guard "$section" "pin_guard" 0
    [ "$pin_guard" -eq 1 ] || return 0
    section_is_disabled "$section" && return 0

    config_get connection_type "$section" "connection_type"
    if [ "$connection_type" != "proxy" ]; then
        _priority_warn_once "$section" pin-not-proxy "Pin guard for section '$section': it applies to proxy sections only; ignoring it"
        return 0
    fi

    config_get_bool priority_mode "$section" "priority_mode" 0
    [ "$priority_mode" -eq 0 ] || return 0

    PIN_GUARD_SECTIONS_TO_CHECK="$PIN_GUARD_SECTIONS_TO_CHECK $section"
}

# One cycle, called from the monitor next to the priority check.
pin_guard_check_sections() {
    local section

    PIN_GUARD_SECTIONS_TO_CHECK=""
    config_foreach _pin_guard_collect_section_handler "section"
    [ -n "$PIN_GUARD_SECTIONS_TO_CHECK" ] || return 0

    priority_clash_setup
    PIN_GUARD_PROXIES_JSON="$(priority_fetch_proxies)"
    [ -n "$PIN_GUARD_PROXIES_JSON" ] || return 0

    for section in $PIN_GUARD_SECTIONS_TO_CHECK; do
        pin_guard_check_section "$section"
    done
}
