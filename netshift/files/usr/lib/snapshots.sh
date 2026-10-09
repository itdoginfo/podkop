# shellcheck shell=ash
#
# Snapshots of the NetShift configuration (/etc/config/netshift): the last working
# settings can be brought back after a change that broke the service. A snapshot
# is a plain copy of the file in SNAPSHOT_DIR, named "<epoch>-<label>.conf". One is
# taken every time the service starts with a configuration sing-box accepted
# (label "auto"), before a restore (label "before-restore") and on demand
# ("manual"); the newest SNAPSHOT_KEEP are kept, an unchanged configuration does
# not make a new one.

SNAPSHOT_LABELS="auto manual before-restore"

# Is the snapshot id one we could have written? "<digits>-<label>"
snapshot_id_is_valid() {
    local id="$1"
    local epoch label

    epoch="${id%%-*}"
    label="${id#*-}"
    case "$epoch" in
    '' | *[!0-9]*) return 1 ;;
    esac
    [ "$label" != "$id" ] || return 1
    case " $SNAPSHOT_LABELS " in
    *" $label "*) return 0 ;;
    esac
    return 1
}

snapshot_path() {
    echo "$SNAPSHOT_DIR/$1.conf"
}

# Snapshot ids, newest first.
snapshot_ids() {
    local file name

    [ -d "$SNAPSHOT_DIR" ] || return 0
    for file in "$SNAPSHOT_DIR"/*.conf; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        name="${name%.conf}"
        snapshot_id_is_valid "$name" && echo "$name"
    done | sort -t- -k1,1 -n -r
}

# Keeps the newest SNAPSHOT_KEEP, removes the rest.
snapshot_prune() {
    local count=0 id

    for id in $(snapshot_ids); do
        count=$((count + 1))
        [ "$count" -gt "$SNAPSHOT_KEEP" ] && rm -f "$(snapshot_path "$id")"
    done
}

# Takes a snapshot of the configuration. $1 - label (default manual), $2 - "force"
# to take it even when the newest one is identical.
# Prints {"ok":true,"id":"..."} (id empty when nothing was needed) or an error.
snapshot_save() {
    local label="${1:-manual}"
    local force="$2"
    local source="$NETSHIFT_CONFIG_FILE"
    local newest id tmp now

    case " $SNAPSHOT_LABELS " in
    *" $label "*) ;;
    *)
        jq -n -c '{error: "unknown label"}'
        return 1
        ;;
    esac
    if [ ! -s "$source" ]; then
        jq -n -c '{error: "there is no configuration to save"}'
        return 1
    fi

    (umask 077 && mkdir -p "$SNAPSHOT_DIR") 2> /dev/null || {
        jq -n -c '{error: "cannot create the snapshot directory"}'
        return 1
    }

    newest="$(snapshot_ids | sed -n '1p')"
    if [ "$force" != "force" ] && [ -n "$newest" ] && cmp -s "$source" "$(snapshot_path "$newest")"; then
        jq -n -c --arg id "$newest" '{ok: true, id: "", unchanged: $id}'
        return 0
    fi

    # The id starts with the time. A clock that is behind (a router without time
    # sync at boot) must not make a new snapshot older than the newest one, or the
    # pruning would drop the wrong ones: the id is then the newest time plus one.
    # Two snapshots in the same second keep their order the same way.
    now="$(date +%s)"
    if [ -n "$newest" ] && [ "$now" -le "${newest%%-*}" ]; then
        now=$((${newest%%-*} + 1))
    fi
    id="$now-$label"
    while [ -e "$(snapshot_path "$id")" ]; do
        now=$((now + 1))
        id="$now-$label"
    done

    # the configuration holds proxy links and passwords: the copy is private from the start
    tmp="$(snapshot_path "$id").tmp.$$"
    if ! (umask 077 && cp "$source" "$tmp") || ! mv "$tmp" "$(snapshot_path "$id")"; then
        rm -f "$tmp"
        jq -n -c '{error: "cannot write the snapshot"}'
        return 1
    fi
    snapshot_prune

    jq -n -c --arg id "$id" '{ok: true, id: $id}'
}

# {"snapshots":[{"id","time","label","size","current"}]}, newest first; "current"
# marks the one equal to the configuration now.
snapshot_list() {
    local id file result="[]" epoch label size current

    for id in $(snapshot_ids); do
        file="$(snapshot_path "$id")"
        epoch="${id%%-*}"
        label="${id#*-}"
        size="$(wc -c < "$file" | tr -d ' ')"
        current=false
        cmp -s "$file" "$NETSHIFT_CONFIG_FILE" && current=true
        result="$(printf '%s' "$result" | jq -c --arg id "$id" --argjson time "$epoch" --arg label "$label" \
            --argjson size "$size" --argjson current "$current" \
            '. + [{id: $id, time: $time, label: $label, size: $size, current: $current}]')"
    done

    jq -n -c --argjson snapshots "$result" '{snapshots: $snapshots}'
}

# Is the file a NetShift configuration UCI can read, with the settings section?
snapshot_file_is_usable() {
    local file="$1"
    local dir

    dir="$(mktemp -d)" || return 1
    cp "$file" "$dir/netshift"
    if uci -c "$dir" -q show netshift 2> /dev/null | grep -q '^netshift\.settings=settings$'; then
        rm -rf "$dir"
        return 0
    fi
    rm -rf "$dir"
    return 1
}

# Brings a snapshot back. The configuration it replaces is kept first (label
# before-restore). The service is not restarted here: the caller does that.
snapshot_restore() {
    local id="$1"
    local file tmp

    if ! snapshot_id_is_valid "$id"; then
        jq -n -c '{error: "invalid snapshot id"}'
        return 1
    fi
    file="$(snapshot_path "$id")"
    if [ ! -f "$file" ]; then
        jq -n -c '{error: "no such snapshot"}'
        return 1
    fi
    if ! snapshot_file_is_usable "$file"; then
        jq -n -c '{error: "the snapshot is not a usable configuration"}'
        return 1
    fi

    snapshot_save before-restore force > /dev/null 2>&1

    tmp="$NETSHIFT_CONFIG_FILE.restore.$$"
    if ! (umask 077 && cp "$file" "$tmp") || ! mv "$tmp" "$NETSHIFT_CONFIG_FILE"; then
        rm -f "$tmp"
        jq -n -c '{error: "cannot write the configuration"}'
        return 1
    fi
    # changes staged in LuCI but not applied belong to the old configuration
    uci -q revert netshift > /dev/null 2>&1

    jq -n -c --arg id "$id" '{ok: true, restored: $id}'
}
