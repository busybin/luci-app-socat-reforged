# socat-reforged WAN zone detection (BusyBox awk compatible)
#
# stdin : "uci show network", a line containing only "%%FIREWALL%%", then
#         "uci show firewall"
# -v dev=<device> : the device holding the default route
#
# Prints the firewall zone name(s) that cover that device, one per line
# (usually just "wan").  Empty output = we could not tell, and the caller
# must then NOT write firewall rules (guessing would put the rule in the
# wrong zone or fail fw4 validation).

function unq(v) {
	if (length(v) >= 2 && substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)
		v = substr(v, 2, length(v) - 2)
	return v
}

function val(line) {                 # value part of "a.b.c='x y'"
	v = line
	sub(/^[^=]*=/, "", v)
	return unq(v)
}

function sec_of(line) {              # section part of "a.b.c=..." -> "b"
	s = line
	sub(/=.*$/, "", s)
	sub(/^[^.]*\./, "", s)
	sub(/\..*$/, "", s)
	return s
}

function opt_of(line) {              # option part of "a.b.c=..." -> "c"
	o = line
	sub(/=.*$/, "", o)
	sub(/^[^.]*\./, "", o)
	sub(/^[^.]*\./, "", o)
	return o
}

BEGIN {
	FS = "\n"
	sq = sprintf("%c", 39)
	fw = 0
	if (dev == "")
		dev = "-"
	cands[dev] = 1              # is a candidate name itself
}

/^%FIREWALL%$/ { fw = 1; next }

fw == 0 {
	# network.<sec>.device='eth0.2' / .ifname=...
	if ($0 ~ /^network\.[^.]+\.[a-zA-Z0-9_]+=/ && (opt_of($0) == "device" || opt_of($0) == "ifname")) {
		v = val($0)
		if (index(" " v " ", " " dev " ") > 0)
			cands[sec_of($0)] = 1     # ... is the logical interface name
	}
	next
}

{
	if ($0 !~ /^firewall\.[^.]+\.[a-zA-Z0-9_]+=/)
		next
	s = sec_of($0)
	o = opt_of($0)
	if (o == "name")
		zname[s] = val($0)
	else if (o == "network" || o == "device") {
		if (!(s in seen))
			seen[s] = 1
		zlist[s] = zlist[s] " " val($0)
	}
}

END {
	for (s in seen) {
		n = split(zlist[s], t, " ")
		hit = 0
		for (i = 1; i <= n; i++)
			if (t[i] in cands)
				hit = 1
		if (!hit)
			continue
		if (s in zname && zname[s] != "")
			print zname[s]
		else if (substr(s, 1, 1) != "@")
			print s          # a named section doubles as the zone name
		# an anonymous zone with no name option cannot be referenced by a
		# rule's src at all, so skip it rather than inventing a name
	}
}
