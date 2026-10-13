# socat-reforged desired-state generator  (BusyBox awk compatible)
#
# stdin : the output of `uci show socat`
# -v ipv6=<addr>   WAN IPv6 address (empty = no IPv6 available)
# -v socat=<path>  socat binary to use
# -v desf=<file>   desired records : sid \t kind \t port \t key \t command
# -v warnf=<file>  warnings        : sid \t message
# -v fwf=<file>    firewall ports  : proto \t port
#
# "key" is the argv of the listener with spaces removed; it is what the shell
# matches against the NUL-stripped /proc/<pid>/cmdline of a running worker, so
# it costs no fork to compare.
#
# Everything that reaches a command line is validated here (whitelists, port
# ranges, no shell metacharacters), so a bad UCI value can never produce a
# broken or dangerous command.

function unq(v,  p) {
	if (length(v) >= 2 && substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq) {
		v = substr(v, 2, length(v) - 2)
		while ((p = index(v, esc)) > 0)
			v = substr(v, 1, p - 1) sq substr(v, p + 4)
	}
	return v
}

# Whitelist validation only: a simple character class behaves identically in
# mawk, gawk and BusyBox awk, and a whitelist can never admit a metacharacter.
function warn(sid, msg) { print sid "\t" msg > warnf }
function ok_host(v)  { return (v ~ /^[A-Za-z0-9._:-]+$/) }
function ok_name(v)  { return (v ~ /^[A-Za-z0-9_.-]+$/) }
function ok_flag(v)  { return (v == "" || v == "0" || v == "1") }
function ipport(v)   { return (v ~ /^[0-9]+$/ && v + 0 >= 1 && v + 0 <= 65535) }

function emit(sid, kind, port, cmd,  key) {
	key = cmd
	gsub(/ /, "", key)
	print sid "\t" kind "\t" port "\t" key "\t" cmd > desf
}

BEGIN {
	FS = "\n"
	sq = sprintf("%c", 39)      # '
	bs = sprintf("%c", 92)      # backslash
	esc = sq bs sq sq           # UCI escaped quote: '\''
	nsec = 0
	KA = "keepalive,keepidle=60,keepintvl=10,keepcnt=5"
	if (ipv6 == "" || ipv6 == "-") ipv6 = ""
}

{
	line = $0
	if (substr(line, 1, 6) != "socat.")
		next
	rest = substr(line, 7)
	eq = index(rest, "=")
	if (eq == 0)
		next
	lhs = substr(rest, 1, eq - 1)
	val = unq(substr(rest, eq + 1))
	# a section declaration is "socat.<name>=config" - the name may contain
	# dots, so decide on the value, not on the shape of the name.
	if (val == "config") {
		secs[++nsec] = lhs
		next
	}
	# option line: split on the LAST dot (option names never contain one)
	dot = 0
	for (i = length(lhs); i > 0; i--)
		if (substr(lhs, i, 1) == ".") { dot = i; break }
	if (dot == 0)
		next
	sec = substr(lhs, 1, dot - 1)
	optname = substr(lhs, dot + 1)
	if (optname !~ /^[a-z][a-z0-9_]*$/)
		next
	V[sec, optname] = val
}

END {
	for (i = 1; i <= nsec; i++) {
		sid    = secs[i]
		proto  = V[sid, "proto"]
		lp     = V[sid, "listen_port"]
		dproto = V[sid, "dest_proto"]
		dip    = V[sid, "dest_ip"]
		dp     = V[sid, "dest_port"]
		fam    = V[sid, "family"]
		prox   = V[sid, "proxy"]
		pserv  = V[sid, "proxy_server"]
		pport  = V[sid, "proxy_port"]
		ra     = V[sid, "reuseaddr"]
		fa     = V[sid, "firewall_accept"]
		en     = V[sid, "enable"]

		if (en == "")                      # missing enable == enabled (UI default)
			en = "1"
		if (en != "1") {
			if (en != "0")
				warn(sid, "enable must be 0 or 1, treating as disabled")
			continue
		}
		if (!ok_name(sid))                 { warn(sid, "bad section id, skip"); continue }
		if (proto != "tcp" && proto != "udp") { warn(sid, "bad proto, skip"); continue }
		if (!ipport(lp))                   { warn(sid, "bad listen_port, skip"); continue }
		if (!ipport(dp))                   { warn(sid, "bad dest_port, skip"); continue }
		if (dip == "" || !ok_host(dip))    { warn(sid, "bad dest_ip, skip"); continue }
		if (dproto != "tcp4" && dproto != "udp4" && dproto != "tcp6" && dproto != "udp6") {
			warn(sid, "bad dest_proto, skip"); continue
		}
		if (fam != "" && fam != "4" && fam != "6") { warn(sid, "bad family, skip"); continue }
		if (!ok_flag(ra))                  { warn(sid, "bad reuseaddr, skip"); continue }

		if (prox != "" && prox != "none") {
			if (dproto != "tcp4") { warn(sid, "proxy only valid with tcp4 target, skip"); continue }
			if (pserv == "") pserv = "127.0.0.1"
			if (pport == "") pport = "1080"
			if (!ipport(pport))              { warn(sid, "bad proxy_port, skip"); continue }
			if (!ok_host(pserv))             { warn(sid, "bad proxy_server, skip"); continue }
			if (prox == "socks4" || prox == "socks4a")
				DIAL = "SOCKS4A:" pserv ":" dip ":" dp ",socksport=" pport
			else if (prox == "http" || prox == "proxy")
				DIAL = "PROXY:" pserv ":" dip ":" dp ",proxyport=" pport
			else { warn(sid, "unknown proxy, skip"); continue }
		}
		else if (dproto == "tcp4") DIAL = "TCP4:" dip ":" dp
		else if (dproto == "udp4") DIAL = "UDP4:" dip ":" dp
		else if (dproto == "tcp6") DIAL = "TCP6:[" dip "]:" dp
		else                      DIAL = "UDP6:[" dip "]:" dp

		RA = ""
		if (ra == "" || ra == "1")
			RA = ",reuseaddr"

		if (proto == "tcp") {
			if (fam != "6")
				emit(sid, "tcp", lp, socat " TCP-LISTEN:" lp ",fork" RA "," KA " " DIAL "," KA)
			if (fam != "4" && ipv6 != "")
				emit(sid, "tcp6", lp, socat " TCP6-LISTEN:" lp ",fork" RA ",bind=" ipv6 ",ip-freebind=1," KA " " DIAL "," KA)
			if (fam == "6" && ipv6 == "")
				warn(sid, "IPv6-only listen but no WAN IPv6 address")
		}
		else {
			if (fam != "6")
				emit(sid, "udp", lp, socat " UDP-LISTEN:" lp ",fork " DIAL)
			# NB: socat rejects bind= on UDP6-LISTEN ("port specification not
			# allowed in this bind option"), and a plain UDP6-LISTEN binds the
			# v6 wildcard (v6only), so it coexists with the v4 listener.
			if (fam != "4" && ipv6 != "")
				emit(sid, "udp6", lp, socat " UDP6-LISTEN:" lp ",fork " DIAL)
			if (fam == "6" && ipv6 == "")
				warn(sid, "IPv6-only listen but no WAN IPv6 address")
		}

		if (fa != "0")
			print proto "\t" lp > fwf
	}
}
