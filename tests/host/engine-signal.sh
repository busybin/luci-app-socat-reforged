#!/bin/sh
# The engine must stop on SIGTERM: a foreground sleep in the loop delayed the
# trap past procd's 5 s timeout, which SIGKILLed it (no shutdown reason, no
# cleanup).  Drives the shipped nap()/on_signal() with a real signal.
# Usage: sh tests/host/engine-signal.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

ENGINE=$REPO/root/etc/socat-boot.sh
INITD=$REPO/root/etc/init.d/socat-reforged
WORK=$HERE/.work-signal
rm -rf "$WORK"; mkdir -p "$WORK"

awk '/^on_signal\(\) \{/,/^\}/' "$ENGINE" > "$WORK/fn.sh"
awk '/^nap\(\) \{/,/^\}/'      "$ENGINE" >> "$WORK/fn.sh"
has 'the engine defines nap() (the interruptible sleep)' 'nap() {' "$(cat "$ENGINE")"
has 'nap() waits for a background sleep' 'wait "$NAP_PID"' "$(cat "$ENGINE")"
has 'the main loop naps instead of sleeping' 'nap "$INTERVAL"' "$(cat "$ENGINE")"
absent 'the main loop no longer uses a bare sleep' 'sleep "$INTERVAL"' "$(cat "$ENGINE")"
has 'the signal trap cancels the pending nap' 'kill "$NAP_PID"' "$(cat "$ENGINE")"
has 'the service gives the engine time to stop' 'procd_set_param term_timeout 20' "$(cat "$INITD")"

# the two functions plus stubs for what on_signal() touches on a router
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
