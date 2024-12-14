include $(TOPDIR)/rules.mk

PKG_NAME:=podkop
PKG_VERSION:=0.2.5
PKG_RELEASE:=1

PKG_MAINTAINER:=ITDog <podkop@itdog.info>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/podkop
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+dnsmasq-full +curl +jq +kmod-nft-tproxy +coreutils-base64
	TITLE:=Domain routing app
	URL:=https://itdog.info
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

grep -q "105 podkop" /etc/iproute2/rt_tables && sed -i "/105 podkop/d" /etc/iproute2/rt_tables

rm -f /etc/hotplug.d/iface/50-podkop

exit 0
endef

define Package/podkop/conffiles
/etc/config/podkop
endef

define Package/podkop/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/podkop $(1)/etc/init.d/podkop
	sed -i "s/VERSION_FROM_MAKEFILE/$(PKG_VERSION)/g" $(1)/etc/init.d/podkop

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/podkop $(1)/etc/config/podkop

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/50-podkop $(1)/etc/hotplug.d/iface/50-podkop
endef

$(eval $(call BuildPackage,podkop))
