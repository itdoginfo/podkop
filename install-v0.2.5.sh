#!/bin/sh

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/tags/v0.2.5"

DOWNLOAD_DIR="/tmp/podkop"
COUNT=3

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

main() {
    check_system
    
    opkg update
  
    if [ -f "/etc/init.d/podkop" ]; then
        echo "Remove current vesrion podkop"
        opkg remove luci-i18n-podkop-ru luci-app-podkop podkop
        rm /etc/config/podkop
    else
        echo "Installed podkop..."
    fi

    wget -qO- "$REPO" | grep -o 'https://[^"[:space:]]*\.ipk' | while read -r url; do
        filename=$(basename "$url")
        filepath="$DOWNLOAD_DIR/$filename"

        attempt=0
        while [ $attempt -lt $COUNT ]; do
            if [ -f "$filepath" ] && [ -s "$filepath" ]; then
                echo "$filename has already been uploaded"
                break
            fi

            echo "Download $filename (count $((attempt+1)))..."
            wget -q -O "$filepath" "$url"
            
            if [ -s "$filepath" ]; then
                echo "$filename successfully downloaded"
            else
                echo "Download error $filename. Retry..."
                rm -f "$filepath"
            fi
            attempt=$((attempt+1))
        done
    done

    for pkg in podkop luci-app-podkop; do
        file=$(ls "$DOWNLOAD_DIR" | grep "^$pkg" | head -n 1)
        if [ -n "$file" ]; then
            echo "Installing $file"
            opkg install "$DOWNLOAD_DIR/$file"
        fi
    done

    ru=$(ls "$DOWNLOAD_DIR" | grep "luci-i18n-podkop-ru" | head -n 1)
    if [ -n "$ru" ]; then
        printf "\033[32;1mРусский язык интерфейса ставим? y/n (Need a Russian translation?)\033[0m "
        while true; do
            read -r -p '' RUS
            case $RUS in
            y)
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


    rm -f $DOWNLOAD_DIR/podkop*.ipk $DOWNLOAD_DIR/luci-app-podkop*.ipk $DOWNLOAD_DIR/luci-i18n-podkop-ru*.ipk

}


check_system() {
    # Get router model
    MODEL=$(cat /tmp/sysinfo/model)
    echo "Router model: $MODEL"

    if ! nslookup google.com >/dev/null 2>&1; then
        log "DNS not working"
        exit 1
    fi

    if opkg list-installed | grep -qE "iptables|kmod-iptab"; then
        printf "\033[31;1mFound incompatible iptables packages. If you're using FriendlyWrt: https://t.me/itdogchat/44512/181082\033[0m\n"
    fi
}

main