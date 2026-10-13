#!/bin/sh
# ============================================================================
# tests/host/zones-cases.sh — unit tests for WAN zone detection
# ============================================================================
# Feeds fake `uci show network` / `uci show firewall` output to the real
# detector and asserts the zone(s) it reports.  This is the guard against the
# package only working on the author's own firewall layout.
#
# Usage: sh zones-cases.sh [path-to-zones.awk]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

REPO=$(cd "$HERE/../.." && pwd)
ZONES="${1:-$REPO/root/usr/libexec/socat-reforged-zones.awk}"
WORK=$HERE/.work
rm -rf "$WORK"; mkdir -p "$WORK"

echo "zone detector: $ZONES"
echo

zones() { # zones <device>   (fixtures in $WORK/net / $WORK/fw)
	printf '' > "$WORK/out"
	{ cat "$WORK/net"; echo "%FIREWALL%"; cat "$WORK/fw"; } \
		| awk -v dev="$1" -f "$ZONES" > "$WORK/out"
	tr '\n' ' ' < "$WORK/out"
}

zcase() { # zcase <label> <device> <expected zones> <network fixture> <firewall fixture>
	printf '%s\n' "$4" > "$WORK/net"
	printf '%s\n' "$5" > "$WORK/fw"
	check "$1" "$3" "$(zones "$2")"
}

# 1. the common case: zone "wan" whose network list names the interface
zcase 'classic DHCP, default zone name' eth0.2 'wan ' \
'network.lan=interface
network.lan.device=br-lan
network.wan=interface
network.wan.device=eth0.2' \
'firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].input=ACCEPT
firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6
firewall.@zone[1].input=REJECT'

# 2. PPPoE: the zone lists the *device*, not the interface
zcase 'pppoe-wan matched via the device list' pppoe-wan 'wan ' \
'network.lan=interface
network.lan.device=br-lan
network.wan=interface
network.wan.device=eth0' \
'firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6
firewall.@zone[1].device=eth0 pppoe-wan'

# 3. renamed zone, named section (no name option)
zcase 'renamed zone with a named section' eth1 'ext ' \
'network.wan=interface
network.wan.device=eth1' \
'firewall.ext=zone
firewall.ext.network=wan
firewall.ext.input=REJECT'

# 4. renamed zone via option name
zcase 'renamed zone via option name' eth1 'ext ' \
'network.wan=interface
network.wan.device=eth1' \
'firewall.@zone[1]=zone
firewall.@zone[1].name=ext
firewall.@zone[1].network=wan'

# 5. zone referenced only by device
zcase 'device-only zone' wlan0 'wwanzone ' \
'network.wwan=interface
network.wwan.device=wlan0' \
'firewall.@zone[2]=zone
firewall.@zone[2].name=wwanzone
firewall.@zone[2].device=wlan0'

# 6. multi-WAN: two zones cover the same device
zcase 'multi-WAN gives both zones' eth0.2 'wan wanb ' \
'network.wan=interface
network.wan.device=eth0.2
network.wanb=interface
network.wanb.device=eth0.2' \
'firewall.@zone[0]=zone
firewall.@zone[0].name=wan
firewall.@zone[0].network=wan
firewall.@zone[1]=zone
firewall.@zone[1].name=wanb
firewall.@zone[1].network=wanb'

# 7. anonymous zone without a name option: fw4 cannot reference it
zcase 'nameless anonymous zone is skipped' eth0.2 '' \
'network.wan=interface
network.wan.device=eth0.2' \
'firewall.@zone[1]=zone
firewall.@zone[1].network=wan'

# 8. nothing matches -> empty (the caller must then not write rules)
zcase 'unmappable layout' eth9 '' \
'network.wan=interface
network.wan.device=eth0.2' \
'firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan'

# 9. no firewall config at all
zcase 'no firewall config' eth0.2 '' '' ''

# 10. ifname instead of device
zcase 'ifname variant' eth0.3 'wan ' \
'network.wan=interface
network.wan.ifname=eth0.3' \
'firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan'

# 11. values quoted the way `uci show` prints them
zcase 'quoted list values' eth0.2 'wan ' \
"network.wan=interface
network.wan.device='eth0.2'" \
"firewall.@zone[1]=zone
firewall.@zone[1].name='wan'
firewall.@zone[1].network='wan wan6'"

# 12. no device at all -> empty
zcase 'empty device' '' '' \
'network.wan=interface
network.wan.device=eth0.2' \
'firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan'

rm -rf "$WORK"
summary 'zone detection unit tests'
