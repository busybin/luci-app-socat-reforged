#!/bin/sh
# ============================================================================
# tests/router/engine-checks.sh — runs ON the router
# ============================================================================
# Exercises the deployed engine end to end and puts everything back:
#   * desired-state behaviour (a rule is added, changed, disabled, removed)
#   * a deliberately broken rule (port out of range, injection attempt)
#   * a rule that cannot bind (conflict) -> must report the reason
#   * per-rule restart, bad section ids, engine status
#   * only our own workers are ever touched (a foreign socat must survive)
#
# Usage (on the router): sh engine-checks.sh
set -u
E=/etc/socat-boot.sh
R=/var/run/socat-reforged
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  %-44s ok\n' "$1"
       else FAIL=$((FAIL+1)); printf '  %-44s FAIL\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) PASS=$((PASS+1)); printf '  %-44s ok\n' "$1" ;;
        *) FAIL=$((FAIL+1)); printf '  %-44s FAIL (missing %s)\n' "$1" "$2" ;; esac; }

SID_BASE="t$(date +%s)"
sid() { echo "${SID_BASE}$1"; }

# Remove every section this run may have created, even on an early failure, so
# a broken test run can never leave junk in the live /etc/config/socat.
cleanup_test_sections() {
	for S in "$(sid conflict)" "$(sid badport)" "$(sid inject)" "$(sid udpv6)" "$(sid disable)" "$(sid orphan)" \
	         "$(sid unix)" "$(sid mcast)" "$(sid tls)"; do
		uci -q delete "socat.$S" 2>/dev/null
	done
	uci commit socat 2>/dev/null
}
trap cleanup_test_sections EXIT

alive() { awk -v s="$1" 'NR>1 && $1==s && $4!="-"{n++} END{print n+0}' "$R/state"; }
total() { awk -v s="$1" 'NR>1 && $1==s{n++} END{print n+0}' "$R/state"; }
err()   { awk -v s="$1" 'NR>1 && $1==s && $5!="-"{ for (i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""; exit }' "$R/state"; }

# The engine loop also reconciles every 15s and holds a lock while doing so, so
# a one-shot reconcile can be told "busy, skip".  Wait for the state file to
# catch up instead of assuming it happened instantly.
wait_alive() { # wait_alive <sid> <want> [seconds]
	local i=0 n="${3:-20}"
	while [ "$i" -lt "$n" ]; do
		[ "$(alive "$1")" = "$2" ] && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}
wait_gone() { # wait_gone <sid> [seconds]  (no live listener, no state rows)
	local i=0 n="${2:-20}"
	while [ "$i" -lt "$n" ]; do
		[ "$(alive "$1")" = "0" ] && [ "$(total "$1")" = "0" ] && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}
reconcile_now() { # reconcile_now — retry past lock contention
	local i=0
	while [ "$i" -lt 5 ]; do
		sh "$E" reconcile >/dev/null 2>&1
		sleep 1
		i=$((i + 1))
	done
}
workers_total() { pgrep socat | wc -l; }
workers_marked() {
	n=0
	for p in $(pgrep socat); do
		read -r e < "/proc/$p/environ" 2>/dev/null
		case "$e" in *SOCAT_REFORGED=1*) n=$((n+1)) ;; esac
	done
	echo "$n"
}

echo "engine checks ($(date))"
echo "  state dir: $R, listeners: $(awk 'NR>1' $R/state | wc -l)"
echo

# ---------------------------------------------------------------- sanity ----
ck "engine loop is running" 1 "$(pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' | wc -l)"
ck "exactly one engine loop" 1 "$(pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' | wc -l)"
ck "state file has a header" 1 "$(grep -c '^engine ' "$R/state")"
ck "all desired listeners alive" "$(awk 'NR>1' "$R/state" | wc -l)" "$(awk 'NR>1 && $4!="-"' "$R/state" | wc -l)"
ck "every socat worker is ours" "$(workers_total)" "$(workers_marked)"

