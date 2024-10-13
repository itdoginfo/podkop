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

echo "Installed..."
opkg install $DOWNLOAD_DIR/podkop*.ipk
opkg install $DOWNLOAD_DIR/luci-app-podkop*.ipk

/etc/init.d/ucitrack restart

echo "Install sing-box for proxy, or install and configure WG/OpenVPN/AWG/etc for VPN mode"