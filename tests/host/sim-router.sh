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

# A TLS listener needs a real certificate, and the scenario that exercises it is
# skipped unless this socat has OpenSSL (the stock OpenWrt package does not).
SOCAT_HAS_SSL=0
socat -V 2>&1 | grep -q '#define WITH_OPENSSL' && SOCAT_HAS_SSL=1
TLS_DIR=/tmp/opencode/socat-sim-tls
TLS_C=$TLS_DIR/c.pem
TLS_K=$TLS_DIR/k.pem
mkdir -p "$TLS_DIR"
if [ "$SOCAT_HAS_SSL" = 1 ]; then
	openssl req -x509 -newkey rsa:2048 -keyout "$TLS_K" -out "$TLS_C" \
		-days 2 -nodes -subj "/CN=socat-sim-tls" >/dev/null 2>&1
fi

# Some of what the engine must accept (",user=nobody", a unix socket it chowns)
# only works as root.  Say so once instead of failing every scenario.
[ "$(id -u)" = "0" ] || echo "  (unprivileged: user=nobody is stripped from the fixtures)"

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
	sed -i "s|^LOGF=.*|LOGF=$SIM/engine-logfile.log|" "$SIM/socat-boot.sh"
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
	firewall) cat "$S/etc/firewall" 2>/dev/null; cat "$S/fw.sections" 2>/dev/null ;;
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
	echo "$2=$3" >> "$S/fw.log"
	case "$2" in
	firewall.socat_reforged_*=rule) echo "$2" >> "$S/fw.sections" ;;
	esac ;;
delete)
	case "$2" in
	*.socat_reforged_*)
		echo "delete $2" >> "$S/fw.log"
		grep -Fv "$2=" "$S/fw.sections" > "$S/fw.sections.t" 2>/dev/null
		mv "$S/fw.sections.t" "$S/fw.sections" 2>/dev/null ;;
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
"-o -6 addr show dev pppoe-wan") echo "3: pppoe-wan    inet6 2001:db8:2::9a91/64 scope global dynamic" ;;
"-o -6 addr show")
	case "$SC" in
	3) ;;
	*) echo "2: eth0.2    inet6 2001:db8:1::55/64 scope global dynamic" ;;
	esac ;;
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
# user=/retry= must be accepted by the real socat for every listener kind.  A
# "once" fixture value proves all of them, because the engine would otherwise
# kill the listener every cycle and the scenario would not come up.
socat.simhttp.user='nobody'
socat.simhttp.retry='5'
socat.simdns=config
socat.simdns.enable='1'
socat.simdns.remarks='dns'
socat.simdns.proto='udp'
socat.simdns.listen_port='21053'
socat.simdns.dest_proto='udp4'
socat.simdns.user='nobody'
socat.simdns.retry='5'
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
	8)
		# a port range must turn into one listener per port, and two rules
		# that share one port must not share their runtime bookkeeping
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
socat.simrange=config
socat.simrange.enable='1'
socat.simrange.proto=tcp
socat.simrange.listen_port='21090-21092'
socat.simrange.dest_proto='tcp4'
socat.simrange.dest_ip=192.168.1.10
socat.simrange.dest_port='80'
socat.simrange.firewall_accept='1'
socat.simclashA=config
socat.simclashA.enable='1'
socat.simclashA.proto=tcp
socat.simclashA.listen_port='21075'
socat.simclashA.dest_proto='tcp4'
socat.simclashA.dest_ip=192.168.1.10
socat.simclashA.dest_port='80'
socat.simclashA.firewall_accept='0'
socat.simclashB=config
socat.simclashB.enable='1'
socat.simclashB.proto=tcp
socat.simclashB.listen_port='21075'
socat.simclashB.dest_proto='tcp4'
socat.simclashB.dest_ip=192.168.1.20
socat.simclashB.dest_port='80'
socat.simclashB.firewall_accept='0'
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
	9)
		# a multicast listener and a unix-socket listener are both absent from
		# /proc/net/tcp: the engine must still see them (otherwise it respawns
		# them forever), and only the multicast rule may open an IGMP rule.
		cat > "$SIM/etc/socat" <<'EOF'
