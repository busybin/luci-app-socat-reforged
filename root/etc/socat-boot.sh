#!/bin/sh
# ============================================================================
#  socat-reforged forwarding engine  (V4)
# ============================================================================
#  Reconciles /etc/config/socat against the running socat workers.
#
#  What changed against V2
#  -----------------------
#  * IPv6 is discovered from the default route device (any WAN type).  The
#    engine no longer refuses to work when there is no IPv6: IPv6 listeners
#    are simply omitted and everything else runs normally.
#  * Config is parsed with ONE `uci show` + ONE awk pass (see
#    /usr/libexec/socat-reforged-gen.awk) into $RUNDIR/desired.  V2 forked
#    ~200 times per 15s cycle just to find out that nothing had changed.
#  * Workers we start carry SOCAT_REFORGED=1 in their environment and are
#    matched by reading /proc/<pid>/environ (zero forks), so we only ever
#    kill our own listeners, never somebody else's socat.
#  * Per-listener stderr is captured in $RUNDIR/err/<sid>-<kind>-<port>.log
#    (named after the rule, not just the port: two rules that share a port
#    must not share one stderr file) and published in $RUNDIR/state, so the
#    UI can say WHY a rule is down.
#
#  The engine log goes to syslog *and* to a size-capped file
#  (/var/log/socat-reforged.log): syslog's ring buffer is small and is wiped
#  on every reboot, so "what happened before it died" would otherwise be gone.
#  The LuCI view reads that file directly (ubus luci.socat-reforged log).
#  A steady state is silent on purpose, so a rate-limited "alive:" line every
#  ~15 min is the log's proof of life.
#  * The personal-environment behaviour of V2 left the default path: the
#    2000::/3 route fix and the WireGuard DNAT watchdog are opt-in UCI
#    switches (default off) and never flush conntrack.
#  * Firewall sync rate-limits retries, aggregates consecutive ports into
#    ranges, and self-heals if its rules were removed behind our back.
#  * A listener is identified by the fact that it still owns the listening
#    socket (/proc/net state 0A/07), not only by its parent pid: socat `,fork`
#    leaves a per-connection child whose argv is identical, and once the
#    listener dies that child is reparented to init and would otherwise be
#    mistaken for a healthy listener (so the rule was never restarted).
#  * The main loop records why it stopped (signal trap + a last-exit file) and
#    logs an unclean previous run on start, so a silent crash is visible.
#
#  Runtime state (/var/run/socat-reforged, never /tmp):
#     engine.lock/       singleton guard for this loop
#     reconcile.lock/    serialises loop + on-demand reconcile
#     desired            desired listeners: sid TAB kind TAB port TAB key TAB cmd
#     desired.cache      last applied desired set
#     state              per-listener state for the LuCI backend / CLI
#     fw                 firewall ports: proto TAB port
#     fw.sig             firewall sync signature (or a retry marker)
#     pids/<kind>-<port> pid of the running listener
#     err/<kind>-<port>.log  stderr of that listener
#     gen.warn           validation warnings of the last generation
#     ratelog/           rate-limit bookkeeping for log messages
# ============================================================================
LOG_TAG="socat-boot"

# Never depend on the caller's PATH: procd, the ucitrack trigger, a cron job
# and an interactive shell all hand us different ones.  Everything the engine
# needs is resolved once, here, with a plain-name fallback so a missing tool
# degrades instead of exploding.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

find_bin() { command -v "$1" 2>/dev/null || echo "$1"; }

AWK_BIN=$(find_bin awk)
IP_BIN=$(find_bin ip)
UCI_BIN=$(find_bin uci)
PGREP_BIN=$(find_bin pgrep)
LOGGER_BIN=$(find_bin logger)
DATE_BIN=$(find_bin date)
TAIL_BIN=$(find_bin tail)
NFT_BIN=$(find_bin nft)
FW4_BIN=$(find_bin fw4)
CMP_BIN=$(find_bin cmp)
CP_BIN=$(find_bin cp)
WC_BIN=$(find_bin wc)
SORT_BIN=$(find_bin sort)
TR_BIN=$(find_bin tr)
CUT_BIN=$(find_bin cut)
HEAD_BIN=$(find_bin head)
SED_BIN=$(find_bin sed)
GREP_BIN=$(find_bin grep)

RUNDIR=/var/run/socat-reforged
DESF=$RUNDIR/desired
CACHEF=$RUNDIR/desired.cache
STATEF=$RUNDIR/state
STATEC=$RUNDIR/state.cache
FWF=$RUNDIR/fw
FWSIG=$RUNDIR/fw.sig
WARNF=$RUNDIR/gen.warn
PIDDIR=$RUNDIR/pids
ERRDIR=$RUNDIR/err
RATELOG=$RUNDIR/ratelog
HB=/var/run/socat-reforged.hb
ALIVE_MARK=$RUNDIR/engine.alive    # present only while our loop is running
GPROG=/usr/libexec/socat-reforged-gen.awk
ZONES_AWK=/usr/libexec/socat-reforged-zones.awk
VERF=/usr/libexec/socat-reforged-version
CFG=/etc/config/socat

TAB=$(printf '\t')
MARKER="SOCAT_REFORGED=1"
KA="keepalive,keepidle=60,keepintvl=10,keepcnt=5"

INTERVAL=15          # loop period, seconds
FULL_EVERY=8         # cycles between unconditional full passes (~2 min)
MEM_EVERY=4          # cycles between memory checks (~1 min)
FW_EVERY=8           # cycles between firewall rule-existence checks
V6_EVERY=8           # cycles between IPv6 address refresh (~2 min)
ALIVE_EVERY=60       # cycles between "still alive" log lines (~15 min)
FW_MAX_ZONES=4       # multi-WAN: how many zones get their own accept rule
MEM_WARN=20          # warn below this % of MemTotal
MEM_CRIT=10          # restart socat below this % of MemTotal
MEM_FLOOR_KB=4096    # ... or below this absolute amount, whichever comes first
FW_RETRY=300         # seconds to wait before retrying a failed fw4 reload

CYCLE=0
MEM_FAILS=0
MEM_LAST_ACTION=-99
IPV6=""
V6DEV=""
WAN_DEV=""
WAN_ZONES=""
SCAN=""               # "pid<TAB>argv-key<TAB>marked" per line, children included
LISTENERS=""         # listeners only
RUN=""               # "pid key pid key ..." (keys never contain spaces)
RUN_KEYS=""
DES_KEYS=""
WORKER_COUNT=0
LIST_COUNT=0
LOOP_PID=""           # this loop's pid (empty while a one-shot runs us)
LISTEN_TCP=""         # " p port ... " sets of ports with a socket in
LISTEN_TCP6=""        #   LISTEN/bound state, per protocol family
LISTEN_UDP=""
LISTEN_UDP6=""
LISTEN_OK=0           # 1 = the socket tables were readable this pass

