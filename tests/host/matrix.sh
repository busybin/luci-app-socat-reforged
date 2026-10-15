#!/bin/sh
# ============================================================================
# tests/host/matrix.sh — run EVERY generated command, one by one, for real
# ============================================================================
# The unit tests compare the generated *key* and match substrings; the simulator
# runs one fixture per scenario.  Neither covers the cross-product of listener
# kind and option: a single option that socat refuses on one address type (the
# unix+keepalive and udp+retry classes of bug) is invisible to both.
#
# This builds one rule per listener kind with every option switched on, generates
# the commands, then starts each one and asserts the listener is really there:
# the port is bound, or the unix socket file exists, or the process is alive.
#
# Usage: sh tests/host/matrix.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

WORK=$HERE/.work-matrix
GEN=$REPO/root/usr/libexec/socat-reforged-gen.awk
SOCAT=/usr/bin/socat
rm -rf "$WORK"; mkdir -p "$WORK"

SOCAT_HAS_SSL=0
socat -V 2>&1 | grep -q '#define WITH_OPENSSL' && SOCAT_HAS_SSL=1

# one rule per listener kind, every option on, so the matrix is one fixture.
# The dial targets are all local/loopback or a dead address: a listener that
# refuses to start dies immediately, one that starts stays up.
cat > "$WORK/in.show" <<'EOF'
socat.mtcp=config
socat.mtcp.enable=1
socat.mtcp.proto=tcp
socat.mtcp.listen_port=37100
socat.mtcp.dest_proto=tcp4
socat.mtcp.dest_ip=127.0.0.1
socat.mtcp.dest_port=37199
socat.mtcp.nodelay=1
socat.mtcp.backlog=64
socat.mtcp.max_children=4
socat.mtcp.timeout=30
socat.mtcp.system_log=0
socat.mtcp.keepalive=1
socat.mtcp.reuseaddr=1
socat.mtcp.user=nobody
socat.mtcp.retry=3
socat.mudp=config
socat.mudp.enable=1
socat.mudp.proto=udp
socat.mudp.listen_port=37101
socat.mudp.dest_proto=udp4
socat.mudp.dest_ip=127.0.0.1
socat.mudp.dest_port=37199
socat.mudp.keepalive=1
socat.mudp.reuseaddr=1
socat.mudp.user=nobody
socat.mudp.retry=3
socat.mssl=config
socat.mssl.enable=1
socat.mssl.proto=ssl
socat.mssl.listen_port=37102
socat.mssl.ssl_cert=/tmp/matrix-c.pem
socat.mssl.ssl_key=/tmp/matrix-k.pem
socat.mssl.dest_proto=ssl
socat.mssl.dest_ip=127.0.0.1
socat.mssl.dest_port=37199
socat.mssl.ssl_verify=1
socat.mssl.ssl_cafile=/tmp/matrix-c.pem
socat.mssl.keepalive=1
socat.mssl.reuseaddr=1
socat.mssl.user=nobody
socat.mssl.retry=3
socat.munix2unix=config
socat.munix2unix.enable=1
socat.munix2unix.proto=unix
socat.munix2unix.unix_path=/tmp/matrix-a.sock
socat.munix2unix.dest_proto=unix
socat.munix2unix.dst_unix_path=/tmp/matrix-b.sock
socat.munix2unix.user=nobody
socat.munix2unix.retry=3
socat.munix2tcp=config
socat.munix2tcp.enable=1
socat.munix2tcp.proto=unix
socat.munix2tcp.unix_path=/tmp/matrix-c.sock
socat.munix2tcp.dest_proto=tcp4
socat.munix2tcp.dest_ip=127.0.0.1
socat.munix2tcp.dest_port=37199
socat.munix2tcp.keepalive=1
socat.munix2tcp.user=nobody
socat.munix2tcp.retry=3
socat.mtcp2unix=config
socat.mtcp2unix.enable=1
socat.mtcp2unix.proto=tcp
socat.mtcp2unix.listen_port=37103
socat.mtcp2unix.dest_proto=unix
socat.mtcp2unix.dst_unix_path=/tmp/matrix-b.sock
socat.mtcp2unix.nodelay=1
socat.mtcp2unix.keepalive=1
socat.mtcp2unix.user=nobody
socat.mtcp2unix.retry=3
socat.mproxy=config
socat.mproxy.enable=1
socat.mproxy.proto=tcp
socat.mproxy.listen_port=37104
socat.mproxy.dest_proto=tcp4
socat.mproxy.dest_ip=example.invalid
socat.mproxy.dest_port=80
socat.mproxy.proxy=socks4a
socat.mproxy.proxy_server=127.0.0.1
socat.mproxy.proxy_port=1080
socat.mproxy.nodelay=1
socat.mproxy.keepalive=1
socat.mproxy.user=nobody
socat.mproxy.retry=3
socat.mmcast=config
socat.mmcast.enable=1
socat.mmcast.proto=udp
socat.mmcast.listen_port=37105
socat.mmcast.mcast_group=239.10.10.10
socat.mmcast.dest_proto=mcast
socat.mmcast.mcast_dst_group=239.10.10.20
socat.mmcast.mcast_dst_port=37200
socat.mmcast.mcast_ttl=4
socat.mmcast.mcast_loop=1
socat.mmcast.user=nobody
socat.mmcast.retry=3
socat.v6wan=config
socat.v6wan.enable=1
socat.v6wan.proto=tcp
socat.v6wan.listen_port=37115
socat.v6wan.family=6
socat.v6wan.dest_proto=tcp4
socat.v6wan.dest_ip=127.0.0.1
socat.v6wan.dest_port=37199
socat.v6la=config
socat.v6la.enable=1
socat.v6la.proto=tcp
socat.v6la.listen_port=37116
socat.v6la.family=6
socat.v6la.listen_addr=2001:db8:1::2
socat.v6la.dest_proto=tcp4
socat.v6la.dest_ip=127.0.0.1
socat.v6la.dest_port=37199
socat.mrange=config
socat.mrange.enable=1
socat.mrange.proto=tcp
socat.mrange.listen_port=37110-37112
socat.mrange.dest_proto=tcp4
socat.mrange.dest_ip=127.0.0.1
socat.mrange.dest_port=37199
socat.mrange.nodelay=1
socat.mrange.keepalive=1
socat.mrange.user=nobody
socat.mrange.retry=3
EOF

