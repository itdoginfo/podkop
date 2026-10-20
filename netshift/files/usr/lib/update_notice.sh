# shellcheck shell=ash
#
# "A newer version is available" notice for the dashboard. The answer is kept in a
# small file in tmpfs: the dashboard reads it without any network access
# (get_update_notice) and, when it is older than UPDATE_NOTICE_TTL and the option
# is on, starts one background refresh (update_notice_refresh_async) that asks
# GitHub through the same checks the Component Manager uses. Nothing is installed.

# One JSON object: {"checked": <epoch>, "netshift": {...}, "sing_box": {...}}.
# Each part is the answer of the matching check (success, current_version,
# latest_version, status) or null when the check failed or does not apply.
update_notice_collect() {
    local netshift_json sing_box_json variant now

    now="$(date +%s)"
    netshift_json="$(updates_check_netshift 2> /dev/null | jq -c 'select(.success == true)' 2> /dev/null)"
    [ -n "$netshift_json" ] || netshift_json="null"

    # Only the cores that come from GitHub: the stock core would need a package
    # feed refresh, which is not something to do in the background.
    sing_box_json="null"
    variant="$(get_sing_box_variant)"
    case "$variant" in
    extended)
        sing_box_json="$(updates_check_sing_box_extended 2> /dev/null | jq -c 'select(.success == true)' 2> /dev/null)"
        ;;
    extended_lite)
        sing_box_json="$(updates_check_sing_box_lite 2> /dev/null | jq -c 'select(.success == true)' 2> /dev/null)"
        ;;
    esac
    [ -n "$sing_box_json" ] || sing_box_json="null"

    jq -n -c --argjson checked "$now" --argjson netshift "$netshift_json" --argjson sing_box "$sing_box_json" \
        '{checked: $checked, netshift: $netshift, sing_box: $sing_box}'
}

# The installed version of the core, as the checks write it (without a leading "v"); empty
# when it cannot be read. Only asked when the stored answer has a core part.
update_notice_sing_box_now() {
    local version

    version="$(get_sing_box_version 2> /dev/null)"
    printf '%s' "${version#v}"
}

# stdin: a stored answer. Drops the parts made for a version that is not the installed one
# ($1 NetShift, $2 the core; an empty value is not compared) and prints the answer, with
# "outdated": true when it dropped something.
update_notice_drop_outdated() {
    jq -c --arg netshift_now "$1" --arg sing_box_now "$2" '
        def outdated($part; $now):
            ($part != null) and ($now != "") and (($part.current_version // "") != $now);
        outdated(.netshift; $netshift_now) as $ns_old
        | outdated(.sing_box; $sing_box_now) as $sb_old
        | (if $ns_old then .netshift = null else . end)
        | (if $sb_old then .sing_box = null else . end)
        | .outdated = ($ns_old or $sb_old)'
}

# Runs the checks and stores the answer. A run that learned nothing (both null,
# i.e. GitHub not reachable) keeps the previous answer.
update_notice_refresh() {
    local result previous sing_box_now="" tmp

    result="$(update_notice_collect)"
    if [ "$(printf '%s' "$result" | jq -r '(.netshift == null) and (.sing_box == null)')" = "true" ]; then
        # Remember that we tried, so an unreachable GitHub is not asked again on
        # every page load: only the time moves. What the previous answer said about a
        # version that is no longer installed goes (after an update it would otherwise be
        # offered again, and the notice would ask for a refresh on every page load).
        if [ -s "$UPDATE_NOTICE_FILE" ]; then
            [ -z "$(jq -r '.sing_box.current_version // empty' "$UPDATE_NOTICE_FILE" 2> /dev/null)" ] ||
                sing_box_now="$(update_notice_sing_box_now)"
            previous="$(update_notice_drop_outdated "${NETSHIFT_VERSION:-}" "$sing_box_now" < "$UPDATE_NOTICE_FILE" 2> /dev/null |
                jq -c --argjson checked "$(date +%s)" '.checked = $checked | del(.outdated)' 2> /dev/null)"
            [ -z "$previous" ] || result="$previous"
        fi
    fi

    tmp="$UPDATE_NOTICE_FILE.tmp.$$"
    printf '%s\n' "$result" > "$tmp" && mv "$tmp" "$UPDATE_NOTICE_FILE"
}

# Starts a refresh that outlives the caller (the RPC session may close), unless one
# is running already. Prints {"started":true|false}.
update_notice_refresh_async() {
    local lock="$UPDATE_NOTICE_FILE.lock"
    local pid

    pid="$(cat "$lock" 2> /dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2> /dev/null; then
        echo '{"started":false}'
        return 0
    fi

    (
        trap '' HUP
        update_notice_refresh
        rm -f "$lock"
    ) > /dev/null 2>&1 &
    printf '%s' "$!" > "$lock"
    echo '{"started":true}'
}

# What the dashboard shows. {"enabled": bool, "stale": bool, "checked": epoch|null,
# "netshift": {...}|null, "sing_box": {...}|null}. No network access.
get_update_notice() {
    local enabled now data checked sing_box_now=""

    config_get_bool enabled "settings" "update_notice" 1
    now="$(date +%s)"

    data="$(cat "$UPDATE_NOTICE_FILE" 2> /dev/null)"
    printf '%s' "$data" | jq -e 'type == "object"' > /dev/null 2>&1 || data="{}"

    checked="$(printf '%s' "$data" | jq -r '.checked // 0')"
    case "$checked" in
    '' | *[!0-9]*) checked=0 ;;
    esac

    # The answer is kept for a day, but it names the versions it was made for. After an
    # update (or a switch of the core) it would keep offering "0.9.10.4 -> 0.9.11.1" on a
    # router that already runs 0.9.11.3: a part whose "current_version" is not what is
    # installed now is dropped and the notice is due for a refresh.
    [ -z "$(printf '%s' "$data" | jq -r '.sing_box.current_version // empty' 2> /dev/null)" ] ||
        sing_box_now="$(update_notice_sing_box_now)"
    data="$(printf '%s' "$data" | update_notice_drop_outdated "${NETSHIFT_VERSION:-}" "$sing_box_now")"

    printf '%s' "$data" | jq -c --argjson enabled "$([ "$enabled" -eq 1 ] && echo true || echo false)" \
        --argjson stale "$([ $((now - checked)) -ge "$UPDATE_NOTICE_TTL" ] && echo true || echo false)" '{
            enabled: $enabled,
            stale: ($stale or .outdated),
            checked: (.checked // null),
            netshift: (.netshift // null),
            sing_box: (.sing_box // null)
        }'
}
