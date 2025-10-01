include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop

PKG_VERSION := $(if $(PKG_VERSION),$(PKG_VERSION),dev_$(shell date +%d%m%Y))

PKG_RELEASE:=1

LUCI_TITLE:=LuCI podkop app
LUCI_DEPENDS:=+luci-base +podkop
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=ITDog <podkop@itdog.info>

LUCI_LANGUAGES:=en ru

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	# https://github.com/openwrt/luci/blob/master/luci.mk
	$$(call Package/$(PKG_NAME))/install/default,$$(1))

	$(SED) 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g' \
		$$(1)$$(HTDOCS)/luci-static/resources/view/podkop/constants.js
endef

# call BuildPackage - OpenWrt buildroot signature