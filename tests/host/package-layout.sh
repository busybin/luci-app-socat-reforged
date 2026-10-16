#!/bin/sh
# ============================================================================
# tests/host/package-layout.sh — what the *package* looks like on a device
# ============================================================================
# Every other suite tests the code.  This one tests the thing users actually
# install, because three defects lived exactly there and no suite could see
# them:
#
#   * the engine, the procd init script and the ctl helper were committed
#     without the executable bit, and luci.mk ships `root/` with `cp -pR`, so
#     the package installed them 0644: procd could not start the service,
#     `/etc/socat-boot.sh` could not be run, and the LuCI Start/Stop buttons
#     failed with "permission denied";
#   * the postinst in the Makefile used `$$$(date ...)` and a bare `$'`, and a
#     Makefile `define` expands the first to `$(` and eats the second, so the
#     *shipped* postinst was a syntax error ("Unterminated quoted string") and
#     never created the config or enabled the service;
#   * `PKG_MAINTAINER` is not read by luci.mk (it is `LUCI_MAINTAINER`), so the
#     package metadata fell back to "OpenWrt LuCI community" and the LuCI URL.
#
# Usage: sh tests/host/package-layout.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

MK=$REPO/Makefile
WORK=$HERE/.work-pkg
rm -rf "$WORK"; mkdir -p "$WORK"

# ------------------------------------------------------------------ bits ----
# files that are executed on the device (by procd, by ucitrack, by the UI)
execs="root/etc/socat-boot.sh
root/etc/init.d/socat-reforged
root/etc/hotplug.d/iface/99-socat-reforged
root/usr/libexec/socat-reforged-ctl
root/usr/libexec/socat-reforged-update
root/usr/libexec/socat-reforged-reload"
# ...and the scripts a user runs from a checkout
for f in install.sh deploy.sh uninstall.sh; do execs="$execs
$f"; done

for f in $execs; do
	[ -x "$REPO/$f" ] && mode=yes || mode=no
	check "$f is executable" yes "$mode"
done

# data files only need to be readable (the engine runs awk -f on them)
for f in root/usr/libexec/socat-reforged-gen.awk root/usr/libexec/socat-reforged-zones.awk \
         root/usr/share/rpcd/ucode/luci.socat-reforged.uc htdocs/luci-static/resources/view/network/socat-reforged.js; do
	[ -r "$REPO/$f" ] && [ -s "$REPO/$f" ] && r=yes || r=no
	check "$f is readable and non-empty" yes "$r"
done

# ------------------------------------------------------------- layout -------
# luci.mk installs `root/` -> / and `htdocs/` -> /www; it does *not* know
# `files/`, which is how an empty package was shipped once.
check 'no files/ dir (luci.mk would ignore it)' 0 "$([ -d "$REPO/files" ] && echo 1 || echo 0)"
check 'the view is where luci.mk puts it' 1 \
	"$([ -f "$REPO/htdocs/luci-static/resources/view/network/socat-reforged.js" ] && echo 1 || echo 0)"
check 'the engine is under root/' 1 "$([ -f "$REPO/root/etc/socat-boot.sh" ] && echo 1 || echo 0)"
check 'the rpcd backend is under root/' 1 \
	"$([ -f "$REPO/root/usr/share/rpcd/ucode/luci.socat-reforged.uc" ] && echo 1 || echo 0)"

# --------------------------------------------------------- Makefile meta ----
check 'PKG_VERSION is a bare number (apk needs that)' 1 "$(grep -cE '^PKG_VERSION:=[0-9]+$' "$MK")"
check 'LUCI_MAINTAINER is set (PKG_MAINTAINER is ignored)' 1 "$(grep -cE '^LUCI_MAINTAINER:=' "$MK")"
check 'LUCI_URL points at this repository' 1 \
	"$(grep -cE '^LUCI_URL:=https://github.com/busybin/luci-app-socat-reforged' "$MK")"
check 'LUCI_DESCRIPTION is set (package description)' 1 "$(grep -cE '^LUCI_DESCRIPTION:=' "$MK")"
check 'no stale PKG_MAINTAINER' 0 "$(grep -cE '^PKG_MAINTAINER:=' "$MK")"