# a certificate for the TLS rules (socat needs a real one)
openssl req -x509 -newkey rsa:2048 -keyout /tmp/matrix-k.pem -out /tmp/matrix-c.pem \
	-days 2 -nodes -subj "/CN=matrix" >/dev/null 2>&1

awk -v ipv6="2001:db8:1::2" -v socat="$SOCAT" \
	-v desf="$WORK/des" -v warnf="$WORK/warn" -v fwf="$WORK/fw" \
	-f "$GEN" < "$WORK/in.show"

printf '  %-42s %s\n' "rule/sid" "kind, command"
BEGIN_BUGS=0

# start one command, then assert the listener really exists
try() { # try <sid> <kind> <port|-> <cmd>
	local sid="$1" kind="$2" port="$3" cmd="$4"
	local out err rc found=0
	err=$(mktemp)
	# shellcheck disable=SC2086
	$cmd >/dev/null 2>"$err" &
	local p=$!
	sleep 1.5
	if [ "$kind" = "unix" ]; then
		found=$([ -S "$(printf '%s' "$cmd" | sed -n 's|.*UNIX-LISTEN:\([^,]*\).*|\1|p')" ] && echo 1 || echo 0)
	else
		found=$(awk -v p="$port" '
			# /proc/net/tcp local_address is "<hex-ip>:<HEX-port>", and each
			# file carries a one-line header (FNR==1) that must be skipped
			FNR > 1 && $2 ~ ("^[0-9A-F]+:" sprintf("%04X", p) "$") &&
				($4 == "0A" || $4 == "07") { found = 1; exit }
			END { print (found ? 1 : 0) }
		' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null)
		[ -n "$found" ] || found=0
	fi
	kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null
	# also clean any forked child that survived
	for c in $(pgrep -P "$p" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
	if [ "$found" = "1" ] && [ ! -s "$err" ]; then
		check "$sid/$kind starts" 1 1
	else
		FAIL=$((FAIL + 1)); printf '  %-42s FAIL\n' "$sid/$kind starts"
		printf '    cmd    : %s\n' "$cmd"
		printf '    stderr : %s\n' "$(head -2 "$err")"
		printf '    listener seen: %s\n' "$found"
	fi
	rm -f "$err"
}

NLINES=$(wc -l < "$WORK/des")
# a literal tab in IFS, so the five columns come back whole
while IFS='	' read -r sid kind port key cmd; do
	[ -n "$sid" ] || continue
	# the TLS rules cannot run without an OpenSSL socat: that is a property of
	# the package, not of the generator, so skip instead of failing
	case "$sid" in mssl) [ "$SOCAT_HAS_SSL" = "1" ] || continue ;; esac
	try "$sid" "$kind" "$port" "$cmd"
done < "$WORK/des"

rm -rf "$WORK" /tmp/matrix-c.pem /tmp/matrix-k.pem /tmp/matrix-a.sock /tmp/matrix-b.sock /tmp/matrix-c.sock
summary 'generator command matrix'
