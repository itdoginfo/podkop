# shellcheck shell=ash
#
# Automatic updates of NetShift and sing-box, with a rollback when the router stops working.
#
# A run (at boot and/or on a schedule) first checks that NetShift works: the Clash API of
# sing-box answers and at least one proxy or VPN section reaches the internet. A router that
# does not work before the update is left alone: there would be nothing to compare with. Then
# each component (sing-box first, NetShift second) is updated when a newer release exists, and
# the same check is repeated. If it fails, the version that was replaced is installed again
# from its release and that release is remembered as bad: later runs skip it, a newer one is
# installed as usual. Everything a run did is kept in AUTO_UPDATE_STATE_FILE and in the log.
#
# Only what can be rolled back is updated: NetShift itself and the sing-box-extended / extended
# lite cores, which come from GitHub releases. The stock sing-box comes from the package feed of
# the firmware, which keeps one version only.

# The status of the last run, for the result of every component: updated, latest, rolled_back,
# failed or skipped. AUTO_UPDATE_RESULTS collects the entries of the current run. $6 is a short
# code of why a component was skipped (stock_core, dev_build, bad_version, not_working, busy),
# which the UI shows in its own language; the message is for the log.
_auto_update_record() {
    local component="$1" result="$2" from="$3" to="$4" message="$5" reason="${6:-}"

    AUTO_UPDATE_RESULTS="$(printf '%s' "$AUTO_UPDATE_RESULTS" | jq -c \
        --arg c "$component" --arg r "$result" --arg f "$from" --arg t "$to" --arg m "$message" --arg why "$reason" \
        '. + [{component: $c, result: $r, from: $f, to: $t, message: $m} + (if $why != "" then {reason: $why} else {} end)]')"

    case "$result" in
    failed | rolled_back) log "Automatic update, $component: $message" "error" ;;
    *) log "Automatic update, $component: $message" "info" ;;
    esac
}

# Prints the release of $1 (netshift | sing_box) that a rollback marked as bad, if any.
auto_update_bad_version() {
    jq -r --arg c "$1" '.bad_versions[$c] // empty' "$AUTO_UPDATE_STATE_FILE" 2> /dev/null
}