[ -n "$SOCAT_BIN" ] || SOCAT_BIN=$(find_bin socat)

# ---------------------------------------------------------------- logging ---

# zero-fork "seconds since boot"
uptime_s() {
	local up rest
	up=""
	rest=""
	read -r up rest < /proc/uptime 2>/dev/null
	[ -n "$up" ] || { echo 0; return; }
	echo "${up%%.*}"
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# log_rate <key> <min_interval_s> <message...>
log_rate() {
	local key="$1" iv="$2"; shift 2
	local f="$RATELOG/$key" last now
	[ -n "$iv" ] || iv=300
	now=$(uptime_s)
	last=0
	[ -f "$f" ] && read -r last < "$f" 2>/dev/null
	is_uint "$last" || last=0
	if [ $((now - last)) -lt "$iv" ]; then
		return 1
	fi
	echo "$now" > "$f" 2>/dev/null
	log "$*"
}

# --------------------------------------------------------------- run state ---

mkrun() {
	mkdir -p "$RUNDIR" "$PIDDIR" "$ERRDIR" "$RATELOG" 2>/dev/null
}

# engine's own settings live in the (internal) socat.reforged section
opt() { # opt <name> [default]
	local v
	v=$($UCI_BIN -q get "socat.reforged.$1" 2>/dev/null)
	if [ -n "$v" ]; then echo "$v"; else echo "${2:-}"; fi
}

debug_on() { [ "$(opt debug 0)" = "1" ]; }

# ------------------------------------------------------------ engine log ----
# logger(1) only reaches syslog: a small ring buffer that is wiped on every
# reboot, so the history before a crash is often already gone.  Every line is
# therefore also appended to a file that survives reboots, capped at
# $LOG_MAX_KB (only the newest half is kept), and that is what the LuCI view
# shows.  /var/log is tmpfs on OpenWrt, so this costs RAM, never flash.
LOGF=/var/log/socat-reforged.log
LOG_MAX_KB=64

log() {
	if [ -n "$LOGF" ]; then
		printf '%s %s\n' "$($DATE_BIN '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" \
			>> "$LOGF" 2>/dev/null || true
	fi
	"$LOGGER_BIN" -t "$LOG_TAG" "$1" 2>/dev/null || true
}

# Keep the file at or below the cap.  Called once per engine cycle: a burst
# inside one cycle is orders of magnitude below 64 KiB, so checking more often
# would only cost forks.
log_rotate() {
	[ -n "$LOGF" ] || return 0
	[ -f "$LOGF" ] || return 0
	local size keep
	size=$($WC_BIN -c < "$LOGF" 2>/dev/null)
	is_uint "$size" || return 0
	[ "$size" -gt $((LOG_MAX_KB * 1024)) ] || return 0
	keep=$((LOG_MAX_KB * 1024 / 2))
	if $TAIL_BIN -c "$keep" "$LOGF" > "$LOGF.tmp" 2>/dev/null; then
		mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
	fi
	rm -f "$LOGF.tmp" 2>/dev/null
	return 0
}

# Version of the *installed* build, stamped by install.sh / the package
# postinst into /usr/libexec/socat-reforged-version.  Read fork-free; a missing
# file (hand-copied engine) must not stop anything.
read_version() {
	local k v
	PKG_VERSION="devel"
	BUILD="devel"
	BUILT=""
	if [ -f "$VERF" ]; then
		while IFS='=' read -r k v; do
			case "$k" in
				PKG_VERSION) PKG_VERSION="$v" ;;
				BUILD)        BUILD="$v" ;;
				BUILT)        BUILT="$v" ;;
			esac
		done < "$VERF"
	fi
}

# Publish it where the LuCI backend and `socat-boot.sh status` can see it.
write_version_file() {
	echo "PKG_VERSION=$PKG_VERSION" > "$RUNDIR/version"
	echo "BUILD=$BUILD"          >> "$RUNDIR/version"
	echo "BUILT=$BUILT"          >> "$RUNDIR/version"
}

version_line() {
	printf 'v%s (%s)' "$PKG_VERSION" "$BUILD"
}

# ------------------------------------------------- file helpers --------------

same_file() { # same_file <a> <b> - true when both exist with identical content
	[ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"
}

copy_file() { cp -f "$1" "$2" 2>/dev/null; }
line_count() { local n=0; [ -f "$1" ] && n=$(wc -l < "$1"); echo "$n"; }

# ------------------------------------------------- desired state generation ---
# 2 forks (`uci show` + awk) and no more.  $RUNDIR/fw gets the WAN ports.
gen_desired() {
	if [ ! -f "$GPROG" ]; then
		log_rate "nogen" 3600 "ERROR: generator $GPROG is missing"
		return 1
	fi
	# Never let a missing tool look like "the user disabled everything":
	# an empty desired set would make reconcile stop every worker we own.
	if [ ! -x "$AWK_BIN" ] || [ ! -x "$UCI_BIN" ]; then
		log_rate "notools" 3600 "ERROR: awk ($AWK_BIN) or uci ($UCI_BIN) missing; not reconciling"
		return 1
	fi
	: > "$WARNF"
	: > "$DESF"
	# awk only opens its output file on the first print, so without this an
	# empty result would leave the *previous* port list in place: deleting the
	# last forward (or turning firewall_accept off everywhere) would keep its
	# WAN port open forever.
	: > "$FWF"
	$UCI_BIN show socat 2>/dev/null | "$AWK_BIN" -v ipv6="$IPV6" -v socat="$SOCAT_BIN" \
		-v desf="$DESF" -v warnf="$WARNF" -v fwf="$FWF" -f "$GPROG"
	return 0
}

# Rate-limited per section, so one broken rule cannot spam the log.
flush_warnings() {
	local sec msg key
	[ -s "$WARNF" ] || return 0
	while IFS="$TAB" read -r sec msg; do
		[ -n "$sec" ] || continue
		key="gen-$(printf '%s' "$sec" | tr -c 'A-Za-z0-9_.-' '_')"
		log_rate "$key" 900 "WARN [$sec] $msg"
	done < "$WARNF"
	: > "$WARNF"
}

# ----------------------------------------------------------------- sockets ---
# Ports that currently have a listening (0A) TCP or bound (07) UDP socket,
# straight out of /proc/net, kept per protocol family.  This is what tells a
# real listener apart from an orphaned per-connection child.  Matching by
# family matters: a tcp6 listener on the same port must not make an orphaned
# *v4* child look alive.
_listen_ports() { # _listen_ports <state> <file...>
	local st="$1"; shift
	"$AWK_BIN" -v st="$st" '
		function h2d(s,  i,c,n,hex){ hex="0123456789ABCDEF"; n=0; s=toupper(s)
			for (i=1;i<=length(s);i++){ c=substr(s,i,1); n=n*16+index(hex,c)-1 } return n }
		FNR>1 && $4==st { split($2,a,":"); printf " %d", h2d(a[2]) }
	' "$@" 2>/dev/null
}

collect_listen_ports() {
	[ -r /proc/net/tcp ] || return 1
	LISTEN_TCP=" $(_listen_ports 0A /proc/net/tcp) "
	LISTEN_TCP6=" $(_listen_ports 0A /proc/net/tcp6) "
	LISTEN_UDP=" $(_listen_ports 07 /proc/net/udp) "
	LISTEN_UDP6=" $(_listen_ports 07 /proc/net/udp6) "
	return 0
}

port_in_listen() { # port_in_listen <fam> <port>
	case "$1" in
		tcp)  case "$LISTEN_TCP"  in *" $2 "*) return 0 ;; esac ;;
		tcp6) case "$LISTEN_TCP6" in *" $2 "*) return 0 ;; esac ;;
		udp)  case "$LISTEN_UDP"  in *" $2 "*) return 0 ;; esac ;;
		udp6) case "$LISTEN_UDP6" in *" $2 "*) return 0 ;; esac ;;
	esac
	return 1
}

