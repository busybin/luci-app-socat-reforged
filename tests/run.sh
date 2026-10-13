#!/bin/sh
# ============================================================================
# tests/run.sh — entry point
# ============================================================================
#   sh tests/run.sh                  host-only checks (no router needed)
#   sh tests/run.sh --router [host]  also deploy + test on a router
#   sh tests/run.sh --sim            only the layout simulator
#   sh tests/run.sh --gen|--zones    only one unit suite
set -u
HERE=$(cd "$(dirname "$0")" && pwd)

run() { # run <label> <command...>
	printf '=== %s ===\n' "$1"
	shift
	if "$@"; then :; else fail=1; fi
	echo
}

case "${1:-}" in
--view)  exec node "$HERE/host/view-smoke.js" ;;
--sim)   exec sh "$HERE/host/sim-router.sh" ;;
--gen)   exec sh "$HERE/host/gen-cases.sh" ;;
--zones) exec sh "$HERE/host/zones-cases.sh" ;;
--router)
	shift
	exec sh "$HERE/router/run.sh" "${1:-router}" ;;
-h|--help)
	sed -n '2,14p' "$0"
	exit 0 ;;
esac

fail=0
if command -v node >/dev/null 2>&1; then
	run "0/4  LuCI view smoke test" node "$HERE/host/view-smoke.js"
else
	echo "=== 0/4  LuCI view smoke test (skipped: no node) ==="
	echo
fi
run "1/4  generator unit tests" sh "$HERE/host/gen-cases.sh"
run "2/4  zone detection tests"  sh "$HERE/host/zones-cases.sh"
run "3/4  OpenWrt layout simulator" sh "$HERE/host/sim-router.sh"
if [ "$fail" = 0 ]; then
	echo "HOST SUITE: all green  (add --router <host> to also test a router)"
else
	echo "HOST SUITE: FAILURES"
fi
exit "$fail"
if [ "$fail" = 0 ]; then
	echo "HOST SUITE: all green  (add --router <host> to also test a router)"
else
	echo "HOST SUITE: FAILURES"
fi
exit "$fail"
