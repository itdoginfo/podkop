# Check if string is valid IPv4
is_ipv4() {
    local ip="$1"
    local regex="^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}$"
    [[ "$ip" =~ $regex ]]
}

# Check if string is valid IPv4 with CIDR mask
is_ipv4_cidr() {
    local ip="$1"
    local regex="^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}(\/(3[0-2]|2[0-9]|1[0-9]|[0-9]))$"
    [[ "$ip" =~ $regex ]]
}

is_ipv4_ip_or_ipv4_cidr() {
    is_ipv4 "$1" || is_ipv4_cidr "$1"
}

is_domain() {
    local str="$1"
    local regex='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'

    [[ "$str" =~ $regex ]]
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

    [[ "$str" =~ $regex ]]
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

    if [[ -f "$filepath" ]]; then
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

    local replaced="${input//,/\",\"}"

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

    echo "${url%%:*}"
}

# Extracts the port number from a URL
url_get_port() {
    local url="$1"

    url="${url#*://}"
    url="${url#*@}"
    url="${url%%[/?#]*}"

    [[ "$url" == *:* ]] && echo "${url#*:}" || echo ""
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

# Generates a unique 16-character ID based on the current timestamp and a random number
gen_id() {
    printf '%s%s' "$(date +%s)" "$RANDOM" | md5sum | cut -c1-16
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
download_to_file() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"

    for attempt in $(seq 1 "$retries"); do
        if [ -n "$http_proxy_address" ]; then
            http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" wget -O "$filepath" "$url" && break
        else
            wget -O "$filepath" "$url" && break
        fi

        log "Attempt $attempt/$retries to download $url failed" "warn"
        sleep "$wait"
    done
}

# Converts Windows-style line endings (CRLF) to Unix-style (LF)
convert_crlf_to_lf() {
    local filepath="$1"

    if grep -q $'\r' "$filepath"; then
        log "File '$filepath' contains CRLF line endings. Converting to LF..." "debug"
        local tmpfile
        tmpfile=$(mktemp)
        tr -d '\r' < "$filepath" > "$tmpfile" && mv "$tmpfile" "$filepath" || rm -f "$tmpfile"
    fi
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
        version="$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
    fi
    echo "${version:-1.0}"
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

# Downloads a subscription JSON from the given URL with custom headers
# Arguments:
#   $1 - subscription URL
#   $2 - output file path
#   $3 - http proxy address (optional)
#   $4 - retries (optional, default 3)
#   $5 - wait between retries (optional, default 2)
download_subscription() {
    local url="$1"
    local filepath="$2"
    local http_proxy_address="$3"
    local retries="${4:-3}"
    local wait="${5:-2}"
    local timeout="${6:-10}"

    local sb_version device_model kernel_version hwid
    sb_version="$(get_sing_box_version)"
    device_model="$(get_device_model)"
    kernel_version="$(get_kernel_version)"
    hwid="$(generate_hwid)"

    local tmpfile
    tmpfile="${filepath}.part.$$"
    rm -f "$tmpfile"

    for attempt in $(seq 1 "$retries"); do
        if [ -n "$http_proxy_address" ]; then
            http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                wget -T "$timeout" -t 1 -O "$tmpfile" \
                    --header "User-Agent: singbox/$sb_version" \
                    --header "X-HWID: $hwid" \
                    --header "X-Device-OS: OpenWrt Linux" \
                    --header "X-Device-Model: $device_model" \
                    --header "X-Ver-OS: $kernel_version" \
                    --header "Accept-Language: ru-RU,en,*" \
                    --header "X-Device-Locale: EN" \
                    "$url"
        else
            wget -T "$timeout" -t 1 -O "$tmpfile" \
                --header "User-Agent: singbox/$sb_version" \
                --header "X-HWID: $hwid" \
                --header "X-Device-OS: OpenWrt Linux" \
                --header "X-Device-Model: $device_model" \
                --header "X-Ver-OS: $kernel_version" \
                --header "Accept-Language: ru-RU,en,*" \
                --header "X-Device-Locale: EN" \
                "$url"
        fi

        if [ $? -eq 0 ] && [ -s "$tmpfile" ]; then
            mv "$tmpfile" "$filepath"
            return 0
        fi

        rm -f "$tmpfile"
        log "Attempt $attempt/$retries to download subscription from $url failed" "warn"
        sleep "$wait"
    done

    rm -f "$tmpfile"
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

    local attempt
    for attempt in $(seq 1 "$retries"); do
        if [ -n "$http_proxy_address" ]; then
            http_proxy="http://$http_proxy_address" https_proxy="http://$http_proxy_address" \
                wget -q -T "$timeout" -t 1 -O /dev/null \
                    --header "User-Agent: singbox/$sb_version" \
                    --header "X-HWID: $hwid" \
                    --header "X-Device-OS: OpenWrt Linux" \
                    --header "X-Device-Model: $device_model" \
                    --header "X-Ver-OS: $kernel_version" \
                    --header "Accept-Language: ru-RU,en,*" \
                    --header "X-Device-Locale: EN" \
                    "$url" && return 0
        else
            wget -q -T "$timeout" -t 1 -O /dev/null \
                --header "User-Agent: singbox/$sb_version" \
                --header "X-HWID: $hwid" \
                --header "X-Device-OS: OpenWrt Linux" \
                --header "X-Device-Model: $device_model" \
                --header "X-Ver-OS: $kernel_version" \
                --header "Accept-Language: ru-RU,en,*" \
                --header "X-Device-Locale: EN" \
                "$url" && return 0
        fi

        [ "$attempt" -lt "$retries" ] && sleep "$wait"
    done

    return 1
}

validate_subscription_file() {
    local filepath="$1"

    [ -s "$filepath" ] || return 1

    jq -e '
        type == "object" and
        (.outbounds | type == "array") and
        ((.outbounds | length) > 0)
    ' "$filepath" > /dev/null 2>&1
}
