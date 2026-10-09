# shellcheck shell=ash
# Check if string is valid IPv4
is_ipv4() {
    local ip="$1"
    local regex='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.?){4}$'
    echo "$ip" | grep -Eq "$regex"
}

# Check if string is valid IPv4 with CIDR mask
is_ipv4_cidr() {
    local ip="$1"
    local regex='^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.?){4}(/(3[0-2]|2[0-9]|1[0-9]|[0-9]))$'
    echo "$ip" | grep -Eq "$regex"
}

is_ipv4_ip_or_ipv4_cidr() {
    is_ipv4 "$1" || is_ipv4_cidr "$1"
}

# Check if string is a valid IPv6 address: the full form, the compressed `::`
# form, IPv4-embedded (2001:db8::192.0.2.33) and IPv4-mapped (::ffff:1.2.3.4)
# forms. Zone indices (fe80::1%eth0) are deliberately not supported: they are
# meaningless in an ECS prefix, and such a value is skipped with a warning
# rather than reaching the config.
is_ipv6() {
    local ip="$1"
    local regex='^(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|::(ffff(:0{1,4})?:)?((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])|([0-9a-fA-F]{1,4}:){1,6}:((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])|([0-9a-fA-F]{1,4}:){5,6}((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9]))$'
    echo "$ip" | grep -Eq "$regex"
}

# Check if string is an IP address or an IP prefix, e.g. '203.0.113.0/24' or
# '2001:db8::/32'. A bare address is accepted, because sing-box appends /32 or
# /128 to it. The prefix length must be canonical decimal (digits only, no
# leading zeros) — that is what sing-box' netip.ParsePrefix requires, and a
# value it rejects makes it reject the WHOLE configuration, so it must be
# filtered out before the value reaches the config. IPv4 is matched with a
# strict regex rather than is_ipv4(), which also accepts '1234' and '1.2.3.4.'
# (both of which sing-box refuses).
is_ip_or_ip_prefix() {
    local value="$1"
    local address prefix max_prefix
    local ipv4_regex='^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'

    case "$value" in
    */*)
        # Exactly one '/' separator.
        case "${value#*/}" in
        */*) return 1 ;;
        esac
        address="${value%%/*}"
        prefix="${value##*/}"
        case "$prefix" in
        '' | *[!0-9]*) return 1 ;;
        0) ;;
        0*) return 1 ;;
        esac
        [ "${#prefix}" -le 3 ] || return 1
        ;;
    *)
        address="$value"
        prefix=""
        ;;
    esac

    if echo "$address" | grep -Eq "$ipv4_regex"; then
        max_prefix=32
    elif is_ipv6 "$address"; then
        max_prefix=128
    else
        return 1
    fi

    [ -z "$prefix" ] && return 0

    [ "$prefix" -le "$max_prefix" ]
}

is_domain() {
    local str="$1"
    local regex='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'

    echo "$str" | grep -Eq "$regex"
}

is_domain_suffix() {
    local str="$1"
    local normalized="${str#.}"

    is_domain "$normalized"
}

# Lowercases a domain name. DNS names are case-insensitive, but is_domain only
# accepts [a-z0-9], so a UCI value typed as "Example.COM" would be dropped
# instead of producing a rule. Every user-supplied domain goes through this
# before validation, so the stored rule is always lowercase (issue #52).
normalize_domain_case() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# Normalizes one domain-rule entry of a list. A bare "example.com" matches the
# domain and all its subdomains. The v2ray-style prefixes narrow or widen that:
#   full:host      the host only (no subdomains)
#   keyword:text   any host containing the text
#   regex:pattern  hosts matching the regular expression (regexp: is accepted too)
# Prints the entry in its canonical form (prefix lowercased, host and keyword
# lowercased, the pattern left as typed: case changes the meaning of \d and \D)
# and returns 1 for anything that is not a valid entry. The pattern itself is
# checked later against the core (validate_domain_regex_file): there is no regex
# engine in jq on OpenWrt.
domain_rule_normalize() {
    local entry="$1"
    local lowered prefix value

    lowered="$(normalize_domain_case "$entry")"
    case "$lowered" in
    full:*) prefix="full" ;;
    keyword:*) prefix="keyword" ;;
    regex:* | regexp:*) prefix="regex" ;;
    *)
        is_domain_suffix "$lowered" || return 1
        printf '%s\n' "$lowered"
        return 0
        ;;
    esac

    value="${entry#*:}"
    case "$prefix" in
    full)
        value="$(normalize_domain_case "$value")"
        is_domain "$value" || return 1
        ;;
    keyword)
        value="$(normalize_domain_case "$value")"
        case "$value" in
        "" | *[!a-z0-9._-]*) return 1 ;;
        esac
        ;;
    regex)
        case "$value" in
        "" | *[[:space:],]*) return 1 ;;
        esac
        [ "${#value}" -le 256 ] || return 1
        ;;
    esac

    printf '%s:%s\n' "$prefix" "$value"
}

# Checks if the given string is a valid base64-encoded sequence
is_base64() {
    local str="$1"

    if echo "$str" | base64 -d > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Checks if the given string looks like a Shadowsocks userinfo
is_shadowsocks_userinfo_format() {
    local str="$1"
    local regex='^[^:]+:[^:]+(:[^:]+)?$'

    echo "$str" | grep -Eq "$regex"
}

# Compares the current package version with the required minimum
is_min_package_version() {
    local current="$1"
    local required="$2"

    local lowest
    lowest="$(printf '%s\n' "$current" "$required" | sort -V | head -n1)"

    [ "$lowest" = "$required" ]
}

# Checks if the given file exists
file_exists() {
    local filepath="$1"

    if [ -f "$filepath" ]; then
        return 0
    else
        return 1
    fi
}

# Checks if a service script exists in /etc/init.d
service_exists() {
    local service="$1"

    if [ -x "/etc/init.d/$service" ]; then
        return 0
    else
        return 1
    fi
}

# Returns the inbound tag name by appending the postfix to the given section
get_inbound_tag_by_section() {
    local section="$1"
    local postfix="in"

    echo "$section-$postfix"
}

# Returns the outbound tag name by appending the postfix to the given section
get_outbound_tag_by_section() {
    local section="$1"
    local postfix="out"

    echo "$section-$postfix"
}

# Constructs and returns a domain resolver tag by appending a fixed postfix to the given section
get_domain_resolver_tag() {
    local section="$1"
    local postfix="domain-resolver"

    echo "$section-$postfix"
}

# Converts a comma-separated string into a JSON array string
comma_string_to_json_array() {
    local input="$1"

    if [ -z "$input" ]; then
        echo "[]"
        return
    fi

    local replaced
    replaced=$(printf '%s' "$input" | sed 's/,/","/g')

    echo "[\"$replaced\"]"
}

# Decodes the '%XX' escapes of a single, already-split URI component.
# A '%' NOT followed by two hex digits is data and is left untouched (a blind
# 's/%/\\x/g' would turn it into garbage), and a literal backslash is doubled so
# printf cannot read it as an escape sequence of its own.
_url_percent_decode() {
    local encoded="$1"

    # Nothing to decode: skip the sed fork (hot path, called per query param).
    case "$encoded" in
    *%* | *\\*) ;;
    *)
        printf '%s' "$encoded"
        return 0
        ;;
    esac

    printf '%b' "$(printf '%s' "$encoded" | sed 's/\\/\\\\/g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

# Decodes a URL-encoded string using application/x-www-form-urlencoded rules,
# where '+' means a space (the convention proxy clients use for query values).
url_decode() {
    case "$1" in
    *+*) _url_percent_decode "$(printf '%s' "$1" | sed 's/+/ /g')" ;;
    *) _url_percent_decode "$1" ;;
    esac
}

# Decodes a single URI component (RFC 3986 percent-encoding). Unlike url_decode,
# a literal '+' is PRESERVED: in a URI userinfo/password '+' is data, not a
# space, so rewriting it would corrupt the credentials.
# The caller MUST split the link into components first and decode them one by
# one — decoding a whole link turns an escaped '%40'/'%23' inside a password
# into a structural '@'/'#', which splits the link in the wrong place or cuts
# off everything after the '#'.
url_decode_component() {
    _url_percent_decode "$1"
}

# Returns the scheme (protocol) part of a URL
url_get_scheme() {
    local url="$1"
    echo "${url%%://*}"
}

# Extracts the userinfo (username[:password]) part from a URL
url_get_userinfo() {
    local url="$1"
    echo "$url" | sed -n -e 's#^[^:/?]*://##' -e '/@/!d' -e 's/@.*//p'
}

# Extracts the host part from a URL
url_get_host() {
    local url="$1"

    url="${url#*://}"
    url="${url#*@}"
    url="${url%%[/?#]*}"

    case "$url" in
    \[*\]) echo "${url#\[}" | sed 's/\]$//' ;;
    \[*\]*) echo "${url#\[}" | sed 's/\].*//' ;;
    *) echo "${url%%:*}" ;;
    esac
}

# Extracts the port number from a URL
url_get_port() {
    local url="$1"

    url="${url#*://}"
    url="${url#*@}"
    url="${url%%[/?#]*}"

    case "$url" in
    \[*\]:*) echo "${url##*]:}" ;;
    # A bracketed IPv6 literal without a port is not "host:port".
    \[*\]) echo "" ;;
    *:*) echo "${url#*:}" ;;
    *) echo "" ;;
    esac
}

# Extracts the path from a URL (without query or fragment; returns "/" if empty)
url_get_path() {
    local url="$1"
    echo "$url" | sed -n -e 's#^[^:/?]*://##' -e 's#^[^/]*##' -e 's#\([^?]*\).*#\1#p'
}

# Extracts the value of a specific query parameter from a URL.
# The caller passes the RAW (still encoded) link: the value is decoded HERE,
# once its boundaries are known, so an escaped '&' or '#' inside a value can no
# longer be mistaken for a delimiter and truncate it.
url_get_query_param() {
    local url="$1"
    local param="$2"

    local raw
    raw=$(_url_get_query_param_raw "$url" "$param")

    [ -z "$raw" ] && echo "" && return

    url_decode "$raw"
}

# Like url_get_query_param, but decodes the value as a URI component: a literal
# '+' stays '+' instead of becoming a space. For opaque tokens such as keys,
# where '+' is data and a space would silently corrupt the value.
url_get_query_param_component() {
    local url="$1"
    local param="$2"

    local raw
    raw=$(_url_get_query_param_raw "$url" "$param")

    [ -z "$raw" ] && echo "" && return

    url_decode_component "$raw"
}