# Writes the state file: the results of this run ($1 = trigger) and the bad versions, the one
# of this run included.
_auto_update_save_state() {
    local trigger="$1" tmp

    mkdir -p "${AUTO_UPDATE_STATE_FILE%/*}" 2> /dev/null
    tmp="${AUTO_UPDATE_STATE_FILE}.tmp.$$"
    {
        cat "$AUTO_UPDATE_STATE_FILE" 2> /dev/null || echo '{}'
    } | jq -c --arg trigger "$trigger" --argjson at "$(date +%s)" \
        --argjson results "$AUTO_UPDATE_RESULTS" --argjson bad "$AUTO_UPDATE_NEW_BAD" '
        (if type == "object" then . else {} end)
        | .last_run = {at: $at, trigger: $trigger, results: $results}
        | .bad_versions = ((.bad_versions // {}) + $bad)' > "$tmp" 2> /dev/null &&
        mv -f "$tmp" "$AUTO_UPDATE_STATE_FILE" || rm -f "$tmp"
}

_auto_update_mark_bad() {
    AUTO_UPDATE_NEW_BAD="$(printf '%s' "$AUTO_UPDATE_NEW_BAD" | jq -c --arg c "$1" --arg v "$2" '. + {($c): $v}')"
}

# config_foreach callback: probes the outbound of a proxy/VPN section that has one, until one
# answers.
_auto_update_probe_section() {
    local section="$1" tag delay

    [ "$AUTO_UPDATE_ALIVE" -eq 0 ] || return 0
    section_has_configured_outbound "$section" || return 0

    tag="$(get_outbound_tag_by_section "$section")"
    [ -n "$tag" ] || return 0
    AUTO_UPDATE_PROBED=$((AUTO_UPDATE_PROBED + 1))
    delay="$(priority_probe_delay "$tag")"
    [ "${delay:-0}" -gt 0 ] && AUTO_UPDATE_ALIVE=1
    return 0
}

# Returns 0 when NetShift works right now; sets AUTO_UPDATE_HEALTH_REASON otherwise.
auto_update_health_once() {
    AUTO_UPDATE_HEALTH_REASON=""
    priority_clash_setup
    if ! curl -m 5 -s --header "$PRIORITY_CLASH_AUTH" "$PRIORITY_CLASH_URL/version" 2> /dev/null |
        jq -e '.version' > /dev/null 2>&1; then
        AUTO_UPDATE_HEALTH_REASON="sing-box does not answer (Clash API)"
        return 1
    fi

    AUTO_UPDATE_PROBED=0
    AUTO_UPDATE_ALIVE=0
    foreach_active_section _auto_update_probe_section "section"
    if [ "$AUTO_UPDATE_PROBED" -gt 0 ] && [ "$AUTO_UPDATE_ALIVE" -eq 0 ]; then
        AUTO_UPDATE_HEALTH_REASON="no proxy or VPN section reaches the internet"
        return 1
    fi
    return 0
}

# The same, with time to come up after a restart: AUTO_UPDATE_HEALTH_ATTEMPTS checks,
# AUTO_UPDATE_HEALTH_INTERVAL seconds apart.
auto_update_wait_healthy() {
    local attempt=1

    while :; do
        auto_update_health_once && return 0
        [ "$attempt" -lt "$AUTO_UPDATE_HEALTH_ATTEMPTS" ] || return 1
        attempt=$((attempt + 1))
        sleep "$AUTO_UPDATE_HEALTH_INTERVAL"
    done
}

# Prints the field $2 of the JSON reply $1.
_auto_update_field() {
    printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty' 2> /dev/null
}

# Updates one component and rolls it back when NetShift stops working.
#   $1 - component (netshift | sing_box), $2 - check command, $3 - install command
#   $4 - command run after the install (restart), or ":"
_auto_update_component() {
    local component="$1" check="$2" install="$3" after="$4"
    local reply status current latest bad reason

    reply="$($check 2> /dev/null)"
    if [ "$(_auto_update_field "$reply" success)" != "true" ]; then
        _auto_update_record "$component" failed "" "" "the check for a new version failed: $(_auto_update_field "$reply" message)"
        return 0
    fi
    status="$(_auto_update_field "$reply" status)"
    current="$(_auto_update_field "$reply" current_version)"
    latest="$(_auto_update_field "$reply" latest_version)"

    # "switch" (the other repository has a lower version) is a choice for the user, never automatic
    if [ "$status" != "outdated" ]; then
        _auto_update_record "$component" latest "$current" "$current" "$current is the latest version"
        return 0
    fi

    bad="$(auto_update_bad_version "$component")"
    if [ -n "$bad" ] && [ "${bad#v}" = "${latest#v}" ]; then
        _auto_update_record "$component" skipped "$current" "$latest" "$latest was rolled back earlier and is skipped; a newer release will be installed" bad_version
        return 0
    fi

    log "Automatic update, $component: installing $latest (installed: $current)" "info"
    reply="$($install 2> /dev/null)"
    if [ "$(_auto_update_field "$reply" success)" != "true" ]; then
        _auto_update_record "$component" failed "$current" "$latest" "installing $latest failed, $current is kept: $(_auto_update_field "$reply" message)"
        return 0
    fi
    $after

    if auto_update_wait_healthy; then
        _auto_update_record "$component" updated "$current" "$latest" "updated from $current to $latest"
        return 0
    fi

    reason="$AUTO_UPDATE_HEALTH_REASON"
    log "Automatic update, $component: NetShift does not work with $latest ($reason); installing $current again" "warn"
    _auto_update_mark_bad "$component" "$latest"
    [ "$component" = "netshift" ] && NETSHIFT_VERSION="$latest"
    reply="$(UPDATES_PINNED_TAG="$current" $install 2> /dev/null)"
    if [ "$(_auto_update_field "$reply" success)" != "true" ]; then
        _auto_update_record "$component" failed "$current" "$latest" "$latest does not work ($reason) and installing $current again failed: $(_auto_update_field "$reply" message)"
        return 0
    fi
    $after
    [ "$component" = "netshift" ] && NETSHIFT_VERSION="$current"

    if auto_update_wait_healthy; then
        _auto_update_record "$component" rolled_back "$current" "$latest" "$latest did not work ($reason), rolled back to $current; $latest will be skipped"
    else
        _auto_update_record "$component" failed "$current" "$latest" "$latest did not work ($reason), rolled back to $current, but NetShift still does not work ($AUTO_UPDATE_HEALTH_REASON)"
    fi
    return 0
}

_auto_update_sing_box() {
    case "$(get_sing_box_variant)" in
    extended)
        _auto_update_component sing_box updates_check_sing_box_extended updates_install_sing_box_extended :
        ;;
    extended_lite)
        _auto_update_component sing_box updates_check_sing_box_lite updates_install_sing_box_lite :
        ;;
    *)
        _auto_update_record sing_box skipped "" "" "the stock sing-box comes from the firmware packages and cannot be rolled back; automatic updates cover sing-box-extended and its lite build" stock_core
        ;;
    esac
}

_auto_update_netshift() {
    case "$NETSHIFT_VERSION" in
    *COMPILED*)
        _auto_update_record netshift skipped "" "" "a development build is not updated automatically" dev_build
        return 0
        ;;
    esac
    _auto_update_component netshift updates_check_netshift updates_self_update_netshift updates_restart_netshift
}

