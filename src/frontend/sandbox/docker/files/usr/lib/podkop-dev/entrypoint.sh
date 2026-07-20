#!/bin/sh
# Prepare the stand, then hand over to procd.
#
# Networking has to happen HERE, before `exec /sbin/init`: config_generate
# writes its own /etc/config/network from board.json (br-lan, hardcoded
# 192.168.1.1), netifd applies it and Docker's address is gone. By the time
# uci-defaults run, eth0 is already down and flushed.
#
# config_generate's guard is `[ -s /etc/config/network -a -s /etc/config/system ]`,
# so both files must exist — hence /etc/config/system in the image.
#
# The interface is named 'lan' because OpenWrt's default firewall allows input
# in that zone; that is what makes port 80 reachable from the host.
#
# Approach borrowed from luci-theme-footstrap.
set -e

addr="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')"
gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
dns="${PODKOP_DEV_DNS:-1.1.1.1 8.8.8.8}"

# Docker's resolv.conf points at 127.0.0.11, which works via NAT rules that
# OpenWrt's boot flushes.
for ns in $dns; do echo "nameserver $ns"; done >/etc/resolv.conf

if [ -n "$addr" ]; then
	netmask="$(ipcalc.sh "$addr" | sed -n 's/^NETMASK=//p')"
	cat >/etc/config/network <<-EOF
		config interface 'loopback'
			option device 'lo'
			option proto 'static'
			option ipaddr '127.0.0.1'
			option netmask '255.0.0.0'

		config globals 'globals'

		config interface 'lan'
			option device 'eth0'
			option proto 'static'
			option ipaddr '${addr%/*}'
			option netmask '$netmask'
			option gateway '$gw'
			option dns '$dns'
			option delegate '0'
	EOF
else
	echo "podkop-dev: eth0 has no IPv4 — /etc/config/network left alone" >&2
fi

# Autostart on by default; get_status reads this. /etc survives boot, /tmp does
# not — runtime state is seeded from /etc/rc.local instead.
mkdir -p /etc/rc.d
touch /etc/rc.d/S99podkop

# Until the cache is dropped, the mounted menu.d/acl.d stay invisible.
rm -f /tmp/luci-indexcache* /var/luci-indexcache* 2>/dev/null || true

exec "$@"