# Which kind of listener is this argv key?  Sets $FAM to tcp/tcp6/udp/udp6.
key_kind() {
	case "$1" in
		*OPENSSL-LISTEN*) FAM=tcp ;;    # an OpenSSL listener is still a TCP socket
		*TCP6-LISTEN*) FAM=tcp6 ;;
		*TCP-LISTEN*)  FAM=tcp ;;
		*UDP6-LISTEN*) FAM=udp6 ;;
		*UDP-LISTEN*)  FAM=udp ;;
		*UDP4-RECVFROM*) FAM=udp ;;
		*UDP-RECVFROM*)  FAM=udp ;;
		*)             FAM=""; return 1 ;;
	esac
	return 0
}

# The listen port encoded in a worker's argv key ("socat TCP-LISTEN:44550,..."
# with the spaces removed -> the digits after "LISTEN:" / "RECVFROM:").
# Sets $KEY_PORT.
key_port() {
	local x
	KEY_PORT=""
	x=${1#*LISTEN:}
	[ "$x" != "$1" ] || x=${1#*RECVFROM:}
	[ "$x" != "$1" ] || return 1
	KEY_PORT=${x%%,*}
	is_uint "$KEY_PORT" || { KEY_PORT=""; return 1; }
	return 0
}

# The socket path of a unix listener key ("...UNIX-LISTEN:/var/run/x.sock,fork").
# Sets $KEY_PATH.  Checked before key_port(): "UNIX-LISTEN:" also contains
# "LISTEN:", so the port parser would otherwise read the path as a port.
key_unix_path() {
	local x
	KEY_PATH=""
	x=${1#*UNIX-LISTEN:}
	[ "$x" != "$1" ] || return 1
	KEY_PATH=${x%%,*}
	[ -n "$KEY_PATH" ] || return 1
	return 0
}

# Is <path> a listening (state 01) unix socket right now?  /proc/net/unix lists
# every unix socket with its state and path, so this costs no fork and — unlike
# a plain "does the file exist" test — it survives a stale socket file left
# behind by a crashed listener.
unix_in_listen() {
	local path="$1" line
	[ -r /proc/net/unix ] || return 1
	while IFS= read -r line; do
		set -- $line
		[ "$6" = "01" ] || continue
		[ "$8" = "$path" ] && return 0
	done < /proc/net/unix
	return 1
}

# ---------------------------------------------------------- worker discovery ---
# Fill $SCAN ("pid<TAB>argv-key<TAB>marked" per line) for every socat worker.  /proc/<pid>/environ is NUL separated and busybox ash `read`
# concatenates those fields, so the marker test costs no fork.
scan_workers() {
	local p env cmd m
	SCAN=""
	WORKER_COUNT=0
	for p in $($PGREP_BIN socat 2>/dev/null); do
		[ -r "/proc/$p/environ" ] || continue
		# /proc files have no trailing newline, so `read` exits non-zero while
		# still filling the variable: test the value, never the exit status.
		env=""
		cmd=""
		read -r env < "/proc/$p/environ" 2>/dev/null
		[ -n "$env" ] || continue
		m=0
		case "$env" in *"$MARKER"*) m=1 ;; esac
		read -r cmd < "/proc/$p/cmdline" 2>/dev/null
		[ -n "$cmd" ] || continue
		case "$cmd" in
			*TCP-LISTEN*|*UDP-LISTEN*|*TCP6-LISTEN*|*UDP6-LISTEN*|*UDP-RECVFROM*|*UDP4-RECVFROM*|*UNIX-LISTEN*|*OPENSSL-LISTEN*) ;;
			*) continue ;;
		esac
		SCAN="$SCAN$p$TAB$cmd$TAB$m
"
		WORKER_COUNT=$((WORKER_COUNT + 1))
	done
}

# A forked per-connection child shares the listener's argv; a listener is a
# worker whose parent is not itself one of our workers.
# Sets $LISTENERS ("pid<TAB>key<TAB>marked" lines), $RUN ("pid key m ..."),
# $RUN_KEYS (" key key ...") and $LIST_COUNT.
# Unmarked workers are only observed, never adopted: the reconcile replaces them
# with a marked one (so Stop/Restart can always clean up after ourselves) but
# never touches socat processes that are not doing one of our jobs.
listener_pids() {
	local pid key m st rest ppid q keep
	RUN=""
	RUN_KEYS=""
	LISTENERS=""
	LIST_COUNT=0
	ALLPIDS=""
	LISTEN_OK=0
	collect_listen_ports && LISTEN_OK=1
	while IFS="$TAB" read -r pid key m; do
		[ -n "$pid" ] || continue
		ALLPIDS="$ALLPIDS $pid"
	done <<EOF
$SCAN
EOF
	while IFS="$TAB" read -r pid key m; do
		[ -n "$pid" ] || continue
		keep=1
		st=""
		read -r st < "/proc/$pid/stat" 2>/dev/null
		[ -n "$st" ] || continue
		rest=${st##*) }
		set -- $rest
		ppid=$2
		for q in $ALLPIDS; do
			[ "$q" = "$ppid" ] && { keep=0; break; }
		done
		[ "$keep" = "1" ] || continue
		# An orphaned per-connection child is reparented to init (ppid 1) and
		# keeps the listener's argv, so the ppid test cannot see it.  A real
		# listener still owns the listening socket; require its port to be in
		# LISTEN state.  If the tables were unreadable we keep the old guess.
		if [ "$LISTEN_OK" = "1" ]; then
			case "$key" in
			*UNIX-LISTEN:*)
				# no port table for unix sockets: require the socket to be
				# in LISTEN state (a stale file is not enough)
				key_unix_path "$key" || continue
				unix_in_listen "$KEY_PATH" || continue
				;;
			*)
				key_kind "$key" || continue
				key_port "$key" || continue
				port_in_listen "$FAM" "$KEY_PORT" || continue
				;;
			esac
		fi
		LISTENERS="$LISTENERS$pid$TAB$key$TAB$m
