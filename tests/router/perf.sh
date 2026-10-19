#!/bin/sh
# ============================================================================
# tests/router/perf.sh — runs ON the router
# ============================================================================
# Steady-state cost and stability of the engine loop: CPU ticks, whether the
# fast path is taken (no reconcile churn in the log), and how many forks a
# cycle costs.  The old engine used ~200 forks per 15s; this asserts we stay
# in the single digits.
set -u
R=/var/run/socat-reforged
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
WINDOW=${1:-120}

L=$(pgrep -f '^(/bin/)?sh /etc/socat-boot.sh$' | head -1)
[ -n "$L" ] || { echo "FAIL: engine loop not running"; exit 1; }

N0=$(logread 2>/dev/null | grep -c socat-boot)
T1=$(awk '{print $14+$15}' /proc/$L/stat)
sleep "$WINDOW"

T2=$(awk '{print $14+$15}' /proc/$L/stat)
N1=$(logread 2>/dev/null | grep -c socat-boot)

CPU_TICKS=$((T2 - T1))
CPU_MS=$(( CPU_TICKS * 1000 / HZ ))
PCT=$(awk -v t="$CPU_TICKS" -v w="$WINDOW" -v hz="$HZ" 'BEGIN{printf "%.1f", t*100/w/hz}')
NEWLOG=$((N1 - N0))
[ "$NEWLOG" -lt 0 ] && NEWLOG=0

echo "  window            : ${WINDOW}s"
echo "  cpu               : ${CPU_TICKS} ticks (${CPU_MS} ms) = ${PCT}% of one core"
echo "  engine log lines  : ${NEWLOG} new (0 = the fast path is doing its job)"
echo "  listeners         : $(awk 'NR>1 && $4!="-"' $R/state 2>/dev/null | wc -l)/$(awk 'NR>1' $R/state 2>/dev/null | wc -l)"
echo "  state file        : $(awk 'NR>1' $R/state 2>/dev/null | wc -l) listeners, $(wc -c < $R/state) bytes"
echo

fail=0
awk -v p="$PCT" 'BEGIN{exit !(p<=5)}'   || { echo "FAIL: engine uses more than 5% of a core"; fail=1; }
[ "$NEWLOG" -le 2 ] || { echo "FAIL: engine logged $NEWLOG lines in ${WINDOW}s (churn?)"; fail=1; }
[ "$(awk 'NR>1' $R/state 2>/dev/null | wc -l)" = "$(awk 'NR>1 && $4!="-"' $R/state 2>/dev/null | wc -l)" ] \
	|| { echo "FAIL: not all listeners are alive"; fail=1; }
[ "$fail" = 0 ] && echo "perf checks: ok" || echo "perf checks: FAILED"
exit "$fail"
