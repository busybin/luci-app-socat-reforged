#!/bin/sh
# ============================================================================
# tests/host/sim-router.sh — run the real engine against other OpenWrt layouts
# ============================================================================
# Boots a copy of the engine in a sandbox with:
#   * fake `uci`  (fixture files instead of /etc/config)
#   * fake `ip`   (whatever WAN device / IPv6 the scenario needs)
#   * real `socat` (the listeners are really started, on 210xx ports)
# and then asserts what the engine did: which listeners exist, which firewall
# zone(s) the accept rules went to, and whether it refused to guess.
#
# Usage: sh sim-router.sh [scenario ...]     (default: all)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

REPO=$(cd "$HERE/../.." && pwd)
SIM=/tmp/opencode/socat-sim/repo-sim
SECS=${SIM_SECS:-9}

prepare() { # prepare <scenario>
	SC="$1"
	rm -rf "$SIM"; mkdir -p "$SIM/bin" "$SIM/etc" "$SIM/run"
	cp "$REPO/root/etc/socat-boot.sh" "$SIM/socat-boot.sh"
	cp "$REPO/root/usr/libexec/socat-reforged-gen.awk"   "$SIM/gen.awk"
	cp "$REPO/root/usr/libexec/socat-reforged-zones.awk" "$SIM/zones.awk"
	chmod 755 "$SIM/socat-boot.sh"

	# point the engine at the sandbox
	sed -i "s|^RUNDIR=.*|RUNDIR=$SIM/run|"          "$SIM/socat-boot.sh"
	sed -i "s|^GPROG=.*|GPROG=$SIM/gen.awk|"        "$SIM/socat-boot.sh"
	sed -i "s|^ZONES_AWK=.*|ZONES_AWK=$SIM/zones.awk|" "$SIM/socat-boot.sh"
	sed -i "s|^CFG=.*|CFG=$SIM/etc/socat|"          "$SIM/socat-boot.sh"
	sed -i "s|^HB=.*|HB=$SIM/run/socat-reforged.hb|" "$SIM/socat-boot.sh"
	sed -i "s|^MARKER=.*|MARKER=SOCAT_SIM_MARKER|"  "$SIM/socat-boot.sh"
	sed -i "s|^\([[:space:]]*\)SOCAT_REFORGED=1 |\1SOCAT_SIM_MARKER=1 |" "$SIM/socat-boot.sh"
	# the engine resolves tools first from its own PATH; put the sandbox in front
	sed -i "s|^PATH=.*|PATH=$SIM/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|" "$SIM/socat-boot.sh"
	# fw4 does not exist on the test host: use a fake, and call it via PATH
	sed -i 's|/sbin/fw4|fw4|g; s|/etc/init.d/firewall|firewall-init|g' "$SIM/socat-boot.sh"
	sed -i 's|\[ -x fw4 \]|command -v fw4 >/dev/null|' "$SIM/socat-boot.sh"

	cat > "$SIM/bin/uci" <<'EOF'
#!/bin/sh
S=$(dirname "$0")/..
[ "$1" = "-q" ] && shift
case "$1" in
show)
	case "$2" in
	socat)    cat "$S/etc/socat"    2>/dev/null ;;
	firewall) cat "$S/etc/firewall" 2>/dev/null ;;
	network)  cat "$S/etc/network"  2>/dev/null ;;
	esac ;;
get)
	ref="$2"
	cfg=${ref%%.*}; rest=${ref#*.}
	sec=${rest%%.*}; opt=${rest#*.}
	if [ "$sec" = "reforged" ]; then
		grep -m1 "^$opt=" "$S/etc/reforged" 2>/dev/null | cut -d= -f2-
		exit 0
	fi
	grep -m1 "^$sec\\.$opt=" "$S/etc/$cfg" 2>/dev/null | sed "s/^$sec\\.$opt=//" ;;
set)
	echo "$2=$3" >> "$S/fw.log" ;;
delete)
	case "$2" in
	*.socat_reforged_*) echo "delete $2" >> "$S/fw.log" ;;
	esac ;;
add_list)
	echo "$2+=$3" >> "$S/fw.log" ;;
commit) : > "$S/fw.applied" ;;
esac
exit 0
EOF
	cat > "$SIM/bin/fw4" <<'EOF'
