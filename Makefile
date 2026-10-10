# luci-app-socat-reforged V1  (self-upstream)
# OpenWrt 25.x ucode-native LuCI for the custom socat forwarding engine.
# A ground-up rewrite ("reforged") of the classic Lua/CBI socat page, which
# cannot run on 25.x (no /usr/lib/lua tree). Distinct name to avoid clashing
# with luci-app-socat.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-socat-reforged
PKG_VERSION:=V1
PKG_RELEASE:=1

PKG_MAINTAINER:=busybin <65460344+busybin@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI support for Socat (Reforged, custom engine)
LUCI_DEPENDS:=+luci-base +socat
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