"
		RUN="$RUN$pid $key $m "
		RUN_KEYS="$RUN_KEYS $key"
		LIST_COUNT=$((LIST_COUNT + 1))
	done <<EOF
$SCAN
EOF
}

# Is this argv key currently running as one of our marked listeners?
# Sets $RUN_PID (empty when not running); no fork, no fragile re-tokenising.
find_pid() { # find_pid <key>
	local want="$1" p k m
	RUN_PID=""
	while IFS="$TAB" read -r p k m; do
		[ "$m" = "1" ] || continue
		[ "$k" = "$want" ] || continue
		RUN_PID="$p"
		return 0
	done <<EOF
$LISTENERS
EOF
	return 1
}

# The pid we treat as the live listener for one desired entry.  Prefer the
# scan (a process that still owns its own listening socket) and fall back to
# the pid recorded when we started it: that closes the tiny race right after a
# spawn, when the fresh worker is not in the LISTEN table yet.
# The registry/err files are keyed by (sid, kind, port): two rules may share
# a listen port, and they must not overwrite each other's bookkeeping.
# Sets $LL_PID.
live_listener_pid() { # live_listener_pid <sid> <kind> <port> <key>
	local reg rc f="$PIDDIR/$1-$2-$3" want="$4"
	LL_PID=""
	find_pid "$want" && { LL_PID="$RUN_PID"; return 0; }
	reg=""
	[ -f "$f" ] && read -r reg < "$f" 2>/dev/null
	[ -n "$reg" ] || return 1
	kill -0 "$reg" 2>/dev/null || return 1
	rc=""
	read -r rc < "/proc/$reg/cmdline" 2>/dev/null
	case "$rc" in *"$want"*) LL_PID="$reg"; return 0 ;; esac
	return 1
}

desired_keys() { # $DESF -> $DES_KEYS (" key key ... " -- note the trailing space)
	local sid kind port key cmd
	DES_KEYS=""
	while IFS="$TAB" read -r sid kind port key cmd; do
		[ -n "$key" ] || continue
		DES_KEYS="$DES_KEYS$key "
	done < "$DESF"
	DES_KEYS=" $DES_KEYS"
}

kill_workers() { # stop every worker of ours (TERM, then KILL)
	local p
	scan_workers
	for p in $(printf '%s\n' "$SCAN" | cut -f1,3 | awk -F'\t' '$2==1{print $1}'); do
		kill "$p" 2>/dev/null
	done
	sleep 1
	scan_workers
	for p in $(printf '%s\n' "$SCAN" | cut -f1,3 | awk -F'\t' '$2==1{print $1}'); do
		kill -9 "$p" 2>/dev/null
	done
}

# ------------------------------------------------------------- reconcile ----

reconcile() {
	local lockdir="$RUNDIR/reconcile.lock" i=0 lp
	mkrun
	while ! mkdir "$lockdir" 2>/dev/null; do
		i=$((i + 1))
		lp=""
		[ -f "$lockdir/pid" ] && read -r lp < "$lockdir/pid" 2>/dev/null
		if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then
			log "reconcile: clearing stale lock (pid $lp gone)"
			rm -rf "$lockdir"
			continue
		fi
		if [ -z "$lp" ] && [ "$i" -ge 3 ]; then
			rm -rf "$lockdir"
			continue
		fi
		[ "$i" -ge 20 ] && { log "reconcile busy, skip"; return 0; }
		sleep 1
	done
	echo $$ > "$lockdir/pid"

	reconcile_pass

	rm -rf "$lockdir"
	return 0
}

# Cheap liveness test: every registered listener must still be alive *and*
# still be our worker (a reused pid must not pass for a listener).
all_listeners_alive() {
	local sid kind port key cmd p c
	while IFS="$TAB" read -r sid kind port key cmd; do
		[ -n "$sid" ] || continue
		p=""
		[ -f "$PIDDIR/$sid-$kind-$port" ] && read -r p < "$PIDDIR/$sid-$kind-$port" 2>/dev/null
		if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
			return 1
		fi
		c=""
		read -r c < "/proc/$p/cmdline" 2>/dev/null
		case "$c" in *"$key"*) ;; *) return 1 ;; esac
	done < "$DESF"
	return 0
}

reconcile_pass() {
	local line sid kind port key cmd pid errf e reg rc seen dups
	local spawned=0 killed=0 remarked=0 kill_it

	[ -f "$CFG" ] || { log_rate "nocfg" 3600 "WARN: $CFG missing, nothing to reconcile"; return 0; }
	[ -x "$SOCAT_BIN" ] || { log_rate "nosocat" 3600 "WARN: $SOCAT_BIN missing, cannot start forwards"; return 0; }

	gen_desired || return 0
	flush_warnings
	desired_keys

	# ---- fast path: nothing changed and everything is still running -------
	if same_file "$DESF" "$CACHEF" && [ $((CYCLE % FULL_EVERY)) -ne 0 ] && all_listeners_alive; then
		copy_file "$STATEC" "$STATEF"
		return 0
	fi

	# ---- full pass --------------------------------------------------------
	scan_workers
	listener_pids

	# Stop listeners that are no longer wanted (only ever our own), plus the
	# unmarked leftovers of an older engine version, which we then replace
	# with a properly marked worker.
	remarked=0
	while IFS="$TAB" read -r pid key m; do
		[ -n "$pid" ] || continue
		kill_it=0
		case "$DES_KEYS" in
			*" $key "*)
				# wanted: keep ours, replace an unmarked legacy copy
				if [ "$m" != "1" ]; then
					kill_it=1
					remarked=$((remarked + 1))
				fi
				;;
			*)
				# not wanted any more: only ever stop our own
				[ "$m" = "1" ] && kill_it=1
				;;
		esac
		if [ "$kill_it" = "1" ]; then
			kill "$pid" 2>/dev/null
			killed=$((killed + 1))
		fi
	done <<EOF
$LISTENERS
EOF
	[ "$killed" -gt 0 ] && sleep 1
	[ "$remarked" -gt 0 ] && log "reconcile: replaced $remarked unmarked legacy listener(s)"

	# Duplicates: several of our listeners can carry the same argv key.  TCP
	# would refuse the second bind, but UDP honours SO_REUSEADDR and happily
	# binds twice, so duplicates can pile up silently over time.  If a desired
	# key has more than one listener, drop *all* of them and let the spawn loop
	# below start exactly one fresh one.
	seen=""
	dups=""
	while IFS="$TAB" read -r pid key m; do
		[ -n "$pid" ] || continue
		[ "$m" = "1" ] || continue
		case "$DES_KEYS" in *" $key "*) ;; *) continue ;; esac
		case "$seen" in
			*"|$key|"*) dups="$dups|$key|" ;;
			*)          seen="$seen|$key|" ;;
		esac
	done <<EOF
