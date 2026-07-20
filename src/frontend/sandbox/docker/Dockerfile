# Dev stand for luci-app-podkop: stock OpenWrt userland + real LuCI.
#
# The app is loaded by LuCI's own require loader and reaches the system through
# rpcd with real ACL checks — neither is exercised by a JS-level mock.
# No backend: /usr/bin/podkop is a shell stub serving fixtures.
ARG OPENWRT_TAG=x86-64-25.12.4
FROM openwrt/rootfs:${OPENWRT_TAG}

# Absent from the rootfs tarball; on a router procd creates them under the /var
# tmpfs. apk needs them earlier.
RUN mkdir -p /var/lock /var/run /var/log /var/state

# firewall/opkg are not about podkop — a page in an empty menu shows nothing
# about how the app sits next to its neighbours.
RUN set -eu; \
	apk update; \
	for p in luci luci-app-firewall luci-app-opkg; do \
		apk add "$p" || echo "skipped (not in feed): $p"; \
	done

COPY files/ /
RUN chmod +x /usr/bin/podkop /etc/init.d/podkop /usr/lib/podkop-dev/entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/usr/lib/podkop-dev/entrypoint.sh"]
CMD ["/sbin/init"]
