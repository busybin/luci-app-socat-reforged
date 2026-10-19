#!/bin/sh
# ============================================================================
# tests/host/gen-cases.sh — unit tests for the desired-state generator
# ============================================================================
# Runs the real generator awk over small fake `uci show socat` snapshots and
# asserts the resulting listener set, the validation warnings and the firewall
# ports.  No router needed.  Run twice: once with the host awk, once with
# BusyBox awk, because they are not byte-identical in regex handling.
#
# Usage: sh gen-cases.sh [path-to-gen.awk]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

REPO=$(cd "$HERE/../.." && pwd)
GEN="${1:-$REPO/root/usr/libexec/socat-reforged-gen.awk}"
# The engine runs this generator with BusyBox awk on the router, so the whole
# suite must hold there too.  Run it once more with AWK="busybox awk" (CI does).
# Unquoted $AWK below on purpose: it has to word-split into "busybox awk".
AWK=${AWK:-awk}
command -v $AWK >/dev/null 2>&1 || { echo "no \"$AWK\""; exit 1; }
WORK=$HERE/.work
rm -rf "$WORK"; mkdir -p "$WORK"

V6="2001:db8:1::55"

run_gen() { # run_gen <mode>  →  writes $WORK/out.des / out.warn / out.fw
	: > "$WORK/out.des"; : > "$WORK/out.warn"; : > "$WORK/out.fw"
	$AWK -v ipv6="$1" -v socat=/usr/bin/socat \
		-v desf="$WORK/out.des" -v warnf="$WORK/out.warn" -v fwf="$WORK/out.fw" \
		-f "$GEN" < "$WORK/in.show"
}

kinds() { awk -F'\t' '{printf "%s/%s ", $1, $2}' "$WORK/out.des" 2>/dev/null; }
warns() { awk -F'\t' '{printf "%s:%s ", $1, $2}' "$WORK/out.warn" 2>/dev/null; }
fwls()  { awk -F'\t' '{printf "%s:%s ", $1, $2}' "$WORK/out.fw" 2>/dev/null | sort; }

echo "generator: $GEN"
echo

# ---------------------------------------------------------------- fixtures ---
# each case: gen_case <label> <ipv6> <expected kinds> <expected warnings> <fixture>

# a plain TCP rule emits v4 (always) + v6 (when we have an address)
gen_case() { # gen_case <label> <ipv6> <expected kinds> <expected warnings> <fixture>
	printf '%s' "$5" > "$WORK/in.show"
	run_gen "$2"
	check "$1" "$3" "$(kinds)"
	if [ -n "$4" ]; then
		contains "$1 (warnings)" "$4" "$(warns)"
	else
		check "$1 (no warnings)" '' "$(warns)"
	fi
}

gen_case 'tcp dual-stack (v6 present)' "$V6" 'a/tcp a/tcp6 ' '' '
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
socat.a.firewall_accept=1
' "$WORK/in.show"

gen_case 'tcp only, no IPv6 at all' '' 'a/tcp ' '' '
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
socat.a.firewall_accept=1
' "$WORK/in.show"

gen_case 'udp dual-stack' "$V6" 'a/udp a/udp6 ' '' '
socat.a=config
socat.a.enable=1
socat.a.proto=udp
socat.a.listen_port=5000
socat.a.dest_proto=udp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=53
socat.a.firewall_accept=1
' "$WORK/in.show"

gen_case 'udp family=6 -> v6 only' "$V6" 'a/udp6 ' '' '
socat.a=config
socat.a.enable=1
socat.a.proto=udp
socat.a.listen_port=5000
socat.a.dest_proto=udp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=53
socat.a.family=6
' "$WORK/in.show"

gen_case 'udp family=6 but no IPv6' '' '' 'a:IPv6-only listen but no WAN IPv6 address ' '
socat.a=config
socat.a.enable=1
socat.a.proto=udp
socat.a.listen_port=5000
socat.a.dest_proto=udp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=53
socat.a.family=6
' "$WORK/in.show"

gen_case 'missing enable == enabled' "$V6" 'a/tcp a/tcp6 ' '' '
socat.a=config
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
' "$WORK/in.show"

gen_case 'enable=0 -> nothing' "$V6" '' '' '
socat.a=config
socat.a.enable=0
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
' "$WORK/in.show"

gen_case 'enable=true -> warn + skip' "$V6" '' 'a:enable must be 0 or 1, treating as disabled ' '
socat.a=config
socat.a.enable=true
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
' "$WORK/in.show"

# ---- validation: every one of these must be refused with a warning ----
# (one readable case each; see val_case below)

# explicit, readable validation cases instead of the loop above
val_case() { # val_case <label> <bad line> <expected warning>
	cat > "$WORK/in.show" <<FIX
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
$2
FIX
	run_gen "$V6"
	check "$1" '' "$(kinds)"
	contains "$1 (warned)" "a:$3" "$(warns)"
}

val_case 'bad listen_port 99999'  "socat.a.listen_port=99999"  'bad listen port, skip'
val_case 'bad listen_port 0'      "socat.a.listen_port=0"      'bad listen port, skip'
val_case 'bad listen_port abc'    "socat.a.listen_port=abc"    'bad listen port, skip'
val_case 'bad listen_port empty'  "socat.a.listen_port="       'bad listen port, skip'
val_case 'bad proto sctp'         "socat.a.proto=sctp"         'bad proto, skip'
val_case 'bad dest_proto sctp'    "socat.a.dest_proto=sctp"    'bad dest_proto, skip'
val_case 'bad family x'           "socat.a.family=x"           'bad family, skip'
val_case 'bad reuseaddr maybe'    "socat.a.reuseaddr=maybe"    'bad reuseaddr, skip'
val_case 'unknown proxy'          "socat.a.proxy=bogus"        'unknown proxy, skip'
val_case 'proxy on non-tcp4'      "socat.a.proxy=socks4a
socat.a.dest_proto=udp4"                                    'proxy only valid with tcp4 target, skip'

# injection / metacharacter attempts in address fields
val_case 'dest_ip with ;'         "socat.a.dest_ip=1.2.3.4;reboot"  'bad dest_ip, skip'
val_case 'dest_ip with $()'       'socat.a.dest_ip=$(id)'            'bad dest_ip, skip'
val_case 'dest_ip with backtick'  'socat.a.dest_ip=a`b'              'bad dest_ip, skip'
val_case 'dest_ip with pipe'      "socat.a.dest_ip=a|b"              'bad dest_ip, skip'
val_case 'dest_ip with space'     "socat.a.dest_ip=my host"          'bad dest_ip, skip'
val_case 'dest_ip with glob'      "socat.a.dest_ip=*"                'bad dest_ip, skip'
val_case 'dest_ip empty'          "socat.a.dest_ip="                 'bad dest_ip, skip'
val_case 'proxy_server injection' "socat.a.proxy=socks4a
socat.a.proxy_server=1.2.3.4;reboot"                          'bad proxy_server, skip'

