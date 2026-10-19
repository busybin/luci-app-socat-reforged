# luci-app-socat-reforged — release V5 (self-upstream)
# V5 is the "works on a stock router, and from the form" sweep: the engine
# settings save on a box whose /etc/config/socat belongs to the official socat
# package, the form accepts what the generator accepts (mcast_iface dots,
# reuseaddr / proxy validation, ports 1-65535), conflicts account for the
# transport and address family, a rule no longer inherits the previous rule's
# ,reuseaddr, and a value that happens to be "config" no longer truncates a rule.
# Versioning: tag / Release = "V5", PKG_VERSION = "5" (see below).
# OpenWrt 25.x ucode-native LuCI for the custom socat forwarding engine.
# A ground-up rewrite ("reforged") of the classic Lua/CBI socat page, which
# cannot run on 25.x (no /usr/lib/lua tree). Distinct name to avoid clashing
# with luci-app-socat.
#
# Versioning: the git tag / GitHub Release use "V<integer>" (V2, V3, ...), but
# PKG_VERSION must be a bare number because the apk format (OpenWrt 25.x /
# snapshot) rejects versions that do not start with a digit. So PKG_VERSION is
# the release integer without the "V" (V2 -> 2).
#
# +uclient-fetch is for the "check for updates / update now" button: it is the
# HTTPS downloader that ships with the base system (curl/wget are fallbacks).

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-socat-reforged
PKG_VERSION:=5
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI support for Socat (Reforged, custom engine)
LUCI_DESCRIPTION:=Port forwarding manager backed by a self-healing custom socat \
	engine: TCP/UDP over IPv4 and IPv6, TLS, unix sockets and multicast, with a \
	procd service, per-rule live status and a ucode backend.
LUCI_DEPENDS:=+luci-base +socat +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci +uclient-fetch
LUCI_PKGARCH:=all
# luci.mk reads these two (a bare PKG_MAINTAINER is silently dropped, and URL
# then falls back to the LuCI feed).
LUCI_MAINTAINER:=busybin <65460344+busybin@users.noreply.github.com>
LUCI_URL:=https://github.com/busybin/luci-app-socat-reforged

# The package ships the engine (/etc/socat-boot.sh + the generator awk in
# /usr/libexec) and its procd service (/etc/init.d/socat-reforged). Enable the
# service on install and migrate off a legacy init that runs the same engine,
# so only one loop can ever run.
#
# This is a Makefile `define`, not a plain script, so the escaping matters:
# `$$` becomes `$`, a *bare* `$'` silently loses the dollar (which made the
# pgrep pattern below an unterminated quote and broke the whole postinst), and
# `$$$(` expands to `$(` as a make variable reference (which turned the backup
# name into a literal "$").  Shell substitutions need `$$(`, literal dollars
# need `$$`.
define Package/luci-app-socat-reforged/postinst
[ -n "$${IPKG_INSTROOT}" ] || { \
	[ -f /etc/config/socat ] || : > /etc/config/socat; \
	if ! uci -q get socat.reforged >/dev/null 2>&1; then
		uci set socat.reforged=internal
		uci set socat.reforged.note='managed by luci-app-socat-reforged'
		uci commit socat
	fi
	if [ -f /etc/init.d/socat ] && grep -q socat-boot.sh /etc/init.d/socat 2>/dev/null; then
		/etc/init.d/socat stop >/dev/null 2>&1
		/etc/init.d/socat disable >/dev/null 2>&1
		rm -f /etc/rc.d/S*socat /etc/rc.d/K*socat
		cp -p /etc/init.d/socat /root/init.d.socat.bak.$$(date +%Y%m%d-%H%M%S) 2>/dev/null
		rm -f /etc/init.d/socat
	fi
	ubus call service delete '{"name":"socat"}' >/dev/null 2>&1
	ubus call service delete '{"name":"socat-reforged"}' >/dev/null 2>&1
	for p in $$(pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$$' 2>/dev/null); do kill -9 "$$p" 2>/dev/null; done
	[ -x /etc/socat-boot.sh ] && /etc/socat-boot.sh cleanup >/dev/null 2>&1
	# apk will not overwrite a file whose content differs from the one it
	# installed (a tree deployed with deploy.sh, say) and parks the packaged
	# copy as <file>.apk-new -- take those BEFORE starting the new engine, or
	# this upgrade runs the previous engine while the page shows the new one.
	[ -x /usr/libexec/socat-reforged-apply-deferred ] && \
		/usr/libexec/socat-reforged-apply-deferred >/dev/null 2>&1
	/etc/init.d/socat-reforged enable
	/etc/init.d/socat-reforged restart
	{ echo "PKG_VERSION=$(PKG_VERSION)-$(PKG_RELEASE)"; \
	  echo "BUILD=$(PKG_VERSION)-$(PKG_RELEASE)"; \
	  echo "BUILT=package"; } > /usr/libexec/socat-reforged-version
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache*
	/etc/init.d/rpcd reload 2>/dev/null || /etc/init.d/rpcd restart
	exit 0
}
endef
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