$LISTENERS
EOF
	if [ -n "$dups" ]; then
		while IFS="$TAB" read -r pid key m; do
			[ -n "$pid" ] || continue
			[ "$m" = "1" ] || continue
			case "$dups" in *"|$key|"*) kill "$pid" 2>/dev/null; killed=$((killed + 1)) ;; esac
		done <<EOF
$LISTENERS
EOF
		log "reconcile: duplicate listeners for$dups removed; respawning one each"
		sleep 1
		# the scan above is stale now; the spawn loop below needs fresh data
		scan_workers
		listener_pids
	fi

	# start what is missing (and refresh stale pid bookkeeping)
	while IFS="$TAB" read -r sid kind port key cmd; do
		[ -n "$sid" ] || continue
		live_listener_pid "$sid" "$kind" "$port" "$key"
		pid="$LL_PID"
		if [ -n "$pid" ]; then
			# keep the registry honest: a reused port must not keep a dead pid
			echo "$pid" > "$PIDDIR/$sid-$kind-$port"
			continue
		fi
		errf="$ERRDIR/$sid-$kind-$port.log"
		: > "$errf" 2>/dev/null
		# the assignment must be literal: $MARKER would expand to a command
		SOCAT_REFORGED=1 $cmd >/dev/null 2>"$errf" &
		echo $! > "$PIDDIR/$sid-$kind-$port"
		spawned=$((spawned + 1))
	done < "$DESF"

	copy_file "$DESF" "$CACHEF"
	publish_state

	if [ "$killed" -gt 0 ] || [ "$spawned" -gt 0 ]; then
		log "reconcile: started=$spawned stopped=$killed listeners=$(line_count "$DESF") (ipv6=${IPV6:-none})"
	fi
	return 0
}

# Per-listener state for the backend / CLI.
#   line 1 : engine <loop_pid> <uptime> <listeners>
#   rest   : <sid> <kind> <port> <pid|-> <error|->
publish_state() {
	local sid kind port key cmd pid e up rest lp
	scan_workers
	listener_pids
	up=""
	rest=""
	read -r up rest < /proc/uptime 2>/dev/null
	up=${up%%.*}
	# report the real engine loop, not the one-shot process that may be running us
	lp=$($PGREP_BIN -f '/etc/socat-boot.sh$' 2>/dev/null | head -1)
	[ -n "$lp" ] || lp=$$
	{
		echo "engine $lp $up $LIST_COUNT $PKG_VERSION $BUILD $BUILT"
		while IFS="$TAB" read -r sid kind port key cmd; do
			[ -n "$sid" ] || continue
			live_listener_pid "$sid" "$kind" "$port" "$key"
			pid="$LL_PID"
			e="-"
			# only report a reason when the listener really is not running:
			# the err file is per rule+kind+port and could hold a previous
			# attempt's message for a healthy listener
			if [ -z "$pid" ]; then
				pid="-"
				[ -s "$ERRDIR/$sid-$kind-$port.log" ] && read -r e < "$ERRDIR/$sid-$kind-$port.log" 2>/dev/null
				[ -n "$e" ] || e="-"
			fi
			echo "$sid $kind $port $pid $e"
		done < "$DESF"
	} > "$STATEF"
	copy_file "$STATEF" "$STATEC"
}

# --------------------------------------------------------------- firewall ---

# Consecutive ports (3+) are merged into ranges to keep the fw4 rule short.
agg_ports() { # stdin: ports -> stdout: space separated, ranges where useful
	local start="" prev="" p out=""
	while read -r p; do
		[ -n "$p" ] || continue
		if [ -z "$start" ]; then start=$p; prev=$p; continue; fi
		if [ $((p - prev)) -eq 1 ]; then prev=$p; continue; fi
		out="$out $(port_range "$start" "$prev")"
		start=$p; prev=$p
	done
	[ -n "$start" ] && out="$out $(port_range "$start" "$prev")"
	echo "${out# }"
}

port_range() { # port_range <first> <last>
	if [ "$1" = "$2" ]; then echo "$1"
	elif [ $(( $2 - $1 )) -eq 1 ]; then echo "$1 $2"
	else echo "$1-$2"; fi
}

fw_ports() { # $FWF -> $FW_TCP / $FW_UDP (raw, unsorted; zero forks)
	local proto port
	FW_TCP=""
	FW_UDP=""
	FW_IGMP=0
	[ -f "$FWF" ] || return 0
	while IFS="$TAB" read -r proto port; do
		[ -n "$port" ] || continue
		case "$proto" in
			tcp) FW_TCP="$FW_TCP $port" ;;
			udp) FW_UDP="$FW_UDP $port" ;;
			igmp) FW_IGMP=1 ;;
		esac
	done < "$FWF"
}