# ---- things that must be accepted ----
cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8443
socat.a.dest_proto=tcp4
socat.a.dest_ip=blocked.example.com
socat.a.dest_port=443
socat.a.proxy=socks4a
socat.a.proxy_server=127.0.0.1
socat.a.proxy_port=1080
socat.a.remarks=label with spaces & symbols!
socat.a.firewall_accept=1
FIX
run_gen "$V6"
check 'socks4a dial, hostname target' 'a/tcp a/tcp6 ' "$(kinds)"
contains 'socks4a uses SOCKS4A:' 'SOCKS4A:127.0.0.1:blocked.example.com:443,socksport=1080' \
	"$(cat "$WORK/out.des")"
check 'hostname target opens the fw port' 'tcp:8443 ' "$(fwls)"

cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp6
socat.a.dest_ip=2001:db8:2:::5
socat.a.dest_port=80
FIX
run_gen "$V6"
contains 'tcp6 target uses [addr]:port' 'TCP6:[2001:db8:2:::5]:80' "$(cat "$WORK/out.des")"

# ---- zero-padded ports are canonicalised ------------------------------------
# The socket tables and the pid registry speak plain decimal ("443"), so a
# padded listen_port would never match a listener back to its socket: the
# listener-identity check (and with it duplicate detection) would be dead for
# that rule while everything still looked healthy.
#
# Also the regression test for a BusyBox-awk-only bug: BusyBox reads a
# leading-zero string as OCTAL ("0443" -> 291) where gawk/mawk read 443, and the
# engine runs BusyBox awk on the router.  With `v + 0` normalisation a padded
# port came out as 291 on the device and 443 on a desktop — right in every test
# on a PC, wrong on the router.  Now normalised as a string.
cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=00443
socat.a.dest_proto=tcp4
socat.a.dest_ip=192.168.1.7
socat.a.dest_port=00080
socat.a.proxy=socks4a
socat.a.proxy_server=127.0.0.1
socat.a.proxy_port=01080
socat.a.retry=00005
socat.a.firewall_accept=1
FIX
run_gen "$V6"
check 'padded ports still yield listeners' 'a/tcp a/tcp6 ' "$(kinds)"
contains 'listener uses the plain port' 'TCP-LISTEN:443,' "$(cat "$WORK/out.des")"
contains 'dial uses the plain dest port' 'SOCKS4A:127.0.0.1:192.168.1.7:80,' "$(cat "$WORK/out.des")"
contains 'proxy port is plain decimal' 'socksport=1080' "$(cat "$WORK/out.des")"
contains 'retry is plain decimal' ',retry=5,' "$(cat "$WORK/out.des")"
check 'firewall lists the plain port' 'tcp:443 ' "$(fwls)"

# proxy=proxy is the legacy spelling of HTTP CONNECT: the engine, the ubus
# test and the import validator must all agree on it.
cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=192.168.1.8
socat.a.dest_port=80
socat.a.proxy=proxy
socat.a.proxy_server=127.0.0.1
socat.a.proxy_port=01080
FIX
run_gen "$V6"
contains 'proxy=proxy dials PROXY:' 'PROXY:127.0.0.1:192.168.1.8:80,proxyport=1080' "$(cat "$WORK/out.des")"

# dotted section names + an option that is not an option
cat > "$WORK/in.show" <<'FIX'
socat.dotted.section.name=config
socat.dotted.section.name.enable=1
socat.dotted.section.name.proto=tcp
socat.dotted.section.name.listen_port=21010
socat.dotted.section.name.dest_proto=tcp4
socat.dotted.section.name.dest_ip=192.168.1.10
socat.dotted.section.name.dest_port=80
socat.odd=config
socat.odd.enable=1
socat.odd.proto=tcp
socat.odd.listen_port=21011
socat.odd.dest_proto=tcp4
socat.odd.dest_ip=192.168.1.11
socat.odd.dest_port=80
socat.odd.x.y=1
socat.reforged=internal
socat.reforged.note=managed by luci-app-socat-reforged
FIX
run_gen "$V6"
check 'dotted section names + junk option' 'dotted.section.name/tcp dotted.section.name/tcp6 odd/tcp odd/tcp6 ' "$(kinds)"
check 'internal section ignored' '' "$(warns)"

# every desired line's key must equal the command with spaces removed
awk -F'\t' '{c=$5; gsub(/ /,"",c); print (c==$4) ? "ok" : "BAD " $1}' "$WORK/out.des" > "$WORK/keys"
KEYS=$(sort -u "$WORK/keys" | tr '\n' ' ')
check 'key == command without spaces' 'ok' "${KEYS% }"

# rules with firewall_accept=0 must not open a port
cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=udp
socat.a.listen_port=5000
socat.a.dest_proto=udp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=53
socat.a.firewall_accept=0
FIX
run_gen "$V6"
check 'firewall_accept=0 -> no fw port' '' "$(fwls)"

# ---- listen_port as a range (one listener per port) ------------------------
cat > "$WORK/in.show" <<'FIX'
socat.r=config
socat.r.enable=1
socat.r.proto=tcp
socat.r.listen_port=30000-30002
socat.r.dest_proto=tcp4
socat.r.dest_ip=10.0.0.9
socat.r.dest_port=80
socat.r.firewall_accept=1
FIX
run_gen ''
check 'range -> one listener per port' 'r/tcp r/tcp r/tcp ' "$(kinds)"
check 'range -> firewall ports' 'tcp:30000 tcp:30001 tcp:30002 ' "$(fwls)"
check 'range -> desired commands carry each port' 'TCP-LISTEN:30000 TCP-LISTEN:30001 TCP-LISTEN:30002 ' \
	"$(cut -f5 "$WORK/out.des" | grep -o 'TCP-LISTEN:[0-9]*' | tr '\n' ' ')"

run_gen "$V6"
check 'range dual-stack -> v4+v6 per port' 'r/tcp r/tcp6 r/tcp r/tcp6 r/tcp r/tcp6 ' "$(kinds)"