# ------------------------------------------------- a rule that cannot bind ---
S=$(sid conflict)
uci set "socat.$S=config" >/dev/null
uci set "socat.$S.enable=1" >/dev/null
uci set "socat.$S.proto=tcp" >/dev/null
BUSYPORT=$(awk 'NR==2 && $3!=""{print $3; exit}' "$R/state")
uci set "socat.$S.listen_port=$BUSYPORT" >/dev/null
uci set "socat.$S.dest_proto=tcp4" >/dev/null
uci set "socat.$S.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$S.dest_port=80" >/dev/null
uci set "socat.$S.firewall_accept=0" >/dev/null
uci commit socat
reconcile_now
wait_alive "$S" 0
# one engine cycle to fail the bind, another to publish the reason
reconcile_now
wait_alive "$S" 0
ck "conflicting rule: nothing alive" 0 "$(alive "$S")"
has "conflicting rule: bind error reported" "Address in use" "$(err "$S")"

# ------------------------------------------------------- bad values refused ---
B=$(sid badport)
uci set "socat.$B=config" >/dev/null
uci set "socat.$B.enable=1" >/dev/null
uci set "socat.$B.proto=tcp" >/dev/null
uci set "socat.$B.listen_port=99999" >/dev/null
uci set "socat.$B.dest_proto=tcp4" >/dev/null
uci set "socat.$B.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$B.dest_port=80" >/dev/null
uci commit socat
reconcile_now
wait_gone "$B"
ck "port 99999 is refused" 0 "$(total "$B")"

I=$(sid inject)
uci set "socat.$I=config" >/dev/null
uci set "socat.$I.enable=1" >/dev/null
uci set "socat.$I.proto=tcp" >/dev/null
uci set "socat.$I.listen_port=21099" >/dev/null
uci set "socat.$I.dest_proto=tcp4" >/dev/null
uci set "socat.$I.dest_ip=1.2.3.4;reboot" >/dev/null
uci set "socat.$I.dest_port=80" >/dev/null
uci commit socat
reconcile_now
wait_gone "$I"
ck "metacharacter target is refused" 0 "$(total "$I")"
WARNLINE=$(logread 2>/dev/null | grep "\[$I\]" | head -1)
has "its warning reaches the log" "bad dest_ip" "$WARNLINE"

# --------------------------------------------------------- udp family=6  ----
U=$(sid udpv6)
uci set "socat.$U=config" >/dev/null
uci set "socat.$U.enable=1" >/dev/null
uci set "socat.$U.proto=udp" >/dev/null
uci set "socat.$U.listen_port=21098" >/dev/null
uci set "socat.$U.dest_proto=udp4" >/dev/null
uci set "socat.$U.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$U.dest_port=53" >/dev/null
uci set "socat.$U.family=6" >/dev/null
uci set "socat.$U.firewall_accept=0" >/dev/null
uci commit socat
reconcile_now
if [ -n "$(ip -6 addr show 2>/dev/null | grep 'scope global')" ]; then
	wait_alive "$U" 1
	ck "udp family=6 -> exactly one v6 listener" 1 "$(alive "$U")"
else
	wait_alive "$U" 0
	ck "udp family=6 without IPv6 -> documented, none" 0 "$(alive "$U")"
fi

# ------------------------------------------------------------ disable/enable -
D=$(sid disable)
uci set "socat.$D=config" >/dev/null
uci set "socat.$D.enable=1" >/dev/null
uci set "socat.$D.proto=tcp" >/dev/null
uci set "socat.$D.listen_port=21097" >/dev/null
uci set "socat.$D.dest_proto=tcp4" >/dev/null
uci set "socat.$D.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$D.dest_port=80" >/dev/null
uci set "socat.$D.firewall_accept=0" >/dev/null
uci commit socat
reconcile_now
wait_alive "$D" 1
uci set "socat.$D.enable=0" >/dev/null
uci commit socat
reconcile_now
wait_alive "$D" 0
ck "disabling stops the listener" 0 "$(alive "$D")"
uci delete "socat.$D" >/dev/null
uci commit socat
reconcile_now
wait_gone "$D"
ck "removing the rule leaves nothing" 0 "$(total "$D")"

