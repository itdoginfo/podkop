# shellcheck shell=ash
#
# A list of subscription feeds: a published list names many feeds (a text file with a
# URL per line, or a JSON object whose keys are the URLs), and adding them one by one
# by hand is the part nobody wants to do. The page asks for the URLs of such a list and
# puts them into the section's subscription_url list.

FEED_LIST_MAX_URLS=200
FEED_LIST_MAX_BYTES=2000000

# Reads a list on stdin, prints one http(s) URL per line, without repeats.
feed_list_parse() {
    local body first

    body="$(head -c "$FEED_LIST_MAX_BYTES")"
    first="$(printf '%s' "$body" | sed -n '1{s/^[[:space:]]*//;s/\(.\).*/\1/p;};1q')"

    case "$first" in
    '{')
        printf '%s' "$body" | jq -r 'keys_unsorted[]' 2> /dev/null
        ;;
    '[')
        printf '%s' "$body" | jq -r '.[] | strings' 2> /dev/null
        ;;
    *)
        printf '%s\n' "$body" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^#'
        ;;
    esac | grep -Ei '^https?://[^[:space:]]+$' | awk '!seen[$0]++' | head -n "$FEED_LIST_MAX_URLS"
}

# Stream at most the limit plus one byte into a private file. A FIFO lets us
# preserve the HTTP client's exit status as well as reject oversized responses.
feed_list_fetch_once() {
    local url="$1" proxy="$2" output="$3" fifo="$4" pid rc size

    rm -f "$fifo"
    mkfifo "$fifo" || return 1
    updates_http_get_once "$url" "$proxy" > "$fifo" &
    pid=$!
    if head -c "$((FEED_LIST_MAX_BYTES + 1))" < "$fifo" > "$output"; then
        rc=0
    else
        rc=1
    fi
    wait "$pid" || rc=1
    rm -f "$fifo"
    size="$(wc -c < "$output" | tr -d ' ')"
    [ "$rc" -eq 0 ] && [ "$size" -gt 0 ] && [ "$size" -le "$FEED_LIST_MAX_BYTES" ]
}

# fetch_feed_list <url>: {"ok":true,"urls":[...]} or {"ok":false,"error":"..."}
fetch_feed_list() {
    local url="$1"
    local urls feed_workdir proxy

    # Same rule as a subscription address, including HTTPS:// (the case below was
    # the only one that required a lower-case scheme).
    # Same rule as a subscription address, including HTTPS:// (the case below was
    # the only one that required a lower-case scheme).
    if ! subscription_url_is_http "$url"; then
        jq -n -c '{ok: false, error: "the address of the list must start with http:// or https://"}'
        return 1
    fi

    feed_workdir="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/netshift-feed-list.XXXXXX")" || return 1
    proxy="$(updates_components_proxy_address)"
    if { [ -z "$proxy" ] || ! feed_list_fetch_once "$url" "$proxy" "$feed_workdir/body" "$feed_workdir/fifo"; } &&
        ! feed_list_fetch_once "$url" "" "$feed_workdir/body" "$feed_workdir/fifo"; then
        rm -rf "$feed_workdir"
        jq -n -c '{ok: false, error: "the list could not be downloaded"}'
        return 1
    fi

    urls="$(feed_list_parse < "$feed_workdir/body")"
    rm -rf "$feed_workdir"
    if [ -z "$urls" ]; then
        jq -n -c '{ok: false, error: "no feed addresses were found in the list"}'
        return 1
    fi

    printf '%s\n' "$urls" | jq -R -s -c '{ok: true, urls: (split("\n") | map(select(length > 0)))}'
}
