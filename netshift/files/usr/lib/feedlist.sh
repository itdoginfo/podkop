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
    esac | grep -E '^https?://[^[:space:]]+$' | awk '!seen[$0]++' | head -n "$FEED_LIST_MAX_URLS"
}

# fetch_feed_list <url>: {"ok":true,"urls":[...]} or {"ok":false,"error":"..."}
fetch_feed_list() {
    local url="$1"
    local body urls

    case "$url" in
    http://* | https://*) ;;
    *)
        jq -n -c '{ok: false, error: "the address of the list must start with http:// or https://"}'
        return 1
        ;;
    esac

    if ! body="$(updates_http_get "$url")" || [ -z "$body" ]; then
        jq -n -c '{ok: false, error: "the list could not be downloaded"}'
        return 1
    fi

    urls="$(printf '%s' "$body" | feed_list_parse)"
    if [ -z "$urls" ]; then
        jq -n -c '{ok: false, error: "no feed addresses were found in the list"}'
        return 1
    fi

    printf '%s\n' "$urls" | jq -R -s -c '{ok: true, urls: (split("\n") | map(select(length > 0)))}'
}
