# shellcheck shell=ash
#
# Warnings about a configuration that is valid but does not do what it says.
#
# A DNS section (connection_type dns) hands the domains of its lists to a DNS server of
# its own. The domains that a proxy or VPN section routes get their FakeIP answer first,
# so a domain written in both is never looked up by the DNS section. The check covers the
# domains typed into the sections (user_domains); the downloaded lists are too big to
# compare on every start. Which list a section uses is decided by user_domain_list_type
# (dynamic: user_domains, text: user_domains_text, anything else - disabled included - no
# list at all), as when the configuration is built. Block sections are not compared: their
# domains are blocked anyway. Exclusion sections are: their domains get the FakeIP answer too.

# config_foreach callback: one line "<section> <type> <domain>" per usable domain.
_lint_collect_section() {
    local section="$1"
    local connection_type list_type text_items item

    section_is_disabled "$section" && return 0
    config_get connection_type "$section" "connection_type"
    case "$connection_type" in
    dns | proxy | vpn | exclusion) ;;
    *) return 0 ;;
    esac

    _lint_section="$section"
    _lint_type="$connection_type"
    config_get list_type "$section" "user_domain_list_type"
    case "$list_type" in
    text)
        # one string with the names separated by commas, blanks and line breaks
        config_get text_items "$section" "user_domains_text"
        printf '%s\n' "$text_items" | sed 's/\/\/.*//' | tr ', \011\012\013\014\015' '\n' | grep -v '^$' | while IFS= read -r item; do
            _lint_collect_domain "$item"
        done
        ;;
    dynamic) netshift_config_list_foreach "$section" "user_domains" _lint_collect_domain ;;
    *) return 0 ;;
    esac
}

_lint_collect_domain() {
    local domain

    domain="$(normalize_domain_case "$1")"
    case "$domain" in
    full:*) domain="=${domain#full:}" ;;
    keyword:* | regex:* | regexp:* | domain:*) return 0 ;;
    esac
    domain="${domain#.}"
    [ -n "$domain" ] || return 0

    printf '%s %s %s\n' "$_lint_section" "$_lint_type" "$domain" >> "$_lint_file"
}

# Prints a JSON array: [{"kind":"dns_domain_shadowed","domain","dns_section","section"}]
get_config_warnings() {
    # In a subshell with its own temporary file (mktemp, never a fixed path in /tmp, which a local
    # user could point elsewhere with a symlink or share between two runs) removed on every exit.
    (
        _lint_file="$(mktemp)" || exit 1
        trap 'rm -f "$_lint_file"' EXIT INT TERM
        _lint_collect_and_compare
    )
}

_lint_collect_and_compare() {
    config_foreach _lint_collect_section "section"

    awk '
        { sec[NR] = $1; typ[NR] = $2; dom[NR] = $3; n = NR }
        END {
            for (i = 1; i <= n; i++) {
                if (typ[i] != "dns") continue
                d = dom[i]; exact = 0
                if (substr(d, 1, 1) == "=") { d = substr(d, 2); exact = 1 }
                for (j = 1; j <= n; j++) {
                    if (typ[j] == "dns") continue
                    p = dom[j]; pexact = 0
                    if (substr(p, 1, 1) == "=") { p = substr(p, 2); pexact = 1 }
                    covered = 0
                    if (d == p) covered = 1
                    else if (!pexact && length(d) > length(p) + 1 && substr(d, length(d) - length(p)) == "." p) covered = 1
                    if (covered) { print d "\t" sec[i] "\t" sec[j]; break }
                }
            }
        }' "$_lint_file" | jq -R -s -c '
        split("\n") | map(select(length > 0) | split("\t")
            | {kind: "dns_domain_shadowed", domain: .[0], dns_section: .[1], section: .[2]})'
}

# Logs the warnings of get_config_warnings.
lint_log_warnings() {
    local warnings line

    warnings="$(get_config_warnings 2> /dev/null)" || return 0
    printf '%s' "$warnings" | jq -r '.[] | "\(.domain)\t\(.dns_section)\t\(.section)"' 2> /dev/null | while IFS="$(printf '\t')" read -r domain dns_section section; do
        log "DNS section '$dns_section': the domain '$domain' is also routed by section '$section', which takes it first (FakeIP), so the DNS section never looks it up" "warn"
    done
    return 0
}
