#!/bin/sh

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"
DOWNLOAD_DIR="/tmp/podkop"
COUNT=3

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

msg() {
    printf "\033[32;1m%s\033[0m\n" "$1"
}

main() {
    check_system
    sing_box

    /usr/sbin/ntpd -q -p 194.190.168.1 -p 216.239.35.0 -p 216.239.35.4 -p 162.159.200.1 -p 162.159.200.123

    opkg update || { echo "opkg update failed"; exit 1; }
  
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
            opkg install "$DOWNLOAD_DIR/$file"
            sleep 3
        fi
    done

    ru=$(ls "$DOWNLOAD_DIR" | grep "luci-i18n-podkop-ru" | head -n 1)
    if [ -n "$ru" ]; then
        if opkg list-installed | grep -q luci-i18n-podkop-ru; then
                msg "Upgraded ru translation..."
                opkg remove luci-i18n-podkop*
                opkg install "$DOWNLOAD_DIR/$ru"
        else
            msg "Русский язык интерфейса ставим? y/n (Need a Russian translation?)"
            while true; do
                read -r -p '' RUS
                case $RUS in
                y)
                    opkg remove luci-i18n-podkop*
                    opkg install "$DOWNLOAD_DIR/$ru"
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

    if opkg list-installed | grep -q https-dns-proxy; then
        msg "Сonflicting package detected: https-dns-proxy. Remove?"

        while true; do
                read -r -p '' DNSPROXY
                case $DNSPROXY in

                yes|y|Y|yes)
                    opkg remove --force-depends luci-app-https-dns-proxy https-dns-proxy luci-i18n-https-dns-proxy*
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
    if ! opkg list-installed | grep -q "^sing-box"; then
        return
    fi

    sing_box_version=$(sing-box version | head -n 1 | awk '{print $3}')
    required_version="1.11.1"

    if [ "$(echo -e "$sing_box_version\n$required_version" | sort -V | head -n 1)" != "$required_version" ]; then
        msg "sing-box version $sing_box_version is older than required $required_version"
        msg "Removing old version..."
        opkg remove sing-box
    fi
}

main