# an over-long span is clamped (and said so) instead of forking listeners
cat > "$WORK/in.show" <<'FIX'
socat.big=config
socat.big.enable=1
socat.big.proto=tcp
socat.big.listen_port=10000-10300
socat.big.dest_proto=tcp4
socat.big.dest_ip=10.0.0.9
socat.big.dest_port=80
socat.big.firewall_accept=0
FIX
run_gen ''
contains 'over-long range is clamped' 'clamped' "$(warns)"
check 'clamped range starts exactly 256 listeners' 256 "$(awk -F'\t' 'END{print NR}' "$WORK/out.des")"

# nonsense ranges are rejected outright
for bad in '5000-1000' '70000-70010' '0-10' '3000-' '-3000' 'abc'; do
	cat > "$WORK/in.show" <<FIX
socat.b=config
socat.b.enable=1
socat.b.proto=tcp
socat.b.listen_port=$bad
socat.b.dest_proto=tcp4
socat.b.dest_ip=10.0.0.9
socat.b.dest_port=80
FIX
	run_gen ''
	check "bad listen port '$bad' -> skipped" 'b:bad listen port, skip ' "$(warns)"
done

# ---- destination that is a hostname must not be bracketed ------------------
# socat only accepts brackets around a literal IPv6 address; "[example.org]"
# is treated as an address and never resolves.
cat > "$WORK/in.show" <<'FIX'
socat.h4=config
socat.h4.enable=1
socat.h4.proto=tcp
socat.h4.listen_port=8080
socat.h4.dest_proto=tcp4
socat.h4.dest_ip=example.org
socat.h4.dest_port=80
socat.h6=config
socat.h6.enable=1
socat.h6.proto=tcp
socat.h6.listen_port=8081
socat.h6.dest_proto=tcp6
socat.h6.dest_ip=example.org
socat.h6.dest_port=80
socat.l6=config
socat.l6.enable=1
socat.l6.proto=udp
socat.l6.listen_port=8082
socat.l6.dest_proto=udp6
socat.l6.dest_ip=2001:db8::1
socat.l6.dest_port=53
socat.l6u=config
socat.l6u.enable=1
socat.l6u.proto=udp
socat.l6u.listen_port=8083
socat.l6u.dest_proto=udp6
socat.l6u.dest_ip=example.org
socat.l6u.dest_port=53
socat.l6t=config
socat.l6t.enable=1
socat.l6t.proto=tcp
socat.l6t.listen_port=8084
socat.l6t.dest_proto=tcp6
socat.l6t.dest_ip=2001:db8::1
socat.l6t.dest_port=443
FIX
# h4 dials v4, h6 dials a v6-resolving hostname, l6/l6t are literal v6
# addresses, l6u is a v6-resolving hostname over udp; every dual-stack rule
# expects its v4 and v6 listeners to dial the same target
run_gen "$V6"
check 'tcp6 hostname dialed unbracketed' 2 \
	"$(grep -c 'TCP6:example.org:80' "$WORK/out.des" || true)"
check 'tcp6 literal stays bracketed' 2 \
	"$(grep -c 'TCP6:\[2001:db8::1\]:443' "$WORK/out.des" || true)"
check 'udp6 hostname dialed unbracketed' 2 \
	"$(grep -c 'UDP6:example.org:53' "$WORK/out.des" || true)"
check 'udp6 literal stays bracketed' 2 \
	"$(grep -c 'UDP6:\[2001:db8::1\]:53' "$WORK/out.des" || true)"
check 'no bracketed hostname in any command' '' \
	"$(grep -o '\[[a-zA-Z0-9._-]*\]' "$WORK/out.des" | sort -u | tr -d '\n')"


# ---- protocols carried over from the other forks: unix / tls / multicast --
cmdgrep() { # cmdgrep <expected-count> <literal> ; greps the 5th column of out.des
	cut -f5 "$WORK/out.des" | grep -cF "$2"
}

# unix listener -> unix target
cat > "$WORK/in.show" <<'FIX'
socat.u=config
socat.u.enable=1
socat.u.proto=unix
socat.u.unix_path=/var/run/s1.sock
socat.u.dest_proto=unix
socat.u.dst_unix_path=/var/run/s2.sock
socat.u.firewall_accept=1
FIX
run_gen ''
check 'unix listener -> unix dial' 'u/unix ' "$(kinds)"
check 'unix socket addresses' 1 "$(cmdgrep 1 'UNIX-LISTEN:/var/run/s1.sock')"
check 'unix dial address' 1 "$(cmdgrep 1 'UNIX-CONNECT:/var/run/s2.sock')"
check 'unix adds no firewall line' '' "$(fwls)"

# unix listener -> tcp target
cat > "$WORK/in.show" <<'FIX'
socat.u2=config
socat.u2.enable=1
socat.u2.proto=unix
socat.u2.unix_path=/var/run/s1.sock
socat.u2.dest_proto=tcp4
socat.u2.dest_ip=10.0.0.5
socat.u2.dest_port=80
FIX
run_gen ''
check 'unix listener -> tcp dial' 'u2/unix ' "$(kinds)"
check 'unix listener dials tcp' 1 "$(cmdgrep 1 'TCP4:10.0.0.5:80')"

# a relative or traversing socket path is refused
for p in 's1.sock' '/var/../etc/s' '/var/run/.;;rm' '/var/run/spa ce.s'; do
	cat > "$WORK/in.show" <<FIX
socat.bp=config
socat.bp.enable=1
socat.bp.proto=unix
socat.bp.unix_path=$p
socat.bp.dest_proto=unix
socat.bp.dst_unix_path=/var/run/s2.sock
FIX
	run_gen ''
	check "bad unix_path '$p' -> skipped" 'bp:bad unix_path, skip ' "$(warns)"
done

# tls listener + tls dial without verification
cat > "$WORK/in.show" <<'FIX'
socat.t=config
socat.t.enable=1
socat.t.proto=ssl
socat.t.listen_port=8443
socat.t.ssl_cert=/etc/luci-cert.pem
socat.t.ssl_key=/etc/luci-key.pem
socat.t.dest_proto=ssl
socat.t.dest_ip=10.0.0.7
socat.t.dest_port=443
socat.t.firewall_accept=1
FIX
run_gen ''
check 'tls listener + tls dial' 't/ssltcp ' "$(kinds)"
check 'tls listener carries cert+key' 1 "$(cmdgrep 1 'OPENSSL-LISTEN:8443,pf=ip4,cert=/etc/luci-cert.pem,key=/etc/luci-key.pem')"
check 'tls listener does not demand a client certificate' 1 "$(cmdgrep 1 'key=/etc/luci-key.pem,verify=0,fork')"
check 'tls dial defaults to verify=0' 1 "$(cmdgrep 1 'OPENSSL:10.0.0.7:443,verify=0')"
check 'tls opens the firewall as tcp' 'tcp:8443 ' "$(fwls)"

