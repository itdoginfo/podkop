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
        read -r -p "Enter Jc value (from [Interface]):"$'\n' AWG_JC
        read -r -p "Enter Jmin value (from [Interface]):"$'\n' AWG_JMIN
        read -r -p "Enter Jmax value (from [Interface]):"$'\n' AWG_JMAX
        read -r -p "Enter S1 value (from [Interface]):"$'\n' AWG_S1
        read -r -p "Enter S2 value (from [Interface]):"$'\n' AWG_S2
        read -r -p "Enter H1 value (from [Interface]):"$'\n' AWG_H1
        read -r -p "Enter H2 value (from [Interface]):"$'\n' AWG_H2
        read -r -p "Enter H3 value (from [Interface]):"$'\n' AWG_H3
        read -r -p "Enter H4 value (from [Interface]):"$'\n' AWG_H4
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
}

wg_awg_setup "$1"