# Returns the still-encoded value of a query parameter from a RAW link.
# Pure shell (no sed fork): '##' takes the last "[?&]<param>=" like the
# greedy sed it replaces.
_url_get_query_param_raw() {
    local rest="${1##*[?&]"$2"=}"

    [ "$rest" != "$1" ] || return 0
    printf '%s\n' "${rest%%[&?#]*}"
}

# Extracts the basename (filename without extension) from a URL
url_get_basename() {
    local url="$1"

    local filename="${url##*/}"
    local basename="${filename%%.*}"

    echo "$basename"
}

# Extracts and returns the file extension from the given URL
url_get_file_extension() {
    local url="$1"

    local basename="${url##*/}"
    case "$basename" in
    *.*) echo "${basename##*.}" ;;
    *) echo "" ;;
    esac
}

# Remove url fragment (everything after the first '#')
url_strip_fragment() {
    local url="$1"

    echo "${url%%#*}"
}

# Decodes and returns a base64-encoded string
base64_decode() {
    local str="$1"
    local decoded_url

    decoded_url="$(echo "$str" | base64 -d 2> /dev/null)"

    echo "$decoded_url"
}

# Decodes a vmess:// share link (V2RayN base64(JSON) form) into its JSON object.
# Strips the vmess:// scheme prefix, base64-decodes the remainder, and echoes the
# decoded text (expected to be a JSON object; the caller validates with jq -e).
# Returns empty output when the input is not a base64(JSON) VMess link.
#
# IMPORTANT: this decodes the WHOLE payload as STANDARD base64 (alphabet
# includes '+'), so the caller MUST pass the RAW pre-url_decode link — passing a
# url_decode'd link rewrites '+'->space and corrupts the body.
# Arguments:
#   $1 - the vmess:// link (raw, pre-url_decode)
vmess_link_to_json() {
    local url="$1"
    local payload decoded pad_len

    payload="${url#vmess://}"
    # Strip a trailing '#fragment' (server display name / remark, like vless/ss/
    # trojan). The base64 body never contains '#', so cutting at the FIRST '#'
    # is safe; a fragment-less payload is a no-op. The canonical VMess name lives
    # in the decoded JSON `ps` field, so we only need to drop the fragment here.
    payload="${payload%%#*}"
    [ -n "$payload" ] || return 0

    # Normalize: strip whitespace (space, tab, CR, LF via octal escapes — busybox
    # `tr` does NOT understand the POSIX `[:space:]` class and would instead
    # delete those literal characters, corrupting the base64), then right-pad to
    # a multiple of 4 with '=' so BusyBox `base64 -d` (which can reject missing
    # padding) accepts real-world unpadded links.
    payload="$(printf '%s' "$payload" | tr -d ' \011\012\015')"
    pad_len=$(( ${#payload} % 4 ))
    if [ "$pad_len" -ne 0 ]; then
        pad_len=$(( 4 - pad_len ))
        while [ "$pad_len" -gt 0 ]; do
            payload="${payload}="
            pad_len=$(( pad_len - 1 ))
        done
    fi

    decoded="$(base64_decode "$payload")"
    echo "$decoded"
}

# Generates a unique 16-character ID based on the current timestamp and a random number
gen_id() {
    { date +%s; head -c 16 /dev/urandom; } | md5sum | cut -c1-16
}

# Adds a missing UCI option with the given value if it does not exist
migration_add_new_option() {
    local package="$1"
    local section="$2"
    local option="$3"
    local value="$4"

    local current
    current="$(uci -q get "$package.$section.$option")"
    if [ -z "$current" ]; then
        log "Adding missing option '$option' with value '$value'"
        uci set "$package.$section.$option=$value"
        uci commit "$package"
        return 0
    else
        return 1
    fi
}

# Migrates a configuration key in an OpenWrt config file from old_key_name to new_key_name
migration_rename_config_key() {
    local config="$1"
    local key_type="$2"
    local old_key_name="$3"
    local new_key_name="$4"

    if grep -q "$key_type $old_key_name" "$config"; then
        log "Deprecated $key_type found: $old_key_name migrating to $new_key_name"
        sed -i "s/$key_type $old_key_name/$key_type $new_key_name/g" "$config"
    fi
}

# Like config_list_foreach, but also works for an option that is NOT a UCI list.
#
# config_list_foreach iterates ONLY list values: it reads the
# <option>_LENGTH / <option>_ITEMn variables that uci_load creates for a `list`.
# For a scalar option (`uci set netshift.settings.routing_excluded_ips=10.0.0.5`,
# a hand-edited file, a config written by a script or by an older version) those
# variables do not exist, so the callback was called ZERO times and the value was
# silently ignored — while config_get still returns it. PROVEN against OpenWrt's
# /lib/functions.sh and on hardware. The shape is decided up front with the same
# <option>_LENGTH variable config_list_foreach itself uses, so list items are never
# re-split on whitespace; only a scalar value is word-split (the same fallback
# get_subscription_urls_for_section has always had for a scalar subscription_url).
# Usage: netshift_config_list_foreach <section> <option> <handler> [args...]
# The handler is called as `<handler> <item> [args...]`.
netshift_config_list_foreach() {
    local section="$1"
    local option="$2"
    local handler="$3"
    local len raw item

    shift 3

    config_get len "$section" "${option}_LENGTH"
    if [ -n "$len" ]; then
        config_list_foreach "$section" "$option" "$handler" "$@"
        return 0
    fi

    config_get raw "$section" "$option"
    [ -n "$raw" ] || return 0
    for item in $raw; do
        "$handler" "$item" "$@"
    done
}

# Download URL to file
redact_url_for_log() {
    local url="$1"
    local scheme rest authority suffix userinfo_flag path_flag query_flag fragment_flag

    scheme=""
    rest="$url"
    userinfo_flag=0
    path_flag=0
    query_flag=0
    fragment_flag=0

    case "$url" in
    *'#'*) fragment_flag=1 ;;
    esac
    rest="${rest%%#*}"

    case "$url" in
    *\?*) query_flag=1 ;;
    esac
    rest="${rest%%\?*}"

    case "$rest" in
    *://*)
        scheme="${rest%%://*}://"
        rest="${rest#*://}"
        ;;
    esac

    authority="${rest%%/*}"
    if [ "$authority" != "$rest" ]; then
        path_flag=1
    fi

    case "$authority" in
    *@*)
        userinfo_flag=1
        authority="${authority##*@}"
        ;;
    esac

    suffix=""
    [ "$path_flag" -eq 1 ] && suffix="$suffix/<redacted>"
    [ "$query_flag" -eq 1 ] && suffix="$suffix?<redacted>"
    [ "$fragment_flag" -eq 1 ] && suffix="$suffix#<redacted>"

    if [ -z "$authority" ]; then
        printf 'redacted-url(has_path=%s,has_query=%s,has_userinfo=%s,has_fragment=%s)\n' \
            "$path_flag" "$query_flag" "$userinfo_flag" "$fragment_flag"
        return 0
    fi

    printf '%s%s%s(has_path=%s,has_query=%s,has_userinfo=%s,has_fragment=%s)\n' \
        "$scheme" "$authority" "$suffix" "$path_flag" "$query_flag" "$userinfo_flag" "$fragment_flag"
}

url_host_for_log() {
    local url="$1"
    local host

    host="${url#*://}"
    host="${host%%/*}"
    host="${host%%\?*}"
    host="${host%%#*}"
    host="${host##*@}"

    case "$host" in
    \[*\]*)
        host="${host#\[}"
        host="${host%%\]*}"
        ;;
    *)
        host="${host%%:*}"
        ;;
    esac

    printf '%s\n' "$host"
}

url_is_ipv6_literal() {
    case "$1" in
    *://\[*\]*) return 0 ;;
    esac
    return 1
}

wget_supports_ipv4_flag() {
    wget --help 2>&1 | grep -Eq -- 'Use IPv4 only|(^|[[:space:]])-4([[:space:],]|$)'
}

has_ipv4_default_route() {
    ip -4 route show default 2>/dev/null | grep -q '^default'
}

has_ipv6_default_route() {
    ip -6 route show default 2>/dev/null | grep -q '^default'
}

has_global_ipv6_addr() {
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
}

ipv6_route_usable() {
    ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1
}

ipv6_appears_usable() {
    has_ipv6_default_route && has_global_ipv6_addr && ipv6_route_usable
}

get_wget_ipv4_mode() {
    local mode
    config_get mode "settings" "wget_ipv4_mode" "auto" 2>/dev/null
    case "$mode" in
    off | force | auto) echo "$mode" ;;
    *) echo "auto" ;;
    esac
}

should_force_wget_ipv4() {
    local url="$1"
    local mode

    url_is_ipv6_literal "$url" && return 1
    wget_supports_ipv4_flag || return 1

    mode="$(get_wget_ipv4_mode)"
    case "$mode" in
    off)
        return 1
        ;;
    force)
        has_ipv4_default_route
        return $?
        ;;
    auto | *)
        has_ipv4_default_route || return 1
        ipv6_appears_usable && return 1
        return 0
        ;;
    esac
}

format_wget_error() {
    local errfile="$1"
    local url="$2"
    local message

    message="$(tr '\n' ' ' < "$errfile" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-220)"
    message="$(printf '%s' "$message" | sed 's#[Hh][Tt][Tt][Pp][Ss]\{0,1\}://[^[:space:]]*#<redacted-url>#g')"
    [ -n "$message" ] || message="no stderr from wget"
    printf '%s\n' "$message"
}

wget_error_class() {
    local err="$1"

    if echo "$err" | grep -qi 'Operation not permitted'; then
        echo "operation_not_permitted"
    elif echo "$err" | grep -qi 'not an http or ftp url\|bad address\|unable to resolve\|Name or service not known'; then
        echo "dns_or_bad_url"
    elif echo "$err" | grep -qi 'timed out\|timeout'; then
        echo "timeout"
    elif echo "$err" | grep -qi 'certificate\|SSL\|TLS'; then
        echo "tls"
    elif echo "$err" | grep -qi '404\|403\|401\|500\|502\|503\|HTTP'; then
        echo "http"
    else
        echo "unknown"
    fi
}