sync_firewall() {
	[ -x "$FW4_BIN" ] || return 0
	local TCP UDP raw_sig stored now p z sfx nzones zone miss
	fw_ports
	load_wan_zones
	raw_sig="zones:${WAN_ZONES:-none} tcp:$FW_TCP udp:$FW_UDP igmp:$FW_IGMP"
	stored=""
	[ -f "$FWSIG" ] && read -r stored < "$FWSIG" 2>/dev/null
	# stamped on every attempt, failure included: a fail marker without an
	# epoch cannot be parsed by the backoff below, and the first retry would
	# then run one cycle later instead of after FW_RETRY seconds.
	now=$(uptime_s)

	# without a known WAN zone we must not guess: a rule in the wrong zone
	# either does nothing or fails `fw4 check` (which we would then undo
	# every FW_RETRY seconds).
	if [ -z "$WAN_ZONES" ]; then
		log_rate "nozone" 3600 "WARN: no firewall zone found for WAN device '${WAN_DEV:-?}'; not managing the firewall (check your zone/network config)"
		return 0
	fi

	# happy path: already applied (and our rules still exist).  Check every
	# protocol we actually need, so a rule deleted behind our back for just
	# one of them is re-created as well.
	if [ "$stored" = "ok $raw_sig" ]; then
		if [ $((CYCLE % FW_EVERY)) -ne 0 ]; then
			return 0
		fi
		miss=0
		if [ -n "$FW_TCP" ] && ! $UCI_BIN -q get firewall.socat_reforged_tcp >/dev/null 2>&1; then miss=1; fi
		if [ -n "$FW_UDP" ] && ! $UCI_BIN -q get firewall.socat_reforged_udp >/dev/null 2>&1; then miss=1; fi
		if [ "$FW_IGMP" = "1" ] && ! $UCI_BIN -q get firewall.socat_reforged_igmp >/dev/null 2>&1; then miss=1; fi
		if [ "$miss" = "0" ]; then
			return 0
		fi
		log "firewall: our accept rules are gone, re-creating them"
	fi

	# backoff after a failed reload (do not fight a broken firewall forever)
	if [ "$stored" != "${stored#fail }" ]; then
		p=${stored##* }
		if is_uint "$p" && [ $((now - p)) -lt "$FW_RETRY" ]; then
			return 0
		fi
	fi

	TCP=$(printf '%s\n' $FW_TCP | sort -n -u | agg_ports)
	UDP=$(printf '%s\n' $FW_UDP | sort -n -u | agg_ports)

	# drop everything we may have created before (up to $FW_MAX_ZONES zones)
	z=0
	while [ $z -lt "$FW_MAX_ZONES" ]; do
		z=$((z + 1))
		sfx=""
		[ "$z" -gt 1 ] && sfx="_$z"
		$UCI_BIN -q delete "firewall.socat_reforged_tcp$sfx"
		$UCI_BIN -q delete "firewall.socat_reforged_udp$sfx"
		$UCI_BIN -q delete "firewall.socat_reforged_igmp$sfx"
	done

	# one rule per (zone, proto).  fw4 rules default to family "any", so both
	# the IPv4 and the IPv6 side of a zone are covered by these.
	nzones=0
	for zone in $WAN_ZONES; do
		nzones=$((nzones + 1))
		[ "$nzones" -le "$FW_MAX_ZONES" ] || break
		sfx=""
		[ "$nzones" -gt 1 ] && sfx="_$nzones"
		if [ -n "$TCP" ]; then
			$UCI_BIN set "firewall.socat_reforged_tcp$sfx=rule"
			$UCI_BIN set "firewall.socat_reforged_tcp$sfx.name=socat-reforged (tcp)"
			$UCI_BIN set "firewall.socat_reforged_tcp$sfx.src=$zone"
			$UCI_BIN set "firewall.socat_reforged_tcp$sfx.proto=tcp"
			$UCI_BIN set "firewall.socat_reforged_tcp$sfx.target=ACCEPT"
			for p in $TCP; do $UCI_BIN add_list "firewall.socat_reforged_tcp$sfx.dest_port=$p"; done
		fi
		if [ -n "$UDP" ]; then
			$UCI_BIN set "firewall.socat_reforged_udp$sfx=rule"
			$UCI_BIN set "firewall.socat_reforged_udp$sfx.name=socat-reforged (udp)"
			$UCI_BIN set "firewall.socat_reforged_udp$sfx.src=$zone"
			$UCI_BIN set "firewall.socat_reforged_udp$sfx.proto=udp"
			$UCI_BIN set "firewall.socat_reforged_udp$sfx.target=ACCEPT"
			for p in $UDP; do $UCI_BIN add_list "firewall.socat_reforged_udp$sfx.dest_port=$p"; done
		fi
		# multicast groups need IGMP accepted too, otherwise the join fails
		if [ "$FW_IGMP" = "1" ]; then
			$UCI_BIN set "firewall.socat_reforged_igmp$sfx=rule"
			$UCI_BIN set "firewall.socat_reforged_igmp$sfx.name=socat-reforged (igmp)"
			$UCI_BIN set "firewall.socat_reforged_igmp$sfx.src=$zone"
			$UCI_BIN set "firewall.socat_reforged_igmp$sfx.proto=igmp"
			$UCI_BIN set "firewall.socat_reforged_igmp$sfx.target=ACCEPT"
		fi
	done
	$UCI_BIN commit firewall

	if "$FW4_BIN" check >/dev/null 2>&1; then
		/etc/init.d/firewall reload >/dev/null 2>&1
		echo "ok $raw_sig" > "$FWSIG"
		log "firewall synced: zones[$WAN_ZONES] tcp[$TCP] udp[$UDP] igmp[$FW_IGMP]"
	else
		z=0
		while [ $z -lt "$FW_MAX_ZONES" ]; do
			z=$((z + 1))
			sfx=""
			[ "$z" -gt 1 ] && sfx="_$z"
			$UCI_BIN -q delete "firewall.socat_reforged_tcp$sfx"
			$UCI_BIN -q delete "firewall.socat_reforged_udp$sfx"
			$UCI_BIN -q delete "firewall.socat_reforged_igmp$sfx"
		done
		$UCI_BIN commit firewall
		echo "fail $raw_sig $now" > "$FWSIG"
		log "WARN: fw4 check failed, removed socat-reforged rules (retry in $((FW_RETRY / 60)) min)"
	fi
}

# ------------------------------------------------------------------ IPv6 ----

get_v6dev() {
	local line
	V6DEV=""
	line=$($IP_BIN -6 route show default 2>/dev/null | head -1)
	[ -n "$line" ] || return 0
	set -- $line
	while [ $# -ge 2 ]; do
		if [ "$1" = "dev" ]; then V6DEV="$2"; return 0; fi
		shift
	done
}

# Device that carries the default IPv4 route (falling back to IPv6) - this is
# what "WAN" means on the box, whatever it is called.
get_wandev() {
	local line
	WAN_DEV=""
	line=$($IP_BIN route show default 2>/dev/null | head -1)
	if [ -z "$line" ]; then
		line=$($IP_BIN -6 route show default 2>/dev/null | head -1)
	fi
	[ -n "$line" ] || return 0
	set -- $line
	while [ $# -ge 2 ]; do
		if [ "$1" = "dev" ]; then WAN_DEV="$2"; return 0; fi
		shift
	done
}

# Firewall zones covering the WAN device.  Refreshed every FW_EVERY cycles and
# cached in $RUNDIR/fw.zones; the result is part of the firewall signature, so
# a zone rename triggers a rebuild.
refresh_wan_zones() {
	local out
	[ -f "$ZONES_AWK" ] || return 1
	[ -n "$WAN_DEV" ] || return 1
	out=$( { $UCI_BIN show network 2>/dev/null; echo "%FIREWALL%"; $UCI_BIN show firewall 2>/dev/null; } \
		| "$AWK_BIN" -v dev="$WAN_DEV" -f "$ZONES_AWK" 2>/dev/null )
	printf '%s\n' "$out" | awk 'NF && !seen[$0]++' > "$RUNDIR/fw.zones"
	return 0
}

# Read the cached zone list into $WAN_ZONES ("wan" / "wan vpn" / ... ).
load_wan_zones() {
	local z
	WAN_ZONES=""
	[ -f "$RUNDIR/fw.zones" ] || return 0
	while read -r z; do
		[ -n "$z" ] || continue
		WAN_ZONES="$WAN_ZONES $z"
	done < "$RUNDIR/fw.zones"
	WAN_ZONES=${WAN_ZONES# }
}

# Preferred: the global address of the device holding the default v6 route.
# Fallback: the first global, non-link-local, non-ULA address anywhere.
get_ipv6() {
	local out line addr
	[ -n "$V6DEV" ] || get_v6dev
	IPV6=""
	if [ -n "$V6DEV" ]; then
		out=$($IP_BIN -o -6 addr show dev "$V6DEV" 2>/dev/null)
		while read -r line; do
			case "$line" in *" scope global "*) ;; *) continue ;; esac
			set -- $line
			addr=${4%%/*}
			case "$addr" in fd*|fc*|fe80*|"") continue ;; esac
			IPV6="$addr"
			return 0
		done <<EOF
$out
EOF
	fi
	out=$($IP_BIN -o -6 addr show 2>/dev/null)
	while read -r line; do
		case "$line" in *" scope global "*) ;; *) continue ;; esac
		set -- $line
		addr=${4%%/*}
		case "$addr" in fd*|fc*|fe80*|"") continue ;; esac
		IPV6="$addr"
		return 0
	done <<EOF
$out
EOF
	return 0
}

# Opt-in (socat.reforged.fix_v6_route=1): keep a 2000::/3 route pointing at the
# current default gateway.  Off by default: it is an ISP-specific workaround.
fix_ipv6_route() {
	[ "$(opt fix_v6_route 0)" = "1" ] || return 0
	local line gw dev
	line=$($IP_BIN -6 route show default 2>/dev/null | head -1)
	[ -n "$line" ] || return 0
	set -- $line
	gw=""
	dev=""
	while [ $# -ge 2 ]; do
		case "$1" in
			via) gw="$2" ;;
			dev) dev="$2" ;;
		esac
		shift
	done
	[ -n "$gw" ] && [ -n "$dev" ] || return 0
	if $IP_BIN -6 route show 2000::/3 2>/dev/null | grep -q "via $gw dev $dev"; then
		return 0
	fi
	if $IP_BIN -6 route replace 2000::/3 via "$gw" dev "$dev" metric 1024 2>/dev/null; then
		log_rate "v6route" 3600 "2000::/3 route updated -> via $gw dev $dev"
	fi
}

# Opt-in (socat.reforged.wg_dnat_guard=1): if the user really configured a
# 51820 DNAT rule, make sure it is present.  Never touches conntrack.
check_wg_dnat() {
	[ "$(opt wg_dnat_guard 0)" = "1" ] || return 0
	local line want=0 fwin zone
	fwin=$($UCI_BIN show firewall 2>/dev/null)
	while IFS= read -r line; do
		case "$line" in *dest_port*51820*) want=1; break ;; esac
	done <<EOF
$fwin
EOF
	[ "$want" = "1" ] || return 0
	# fw4 names the chain after the zone (dstnat_<zone>), so check the zones
	# we detected instead of assuming one called "wan"
	load_wan_zones
	for zone in $WAN_ZONES; do
		if $NFT_BIN list chain inet fw4 "dstnat_$zone" 2>/dev/null | grep -q '51820.*dnat'; then
			return 0
		fi
	done
	log_rate "wgdnat" 900 "WARN: configured WG 51820 DNAT rule is missing from nftables"
	if [ $((CYCLE % (FW_EVERY * 4))) -eq 0 ]; then
		"$FW4_BIN" reload 2>/dev/null
		log "reloaded fw4 to restore the WG DNAT rule"
	fi
}

# ------------------------------------------------------------ memory health ---

read_mem() { # -> $MEM_TOTAL_KB / $MEM_AVAIL_KB / $MEM_FREE_KB
	local k v
	MEM_TOTAL_KB=0
	MEM_AVAIL_KB=0
	MEM_FREE_KB=0
	while read -r k v _; do
		case "$k" in
			MemTotal:) MEM_TOTAL_KB=$v ;;
			MemAvailable:) MEM_AVAIL_KB=$v; break ;;
			MemFree:) MEM_FREE_KB=$v ;;
		esac
	done < /proc/meminfo
	is_uint "$MEM_TOTAL_KB" || MEM_TOTAL_KB=0
	is_uint "$MEM_AVAIL_KB" || MEM_AVAIL_KB=0
	is_uint "$MEM_FREE_KB" || MEM_FREE_KB=0
	[ "$MEM_AVAIL_KB" -gt 0 ] || MEM_AVAIL_KB=$MEM_FREE_KB
}

mem_pct() {
	read_mem
	[ "$MEM_TOTAL_KB" -gt 0 ] || { echo ""; return; }
	echo $((MEM_AVAIL_KB * 100 / MEM_TOTAL_KB))
}

check_health() {
	local pct
	pct=$(mem_pct)
	[ -n "$pct" ] || return 0

	if [ "$MEM_AVAIL_KB" -lt "$MEM_FLOOR_KB" ] || [ "$pct" -lt "$MEM_CRIT" ]; then
		MEM_FAILS=$((MEM_FAILS + 1))
		# two consecutive hits, and never more than once every 20 cycles
		if [ "$MEM_FAILS" -ge 2 ] && [ $((CYCLE - MEM_LAST_ACTION)) -ge 20 ]; then
			MEM_LAST_ACTION=$CYCLE
			MEM_FAILS=0
			log "CRIT: free memory ${pct}% (${MEM_AVAIL_KB}kB), restarting socat workers"
			kill_workers
			reconcile
		fi
		return 0
	fi
	MEM_FAILS=0

	if [ "$pct" -lt "$MEM_WARN" ]; then
		log_rate "memwarn" 3600 "WARN: free memory ${pct}% (${MEM_AVAIL_KB}kB)"
	fi
}

pet_watchdog() {
	# Intentionally empty: the hardware watchdog belongs to the system
	# (watchdogd), not to a port-forward manager.  Writing to /dev/watchdog
	# from here would fight the real watchdog daemon and could disarm it.
	return 0
}

# engine + worker heartbeat for the LuCI backend (zero forks).  The loop pid
# travels with it, so the backend never has to fork to find out whether the
# engine is alive.
heartbeat() {
	local up rest pid
	pid="$LOOP_PID"
	if [ -z "$pid" ]; then
		# a one-shot process: borrow the loop pid from the state header
		pid=""
		[ -f "$STATEF" ] && read -r _ pid _ < "$STATEF" 2>/dev/null
	fi
	up=""
	rest=""
	read -r up rest < /proc/uptime 2>/dev/null
	echo "${up%%.*} $WORKER_COUNT ${pid:-}" > "$HB" 2>/dev/null
}

# Why the loop stopped, for the next start to report.
note_exit() { # note_exit <reason>
	printf '%s %s %s\n' "$(uptime_s)" "$$" "$1" > "$RUNDIR/last-exit" 2>/dev/null
}

on_signal() { # on_signal <NAME>  (installed only in the main loop)
	note_exit "signal $1"
	log "engine: caught SIG$1, stopping"
	rm -f "$ALIVE_MARK" 2>/dev/null
	exit 0
}

# -------------------------------------------------------------- one-shots ---

init_once() {
	mkrun
	CYCLE=0
	read_version
	write_version_file
	get_ipv6
	get_wandev
	refresh_wan_zones
}

if [ "$1" = "reconcile" ]; then
	init_once
	reconcile
	sync_firewall
	heartbeat
	exit 0
fi

if [ "$1" = "restart-rule" ]; then
	_sec="$2"
	case "$_sec" in ''|*[!A-Za-z0-9_.-]*) log "restart-rule: bad section id '$2'"; exit 1 ;; esac
	init_once
	gen_desired || exit 1
	flush_warnings
	scan_workers
	listener_pids
	desired_keys
	_restarted=0
	while IFS="$TAB" read -r _pid _key _m; do
		[ "$_m" = "1" ] || continue          # only our own listeners
		[ -n "$_pid" ] || continue
		while IFS="$TAB" read -r _sid _kind _port _key2 _cmd; do
			[ "$_sid" = "$_sec" ] || continue
			if [ "$_key2" = "$_key" ]; then
				rm -f "$PIDDIR/$_sid-$_kind-$_port" "$ERRDIR/$_sid-$_kind-$_port.log" 2>/dev/null
				log "restart-rule $_sec: killed pid $_pid"
				kill "$_pid" 2>/dev/null
				_restarted=1
			fi
		done < "$DESF"
	done <<EOF
$LISTENERS
EOF
	[ "$_restarted" = "0" ] && log "restart-rule $_sec: nothing to restart"
	sleep 1
	reconcile
	heartbeat
	exit 0
fi

if [ "$1" = "status" ]; then
	init_once
	scan_workers
	listener_pids
	gen_desired
	flush_warnings
	echo "engine loop  : $($PGREP_BIN -f '/etc/socat-boot.sh$' | tr '\n' ' ')"
	echo "version       : $(version_line) (built $BUILT)"
	echo "uptime        : $(uptime_s)s"
	echo "socat workers : $WORKER_COUNT (listeners $LIST_COUNT)"
	echo "log file      : $LOGF ($(line_count "$LOGF") lines)"
	echo "wan ipv6      : ${IPV6:-none}"
	echo "desired file  : $DESF ($(line_count "$DESF") listeners)"
	echo "--- state file ---"
	[ -f "$STATEF" ] && cat "$STATEF"
	[ -s "$WARNF" ] && { echo "--- warnings ---"; cat "$WARNF"; }
	exit 0
fi

if [ "$1" = "cleanup" ]; then
	# stop path: drop our workers and all runtime state
	kill_workers
	rm -rf "$RUNDIR"
	rm -f "$HB"
	exit 0
fi

# ------------------------------------------------------------- main loop -----

acquire_loop_lock() {
	local lockdir="$RUNDIR/engine.lock" lp warned=0
	mkrun
	while true; do
		if mkdir "$lockdir" 2>/dev/null; then
			echo $$ > "$lockdir/pid"
			return 0
		fi
		lp=""
		[ -f "$lockdir/pid" ] && read -r lp < "$lockdir/pid" 2>/dev/null
		if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null \
		   && grep -q 'socat-boot.sh' "/proc/$lp/cmdline" 2>/dev/null; then
			[ "$warned" = 0 ] && { log "another engine loop (pid $lp) is active; idling this one"; warned=1; }
			sleep 30
			continue
		fi
		log "clearing stale engine lock (holder '$lp' gone)"
		rm -rf "$lockdir"
	done
}

acquire_loop_lock
mkrun
LOOP_PID=$$
read_version
write_version_file

# An engine that died without a clean stop left its marker behind: report it
# (together with the last recorded exit reason) so a silent crash is visible
# in logread instead of just being an unexplained "engine started".
if [ -f "$ALIVE_MARK" ]; then
	_prev=""
	read -r _prev < "$ALIVE_MARK" 2>/dev/null
	if [ -n "$_prev" ] && [ "$_prev" != "$$" ] && ! kill -0 "$_prev" 2>/dev/null; then
		_le="none"
		[ -f "$RUNDIR/last-exit" ] && _le=$(cat "$RUNDIR/last-exit" 2>/dev/null)
		log "engine: previous loop (pid $_prev) exited without cleanup; last-exit: ${_le:-none}"
	fi
fi
echo $$ > "$ALIVE_MARK" 2>/dev/null
trap 'on_signal TERM' TERM
trap 'on_signal INT'  INT
trap 'on_signal HUP'  HUP
trap 'on_signal QUIT' QUIT

log "engine started (pid $$, $(version_line), interval ${INTERVAL}s, socat=$SOCAT_BIN)"

while true; do
	CYCLE=$((CYCLE + 1))

	if [ $((CYCLE % V6_EVERY)) -eq 1 ] || [ -z "$IPV6" ]; then
		get_ipv6
	fi
	if [ $((CYCLE % V6_EVERY)) -eq 1 ] || [ -z "$WAN_DEV" ]; then
		get_wandev
	fi
	if [ $((CYCLE % V6_EVERY)) -eq 3 ]; then
		fix_ipv6_route
	fi
	if [ $((CYCLE % FW_EVERY)) -eq 3 ]; then
		check_wg_dnat
	fi
	# firewall zones are only re-detected when something may have changed
	if [ $((CYCLE % FW_EVERY)) -eq 2 ] || [ ! -f "$RUNDIR/fw.zones" ]; then
		refresh_wan_zones
	fi

	reconcile

	if [ $((CYCLE % MEM_EVERY)) -eq 0 ]; then
		check_health
	fi

	# Proof of life.  While nothing changes the engine is deliberately silent
	# (zero log lines in a steady state is the point), but a log that stays
	# empty for hours looks broken — so poll it at a human cadence.  15 min, not
	# 15s: per-minute HEALTH spam is exactly what buried the real warnings in
	# the (small) syslog ring buffer before.
	if [ $((CYCLE % ALIVE_EVERY)) -eq 0 ]; then
		log "alive: workers=$WORKER_COUNT listeners=$LIST_COUNT mem=$(mem_pct)% uptime=$(uptime_s)s"
	fi

	sync_firewall
	log_rotate
	heartbeat

	if debug_on && [ $((CYCLE % MEM_EVERY)) -eq 0 ]; then
		log "HEALTH: mem=$(mem_pct)% workers=$WORKER_COUNT listeners=$LIST_COUNT ipv6=${IPV6:-none} uptime=$(uptime_s)s"
	fi

	sleep "$INTERVAL"
done