# True while the Components manager installs something.
_auto_update_component_job_running() {
    local state_file

    for state_file in "$UPDATES_JOB_DIR"/*.json; do
        updates_job_state_is_running "$state_file" && return 0
    done
    return 1
}

# Entry point: `netshift auto_update <trigger>`. boot and scheduled runs need the option
# auto_update; `now` runs anyway (from the command line).
auto_update_run() {
    local trigger="${1:-now}" enabled update_netshift update_sing_box

    config_get_bool enabled "settings" "auto_update" 0
    if [ "$enabled" -ne 1 ] && [ "$trigger" != "now" ]; then
        return 0
    fi

    if ! mkdir "$AUTO_UPDATE_LOCK_DIR" 2> /dev/null; then
        log "Automatic update: another run is in progress" "info"
        return 0
    fi
    # shellcheck disable=SC2064
    trap "rmdir '$AUTO_UPDATE_LOCK_DIR' 2> /dev/null" EXIT INT TERM

    AUTO_UPDATE_RESULTS="[]"
    AUTO_UPDATE_NEW_BAD="{}"
    config_get_bool update_sing_box "settings" "auto_update_sing_box" 1
    config_get_bool update_netshift "settings" "auto_update_netshift" 1

    if _auto_update_component_job_running; then
        _auto_update_record all skipped "" "" "the Components manager is installing something; nothing is updated now" busy
    elif ! auto_update_wait_healthy; then
        _auto_update_record all skipped "" "" "NetShift does not work right now ($AUTO_UPDATE_HEALTH_REASON), so an update could not be checked; nothing is updated" not_working
    else
        [ "$update_sing_box" -eq 1 ] && _auto_update_sing_box
        [ "$update_netshift" -eq 1 ] && _auto_update_netshift
    fi

    _auto_update_save_state "$trigger"
    rmdir "$AUTO_UPDATE_LOCK_DIR" 2> /dev/null
    trap - EXIT INT TERM
    return 0
}

# Prints the state file for the UI ({} when there was no run yet).
auto_update_status() {
    jq -c '.' "$AUTO_UPDATE_STATE_FILE" 2> /dev/null || echo '{}'
}

# The cron line of the schedule, or nothing (off, unknown value).
#   $1 - interval (12h | 1d | 1w), $2 - HH:MM
get_auto_update_cron_line() {
    local interval="$1" time="$2" hour minute

    is_valid_subscription_update_time "$time" || time="$AUTO_UPDATE_TIME_DEFAULT"
    hour="$(cron_number "${time%%:*}")"
    minute="$(cron_number "${time##*:}")"

    case "$interval" in
    12h) echo "$minute $hour,$(((hour + 12) % 24)) * * * /usr/bin/netshift auto_update scheduled" ;;
    1d) echo "$minute $hour * * * /usr/bin/netshift auto_update scheduled" ;;
    1w) echo "$minute $hour * * 0 /usr/bin/netshift auto_update scheduled" ;;
    *) return 1 ;;
    esac
}

# Writes (or removes) the cron job of the automatic update from the settings.
sync_auto_update_cron_job() {
    local enabled interval time line

    (crontab -l 2> /dev/null | grep -v "/usr/bin/netshift auto_update") | crontab -

    config_get_bool enabled "settings" "auto_update" 0
    [ "$enabled" -eq 1 ] || return 0
    config_get interval "settings" "auto_update_interval" "$AUTO_UPDATE_INTERVAL_DEFAULT"
    config_get time "settings" "auto_update_time" "$AUTO_UPDATE_TIME_DEFAULT"
    [ "$interval" != "off" ] || return 0

    if ! line="$(get_auto_update_cron_line "$interval" "$time")"; then
        log "Unknown auto_update_interval '$interval': no scheduled automatic update" "warn"
        return 0
    fi
    crontab -l 2> /dev/null | {
        cat
        echo "$line"
    } | crontab -
    log "The automatic update cron job has been created: $line"
}

# After a start: the run at boot, once per boot, detached from procd (the start of the
# service must not wait for it, and a restart of the service must not kill it). Only a start
# in the first AUTO_UPDATE_BOOT_WINDOW seconds of uptime is a boot: turning the option on, or
# a restart a day later, is not.
auto_update_schedule_boot_run() {
    local enabled on_boot uptime

    config_get_bool enabled "settings" "auto_update" 0
    config_get_bool on_boot "settings" "auto_update_on_boot" 1
    [ "$enabled" -eq 1 ] && [ "$on_boot" -eq 1 ] || return 0
    [ ! -e "$AUTO_UPDATE_BOOT_MARKER" ] || return 0
    uptime="$(cut -d. -f1 "${AUTO_UPDATE_UPTIME_FILE:-/proc/uptime}" 2> /dev/null)"
    case "$uptime" in '' | *[!0-9]*) return 0 ;; esac
    [ "$uptime" -lt "$AUTO_UPDATE_BOOT_WINDOW" ] || return 0
    : > "$AUTO_UPDATE_BOOT_MARKER"

    setsid /bin/sh -c "exec 1000>&- 2>/dev/null; sleep $AUTO_UPDATE_BOOT_DELAY; exec /usr/bin/netshift auto_update boot" \
        < /dev/null > /dev/null 2>&1 &
    log "The automatic update runs in $AUTO_UPDATE_BOOT_DELAY seconds (after boot)" "info"
}