log_wget_failure() {
    local operation="$1"
    local url="$2"
    local errfile="$3"
    local rc="$4"
    local attempt="$5"
    local retries="$6"
    local timeout="$7"
    local http_proxy_address="$8"
    local family="$9"
    local mode err host err_class

    if [ -n "$http_proxy_address" ]; then
        mode="proxy $http_proxy_address"
    else
        mode="direct"
    fi

    err="$(format_wget_error "$errfile" "$url")"
    host="$(url_host_for_log "$url")"
    err_class="$(wget_error_class "$err")"

    log "$operation failed [$attempt/$retries]: wget rc=$rc, mode=$mode, family=$family, timeout=${timeout}s, host=${host:-unknown}, url=$(redact_url_for_log "$url"), error_class=$err_class, error=\"$err\"" "warn"
    if echo "$err" | grep -qi 'Operation not permitted'; then
        log "$operation got 'Operation not permitted'. On OpenWrt this can indicate firewall, routing, or IPv6 preference issues; netshift will retry with IPv4 when supported." "warn"
    fi
}

download_to_file() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"
    local timeout="${6:-10}"
    local attempt errfile rc family

    for attempt in $(seq 1 "$retries"); do
        errfile="${filepath}.wget.err.$$"
        family="any"
        if should_force_wget_ipv4 "$url"; then
            family="ipv4"
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" wget -4 -T "$timeout" -O "$filepath" "$url" 2>"$errfile"
            else
                wget -4 -T "$timeout" -O "$filepath" "$url" 2>"$errfile"
            fi
        elif [ -n "$http_proxy_address" ]; then
            http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" wget -T "$timeout" -O "$filepath" "$url" 2>"$errfile"
        else
            wget -T "$timeout" -O "$filepath" "$url" 2>"$errfile"
        fi
        rc=$?
        if [ "$rc" -eq 0 ]; then
            rm -f "$errfile"
            return 0
        fi

        log_wget_failure "Download" "$url" "$errfile" "$rc" "$attempt" "$retries" "$timeout" "$http_proxy_address" "$family"
        rm -f "$errfile"

        if [ "$family" != "ipv4" ] && has_ipv4_default_route && wget_supports_ipv4_flag; then
            errfile="${filepath}.wget.err.$$"
            log "Retrying download over IPv4-only after generic wget failure" "warn"
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" wget -4 -T "$timeout" -O "$filepath" "$url" 2>"$errfile"
            else
                wget -4 -T "$timeout" -O "$filepath" "$url" 2>"$errfile"
            fi
            rc=$?
            if [ "$rc" -eq 0 ]; then
                rm -f "$errfile"
                return 0
            fi
            log_wget_failure "Download IPv4 retry" "$url" "$errfile" "$rc" "$attempt" "$retries" "$timeout" "$http_proxy_address" "ipv4"
            rm -f "$errfile"
        fi

        [ "$attempt" -lt "$retries" ] && sleep "$wait"
    done

    return 1
}

# Converts Windows-style line endings (CRLF) to Unix-style (LF)
convert_crlf_to_lf() {
    local filepath="$1"

    if grep -q "$(printf '\r')" "$filepath"; then
        log "File '$filepath' contains CRLF line endings. Converting to LF..." "debug"
        local tmpfile
        tmpfile=$(mktemp)
        tr -d '\r' < "$filepath" > "$tmpfile" && mv "$tmpfile" "$filepath" || rm -f "$tmpfile"
    fi
}

# Best-effort, in-place gzip decompression of a downloaded subscription body.
#
# Some panels unconditionally return a gzip-compressed HTTP body (busybox wget
# does NOT transparently decompress and we send no Accept-Encoding), so the raw
# bytes are binary and every downstream consumer (validate/normalize) chokes.
# This decompresses once at download time so all consumers see text.
#
# Detection is attempt-based (no od/hexdump/xxd, none of which exist on device):
# we try `gzip -dc` (busybox built-in) into a temp file and accept the result
# ONLY if (a) gzip returned 0, (b) the result is non-empty, and (c) the result
# is NUL-free. gzip -dc on plain-text input returns rc!=0 cleanly, so a
# plain-text body is left byte-for-byte untouched; this can never corrupt text.
# Modeled on convert_crlf_to_lf: mktemp -> transform -> mv on success / rm on
# failure. Best-effort: always returns 0 (never aborts the caller).
maybe_gunzip_subscription_file() {
    local filepath="$1"
    local tmpfile

    [ -s "$filepath" ] || return 0

    tmpfile=$(mktemp)
    if gzip -dc "$filepath" > "$tmpfile" 2>/dev/null &&
        [ -s "$tmpfile" ] &&
        ! subscription_body_is_binary "$tmpfile"; then
        log "Decompressed gzip subscription body for '$filepath'" "debug"
        mv "$tmpfile" "$filepath"
    else
        rm -f "$tmpfile"
    fi

    return 0
}

# Returns 0 (true) if the file contains at least one NUL byte (i.e. it is
# binary / undecodable, not text). Busybox-safe, no od/hexdump/xxd: `tr -d`
# strips NUL bytes and we compare the resulting byte count to the original; a
# difference means a NUL was present. All vars local.
subscription_body_is_binary() {
    local filepath="$1"
    local raw_count stripped_count

    [ -s "$filepath" ] || return 1

    raw_count="$(wc -c < "$filepath" 2>/dev/null | tr -d ' ')"
    stripped_count="$(tr -d '\000' < "$filepath" 2>/dev/null | wc -c 2>/dev/null | tr -d ' ')"

    [ -n "$raw_count" ] || raw_count=0
    [ -n "$stripped_count" ] || stripped_count=0

    [ "$raw_count" != "$stripped_count" ]
}

#######################################
# Parses a comma- or whitespace-separated string, validates items as either
# domains or IPv4 addresses/subnets, and returns a comma-separated string of
# valid items. Items may be separated by commas or by any ASCII whitespace —
# space, tab, CR, LF, VT, FF — which is the same set the UI splits on
# (parseValueList uses /[,\s]+/), so a list pasted from a spreadsheet or a TSV
# column is not silently collapsed into one invalid item.
# Arguments:
#   $1 - Input string (comma- and/or whitespace-separated list of items)
#   $2 - Type of validation ("domains" or "subnets")
# Outputs:
#   Comma-separated string of valid domains or subnets
#######################################
parse_domain_or_subnet_string_to_commas_string() {
    local string="$1"
    local type="$2"

    tmpfile=$(mktemp)
    # Busybox `tr` has no POSIX `[:space:]` class (it would read the bracket
    # expression as a literal character list), so the whitespace characters are
    # spelled out as octal escapes.
    printf "%s\n" "$string" | sed 's/\/\/.*//' | tr ', \011\012\013\014\015' '\n' | grep -v '^$' > "$tmpfile"

    result="$(parse_domain_or_subnet_file_to_comma_string "$tmpfile" "$type")"
    rm -f "$tmpfile"

    echo "$result"
}

#######################################
# Parses a file line by line, validates entries as either domains or subnets,
# and returns a single comma-separated string of valid items. Domains are
# lowercased before validation (DNS is case-insensitive), so mixed-case input
# such as "Example.COM" yields a rule instead of being discarded.
# Arguments:
#   $1 - Path to the input file
#   $2 - Type of validation ("domains" or "subnets")
# Outputs:
#   Comma-separated string of valid domains or subnets
#######################################
parse_domain_or_subnet_file_to_comma_string() {
    local filepath="$1"
    local type="$2"

    local result normalized
    while IFS= read -r line; do
        line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        case "$type" in
        domains)
            if ! normalized="$(domain_rule_normalize "$line")"; then
                log "'$line' is not a valid domain" "debug"
                continue
            fi
            line="$normalized"
            ;;
        subnets)
            if ! is_ipv4 "$line" && ! is_ipv4_cidr "$line"; then
                log "'$line' is not IPv4 or IPv4 CIDR" "debug"
                continue
            fi
            ;;
        *)
            log "Unknown type: $type" "error"
            return 1
            ;;
        esac

        if [ -z "$result" ]; then
            result="$line"
        else
            result="$result,$line"
        fi
    done < "$filepath"

    echo "$result"
}

# Returns the device model from OpenWrt sysinfo, or "OpenWrt Router" as fallback
get_device_model() {
    local model=""
    if [ -f /tmp/sysinfo/model ]; then
        model="$(cat /tmp/sysinfo/model 2>/dev/null)"
    fi
    echo "${model:-OpenWrt Router}"
}

# Returns the Linux kernel version
get_kernel_version() {
    uname -r
}

# Returns the total RAM in megabytes (MemTotal from /proc/meminfo), or 0 when
# it cannot be read. Integer division is fine here: the value feeds the UI
# and the lite build warning threshold, not an exact resource accounting.
get_ram_total_mb() {
    local kb

    kb="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\)[[:space:]]*kB$/\1/p' /proc/meminfo 2>/dev/null | head -n 1)"
    case "$kb" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo $((kb / 1024)) ;;
    esac
}

# Returns the free space on the root filesystem in megabytes (df -Pk /), or 0
# when it cannot be read. The overlay the core lives on is what this measures.
get_flash_free_mb() {
    local kb

    kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
    case "$kb" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo $((kb / 1024)) ;;
    esac
}

# Returns the sing-box version number (e.g. "1.12.0")
#
# A loop that asks for the version once per link can resolve it once instead:
#   local NETSHIFT_SING_BOX_VERSION
#   NETSHIFT_SING_BOX_VERSION="$(get_sing_box_version)"
# Everything it calls, command-substitution subshells included, then reuses
# the value rather than spawning `sing-box version` again; `local` keeps it
# from outliving the loop (a sing-box upgrade must be seen by the next run).
get_sing_box_version() {
    if [ -n "${NETSHIFT_SING_BOX_VERSION:-}" ]; then
        echo "$NETSHIFT_SING_BOX_VERSION"
        return
    fi

    local version=""
    if command -v sing-box >/dev/null 2>&1; then
        # "sing-box version 1.13.14-extended-2.5.0": take the word after
        # "version", so a build that appends more words to the line still
        # reports its version; fall back to the last word.
        version="$(sing-box version 2>/dev/null | head -n1 | awk '
            { for (i = 1; i < NF; i++) if ($i == "version") { print $(i + 1); exit }
              print $NF }')"
    fi
    echo "${version:-1.0}"
}