# ---------------------------------------------- orphaned ,fork child ---
# socat `,fork` leaves a per-connection child with the *same* argv; when the
# listener dies first that child is reparented to init.  It must not be
# mistaken for a healthy listener (that would leave the rule dead forever).
O=$(sid orphan)
OPORT=21094
OTGT=21093
# clear anything a previous, possibly aborted run left behind (no pkill on busybox)
for p in $(pgrep -f "TCP-LISTEN:$OPORT") $(pgrep -f "TCP-LISTEN:$OTGT"); do kill "$p" 2>/dev/null; done
sleep 1
socat "TCP-LISTEN:$OTGT,fork,reuseaddr" EXEC:'sleep 60' >/dev/null 2>&1 & TP=$!
uci set "socat.$O=config" >/dev/null
uci set "socat.$O.enable=1" >/dev/null
uci set "socat.$O.proto=tcp" >/dev/null
uci set "socat.$O.listen_port=$OPORT" >/dev/null
uci set "socat.$O.dest_proto=tcp4" >/dev/null
uci set "socat.$O.dest_ip=127.0.0.1" >/dev/null
uci set "socat.$O.dest_port=$OTGT" >/dev/null
uci set "socat.$O.firewall_accept=0" >/dev/null
uci commit socat
reconcile_now
wait_alive "$O" 2 || echo "    (orphan setup: rule did not come up; state: [$(err "$O")])"
# open a connection so the listener forks a per-connection child
socat - "TCP4:127.0.0.1:$OPORT" < /dev/zero >/dev/null 2>&1 & CP=$!
sleep 2
LP=$(awk -v s="$O" 'NR>1 && $1==s && $4!="-" {print $4; exit}' "$R/state")
CH=$(pgrep -P "$LP" 2>/dev/null | head -1)
ck "orphan: listener forked a child" 1 "$([ -n "$CH" ] && echo 1 || echo 0)"
kill "$LP" 2>/dev/null
sleep 1
ck "orphan: child outlives its listener" 1 "$([ -n "$CH" ] && kill -0 "$CH" 2>/dev/null && echo 1 || echo 0)"
reconcile_now
wait_alive "$O" 2
NP=$(awk -v s="$O" 'NR>1 && $1==s && $2=="tcp" && $4!="-" {print $4; exit}' "$R/state")
ck "orphan: engine restarts the real listener" 1 \
	"$([ -n "$NP" ] && [ "$NP" != "$LP" ] && [ "$NP" != "$CH" ] && echo 1 || echo 0)"
kill "$CP" "$TP" 2>/dev/null
for p in $(pgrep -f "TCP-LISTEN:$OPORT") $(pgrep -f "TCP-LISTEN:$OTGT"); do kill "$p" 2>/dev/null; done
uci delete "socat.$O" >/dev/null 2>&1
uci commit socat
reconcile_now

# ------------------------------------------------------------- restart-rule --
S2=$(awk 'NR==2 && $4!="-"{print $1; exit}' "$R/state")
P1=$(awk -v s="$S2" 'NR>1 && $1==s && $4!="-"{print $4; exit}' "$R/state")
sh "$E" restart-rule "$S2" >/dev/null 2>&1
reconcile_now
P2=$(awk -v s="$S2" 'NR>1 && $1==s && $4!="-"{print $4; exit}' "$R/state")
if [ "$P1" != "$P2" ] && [ -n "$P2" ]; then
	PASS=$((PASS+1)); printf '  %-44s ok\n' "restart-rule recycles only that rule"
else
	FAIL=$((FAIL+1)); printf '  %-44s FAIL (%s -> %s)\n' "restart-rule" "$P1" "$P2"
fi

sh "$E" restart-rule 'bad;id' >/dev/null 2>&1
ck "restart-rule rejects a bad sid" 1 $([ $? -ne 0 ] && echo 1 || echo 0)

# ------------------------------------------------------- a foreign socat  ----
FOREIGN=$(mktemp -u)
socat "TCP-LISTEN:21096,fork" "TCP4:192.0.2.1:80" >/dev/null 2>&1 &
FP=$!
sleep 1
sh "$E" reconcile >/dev/null 2>&1
sleep 1
if kill -0 "$FP" 2>/dev/null; then
	PASS=$((PASS+1)); printf '  %-44s ok\n' "a foreign socat is never touched"
