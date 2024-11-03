#!/bin/sh

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"
BASE_RAW_URL="https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/refs/heads/main"

DOWNLOAD_DIR="/tmp/podkop"
mkdir -p "$DOWNLOAD_DIR"

wget -qO- "$REPO" | grep -o 'https://[^"]*\.ipk' | while read -r url; do
    filename=$(basename "$url")
    echo "Download $filename..."
    wget -q -O "$DOWNLOAD_DIR/$filename" "$url"
done

echo "opkg update"
opkg update

if opkg list-installed | grep -q dnsmasq-full; then
    echo "dnsmasq-full already installed"
else
    echo "Installed dnsmasq-full"
    cd /tmp/ && opkg download dnsmasq-full
    opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/

    [ -f /etc/config/dhcp-opkg ] && cp /etc/config/dhcp /etc/config/dhcp-old && mv /etc/config/dhcp-opkg /etc/config/dhcp
fi

install_awg_packages() {
    # Получение pkgarch с наибольшим приоритетом
    PKGARCH=$(opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}')

    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}.ipk"
    BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"
    
    if opkg list-installed | grep -q kmod-amneziawg; then
        echo "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME="kmod-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${KMOD_AMNEZIAWG_FILENAME}"
        wget -O "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error downloading kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
        
        opkg install "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error installing kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    if opkg list-installed | grep -q amneziawg-tools; then
        echo "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME="amneziawg-tools${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${AMNEZIAWG_TOOLS_FILENAME}"
        wget -O "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error downloading amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi

        opkg install "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error installing amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi
    fi
    
    if opkg list-installed | grep -q luci-app-amneziawg; then
        echo "luci-app-amneziawg already installed"
    else
        LUCI_APP_AMNEZIAWG_FILENAME="luci-app-amneziawg${PKGPOSTFIX}"
        DOWNLOAD_URL="${BASE_URL}v${VERSION}/${LUCI_APP_AMNEZIAWG_FILENAME}"
        wget -O "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME" "$DOWNLOAD_URL"

        if [ $? -eq 0 ]; then
            echo "luci-app-amneziawg file downloaded successfully"
        else
            echo "Error downloading luci-app-amneziawg. Please, install luci-app-amneziawg manually and run the script again"
            exit 1
        fi

        opkg install "$AWG_DIR/$LUCI_APP_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "luci-app-amneziawg file downloaded successfully"
        else
            echo "Error installing luci-app-amneziawg. Please, install luci-app-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    rm -rf "$AWG_DIR"
}

add_tunnel() {
    echo "What type of VPN or proxy will be used?"
    echo "1) VLESS, Shadowsocks (A sing-box will be installed)"
    echo "2) Wireguard"
    echo "3) AmneziaWG"
    echo "4) OpenVPN"
    echo "5) OpenConnect"
    echo "6) Skip this step"

    while true; do
        read -r -p '' TUNNEL
        case $TUNNEL in

        1)
            opkg install sing-box
            break
            ;;

        2)
            opkg install wireguard-tools luci-proto-wireguard luci-app-wireguard

            printf "\033[32;1mDo you want to configure the wireguard interface? (y/n): \033[0m\n"
            read IS_SHOULD_CONFIGURE_WG_INTERFACE

            if [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "Y" ]; then
                sh <(wget -O - "$BASE_RAW_URL/utils/wg-awg-setup.sh") Wireguard
            else
            printf "\e[1;32mUse these instructions to manual configure https://itdog.info/nastrojka-klienta-wireguard-na-openwrt/\e[0m\n"
            fi

            break
            ;;

        3)
            install_awg_packages

            printf "\033[32;1mThere are no instructions for manual configure yet. Do you want to configure the amneziawg interface? (y/n): \033[0m\n"
            read IS_SHOULD_CONFIGURE_WG_INTERFACE

            if [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "Y" ]; then
                sh <(wget -O - "$BASE_RAW_URL/utils/wg-awg-setup.sh") AmneziaWG
            fi

            break
            ;;

        4)
            opkg install opkg install openvpn-openssl luci-app-openvpn
            printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-openvpn-na-openwrt/\e[0m\n"
            break
            ;;

        5)
            opkg install opkg install openconnect luci-proto-openconnect
            printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-openconnect-na-openwrt/\e[0m\n"
            break
            ;;

        6)
            echo "Skip. Use this if you're installing an upgrade."
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done
}

add_tunnel

echo "Installed podkop..."
opkg install $DOWNLOAD_DIR/podkop*.ipk
opkg install $DOWNLOAD_DIR/luci-app-podkop*.ipk

rm -f $DOWNLOAD_DIR/podkop*.ipk $DOWNLOAD_DIR/luci-app-podkop*.ipk

printf "\033[32;1mRestart network\033[0m\n"
service network restart
