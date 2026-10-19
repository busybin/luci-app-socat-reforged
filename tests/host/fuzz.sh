#!/bin/sh
# ============================================================================
# tests/host/fuzz.sh — adversarial values through the generator
# ============================================================================
# The generator is the only place that turns a config value into part of a shell
# command, so the whitelist has to hold for every option and every hostile value.
# This feeds one hostile value to every option at once (each in its own rule, so
# one bad value cannot mask another) and asserts the invariants that hold for
# ANY input:
#
#   1. the generator never crashes (exit 0) and never writes to stderr
#   2. a rule with an unvalidatable value produces NO listener at all
#   3. no generated command, key or firewall line contains a shell metacharacter
#   4. no target address is glued to the option before it (same check as the
#      matrix, applied to hostile input)
#
# Usage: sh tests/host/fuzz.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

WORK=$HERE/.work-fuzz
GEN="${1:-$REPO/root/usr/libexec/socat-reforged-gen.awk}"
rm -rf "$WORK"; mkdir -p "$WORK"

# A hostile value for each option, with a *valid* fallback value for the rest.
# Each rule gets a fresh sid; the ones that must be refused are listed in BAD.
# the warn file is tab-separated; format it like gen-cases.sh does so the
# assertions can be written as "sid:reason"
warns() { awk -F'\t' '{printf "%s:%s ", $1, $2}' "$WORK/warn" 2>/dev/null; }

BADS=''
i=0

# A hostile value is only reachable when the rule is actually configured for
# that option (a mcast_iface on a plain tcp rule is ignored, by design), so each
# case states the profile it needs.  The hostile option is written LAST so it
# cannot be overwritten by the profile's own baseline.
BAD=''

# emit_case <sid> <profile> <option> <value>
emit_case() { # emit_case <sid> <profile> <option> <value>
	local sid="$1" prof="$2" opt="$3" val="$4"
	printf 'socat.f%s=config\n' "$sid" >> "$WORK/in.show"
	printf 'socat.f%s.enable=1\n' "$sid" >> "$WORK/in.show"
	case "$prof" in
	tcp)
		printf 'socat.f%s.proto=tcp\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.listen_port=8%03d\n' "$sid" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=tcp4\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_ip=10.0.0.9\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_port=80\n' "$sid" >> "$WORK/in.show"
		;;
	unix)
		printf 'socat.f%s.proto=unix\n' "$sid" >> "$WORK/in.show"
		printf "socat.f%s.unix_path='/var/run/ok.sock'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=tcp4\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_ip=10.0.0.9\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_port=80\n' "$sid" >> "$WORK/in.show"
		;;
	ssl)
		printf 'socat.f%s.proto=ssl\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.listen_port=8%03d\n' "$sid" "$sid" >> "$WORK/in.show"
		printf "socat.f%s.ssl_cert='/etc/ssl/c.pem'\n" "$sid" >> "$WORK/in.show"
		printf "socat.f%s.ssl_key='/etc/ssl/k.pem'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=ssl\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_ip=10.0.0.9\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_port=443\n' "$sid" >> "$WORK/in.show"
		;;
	mcast)
		printf 'socat.f%s.proto=udp\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.listen_port=8%03d\n' "$sid" "$sid" >> "$WORK/in.show"
		printf "socat.f%s.mcast_group='239.10.10.10'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=mcast\n' "$sid" >> "$WORK/in.show"
		printf "socat.f%s.mcast_dst_group='239.10.10.20'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.mcast_dst_port=5000\n' "$sid" >> "$WORK/in.show"
		;;
	mcastdial)
		# relays INTO a group without joining one: mcast_iface reaches the dial
		# address here, and the receive-side validation never runs
		printf 'socat.f%s.proto=udp\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.listen_port=8%03d\n' "$sid" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=mcast\n' "$sid" >> "$WORK/in.show"
		printf "socat.f%s.mcast_dst_group='239.10.10.20'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.mcast_dst_port=5000\n' "$sid" >> "$WORK/in.show"
		;;
	v6tcp)
		printf 'socat.f%s.proto=tcp\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.listen_port=8%03d\n' "$sid" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=tcp6\n' "$sid" >> "$WORK/in.show"
		printf "socat.f%s.dest_ip='2001:db8::77'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_port=80\n' "$sid" >> "$WORK/in.show"
		;;
	proxy)
		printf 'socat.f%s.proto=tcp\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.listen_port=8%03d\n' "$sid" "$sid" >> "$WORK/in.show"
		printf "socat.f%s.proxy='socks4a'\n" "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_proto=tcp4\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_ip=10.0.0.9\n' "$sid" >> "$WORK/in.show"
		printf 'socat.f%s.dest_port=80\n' "$sid" >> "$WORK/in.show"
		;;
	esac
	printf "socat.f%s.%s='%s'\n" "$sid" "$opt" "$val" >> "$WORK/in.show"
}