# Returns 0 if the given (or detected) sing-box core is at least the given
# upstream release. Only the part in front of the first "-" is compared, so
# "1.14.1-extended-2.7.2-lite" counts as 1.14.1 whatever the fork adds after it;
# an undetectable core reports "1.0" and fails every gate.
# Arguments:
#   $1 - minimum upstream release (e.g. "1.14.0")
#   $2 - optional sing-box version string (defaults to get_sing_box_version)
is_sing_box_at_least() {
    local required="$1"
    local version="${2:-}"

    [ -n "$version" ] || version="$(get_sing_box_version)"

    is_min_package_version "${version%%-*}" "$required"
}

# Returns 0 if the given (or detected) sing-box version is an "extended" build
# Arguments:
#   $1 - optional sing-box version string (defaults to get_sing_box_version)
is_sing_box_extended() {
    local version="${1:-}"

    [ -n "$version" ] || version="$(get_sing_box_version)"

    case "$version" in
    *extended*) return 0 ;;
    esac

    return 1
}

# Returns 0 if the given (or detected) sing-box version is an "extended" build
# at or above the given extended release. Extended cores report e.g.
# "1.13.14-extended-2.5.0": the part after "-extended-" is the fork's own
# release, and fields are added there independently of the upstream version in
# front of it (v1.13.11-extended-1.6.2 exists and still lacks VLESS
# Encryption, which arrived in extended-2.0.0, see
# SB_EXTENDED_VLESS_ENCRYPTION_MIN). Stock cores always fail.
# Only the release part of that suffix is compared: `sort -V` would rank
# "2.0.0-rc.1" above "2.0.0", the reverse of semver, so the pre-release tag is
# dropped instead. Pre-releases of the required release therefore pass, and
# that is deliberate here: VLESS Encryption already ships in 2.0.0-rc.1. The
# lite suffix is a pre-release-style tag too ("2.7.2-lite"), so
# "1.14.1-extended-2.7.2-lite" compares as 2.7.2 and its gate features
# (VLESS Encryption, XHTTP, vmess) are the extended ones.
# Arguments:
#   $1 - minimum extended release (e.g. "2.0.0")
#   $2 - optional sing-box version string (defaults to get_sing_box_version)
is_sing_box_extended_at_least() {
    local required="$1"
    local version="${2:-}"
    local release

    [ -n "$version" ] || version="$(get_sing_box_version)"

    is_sing_box_extended "$version" || return 1
    release="${version##*-extended-}"
    is_min_package_version "${release%%-*}" "$required"
}

# Returns 0 if the given file exists, is a regular file and starts with "#!"
# (a shell wrapper script rather than an ELF binary). Two bytes via
# `head -c` are the cheapest reliable tell; od/hexdump are avoided on purpose.
is_sing_box_wrapper_script() {
    local path="$1"

    [ -f "$path" ] || return 1
    [ "$(head -c 2 "$path" 2>/dev/null)" = "#!" ]
}

# Prints the installed sing-box core variant: "stock", "extended" or
# "extended_lite".
#   (a) the version banner carries the lite suffix -> extended_lite (both our
#       ELF and UPX installs report "1.14.1-extended-2.7.2-lite");
#   (b) /usr/bin/sing-box is a shell wrapper AND the side-loaded core exists
#       -> extended_lite. This is the UPX layout, shared with the community
#       manual installs (MANCrimSon/EikeiDev), whose wrapper may report a
#       version WITHOUT the suffix — the layout is authoritative then;
#   (c) the version carries "extended" -> extended (the full fork build);
#   (d) otherwise -> stock.
# Arguments:
#   $1 - optional sing-box version string (defaults to get_sing_box_version)
get_sing_box_variant() {
    local version="${1:-}"

    [ -n "$version" ] || version="$(get_sing_box_version)"

    case "$version" in
    *"$SB_LITE_SUFFIX"*)
        echo "extended_lite"
        return 0
        ;;
    esac

    if [ -f "$UPDATES_SING_BOX_LITE_CORE_BIN" ] &&
        is_sing_box_wrapper_script "$UPDATES_SING_BOX_BIN"; then
        echo "extended_lite"
        return 0
    fi

    if is_sing_box_extended "$version"; then
        echo "extended"
        return 0
    fi

    echo "stock"
}

# Returns 0 when the installed lite core is the UPX-compressed build: the
# variant is extended_lite and /usr/bin/sing-box is the wrapper script (a
# pure ELF lite install puts the binary itself on that path).
sing_box_lite_is_upx() {
    [ "$(get_sing_box_variant)" = "extended_lite" ] || return 1

    is_sing_box_wrapper_script "$UPDATES_SING_BOX_BIN"
}

# Returns 0 when the extended lite release has a build for this machine's
# architecture. The lite repo publishes exactly five generic builds —
# amd64, arm64, armv7, mips-softfloat, mipsle-softfloat — so everything the
# extended resolver maps otherwise (armv6, 386, mips64*, riscv64, s390x and
# the OpenWrt .ipk fallback for FPU-less ARM) has no lite counterpart. The
# resolver is defined in updater.sh (sourced after helpers.sh); it is only
# ever called here at runtime, by which time it is defined.
sing_box_lite_arch_supported() {
    updates_resolve_sing_box_extended_arch_suffix || return 1

    case "$SB_EXT_ARCH_SUFFIX" in
    amd64 | arm64 | armv7 | mips-softfloat | mipsle-softfloat) return 0 ;;
    esac

    return 1
}

# Returns 0 if the value is a VLESS Encryption client string that
# sing-box-extended accepts, i.e. passes both parseClientEncryption and
# ClientInstance.Init in the fork:
#   "mlkem768x25519plus.<native|xorpub|random>.<0rtt|1rtt>." then segments;
#   a segment that base64url-decodes must be a key of exactly 32 bytes
#   (X25519, any value) or 1184 bytes (ML-KEM-768: every 12-bit coefficient
#   below q = 3329); one that does not decode is padding "N-N-N", allowed only
#   before the first key, with the limits of ParsePadding; at least one key.
# A value this accepts is one the core accepts too, so a '+' turned into a
# space, a stray '%', a key cut short by one character or a corrupted key is
# caught here instead of failing `sing-box check` — and with it the whole
# config — later on. No od/hexdump on device: base64 is decoded in awk.
# Arguments:
#   $1 - encryption value from a vless:// link
is_valid_vless_encryption() {
    local value="$1"
    local rest

    # Only [A-Za-z0-9._-] ever occurs: keys are base64.RawURLEncoding and the
    # parts are joined by dots. No empty part either.
    case "$value" in
    '' | *[!A-Za-z0-9._-]* | *..* | *.) return 1 ;;
    esac

    rest="${value#mlkem768x25519plus.}"
    [ "$rest" != "$value" ] || return 1

    case "$rest" in
    native.* | xorpub.* | random.*) ;;
    *) return 1 ;;
    esac
    rest="${rest#*.}"

    case "$rest" in
    0rtt.?* | 1rtt.?*) ;;
    *) return 1 ;;
    esac
    rest="${rest#*.}"

    # Within [A-Za-z0-9_-] unpadded base64url fails to decode only when the
    # length is 1 mod 4; otherwise it decodes into floor(3*len/4) bytes, and
    # 32 / 1184 bytes are exactly 43 / 1579 characters.
    printf '%s\n' "$rest" | awk -F. '
        function b64(c) {
            return index("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", c) - 1
        }
        # Go crypto/mlkem: the first 1152 bytes (1536 characters) pack 768
        # 12-bit coefficients, two per 3 bytes, each of which must be < 3329.
        function mlkem_ok(s,    i, x0, x1, x2, x3, b0, b1, b2) {
            for (i = 1; i <= 1536; i += 4) {
                x0 = b64(substr(s, i, 1)); x1 = b64(substr(s, i + 1, 1))
                x2 = b64(substr(s, i + 2, 1)); x3 = b64(substr(s, i + 3, 1))
                b0 = x0 * 4 + int(x1 / 16)
                b1 = (x1 % 16) * 16 + int(x2 / 4)
                b2 = (x2 % 4) * 64 + x3
                if (b0 + (b1 % 16) * 256 >= 3329) return 0
                if (int(b1 / 16) + b2 * 16 >= 3329) return 0
            }
            return 1
        }
        # ParsePadding: "len-min-max" (more parts are ignored), the first one
        # at least 100-35-35, the sum of max(min, max) over the even ones at
        # most 18 + 65535.
        function padding_ok(s, idx,    n, x, k) {
            n = split(s, x, "-")
            if (n < 3) return 0
            for (k = 1; k <= 3; k++)
                if (x[k] !~ /^[0-9]+$/ || length(x[k]) > 18) return 0
            if (idx == 0 && (x[1] + 0 < 100 || x[2] + 0 < 35 || x[3] + 0 < 35)) return 0
            if (idx % 2 == 0) total += (x[2] + 0 > x[3] + 0) ? x[2] + 0 : x[3] + 0
            return 1
        }
        {
            keys = 0; pads = 0; total = 0
            for (f = 1; f <= NF; f++) {
                len = length($f)
                if (len % 4 == 1) {
                    if (keys > 0 || !padding_ok($f, pads)) exit 1
                    pads++
                    continue
                }
                if (len == 43 || (len == 1579 && mlkem_ok($f))) { keys++; continue }
                exit 1
            }
            exit (keys > 0 && total <= 18 + 65535) ? 0 : 1
        }'
}

# Generates a deterministic HWID based on WAN MAC address and device model
# Format: xxxx-xxxx-xxxx-xxxx
# Same router always produces the same HWID
generate_hwid() {
    local mac="" model="" raw_hash=""

    # Try to get WAN MAC address
    if [ -f /sys/class/net/eth0/address ]; then
        mac="$(cat /sys/class/net/eth0/address 2>/dev/null)"
    elif [ -f /sys/class/net/br-lan/address ]; then
        mac="$(cat /sys/class/net/br-lan/address 2>/dev/null)"
    fi

    model="$(get_device_model)"

    # Generate hash from MAC + model
    raw_hash="$(printf '%s-%s' "$mac" "$model" | md5sum | cut -c1-16)"

    # Format as xxxx-xxxx-xxxx-xxxx
    printf '%s-%s-%s-%s' \
        "$(echo "$raw_hash" | cut -c1-4)" \
        "$(echo "$raw_hash" | cut -c5-8)" \
        "$(echo "$raw_hash" | cut -c9-12)" \
        "$(echo "$raw_hash" | cut -c13-16)"
}

