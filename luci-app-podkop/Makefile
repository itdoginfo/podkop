include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop
PKG_VERSION:=0.2.3
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

define Package/luci-i18n-$(PKG_NAME)-$(1)
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=$(PKG_NAME) - $(1) translation
  HIDDEN:=1
  DEFAULT:=LUCI_LANG_$(1)||ALL
  VERSION:=$(PKG_VERSION_TRANS)
  DEPENDS:=$(PKG_NAME)
endef

# call BuildPackage - OpenWrt buildroot signature