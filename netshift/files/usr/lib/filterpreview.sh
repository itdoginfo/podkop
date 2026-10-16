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
# use whatever the filters say (for example xhttp without sing-box-extended) - or {"error": "no_cache"|"bad_input"|"no_config"}.
preview_subscription_filter() {
    local section="$1"
    local overrides="${2:-}"
    local tmp_dir keys key value
    local include_json exclude_json urls_file merged_file batch all_batch feed_total

    # a preview is not an event: the shared code logs what it merges, and every press of the
    # button would fill the log of the router
    log() { :; }
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
        all_batch="$(sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$merged_file" "[]" "[]")" || exit 4
        SUBSCRIPTION_PARAM_FILTER="$(build_subscription_param_filter_json "$section")"
        batch="$(sing_box_cf_prepare_subscription_batch '{"outbounds":[]}' "$merged_file" "$include_json" "$exclude_json")" || exit 4
        jq -c -n --argjson all "$all_batch" --argjson batch "$batch" --argjson feed "${feed_total:-0}" \
            '{total: ($all.names | length), kept: ($batch.names | length), unsupported: ($feed - ($all.names | length)), names: $batch.names}'
    )"
    local rc=$?
    rm -rf "$tmp_dir"

    if [ "$rc" -ne 0 ] || [ -z "$batch" ]; then
        echo '{"error":"no_cache"}'
        return 0
    fi
    printf '%s\n' "$batch"
}