# ---- socat's OPENSSL-LISTEN is IPv4-only -----------------------------------
# Every v6 form of bind= (literal, bracketed, "::") fails with
# getaddrinfo EAI_ADDRFAMILY, and with no bind it binds IPv4 only, so a second
# OpenSSL listener for IPv6 would have made every dual-stack TLS rule look
# "partial" forever with a getaddrinfo error.  The matrix suite starts every
# generated command for real, which is what proved it.
cat > "$WORK/in.show" <<'FIX'
socat.d4=config
socat.d4.enable=1
socat.d4.proto=ssl
socat.d4.listen_port=8445
socat.d4.family=4
socat.d4.ssl_cert=/etc/luci-cert.pem
socat.d4.ssl_key=/etc/luci-key.pem
socat.d4.dest_proto=ssl
socat.d4.dest_ip=10.0.0.7
socat.d4.dest_port=443
socat.d6=config
socat.d6.enable=1
socat.d6.proto=ssl
socat.d6.listen_port=8446
socat.d6.family=6
socat.d6.ssl_cert=/etc/luci-cert.pem
socat.d6.ssl_key=/etc/luci-key.pem
socat.d6.dest_proto=ssl
socat.d6.dest_ip=10.0.0.7
socat.d6.dest_port=443
socat.d0=config
socat.d0.enable=1
socat.d0.proto=ssl
socat.d0.listen_port=8447
socat.d0.ssl_cert=/etc/luci-cert.pem
socat.d0.ssl_key=/etc/luci-key.pem
socat.d0.dest_proto=ssl
socat.d0.dest_ip=10.0.0.7
socat.d0.dest_port=443
FIX
run_gen ''
check 'a family=4 tls rule yields one listener' 'd4/ssltcp d0/ssltcp ' "$(kinds)"
check 'a family=6 tls rule starts nothing' '' "$(kinds | grep 'd6/' | grep . || echo '')"
has 'a family=6 tls rule says why' 'd6:TLS cannot listen on IPv6 with this socat, rule skipped' "$(warns)"
has 'a default-family tls rule says it is v4 only' 'd0:TLS listens on IPv4 only' "$(warns)"

# tls dial with verification
cat > "$WORK/in.show" <<'FIX'
socat.t2=config
socat.t2.enable=1
socat.t2.proto=tcp
socat.t2.listen_port=8444
socat.t2.dest_proto=ssl
socat.t2.dest_ip=10.0.0.7
socat.t2.dest_port=443
socat.t2.ssl_verify=1
socat.t2.ssl_cafile=/etc/ca.pem
FIX
run_gen ''
check 'tls dial with verification' 1 "$(cmdgrep 1 'OPENSSL:10.0.0.7:443,verify=1,cafile=/etc/ca.pem')"

# multicast receive joins a group on one interface
cat > "$WORK/in.show" <<'FIX'
socat.m=config
socat.m.enable=1
socat.m.proto=udp
socat.m.listen_port=5000
socat.m.mcast_group=239.10.10.10
socat.m.mcast_iface=eth0.2
socat.m.mcast_localip=192.168.1.1
socat.m.dest_proto=tcp4
socat.m.dest_ip=10.0.0.9
socat.m.dest_port=1935
socat.m.firewall_accept=1
FIX
run_gen ''
check 'multicast receive listener' 'm/udp ' "$(kinds)"
check 'multicast joins the group' 1 "$(cmdgrep 1 'ip-add-membership=239.10.10.10:192.168.1.1,bind=239.10.10.10,so-bindtodevice=eth0.2')"
check 'multicast uses RECVFROM+fork' 1 "$(cmdgrep 1 'UDP4-RECVFROM:5000')"
check 'multicast requests IGMP too' 'udp:5000 igmp:- ' "$(fwls)"

# multicast receive -> multicast relay (ttl + interface)
cat > "$WORK/in.show" <<'FIX'
socat.m2=config
socat.m2.enable=1
socat.m2.proto=udp
socat.m2.listen_port=5000
socat.m2.mcast_group=239.10.10.10
socat.m2.dest_proto=mcast
socat.m2.mcast_dst_group=239.20.20.20
socat.m2.mcast_dst_port=4000
socat.m2.mcast_iface=eth0.2
socat.m2.mcast_ttl=8
socat.m2.mcast_loop=1
FIX
run_gen ''
check 'multicast relay dial' 1 "$(cmdgrep 1 'UDP4-DATAGRAM:239.20.20.20:4000,ip-multicast-if=eth0.2,ip-multicast-ttl=8,ip-multicast-loop=1')"


