#!/bin/sh
# The engine must stop on SIGTERM: a foreground sleep in the loop delayed the
# trap past procd's 5 s timeout, which SIGKILLed it.  Runs on the router, where
# ash really delays the trap (a host shell does not).
set -u
PASS=0
FAIL=0
ck() { # ck <description> <expected> <actual>
	if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  %-46s ok\n' "$1"
	else FAIL=$((FAIL + 1)); printf '  %-46s FAIL\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; fi
}

kills0=$(logread 2>/dev/null | grep -c 'not stopped on SIGTERM')
caught0=$(grep -c 'caught SIGTERM, stopping' /var/log/socat-reforged.log 2>/dev/null)

/etc/init.d/socat-reforged restart >/dev/null 2>&1
sleep 5

kills1=$(logread 2>/dev/null | grep -c 'not stopped on SIGTERM')
caught1=$(grep -c 'caught SIGTERM, stopping' /var/log/socat-reforged.log 2>/dev/null)
run=$(ubus call service list '{"name":"socat-reforged"}' 2>/dev/null | grep -c '"running": true')

ck 'procd did not have to SIGKILL the engine' "$kills0" "$kills1"
ck 'the engine logged its SIGTERM (the trap ran)' "$((caught0 + 1))" "$caught1"
ck 'the engine is back up after the restart' 1 "$run"

listeners=$(ubus call luci.socat-reforged status 2>/dev/null | sed -n 's/.*"listeners": \([0-9]*\).*/\1/p' | head -1)
workers=$(ubus call luci.socat-reforged status 2>/dev/null | sed -n 's/.*"workers": \([0-9]*\).*/\1/p' | head -1)
[ -n "$listeners" ] && [ "$listeners" = "$workers" ] && r=yes || r=no
ck 'every enabled rule is listening again' yes "$r"

printf '\nservice checks: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