else
	FAIL=$((FAIL+1)); printf '  %-44s FAIL (killed it!)\n' "a foreign socat is never touched"
fi
kill "$FP" 2>/dev/null


# --------------------------------------------------------- the new kinds -----
# A unix socket and a UDP4-RECVFROM socket never show up in /proc/net/tcp, and
# /proc/net/tcp is what the engine reads its listener table from.  These are
# therefore the kinds that used to be invisible to the engine: it killed and
# respawned them every cycle and never stopped them, so the rule never came
# up.  Both must now come up with a real pid.
UX=$(sid unix); UXP=/tmp/socat-reforged-test.sock
rm -f "$UXP"
uci set "socat.$UX=config" >/dev/null
uci set "socat.$UX.enable=1" >/dev/null
uci set "socat.$UX.proto=unix" >/dev/null
uci set "socat.$UX.unix_path=$UXP" >/dev/null
uci set "socat.$UX.dest_proto=tcp4" >/dev/null
uci set "socat.$UX.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$UX.dest_port=80" >/dev/null
uci set "socat.$UX.firewall_accept=0" >/dev/null
uci commit socat
reconcile_now
wait_alive "$UX" 1 20
ck "unix listener comes up" 1 "$(alive "$UX")"
ck "unix listener leaves a socket file" 1 "$([ -S "$UXP" ] && echo 1 || echo 0)"
ck "unix socket is in /proc/net/unix" 1 "$(grep -c "$UXP" /proc/net/unix)"
# a stale socket file (a listener killed hard) must not block the rebind
UXP1=$(awk -v s="$UX" 'NR>1 && $1==s && $4!="-" {print $4; exit}' "$R/state")
[ -n "$UXP1" ] && kill -9 "$UXP1" 2>/dev/null
sleep 1
ck "stale socket file survives a hard kill" 1 "$([ -S "$UXP" ] && echo 1 || echo 0)"
reconcile_now
wait_alive "$UX" 1 20
UXP2=$(awk -v s="$UX" 'NR>1 && $1==s && $4!="-" {print $4; exit}' "$R/state")
ck "unix listener rebinds over a stale file" 1 \
	"$([ -n "$UXP2" ] && [ "$UXP2" != "$UXP1" ] && echo 1 || echo 0)"

MC=$(sid mcast)
MCPORT=21060
uci set "socat.$MC=config" >/dev/null
uci set "socat.$MC.enable=1" >/dev/null
uci set "socat.$MC.proto=udp" >/dev/null
uci set "socat.$MC.listen_port=$MCPORT" >/dev/null
uci set "socat.$MC.mcast_group=239.10.10.10" >/dev/null
uci set "socat.$MC.dest_proto=tcp4" >/dev/null
uci set "socat.$MC.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$MC.dest_port=80" >/dev/null
uci set "socat.$MC.firewall_accept=1" >/dev/null
uci commit socat
reconcile_now
wait_alive "$MC" 1 20
ck "multicast listener comes up" 1 "$(alive "$MC")"
# one igmp rule per WAN zone, and each rule is described by several uci lines,
# so count rules (=rule) and not lines that mention the name
ck "multicast opened an igmp accept rule" 1 "$(uci -q show firewall | grep -c "socat_reforged_igmp.*=rule")"
ck "that rule is proto igmp" 1 "$(uci -q show firewall | grep -c "socat_reforged_igmp.proto='igmp'")"
# (uci show prints values quoted, hence the .* around the pattern)
ck "a udp accept rule is opened for its port" 1 "$(uci -q show firewall | grep -c "dest_port.*'$MCPORT'")"
uci -q delete "socat.$MC" >/dev/null
uci commit socat
reconcile_now
ck "the igmp rule goes with the rule" 0 "$(uci -q show firewall | grep -c 'socat_reforged_igmp')"