#!/bin/sh
S=$(dirname "$0")/..
case "$1" in
check)  [ -f "$S/fw.check.ok" ] || exit 1; exit 0 ;;
reload) echo "fw4 reload" >> "$S/fw.log"; exit 0 ;;
esac
exit 0
EOF
	cat > "$SIM/bin/firewall-init" <<'EOF'
#!/bin/sh
echo "firewall-init $*" >> "$(dirname "$0")/../fw.log"
exit 0
EOF
	cat > "$SIM/bin/logger" <<'EOF'
#!/bin/sh
tag="socat-boot"; msg=""
while [ $# -gt 0 ]; do
	case "$1" in
	-t) tag="$2"; shift 2 ;;
	*)  msg="$msg $1"; shift ;;
	esac
done
echo "$tag:$msg" >> "$(dirname "$0")/../engine.log"
EOF
	# fake ip: the WAN device and IPv6 depend on the scenario
	cat > "$SIM/bin/ip" <<EOF
#!/bin/sh
case "\$*" in
"route show default")
	case "$SC" in
	3) echo "default via 192.168.9.1 dev eth1 proto dhcp src 192.168.9.55" ;;
	6) echo "default via 100.64.0.1 dev pppoe-wan proto static" ;;
	*) echo "default via 192.168.1.1 dev eth0.2 proto dhcp src 192.168.1.55" ;;
	esac ;;
"-6 route show default")
	case "$SC" in
	3) ;;                                     # no IPv6 at all
	*) echo "default from 2001:db8:1::/64 via fe80::1 dev eth0.2 proto ra metric 1024" ;;
	esac ;;
"-o -6 addr show dev eth0.2")    echo "2: eth0.2    inet6 2001:db8:1::55/64 scope global dynamic" ;;
"-o -6 addr show dev eth1")      : ;;
"-o -6 addr show dev pppoe-wan") echo "3: pppoe-wan    inet6 2001:db8:2:::9a91/64 scope global dynamic" ;;
"-o -6 addr show")
	case "$SC" in
	3) ;;
	*) echo "2: eth0.2    inet6 2001:db8:1::55/64 scope global dynamic" ;;
	esac ;;