# Resolves the effective subscription User-Agent: the explicit value when one
# is given, otherwise the default "singbox/<version>" string. Centralizes the
# default so download_subscription and the candidate builder agree.
get_subscription_user_agent() {
    local custom_user_agent="${1:-}"

    if [ -n "$custom_user_agent" ]; then
        printf '%s' "$custom_user_agent"
        return 0
    fi

    printf 'singbox/%s' "$(get_sing_box_version)"
}

# Emits the ordered, de-duplicated list of User-Agent candidates (one per line)
# to try for a subscription source when no User-Agent is explicitly configured.
# Different panels key the returned body format off the User-Agent, so we probe
# a whitelist of well-known clients and let the caller keep the first that
# yields valid outbounds.
#
# Arguments:
#   $1 - configured User-Agent (empty for auto mode)
#   $2 - preferred User-Agent (e.g. the previously cached winner; tried early)
#   $3 - format preference: "auto" (default) | "xray" | "singbox". Reorders the
#        auto-mode candidates so the preferred FORMAT's UA is probed first; the
#        probe loop still keeps the first body that yields valid outbounds.
# Behavior:
#   - configured non-empty: emit ONLY that value (respect the user's choice;
#     an explicit UA always outranks the format preference).
#   - auto/empty/unrecognised: emit "singbox/<ver>", then the preferred one,
#     then the whitelist (SUBSCRIPTION_USER_AGENT_CANDIDATES) — today's order.
#   - xray: emit the Xray-JSON UAs (SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES)
#     FIRST (outranking the cached winner + default), then "singbox/<ver>",
#     then the preferred one, then the rest of the whitelist.
#   - singbox: same as auto (singbox/<ver> first); the explicit name for the
#     current default ordering.
#   All orderings are de-duplicated with the newline "seen" set below.
build_subscription_user_agent_candidates() {
    local configured_user_agent="${1:-}"
    local preferred_user_agent="${2:-}"
    local format_preference="${3:-}"
    local default_user_agent candidate seen

    if [ -n "$configured_user_agent" ]; then
        printf '%s\n' "$configured_user_agent"
        return 0
    fi

    default_user_agent="$(get_subscription_user_agent)"
    seen=""

    # Order the auto-mode candidate stream by the requested format preference.
    # "xray" front-loads the Xray-JSON-yielding UAs (so they outrank the cached
    # winner and the default); "singbox"/"auto"/empty/unknown keep today's order
    # (default UA -> cached winner -> whitelist). Any unknown value falls through
    # to the default ordering (forward-compatible).
    if [ "$format_preference" = "xray" ]; then
        # shellcheck disable=SC2086 # word-splitting of the candidate lists is intentional
        set -- $SUBSCRIPTION_USER_AGENT_XRAY_CANDIDATES "$default_user_agent" "$preferred_user_agent" $SUBSCRIPTION_USER_AGENT_CANDIDATES
    else
        # shellcheck disable=SC2086 # word-splitting of the candidate list is intentional
        set -- "$default_user_agent" "$preferred_user_agent" $SUBSCRIPTION_USER_AGENT_CANDIDATES
    fi

    for candidate in "$@"; do
        [ -n "$candidate" ] || continue
        # Skip a candidate already emitted. Wrap stored names in newlines so the
        # substring test matches whole entries only.
        case "$seen" in
        *"
$candidate
"*) continue ;;
        esac
        seen="${seen}
$candidate
"
        printf '%s\n' "$candidate"
    done
}

# Runs a single wget subscription request with the shared client-mimicking
# headers and an optional --no-check-certificate flag, so all branches of
# download_subscription stay byte-identical.
# Arguments:
#   $1       - cert flag ("" or "--no-check-certificate")
#   $2       - User-Agent header value
#   $3       - X-HWID header value
#   $4       - X-Device-Model header value
#   $5       - X-Ver-OS header value
#   $6       - output file path (passed to wget -O)
#   $7       - error file path (wget stderr is redirected here)
#   $8       - subscription URL
#   $9..     - leading wget flags (e.g. -4, -T, <timeout>)
# Caller is responsible for exporting http_proxy/https_proxy when needed.
_wget_subscription_request() {
    local cert_flag="$1"
    local req_user_agent="$2"
    local req_hwid="$3"
    local req_device_model="$4"
    local req_kernel_version="$5"
    local req_outfile="$6"
    local req_errfile="$7"
    local req_url="$8"
    shift 8

    # shellcheck disable=SC2086
    wget $cert_flag "$@" -O "$req_outfile" \
        --header "User-Agent: $req_user_agent" \
        --header "X-HWID: $req_hwid" \
        --header "X-Device-OS: OpenWrt Linux" \
        --header "X-Device-Model: $req_device_model" \
        --header "X-Ver-OS: $req_kernel_version" \
        --header "Accept-Language: ru-RU,en,*" \
        --header "X-Device-Locale: EN" \
        "$req_url" 2>"$req_errfile"
}

# Downloads a subscription body from the given URL with client-mimicking headers
# Arguments:
#   $1 - subscription URL
#   $2 - output file path
#   $3 - http proxy address (optional)
#   $4 - retries (optional, default 3)
#   $5 - wait between retries (optional, default 2)
#   $6 - timeout seconds (optional, default 10)
#   $7 - User-Agent (optional; default "singbox/<version>")
#   $8 - insecure (optional, default 0; when 1 adds --no-check-certificate)
download_subscription() {
    # The #fragment only names the feed on the dashboard. uclient-fetch puts it
    # into the request line verbatim (checked on OpenWrt 25.12), where a panel
    # would read it as part of the path/token, so it is cut off here.
    local url="${1%%#*}"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"
    local timeout="${6:-10}"
    local user_agent="${7:-}"
    local insecure="${8:-0}"

    local sb_version device_model kernel_version hwid
    sb_version="$(get_sing_box_version)"
    device_model="$(get_device_model)"
    kernel_version="$(get_kernel_version)"
    hwid="$(generate_hwid)"
    [ -n "$user_agent" ] || user_agent="$(get_subscription_user_agent)"

    # Optional TLS-verification bypass for IP-host panels with broken certs.
    # Empty string keeps the secure default; word-splitting it into the wget
    # argv (via _wget_subscription_request) yields zero extra args when off.
    local cert_flag=""
    if [ "$insecure" = "1" ]; then
        cert_flag="--no-check-certificate"
    fi

    local tmpfile errfile rc family
    tmpfile="${filepath}.part.$$"
    errfile="${filepath}.err.$$"
    rm -f "$tmpfile" "$errfile"

    for attempt in $(seq 1 "$retries"); do
        family="any"
        if should_force_wget_ipv4 "$url"; then
            family="ipv4"
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    _wget_subscription_request "$cert_flag" "$user_agent" "$hwid" \
                        "$device_model" "$kernel_version" "$tmpfile" "$errfile" "$url" \
                        -4 -T "$timeout"
            else
                _wget_subscription_request "$cert_flag" "$user_agent" "$hwid" \
                    "$device_model" "$kernel_version" "$tmpfile" "$errfile" "$url" \
                    -4 -T "$timeout"
            fi
        else
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    _wget_subscription_request "$cert_flag" "$user_agent" "$hwid" \
                        "$device_model" "$kernel_version" "$tmpfile" "$errfile" "$url" \
                        -T "$timeout"
            else
                _wget_subscription_request "$cert_flag" "$user_agent" "$hwid" \
                    "$device_model" "$kernel_version" "$tmpfile" "$errfile" "$url" \
                    -T "$timeout"
            fi
        fi

        rc=$?
        if [ "$rc" -eq 0 ] && [ -s "$tmpfile" ]; then
            if ! mv "$tmpfile" "$filepath"; then
                log "Subscription download succeeded but failed to move temporary file to destination" "error"
                rm -f "$tmpfile" "$errfile"
                return 1
            fi
            rm -f "$errfile"
            return 0
        fi

        if [ "$rc" -eq 0 ] && [ ! -s "$tmpfile" ]; then
            log "Subscription download returned success but produced an empty file: host=$(url_host_for_log "$url"), url=$(redact_url_for_log "$url")" "warn"
        fi

        rm -f "$tmpfile"
        log_wget_failure "Subscription download" "$url" "$errfile" "$rc" "$attempt" "$retries" "$timeout" "$http_proxy_address" "$family"

        if [ "$family" != "ipv4" ] && has_ipv4_default_route && wget_supports_ipv4_flag; then
            family="ipv4"
            log "Retrying subscription download over IPv4-only" "warn"
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    _wget_subscription_request "$cert_flag" "$user_agent" "$hwid" \
                        "$device_model" "$kernel_version" "$tmpfile" "$errfile" "$url" \
                        -4 -T "$timeout"
            else
                _wget_subscription_request "$cert_flag" "$user_agent" "$hwid" \
                    "$device_model" "$kernel_version" "$tmpfile" "$errfile" "$url" \
                    -4 -T "$timeout"
            fi
            rc=$?
            if [ "$rc" -eq 0 ] && [ -s "$tmpfile" ]; then
                if ! mv "$tmpfile" "$filepath"; then
                    log "Subscription download IPv4 retry succeeded but failed to move temporary file to destination" "error"
                    rm -f "$tmpfile" "$errfile"
                    return 1
                fi
                rm -f "$errfile"
                return 0
            fi
            if [ "$rc" -eq 0 ] && [ ! -s "$tmpfile" ]; then
                log "Subscription download IPv4 retry returned success but produced an empty file: host=$(url_host_for_log "$url"), url=$(redact_url_for_log "$url")" "warn"
            fi
            log_wget_failure "Subscription download IPv4 retry" "$url" "$errfile" "$rc" "$attempt" "$retries" "$timeout" "$http_proxy_address" "$family"
        fi

        sleep "$wait"
    done

    rm -f "$tmpfile"
    rm -f "$errfile"
    log "Subscription download failed after $retries attempts: host=$(url_host_for_log "$url"), url=$(redact_url_for_log "$url")" "error"
    return 1
}

