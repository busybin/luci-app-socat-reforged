# luci-app-socat-reforged v1.0.2  (self-upstream)
# OpenWrt 25.x ucode-native LuCI for the custom socat forwarding engine.
# A ground-up rewrite ("reforged") of the classic Lua/CBI socat page, which
# cannot run on 25.x (no /usr/lib/lua tree). Distinct name to avoid clashing
# with luci-app-socat.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-socat-reforged
PKG_VERSION:=1.0.2
PKG_RELEASE:=1

PKG_MAINTAINER:=busybin <65460344+busybin@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

LUCI_TITLE:=LuCI support for Socat (Reforged, custom engine)
LUCI_DEPENDS:=+luci-base +socat
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
