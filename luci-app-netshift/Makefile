include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netshift

PKG_VERSION := $(if $(NETSHIFT_VERSION),$(NETSHIFT_VERSION),0.$(shell date +%d%m%Y))

PKG_RELEASE:=1

LUCI_TITLE:=LuCI NetShift app
LUCI_DEPENDS:=+luci-base +netshift
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English

PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=ITDog <podkop@itdog.info>

LUCI_LANGUAGES:=en ru

# luci.mk only defines its own postinst when none is set, so the default LuCI cache
# cleanup is repeated here, followed by removal of the view directories of earlier
# versions: opkg does not delete files that disappeared from a package, and every
# release installs a new view/netshift_<hash>/ (see cache-bust.sh). The directory
# the menu entry points to is the installed one and is kept.
define Package/$(PKG_NAME)/postinst
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	view_dir="$${LUCI_VIEW_DIR:-/www/luci-static/resources/view}"
	menu_file="$${LUCI_MENU_FILE:-/usr/share/luci/menu.d/luci-app-netshift.json}"
	active="$$(sed -n 's#.*"path": *"\(netshift_[0-9a-f]*\)/netshift".*#\1#p' "$$menu_file" 2>/dev/null | head -n 1)"
	if [ -n "$$active" ] && [ -d "$$view_dir/$$active" ]; then
		for dir in "$$view_dir"/netshift_* "$$view_dir"/netshift; do
			[ -d "$$dir" ] || continue
			[ "$$dir" = "$$view_dir/$$active" ] && continue
			rm -rf "$$dir"
		done
	fi
	exit 0
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)$(HTDOCS)
	$(CP) $(PKG_BUILD_DIR)/htdocs/* $(1)$(HTDOCS)/
	$(INSTALL_DIR) $(1)/
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g' $(1)$(HTDOCS)/luci-static/resources/view/netshift/main.js || true
	# Content-hashed view directory + rewritten requires/menu path, so a browser
	# cannot keep serving the previous version's JS after an update
	# (see cache-bust.sh). Must run after the version stamp above.
	sh "$(CURDIR)/cache-bust.sh" "$(1)$(HTDOCS)" "$(1)"
endef

$(eval $(call BuildPackage,$(PKG_NAME)))