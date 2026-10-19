#!/bin/sh
# ============================================================================
# tests/host/engine-signal.sh — does the engine stop on SIGTERM, or does procd
# have to SIGKILL it?
# ============================================================================
# Observed on the 25.12 router while replacing the engine file:
#
#   daemon.info procd: Instance socat-reforged::instance1 pid 18345 not stopped
#                      on SIGTERM, sending SIGKILL instead
#
# and the engine log had no "caught SIGTERM" line: the trap never ran, so
# neither the reason for the exit nor the runtime cleanup happened.  The cause is
# the shape of the sleep in the main loop -- `sleep 15` is a foreground child and
# ash does not run a trap until that child returns, which is longer than procd's
# 5 s term_timeout.
#
# This suite takes `nap()` and `on_signal()` *out of the shipped engine* (not a
# copy) and drives them with a real signal, so a plain `sleep` in the loop makes
# it fail.
#
# Usage: sh tests/host/engine-signal.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

ENGINE=$REPO/root/etc/socat-boot.sh
INITD=$REPO/root/etc/init.d/socat-reforged
WORK=$HERE/.work-signal
rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------- the shipped bits --
awk '/^on_signal\(\) \{/,/^\}/' "$ENGINE" > "$WORK/fn.sh"
awk '/^nap\(\) \{/,/^\}/'      "$ENGINE" >> "$WORK/fn.sh"
has 'the engine defines nap() (the interruptible sleep)' 'nap() {' "$(cat "$ENGINE")"
has 'nap() waits for a background sleep' 'wait "$NAP_PID"' "$(cat "$ENGINE")"
has 'the main loop naps instead of sleeping' 'nap "$INTERVAL"' "$(cat "$ENGINE")"
absent 'the main loop no longer uses a bare sleep' 'sleep "$INTERVAL"' "$(cat "$ENGINE")"
has 'the signal trap cancels the pending nap' 'kill "$NAP_PID"' "$(cat "$ENGINE")"
has 'the service gives the engine time to stop' 'procd_set_param term_timeout 20' "$(cat "$INITD")"

# -------------------------------------------------------- one real signal -----
# Stubs for what on_signal() would touch on a router, then the two functions
# themselves, then a nap long enough to be unmistakable.
{
	echo 'note_exit() { printf "%s\n" "$1" > "'"$WORK"'/exit-reason"; }'
	echo 'log() { :; }'
	echo 'ALIVE_MARK=/dev/null'
	cat "$WORK/fn.sh"
	echo 'trap "on_signal TERM" TERM'
	echo 'echo alive > "'"$WORK"'/started"'
	echo 'nap 15'
	echo 'echo "nap finished without a signal"'
} > "$WORK/loop.sh"
sh -n "$WORK/loop.sh" && rc=0 || rc=1
check 'the extracted loop is valid shell' 0 "$rc"

sh "$WORK/loop.sh" &
lpid=$!
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	[ -f "$WORK/started" ] && break
	sleep 0.1
done
start=$(date +%s)
kill -TERM "$lpid" 2>/dev/null
waited=0
while kill -0 "$lpid" 2>/dev/null; do
	sleep 0.1
	waited=$((waited + 1))
	[ "$waited" -gt 100 ] && break
done
took=$(( $(date +%s) - start ))
if [ "$waited" -gt 100 ]; then
	kill -9 "$lpid" 2>/dev/null
	begin 'the engine stops on SIGTERM at once'
	bad 'exit within 10s' 'still running'
else
	wait "$lpid" 2>/dev/null
	begin 'the engine stops on SIGTERM at once'
	if [ "$took" -le 2 ]; then ok; else bad 'exit within 2s' "${took}s"; fi
fi

begin 'the trap ran (the reason is recorded)'
if [ "$(cat "$WORK/exit-reason" 2>/dev/null)" = 'signal TERM' ]; then ok; else bad 'signal TERM' "$(cat "$WORK/exit-reason" 2>/dev/null)"; fi

rm -rf "$WORK"
summary 'engine signal handling'
