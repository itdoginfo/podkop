# shellcheck shell=ash
#
# Subscription account info: traffic used, quota and expiry that panels report in
# the `subscription-userinfo` response header (the de-facto standard of Clash,
# sing-box and Xray clients), plus the optional profile title.
#
# The body download goes through wget, which cannot show response headers, so after
# a successful refresh one more request is made with curl and only its headers are
# read. It never fails a refresh: a panel that does not send the header (or does not
# answer) simply has no info. Nothing but the numbers and the title is stored,
# never a URL (neither the subscription link, which carries the account token, nor the
# web page the panel names); the file is readable by root only.

SUBSCRIPTION_INFO_TIMEOUT=10

get_subscription_info_cache_path() {
    local section="$1"
    local urlhash="$2"

    echo "$SUBSCRIPTION_CACHE_FOLDER/${section}${urlhash:+.$urlhash}.info.json"
}

# Reads one `key=value` pair of a header like "upload=1; download=2; total=3; expire=4".
subscription_userinfo_value() {
    local header="$1"
    local key="$2"

    printf '%s' "$header" | tr ';' '\n' | sed -n "s/^[[:space:]]*$key=[[:space:]]*\\([0-9][0-9]*\\)[[:space:]]*\$/\\1/p" | sed -n '1p'
}

# The profile title: plain text, or "base64:<text>" as some panels send it.
subscription_profile_title() {
    local value="$1"

    case "$value" in
    base64:*) printf '%s' "${value#base64:}" | base64 -d 2> /dev/null ;;
    *) printf '%s' "$value" ;;
    esac
}

# Reads the response headers in a file and prints the info as one JSON object, or
# nothing when the panel sent no usable `subscription-userinfo`.
subscription_info_from_headers() {
    local headers_file="$1"
    local userinfo title upload download total expire

    userinfo="$(tr -d '\r' < "$headers_file" | sed -n 's/^[Ss]ubscription-[Uu]serinfo:[[:space:]]*//p' | sed -n '$p')"
    [ -n "$userinfo" ] || return 1

    upload="$(subscription_userinfo_value "$userinfo" upload)"
    download="$(subscription_userinfo_value "$userinfo" download)"
    total="$(subscription_userinfo_value "$userinfo" total)"
    expire="$(subscription_userinfo_value "$userinfo" expire)"
    # a header with none of the numbers is not usable
    [ -n "$upload$download$total$expire" ] || return 1

    title="$(tr -d '\r' < "$headers_file" | sed -n 's/^[Pp]rofile-[Tt]itle:[[:space:]]*//p' | sed -n '$p')"
    title="$(subscription_profile_title "$title" | tr -d '\n' | cut -c1-80)"
    jq -n -c \
        --arg upload "$upload" --arg download "$download" --arg total "$total" --arg expire "$expire" \
        --arg title "$title" \
        '{
            upload: (if $upload == "" then null else ($upload | tonumber) end),
            download: (if $download == "" then null else ($download | tonumber) end),
            total: (if $total == "" then null else ($total | tonumber) end),
            expire: (if $expire == "" then null else ($expire | tonumber) end),
            title: (if $title == "" then null else $title end)
        }'
}

# Asks the panel for its headers again and stores the info.
#   $1 section, $2 URL, $3 URL hash, $4 User-Agent, $5 service proxy address,
#   $6 insecure (1 = skip certificate check)
# Always returns 0.
subscription_refresh_info() {
    local section="$1"
    local url="${2%%#*}"
    local urlhash="$3"
    local user_agent="$4"
    local proxy="$5"
    local insecure="$6"
    local headers_file info path tmp

    command -v curl > /dev/null 2>&1 || return 0
    ensure_subscription_cache_dir > /dev/null 2>&1 || return 0

    headers_file="$(mktemp "${TMPDIR:-/tmp}/netshift-subinfo.XXXXXX")" || return 0

    # -L: the body is downloaded through wget, which follows redirects, so the headers of the
    # FINAL answer are the ones that belong to the subscription (a panel that answers 302 to a
    # CDN sends them there); the parser takes the last block.
    set -- -s -L --max-redirs 5 -m "$SUBSCRIPTION_INFO_TIMEOUT" -D "$headers_file" -o /dev/null \
        -A "${user_agent:-singbox}" \
        -H "X-HWID: $(generate_hwid)" -H "X-Device-OS: OpenWrt Linux" \
        -H "X-Device-Model: $(get_device_model)" -H "X-Ver-OS: $(get_kernel_version)" \
        -H "Accept-Language: ru-RU,en,*" -H "X-Device-Locale: EN"
    [ "$insecure" = "1" ] && set -- "$@" -k
    [ -n "$proxy" ] && set -- "$@" -x "http://$proxy"

    if ! curl "$@" "$url" > /dev/null 2>&1 || ! info="$(subscription_info_from_headers "$headers_file")" || [ -z "$info" ]; then
        rm -f "$headers_file"
        log "Subscription info is not available for section '$section'" "debug"
        return 0
    fi
    rm -f "$headers_file"

    path="$(get_subscription_info_cache_path "$section" "$urlhash")"
    tmp="$path.tmp.$$"
    if (umask 077 && printf '%s\n' "$info" > "$tmp") && mv "$tmp" "$path"; then
        chmod 600 "$path" 2> /dev/null
    else
        rm -f "$tmp"
    fi
    return 0
}

# JSON for the dashboard: {"<section>": [{upload, download, total, expire, title}, ...]},
# one entry per feed of the section. A file that cannot be read is left out; the others stay.
get_subscription_info() {
    local file name section next result="{}"

    [ -d "$SUBSCRIPTION_CACHE_FOLDER" ] || {
        echo "{}"
        return 0
    }

    for file in "$SUBSCRIPTION_CACHE_FOLDER"/*.info.json; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        section="${name%%.*}"
        next="$(printf '%s' "$result" | jq -c --arg section "$section" --slurpfile info "$file" \
            '.[$section] = ((.[$section] // []) + $info)' 2> /dev/null)" || continue
        result="$next"
    done

    printf '%s\n' "$result"
}
