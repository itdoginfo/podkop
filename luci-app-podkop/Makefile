# See /LICENSE for more information.
# This is free software, licensed under the GNU General Public License v2.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop
PKG_VERSION:=0.2.3
PKG_RELEASE:=1

LUCI_TITLE:=LuCI podkop app
LUCI_DEPENDS:=+luci-base +podkop
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=ITDog <podkop@itdog.info>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature