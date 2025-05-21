#!/bin/sh

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"

IS_SHOULD_RESTART_NETWORK=
DOWNLOAD_DIR="/tmp/podkop"
COUNT=3
UPGRADE=0

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

for arg in "$@"; do
    if [ "$arg" = "--upgrade" ]; then
        UPGRADE=1
    fi
done

main() {
    check_system
    sing_box
    
    opkg update
  
    if [ -f "/etc/init.d/podkop" ]; then
        if [ "$UPGRADE" -eq 1 ]; then
            echo "Upgraded podkop with flag..."
            break
        else
            printf "\033[32;1mPodkop is already installed. Just upgrade it?\033[0m\n"
            printf "\033[32;1my - Only upgrade podkop\033[0m\n"
            printf "\033[32;1mn - Upgrade and install tunnels (WG, AWG, OpenVPN, OC)\033[0m\n"

            while true; do
                printf "\033[32;1mEnter (y/n): \033[0m"
                read -r -p '' UPDATE
                case $UPDATE in
                y)
                    echo "Upgraded podkop..."
                    break
                    ;;

                n)
                    add_tunnel
                    break
                    ;;

                *)
                    echo "Please enter y or n"
                    ;;
                esac
            done
        fi
    else
        echo "Installed podkop..."
        add_tunnel
    fi
    
    if command -v curl &> /dev/null; then
        check_response=$(curl -s "https://api.github.com/repos/itdoginfo/podkop/releases/latest")

        if echo "$check_response" | grep -q 'API rate limit '; then
            echo "You've reached rate limit from GitHub. Repeat in five minutes."
            exit 1
        fi
    fi

    download_success=0
    while read -r url; do
        filename=$(basename "$url")
        filepath="$DOWNLOAD_DIR/$filename"
               
        attempt=0
        while [ $attempt -lt $COUNT ]; do
            echo "Download $filename (count $((attempt+1)))..."
            if wget -q -O "$filepath" "$url"; then
                if [ -s "$filepath" ]; then
                    echo "$filename successfully downloaded"
                    download_success=1
                    break
                fi
            fi
            echo "Download error $filename. Retry..."
            rm -f "$filepath"
            attempt=$((attempt+1))
        done
        
        if [ $attempt -eq $COUNT ]; then
            echo "Failed to download $filename after $COUNT attempts"
        fi
    done < <(wget -qO- "$REPO" | grep -o 'https://[^"[:space:]]*\.ipk')
    
    if [ $download_success -eq 0 ]; then
        echo "No packages were downloaded successfully"
        exit 1
    fi
    
    for pkg in podkop luci-app-podkop; do
        file=$(ls "$DOWNLOAD_DIR" | grep "^$pkg" | head -n 1)
        if [ -n "$file" ]; then
            echo "Installing $file"
            opkg install "$DOWNLOAD_DIR/$file"
            sleep 3
        fi
    done

    ru=$(ls "$DOWNLOAD_DIR" | grep "luci-i18n-podkop-ru" | head -n 1)
    if [ -n "$ru" ]; then
        printf "\033[32;1mРусский язык интерфейса ставим? y/n (Need a Russian translation?)\033[0m "
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

    find "$DOWNLOAD_DIR" -type f -name '*podkop*' -exec rm {} \;

    if [ "$IS_SHOULD_RESTART_NETWORK" ]; then
        printf "\033[32;1mRestart network\033[0m\n"
        /etc/init.d/network restart
    fi
}

add_tunnel() {
    printf "\033[32;1mWill you be using Wireguard, AmneziaWG, OpenVPN, OpenConnect? If yes, select a number and they will be automatically installed\033[0m\n"
    echo "1) Wireguard"
    echo "2) AmneziaWG"
    echo "3) OpenVPN"
    echo "4) OpenConnect"
    echo "5) I use VLESS/SS. Skip this step"

    while true; do
        read -r -p '' TUNNEL
        case $TUNNEL in

        1)
            opkg install wireguard-tools luci-proto-wireguard luci-app-wireguard

            printf "\033[32;1mDo you want to configure the wireguard interface? (y/n): \033[0m\n"
            read IS_SHOULD_CONFIGURE_WG_INTERFACE

            if [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "Y" ]; then
                wg_awg_setup Wireguard
            else
            printf "\e[1;32mUse these instructions to manual configure https://itdog.info/nastrojka-klienta-wireguard-na-openwrt/\e[0m\n"
            fi

            break
            ;;

        2)
            install_awg_packages

            printf "\033[32;1mThere are no instructions for manual configure yet. Do you want to configure the amneziawg interface? (y/n): \033[0m\n"
            read IS_SHOULD_CONFIGURE_WG_INTERFACE

            if [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "y" ] || [ "$IS_SHOULD_CONFIGURE_WG_INTERFACE" = "Y" ]; then
                wg_awg_setup AmneziaWG
            fi

            break
            ;;

        3)
            opkg install openvpn-openssl luci-app-openvpn
            printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-openvpn-na-openwrt/\e[0m\n"
            break
            ;;

        4)
            opkg install openconnect luci-proto-openconnect
            printf "\e[1;32mUse these instructions to configure https://itdog.info/nastrojka-klienta-openconnect-na-openwrt/\e[0m\n"
            break
            ;;

        5)
            echo "Installation without additional dependencies."
            break
            ;;

        *)
            echo "Choose from the following options"
            ;;
        esac
    done
}