check_subscription_connectivity() {
    # Same as download_subscription: the #fragment must not reach the server.
    local url="${1%%#*}"
    local http_proxy_address="$2"
    local retries="${3:-3}"
    local wait="${4:-2}"
    local timeout="${5:-5}"

    local sb_version device_model kernel_version hwid
    sb_version="$(get_sing_box_version)"
    device_model="$(get_device_model)"
    kernel_version="$(get_kernel_version)"
    hwid="$(generate_hwid)"

    local attempt errfile rc family
    errfile="/tmp/netshift-subscription-check.$$"
    rm -f "$errfile"
    for attempt in $(seq 1 "$retries"); do
        family="any"
        if should_force_wget_ipv4 "$url"; then
            family="ipv4"
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    wget -q -4 -T "$timeout" -O /dev/null \
                        --header "User-Agent: singbox/$sb_version" \
                        --header "X-HWID: $hwid" \
                        --header "X-Device-OS: OpenWrt Linux" \
                        --header "X-Device-Model: $device_model" \
                        --header "X-Ver-OS: $kernel_version" \
                        --header "Accept-Language: ru-RU,en,*" \
                        --header "X-Device-Locale: EN" \
                        "$url" 2>"$errfile"
            else
                wget -q -4 -T "$timeout" -O /dev/null \
                    --header "User-Agent: singbox/$sb_version" \
                    --header "X-HWID: $hwid" \
                    --header "X-Device-OS: OpenWrt Linux" \
                    --header "X-Device-Model: $device_model" \
                    --header "X-Ver-OS: $kernel_version" \
                    --header "Accept-Language: ru-RU,en,*" \
                    --header "X-Device-Locale: EN" \
                    "$url" 2>"$errfile"
            fi
        else
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    wget -q -T "$timeout" -O /dev/null \
                        --header "User-Agent: singbox/$sb_version" \
                        --header "X-HWID: $hwid" \
                        --header "X-Device-OS: OpenWrt Linux" \
                        --header "X-Device-Model: $device_model" \
                        --header "X-Ver-OS: $kernel_version" \
                        --header "Accept-Language: ru-RU,en,*" \
                        --header "X-Device-Locale: EN" \
                        "$url" 2>"$errfile"
            else
                wget -q -T "$timeout" -O /dev/null \
                    --header "User-Agent: singbox/$sb_version" \
                    --header "X-HWID: $hwid" \
                    --header "X-Device-OS: OpenWrt Linux" \
                    --header "X-Device-Model: $device_model" \
                    --header "X-Ver-OS: $kernel_version" \
                    --header "Accept-Language: ru-RU,en,*" \
                    --header "X-Device-Locale: EN" \
                    "$url" 2>"$errfile"
            fi
        fi

        rc=$?
        if [ "$rc" -eq 0 ]; then
            rm -f "$errfile"
            return 0
        fi

        log_wget_failure "Subscription connectivity" "$url" "$errfile" "$rc" "$attempt" "$retries" "$timeout" "$http_proxy_address" "$family"

        if [ "$family" != "ipv4" ] && has_ipv4_default_route && wget_supports_ipv4_flag; then
            family="ipv4"
            if [ -n "$http_proxy_address" ]; then
                http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                    wget -q -4 -T "$timeout" -O /dev/null \
                        --header "User-Agent: singbox/$sb_version" \
                        --header "X-HWID: $hwid" \
                        --header "X-Device-OS: OpenWrt Linux" \
                        --header "X-Device-Model: $device_model" \
                        --header "X-Ver-OS: $kernel_version" \
                        --header "Accept-Language: ru-RU,en,*" \
                        --header "X-Device-Locale: EN" \
                        "$url" 2>"$errfile"
            else
                wget -q -4 -T "$timeout" -O /dev/null \
                    --header "User-Agent: singbox/$sb_version" \
                    --header "X-HWID: $hwid" \
                    --header "X-Device-OS: OpenWrt Linux" \
                    --header "X-Device-Model: $device_model" \
                    --header "X-Ver-OS: $kernel_version" \
                    --header "Accept-Language: ru-RU,en,*" \
                    --header "X-Device-Locale: EN" \
                    "$url" 2>"$errfile"
            fi
            rc=$?
            if [ "$rc" -eq 0 ]; then
                rm -f "$errfile"
                return 0
            fi
            log_wget_failure "Subscription connectivity IPv4 retry" "$url" "$errfile" "$rc" "$attempt" "$retries" "$timeout" "$http_proxy_address" "$family"
        fi

        [ "$attempt" -lt "$retries" ] && sleep "$wait"
    done

    rm -f "$errfile"
    return 1
}

validate_subscription_file() {
    local filepath="$1"

    [ -s "$filepath" ] || return 1

    jq -e '
        type == "object" and
        (.outbounds | type == "array") and
        ([.outbounds[] | select(
            .type != "selector" and
            .type != "urltest" and
            .type != "direct" and
            .type != "dns" and
            .type != "block"
        )] | length > 0)
    ' "$filepath" > /dev/null 2>&1
}

describe_subscription_validation_failure() {
    local filepath="$1"
    local total usable

    if [ ! -s "$filepath" ]; then
        echo "downloaded file is empty"
        return 0
    fi

    if ! jq -e '.' "$filepath" >/dev/null 2>&1; then
        echo "downloaded file is not valid JSON"
        return 0
    fi

    if ! jq -e 'type == "object"' "$filepath" >/dev/null 2>&1; then
        echo "subscription root is not a JSON object"
        return 0
    fi

    if ! jq -e '.outbounds | type == "array"' "$filepath" >/dev/null 2>&1; then
        echo "subscription has no outbounds array"
        return 0
    fi

    total="$(jq -r '.outbounds | length' "$filepath" 2>/dev/null)"
    usable="$(jq -r '[.outbounds[] | select(
        .type != "selector" and
        .type != "urltest" and
        .type != "direct" and
        .type != "dns" and
        .type != "block"
    )] | length' "$filepath" 2>/dev/null)"
    echo "subscription contains no usable proxy outbounds: total=${total:-unknown}, usable=${usable:-unknown}"
}

