# socat-reforged desired-state generator  (BusyBox awk compatible)
#
# stdin : the output of `uci show socat`
# -v ipv6=<addr>   WAN IPv6 address (empty = no IPv6 available)
# -v socat=<path>  socat binary to use
# -v desf=<file>   desired records : sid \t kind \t port \t key \t command
# -v warnf=<file>  warnings        : sid \t message
# -v fwf=<file>    firewall ports  : proto \t port   ("igmp\t-" joins groups)
#
# "key" is the argv of the listener with spaces removed; it is what the shell
# matches against the NUL-stripped /proc/<pid>/cmdline of a running worker, so
# it costs no fork to compare.
#
# Everything that reaches a command line is validated here (whitelists, port
# ranges, no shell metacharacters), so a bad UCI value can never produce a
# broken or dangerous command.
#
# Protocol matrix:
#   proto (listen)  : tcp | udp | ssl (OPENSSL-LISTEN) | unix (UNIX-LISTEN)
#   dest_proto (dial: tcp4 | udp4 | tcp6 | udp6 | ssl (OPENSSL)
#                      | unix (UNIX-CONNECT) | mcast (UDP4-DATAGRAM)
#   udp + mcast_group    : join a multicast group (ip-add-membership)
#   tcp4 + proxy         : SOCKS4a / HTTP CONNECT (the only proxy target)

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
# a user the listener's children run as (socat's ",user=").  Same character set
# Linux usernames allow, no metacharacters, so it can never become an option.
function ok_user(v)  { return (v ~ /^[A-Za-z_][A-Za-z0-9_-]*$/ && length(v) <= 32) }
function ok_name(v)  { return (v ~ /^[A-Za-z0-9_.-]+$/) }
function ok_flag(v)  { return (v == "" || v == "0" || v == "1") }
function ipport(v)   { v = plain_num(v); return (v ~ /^[0-9]+$/ && v + 0 >= 1 && v + 0 <= 65535) }
function ok_uint(v, lo, hi) { v = plain_num(v); return (v ~ /^[0-9]+$/ && v + 0 >= lo && v + 0 <= hi) }
# absolute filesystem path (certificate/key/unix socket), no traversal
function ok_path(v) {
	return (v ~ /^\//) && (v ~ /^[A-Za-z0-9._\/-]+$/) && (index(v, "..") == 0)
}
# IPv4 multicast group 224.0.0.0 - 239.255.255.255
function ok_mgroup(v,  o) {
	if (v !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
	split(v, o, ".")
	if (o[1] + 0 < 224 || o[1] + 0 > 239) return 0
	if (o[2] + 0 > 255 || o[3] + 0 > 255 || o[4] + 0 > 255) return 0
	return 1
}

# awk's numeric coercion of a leading-zero string is implementation-defined:
# gawk and mawk read "0443" as 443, BusyBox awk as octal 291.  The router runs
# BusyBox awk, so a padded port must be normalised as a *string* - with "+ 0"
# it would silently become a different port on the device.
function plain_num(v) {
	sub(/^0+/, "", v)
	if (v == "") v = "0"
	return v
}

# listen_port may be a single port ("443") or a range ("30000-30010").
# Returns 0 and sets LP_FROM/LP_TO (plain decimals) on success.
# A range is expanded into one listener per port, so the span is capped: a
# typo like "1000-99999" must not turn into ~100k workers.  LP_CLAMPED is set
# when the cap kicked in so the caller can warn.
function lport_parse(v,  a, b, n) {
	LP_FROM = ""; LP_TO = ""; LP_CLAMPED = 0
	n = index(v, "-")
	if (n > 0) {
		a = substr(v, 1, n - 1); b = substr(v, n + 1)
		if (a !~ /^[0-9]+$/ || b !~ /^[0-9]+$/) return 1
		a = plain_num(a); b = plain_num(b)
		# plain_num() returns a string, so coerce for the bounds check:
		# without this "8080" > 65535 is a lexical comparison
		a = a + 0; b = b + 0
		if (a < 1 || b > 65535 || a > b) return 1
		if (b - a + 1 > LPORT_CAP) { b = a + LPORT_CAP - 1; LP_CLAMPED = 1 }
	}
	else {
		if (v !~ /^[0-9]+$/) return 1
		a = plain_num(v) + 0
		b = a
		if (a < 1 || b > 65535) return 1
	}
	LP_FROM = a; LP_TO = b
	return 0
}

# socat address host part: brackets are only valid around a *literal* IPv6
# address.  A hostname must go in unbracketed ("TCP6:example.org:80") or socat
# treats the brackets as part of the address and fails to resolve it — the
# "IPv6 domain silently does not forward" class of bug.
function dial_host(h) { return (h ~ /:/) ? "[" h "]" : h }

function emit(sid, kind, port, cmd,  key) {
	key = cmd
	gsub(/ /, "", key)
	print sid "\t" kind "\t" port "\t" key "\t" cmd > desf
}

# Global socat options go before the two addresses:
#   -T<n>   transfer timeout (per rule)
#   -ls -d  route socat's log through syslog (per rule "system_log")
function build_cmd(addr,  o) {
	o = socat
	if (TMO != "")
		o = o " -T" TMO
	if (SYSLOG_ON == "1")
		o = o " -ls -d"
	return o " " addr
}

BEGIN {
	FS = "\n"
	sq = sprintf("%c", 39)      # '
	bs = sprintf("%c", 92)      # backslash
	esc = sq bs sq sq           # UCI escaped quote: '\''
	nsec = 0
	KA = "keepalive,keepidle=60,keepintvl=10,keepcnt=5"
	# max listeners one rule may spawn through a port range
	LPORT_CAP = 256
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
		# socket options
		nodelay = V[sid, "nodelay"]
		backlog = V[sid, "backlog"]
		maxkids = V[sid, "max_children"]
		tmo     = V[sid, "timeout"]
		syslog  = V[sid, "system_log"]
		kalive  = V[sid, "keepalive"]
		laddr   = V[sid, "listen_addr"]
		# process + connection options (socat ",user=" on the listener,
		# ",retry=" on the dial)
		uuser   = V[sid, "user"]
		rtry    = V[sid, "retry"]
		# tls / unix paths
		ucert   = V[sid, "ssl_cert"]
		ukey    = V[sid, "ssl_key"]
		ucafile = V[sid, "ssl_cafile"]
		uverify = V[sid, "ssl_verify"]
		upath   = V[sid, "unix_path"]
		dupath  = V[sid, "dst_unix_path"]
		# multicast
		mcgrp   = V[sid, "mcast_group"]
		mcif    = V[sid, "mcast_iface"]
		mclip   = V[sid, "mcast_localip"]
		mcdgrp  = V[sid, "mcast_dst_group"]
		mcdp    = V[sid, "mcast_dst_port"]
		mcttl   = V[sid, "mcast_ttl"]
		mcloop  = V[sid, "mcast_loop"]

		if (en == "")                      # missing enable == enabled (UI default)
			en = "1"
		if (en != "1") {
			if (en != "0")
				warn(sid, "enable must be 0 or 1, treating as disabled")
			continue
		}
		if (!ok_name(sid))                 { warn(sid, "bad section id, skip"); continue }
		if (proto != "tcp" && proto != "udp" && proto != "ssl" && proto != "unix") {
			warn(sid, "bad proto, skip"); continue
		}
		if (proto == "unix" && (upath == "" || !ok_path(upath))) {
			warn(sid, "bad unix_path, skip"); continue
		}
		if (!ok_flag(nodelay))             { warn(sid, "bad nodelay, skip"); continue }
		if (!ok_flag(syslog))              { warn(sid, "bad system_log, skip"); continue }
		if (!ok_flag(kalive))              { warn(sid, "bad keepalive, skip"); continue }
		if (laddr != "" && !ok_host(laddr)) { warn(sid, "bad listen_addr, skip"); continue }
		if (uuser != "" && !ok_user(uuser)) { warn(sid, "bad user, skip"); continue }
		if (rtry != "" && !ok_uint(rtry, 0, 3600)) { warn(sid, "bad retry, skip"); continue }
		# validated here, not only inside the multicast-receive branch: on a
		# dest_proto=mcast rule mcast_iface reaches the *dial* address, and
		# that branch is not taken when no group is joined
		if (mcif != "" && !ok_name(mcif))  { warn(sid, "bad mcast_iface, skip"); continue }
		if (!ok_flag(ra))                  { warn(sid, "bad reuseaddr, skip"); continue }
		if (!ok_flag(uverify))             { warn(sid, "bad ssl_verify, skip"); continue }
		if (!ok_flag(mcloop))              { warn(sid, "bad mcast_loop, skip"); continue }
		if (backlog != "" && !ok_uint(backlog, 1, 65535)) { warn(sid, "bad backlog, skip"); continue }
		if (maxkids != "" && !ok_uint(maxkids, 1, 1000))  { warn(sid, "bad max_children, skip"); continue }
		if (tmo != "" && !ok_uint(tmo, 1, 86400))          { warn(sid, "bad timeout, skip"); continue }
		if (mcttl != "" && !ok_uint(mcttl, 1, 255))        { warn(sid, "bad mcast_ttl, skip"); continue }
		if (mcttl == "") mcttl = "1"
		if (proto == "ssl") {
			if (ucert == "" || !ok_path(ucert)) { warn(sid, "bad ssl_cert, skip"); continue }
			if (ukey  == "" || !ok_path(ukey))  { warn(sid, "bad ssl_key, skip"); continue }
		}
		# globals build_cmd prefixes
		TMO = (tmo != "") ? tmo : ""
		SYSLOG_ON = (syslog == "1") ? "1" : ""

		# ---- listen ports: none for unix, single port or range otherwise ---
		if (proto == "unix") {
			LP_FROM = 0; LP_TO = 0
		}
		else if (lport_parse(lp) != 0) { warn(sid, "bad listen port, skip"); continue }
		if (LP_CLAMPED) warn(sid, "port range larger than " LPORT_CAP " ports, clamped")

		# ---- multicast receive (udp only) ----------------------------------
		MC_RECV = ""
		if (mcgrp != "") {
			if (proto != "udp") {
				warn(sid, "multicast group needs proto=udp, ignored")
				mcgrp = ""
			}
			else if (!ok_mgroup(mcgrp)) { warn(sid, "bad mcast_group, skip"); continue }
			else if (mclip != "" && !ok_host(mclip)) { warn(sid, "bad mcast_localip, skip"); continue }
			else {
				# ip-add-membership=<group>:<local ip> joins the group (0.0.0.0 =
				# let the kernel pick); bind=<group> keeps two rules on the
				# same port from receiving each other's stream;
				# so-bindtodevice pins the receive interface.
				lp_if = mclip
				if (lp_if == "") lp_if = "0.0.0.0"
				MC_RECV = ",ip-add-membership=" mcgrp ":" lp_if ",bind=" mcgrp
				if (mcif != "")
					MC_RECV = MC_RECV ",so-bindtodevice=" mcif
				MC_RECV = MC_RECV RA
			}
		}

		# ---- dial side ------------------------------------------------------
		if (dproto != "tcp4" && dproto != "udp4" && dproto != "tcp6" && dproto != "udp6" \
		    && dproto != "unix" && dproto != "ssl" && dproto != "mcast") {
			warn(sid, "bad dest_proto, skip"); continue
		}
		if (fam != "" && fam != "4" && fam != "6") { warn(sid, "bad family, skip"); continue }

		if (dproto == "unix") {
			if (dupath == "" || !ok_path(dupath)) { warn(sid, "bad dst_unix_path, skip"); continue }
			DIAL = "UNIX-CONNECT:" dupath
		}
		else if (dproto == "mcast") {
			if (!ok_mgroup(mcdgrp)) { warn(sid, "bad mcast_dst_group, skip"); continue }
			if (!ipport(mcdp))      { warn(sid, "bad mcast_dst_port, skip"); continue }
			mcdp = plain_num(mcdp) + 0
			# UDP4-DATAGRAM is send-only, so a relayed stream expects nothing back
			DIAL = "UDP4-DATAGRAM:" mcdgrp ":" mcdp
			if (mcif != "")
				DIAL = DIAL ",ip-multicast-if=" mcif
			DIAL = DIAL ",ip-multicast-ttl=" mcttl
			if (mcloop == "1")
				DIAL = DIAL ",ip-multicast-loop=1"
		}
		else if (dproto == "ssl") {
			if (dip == "" || !ok_host(dip)) { warn(sid, "bad dest_ip, skip"); continue }
			if (!ipport(dp))                { warn(sid, "bad dest_port, skip"); continue }
			dp = plain_num(dp) + 0
			DIAL = "OPENSSL:" dial_host(dip) ":" dp
			if (uverify == "1" && ucafile != "") {
				if (!ok_path(ucafile)) { warn(sid, "bad ssl_cafile, skip"); continue }
				DIAL = DIAL ",verify=1,cafile=" ucafile
			}
			else
				DIAL = DIAL ",verify=0"
		}
		else {
			if (dp == "" || !ipport(dp))    { warn(sid, "bad dest_port, skip"); continue }
			dp = plain_num(dp) + 0
			if (dip == "" || !ok_host(dip)) { warn(sid, "bad dest_ip, skip"); continue }
			# A v6 literal in a v4 address is accepted by socat at bind time
			# and then fails on every connection ("TCP4: wrong number of
			# parameters"), so the rule would look healthy and forward nothing.
			if (dip ~ /:/ && (dproto == "tcp4" || dproto == "udp4")) {
				warn(sid, "an IPv6 target needs dest_proto tcp6/udp6/tls, skip")
				continue
			}
			# ...and its mirror image: getaddrinfo with AF_INET6 rejects a v4
			# literal on every connection ("Address family for hostname not
			# supported"), so the listener binds fine and the rule forwards
			# nothing while looking healthy.
			if (dip !~ /:/ && dip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ \
			    && (dproto == "tcp6" || dproto == "udp6")) {
				warn(sid, "an IPv4 target needs dest_proto tcp4/udp4, skip")
				continue
			}

			if (prox != "" && prox != "none") {
				if (dproto != "tcp4") { warn(sid, "proxy only valid with tcp4 target, skip"); continue }
				if (pserv == "") pserv = "127.0.0.1"
				if (pport == "") pport = "1080"
				if (!ipport(pport))          { warn(sid, "bad proxy_port, skip"); continue }
				pport = plain_num(pport) + 0
				if (!ok_host(pserv))         { warn(sid, "bad proxy_server, skip"); continue }
				# the proxy address is "SOCKS4A:<proxy>:<host>:<port>", so a v6
				# literal in the proxy field adds the colons the parser counts
				# fields on and socat refuses the address outright
				if (pserv ~ /:/)             { warn(sid, "proxy_server cannot be an IPv6 address, skip"); continue }
				if (prox == "socks4" || prox == "socks4a")
					DIAL = "SOCKS4A:" pserv ":" dip ":" dp ",socksport=" pport
				else if (prox == "http" || prox == "proxy")
					DIAL = "PROXY:" pserv ":" dip ":" dp ",proxyport=" pport
				else { warn(sid, "unknown proxy, skip"); continue }
			}
			else if (dproto == "tcp4") DIAL = "TCP4:" dip ":" dp
			else if (dproto == "udp4") DIAL = "UDP4:" dip ":" dp
			else if (dproto == "tcp6") DIAL = "TCP6:" dial_host(dip) ":" dp
			else                      DIAL = "UDP6:" dial_host(dip) ":" dp
		}

		# TCP_NODELAY on the dial side too (the listener carries its own copy)
		ND = ""
		if (nodelay == "1" && (dproto == "tcp4" || dproto == "tcp6"))
			ND = ",nodelay"

		# the listener's children run as this user (drop privileges after the
		# socket is open).  Empty = leave it alone (root).
		USR = ""
		if (uuser != "")
			USR = ",user=" uuser

		# ",retry=N": keep dialling a target that is not up yet instead of
		# giving up and dropping the connection.  Seconds, 0 = socat default.
		# Only for connection-oriented dials: socat rejects the option on a
		# UDP address ("retry not supported with this address type"), which
		# would kill every udp rule that set it.
		RTY = ""
		if (rtry != "" && plain_num(rtry) + 0 > 0 &&
		    dproto != "udp4" && dproto != "udp6" && dproto != "mcast")
			RTY = ",retry=" plain_num(rtry)

		RA = ""
		if (ra == "" || ra == "1")
			RA = ",reuseaddr"

		# keepalive is on by default (a rule may switch it off)
		KAD = ""
		if (kalive != "0")
			KAD = "," KA

		# ...but a unix socket has no TCP keepalive: socat rejects the option
		# ("keepidle not supported with this address type")
		KADL = KAD
		if (dproto == "unix")
			KADL = ""

		# bind the listener to one local address; a v6 literal replaces the
		# automatic WAN IPv6 bind, a v4 literal is used as-is
		BIND4 = ""
		BIND6 = ""
		if (laddr != "") {
			if (laddr ~ /:/) BIND6 = ",bind=" laddr ",ip-freebind=1"
			else             BIND4 = ",bind=" laddr
		}

		# listener tuning options (tcp/ssl).  ",nodelay" must not reach a UDP
		# listener: socat refuses the option on UDP-LISTEN ("option "nodelay"
		# not supported with this address type") and the whole rule would die
		# on start, exactly like unix+keepalive and udp+retry before it.
		LOPT = ""
		if (nodelay == "1" && (proto == "tcp" || proto == "ssl"))
			LOPT = LOPT ",nodelay"
		if (backlog != "" && (proto == "tcp" || proto == "ssl"))
			LOPT = LOPT ",backlog=" backlog
		if (maxkids != "" && (proto == "tcp" || proto == "ssl"))
			LOPT = LOPT ",max-children=" maxkids

		# per-rule warnings: only once, not once per port
		if (fam == "6" && ipv6 == "" && proto != "unix")
			warn(sid, "IPv6-only listen but no WAN IPv6 address")
		if (laddr != "" && MC_RECV != "")
			warn(sid, "listen_addr is ignored on a multicast listener (bind=group is used)")
		# socat refuses bind= on a UDP6 listener ("port specification not allowed
		# in this bind option"), so a v6 listen_addr on a udp rule cannot be
		# honoured: say so instead of silently binding every v6 address
		if (proto == "udp" && MC_RECV == "" && laddr != "" && BIND6 != "")
			warn(sid, "listen_addr is ignored on an IPv6 UDP listener (socat limitation)")
		# socat has no IPv6-capable OpenSSL listener (see the emit block), so an
		# explicit family=6 TLS rule cannot be honoured at all: skipping it with a
		# warning is better than starting a listener that dies on start.
		if (proto == "ssl") {
			if (fam == "6") {
				warn(sid, "TLS cannot listen on IPv6 with this socat, rule skipped")
				continue
			}
			if (fam != "4")
				warn(sid, "TLS listens on IPv4 only with this socat")
		}
		# multicast receive is UDP4-only (ip-add-membership on a v4 group), so
		# an IPv6-only multicast rule would produce no listener at all
		if (proto == "udp" && mcgrp != "" && fam == "6") {
			warn(sid, "multicast cannot listen on IPv6, rule skipped")
			continue
		}
		# socat's OpenSSL listener has no IPv6 capability, so a v6 listen_addr
		# on a TLS rule is dropped by the emit block; say so instead of binding
		# every IPv4 address without a word
		if (proto == "ssl" && BIND6 != "")
			warn(sid, "listen_addr is ignored on a TLS listener (IPv4 only)")
		# asking for certificate verification but giving no CA file would
		# silently fall back to "no verification at all"
		if (dproto == "ssl" && uverify == "1" && ucafile == "")
			warn(sid, "ssl_verify is on but ssl_cafile is empty (the target certificate is not verified)")

		for (lp = LP_FROM; lp <= LP_TO; lp++) {
			if (proto == "unix") {
				# no port at all: one listener on the socket path, then done.
				# unlink-early removes a socket file left behind by a crashed
				# listener, which would otherwise make the rebind fail.
				emit(sid, "unix", "-", build_cmd("UNIX-LISTEN:" upath ",fork,unlink-early" RA USR " " DIAL ND RTY KADL))
				break
			}
			if (proto == "tcp") {
				if (fam != "6")
					emit(sid, "tcp", lp, build_cmd("TCP-LISTEN:" lp ",fork" RA BIND4 LOPT KAD USR " " DIAL ND RTY KADL))
				if (fam != "4" && (ipv6 != "" || BIND6 != "")) {
					B6 = BIND6
					if (B6 == "") B6 = ",bind=" ipv6 ",ip-freebind=1"
					emit(sid, "tcp6", lp, build_cmd("TCP6-LISTEN:" lp ",fork" RA LOPT B6 KAD USR " " DIAL ND RTY KADL))
				}
			}
			else if (proto == "ssl") {
				# socat's OPENSSL-LISTEN cannot listen on IPv6 at all: every v6
				# form of bind= (a literal, bracketed, or "::") fails with
				# getaddrinfo EAI_ADDRFAMILY, and without a bind it binds IPv4
				# only.  A second OpenSSL listener for IPv6 would therefore die
				# on start and leave the rule "partial" forever with a
				# getaddrinfo error, so only the v4 listener is emitted and the
				# narrowing is warned about (the listener block above turned an
				# explicit family=6 into a skip, because that cannot be honoured).
				emit(sid, "ssltcp", lp, build_cmd("OPENSSL-LISTEN:" lp ",cert=" ucert ",key=" ukey ",verify=0,fork" RA BIND4 LOPT KAD USR " " DIAL ND RTY KADL))
			}
			else {
				if (MC_RECV != "") {
					# multicast receive: RECVFROM + fork hands each datagram to a
					# child while the listener itself keeps running
					if (fam != "6")
						emit(sid, "udp", lp, build_cmd("UDP4-RECVFROM:" lp MC_RECV ",fork" USR " " DIAL))
				}
				else {
					if (fam != "6")
						# ",pf=ip4" is not decoration: socat 1.8.0.0 (Ubuntu 24.04,
						# Debian 13) refuses a bare "UDP-LISTEN:port" with
						# "xioopen_ipdgram_listen(): unknown address family 0", while
						# UDP6-LISTEN and UDP4-RECVFROM carry the family in their name.
						# Pinning it costs nothing on 1.7.4 and 1.8.1 and keeps the
						# command portable across the socat versions the suite runs on.
						emit(sid, "udp", lp, build_cmd("UDP-LISTEN:" lp ",pf=ip4,fork" BIND4 LOPT USR " " DIAL))
					# NB: socat rejects bind= on UDP6-LISTEN ("port specification not
					# allowed in this bind option"), and a plain UDP6-LISTEN binds the
					# v6 wildcard (v6only), so it coexists with the v4 listener.
					if (fam != "4" && ipv6 != "")
						emit(sid, "udp6", lp, build_cmd("UDP6-LISTEN:" lp ",fork" USR " " DIAL))
				}
			}

			# (a unix listener breaks out of this loop above, so it never
			# reaches this line: it opens no port on the wire)
			if (fa != "0")
				print ((proto == "ssl") ? "tcp" : proto) "\t" lp > fwf
		}
		# joining a multicast group needs IGMP accepted on the WAN zones
		if (mcgrp != "" && fa != "0")
			print "igmp\t-" > fwf
	}
}
