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
ck "engine loop is running" 1 "$(pgrep -f '/etc/socat-boot.sh$' | wc -l)"
ck "exactly one engine loop" 1 "$(pgrep -f '/etc/socat-boot.sh$' | wc -l)"
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
FIRST=$(alive "$D")
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

# ---------------------------------------------------------------- cleanup ---
for S in "$S" "$B" "$I" "$U" "$D"; do uci delete "socat.$S" >/dev/null 2>&1; done
uci commit socat
reconcile_now
ck "cleanup: listeners back to normal" "$(awk 'NR>1' "$R/state" | wc -l)" "$(awk 'NR>1 && $4!="-"' "$R/state" | wc -l)"
ck "cleanup: still only our workers" "$(workers_total)" "$(workers_marked)"
rm -f "$FOREIGN" 2>/dev/null

echo
echo "engine checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