socat.reforged=internal
socat.simmcast=config
socat.simmcast.enable='1'
socat.simmcast.proto=udp
socat.simmcast.listen_port='21060'
socat.simmcast.mcast_group=239.10.10.10
socat.simmcast.dest_proto=tcp4
socat.simmcast.dest_ip=192.168.1.10
socat.simmcast.dest_port='80'
socat.simmcast.firewall_accept='1'
socat.simunix=config
socat.simunix.enable='1'
socat.simunix.proto=unix
socat.simunix.unix_path='/tmp/opencode/socat-sim/repo-sim/run/sim.sock'
socat.simunix.dest_proto=tcp4
socat.simunix.dest_ip=192.168.1.10
socat.simunix.dest_port='80'
socat.simunix.firewall_accept='1'
EOF
		cat > "$SIM/etc/firewall" <<'EOF'
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
	11)
		# a paused rule (temporary stop) and a peer allowlist: the paused rule
		# must not be started or open a WAN port, and the v4-only allowlist must
		# not leave an unrestricted v6 listener behind
		cat > "$SIM/etc/socat" <<'EOF'
socat.reforged=internal
socat.simpaused=config
socat.simpaused.enable='1'
socat.simpaused.proto=tcp
socat.simpaused.listen_port='21070'
socat.simpaused.src_allow='127.0.0.0/8'
socat.simpaused.dest_proto='tcp4'
socat.simpaused.dest_ip=192.168.1.10
socat.simpaused.dest_port='80'
socat.simpaused.firewall_accept='1'
socat.simfree=config
socat.simfree.enable='1'
socat.simfree.proto=tcp
socat.simfree.listen_port='21071'
socat.simfree.dest_proto='tcp4'
socat.simfree.dest_ip=192.168.1.10
socat.simfree.dest_port='80'
socat.simfree.firewall_accept='1'
EOF
		cat > "$SIM/etc/firewall" <<'EOF'
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
	10)
		# a TLS rule: the engine must see the OPENSSL-LISTEN worker like any
		# other, or it can never stop it again
		cat > "$SIM/etc/socat" <<EOF
socat.reforged=internal
socat.simtls=config
socat.simtls.enable='1'
socat.simtls.proto=ssl
socat.simtls.listen_port='21095'
socat.simtls.ssl_cert='$TLS_C'
socat.simtls.ssl_key='$TLS_K'
socat.simtls.dest_proto=tcp4
socat.simtls.dest_ip=192.168.1.10
socat.simtls.dest_port='80'
socat.simtls.firewall_accept='1'
EOF
		cat > "$SIM/etc/firewall" <<'EOF'
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
	# ",user=nobody" needs root: socat chowns a unix socket to that user, and
	# some builds need the privilege to resolve a datagram family.  Drop it when
	# the suite runs unprivileged instead of reporting a dead listener.
	if [ "$(id -u)" != "0" ]; then
		sed -i "/\.user='nobody'\$/d" "$SIM/etc/socat"
	fi
}

