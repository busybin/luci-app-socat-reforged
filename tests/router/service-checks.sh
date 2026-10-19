#!/bin/sh
# ============================================================================
# tests/router/service-checks.sh — does procd have to SIGKILL the engine?
# ============================================================================
# On 2026-10-19 a restart logged
#
#   daemon.info procd: Instance socat-reforged::instance1 pid 18345 not stopped
#                      on SIGTERM, sending SIGKILL instead
#
# and the engine never wrote its "caught SIGTERM" line: `sleep 15` in the main
# loop is a foreground child and BusyBox ash only runs the trap when that child
# returns, which is longer than procd's 5 s term_timeout.  The engine now naps
# (background sleep + wait, see socat-boot.sh) and the service sets
# term_timeout 20.  This runs on the real platform -- on a host shell (dash) the
# trap fires during a plain sleep too, so the host suite cannot see this.
#
# Run on the router: sh service-checks.sh
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
# give procd time to notice a missing exit; the engine stops in well under a
# second when the trap runs, so 5 s is generous
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
