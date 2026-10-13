# luci-app-socat-reforged — release V3 (self-upstream)
# V3 is the engine/UI rework: portable IPv6, single-pass config parsing,
# per-rule error reporting, robust listener identity, crash diagnostics.
# Versioning: tag / Release = "V3", PKG_VERSION = "3" (see below).
# OpenWrt 25.x ucode-native LuCI for the custom socat forwarding engine.
# A ground-up rewrite ("reforged") of the classic Lua/CBI socat page, which
# cannot run on 25.x (no /usr/lib/lua tree). Distinct name to avoid clashing
# with luci-app-socat.
#
# Versioning: the git tag / GitHub Release use "V<integer>" (V2, V3, ...), but
# PKG_VERSION must be a bare number because the apk format (OpenWrt 25.x /
# snapshot) rejects versions that do not start with a digit. So PKG_VERSION is
# the release integer without the "V" (V2 -> 2).

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-socat-reforged
PKG_VERSION:=3
PKG_RELEASE:=1

PKG_MAINTAINER:=busybin <65460344+busybin@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI support for Socat (Reforged, custom engine)
LUCI_DEPENDS:=+luci-base +socat +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci
LUCI_PKGARCH:=all

# The package ships the engine (/etc/socat-boot.sh + the generator awk in
# /usr/libexec) and its procd service (/etc/init.d/socat-reforged). Enable the
# service on install and migrate off a legacy init that runs the same engine,
# so only one loop can ever run.
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
		cp -p /etc/init.d/socat /root/init.d.socat.bak.$$$(date +%Y%m%d-%H%M%S) 2>/dev/null
		rm -f /etc/init.d/socat
	fi
	ubus call service delete '{"name":"socat"}' >/dev/null 2>&1
	ubus call service delete '{"name":"socat-reforged"}' >/dev/null 2>&1
	for p in $$(pgrep -f '/etc/socat-boot.sh$' 2>/dev/null); do kill -9 "$$p" 2>/dev/null; done
	[ -x /etc/socat-boot.sh ] && /etc/socat-boot.sh cleanup >/dev/null 2>&1
	/etc/init.d/socat-reforged enable
	/etc/init.d/socat-reforged restart
	{ echo "PKG_VERSION=$(PKG_VERSION)-$(PKG_RELEASE)"; \
	  echo "BUILD=$(PKG_VERSION)-$(PKG_RELEASE)"; \
	  echo "BUILT=package"; } > /usr/libexec/socat-reforged-version
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache /tmp/luci-modulecache.*
	/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart
	exit 0
}
endef
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