results() { # results -> "zones|listeners|srcs|errors"
	ZONES=$(tr '\n' ' ' < "$SIM/run/fw.zones" 2>/dev/null | sed 's/ $//')
	LIST=$(awk 'NR>1 && $4!="-"{print $2}' "$SIM/run/state" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
	SRC=$(grep -h '\.src=' "$SIM/fw.log" 2>/dev/null | sed 's/.*src=//; s/=$//' | sort -u | tr '\n' ' ' | sed 's/ $//')
	ERR=$(awk 'NR>1 && $5!="-"{print $1}' "$SIM/run/state" 2>/dev/null | tr '\n' ' ')
	printf '%s|%s|%s|%s' "$ZONES" "$LIST" "$SRC" "$ERR"
}

cleanup() {
	# Kill only our own workers: the engine stamps every socat it spawns with
	# SOCAT_SIM_MARKER in the environment, so an unrelated socat (a real port
	# forward on the test host) is never touched.  The old port-pattern list
	# (2108/2105/2103/2101) missed the multicast (21060) and unix listeners,
	# which leaked between scenarios and made later runs fail on EADDRINUSE.
	for p in $(pgrep socat 2>/dev/null); do
		grep -qs SOCAT_SIM_MARKER "/proc/$p/environ" 2>/dev/null && kill -9 "$p" 2>/dev/null
	done
	# a leftover sandbox engine (killed hard, no trap) must not survive either
	for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do
		kill -9 "$p" 2>/dev/null
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
	for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
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

echo "layout simulator (real engine, fake uci/ip, real socat, ${SECS}s each)"
echo

run_one 1 'wan'     'tcp tcp6 udp udp6' 'wan'
run_one 2 'ext'     'tcp tcp6 udp udp6' 'ext'
run_one 3 'wan'     'tcp'               'wan'
run_one 4 'wan wanb' 'tcp tcp6 udp udp6' 'wan wanb'
run_one 5 ''        'tcp tcp6 udp udp6' ''
run_one 6 'wan'     'tcp tcp6'          'wan'
run_one 7 ''        'tcp tcp6 udp udp6' ''

# scenario 8: a port range (one listener per port) + two rules sharing one
# port.  Run inline (not via run_one) so the per-rule runtime files can be
# inspected before the sandbox is torn down.
SC=8
prepare "$SC"
fixtures "$SC"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep "$SECS"
# the two rules sharing a port are retried independently, so a sample taken
# while one is being restarted sees both down (seen once on CI); the steady
# state has exactly one of them reporting the clash
clash_n() { awk 'NR>1 && $5!="-"{print $1}' "$SIM/run/state" 2>/dev/null | sort -u | grep -c .; }
prev=-1
for i in 1 2 3 4 5 6 7 8 9 10; do
	now=$(clash_n)
	[ "$now" = "$prev" ] && break
	prev=$now
	sleep 1
done
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
IFS='|' read -r Z L S E <<EOF
$(results)
EOF
check 'scenario 8: zones' 'wan' "$Z"
check 'scenario 8: range + clash listeners' 'tcp tcp tcp tcp tcp6 tcp6 tcp6 tcp6' "$L"
check 'scenario 8: firewall src zones' 'wan' "$S"
check 'scenario 8: exactly one clash error' 1 "$(clash_n)"
check 'scenario 8: per-rule pid files for a shared port' 4 \
	"$(ls "$SIM/run/pids" 2>/dev/null | grep -c '21075')"
check 'scenario 8: per-rule stderr files for a shared port' 4 \
	"$(ls "$SIM/run/err" 2>/dev/null | grep -c '21075')"
cleanup

# scenario 9: a multicast listener and a unix-socket listener.  Both kinds are
# missing from /proc/net/tcp, so this is the regression test for the discovery
# filter and the port parser: if they are not recognised the engine kills and
# respawns them every cycle (and the state file flips between up and down).
# Run inline: the firewall log and the state file are inspected directly.
SC=9
prepare "$SC"
fixtures "$SC"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep "$SECS"
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
IFS='|' read -r Z L S E <<EOF
$(results)
EOF
check 'scenario 9: zones' 'wan' "$Z"
check 'scenario 9: multicast + unix listeners' 'udp unix' "$L"
check 'scenario 9: firewall src zones' 'wan' "$S"
check 'scenario 9: no rule errors' '' "$E"
check 'scenario 9: the multicast rule opens a tcp/udp port' 1 "$(grep -c 'socat_reforged_udp_[0-9]*_[0-9]*\..*dest_port=21060' "$SIM/fw.log" 2>/dev/null)"
check 'scenario 9: ...and an IGMP accept rule' 1 "$(grep -c 'socat_reforged_igmp_[0-9]*_[0-9]*=rule' "$SIM/fw.log" 2>/dev/null)"
check 'scenario 9: the IGMP rule is proto igmp' 1 "$(grep -c 'socat_reforged_igmp_[0-9]*_[0-9]*\.proto=igmp' "$SIM/fw.log" 2>/dev/null)"
check 'scenario 9: the unix rule opens no port' 0 "$(grep -c 'socat_reforged_tcp' "$SIM/fw.log" 2>/dev/null)"
check 'scenario 9: the unix listener socket exists' 1 "$([ -S "$SIM/run/sim.sock" ] && echo 1 || echo 0)"
cleanup

# scenario 11: temporary pause + peer allowlist.  The pause marker is written
# before the engine starts; its expiry is then moved into the past and a
# one-shot reconcile must prune it and bring the rule back.
SC=11
prepare "$SC"
fixtures "$SC"
mkdir -p "$SIM/run/pause"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SIM/run/pause/simpaused"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep "$SECS"
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
IFS='|' read -r Z L S E <<EOF
$(results)
EOF
check 'scenario 11: zones' 'wan' "$Z"
check 'scenario 11: only the unpaused rule listens' 'tcp tcp6' "$L"
check 'scenario 11: no rule errors' '' "$E"
check 'scenario 11: the paused port stays closed' 0 "$(grep -c 'dest_port=21070' "$SIM/fw.log" 2>/dev/null)"
check 'scenario 11: the free rule opens its port' 1 "$(grep -c 'dest_port=21071' "$SIM/fw.log" 2>/dev/null)"
check 'scenario 11: the paused rule contributes no listener' 0 \
	"$(grep -c '21070' "$SIM/run/desired" 2>/dev/null)"
check 'scenario 11: a v4-only allowlist drops the v6 listener' 0 \
	"$(grep -c 'range=127.0.0.0/8.*TCP6\|TCP6.*range=127.0.0.0/8' "$SIM/run/desired" 2>/dev/null)"
check 'scenario 11: a paused rule emits no warning' 0 \
	"$(grep -c 'no IPv6 range' "$SIM/engine-logfile.log" 2>/dev/null)"

# expire the marker: the next reconcile prunes it and the rule comes back
printf '%s\n' "$(( $(date +%s) - 60 ))" > "$SIM/run/pause/simpaused"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" reconcile >/dev/null 2>&1
sleep 1
check 'scenario 11: an expired pause marker is removed' 0 \
	"$(ls "$SIM/run/pause" 2>/dev/null | grep -c simpaused)"
check 'scenario 11: the rule runs again after expiry' 1 \
	"$(grep -c '^simpaused tcp 21070 ' "$SIM/run/state" 2>/dev/null)"
check 'scenario 11: the v6 narrowing is logged once it runs' 1 \
	"$(grep -c 'no IPv6 range' "$SIM/engine-logfile.log" 2>/dev/null)"
check 'scenario 11: the allowlist reaches the running command' 1 \
	"$(grep -c 'range=127.0.0.0/8' "$SIM/run/desired" 2>/dev/null)"
cleanup

# ---- a TLS listener must be visible to the engine ---------------------------
# OPENSSL-LISTEN was missing from both of the engine's listener-kind lists, so a
# TLS worker was invisible: deleting its rule left the listener running, Stop
# never killed it, and the worker count was short.  Only a socat built with
# OpenSSL can show this, so the scenario is skipped without one.
if [ "$SOCAT_HAS_SSL" = 1 ]; then
	SC=10
	prepare "$SC"
	fixtures "$SC"
	PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
	LOOP=$!
	sleep "$SECS"
	kill "$LOOP" 2>/dev/null
	wait "$LOOP" 2>/dev/null
	for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
	sleep 1
	check 'scenario 10: the TLS listener is tracked' 1 \
		"$(awk 'NR>1 && $2=="ssltcp" && $4!="-"' "$SIM/run/state" 2>/dev/null | grep -c .)"
	# 21095 == 0x5267 in /proc/net/tcp
	check 'scenario 10: ...and it is really listening' 1 \
		"$(awk 'FNR>1 && toupper($2) ~ /:5267$/ && $4=="0A"' /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -c .)"
	# drop the rule: the engine must stop the listener it started itself
	cat > "$SIM/etc/socat" <<'EOF'
socat.reforged=internal
EOF
	PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
	LOOP=$!
	sleep "$SECS"
	kill "$LOOP" 2>/dev/null
	wait "$LOOP" 2>/dev/null
	for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
	sleep 1
	check 'scenario 10: the deleted TLS listener is gone' 0 \
		"$(awk 'FNR>1 && toupper($2) ~ /:5267$/ && $4=="0A"' /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -c .)"
	cleanup
else
	echo "  (scenario 10 skipped: this socat is built without OpenSSL)"
fi

# ---- the engine keeps a persistent, capped log file ------------------------
# syslog's ring buffer is small and wiped on reboot, so every line also goes to
# $LOGF (64 KiB cap, newest half kept).  The layout is irrelevant here, so this
# only re-uses scenario 1 with a 2s cycle.
prepare 1
fixtures 1
sed -i "s|^INTERVAL=15|INTERVAL=2|" "$SIM/socat-boot.sh"
# the proof-of-life line is 15 min on a router; one cycle is enough here
sed -i "s|^ALIVE_EVERY=60|ALIVE_EVERY=1|" "$SIM/socat-boot.sh"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep 5
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1

TOTAL=$(wc -l < "$SIM/engine-logfile.log" 2>/dev/null | tr -d ' ')
STAMPED=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$SIM/engine-logfile.log" 2>/dev/null)
check "engine log: file is created" 1 "$([ -s "$SIM/engine-logfile.log" ] && echo 1 || echo 0)"
check "engine log: records the start" 1 "$(grep -c 'engine started' "$SIM/engine-logfile.log" 2>/dev/null)"
check "engine log: enough lines for a cycle" 1 "$([ "${TOTAL:-0}" -ge 2 ] && echo 1 || echo 0)"
check "engine log: every line is timestamped" "${TOTAL:-0}" "${STAMPED:-0}"
check "engine log: keeps a proof of life" 1 "$([ "$(grep -c 'alive: workers=' "$SIM/engine-logfile.log" 2>/dev/null)" -ge 1 ] && echo 1 || echo 0)"

# beyond the cap only the newest half survives (the marker is at the very end)
head -c 200000 /dev/zero | tr '\0' 'x' > "$SIM/engine-logfile.log"
echo '2026-10-13 00:00:00 marker line' >> "$SIM/engine-logfile.log"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep 4
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
SIZE=$(wc -c < "$SIM/engine-logfile.log" 2>/dev/null | tr -d ' ')
check "engine log: capped at 64 KiB" 1 "$([ "${SIZE:-0}" -le 65536 ] && echo 1 || echo 0)"
check "engine log: keeps the newest half" 1 "$(grep -c 'marker line' "$SIM/engine-logfile.log" 2>/dev/null)"
cleanup

# ---- a failed fw4 check must stamp the time of the attempt ------------------
# The backoff parses the epoch out of the fail marker.  A marker written
# without one ("fail <sig> " — the write used a variable that was only
# assigned *inside* the backoff branch) cannot be parsed, so after a first
# failure the engine retried one cycle later instead of after FW_RETRY
# seconds, fighting a broken firewall every 15s.  The fake fw4 check fails
# while fw.check.ok is absent; the engine is stopped as soon as it has
# written the marker, so exactly one attempt is observed either way.
prepare 1
fixtures 1
rm -f "$SIM/fw.check.ok"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
i=0
while [ ! -s "$SIM/run/fw.sig" ] && [ "$i" -lt 60 ]; do sleep 0.2; i=$((i + 1)); done
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
check "fw fail: the marker records the attempt" 1 "$(grep -c '^fail ' "$SIM/run/fw.sig" 2>/dev/null)"
# ... and it ends in the epoch (a trailing space means "no epoch written")
check "fw fail: the marker ends in an epoch" 1 "$(grep -cE '^fail [0-9]+ ' "$SIM/run/fw.sig" 2>/dev/null)"
contains "fw fail: the backoff is logged" 'retry in 5 min' "$(cat "$SIM/engine-logfile.log" 2>/dev/null)"

# the read path: a marker that says "failed seconds ago" must block a rebuild
: > "$SIM/fw.log"
printf 'fail %s z:wan|f:' "$(( $(awk '{printf "%d", $1}' /proc/uptime) - 5 ))" > "$SIM/run/fw.sig"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep 4
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
check "fw backoff: a fresh fail marker blocks a rebuild" '' "$(cat "$SIM/fw.log" 2>/dev/null)"
cleanup

# ---- an emptied firewall port list must really be emptied -------------------
# The generator opens its fw file only when it has a line to write, so the
# engine has to truncate it itself.  Without that the previous ports survive,
# the firewall signature never changes, and the WAN accept rule of a forward
# whose firewall_accept was turned off stays open forever.
prepare 3
fixtures 3
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep "$SECS"
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
check 'fw stale: the first run opened the port' 1 "$(grep -c 'dest_port=21081' "$SIM/fw.log" 2>/dev/null)"
check 'fw stale: the port list holds it' 1 "$(grep -c '21081' "$SIM/run/fw" 2>/dev/null)"
# stop wanting the accept rule; nothing else about the rule changes
sed -i "s/^socat.simhttp.firewall_accept='1'/socat.simhttp.firewall_accept='0'/" "$SIM/etc/socat"
: > "$SIM/fw.log"
PATH="$SIM/bin:$PATH" sh "$SIM/socat-boot.sh" >/dev/null 2>&1 &
LOOP=$!
sleep "$SECS"
kill "$LOOP" 2>/dev/null
wait "$LOOP" 2>/dev/null
for p in $(pgrep -f "$SIM/socat-boot.sh" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
sleep 1
check 'fw stale: the port list is emptied' '' "$(cat "$SIM/run/fw" 2>/dev/null)"
check 'fw stale: the old accept rule is gone' 0 "$(grep -c 'dest_port=21081' "$SIM/fw.log" 2>/dev/null)"
check 'fw stale: the engine deletes its own rules' 1 \
	"$([ "$(grep -c 'delete firewall.socat_reforged_' "$SIM/fw.log" 2>/dev/null)" -ge 1 ] && echo 1 || echo 0)"
cleanup

rm -rf "$SIM" "$TLS_DIR"
summary 'OpenWrt layout simulator'