handler_network_restart() {
    IS_SHOULD_RESTART_NETWORK=true
}

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
    
    if opkg list-installed | grep -qE 'luci-app-amneziawg|luci-proto-amneziawg'; then
        echo "luci-app-amneziawg or luci-proto-amneziawg already installed"
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

wg_awg_setup() {
    PROTOCOL_NAME=$1
    printf "\033[32;1mConfigure ${PROTOCOL_NAME}\033[0m\n"
    if [ "$PROTOCOL_NAME" = 'Wireguard' ]; then
        INTERFACE_NAME="wg0"
        CONFIG_NAME="wireguard_wg0"
        PROTO="wireguard"
        ZONE_NAME="wg"
    fi

    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        INTERFACE_NAME="awg0"
        CONFIG_NAME="amneziawg_awg0"
        PROTO="amneziawg"
        ZONE_NAME="awg"
        
        echo "Do you want to use AmneziaWG config or basic Wireguard config + automatic obfuscation?"
        echo "1) AmneziaWG"
        echo "2) Wireguard + automatic obfuscation"
        read CONFIG_TYPE
    fi

    read -r -p "Enter the private key (from [Interface]):"$'\n' WG_PRIVATE_KEY_INT

    while true; do
        read -r -p "Enter internal IP address with subnet, example 192.168.100.5/24 (from [Interface]):"$'\n' WG_IP
        if echo "$WG_IP" | egrep -oq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$'; then
            break
        else
            echo "This IP is not valid. Please repeat"
        fi
    done

    read -r -p "Enter the public key (from [Peer]):"$'\n' WG_PUBLIC_KEY_INT
    read -r -p "If use PresharedKey, Enter this (from [Peer]). If your don't use leave blank:"$'\n' WG_PRESHARED_KEY_INT
    read -r -p "Enter Endpoint host without port (Domain or IP) (from [Peer]):"$'\n' WG_ENDPOINT_INT

    read -r -p "Enter Endpoint host port (from [Peer]) [51820]:"$'\n' WG_ENDPOINT_PORT_INT
    WG_ENDPOINT_PORT_INT=${WG_ENDPOINT_PORT_INT:-51820}
    if [ "$WG_ENDPOINT_PORT_INT" = '51820' ]; then
        echo $WG_ENDPOINT_PORT_INT
    fi

    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        if [ "$CONFIG_TYPE" = '1' ]; then
            read -r -p "Enter Jc value (from [Interface]):"$'\n' AWG_JC
            read -r -p "Enter Jmin value (from [Interface]):"$'\n' AWG_JMIN
            read -r -p "Enter Jmax value (from [Interface]):"$'\n' AWG_JMAX
            read -r -p "Enter S1 value (from [Interface]):"$'\n' AWG_S1
            read -r -p "Enter S2 value (from [Interface]):"$'\n' AWG_S2
            read -r -p "Enter H1 value (from [Interface]):"$'\n' AWG_H1
            read -r -p "Enter H2 value (from [Interface]):"$'\n' AWG_H2
            read -r -p "Enter H3 value (from [Interface]):"$'\n' AWG_H3
            read -r -p "Enter H4 value (from [Interface]):"$'\n' AWG_H4
        elif [ "$CONFIG_TYPE" = '2' ]; then
            #Default values to wg automatic obfuscation
            AWG_JC=4
            AWG_JMIN=40
            AWG_JMAX=70
            AWG_S1=0
            AWG_S2=0
            AWG_H1=1
            AWG_H2=2
            AWG_H3=3
            AWG_H4=4
        fi
    fi
    
    uci set network.${INTERFACE_NAME}=interface
    uci set network.${INTERFACE_NAME}.proto=$PROTO
    uci set network.${INTERFACE_NAME}.private_key=$WG_PRIVATE_KEY_INT
    uci set network.${INTERFACE_NAME}.listen_port='51821'
    uci set network.${INTERFACE_NAME}.addresses=$WG_IP

    if [ "$PROTOCOL_NAME" = 'AmneziaWG' ]; then
        uci set network.${INTERFACE_NAME}.awg_jc=$AWG_JC
        uci set network.${INTERFACE_NAME}.awg_jmin=$AWG_JMIN
        uci set network.${INTERFACE_NAME}.awg_jmax=$AWG_JMAX
        uci set network.${INTERFACE_NAME}.awg_s1=$AWG_S1
        uci set network.${INTERFACE_NAME}.awg_s2=$AWG_S2
        uci set network.${INTERFACE_NAME}.awg_h1=$AWG_H1
        uci set network.${INTERFACE_NAME}.awg_h2=$AWG_H2
        uci set network.${INTERFACE_NAME}.awg_h3=$AWG_H3
        uci set network.${INTERFACE_NAME}.awg_h4=$AWG_H4
    fi

    if ! uci show network | grep -q ${CONFIG_NAME}; then
        uci add network ${CONFIG_NAME}
    fi

    uci set network.@${CONFIG_NAME}[0]=$CONFIG_NAME
    uci set network.@${CONFIG_NAME}[0].name="${INTERFACE_NAME}_client"
    uci set network.@${CONFIG_NAME}[0].public_key=$WG_PUBLIC_KEY_INT
    uci set network.@${CONFIG_NAME}[0].preshared_key=$WG_PRESHARED_KEY_INT
    uci set network.@${CONFIG_NAME}[0].route_allowed_ips='0'
    uci set network.@${CONFIG_NAME}[0].persistent_keepalive='25'
    uci set network.@${CONFIG_NAME}[0].endpoint_host=$WG_ENDPOINT_INT
    uci set network.@${CONFIG_NAME}[0].allowed_ips='0.0.0.0/0'
    uci set network.@${CONFIG_NAME}[0].endpoint_port=$WG_ENDPOINT_PORT_INT
    uci commit network

    if ! uci show firewall | grep -q "@zone.*name='${ZONE_NAME}'"; then
        printf "\033[32;1mZone Create\033[0m\n"
        uci add firewall zone
        uci set firewall.@zone[-1].name=$ZONE_NAME
        uci set firewall.@zone[-1].network=$INTERFACE_NAME
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].family='ipv4'
        uci commit firewall
    fi

    if ! uci show firewall | grep -q "@forwarding.*name='${ZONE_NAME}'"; then
        printf "\033[32;1mConfigured forwarding\033[0m\n"
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].name="${ZONE_NAME}-lan"
        uci set firewall.@forwarding[-1].dest=${ZONE_NAME}
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].family='ipv4'
        uci commit firewall
    fi

    handler_network_restart
}