add_bad() { # add_bad <sid> <profile> <option> <value>
	emit_case "$1" "$2" "$3" "$4"
	BAD="$BAD $1"
}

add_ok() { # add_ok <sid> <profile> <option> <value>
	emit_case "$1" "$2" "$3" "$4"
}

: > "$WORK/in.show"

# ---- values that must be refused -------------------------------------------
add_bad 1 tcp 'dest_ip'     '10.0.0.9;reboot'
add_bad 2 tcp 'dest_ip'     '10.0.0.9$(id)'
add_bad 3 tcp 'dest_ip'     '10.0.0.9`id`'
add_bad 4 tcp 'dest_ip'     '10.0.0.9|id'
add_bad 5 tcp 'dest_ip'     '10.0.0.9&&id'
add_bad 6 tcp 'dest_ip'     '../etc/passwd'
add_bad 7 tcp 'dest_ip'     'a b'
add_bad 9 tcp 'dest_ip'     '10.0.0.9 -T9'
add_bad 10 tcp 'dest_port'   '80;id'
add_bad 11 tcp 'dest_port'   '-1'
add_bad 12 tcp 'dest_port'   '65536'
add_bad 13 tcp 'dest_port'   '0'
add_bad 14 tcp 'dest_port'   ' 80'
add_bad 15 tcp 'dest_port'   '80 '
add_bad 16 tcp 'listen_port' '80 90'
add_bad 17 tcp 'listen_port' '80-'
add_bad 18 tcp 'listen_port' 'a-90'
add_bad 19 tcp 'listen_port' '0-65535'
add_bad 20 tcp 'listen_port' '80000-90000'
add_bad 21 tcp 'proto'       'tcp; id'
add_bad 22 tcp 'proto'       'TCP'
add_bad 23 tcp 'proto'       'tcp '
add_bad 24 tcp 'dest_proto'  'tcp4; id'
add_bad 25 tcp 'family'      '4; id'
add_bad 26 tcp 'family'      '44'
add_bad 27 tcp 'user'        'nobody;reboot'
add_bad 28 tcp 'user'        'nobody id'
add_bad 29 tcp 'user'        '../etc/passwd'
add_bad 30 tcp 'user'        '-oProxyCommand=id'
add_bad 31 tcp 'retry'       '3;id'
add_bad 32 tcp 'retry'       '3x'
add_bad 33 tcp 'retry'       '-3'
add_bad 34 tcp 'retry'       '99999'
add_bad 35 tcp 'nodelay'     '2'
add_bad 36 tcp 'nodelay'     'yes'
add_bad 37 tcp 'keepalive'   '1 '
add_bad 38 tcp 'reuseaddr'   'true'
add_bad 39 tcp 'system_log'  'on'
add_bad 40 tcp 'backlog'     '0'
add_bad 41 tcp 'backlog'     '70000'
add_bad 42 tcp 'backlog'     '5;id'
add_bad 43 tcp 'max_children' '0'
add_bad 44 tcp 'max_children' '5,6'
add_bad 45 tcp 'timeout'     '0'
add_bad 46 tcp 'timeout'     '999999'
add_bad 47 tcp 'timeout'     '5x'
add_bad 48 unix 'unix_path' 'relative.sock'
add_bad 49 unix 'unix_path' '/var/run/a.sock;id'
add_bad 50 unix 'unix_path' '/var/run/../etc/passwd'
add_bad 51 ssl 'ssl_cert'   'no-leading-slash.pem'
add_bad 52 ssl 'ssl_cert'    '/etc/ssl/a b.pem'
add_bad 53 ssl 'ssl_key'     '/etc/ssl/k.pem;id'
add_bad 54 mcast 'mcast_group' 'not-a-group'
add_bad 55 mcast 'mcast_group' '10.0.0.1'
add_bad 56 mcast 'mcast_group' '999.1.1.1'
add_bad 58 mcast 'mcast_dst_port' '0'
add_bad 59 mcast 'mcast_dst_port' '70000'
add_bad 60 mcast 'mcast_ttl'  '0'
add_bad 61 mcast 'mcast_ttl'  '300'
add_bad 62 mcast 'mcast_loop' '2'
add_bad 63 proxy 'proxy'      'id'
add_bad 65 proxy 'proxy_server' '1.2.3.4;id'
add_bad 66 proxy 'proxy_port'   '0'
add_bad 67 proxy 'proxy_port'   '99999'
add_bad 68 tcp 'listen_addr' '10.0.0.1;id'
add_bad 69 ssl 'ssl_verify'  '2'
add_bad 70 mcast 'mcast_iface' 'eth0.2;id'
add_bad 71 tcp 'enable'      '2'