"route show 2000::/3") : ;;
*) : ;;
esac
exit 0
EOF
	chmod +x "$SIM/bin"/*
	: > "$SIM/fw.check.ok"
}

fixtures() { # fixtures <scenario>
	cat > "$SIM/etc/network" <<'EOF'
network.loopback=interface
network.loopback.device=lo
network.lan=interface
network.lan.device=br-lan
network.wan=interface
network.wan.device=eth0.2
network.wan.proto=dhcp
EOF
	cat > "$SIM/etc/socat" <<'EOF'
socat.reforged=internal
socat.reforged.note='simulated router'
socat.simhttp=config
socat.simhttp.enable='1'
socat.simhttp.remarks='web'
socat.simhttp.proto='tcp'
socat.simhttp.listen_port='21080'
socat.simhttp.dest_proto='tcp4'
socat.simhttp.dest_ip='192.168.1.10'
socat.simhttp.dest_port='80'
socat.simhttp.firewall_accept='1'
socat.simdns=config
socat.simdns.enable='1'
socat.simdns.remarks='dns'
socat.simdns.proto='udp'
socat.simdns.listen_port='21053'
socat.simdns.dest_proto='udp4'
socat.simdns.dest_ip='192.168.1.11'
socat.simdns.dest_port='53'
socat.simdns.firewall_accept='1'
EOF
	case "$SC" in
	3)
		cat > "$SIM/etc/network" <<'EOF'
network.wan=interface
network.wan.device=eth1
network.wan.proto=dhcp
EOF
		cat > "$SIM/etc/socat" <<'EOF'
socat.reforged=internal
socat.reforged.note='no ipv6 here'
socat.simhttp=config
socat.simhttp.enable='1'
socat.simhttp.proto='tcp'
socat.simhttp.listen_port='21081'
socat.simhttp.dest_proto='tcp4'
socat.simhttp.dest_ip='192.168.1.10'
socat.simhttp.dest_port='80'
socat.simhttp.firewall_accept='1'
EOF
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].input=ACCEPT
firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan
firewall.@zone[1].input=REJECT
EOF
		;;
	5)
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].input=ACCEPT
EOF
		;;
	7)
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].network=lan
firewall.@zone[1]=zone
firewall.@zone[1].network=wan
firewall.@zone[1].input=REJECT
EOF
		;;
	6)
		cat > "$SIM/etc/network" <<'EOF'
network.loopback=interface
network.loopback.device=lo
network.lan=interface
network.lan.device=br-lan
network.wan=interface
network.wan.device=eth0
network.wan.proto=pppoe
EOF
		cat > "$SIM/etc/socat" <<'EOF'
socat.reforged=internal
socat.simhttp=config
socat.simhttp.enable='1'
socat.simhttp.proto='tcp'
socat.simhttp.listen_port='21083'
socat.simhttp.dest_proto='tcp4'
socat.simhttp.dest_ip='192.168.1.10'
socat.simhttp.dest_port='80'
socat.simhttp.firewall_accept='1'
EOF
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6
firewall.@zone[1].device=eth0 pppoe-wan
firewall.@zone[1].input=REJECT
EOF
		;;
	2)
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].input=ACCEPT
firewall.ext=zone
firewall.ext.name=ext
firewall.ext.network=wan
firewall.ext.input=REJECT
EOF
		;;
	4)
		cat >> "$SIM/etc/network" <<'EOF'
network.wanb=interface
network.wanb.device=eth0.2
network.wanb.proto=dhcp
EOF
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name=wan
firewall.@zone[0].network=wan
firewall.@zone[0].input=REJECT
firewall.@zone[1]=zone
firewall.@zone[1].name=wanb
firewall.@zone[1].network=wanb
firewall.@zone[1].input=REJECT
EOF
		;;
	*)
		cat > "$SIM/etc/firewall" <<'EOF'
firewall.@defaults[0]=defaults
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[0].input=ACCEPT
firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6
firewall.@zone[1].input=REJECT
EOF
		;;
	esac
}

results() { # results -> "zones|listeners|srcs|errors"
	ZONES=$(tr '\n' ' ' < "$SIM/run/fw.zones" 2>/dev/null | sed 's/ $//')
	LIST=$(awk 'NR>1 && $4!="-"{print $2}' "$SIM/run/state" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
	SRC=$(grep -h '\.src=' "$SIM/fw.log" 2>/dev/null | sed 's/.*src=//; s/=$//' | sort -u | tr '\n' ' ' | sed 's/ $//')
	ERR=$(awk 'NR>1 && $5!="-"{print $1}' "$SIM/run/state" 2>/dev/null | tr '\n' ' ')
	printf '%s|%s|%s|%s' "$ZONES" "$LIST" "$SRC" "$ERR"
}

cleanup() {
	for p in $($PG /proc/[0-9]*/cmdline 2>/dev/null); do :; done
	# kill only the simulated listeners (210xx ports)
	for p in $(pgrep socat 2>/dev/null); do
		read -r c < "/proc/$p/cmdline" 2>/dev/null
		case "$c" in *2108*|*2105*|*2103*|*2101*) kill -9 "$p" 2>/dev/null ;; esac
	done
	rm -rf "$SIM"
}

run_one() { # run_one <scenario> <expected zones> <expected listener kinds> <expected src zones>
	SC="$1"
	prepare "$SC"
	fixtures "$SC"
	PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
	LOOP=$!
	sleep "$SECS"
	kill "$LOOP" 2>/dev/null
	wait "$LOOP" 2>/dev/null
	for p in $(pgrep -f 'socat-reforged-sim/socat-boot.sh' 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
	sleep 1

	IFS='|' read -r Z L S E <<EOF
$(results)
EOF
	check "scenario $SC: zones" "$2" "$Z"
	check "scenario $SC: listeners" "$3" "$L"
	check "scenario $SC: firewall src zones" "$4" "$S"
	check "scenario $SC: no rule errors" '' "$E"
	cleanup
}

PG=x   # (kept for readability of cleanup; the real loop is below)

echo "layout simulator (real engine, fake uci/ip, real socat, ${SECS}s each)"
echo

run_one 1 'wan'     'tcp tcp6 udp udp6' 'wan'
run_one 2 'ext'     'tcp tcp6 udp udp6' 'ext'
run_one 3 'wan'     'tcp'               'wan'
run_one 4 'wan wanb' 'tcp tcp6 udp udp6' 'wan wanb'
run_one 5 ''        'tcp tcp6 udp udp6' ''
run_one 6 'wan'     'tcp tcp6'          'wan'
run_one 7 ''        'tcp tcp6 udp udp6' ''

rm -rf "$SIM"
summary 'OpenWrt layout simulator'
