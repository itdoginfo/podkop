include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop
PKG_VERSION:=0.2.5
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

# call BuildPackage - OpenWrt buildroot signature