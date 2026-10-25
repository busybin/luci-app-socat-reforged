#!/bin/sh
# luci-app-socat-reforged uninstaller — stops and removes everything this
# package installed.  Your rules in /etc/config/socat are KEPT unless you pass
# --purge.
#
# Usage: sh uninstall.sh [--purge]
set -eu
HERE=$(dirname "$0")
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "stopping the engine ..."
/etc/init.d/socat-reforged stop >/dev/null 2>&1 || true
/etc/init.d/socat-reforged disable >/dev/null 2>&1 || true
for p in $(pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
[ -x /etc/socat-boot.sh ] && /etc/socat-boot.sh cleanup >/dev/null 2>&1 || true

echo "removing firewall rules ..."
uci show firewall 2>/dev/null \
	| sed -n 's/^firewall\.\(socat_reforged_[A-Za-z0-9_]*\)=.*/\1/p' \
	| while read -r s; do
		[ -n "$s" ] && uci -q delete "firewall.$s" 2>/dev/null || true
	done
uci commit firewall 2>/dev/null || true
if command -v fw4 >/dev/null 2>&1 && fw4 check >/dev/null 2>&1; then
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
fi

echo "removing package files ..."
rm -f /etc/init.d/socat-reforged
rm -f /etc/rc.d/S*socat-reforged /etc/rc.d/K*socat-reforged
rm -f /etc/hotplug.d/iface/99-socat-reforged
rm -f /etc/socat-boot.sh
rm -f /etc/socat-boot.sh.bak.*
rm -f /usr/libexec/socat-reforged-gen.awk
rm -f /usr/libexec/socat-reforged-zones.awk
rm -f /usr/libexec/socat-reforged-ctl
rm -f /usr/libexec/socat-reforged-update
rm -f /usr/libexec/socat-reforged-apply-deferred
rm -f /usr/libexec/socat-reforged-reload
rm -f /usr/libexec/socat-reforged-version
rm -f /usr/share/rpcd/ucode/luci.socat-reforged.uc
rm -f /usr/share/rpcd/acl.d/luci-app-socat-reforged.json
rm -f /usr/share/luci/menu.d/luci-app-socat-reforged.json
rm -f /usr/share/ucitrack/luci-app-socat-reforged.json
rm -f /www/luci-static/resources/view/network/socat-reforged.js
rm -rf /var/run/socat-reforged
rm -f /var/log/socat-reforged.log
rm -f /tmp/socat-reforged-update.state /tmp/socat-reforged-update.log
rm -rf /tmp/socat-reforged-update.d

if [ "$PURGE" = "1" ]; then
	echo "purging /etc/config/socat (all forwarding rules) ..."
	rm -f /etc/config/socat
else
	echo "keeping /etc/config/socat (your forwarding rules; --purge removes it)"
fi

rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache /tmp/luci-modulecache.*
/etc/init.d/rpcd reload >/dev/null 2>&1 || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
echo "done."