# ---- IPv6: each of these is a case the IPv6 round fixed ----------------------
# socat rejects a v6 literal in a v4 address on connect ("TCP4: wrong number of
# parameters"), so the rule would look healthy and forward nothing.
add_bad 72 tcp 'dest_ip'    '2001:db8::99'
add_bad 73 tcp 'dest_ip'    '::1'
add_bad 74 tcp 'dest_ip'    'fe80::1'
add_bad 75 tcp 'dest_ip'    '2001:db8::99 '
add_bad 76 tcp 'dest_ip'    ' 2001:db8::99'
add_bad 77 tcp 'dest_ip'    '2001:db8::99;id'
add_bad 78 tcp 'dest_ip'    '2001:db8::99$(id)'
add_bad 79 tcp 'dest_ip'    '2001:db8::99|id'
add_bad 80 tcp 'dest_ip'    '2001:db8::99`id`'
add_bad 81 tcp 'dest_ip'    '2001:db8::99&&id'
add_bad 82 tcp 'dest_ip'    '2001:db8::99 -T9'
# a v6 literal cannot be expressed in SOCKS4A:/PROXY: (the colons are the field
# separator), neither as the proxy nor as the target
add_bad 83 proxy 'proxy_server' '2001:db8::1'
add_bad 84 proxy 'dest_ip'   '2001:db8::99'
# multicast receive is UDP4-only, so an IPv6-only multicast rule has no listener
add_bad 85 mcast 'family'    '6'
# ...and the mirror image of 72: a v4 literal in a tcp6/udp6 dial is refused by
# getaddrinfo on every connect, so the rule would bind and forward nothing
add_bad 87 v6tcp 'dest_ip'   '10.0.0.9'
# a relay rule (dest_proto=mcast, no joined group) still puts mcast_iface in the
# dial address: it must be checked there too, not only on the receive side
add_bad 86 mcastdial 'mcast_iface' 'eth0 -T99 evil'


# ---- values that must be ACCEPTED (the whitelist is not a blanket no) ------
add_ok 101 tcp 'dest_ip'     'example.org'
add_ok 102 tcp 'dest_ip'     '10.0.0.1'
add_ok 103 v6tcp 'dest_ip'     '::1'
add_ok 104 v6tcp 'dest_ip'     '2001:db8::1'
add_ok 105 tcp 'dest_port'   '1'
add_ok 106 tcp 'dest_port'   '65535'
add_ok 107 tcp 'listen_port' '1'
add_ok 108 tcp 'listen_port' '65535'
add_ok 109 tcp 'listen_port' '9000-9005'
add_ok 110 tcp 'user'        'nobody'
add_ok 111 tcp 'user'        'a-b_c'
add_ok 112 tcp 'retry'       '0'
add_ok 113 tcp 'retry'       '3600'
add_ok 114 tcp 'nodelay'     '0'
add_ok 115 tcp 'keepalive'   '0'
add_ok 116 tcp 'reuseaddr'   '0'
add_ok 117 tcp 'system_log'  '1'
add_ok 118 tcp 'backlog'     '128'
add_ok 119 tcp 'max_children' '256'
add_ok 120 tcp 'timeout'     '86400'
add_ok 121 proxy 'proxy'     'socks4a'
add_ok 133 proxy 'proxy'     'socks4'
add_ok 134 proxy 'proxy'     'http'
add_ok 123 proxy 'proxy'     'proxy'
add_ok 124 proxy 'proxy'     'none'
add_ok 125 tcp 'listen_addr' '192.168.1.5'
add_ok 126 tcp 'listen_addr' '2001:db8::9'
add_ok 127 ssl 'ssl_verify'  '1'
add_ok 130 mcast 'mcast_dst_group' '239.0.0.0'
add_ok 128 mcast 'mcast_ttl'  '32'
add_ok 129 unix 'unix_path'  '/var/run/ok.sock'
add_ok 132 ssl 'listen_addr' '2001:db8::9'