# TLS: OpenWrt's socat package is built --disable-openssl, so on this router a
# TLS rule cannot start.  It must then be reported DOWN, with socat's own
# reason, rather than silently pretending to listen.
TL=$(sid tls)
uci set "socat.$TL=config" >/dev/null
uci set "socat.$TL.enable=1" >/dev/null
uci set "socat.$TL.proto=ssl" >/dev/null
uci set "socat.$TL.listen_port=34991" >/dev/null
uci set "socat.$TL.ssl_cert=/etc/luci-cert.pem" >/dev/null
uci set "socat.$TL.ssl_key=/etc/luci-key.pem" >/dev/null
uci set "socat.$TL.dest_proto=tcp4" >/dev/null
uci set "socat.$TL.dest_ip=192.0.2.1" >/dev/null
uci set "socat.$TL.dest_port=80" >/dev/null
uci set "socat.$TL.firewall_accept=0" >/dev/null
uci commit socat
reconcile_now
TL_HAS_SSL=0
if socat -V 2>&1 | grep -q '#define WITH_OPENSSL'; then
	TL_HAS_SSL=1
	sleep 2
	if [ "$(alive "$TL")" -ge 1 ]; then
		PASS=$((PASS+1)); printf '  %-44s ok\n' "tls listener comes up"
	else
		FAIL=$((FAIL+1)); printf '  %-44s FAIL (state: [%s])\n' "tls listener" "$(err "$TL")"
	fi
else
	# socat without OpenSSL: the rule cannot start, and it must say so.  A down
	# rule keeps its row in the state file (pid "-" plus the error), so wait for
	# "nothing alive and a reason present" rather than for the rows to vanish.
	i=0
	while [ "$i" -lt 20 ]; do
		[ "$(alive "$TL")" = "0" ] && [ -n "$(err "$TL")" ] && break
		sleep 1; i=$((i + 1))
	done
	ck "tls rule without ssl socat is down" 0 "$(alive "$TL")"
	has "tls rule states socat's own reason" 'OPENSSL-LISTEN' "$(err "$TL")"
fi
uci -q delete "socat.$TL" >/dev/null
uci commit socat
reconcile_now
# a TLS worker must be recognised like any other, or deleting its rule leaves
# the listener running for good (the OpenSSL-LISTEN kind was in neither of the
# engine's two kind lists, which no non-TLS router can show)
if [ "$TL_HAS_SSL" = 1 ]; then
	ck "the deleted tls listener is gone" 0 "$(alive "$TL")"
fi
rm -f "$UXP"
# ---------------------------------------------------------------- cleanup ---
for S in "$S" "$B" "$I" "$U" "$D" "$O" "$UX" "$MC" "$TL"; do uci delete "socat.$S" >/dev/null 2>&1; done
uci commit socat
reconcile_now
ck "cleanup: listeners back to normal" "$(awk 'NR>1' "$R/state" | wc -l)" "$(awk 'NR>1 && $4!="-"' "$R/state" | wc -l)"
ck "cleanup: still only our workers" "$(workers_total)" "$(workers_marked)"
rm -f "$FOREIGN" 2>/dev/null

# ------------------------------------------------------------- engine log ---
# syslog's ring buffer is small and wiped on reboot, so every line also goes to
# a size-capped file the UI can show.  A rotation may cut one line in half (it
# keeps the newest *bytes*), so only "has timestamped lines" is asserted.
L=/var/log/socat-reforged.log
LT=$(wc -l < "$L" 2>/dev/null | tr -d ' ')
LS=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$L" 2>/dev/null)
LR=$(grep -c 'reconcile:' "$L" 2>/dev/null)
ck "engine log: file exists" 1 "$([ -s "$L" ] && echo 1 || echo 0)"
ck "engine log: reconcile activity logged" 1 "$([ "${LR:-0}" -ge 1 ] && echo 1 || echo 0)"
ck "engine log: lines are timestamped" 1 "$([ "${LS:-0}" -ge 1 ] && echo 1 || echo 0)"
ck "engine log: capped at 64 KiB" 1 "$([ "$(wc -c < "$L" 2>/dev/null | tr -d ' ')" -le 65536 ] && echo 1 || echo 0)"
echo "  (engine log: $LT lines, $LS timestamped, $LR reconcile lines, $(wc -c < "$L" 2>/dev/null | tr -d ' ') bytes)"

echo
echo "engine checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
