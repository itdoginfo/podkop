include $(TOPDIR)/rules.mk

PKG_NAME:=netshift

PKG_VERSION := $(if $(NETSHIFT_VERSION),$(NETSHIFT_VERSION),0.9.10)

PKG_RELEASE:=1

PKG_MAINTAINER:=ITDog <podkop@itdog.info>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/netshift
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+sing-box +curl +jq +kmod-nft-tproxy +coreutils-base64 +bind-dig
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Domain routing app
	URL:=https://podkop.net
	PKGARCH:=all
endef

define Package/netshift/description
	Domain routing. Use of VLESS, Shadowsocks technologies
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/netshift/prerm
#!/bin/sh

# block_leaks keeps dnsmasq pointed at the (now dead) sing-box DNS inbound and
# the guard table armed while the service is down. Nothing starts the service
# again after this script - not on a removal, and not on an upgrade either (the
# package has no postinst) - so that would leave the router without DNS. The
# stop below therefore releases the kill switch: DNS is handed back and the
# guard table is deleted. The stored option is left alone (/etc/config/netshift
# is a conffile), so after an upgrade the next start arms the guard again.
export NETSHIFT_BLOCK_LEAKS_RELEASE=1

grep -q "105 netshift" /etc/iproute2/rt_tables && sed -i "/105 netshift/d" /etc/iproute2/rt_tables

/etc/init.d/netshift stop

exit 0
endef

define Package/netshift/conffiles
/etc/config/netshift
endef

define Package/netshift/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/netshift $(1)/etc/init.d/netshift
	$(INSTALL_BIN) ./files/etc/init.d/netshift-naive $(1)/etc/init.d/netshift-naive

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/netshift $(1)/etc/config/netshift

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/netshift $(1)/usr/bin/netshift

	$(INSTALL_DIR) $(1)/usr/lib/netshift
	$(CP) ./files/usr/lib/* $(1)/usr/lib/netshift/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g' $(1)/usr/lib/netshift/constants.sh
endef

$(eval $(call BuildPackage,netshift))
