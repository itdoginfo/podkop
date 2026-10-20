# shellcheck shell=ash
#
# Applying a change of /etc/config/netshift. A change of the configuration used to restart
# NetShift and sing-box every time, whatever was changed. Some options never reach the
# running service (where updates come from, the notice about a new version, the tiles of
# the dashboard): changing only these needs no restart. The configuration without those
# options is hashed when the service has started; when the configuration changes, the hash is
# compared and the service is restarted only if it differs. When in doubt (no hash: the
# service was not started by NetShift) it restarts, as before.

# Prints the hash of the options that the running service depends on.
config_runtime_hash() {
    local ignored

    ignored="$(printf '%s' "$CONFIG_NO_RESTART_OPTIONS" | tr ' ' '|')"
    uci -q export netshift 2> /dev/null |
        awk -v ignored="$ignored" '
            BEGIN { n = split(ignored, names, "|"); for (i = 1; i <= n; i++) skip[names[i]] = 1 }
            ($1 == "option" || $1 == "list") && ($2 in skip) { next }
            { print }' |
        md5sum | awk '{print $1}'
}

# Remembers the hash of the configuration the service has started with (readable by root only:
# the hash is taken over the whole configuration, passwords and links included).
config_applied_hash_save() {
    (
        umask 077
        config_runtime_hash > "$CONFIG_APPLIED_HASH_FILE" 2> /dev/null
    )
}

# Forgets it: the service is stopped or being started, so the next change of the configuration
# must start it again whatever was changed. start() clears it first and saves it only after a
# start that succeeded; stop() clears it.
config_applied_hash_clear() {
    rm -f "$CONFIG_APPLIED_HASH_FILE"
}

# Called by procd when the configuration changes.
apply_config_change() {
    local saved current

    saved="$(cat "$CONFIG_APPLIED_HASH_FILE" 2> /dev/null)"
    current="$(config_runtime_hash)"
    if [ -n "$saved" ] && [ "$saved" = "$current" ]; then
        log "Configuration changed, but only in options that need no restart (updates, dashboard); NetShift is not restarted" "info"
        # the schedule of the automatic update is one of them: only its cron job changes
        config_load "$NETSHIFT_CONFIG"
        sync_auto_update_cron_job
        return 0
    fi
    "$NETSHIFT_INIT" restart > /dev/null 2>&1
}
