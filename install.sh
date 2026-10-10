#!/bin/sh
# luci-app-socat-reforged installer V2 — idempotent, network-safe.
# Deploys the LuCI UI + ACL + config-change trigger; removes stale files
# from the old package name (luci-app-socat / luci_socat / luci_socat_reforged).
# The forwarding ENGINE (/etc/socat-boot.sh) is only touched with
# --with-engine, and then the running loop is killed so procd respawns it
# from the new file (a plain "/etc/init.d/socat restart" does NOT reload a
# replaced script!).
# Usage: ./install.sh [--with-engine]
set -eu
WITH_ENGINE=0
for a in "$@"; do
  case "$a" in
    --with-engine) WITH_ENGINE=1 ;;
  esac
done
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

# --- new files ---
inst files/usr/share/luci/menu.d/luci-app-socat-reforged.json /usr/share/luci/menu.d/luci-app-socat-reforged.json 644
inst files/www/luci-static/resources/view/network/socat-reforged.js /www/luci-static/resources/view/network/socat-reforged.js 644
inst files/usr/share/ucitrack/luci-app-socat-reforged.json /usr/share/ucitrack/luci-app-socat-reforged.json 644
inst files/usr/share/rpcd/acl.d/luci-app-socat-reforged.json /usr/share/rpcd/acl.d/luci-app-socat-reforged.json 644
inst files/usr/libexec/socat-reforged-reload /usr/libexec/socat-reforged-reload 755
inst files/usr/libexec/socat-reforged-ctl /usr/libexec/socat-reforged-ctl 755

# Re-register procd config triggers so Save&Apply works without a reboot.
/etc/init.d/ucitrack restart >/dev/null 2>&1 || true

if [ "$WITH_ENGINE" = "1" ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  cp -p /etc/socat-boot.sh "/etc/socat-boot.sh.bak.$TS"
  cp "$HERE/files/opt/socat-engine/socat-boot.sh" /etc/socat-boot.sh
  chmod 755 /etc/socat-boot.sh
  sh -n /etc/socat-boot.sh && echo "engine syntax OK (backup: $TS)"
  for p in $(pgrep -f '/etc/socat-boot.sh$' 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  echo "old engine loop killed; procd will respawn it from the new file"
fi

rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
echo "done. Open LuCI -> Network -> Socat Reforged."
