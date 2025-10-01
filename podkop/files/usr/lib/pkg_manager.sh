#!/bin/ash
# Ash isn't supported properly in spellcheck static analyzer
# Using debian based version (kind of similar)
# shellcheck shell=dash

# Optimize command -v calls
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

pkg_get_version () {
    local version pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        version=$(apk info "$pkg_name" 2>/dev/null | grep -oP "${pkg_name}-\K.*")
    else
        version=$(opkg list-installed "$pkg_name" 2>/dev/null | awk '{print $3}')
    fi

    echo "$version"
}