# the unix rule needs its paths, the ssl rule its files, or it is refused for a
# reason that has nothing to do with the value under test
printf 'socat.funix=config\nsocat.funix.enable=1\nsocat.funix.proto=unix\n' >> "$WORK/in.show"
printf "socat.funix.unix_path='/var/run/ok.sock'\n" >> "$WORK/in.show"
printf 'socat.funix.dest_proto=tcp4\nsocat.funix.dest_ip=10.0.0.9\nsocat.funix.dest_port=80\n' >> "$WORK/in.show"
printf 'socat.fssl=config\nsocat.fssl.enable=1\nsocat.fssl.proto=ssl\nsocat.fssl.listen_port=8443\n' >> "$WORK/in.show"
printf "socat.fssl.ssl_cert='/etc/ssl/c.pem'\n" >> "$WORK/in.show"
printf "socat.fssl.ssl_key='/etc/ssl/k.pem'\n" >> "$WORK/in.show"
printf 'socat.fssl.dest_proto=ssl\nsocat.fssl.dest_ip=10.0.0.9\nsocat.fssl.dest_port=443\n' >> "$WORK/in.show"

set +e
awk -v ipv6="2001:db8:1::55" -v socat=/usr/bin/socat \
	-v desf="$WORK/des" -v warnf="$WORK/warn" -v fwf="$WORK/fw" \
	-f "$GEN" < "$WORK/in.show" 2>"$WORK/err"
rc=$?
# NOT "set -e": the assertions below use grep -c, which exits 1 on "no match"
# and that is the result we want, not a failure of the suite
set +e
check 'the generator survives every hostile value' 0 "$rc"
check 'the generator writes nothing to stderr' '' "$(cat "$WORK/err")"

# every rule that must be refused produced no listener at all
leaked=""
for i in $BAD; do
	n=$(awk -F'\t' -v s="f$i" '$1==s{n++} END{print n+0}' "$WORK/des" 2>/dev/null)
	[ "$n" = "0" ] || leaked="$leaked f$i($n)"
done
check 'no refused rule leaks a listener' '' "$leaked"

# and the accepted ones did produce theirs (the list comes from the add_ok
# lines above, so a newly added case cannot be forgotten here)
leaked2=""
oks="$(grep -oE '^add_ok [0-9]+' "$0" | awk '{print $2}')"
for i in $oks; do
	n=$(awk -F'\t' -v s="f$i" '$1==s{n++} END{print n+0}' "$WORK/des")
	[ "${n:-0}" -ge 1 ] || leaked2="$leaked2 f$i"
done
check 'accepted values still produce listeners' '' "$leaked2"

# no command, key or firewall line may contain a shell metacharacter
metas="$( { cut -f4,5 "$WORK/des"; cat "$WORK/fw"; cat "$WORK/warn"; } | \
	grep -cE '[$`;|&<>]|\\' )"
check 'nothing in the output is a shell metacharacter' 0 "$metas"

# the glue invariant from the matrix, on hostile input
glue="$(cut -f5 "$WORK/des" | grep -cE '[^[:space:]](TCP|UDP|OPENSSL|UNIX-CONNECT|PROXY|SOCKS4)')"
check 'no address is glued to the option before it' 0 "$glue"

# and a unix / ssl rule with clean paths still works
check 'a clean unix rule survives the fuzz' 1 "$(awk -F'\t' '$1=="funix"{n++} END{print n+0}' "$WORK/des")"
check 'a clean ssl rule survives the fuzz' 1 "$(awk -F'\t' '$1=="fssl"{n++} END{print n+0}' "$WORK/des")"

# ---- IPv6: a rule that cannot be honoured must say why ----------------------
# Asserting only "no listener leaked" is not enough: an IPv6-only multicast rule
# emits nothing either way, so removing its guard passed the first version of
# this check.  The warning is the reason, so it is asserted too.
has 'a v6 literal on a v4 target is refused with a reason' 'f72:an IPv6 target needs dest_proto tcp6/udp6/tls, skip' "$(warns)"
has 'a v4 literal on a v6 target is refused with a reason' 'f87:an IPv4 target needs dest_proto tcp4/udp4, skip' "$(warns)"
has 'a v6 proxy server is refused with a reason' 'f83:proxy_server cannot be an IPv6 address, skip' "$(warns)"
has 'an IPv6-only multicast rule is refused with a reason' 'f85:multicast cannot listen on IPv6, rule skipped' "$(warns)"
has 'a hostile mcast_iface on a relay rule is refused' 'f86:bad mcast_iface, skip' "$(warns)"
# a value that cannot be honoured must not be dropped in silence, either
has 'ssl_verify without a CA file is reported' \
	'f127:ssl_verify is on but ssl_cafile is empty (the target certificate is not verified)' "$(warns)"
has 'a v6 listen_addr on a TLS rule is reported' \
	'f132:listen_addr is ignored on a TLS listener (IPv4 only)' "$(warns)"

rm -rf "$WORK"
summary 'generator fuzz'