# Convert an "Xray JSON" subscription body into a newline-separated list of
# proxy share URIs (one per line) that the fallback parser's URI loop can
# consume.
#
# An "Xray JSON" body is what several panels (e.g. the Xray/v2rayN ecosystem)
# hand out instead of a sing-box config: either a single Xray client config
# object or, more commonly, a JSON ARRAY of such objects. Each object carries
# an `outbounds` array whose proxy members use the Xray schema
# (`protocol` + `settings.vnext`/`settings.servers` + `streamSettings`), which
# is NOT the sing-box outbound schema. validate_subscription_file() rejects it
# (its outbounds have no sing-box `type`), so without this converter the whole
# subscription is unusable.
#
# Strategy: for every config object we emit one `vless://` / `trojan://` /
# `ss://` share URI per *directly usable* proxy outbound, i.e. one that does
# NOT declare `streamSettings.sockopt.dialerProxy` (a chained / multi-hop
# upstream that cannot be expressed as a single share link). The resulting URIs
# carry the standard query params the facade already understands
# (encryption/security/sni/fp/pbk/sid/flow/type/path/host/mode/alpn), so they flow through
# the existing sing_box_cf_add_proxy_outbound path unchanged. The outbound tag
# becomes the URI fragment so the node keeps a human-readable name; a generic
# tag ("proxy", "proxy-N" or none) gives way to the config `remarks`
# ("<remarks> · <n>" for members of a multi-node balancer).
#
# CRITICAL: OpenWRT's jq has no Oniguruma, so the program below uses only
# explicit string operations (no test/match/sub/gsub). It also keeps every
# query VALUE free of '& ? # %' and whitespace, because url_get_query_param()
# (helpers.sh) stops a value at the first such delimiter. The one exception is
# the vless `encryption` key, which is percent-encoded (@uri) instead, so it is
# never lost.
#
# Arguments:
#   src_file: path to the raw downloaded subscription body
# Returns:
#   0 and prints the URI lines to stdout when at least one outbound converted;
#   1 (and prints nothing) otherwise.
xray_json_to_uri_lines() {
    local src_file="$1"

    [ -s "$src_file" ] || return 1

    # Quick structural gate before invoking jq: the body must be valid JSON
    # whose (array element | object) carries Xray-style proxy outbounds. We let
    # jq make the authoritative decision and emit the URIs in one pass.
    jq -er '
        # Normalize the document to an array of Xray config objects.
        (if type == "array" then . else [.] end) as $configs

        # A query value is only safe for url_get_query_param when it is present
        # (not JSON null) and carries none of these delimiters/whitespace;
        # otherwise drop the param entirely. NB: a missing Xray field reads as
        # JSON null, and (null | tostring) == "null" — we must treat that as
        # absent, never emit a literal "null" value (e.g. sid=null).
        | def safe($v):
            if $v == null then ""
            else
              ($v | tostring) as $s
              | if ($s == "") then ""
                elif ($s | (index("&") // index("?") // index("#")
                            // index(" ") // index("%")
                            // index("\t") // index("\n"))) != null then ""
                else $s end
            end;

        # Build "key=value" only when value is present and delimiter-safe.
        def kv($k; $v):
            safe($v) as $s
            | if $s == "" then empty else ($k + "=" + $s) end;

        # Number of a generic Happ/Remnawave tag: "proxy" -> 1, "proxy-N" -> N,
        # anything else -> null. Digits only, at most 6 (no regex on OpenWRT).
        def tag_num:
            if . == "proxy" then 1
            elif startswith("proxy-")
                 and (ltrimstr("proxy-") | explode
                      | length > 0 and length <= 6 and all(. >= 48 and . <= 57))
            then ltrimstr("proxy-") | tonumber
            else null end;

        [ $configs[]
          # Whitespace-only remarks count as missing (fall back to the tag).
          | ((.remarks // "") | tostring
             | if explode | all(. <= 32) then "" else . end) as $cfg_name
          | [ (.outbounds // [])[]
              | select(type == "object")
              | select(.protocol == "vless" or .protocol == "trojan"
                       or .protocol == "shadowsocks"
                       or .protocol == "hysteria")
              # Skip chained / multi-hop outbounds: not representable as one URI.
              | select((.streamSettings.sockopt.dialerProxy // "") == "")
              # Hysteria here is always Hysteria2 (hysteriaSettings.version == 2);
              # the facade has no Hysteria v1 parser, so skip v1/missing-version
              # silently (no fatal). vless/trojan/shadowsocks are unaffected.
              | select(.protocol != "hysteria"
                       or ((.streamSettings.hysteriaSettings.version // 0) == 2))
            ] as $usable
          | ($usable | length) as $n_usable
          # Dedup priority, lower wins: a node keeps the name of the smallest
          # group it is listed in; a balancer loses a tie with a plain profile.
          | ((.routing.balancers? // []) as $b
             | $n_usable + (if ($b | type) == "array" and ($b | length) > 0
                            then 1 else 0 end)) as $prio
          # Balancer members are numbered after their provider tag (proxy-3 ->
          # " · 3") unless those numbers are missing or repeat; then by position.
          | [ $usable[] | (.tag // "" | tostring)
              | select(. == "" or tag_num != null) | tag_num ] as $gnums
          | (($gnums | all(. != null))
             and ($gnums | unique | length) == ($gnums | length)) as $by_tag
          | range(0; $n_usable) as $ob_idx
          | $usable[$ob_idx]
          | . as $ob
          | (.streamSettings // {}) as $ss
          # splithttp is the pre-rename name of the xhttp transport (sing-box
          # renamed it). Normalize it to xhttp so the emitted URI uses the modern
          # name and the facade xhttp branch handles it. No regex.
          | ($ss.network // "tcp") as $net_raw
          | (if $net_raw == "splithttp" then "xhttp" else $net_raw end) as $net
          # xhttp transport settings live under xhttpSettings, or the pre-rename
          # splithttpSettings alias.
          | ($ss.xhttpSettings // $ss.splithttpSettings // {}) as $xs
          | ($ss.security // "") as $sec
          | ($ss.realitySettings // {}) as $reality
          | ($ss.tlsSettings // $ss.realitySettings // {}) as $tls
          # Addressing: vnext (vless/vmess) vs servers (trojan/shadowsocks);
          # hysteria carries the peer directly in settings.address/settings.port
          # (no vnext/servers), so branch the peer derivation on protocol.
          | (if $ob.protocol == "hysteria"
             then {address: $ob.settings.address, port: $ob.settings.port}
             else ($ob.settings.vnext[0] // $ob.settings.servers[0] // {}) end) as $peer
          | ($peer.users[0] // {}) as $user
          | ($peer.address // "") as $host
          | ($peer.port // "") as $port
          | select($host != "" and ($port | tostring) != "")
          # Happ/Remnawave tag every outbound "proxy", "proxy-2", ..., so such
          # generic tags give way to `remarks` (balancer members become
          # "<remarks> · <n>"); any other tag is kept as the name. $name_base is
          # what a name collision across configs is renumbered from.
          | ($ob.tag // "" | tostring) as $tag
          | ($tag == "" or ($tag | tag_num) != null) as $generic
          | ($generic and $cfg_name != "" and $n_usable > 1) as $numbered
          | (if ($generic | not) or $cfg_name == "" then $tag
             elif ($numbered | not) then $cfg_name
             else $cfg_name + " · "
                  + ((if $by_tag then $tag | tag_num else $ob_idx + 1 end)
                     | tostring) end) as $name
          | (if $numbered then $cfg_name else $name end) as $name_base
          # Build the query param list per protocol, dropping empties.
          | (
              if $ob.protocol == "vless" then
                # VLESS Encryption keys (mlkem768x25519plus...) live in the
                # user entry; carry them over so the facade can emit them.
                # Plain VLESS has "none" there or no field at all. Unlike the
                # other params the value is percent-encoded rather than
                # dropped by safe(): dropping it would silently turn a PQ node
                # into plain VLESS. The facade decodes it as a URI component
                # and rejects a malformed key loudly.
                ([ ("encryption="
                    + (($user.encryption // "") | tostring
                       | if . == "" then "none" else @uri end)),
                   ("type=" + $net),
                   kv("flow"; $user.flow),
                   (if $sec != "" then ("security=" + $sec) else empty end),
                   kv("sni"; ($tls.serverName // "")) ])
                + (if $sec == "reality" then
                     [ kv("pbk"; $reality.publicKey),
                       kv("sid"; $reality.shortId),
                       kv("fp"; ($reality.fingerprint // "chrome")) ]
                   else
                     [ kv("fp"; ($tls.fingerprint // "")) ]
                   end)
              elif $ob.protocol == "trojan" then
                [ ("type=" + $net),
                  (if $sec != "" then ("security=" + ($sec)) else "security=tls" end),
                  kv("sni"; ($tls.serverName // "")),
                  kv("fp"; ($tls.fingerprint // "")) ]
              elif $ob.protocol == "hysteria" then
                # Hysteria2: no stream transport, so DO NOT emit type=. The
                # facade defaults security to tls for hysteria2 and reads
                # sni/insecure (via _add_outbound_security), obfs/obfs-password.
                ($ss.hysteriaSettings // {}) as $hy
                | [ kv("sni"; ($tls.serverName // "")),
                    (if (($tls.allowInsecure // $tls.insecure // false) == true)
                     then "insecure=1" else empty end) ]
                  + (if ($hy.obfs // "") != "" then
                       [ "obfs=salamander",
                         kv("obfs-password"; ($hy.obfsPassword // $hy.obfs_password // "")) ]
                     else [] end)
              else
                [ ("type=" + $net) ]
              end
            ) as $base
          # Transport-specific params (ws / xhttp / grpc).
          | (
              if $net == "ws" then
                [ kv("path"; ($ss.wsSettings.path // "")),
                  kv("host"; ($ss.wsSettings.headers.Host // "")) ]
              elif $net == "xhttp" then
                # Accept both the modern xhttpSettings and the pre-rename
                # splithttpSettings key (network was normalized to xhttp above).
                # $xs binds to whichever settings object is present.
                [ kv("path"; ($xs.path // "")),
                  kv("host"; ($xs.host // "")),
                  kv("mode"; ($xs.mode // "")) ]
              elif $net == "grpc" then
                [ kv("serviceName"; ($ss.grpcSettings.serviceName // "")) ]
              else [] end
            ) as $transport
          # alpn is a JSON array in Xray; flatten to a comma string (no spaces).
          | ([ ($tls.alpn // [])[] | tostring ] | join(",")) as $alpn_str
          | ($base + $transport
             + (if $alpn_str != "" then [ kv("alpn"; $alpn_str) ] else [] end)
             | map(select(. != null and . != ""))) as $query
          # Credential: uuid for vless, hysteriaSettings.auth for hysteria,
          # password for trojan/shadowsocks.
          | (if $ob.protocol == "vless" then ($user.id // "")
             elif $ob.protocol == "hysteria" then
               ($ss.hysteriaSettings.auth // "")
             else ($peer.password // $ob.settings.password // "") end) as $cred
          | select($cred != "")
          | ($ob.protocol
             | if . == "shadowsocks" then "ss"
               elif . == "hysteria" then "hysteria2"
               else . end) as $scheme
          # The connection part (no #fragment) is the dedup key: providers that
          # ship one server set across many "profiles" repeat identical nodes
          # with only the display name differing, which would otherwise inflate
          # the list into thousands of duplicates.
          | ($scheme + "://" + $cred + "@" + $host + ":" + ($port | tostring)
             + (if ($query | length) > 0 then "?" + ($query | join("&")) else "" end)
            ) as $conn
          | { conn: $conn, prio: $prio, name: $name, base: $name_base }
        ]
        # Deduplicate on $conn in first-seen order (unique_by would reorder),
        # keeping the name with the lowest $prio.
        | reduce .[] as $e ({ idx: {}, out: [] };
            .idx[$e.conn] as $i
            | if $i == null then
                .idx[$e.conn] = (.out | length) | .out += [$e]
              elif $e.prio < .out[$i].prio then .out[$i] = $e
              else . end)
        # Keep names unique across configs: a repeat becomes "<base> · <k>"
        # with the lowest free k >= 2 (two "Auto" balancers -> Auto · 1..4).
        | reduce .out[] as $e ({ used: {}, next: {}, out: [] };
            if $e.name == "" then .out += [$e.conn]
            else
              . as $st
              | (if $st.used[$e.name] | not then {n: $e.name}
                 else
                   first(range($st.next[$e.base] // 2; infinite) as $k
                         | {n: ($e.base + " · " + ($k | tostring)), k: $k}
                         | select($st.used[.n] | not))
                 end) as $pick
              | ($pick.n) as $n
              | (if $pick.k then .next[$e.base] = $pick.k + 1 else . end)
              | .used[$n] = true
              # @uri: a raw hash or plus in the name would not survive the fragment parse.
              | .out += [$e.conn + "#" + ($n | @uri)]
            end)
        | .out
        | select(length > 0)
        | .[]
    ' "$src_file" 2>/dev/null
}

# Count the Xray-JSON proxy outbounds that look like real nodes but use a
# protocol the NetShift facade cannot build (today: vmess — the facade has no
# vmess outbound). These are silently dropped by xray_json_to_uri_lines, so we
# count them separately to surface an explicit warning to the user instead of
# leaving them to wonder why a node count came up short. Chained (dialerProxy)
# outbounds are NOT counted here — those are deliberately collapsed, not
# "unsupported". Prints a single integer (0 when none / on any error).
xray_json_count_unsupported() {
    local src_file="$1"

    [ -s "$src_file" ] || {
        echo 0
        return 0
    }

    jq -er '
        [ (if type == "array" then . else [.] end)[]
          | (.outbounds // [])[]
          | select(type == "object")
          | select((.streamSettings.sockopt.dialerProxy // "") == "")
          | select(.protocol == "vmess")
        ] | length
    ' "$src_file" 2>/dev/null || echo 0
}

# Fallback subscription parser.
#
# Many providers do not return a sing-box JSON config. Instead they return
# either (a) a base64-encoded list of proxy URIs, or (b) a plaintext list of
# proxy URIs (one per line), possibly interspersed with '#comment' metadata
# lines, or (c) an "Xray JSON" config (object or array of objects, handled via
# xray_json_to_uri_lines above). This function decodes/parses such a body into
# a minimal sing-box configuration ({"outbounds":[...]}) so the normal persist
# + merge path can consume it unchanged.
#
# It lives in helpers.sh (alongside validate_subscription_file). It calls
# sing_box_cf_add_proxy_outbound, which is defined later in
# sing_box_config_facade.sh. Shell resolves function names at call time, and
# bin/netshift sources both helpers.sh and the facade before any subscription
# work runs, so both the base64 helpers (defined here) and the URI->outbound
# builder are available when this function is invoked.
#
# Arguments:
#   src_file: path to the raw downloaded subscription body
#   out_file: path to write the normalized sing-box JSON to
#   section:  UCI section name (used to derive outbound tags)
# Returns:
#   0 and writes out_file when at least one outbound was parsed; 1 otherwise.
normalize_subscription_to_singbox() {
    local src_file="$1"
    local out_file="$2"
    local section="$3"

    local raw stripped candidate pad_len decoded bom
    local udp_over_tcp config new_config lines_file
    local line scheme idx kept skipped final_count builder_tag builder_out_tag
    local fragment display_name first_char xray_uris xray_unsupported

    # The normalized body is cached per URL and reused until the next download,
    # so it must not depend on the per-section reality_mlkem option (set by
    # set_section_reality_mlkem): the key share is added when the outbounds are
    # prepared for the config (sing_box_cf_prepare_subscription_batch), where
    # switching the option off or changing the core takes effect immediately.
    local NETSHIFT_REALITY_MLKEM=0

    [ -s "$src_file" ] || return 1
    # Strip a leading UTF-8 BOM (EF BB BF) if present; it would otherwise break
    # base64 charset detection and decoding. busybox sed lacks \x hex escapes,
    # so build the BOM literally with printf octal escapes.
    bom="$(printf '\357\273\277')"
    raw="$(sed "1s/^${bom}//" "$src_file" 2>/dev/null)"
    [ -n "$raw" ] || raw="$(cat "$src_file" 2>/dev/null)"
    [ -n "$raw" ] || return 1

    # Xray-JSON detection (before base64/URI handling). When the body is a JSON
    # object/array of Xray client configs, convert its proxy outbounds to share
    # URIs and feed those through the URI loop below. Only attempt this when the
    # first non-whitespace byte is '{' or '[' (cheap pre-gate) so plaintext URI
    # lists never pay the jq cost.
    first_char="$(printf '%s' "$raw" | sed -n '1{s/^[[:space:]]*//;s/\(.\).*/\1/p;};1q' 2>/dev/null)"
    case "$first_char" in
    '{' | '[')
        xray_uris="$(xray_json_to_uri_lines "$src_file" 2>/dev/null)"
        if [ -n "$xray_uris" ]; then
            log "Detected Xray JSON subscription for '$section'; converting proxy outbounds to share URIs" "debug"
            raw="$xray_uris"
            # Surface unsupported protocols (vmess) explicitly: they are dropped
            # by the converter because the facade cannot build them, and a silent
            # drop looks like a bug to the user.
            xray_unsupported="$(xray_json_count_unsupported "$src_file")"
            case "$xray_unsupported" in
            '' | *[!0-9]*) xray_unsupported=0 ;;
            esac
            if [ "$xray_unsupported" -gt 0 ]; then
                log "Xray JSON subscription for '$section' has $xray_unsupported VMess node(s); VMess is not supported and they were skipped" "warn"
            fi
        fi
        ;;
    esac

    # Decide whether the body is a base64 blob or already plaintext URIs.
    # Be conservative: only treat as base64 when the raw body has NO '://'
    # substring (a plaintext URI list always contains '://') but the decoded
    # body does contain '://'.
    candidate="$raw"
    case "$raw" in
    *"://"*)
        # Raw already contains URIs -> treat as plaintext.
        :
        ;;
    *)
        # Strip all whitespace and check the remaining charset is base64-only.
        stripped="$(printf '%s' "$raw" | tr -d ' \t\r\n')"
        if [ -n "$stripped" ] && [ -z "$(printf '%s' "$stripped" | tr -d 'A-Za-z0-9+/=')" ]; then
            # Add '=' padding to a multiple of 4 (older coreutils-base64 lacks
            # auto-padding).
            pad_len=$(( ${#stripped} % 4 ))
            if [ "$pad_len" -eq 2 ]; then
                stripped="${stripped}=="
            elif [ "$pad_len" -eq 3 ]; then
                stripped="${stripped}="
            elif [ "$pad_len" -eq 1 ]; then
                # Length 1 mod 4 is not valid base64; leave as-is and let
                # decode fail.
                :
            fi
            decoded="$(base64_decode "$stripped")"
            case "$decoded" in
            *"://"*)
                candidate="$decoded"
                ;;
            esac
        fi
        ;;
    esac

    # udp_over_tcp from the section if present, else empty.
    udp_over_tcp="$(uci -q get "netshift.${section}.udp_over_tcp" 2>/dev/null)"

    config='{"outbounds":[]}'
    idx=0
    kept=0
    skipped=0

    # Write candidate lines to a temp file and feed the loop via redirect rather
    # than a heredoc/pipe. The builder calls helpers that read stdin (e.g.
    # base64 pipelines); feeding the loop from the same stdin would let them
    # consume subsequent lines. A file redirect keeps the loop's stdin isolated.
    lines_file="$(mktemp 2>/dev/null)" || lines_file="/tmp/netshift-sub-fb.$$"
    printf '%s\n' "$candidate" > "$lines_file"

    # Resolve the core version once for the whole feed: the builder checks it
    # per link (e.g. VLESS Encryption), and each check would otherwise spawn
    # `sing-box version` again. See get_sing_box_version.
    local NETSHIFT_SING_BOX_VERSION
    NETSHIFT_SING_BOX_VERSION="$(get_sing_box_version)"

    while IFS= read -r line; do
        # Trim leading/trailing whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        # Skip metadata/comment lines.
        case "$line" in
        '#'*)
            continue
            ;;
        esac
        # Pre-filter: only attempt known schemes so an unknown scheme never
        # reaches the builder's fatal path.
        scheme="$(url_get_scheme "$line")"
        case "$scheme" in
        vless | trojan | ss | hysteria2 | hy2 | socks5 | socks4 | socks4a) ;;
        *)
            skipped=$(( skipped + 1 ))
            continue
            ;;
        esac

        # Extract the human-readable name from the URI fragment (the part after
        # the first '#', e.g. vless://...#🇩🇪 Frankfurt). The builder strips the
        # fragment, so we capture it here and re-apply it as the outbound tag
        # below. Fall back to a synthetic name when the fragment is absent.
        case "$line" in
        *"#"*) fragment="${line##*#}" ;;
        *) fragment="" ;;
        esac
        # url_decode handles %20 / percent-escaped UTF-8 (flag emoji etc.).
        display_name=""
        [ -z "$fragment" ] || display_name="$(url_decode "$fragment" 2>/dev/null)"
        builder_tag="${section}-fb${idx}"
        builder_out_tag="$(get_outbound_tag_by_section "$builder_tag")"

        # Second guard: run the builder in a subshell (command substitution) so
        # an unexpected exit 1 (e.g. malformed URI) is contained and surfaced as
        # a non-zero rc. Redirect its stdin from /dev/null so its internal
        # pipelines cannot consume the loop's input.
        new_config="$(sing_box_cf_add_proxy_outbound "$config" "$builder_tag" "$line" "$udp_over_tcp" </dev/null 2>/dev/null)" || {
            log "skip unparsable subscription key #$idx for '$section'" "debug"
            idx=$(( idx + 1 ))
            continue
        }
        idx=$(( idx + 1 ))

        # One jq pass over the whole config per key: it rejects an invalid
        # result or one where the builder appended nothing (the last outbound
        # is not its $builder_out_tag), then re-applies the human-readable name as the
        # tag of the just-added outbound. The name drops control characters
        # and is deduplicated against tags already present so identical
        # remarks stay unique and valid for sing-box and the dashboard (which
        # displays the tag verbatim via the Clash API).
        new_config="$(
            printf '%s' "$new_config" | jq -c --arg name "$display_name" --arg builder_tag "$builder_tag" --arg builder_out_tag "$builder_out_tag" '
                if (.outbounds[-1].tag // null) != $builder_out_tag then error("no outbound added") else . end
                | ($name | explode | map(select(. != 9 and . != 10 and . != 13)) | implode
                   | if . == "" then $builder_tag else . end) as $name
                | ([.outbounds[:-1][].tag // empty]) as $existing
                | (
                    if ($existing | index($name) | not) then $name
                    else
                        (label $found
                            | (range(1; 1000001)
                                | ($name + "-" + (. | tostring)) as $cand
                                | if ($existing | index($cand) | not) then $cand, break $found else empty end))
                    end
                  ) as $tag
                | .outbounds[-1].tag = $tag
            ' 2>/dev/null
        )" && [ -n "$new_config" ] || {
            log "skip subscription key (invalid result or no outbound added) for '$section'" "debug"
            continue
        }

        config="$new_config"
        kept=$(( kept + 1 ))
    done < "$lines_file"
    rm -f "$lines_file"

    if [ "$skipped" -gt 0 ]; then
        log "Fallback subscription parser for '$section' skipped $skipped key(s) with unknown/unsupported schemes" "debug"
    fi

    final_count="$(printf '%s' "$config" | jq -r '.outbounds | length' 2>/dev/null)"
    [ -n "$final_count" ] || final_count=0
    log "Fallback subscription parser for '$section' produced $final_count outbound(s) from $kept accepted key(s)" "debug"
    if [ "$final_count" -le 0 ]; then
        return 1
    fi

    printf '%s' "$config" | jq '.' > "$out_file" 2>/dev/null || return 1
    return 0
}

# Converts an HTTP Date header value ("Sun, 04 Oct 2026 09:13:05 GMT") to epoch
# seconds; prints nothing when it cannot be parsed. busybox date does not read
# this format, so the fields are rearranged for `date -u -d`.
http_date_to_epoch() {
    local value="$1"
    local day month year time month_number

    # "Sun, 04 Oct 2026 09:13:05 GMT" -> day=04 month=Oct year=2026 time=09:13:05
    set -- $(printf '%s' "$value" | tr -d ',')
    [ "$#" -ge 5 ] || return 1
    day="$2"
    month="$3"
    year="$4"
    time="$5"

    case "$month" in
    Jan) month_number=01 ;;
    Feb) month_number=02 ;;
    Mar) month_number=03 ;;
    Apr) month_number=04 ;;
    May) month_number=05 ;;
    Jun) month_number=06 ;;
    Jul) month_number=07 ;;
    Aug) month_number=08 ;;
    Sep) month_number=09 ;;
    Oct) month_number=10 ;;
    Nov) month_number=11 ;;
    Dec) month_number=12 ;;
    *) return 1 ;;
    esac

    case "$year$day" in
    *[!0-9]*) return 1 ;;
    esac

    date -u -d "$year-$month_number-$day $time" +%s 2> /dev/null
}
