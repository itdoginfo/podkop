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

# Check if string is valid domain
is_domain() {
    local str="$1"
    echo "$str" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9]))+$'
}

# Checks if the given string is a valid base64-encoded sequence
is_base64() {
    local str="$1"

    if echo "$str" | base64 -d >/dev/null 2>&1; then
        return 0
    fi
    return 1
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

# Extracts and returns the file extension from the given URL
get_url_file_extension() {
    local url="$1"
    local file_extension="${url##*.}"

    echo "$file_extension"
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

# Constructs and returns a ruleset tag using section, name, optional type, and a fixed postfix
get_ruleset_tag() {
    local section="$1"
    local name="$2"
    local type="$3"
    local postfix="ruleset"

    if [ -n "$type" ]; then
        echo "$section-$name-$type-$postfix"
    else
        echo "$section-$name-$postfix"
    fi
}

# Determines the ruleset format based on the file extension (json → source, srs → binary)
get_ruleset_format_by_file_extension() {
    local file_extension="$1"

    local format
    case "$file_extension" in
    json) format="source" ;;
    srs) format="binary" ;;
    *)
        log "Unsupported file extension: .$file_extension"
        return 1
        ;;
    esac

    echo "$format"
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

# Extracts the userinfo (username[:password]) part from a URL
url_get_userinfo() {
    local url="$1"
    echo "$url" | sed -n 's#^[^:]*://\([^@]*\)@.*#\1#p'
}

# Extracts the host part from a URL
url_get_host() {
    local url="$1"
    echo "$url" | sed -n 's#^[^:]*://[^@]*@\([^:/?#]*\).*#\1#p'
}

# Extracts the port number from a URL
url_get_port() {
    local url="$1"
    echo "$url" | sed -n 's#^[^:]*://[^@]*@[^:/?#]*:\([0-9]*\).*#\1#p'
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

# Decodes and returns a base64-encoded string
base64_decode() {
    local str="$1"
    local decoded_url

    decoded_url="$(echo "$str" | base64 -d 2>/dev/null)"

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

# Download URL content directly
download_to_stream() {
    local url="$1"
    local http_proxy_url="$2"

    if [ -n "$http_proxy_url" ]; then
        http_proxy="$http_proxy_url" https_proxy="$http_proxy_url" wget -qO- "$url" | sed 's/\r$//'
    else
        wget -qO- "$url" | sed 's/\r$//'
    fi
}

# Download URL to temporary file
download_to_tempfile() {
    local url="$1"
    local filepath="$2"
    local http_proxy_url="$3"

    if [ -n "$http_proxy_url" ]; then
        http_proxy="$http_proxy_url" https_proxy="$http_proxy_url" wget -O "$filepath" "$url"
    else
        wget -O "$filepath" "$url"
    fi

    if grep -q $'\r' "$filepath"; then
        log "$filename has Windows line endings (CRLF). Converting to Unix (LF)"
        sed -i 's/\r$//' "$filepath"
    fi
}
