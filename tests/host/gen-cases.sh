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
WORK=$HERE/.work
rm -rf "$WORK"; mkdir -p "$WORK"

V6="2001:db8:1::55"

run_gen() { # run_gen <mode>  →  writes $WORK/out.des / out.warn / out.fw
	: > "$WORK/out.des"; : > "$WORK/out.warn"; : > "$WORK/out.fw"
	awk -v ipv6="$1" -v socat=/usr/bin/socat \
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
cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=00443
socat.a.dest_proto=tcp4
socat.a.dest_ip=192.168.1.7
socat.a.dest_port=00080
socat.a.firewall_accept=1
FIX
run_gen "$V6"
check 'padded ports still yield listeners' 'a/tcp a/tcp6 ' "$(kinds)"
contains 'listener uses the plain port' 'TCP-LISTEN:443,' "$(cat "$WORK/out.des")"
contains 'dial uses the plain dest port' 'TCP4:192.168.1.7:80' "$(cat "$WORK/out.des")"
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

# ---- second awk implementation: the tests must hold there too -------------
if command -v busybox >/dev/null 2>&1; then
	echo
	echo "cross-check with BusyBox awk"
	cat > "$WORK/in.show" <<'FIX'
socat.a=config
socat.a.enable=1
socat.a.proto=tcp
socat.a.listen_port=8080
socat.a.dest_proto=tcp4
socat.a.dest_ip=10.0.0.9
socat.a.dest_port=80
socat.a.firewall_accept=1
FIX
	busybox awk -v ipv6="$V6" -v socat=/usr/bin/socat \
		-v desf="$WORK/b.des" -v warnf="$WORK/b.warn" -v fwf="$WORK/b.fw" \
		-f "$GEN" < "$WORK/in.show"
	BK=$(awk -F'\t' '{printf "%s/%s ", $1, $2}' "$WORK/b.des")
	check 'busybox: same listeners as the host awk' 'a/tcp a/tcp6' "${BK% }"
fi

rm -rf "$WORK"
summary 'generator unit tests'