check_system() {
    # Get router model
    MODEL=$(cat /tmp/sysinfo/model)
    echo "Router model: $MODEL"

    # Check available space
    AVAILABLE_SPACE=$(df /overlay | awk 'NR==2 {print $4}')
    REQUIRED_SPACE=15360 # 15MB in KB

    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        printf "\033[31;1mError: Insufficient space in flash\033[0m\n"
        echo "Available: $((AVAILABLE_SPACE/1024))MB"
        echo "Required: $((REQUIRED_SPACE/1024))MB"
        exit 1
    fi

    if ! nslookup google.com >/dev/null 2>&1; then
        printf "\033[31;1mDNS not working\033[0m\n"
        exit 1
    fi

    if opkg list-installed | grep -q https-dns-proxy; then
        printf "\033[31;1mСonflicting package detected: https-dns-proxy. Remove? yes/no\033[0m\n"

        while true; do
                read -r -p '' DNSPROXY
                case $DNSPROXY in

                yes|y|Y|yes)
                    opkg remove --force-depends luci-app-https-dns-proxy https-dns-proxy luci-i18n-https-dns-proxy*
                    break
                    ;;
                *)
                    echo "Exit"
                    exit 1
                    ;;
        esac
    done
    fi

    if opkg list-installed | grep -q "iptables-mod-extra"; then
        printf "\033[31;1mFound incompatible iptables packages. If you're using FriendlyWrt: https://t.me/itdogchat/44512/181082\033[0m\n"
    fi
}

sing_box() {
    if ! opkg list-installed | grep -q "^sing-box"; then
        return
    fi

    sing_box_version=$(sing-box version | head -n 1 | awk '{print $3}')
    required_version="1.11.1"

    if [ "$(echo -e "$sing_box_version\n$required_version" | sort -V | head -n 1)" != "$required_version" ]; then
        opkg remove sing-box
    fi
}

main