# -------------------------------------------------- postinst under make -----
# The postinst is a Makefile `define`: `$$` becomes `$`, a bare `$'` loses the
# dollar and `$$$(` becomes `$(`.  Two static checks for the known shapes...
cat > "$WORK/scan.awk" <<'AWK'
# comments may quote the traps on purpose (that is how the next person learns
# about them); only real recipe lines are scanned
/^[[:space:]]*#/ { next }
/[^$]\$'/  { barequote++ }
/\$\$\$\(/ { triple++ }
END { printf "%d %d\n", barequote+0, triple+0 }
AWK
set -- $(awk -f "$WORK/scan.awk" "$MK")
check 'no bare $ before a quote (make eats the dollar)' 0 "$1"
check 'no $$$( in the Makefile (make expands it)' 0 "$2"

# ...and, when make is available, the real thing: expand the define exactly the
# way the OpenWrt build does and syntax-check the result.
if command -v make >/dev/null 2>&1; then
	awk '/^define Package\/luci-app-socat-reforged\/postinst$/{f=1;next} /^endef$/{f=0} f' "$MK" > "$WORK/body.mk"
	{
		echo 'define X'
		cat "$WORK/body.mk"
		echo 'endef'
		echo '$(info $(X))'
		echo 'all:'
		printf '\t@true\n'
	} > "$WORK/expand.mk"
	make -f "$WORK/expand.mk" > "$WORK/postinst.sh" 2>"$WORK/make.err"
	grep -v '^make' "$WORK/postinst.sh" > "$WORK/postinst.clean"
	mv "$WORK/postinst.clean" "$WORK/postinst.sh"
	if sh -n "$WORK/postinst.sh" 2>"$WORK/syntax.err"; then rc=0; else rc=1; fi
	check 'the expanded postinst is valid shell' 0 "$rc"
	has 'the backup name keeps its command substitution' '.bak.$(date +' "$(cat "$WORK/postinst.sh")"
	has 'the pgrep pattern keeps its anchor and quote' "'/etc/socat-boot.sh\$'" "$(cat "$WORK/postinst.sh")"
else
	printf '  %-46s %s\n' 'the expanded postinst is valid shell' '(skipped: no make)'
fi

# --------------------------------------------- install.sh keeps the bits ----
# the manual path must chmod what it copies (that is why a manual deploy works
# while the package was broken)
check 'install.sh installs the engine 755' 1 "$(grep -c 'root/etc/socat-boot.sh /etc/socat-boot.sh 755' "$REPO/install.sh")"
check 'install.sh installs the init script 755' 1 "$(grep -c 'root/etc/init.d/socat-reforged /etc/init.d/socat-reforged 755' "$REPO/install.sh")"
check 'install.sh installs the ctl helper 755' 1 "$(grep -c 'root/usr/libexec/socat-reforged-ctl /usr/libexec/socat-reforged-ctl 755' "$REPO/install.sh")"
check 'install.sh keeps data files 644' 1 "$(grep -c 'socat-reforged-gen.awk /usr/libexec/socat-reforged-gen.awk 644' "$REPO/install.sh")"

# ------------------------------------------------ self-update stays runnable --
# the "Update now" button exec's this helper through rpcd, and the ACL has to
# grant the three update methods (the view calls them, and an ungranted method
# only fails in the browser)
check 'install.sh installs the self-update helper 755' 1 \
	"$(grep -c 'root/usr/libexec/socat-reforged-update /usr/libexec/socat-reforged-update 755' "$REPO/install.sh")"
sh -n "$REPO/root/usr/libexec/socat-reforged-update" 2>/dev/null && rc=0 || rc=1
check 'the self-update helper is valid shell' 0 "$rc"
acl=$REPO/root/usr/share/rpcd/acl.d/luci-app-socat-reforged.json
for m in update_check update_status update_install; do
	check "the ACL grants $m" 1 "$(grep -c "\"$m\"" "$acl")"
done
check 'the backend implements update_install' 1 \
	"$(grep -c 'update_install: {' "$REPO/root/usr/share/rpcd/ucode/luci.socat-reforged.uc")"

rm -rf "$WORK"
summary 'package layout'
