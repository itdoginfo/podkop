#!/bin/sh

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"

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
        printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-wireguard-na-openwrt/\e[0m\n"
        break
        ;;

    3)
        sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/podkop/refs/heads/feat/add-amneziawg-auto-install/utils/amneziawg-install.sh)
        sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/podkop/refs/heads/feat/add-amneziawg-auto-install/utils/wg_awg_setup.sh) AmneziaWG
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

echo "Installed podkop..."
opkg install $DOWNLOAD_DIR/podkop*.ipk
opkg install $DOWNLOAD_DIR/luci-app-podkop*.ipk

rm -f $DOWNLOAD_DIR/podkop*.ipk $DOWNLOAD_DIR/luci-app-podkop*.ipk