# bad multicast parameters, each in its own fixture (a good group on a later
# line would override the value under test)
for bad in 'mcast_dst_port=70000' 'mcast_ttl=999'; do
	opt=${bad%%=*}; val=${bad#*=}
	cat > "$WORK/in.show" <<EOF
socat.bm=config
socat.bm.enable=1
socat.bm.proto=udp
socat.bm.listen_port=5001
socat.bm.$bad
socat.bm.mcast_group=239.10.10.10
socat.bm.dest_proto=mcast
socat.bm.mcast_dst_group=239.20.20.20
socat.bm.dest_ip=10.0.0.9
socat.bm.dest_port=80
EOF
	run_gen ''
	contains "bad $bad is refused" 'skip' "$(warns)"
done

cat > "$WORK/in.show" <<'EOF'
socat.bm=config
socat.bm.enable=1
socat.bm.proto=udp
socat.bm.listen_port=5001
socat.bm.mcast_group=200.1.1.1
socat.bm.dest_proto=tcp4
socat.bm.dest_ip=10.0.0.9
socat.bm.dest_port=80
EOF
run_gen ''
check 'bad mcast_group=200.1.1.1 is refused' 'bm:bad mcast_group, skip ' "$(warns)"

cat > "$WORK/in.show" <<'EOF'
socat.bm=config
socat.bm.enable=1
socat.bm.proto=udp
socat.bm.listen_port=5001
socat.bm.mcast_group=239.10.10.10
socat.bm.dest_proto=mcast
socat.bm.mcast_dst_group=10.0.0.1
socat.bm.dest_ip=10.0.0.9
socat.bm.dest_port=80
EOF
run_gen ''
check 'bad mcast_dst_group=10.0.0.1 is refused' 'bm:bad mcast_dst_group, skip ' "$(warns)"
# bad multicast parameters

# a group on a non-udp listener is ignored, not fatal
cat > "$WORK/in.show" <<'FIX'
socat.mt=config
socat.mt.enable=1
socat.mt.proto=tcp
socat.mt.listen_port=5002
socat.mt.mcast_group=239.10.10.10
socat.mt.dest_proto=tcp4
socat.mt.dest_ip=10.0.0.9
socat.mt.dest_port=80
FIX
run_gen ''
contains 'group on a tcp rule is ignored' 'multicast group needs proto=udp' "$(warns)"
check 'the tcp rule still starts' 'mt/tcp ' "$(kinds)"

# socket options: nodelay / backlog / max-children / timeout / system_log
cat > "$WORK/in.show" <<'FIX'
socat.o=config
socat.o.enable=1
socat.o.proto=tcp
socat.o.listen_port=6000
socat.o.dest_proto=tcp4
socat.o.dest_ip=10.0.0.9
socat.o.dest_port=80
socat.o.nodelay=1
socat.o.backlog=64
socat.o.max_children=16
socat.o.timeout=30
socat.o.system_log=1
FIX
run_gen ''
check 'nodelay on the listener' 1 "$(cmdgrep 1 'TCP-LISTEN:6000,pf=ip4,fork,reuseaddr,nodelay,backlog=64,max-children=16')"
check 'nodelay on the dial' 1 "$(cmdgrep 1 'TCP4:10.0.0.9:80,nodelay')"
check 'timeout becomes socat -T' 1 "$(cmdgrep 1 'socat -T30 ')"
check 'system_log routes to syslog' 1 "$(cmdgrep 1 'socat -T30 -ls -d TCP-LISTEN:6000')"


# keepalive can be switched off per rule
cat > "$WORK/in.show" <<'FIX'
socat.k=config
socat.k.enable=1
socat.k.proto=tcp
socat.k.listen_port=6100
socat.k.dest_proto=tcp4
socat.k.dest_ip=10.0.0.9
socat.k.dest_port=80
socat.k.keepalive=0
FIX
run_gen ''
check 'keepalive=0 drops it from the listener' 0 "$(cmdgrep 1 'TCP-LISTEN:6100,pf=ip4,fork,reuseaddr,keepalive')"
check 'keepalive=0 drops it from the dial too' 1 "$(cmdgrep 1 'TCP4:10.0.0.9:80')"
check 'the listener is still built without keepalive' 'k/tcp ' "$(kinds)"

# listen_addr binds the IPv4 listener to one local address
cat > "$WORK/in.show" <<'FIX'
socat.la=config
socat.la.enable=1
socat.la.proto=tcp
socat.la.listen_addr=192.168.1.5
socat.la.listen_port=6200
socat.la.dest_proto=tcp4
socat.la.dest_ip=10.0.0.9
socat.la.dest_port=80
FIX
run_gen ''
check 'listen_addr binds the v4 listener' 1 "$(cmdgrep 1 'TCP-LISTEN:6200,pf=ip4,fork,reuseaddr,bind=192.168.1.5')"

# with IPv6 available the auto WAN bind stays on the v6 listener
cat > "$WORK/in.show" <<'FIX'
socat.la6=config
socat.la6.enable=1
socat.la6.proto=tcp
socat.la6.listen_addr=192.168.1.5
socat.la6.listen_port=6201
socat.la6.dest_proto=tcp4
socat.la6.dest_ip=10.0.0.9
socat.la6.dest_port=80
FIX
run_gen "$V6"
check 'v4 listener keeps its own bind' 1 "$(cmdgrep 1 'TCP-LISTEN:6201,pf=ip4,fork,reuseaddr,bind=192.168.1.5')"
check 'v6 listener keeps the WAN bind' 1 "$(cmdgrep 1 "TCP6-LISTEN:6201,fork,reuseaddr,bind=$V6")"

# a v6 listen_addr moves the bind to the v6 listener (and needs ip-freebind)
cat > "$WORK/in.show" <<'FIX'
socat.la66=config
socat.la66.enable=1
socat.la66.proto=tcp
socat.la66.listen_addr=fd00::5
socat.la66.listen_port=6202
socat.la66.dest_proto=tcp4
socat.la66.dest_ip=10.0.0.9
socat.la66.dest_port=80
FIX
run_gen "$V6"
check 'v6 listen_addr binds the v6 listener' 1 "$(cmdgrep 1 'TCP6-LISTEN:6202,fork,reuseaddr,bind=fd00::5,ip-freebind=1')"
check 'v4 listener has no bind then' 1 "$(cmdgrep 1 'TCP-LISTEN:6202,pf=ip4,fork,reuseaddr,keepalive')"

# a listen_addr on a multicast listener is ignored, with a warning
cat > "$WORK/in.show" <<'FIX'
socat.lam=config
socat.lam.enable=1
socat.lam.proto=udp
socat.lam.listen_addr=192.168.1.5
socat.lam.listen_port=6203
socat.lam.mcast_group=239.10.10.10
socat.lam.dest_proto=tcp4
socat.lam.dest_ip=10.0.0.9
socat.lam.dest_port=80
FIX
run_gen ''
contains 'listen_addr is ignored on multicast' 'listen_addr is ignored' "$(warns)"
check 'the multicast listener keeps bind=group' 1 "$(cmdgrep 1 'bind=239.10.10.10')"

# a bad keepalive or listen_addr is refused
cat > "$WORK/in.show" <<'FIX'
socat.bk=config
socat.bk.enable=1
socat.bk.proto=tcp
socat.bk.listen_port=6204
socat.bk.keepalive=2
socat.bk.dest_proto=tcp4
socat.bk.dest_ip=10.0.0.9
socat.bk.dest_port=80
FIX
run_gen ''
check 'bad keepalive is refused' 'bk:bad keepalive, skip ' "$(warns)"

cat > "$WORK/in.show" <<'FIX'
socat.bl=config
socat.bl.enable=1
socat.bl.proto=tcp
socat.bl.listen_addr=192.168.1.5;rm -rf /
socat.bl.listen_port=6205
socat.bl.dest_proto=tcp4
socat.bl.dest_ip=10.0.0.9
socat.bl.dest_port=80
FIX
run_gen ''
check 'a shell metacharacter in listen_addr is refused' 'bl:bad listen_addr, skip ' "$(warns)"

# a unix listener unlinks a stale socket file before binding
cat > "$WORK/in.show" <<'FIX'
socat.ux=config
socat.ux.enable=1
socat.ux.proto=unix
socat.ux.unix_path=/var/run/x.sock
socat.ux.dest_proto=tcp4
socat.ux.dest_ip=10.0.0.5
socat.ux.dest_port=80
FIX
run_gen ''
check 'unix listener unlinks a stale socket' 1 "$(cmdgrep 1 'UNIX-LISTEN:/var/run/x.sock,fork,unlink-early')"

# a unix socket has no TCP keepalive (socat rejects keepidle there): neither a
# unix listener dialling unix, nor a tcp listener dialling unix, may carry it
# on the unix side; the tcp listener itself still keeps its own copy.
cat > "$WORK/in.show" <<'FIX'
socat.xx=config
socat.xx.enable=1
socat.xx.proto=unix
socat.xx.unix_path=/var/run/a.sock
socat.xx.dest_proto=unix
socat.xx.dst_unix_path=/var/run/b.sock
socat.tx=config
socat.tx.enable=1
socat.tx.proto=tcp
socat.tx.listen_port=6400
socat.tx.dest_proto=unix
socat.tx.dst_unix_path=/var/run/c.sock
FIX
run_gen ''
check 'unix to unix carries no keepalive at all' 0 "$(awk -F'\t' '$1=="xx"{print $5}' "$WORK/out.des" | grep -c keepalive)"
check 'unix to unix keeps reuseaddr and unlink-early' 1 "$(cmdgrep 1 'UNIX-LISTEN:/var/run/a.sock,fork,unlink-early,reuseaddr UNIX-CONNECT:/var/run/b.sock')"
check 'tcp to unix keeps keepalive on the listener only' 1 "$(cmdgrep 1 'TCP-LISTEN:6400,pf=ip4,fork,reuseaddr,keepalive,keepidle=60,keepintvl=10,keepcnt=5 UNIX-CONNECT:/var/run/c.sock')"

# ---- command shape: no target address may run into the option before it -----
# Regression this caught: "UDP-LISTEN:5000,forkUDP4:10.0.0.9:53" — the space
# before the target was lost when the listener options became variables, and
# every substring assertion (and the unit tests' key column, which strips
# spaces on purpose) still matched, so only the real listener failed to start.
cat > "$WORK/in.show" <<'FIX'
socat.t=config
socat.t.enable=1
socat.t.proto=tcp
socat.t.listen_port=6300
socat.t.dest_proto=tcp4
socat.t.dest_ip=10.0.0.9
socat.t.dest_port=80
socat.t.nodelay=1
socat.t.backlog=8
socat.u=config
socat.u.enable=1
socat.u.proto=udp
socat.u.listen_port=6301
socat.u.dest_proto=udp4
socat.u.dest_ip=10.0.0.9
socat.u.dest_port=53
socat.s=config
socat.s.enable=1
socat.s.proto=ssl
socat.s.listen_port=6302
socat.s.ssl_cert=/etc/ssl/c.pem
socat.s.ssl_key=/etc/ssl/k.pem
socat.s.dest_proto=ssl
socat.s.dest_ip=10.0.0.9
socat.s.dest_port=443
socat.x=config
socat.x.enable=1
socat.x.proto=unix
socat.x.unix_path=/var/run/x.sock
socat.x.dest_proto=tcp4
socat.x.dest_ip=10.0.0.9
socat.x.dest_port=80
socat.m=config
socat.m.enable=1
socat.m.proto=udp
socat.m.listen_port=6303
socat.m.mcast_group=239.1.1.1
socat.m.dest_proto=mcast
socat.m.mcast_dst_group=239.2.2.2
socat.m.mcast_dst_port=5000
FIX
run_gen "$V6"
check 'no target address is glued to the option before it' 0 \
	"$(cut -f5 "$WORK/out.des" | grep -cE '[^[:space:]](TCP|UDP|OPENSSL|UNIX-CONNECT|PROXY|SOCKS4)')"
check 'udp v4 keeps the space before the target' 1 "$(cmdgrep 1 'UDP-LISTEN:6301,pf=ip4,fork UDP4:10.0.0.9:53')"
# socat 1.8.0.0 refuses a bare UDP-LISTEN ("unknown address family 0")
check 'the v4 udp listener pins its address family' 1 "$(cmdgrep 1 'UDP-LISTEN:6301,pf=ip4')"
check 'udp v6 keeps the space before the target' 1 "$(cmdgrep 1 'UDP6-LISTEN:6301,fork UDP4:10.0.0.9:53')"
check 'ssl keeps the space before the target' 1 "$(cmdgrep 1 'fork,reuseaddr,keepalive,keepidle=60,keepintvl=10,keepcnt=5 OPENSSL:10.0.0.9:443')"
check 'unix keeps the space before the target' 1 "$(cmdgrep 1 'unlink-early,reuseaddr TCP4:10.0.0.9:80,keepalive,keepidle=60,keepintvl=10,keepcnt=5')"
check 'a unix listener carries no keepalive itself' 0 "$(cmdgrep 1 'unlink-early,reuseaddr,keepalive')"
check 'multicast receive keeps the space before the target' 1 "$(cmdgrep 1 'bind=239.1.1.1,reuseaddr,fork UDP4-DATAGRAM:239.2.2.2:5000')"
check 'ssl listener carries the cert and key' 1 "$(cmdgrep 1 'OPENSSL-LISTEN:6302,pf=ip4,cert=/etc/ssl/c.pem,key=/etc/ssl/k.pem,verify=0,fork')"
check 'tcp listener carries nodelay and backlog' 1 "$(cmdgrep 1 'TCP-LISTEN:6300,pf=ip4,fork,reuseaddr,nodelay,backlog=8')"
check 'the multicast rule opens udp on the wire' 'udp:6303 ' "$(fwls | tr ' ' '\n' | grep '^udp:6303' | tr '\n' ' ')"
check 'the multicast rule also opens igmp' 'igmp:- ' "$(fwls | tr ' ' '\n' | grep '^igmp:' | tr '\n' ' ')"
check 'an ssl listener is opened as tcp on the wire' 'tcp:6302 ' "$(fwls | tr ' ' '\n' | grep '^tcp:6302' | tr '\n' ' ')"

# ---- ",reuseaddr" belongs to the rule that asks for it ---------------------
# RA is a global awk variable and the multicast address is built from it, so
# the assignment has to happen before that block.  Regression: a rule with
# reuseaddr=0 used to strip ,reuseaddr from the *next* rule's group join, and
# the first rule of a config never got it at all.
cat > "$WORK/in.show" <<'FIX'
socat.m1=config
socat.m1.enable=1
socat.m1.proto=udp
socat.m1.listen_port=6310
socat.m1.mcast_group=239.1.1.10
socat.m1.dest_proto=udp4
socat.m1.dest_ip=10.0.0.9
socat.m1.dest_port=53
socat.m2=config
socat.m2.enable=1
socat.m2.proto=udp
socat.m2.listen_port=6311
socat.m2.mcast_group=239.1.1.11
socat.m2.reuseaddr=0
socat.m2.dest_proto=udp4
socat.m2.dest_ip=10.0.0.9
socat.m2.dest_port=53
socat.m3=config
socat.m3.enable=1
socat.m3.proto=udp
socat.m3.listen_port=6312
socat.m3.mcast_group=239.1.1.12
socat.m3.dest_proto=udp4
socat.m3.dest_ip=10.0.0.9
socat.m3.dest_port=53
FIX
run_gen "$V6"
check 'multicast: the first rule keeps its reuseaddr' 1 \
	"$(cmdgrep 1 'bind=239.1.1.10,reuseaddr,fork')"
check 'multicast: reuseaddr=0 is honoured' 0 \
	"$(cmdgrep 1 'bind=239.1.1.11,reuseaddr')"
check 'multicast: the next rule gets it again' 1 \
	"$(cmdgrep 1 'bind=239.1.1.12,reuseaddr,fork')"
absent 'multicast: no reuseaddr leaks into the rule that refused it' ',reuseaddr' \
	"$(grep -F 'bind=239.1.1.11' "$WORK/out.des" | cut -f5)"

# ---- an option value that happens to be the word "config" ------------------
# The generator decided "is this a section header?" on the value alone, so
# socat.a.remarks='config' also became a section and warned "a.remarks bad
# proto, skip".  A header is only a header when options follow it.
gen_case 'a rule may be called or describe itself "config"' "$V6" 'a/tcp a/tcp6 ' '' '
socat.a=config
socat.a.enable=1
socat.a.remarks=config
socat.a.proto=tcp
socat.a.listen_port=6320
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
'

# ---- drop privileges (socat ",user=") and retry (",retry=") ------------------
# Copied from mylucien.  Both are single-token options, so unlike custom_opts
# they cannot smuggle another option into the command line; the character set
# is still validated (the ",user=;" test below).
cat > "$WORK/in.show" <<'FIX'
socat.t=config
socat.t.enable=1
socat.t.proto=tcp
socat.t.listen_port=6500
socat.t.user=nobody
socat.t.retry=5
socat.t.dest_proto=tcp4
socat.t.dest_ip=10.0.0.9
socat.t.dest_port=80
socat.u=config
socat.u.enable=1
socat.u.proto=udp
socat.u.listen_port=6501
socat.u.user=nobody
socat.u.retry=5
socat.u.dest_proto=udp4
socat.u.dest_ip=10.0.0.9
socat.u.dest_port=53
socat.m=config
socat.m.enable=1
socat.m.proto=udp
socat.m.listen_port=6502
socat.m.mcast_group=239.1.1.1
socat.m.user=nobody
socat.m.retry=5
socat.m.dest_proto=mcast
socat.m.mcast_dst_group=239.2.2.2
socat.m.mcast_dst_port=5000
socat.s=config
socat.s.enable=1
socat.s.proto=unix
socat.s.unix_path=/var/run/x.sock
socat.s.user=nobody
socat.s.retry=5
socat.s.dest_proto=unix
socat.s.dst_unix_path=/var/run/b.sock
socat.z=config
socat.z.enable=1
socat.z.proto=tcp
socat.z.listen_port=6503
socat.z.user=nobody
socat.z.retry=0
socat.z.dest_proto=tcp4
socat.z.dest_ip=10.0.0.9
socat.z.dest_port=80
socat.badu=config
socat.badu.enable=1
socat.badu.proto=tcp
socat.badu.listen_port=6504
socat.badu.user='nobody;reboot'
socat.badu.dest_proto=tcp4
socat.badu.dest_ip=10.0.0.9
socat.badu.dest_port=80
socat.badr=config
socat.badr.enable=1
socat.badr.proto=tcp
socat.badr.listen_port=6505
socat.badr.retry='5x'
socat.badr.dest_proto=tcp4
socat.badr.dest_ip=10.0.0.9
socat.badr.dest_port=80
FIX
run_gen "$V6"
check 'user= reaches the tcp listener' 1 "$(cmdgrep 1 'TCP-LISTEN:6500,pf=ip4,fork,reuseaddr,keepalive,keepidle=60,keepintvl=10,keepcnt=5,user=nobody ')"
check 'retry= reaches the tcp dial' 2 "$(cmdgrep 1 'TCP4:10.0.0.9:80,retry=5,keepalive')"
check 'user= reaches the unix listener' 1 "$(cmdgrep 1 'unlink-early,reuseaddr,user=nobody UNIX-CONNECT')"
check 'retry= reaches the unix dial' 1 "$(cmdgrep 1 'UNIX-CONNECT:/var/run/b.sock,retry=5')"
check 'a udp rule keeps user= but drops retry=' 1 "$(cmdgrep 1 'UDP-LISTEN:6501,pf=ip4,fork,user=nobody UDP4:10.0.0.9:53')"
check 'a multicast rule keeps user= but drops retry=' 1 "$(cmdgrep 1 'bind=239.1.1.1,reuseaddr,fork,user=nobody UDP4-DATAGRAM')"
check 'retry=0 means no retry option' 0 "$(cmdgrep 1 'TCP4:10.0.0.9:80,retry=0')"
# two separate rules on purpose: one rule with both faults stops at the first
has 'a metacharacter user is refused, whole rule' 'badu:bad user, skip' "$(warns)"
has 'a non-numeric retry is refused, whole rule' 'badr:bad retry, skip' "$(warns)"
check 'the refused rules start nothing' 0 "$(awk -F'\t' '$1=="badu" || $1=="badr"' "$WORK/out.des" | grep -c .)"
# ---- TCP_NODELAY must not reach a UDP listener -----------------------------
# socat refuses the option on UDP-LISTEN ("option "nodelay" not supported with
# this address type"), which killed the whole rule on start — the same class as
# unix+keepalive and udp+retry before it.  The matrix suite starts the generated
# command for real, so it is the second half of this regression.
cat > "$WORK/in.show" <<'FIX'
socat.nd=config
socat.nd.enable=1
socat.nd.proto=udp
socat.nd.listen_port=6601
socat.nd.nodelay=1
socat.nd.dest_proto=udp4
socat.nd.dest_ip=10.0.0.9
socat.nd.dest_port=53
socat.tn=config
socat.tn.enable=1
socat.tn.proto=tcp
socat.tn.listen_port=6600
socat.tn.nodelay=1
socat.tn.dest_proto=tcp4
socat.tn.dest_ip=10.0.0.9
socat.tn.dest_port=80
FIX
run_gen "$V6"
check 'a udp rule with nodelay still listens' 'nd/udp nd/udp6 tn/tcp tn/tcp6 ' "$(kinds)"
check 'a udp listener drops nodelay' 0 "$(cmdgrep 0 'UDP-LISTEN:6601,pf=ip4,fork,nodelay')"
check 'a udp6 listener drops nodelay' 0 "$(cmdgrep 0 'UDP6-LISTEN:6601,fork,nodelay')"
check 'a tcp listener keeps nodelay' 1 "$(cmdgrep 1 'TCP-LISTEN:6600,pf=ip4,fork,reuseaddr,nodelay')"

# ---- an IPv4 literal cannot be a v6 target ---------------------------------
# getaddrinfo with AF_INET6 rejects "192.168.1.9" on every connection, so the
# listener binds fine and forwards nothing: the rule looks healthy.  The mirror
# image of the "IPv6 target on a v4 dial" guard from the v6 round.  A hostname
# is still fine — it resolves to whichever family the record has.
cat > "$WORK/in.show" <<'FIX'
socat.b6=config
socat.b6.enable=1
socat.b6.proto=tcp
socat.b6.listen_port=6602
socat.b6.dest_proto=tcp6
socat.b6.dest_ip=192.168.1.9
socat.b6.dest_port=80
socat.b6u=config
socat.b6u.enable=1
socat.b6u.proto=udp
socat.b6u.listen_port=6603
socat.b6u.dest_proto=udp6
socat.b6u.dest_ip=10.0.0.9
socat.b6u.dest_port=53
socat.ok6=config
socat.ok6.enable=1
socat.ok6.proto=tcp
socat.ok6.listen_port=6604
socat.ok6.dest_proto=tcp6
socat.ok6.dest_ip=example.org
socat.ok6.dest_port=80
FIX
run_gen "$V6"
check 'a v4 literal target on a tcp6 dial starts nothing' 0 "$(cmdgrep 0 'TCP6:192.168.1.9:80')"
check 'a v4 literal target on a udp6 dial starts nothing' 0 "$(cmdgrep 0 'UDP6:10.0.0.9:53')"
has 'a v4 target on a v6 dial says why' 'b6:an IPv4 target needs dest_proto tcp4/udp4, skip' "$(warns)"
# both the v4 and the v6 listener of that rule dial the same TCP6 target
check 'a hostname target on a tcp6 dial is kept' 2 "$(cmdgrep 2 'TCP6:example.org:80')"

# ---- mcast_iface is validated on a relay rule too --------------------------
# On a dest_proto=mcast rule mcast_iface is part of the *dial* address, and that
# path runs even when no group is joined: an unchecked value used to land in the
# command line verbatim (the receive side validated it, this side did not).
cat > "$WORK/in.show" <<'FIX'
socat.mc=config
socat.mc.enable=1
socat.mc.proto=udp
socat.mc.listen_port=6605
socat.mc.dest_proto=mcast
socat.mc.mcast_dst_group=239.10.10.20
socat.mc.mcast_dst_port=5000
socat.mc.mcast_iface='eth0 -T99 evil'
FIX
run_gen "$V6"
check 'a hostile mcast_iface emits nothing' '' "$(kinds)"
has 'a hostile mcast_iface is refused with a reason' 'mc:bad mcast_iface, skip' "$(warns)"

# ---- a request that cannot be honoured must still say why ------------------
cat > "$WORK/in.show" <<'FIX'
socat.v1=config
socat.v1.enable=1
socat.v1.proto=ssl
socat.v1.listen_port=6606
socat.v1.ssl_cert=/etc/ssl/c.pem
socat.v1.ssl_key=/etc/ssl/k.pem
socat.v1.dest_proto=ssl
socat.v1.dest_ip=10.0.0.9
socat.v1.dest_port=443
socat.v1.ssl_verify=1
socat.v2=config
socat.v2.enable=1
socat.v2.proto=ssl
socat.v2.listen_port=6607
socat.v2.listen_addr=2001:db8::9
socat.v2.ssl_cert=/etc/ssl/c.pem
socat.v2.ssl_key=/etc/ssl/k.pem
socat.v2.dest_proto=ssl
socat.v2.dest_ip=10.0.0.9
socat.v2.dest_port=443
socat.u3=config
socat.u3.enable=1
socat.u3.proto=unix
socat.u3.unix_path=/var/run/u3.sock
socat.u3.dest_proto=tcp4
socat.u3.dest_ip=10.0.0.9
socat.u3.dest_port=80
socat.u3.firewall_accept=1
FIX
run_gen "$V6"
has 'ssl_verify without a CA file is reported' \
	'v1:ssl_verify is on but ssl_cafile is empty (the target certificate is not verified)' "$(warns)"
has 'a v6 listen_addr on a TLS rule is reported' \
	'v2:listen_addr is ignored on a TLS listener (IPv4 only)' "$(warns)"
check 'the TLS listener ignores the v6 bind' 0 "$(cmdgrep 0 'bind=2001:db8::9')"
check 'a unix listener opens no firewall port' 0 "$(grep -c '^unix' "$WORK/out.fw")"

# ---- second awk implementation: the whole suite must hold there too ---------
# The engine on the router runs this generator with BusyBox awk, which is not
# byte-identical to gawk/mawk in its regex handling.  So the entire suite runs
# again from the top under BusyBox: run it with "AWK=busybox sh gen-cases.sh"
# (CI does exactly that).  A single fixture would prove nothing.
	if [ "$AWK" = "awk" ] && command -v busybox >/dev/null 2>&1; then
	echo
	echo "cross-check with BusyBox awk: re-running the whole suite"
	if AWK="busybox awk" sh "$0" "$GEN" < /dev/null; then
		PASS=$((PASS + 1)); printf '  %-46s ok\n' "busybox: whole suite green"
	else
		FAIL=$((FAIL + 1)); printf '  %-46s FAIL\n' "busybox: whole suite green"
		echo "    the BusyBox run above reported failures"
	fi
fi

rm -rf "$WORK"
summary 'generator unit tests'
