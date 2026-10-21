# shellcheck shell=ash
#
# A preview of the subscription filters of a section: how many servers of the downloaded
# subscription stay with the filters as they are in the form (not yet saved). It works on the
# cached feeds of the last start, downloads nothing and changes nothing: the form values go
# into a temporary copy of the configuration (with a save directory of its own, so that what
# LuCI has staged is never touched), the GeoIP flags come from the cache only.

# $1 = section, $2 = {"<option>": ["value", ...]} for the options the form holds right now
# (only the subscription_filter_* lists are taken). Prints
# {"total": N, "kept": M, "unsupported": U, "names": [..kept names..]}
# - total: servers of the subscription that this core can use at all (an estimate: the static
# filter of the generator, without the sing-box check of the start, which may still drop a server
# that is malformed), kept: of them, those the filters keep, unsupported: servers the core cannot
# use whatever the filters say (for example xhttp without sing-box-extended) - or
# {"error": "no_cache"|"bad_input"|"no_config"|"no_section"|"disabled"}: no_section for a section
# that is not saved (yet), disabled for one that gives no servers at all (disabled '1').
preview_subscription_filter() {
    # In a subshell: a preview is not an event (the shared code logs what it merges, and every
    # press of the button would fill the log of the router), so log is silenced - for the
    # preview only, not for whoever calls it next in the same shell.
    (
        log() { :; }
        _preview_subscription_filter_run "$@"
    )
}

_preview_subscription_filter_run() {
    local section="$1"
    local overrides="${2:-}"
    local tmp_dir keys key value
    local include_json exclude_json urls_file merged_file batch all_batch feed_total

    [ -n "$overrides" ] || overrides="{}"
    # the section id goes into uci names and the name of the cache file: a UCI id only
    case "$section" in
    "" | *[!A-Za-z0-9_]*)
        echo '{"error":"bad_input"}'
        return 0
        ;;
    esac
    if ! printf '%s' "$overrides" | jq -e 'type == "object"' > /dev/null 2>&1; then
        echo '{"error":"bad_input"}'
        return 0
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/netshift-preview.XXXXXX")" || {
        echo '{"error":"bad_input"}'
        return 0
    }
    mkdir -p "$tmp_dir/save"
    cp "$NETSHIFT_CONFIG" "$tmp_dir/netshift" 2> /dev/null || {
        rm -rf "$tmp_dir"
        echo '{"error":"no_config"}'
        return 0
    }
    if [ "$(uci -q -c "$tmp_dir" -t "$tmp_dir/save" get "netshift.$section" 2> /dev/null)" != "section" ]; then
        rm -rf "$tmp_dir"
        echo '{"error":"no_section"}'
        return 0
    fi
    if [ "$(uci -q -c "$tmp_dir" -t "$tmp_dir/save" get "netshift.$section.disabled" 2> /dev/null)" = "1" ]; then
        rm -rf "$tmp_dir"
        echo '{"error":"disabled"}'
        return 0
    fi

    # Only the filter lists may be overridden. -t: uci keeps what it stages in the save
    # directory, which -c does not move; ours is inside the temporary directory.
    keys="$(printf '%s' "$overrides" | jq -r 'keys[] | select(startswith("subscription_filter_"))' 2> /dev/null)"
    for key in $keys; do
        case "$key" in
        *[!a-z_]*) continue ;;
        esac
        uci -q -c "$tmp_dir" -t "$tmp_dir/save" delete "netshift.$section.$key" 2> /dev/null
        printf '%s' "$overrides" | jq -r --arg k "$key" '.[$k][]? | tostring' 2> /dev/null |
            while IFS= read -r value; do
                [ -n "$value" ] && uci -q -c "$tmp_dir" -t "$tmp_dir/save" add_list "netshift.$section.$key=$value"
            done
    done
    uci -q -c "$tmp_dir" -t "$tmp_dir/save" commit netshift 2> /dev/null

    urls_file="$tmp_dir/urls"
    merged_file="$tmp_dir/merged.json"
    printf '%s' '{"outbounds":[]}' > "$merged_file"

    batch="$(
        # a subshell: the configuration loaded here is the preview copy, and the GeoIP switch
        # below does not leak
        UCI_CONFIG_DIR="$tmp_dir" config_load netshift
        include_json="$(build_subscription_filter_json "$section" "subscription_filter_include_keywords" "subscription_filter_include_countries")"
        exclude_json="$(build_subscription_filter_json "$section" "subscription_filter_exclude_keywords" "subscription_filter_exclude_countries")"
        SUBSCRIPTION_PARAM_FILTER="$(build_subscription_param_filter_json "$section")"
        get_subscription_urls_for_section "$section" > "$urls_file"
        subscription_merge_section_feeds "$section" "$urls_file" "$merged_file"
        [ "$SUBSCRIPTION_USABLE_FEED_COUNT" -gt 0 ] || exit 3
        feed_total="$(jq -r '.outbounds | length' "$merged_file" 2> /dev/null)"
        # the flags the real start puts in front of the names (the country filters match them),
        # from the cache only
        if geoip_section_enabled "$section"; then
            GEOIP_CACHE_ONLY=1
            subscription_geoip_annotate "$merged_file"
        fi
        # the servers the core can use at all (no filter), then the ones the filters keep
        SUBSCRIPTION_PARAM_FILTER="{}"
        # the batches carry every kept outbound: hundreds of KB for a large feed, more than one
        # argument of a command may hold (E2BIG past 128 KiB), so they go to jq as files
        sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$merged_file" "[]" "[]" > "$tmp_dir/all.json" || exit 4
        SUBSCRIPTION_PARAM_FILTER="$(build_subscription_param_filter_json "$section")"
        sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$merged_file" "$include_json" "$exclude_json" > "$tmp_dir/batch.json" || exit 4
        jq -c -n --slurpfile all "$tmp_dir/all.json" --slurpfile batch "$tmp_dir/batch.json" --argjson feed "${feed_total:-0}" \
            '{total: ($all[0].names | length), kept: ($batch[0].names | length), unsupported: ($feed - ($all[0].names | length)), names: $batch[0].names}'
    )"
    local rc=$?
    rm -rf "$tmp_dir"

    if [ "$rc" -ne 0 ] || [ -z "$batch" ]; then
        echo '{"error":"no_cache"}'
        return 0
    fi
    printf '%s\n' "$batch"
}
