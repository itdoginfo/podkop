include $(TOPDIR)/rules.mk

PKG_NAME:=podkop

PKG_VERSION := $(if $(PODKOP_VERSION),$(PODKOP_VERSION),0.$(shell date +%d%m%Y))

PKG_RELEASE:=1

PKG_MAINTAINER:=ITDog <podkop@itdog.info>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/podkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+sing-box +curl +jq +kmod-nft-tproxy +coreutils-base64 +bind-dig
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Domain routing app
	URL:=https://podkop.net
	PKGARCH:=all
endef

define Package/podkop/description
	Domain routing. Use of VLESS, Shadowsocks technologies
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/podkop/prerm
#!/bin/sh

# On an upgrade (PKG_UPGRADE=1) the stop keeps the fail-closed protection, the new version starts right after it
/etc/init.d/podkop stop

if [ "$${PKG_UPGRADE}" != "1" ]; then
	grep -q "105 podkop" /etc/iproute2/rt_tables && sed -i "/105 podkop/d" /etc/iproute2/rt_tables
fi

exit 0
endef

define Package/podkop/conffiles
/etc/config/podkop
endef

define Package/podkop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/podkop $(1)/etc/init.d/podkop

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/podkop $(1)/etc/config/podkop

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/podkop $(1)/usr/bin/podkop

	$(INSTALL_DIR) $(1)/usr/lib/podkop
	$(CP) ./files/usr/lib/* $(1)/usr/lib/podkop/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g' $(1)/usr/lib/podkop/constants.sh
endef

$(eval $(call BuildPackage,podkop))
