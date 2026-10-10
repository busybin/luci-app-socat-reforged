# luci-app-socat-reforged V2  (self-upstream)
# OpenWrt 25.x ucode-native LuCI for the custom socat forwarding engine.
# A ground-up rewrite ("reforged") of the classic Lua/CBI socat page, which
# cannot run on 25.x (no /usr/lib/lua tree). Distinct name to avoid clashing
# with luci-app-socat.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-socat-reforged
PKG_VERSION:=V2
PKG_RELEASE:=1

PKG_MAINTAINER:=busybin <65460344+busybin@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI support for Socat (Reforged, custom engine)
LUCI_DEPENDS:=+luci-base +socat
LUCI_PKGARCH:=all

# The package ships the engine (/etc/socat-boot.sh) and its procd service
# (/etc/init.d/socat-reforged). Enable the service on install and migrate off
# a legacy init that runs the same engine, so only one loop can ever run.
define Package/luci-app-socat-reforged/postinst
[ -n "$${IPKG_INSTROOT}" ] || { \
	[ -f /etc/config/socat ] || {
		uci set socat.reforged=internal
		uci set socat.reforged.note='managed by luci-app-socat-reforged'
		uci commit socat
	}
	if [ -f /etc/init.d/socat ] && grep -q socat-boot.sh /etc/init.d/socat 2>/dev/null; then
		/etc/init.d/socat stop >/dev/null 2>&1
		/etc/init.d/socat disable >/dev/null 2>&1
		rm -f /etc/rc.d/S*socat /etc/rc.d/K*socat
	fi
	ubus call service delete '{"name":"socat"}' >/dev/null 2>&1
	/etc/init.d/socat-reforged enable
	/etc/init.d/socat-reforged restart
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
