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

# Decodes a URL-encoded string
url_decode() {
    local encoded="$1"
    printf '%b' "$(echo "$encoded" | sed 's/+/ /g; s/%/\\x/g')"
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
    *:*) echo "${url#*:}" ;;
    *) echo "" ;;
    esac
}

# Extracts the path from a URL (without query or fragment; returns "/" if empty)
url_get_path() {
    local url="$1"
    echo "$url" | sed -n -e 's#^[^:/?]*://##' -e 's#^[^/]*##' -e 's#\([^?]*\).*#\1#p'
}

# Extracts the value of a specific query parameter from a URL
url_get_query_param() {
    local url="$1"
    local param="$2"

    local raw
    raw=$(echo "$url" | sed -n "s/.*[?&]$param=\([^&?#]*\).*/\1/p")

    [ -z "$raw" ] && echo "" && return

    echo "$raw"
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
# Parses a whitespace-separated string, validates items as either domains
# or IPv4 addresses/subnets, and returns a comma-separated string of valid items.
# Arguments:
#   $1 - Input string (space-separated list of items)
#   $2 - Type of validation ("domains" or "subnets")
# Outputs:
#   Comma-separated string of valid domains or subnets
#######################################
parse_domain_or_subnet_string_to_commas_string() {
    local string="$1"
    local type="$2"

    tmpfile=$(mktemp)
    printf "%s\n" "$string" | sed 's/\/\/.*//' | tr ', ' '\n' | grep -v '^$' > "$tmpfile"

    result="$(parse_domain_or_subnet_file_to_comma_string "$tmpfile" "$type")"
    rm -f "$tmpfile"

    echo "$result"
}

#######################################
# Parses a file line by line, validates entries as either domains or subnets,
# and returns a single comma-separated string of valid items.
# Arguments:
#   $1 - Path to the input file
#   $2 - Type of validation ("domains" or "subnets")
# Outputs:
#   Comma-separated string of valid domains or subnets
#######################################
parse_domain_or_subnet_file_to_comma_string() {
    local filepath="$1"
    local type="$2"

    local result
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$line" ] && continue

        case "$type" in
        domains)
            if ! is_domain_suffix "$line"; then
                log "'$line' is not a valid domain" "debug"
                continue
            fi
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

# Returns the sing-box version number (e.g. "1.12.0")
get_sing_box_version() {
    local version=""
    if command -v sing-box >/dev/null 2>&1; then
        version="$(sing-box version 2>/dev/null | head -n1 | awk '{print $NF}')"
    fi
    echo "${version:-1.0}"
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
    local url="$1"
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
    local url="$1"
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
# (security/sni/fp/pbk/sid/flow/type/path/host/mode/alpn), so they flow through
# the existing sing_box_cf_add_proxy_outbound path unchanged. The outbound tag
# (or the config `remarks`) becomes the URI fragment so the node keeps a
# human-readable name.
#
# CRITICAL: OpenWRT's jq has no Oniguruma, so the program below uses only
# explicit string operations (no test/match/sub/gsub). It also keeps every
# query VALUE free of '& ? # %' and whitespace, because url_get_query_param()
# (helpers.sh) stops a value at the first such delimiter.
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

        [ $configs[]
          | (.remarks // "") as $cfg_name
          | (.outbounds // [])[]
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
          | ($ob.tag // $cfg_name) as $name
          # Build the query param list per protocol, dropping empties.
          | (
              if $ob.protocol == "vless" then
                ([ "encryption=none",
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
          | { conn: $conn,
              uri: ($conn + (if $name != "" then "#" + $name else "" end)) }
        ]
        # Deduplicate on $conn, preserving first-seen order (no sort): a
        # label/break reduce over already-seen keys. Avoids unique_by (which
        # reorders) and stays within the no-regex jq subset on OpenWRT.
        | reduce .[] as $e ({ seen: [], out: [] };
            if (.seen | index($e.conn)) != null then .
            else .seen += [$e.conn] | .out += [$e.uri] end)
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
    local line scheme idx kept skipped before_count after_count final_count
    local fragment display_name first_char xray_uris xray_unsupported

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

    while IFS= read -r line; do
        # Trim leading/trailing whitespace.
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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
        display_name=""
        if [ -n "$fragment" ]; then
            # url_decode handles %20 / percent-escaped UTF-8 (flag emoji etc.).
            display_name="$(url_decode "$fragment" 2>/dev/null)"
            # Drop control characters/newlines that would corrupt the tag.
            display_name="$(printf '%s' "$display_name" | tr -d '\r\n\t')"
        fi
        [ -n "$display_name" ] || display_name="${section}-fb${idx}"

        before_count="$(printf '%s' "$config" | jq -r '.outbounds | length' 2>/dev/null)"
        [ -n "$before_count" ] || before_count=0

        # Second guard: run the builder in a subshell (command substitution) so
        # an unexpected exit 1 (e.g. malformed URI) is contained and surfaced as
        # a non-zero rc. Redirect its stdin from /dev/null so its internal
        # pipelines cannot consume the loop's input.
        new_config="$(sing_box_cf_add_proxy_outbound "$config" "${section}-fb${idx}" "$line" "$udp_over_tcp" </dev/null 2>/dev/null)" || {
            log "skip unparsable subscription key #$idx for '$section'" "debug"
            idx=$(( idx + 1 ))
            continue
        }
        idx=$(( idx + 1 ))

        # Validate the result parses as JSON and the outbound count increased.
        if [ -z "$new_config" ] || ! printf '%s' "$new_config" | jq -e . >/dev/null 2>&1; then
            log "skip subscription key (invalid JSON result) for '$section'" "debug"
            continue
        fi
        after_count="$(printf '%s' "$new_config" | jq -r '.outbounds | length' 2>/dev/null)"
        [ -n "$after_count" ] || after_count=0
        if [ "$after_count" -le "$before_count" ]; then
            log "skip subscription key (no outbound added) for '$section'" "debug"
            continue
        fi

        # Re-apply the human-readable name as the tag of the just-added outbound
        # (the builder appends it last). Deduplicate against tags already present
        # so identical remarks across keys stay unique and valid for sing-box and
        # the dashboard (which displays the tag verbatim via the Clash API).
        new_config="$(
            printf '%s' "$new_config" | jq -c --arg name "$display_name" '
                ([.outbounds[:-1][].tag // empty]) as $existing
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
        )"
        if [ -z "$new_config" ] || ! printf '%s' "$new_config" | jq -e . >/dev/null 2>&1; then
            log "skip subscription key (tag rename failed) for '$section'" "debug"
            continue
        fi

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
