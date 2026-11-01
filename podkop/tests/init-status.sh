#!/bin/sh

set -eu

INIT_SCRIPT=${INIT_SCRIPT:-"$(dirname "$0")/../files/etc/init.d/podkop"}

readlink() {
    printf '%s\n' "$1"
}

config_load() {
    :
}

service_running() {
    return 0
}

procd_running() {
    [ "$1" = "sing-box" ] || return 1
    [ "$PROCD_RUNNING" = "1" ]
}

nft() {
    [ "$1" = "list" ] && [ "$2" = "table" ] &&
        [ "$3" = "inet" ] && [ "$4" = "PodkopTable" ] || return 1
    [ "$NFT_TABLE_PRESENT" = "1" ]
}

initscript=/etc/init.d/podkop
. "$INIT_SCRIPT"

# rc.common installs these command wrappers after sourcing the init script.
status() {
    status_service
}

running() {
    service_running "$@"
}

assert_service_running() {
    expected_status=$1
    if output=$(service_running 2>&1); then
        actual_status=0
    else
        actual_status=$?
    fi
    if [ -n "$output" ] || [ "$actual_status" -ne "$expected_status" ]; then
        printf 'FAIL: service_running: expected no output (exit %s), got "%s" (exit %s)\n' \
            "$expected_status" "$output" "$actual_status" >&2
        exit 1
    fi
}

assert_result() {
    action=$1
    expected_output=$2
    expected_status=$3

    if output=$("$action" 2>&1); then
        actual_status=0
    else
        actual_status=$?
    fi

    if [ "$output" != "$expected_output" ] || [ "$actual_status" -ne "$expected_status" ]; then
        printf 'FAIL: %s: expected "%s" (exit %s), got "%s" (exit %s)\n' \
            "$action" "$expected_output" "$expected_status" "$output" "$actual_status" >&2
        exit 1
    fi
}

PROCD_RUNNING=1
NFT_TABLE_PRESENT=1
assert_service_running 0
assert_result status running 0
assert_result running '' 0

PROCD_RUNNING=0
NFT_TABLE_PRESENT=1
assert_service_running 1
assert_result status 'not running' 5
assert_result running '' 1

PROCD_RUNNING=1
NFT_TABLE_PRESENT=0
assert_service_running 1
assert_result status 'not running' 5
assert_result running '' 1

printf 'init status behavior: OK\n'
