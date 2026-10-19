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

# Creates a new ruleset JSON file if it doesn't already exist
create_source_rule_set() {
    local ruleset_filepath="$1"

    if file_exists "$ruleset_filepath"; then
        return 3
    fi

    jq -n '{version: 3, rules: []}' > "$ruleset_filepath"
}

#######################################
# Patch a source ruleset JSON file for sing-box by appending a new ruleset object containing the provided key
# and value.
# Arguments:
#   filepath: path to the JSON file to patch
#   key: the ruleset key to insert (e.g., "ip_cidr")
#   value: a JSON array of values to assign to the key
# Example:
#   patch_source_ruleset_rules "/tmp/sing-box/ruleset.json" "ip_cidr" '["1.1.1.1","2.2.2.2"]'
#######################################
patch_source_ruleset_rules() {
    local filepath="$1"
    local key="$2"
    local value="$3"

    local tmpfile=$(mktemp)

    jq --arg key "$key" --argjson value "$value" \
        '( .rules | map(has($key)) | index(true) ) as $idx |
        if $idx != null then
            .rules[$idx][$key] = (.rules[$idx][$key] + $value | unique)
        else
            .rules += [{ ($key): $value }]
        end' "$filepath" > "$tmpfile"

    if [ $? -ne 0 ]; then
        rm -f "$tmpfile"
        return 1
    fi

    mv "$tmpfile" "$filepath"
}

#######################################
# Same as patch_source_ruleset_rules, but takes the values from a file with one value per line. The file is
# read by jq itself: a list of tens of thousands of entries does not fit into a command line argument.
# Duplicates are removed and the values are sorted, as patch_source_ruleset_rules does when merging.
# Arguments:
#   filepath: path to the JSON file to patch
#   key: the ruleset key to insert (e.g., "ip_cidr")
#   values_filepath: path to the file with values, one per line
#######################################
patch_source_ruleset_rules_from_file() {
    local filepath="$1"
    local key="$2"
    local values_filepath="$3"

    local tmpfile
    tmpfile=$(mktemp)

    if ! jq --arg key "$key" --rawfile values "$values_filepath" \
        '($values | split("\n") | map(select(length > 0))) as $value |
        ( .rules | map(has($key)) | index(true) ) as $idx |
        if $idx != null then
            .rules[$idx][$key] = (.rules[$idx][$key] + $value | unique)
        else
            .rules += [{ ($key): ($value | unique) }]
        end' "$filepath" > "$tmpfile"; then
        rm -f "$tmpfile"
        return 1
    fi

    mv "$tmpfile" "$filepath"
}

#######################################
# Imports a plain list into a source ruleset: validates the entries and merges them under the given key with
# a single jq call.
# Arguments:
#   $1 - Path to the plain list file
#   $2 - Path to the ruleset JSON file
#   $3 - Type of validation ("domains" or "subnets")
#   $4 - Ruleset key ("domain_suffix" or "ip_cidr")
#######################################
import_plain_list_to_local_source_ruleset() {
    local plain_list_filepath="$1"
    local ruleset_filepath="$2"
    local type="$3"
    local key="$4"

    local valid_filepath status
    valid_filepath=$(mktemp)
    status=0
    if ! filter_plain_list_file "$plain_list_filepath" "$type" "$valid_filepath"; then
        status=1
    elif [ -s "$valid_filepath" ]; then
        log "Adding $(wc -l < "$valid_filepath") elements to rule set at $ruleset_filepath" "debug"
        patch_source_ruleset_rules_from_file "$ruleset_filepath" "$key" "$valid_filepath" || status=1
    fi

    rm -f "$valid_filepath"
    return "$status"
}

# Imports a plain domain list into a ruleset, validating domains and appending them as domain_suffix rules
import_plain_domain_list_to_local_source_ruleset_chunked() {
    import_plain_list_to_local_source_ruleset "$1" "$2" "domains" "domain_suffix"
}

# Imports a plain IPv4/CIDR list into a ruleset, validating entries and appending them as ip_cidr rules
import_plain_subnet_list_to_local_source_ruleset_chunked() {
    import_plain_list_to_local_source_ruleset "$1" "$2" "subnets" "ip_cidr"
}

# Determines the ruleset format based on the file extension (json → source, srs → binary)
get_ruleset_format_by_file_extension() {
    local file_extension="$1"

    local format
    case "$file_extension" in
    json) format="source" ;;
    srs) format="binary" ;;
    *)
        log "Unsupported file extension: .$file_extension" "error"
        return 1
        ;;
    esac

    echo "$format"
}

# Decompiles a sing-box SRS binary file into a JSON ruleset file
decompile_binary_ruleset() {
    local binary_filepath="$1"
    local output_filepath="$2"

    log "Decompiling $binary_filepath to $output_filepath" "debug"
    sing-box rule-set decompile "$binary_filepath" -o "$output_filepath"
    if [[ $? -ne 0 ]]; then
        log "Decompilation command failed for $binary_filepath" "error"
        return 1
    fi
}

# Extracts all ip_cidr entries from a JSON ruleset file and writes them to an output file.
extract_ip_cidr_from_json_ruleset_to_file() {
    local json_file="$1"
    local output_file="$2"

    log "Extracting ip_cidr entries from $json_file to $output_file" "debug"
    jq -r '.rules[].ip_cidr[]' "$json_file" > "$output_file"
}
