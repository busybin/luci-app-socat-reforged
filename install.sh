#!/bin/sh
# luci-app-socat-reforged installer — V6 (2026-10).
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
  # a copy the package manager deferred is older than what we just installed
  rm -f "$2.apk-new" "$2.opkg-new"
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
inst root/usr/libexec/socat-reforged-update /usr/libexec/socat-reforged-update 755
inst root/usr/libexec/socat-reforged-apply-deferred /usr/libexec/socat-reforged-apply-deferred 755
inst root/usr/libexec/socat-reforged-gen.awk /usr/libexec/socat-reforged-gen.awk 644
inst root/usr/libexec/socat-reforged-zones.awk /usr/libexec/socat-reforged-zones.awk 644

# --- dependency check (manual installs have no opkg to resolve these) -------
missing=""
command -v socat >/dev/null 2>&1 || missing="$missing socat"
command -v ucode >/dev/null 2>&1 || missing="$missing ucode"
command -v ubus  >/dev/null 2>&1 || missing="$missing ubus"
if command -v ucode >/dev/null 2>&1; then
  for m in uci fs; do
    ucode -e "import * as x from '$m';" >/dev/null 2>&1 || missing="$missing ucode-mod-$m"
  done
fi
if [ -n "$missing" ]; then
  echo "WARNING: missing dependencies:$missing"
  echo "         the engine needs socat; the LuCI page also needs ubus + ucode"
  echo "         (ucode-mod-uci, ucode-mod-fs and rpcd-mod-ucode)."
  echo "         On OpenWrt: opkg install$missing"
fi

# --- stamp the version the UI shows (what is installed, not what git says) --
VER=/usr/libexec/socat-reforged-version
PKG_VER=$(sed -n 's/^PKG_VERSION:=//p' "$HERE/Makefile" 2>/dev/null | tr -d ' ')
[ -n "$PKG_VER" ] || PKG_VER=devel
# build id, in order of preference: explicit argument, a stamp shipped inside
# the tarball (.build-stamp), git, else "devel"
BUILD="${1:-}"
if [ -z "$BUILD" ] && [ -n "${SOCAT_BUILD:-}" ]; then BUILD="$SOCAT_BUILD"; fi
if [ -z "$BUILD" ] && [ -f "$HERE/.build-stamp" ]; then BUILD=$(cat "$HERE/.build-stamp"); fi
if [ -z "$BUILD" ]; then BUILD=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo devel); fi
{
  echo "PKG_VERSION=$PKG_VER"
  echo "BUILD=$BUILD"
  echo "BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$VER"
echo "stamped $VER ($PKG_VER / $BUILD)"

# --- outgoing engine + its service (self-contained) ---
TS=$(date +%Y%m%d-%H%M%S)
[ -f /etc/socat-boot.sh ] && cp -p /etc/socat-boot.sh "/etc/socat-boot.sh.bak.$TS"
# installs are idempotent and repeatable; keep only the 5 most recent backups
ls -1t /etc/socat-boot.sh.bak.* 2>/dev/null | tail -n +6 | while read -r b; do rm -f "$b"; done
if inst root/etc/socat-boot.sh /etc/socat-boot.sh 755 && sh -n /etc/socat-boot.sh; then
  echo "engine syntax OK (backup: $TS)"
else
  echo "FATAL: new engine failed its syntax check; restoring the backup"
  [ -f "/etc/socat-boot.sh.bak.$TS" ] && cp -p "/etc/socat-boot.sh.bak.$TS" /etc/socat-boot.sh
  exit 1
fi
inst root/etc/init.d/socat-reforged /etc/init.d/socat-reforged 755
inst root/etc/hotplug.d/iface/99-socat-reforged /etc/hotplug.d/iface/99-socat-reforged 755

# --- make sure the config + our engine section exist (menu/form expect it) ---
# The official socat package ships /etc/config/socat, and an old install may
# predate the section, so "the file exists" is not enough: without
# socat.reforged every engine setting silently refuses to save (LuCI's
# uci.set() no-ops on a missing section).
[ -f /etc/config/socat ] || : > /etc/config/socat   # uci set cannot create the file
if ! uci -q get socat.reforged >/dev/null 2>&1; then
  uci set socat.reforged=internal
  uci set socat.reforged.note='managed by luci-app-socat-reforged'
  uci commit socat
  echo "created the engine settings section (socat.reforged) in /etc/config/socat"
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
# procd swallows a start issued while it is still tearing the old instance down
# (observed: the box was left with its workers up and no engine running), so
# wait for the old loop to disappear and check that a new one really came up
for i in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' >/dev/null 2>&1 || break
  sleep 1
done
for p in $(pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
# drop runtime state of the previous engine (workers are re-adopted/killed by
# the new one, which only ever touches its own marker processes)
[ -x /etc/socat-boot.sh ] && /etc/socat-boot.sh cleanup >/dev/null 2>&1 || true
/etc/init.d/socat-reforged enable >/dev/null 2>&1 || true
engine_up() { pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' >/dev/null 2>&1; }
/etc/init.d/socat-reforged start >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  engine_up && break
  /etc/init.d/socat-reforged start >/dev/null 2>&1 || true
  sleep 1
done
engine_up || echo "WARNING: the engine did not come up; run /etc/init.d/socat-reforged start"

# --- triggers + caches ---
/etc/init.d/ucitrack restart >/dev/null 2>&1 || true
rm -f  /tmp/luci-indexcache     2>/dev/null || true
rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache /tmp/luci-modulecache.* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
echo "done. Open LuCI -> Network -> Socat Reforged."
