#!/bin/sh
# luci-app-socat-reforged installer — unreleased 2026-10 work (next: V3).
# Idempotent, network-safe.
#
# Self-contained: installs the LuCI UI + rpcd backend + ACL + the forwarding
# ENGINE (/etc/socat-boot.sh + /usr/libexec/socat-reforged-gen.awk) + its procd
# service (/etc/init.d/socat-reforged).
# If a legacy init that runs /etc/socat-boot.sh is found (e.g. from a custom
# socat build) it is stopped and removed so only ONE engine loop can run.
# The existing /etc/config/socat is never overwritten.
# Usage: ./install.sh
set -eu
HERE=$(dirname "$0")
inst() { # src dst mode
  mkdir -p "$(dirname "$2")"
  cp "$HERE/$1" "$2"
  chmod "$3" "$2"
  echo "installed $2"
}

# --- stale files from older package names/methods ---
rm -f /usr/share/luci/menu.d/luci-app-socat.json \
      /usr/share/ucitrack/luci-app-socat.json \
      /www/luci-static/resources/view/network/socat.js \
      /etc/init.d/luci_socat \
      /etc/init.d/luci_socat_reforged \
      /etc/rc.d/S99luci_socat_reforged \
      /etc/rc.d/K10luci_socat_reforged 2>/dev/null || true

# --- app files (mirrors the package layout: root/ -> /, htdocs/ -> /www) ---
inst root/usr/share/luci/menu.d/luci-app-socat-reforged.json /usr/share/luci/menu.d/luci-app-socat-reforged.json 644
inst htdocs/luci-static/resources/view/network/socat-reforged.js /www/luci-static/resources/view/network/socat-reforged.js 644
inst root/usr/share/ucitrack/luci-app-socat-reforged.json /usr/share/ucitrack/luci-app-socat-reforged.json 644
inst root/usr/share/rpcd/acl.d/luci-app-socat-reforged.json /usr/share/rpcd/acl.d/luci-app-socat-reforged.json 644
inst root/usr/share/rpcd/ucode/luci.socat-reforged.uc /usr/share/rpcd/ucode/luci.socat-reforged.uc 644
inst root/usr/libexec/socat-reforged-reload /usr/libexec/socat-reforged-reload 755
inst root/usr/libexec/socat-reforged-ctl /usr/libexec/socat-reforged-ctl 755
inst root/usr/libexec/socat-reforged-gen.awk /usr/libexec/socat-reforged-gen.awk 644

# --- outgoing engine + its service (self-contained) ---
TS=$(date +%Y%m%d-%H%M%S)
[ -f /etc/socat-boot.sh ] && cp -p /etc/socat-boot.sh "/etc/socat-boot.sh.bak.$TS"
if inst root/etc/socat-boot.sh /etc/socat-boot.sh 755 && sh -n /etc/socat-boot.sh; then
  echo "engine syntax OK (backup: $TS)"
else
  echo "FATAL: new engine failed its syntax check; restoring the backup"
  [ -f "/etc/socat-boot.sh.bak.$TS" ] && cp -p "/etc/socat-boot.sh.bak.$TS" /etc/socat-boot.sh
  exit 1
fi
inst root/etc/init.d/socat-reforged /etc/init.d/socat-reforged 755

# --- make sure the config exists (menu/form expect it) ---
if [ ! -f /etc/config/socat ]; then
  uci set socat.reforged=internal
  uci set socat.reforged.note='managed by luci-app-socat-reforged'
  uci commit socat
  echo "created /etc/config/socat (placeholder section)"
fi

# --- migrate off a legacy init that runs our engine ---
if [ -f /etc/init.d/socat ] && grep -q 'socat-boot.sh' /etc/init.d/socat 2>/dev/null; then
  /etc/init.d/socat stop >/dev/null 2>&1 || true
  /etc/init.d/socat disable >/dev/null 2>&1 || true
  rm -f /etc/rc.d/S*socat /etc/rc.d/K*socat 2>/dev/null || true
  cp -p /etc/init.d/socat "/root/init.d.socat.bak.$TS" 2>/dev/null || true
  rm -f /etc/init.d/socat 2>/dev/null || true
  echo "removed legacy /etc/init.d/socat (backup: /root/init.d.socat.bak.$TS)"
fi

# --- (re)start the engine from the freshly installed file ---
ubus call service delete '{"name":"socat"}' >/dev/null 2>&1 || true
ubus call service delete '{"name":"socat-reforged"}' >/dev/null 2>&1 || true
for p in $(pgrep -f '/etc/socat-boot.sh$' 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
# drop runtime state of the previous engine (workers are re-adopted/killed by
# the new one, which only ever touches its own marker processes)
[ -x /etc/socat-boot.sh ] && /etc/socat-boot.sh cleanup >/dev/null 2>&1 || true
/etc/init.d/socat-reforged enable >/dev/null 2>&1 || true
/etc/init.d/socat-reforged start >/dev/null 2>&1 || true

# --- triggers + caches ---
/etc/init.d/ucitrack restart >/dev/null 2>&1 || true
rm -f  /tmp/luci-indexcache     2>/dev/null || true
rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache /tmp/luci-modulecache.* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
echo "done. Open LuCI -> Network -> Socat Reforged."
