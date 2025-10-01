#!/bin/sh

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"
DOWNLOAD_DIR="/tmp/podkop"
COUNT=3
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

msg() {
    printf "\033[32;1m%s\033[0m\n" "$1"
}

pkg_is_installed () {
    local pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # grep -q should work without change based on example from documentation
        # apk list --installed --providers dnsmasq
        # <dnsmasq> dnsmasq-full-2.90-r3 x86_64 {feeds/base/package/network/services/dnsmasq} (GPL-2.0) [installed]
        apk list --installed | grep -q "$pkg_name"
    else
        opkg list-installed | grep -q "$pkg_name"
    fi
}

pkg_remove() {
    local pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # TODO: check --force-depends flag
        # Nothing here: https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet
        apk del "$pkg_name"
    else
        opkg remove --force-depends "$pkg_name"
    fi
}

pkg_list_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update
    else
        opkg update
    fi
}

pkg_install() {
    local pkg_file="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        # Can't install without flag based on info from documentation
        # If you're installing a non-standard (self-built) package, use the --allow-untrusted option:
        apk add --allow-untrusted "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

main() {
    check_system
    sing_box

    /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    pkg_list_update || { echo "Packages list update failed"; exit 1; }

    if [ -f "/etc/init.d/podkop" ]; then
        msg "Podkop is already installed. Upgraded..."
    else
        msg "Installed podkop..."
    fi

    if command -v curl &> /dev/null; then
        check_response=$(curl -s "https://api.github.com/repos/itdoginfo/podkop/releases/latest")

        if echo "$check_response" | grep -q 'API rate limit '; then
            msg "You've reached rate limit from GitHub. Repeat in five minutes."
            exit 1
        fi
    fi

    download_success=0
    while read -r url; do
        filename=$(basename "$url")
        filepath="$DOWNLOAD_DIR/$filename"

        attempt=0
        while [ $attempt -lt $COUNT ]; do
            msg "Download $filename (count $((attempt+1)))..."
            if wget -q -O "$filepath" "$url"; then
                if [ -s "$filepath" ]; then
                    msg "$filename successfully downloaded"
                    download_success=1
                    break
                fi
            fi
            msg "Download error $filename. Retry..."
            rm -f "$filepath"
            attempt=$((attempt+1))
        done

        if [ $attempt -eq $COUNT ]; then
            msg "Failed to download $filename after $COUNT attempts"
        fi
    done < <(wget -qO- "$REPO" | grep -o 'https://[^"[:space:]]*\.ipk')

    if [ $download_success -eq 0 ]; then
        msg "No packages were downloaded successfully"
        exit 1
    fi

    for pkg in podkop luci-app-podkop; do
        file=$(ls "$DOWNLOAD_DIR" | grep "^$pkg" | head -n 1)
        if [ -n "$file" ]; then
            msg "Installing $file"
            pkg_install "$DOWNLOAD_DIR/$file"
            sleep 3
        fi
    done

    ru=$(ls "$DOWNLOAD_DIR" | grep "luci-i18n-podkop-ru" | head -n 1)
    if [ -n "$ru" ]; then
        if pkg_is_installed luci-i18n-podkop-ru; then
                msg "Upgraded ru translation..."
                pkg_remove remove luci-i18n-podkop*
                pkg_install install "$DOWNLOAD_DIR/$ru"
        else
            msg "Русский язык интерфейса ставим? y/n (Need a Russian translation?)"
            while true; do
                read -r -p '' RUS
                case $RUS in
                y)
                    pkg_remove luci-i18n-podkop*
                    pkg_install "$DOWNLOAD_DIR/$ru"
                    break
                    ;;
                n)
                    break
                    ;;
                *)
                    echo "Введите y или n"
                    ;;
                esac
            done
        fi
    fi

    find "$DOWNLOAD_DIR" -type f -name '*podkop*' -exec rm {} \;
}

check_system() {
    # Get router model
    MODEL=$(cat /tmp/sysinfo/model)
    msg "Router model: $MODEL"

    # Check OpenWrt version
    openwrt_version=$(cat /etc/openwrt_release | grep DISTRIB_RELEASE | cut -d"'" -f2 | cut -d'.' -f1)
    if [ "$openwrt_version" = "23" ]; then
        msg "OpenWrt 23.05 не поддерживается начиная с podkop 0.5.0"
        msg "Для OpenWrt 23.05 используйте podkop версии 0.4.11 или устанавливайте зависимости и podkop вручную"
        msg "Подробности: https://podkop.net/docs/install/#%d1%83%d1%81%d1%82%d0%b0%d0%bd%d0%be%d0%b2%d0%ba%d0%b0-%d0%bd%d0%b0-2305"
        exit 1
    fi

    # Check available space
    AVAILABLE_SPACE=$(df /overlay | awk 'NR==2 {print $4}')
    REQUIRED_SPACE=15360 # 15MB in KB

    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        msg "Error: Insufficient space in flash"
        msg "Available: $((AVAILABLE_SPACE/1024))MB"
        msg "Required: $((REQUIRED_SPACE/1024))MB"
        exit 1
    fi

    if ! nslookup google.com >/dev/null 2>&1; then
        msg "DNS not working"
        exit 1
    fi

    if pkg_is_installed https-dns-proxy; then
        msg "Сonflicting package detected: https-dns-proxy. Remove?"

        while true; do
                read -r -p '' DNSPROXY
                case $DNSPROXY in

                yes|y|Y)
                    pkg_remove luci-app-https-dns-proxy
                    pkg_remove https-dns-proxy
                    pkg_remove luci-i18n-https-dns-proxy*
                    break
                    ;;
                *)
                    msg "Exit"
                    exit 1
                    ;;
        esac
    done
    fi
}

sing_box() {
    if ! pkg_is_installed "^sing-box"; then
        return
    fi

    sing_box_version=$(sing-box version | head -n 1 | awk '{print $3}')
    required_version="1.12.4"

    if [ "$(echo -e "$sing_box_version\n$required_version" | sort -V | head -n 1)" != "$required_version" ]; then
        msg "sing-box version $sing_box_version is older than required $required_version"
        msg "Removing old version..."
        pkg_remove sing-box
    fi
}

main
