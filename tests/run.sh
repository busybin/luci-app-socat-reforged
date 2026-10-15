#!/bin/sh
# ============================================================================
# tests/run.sh — entry point
# ============================================================================
#   sh tests/run.sh                  host-only checks (no router needed)
#   sh tests/run.sh --router [host]  also deploy + test on a router
#   sh tests/run.sh --sim|--matrix   only one of the "real socat" suites
#   sh tests/run.sh --gen|--zones|--fuzz|--keys   only one unit suite
#   sh tests/run.sh --pkg    only the packaging layout/bit checks
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
--matrix) exec sh "$HERE/host/matrix.sh" ;;
--fuzz)  exec sh "$HERE/host/fuzz.sh" ;;
--keys)  exec sh "$HERE/host/engine-keys.sh" ;;
--pkg)   exec sh "$HERE/host/package-layout.sh" ;;
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
	run "0/8  LuCI view smoke test" node "$HERE/host/view-smoke.js"
else
	echo "=== 0/8  LuCI view smoke test (skipped: no node) ==="
	echo
fi
run "1/8  generator unit tests" sh "$HERE/host/gen-cases.sh"
run "2/8  zone detection tests"  sh "$HERE/host/zones-cases.sh"
run "3/8  OpenWrt layout simulator" sh "$HERE/host/sim-router.sh"
run "4/8  generator command matrix" sh "$HERE/host/matrix.sh"
run "5/8  generator fuzz"              sh "$HERE/host/fuzz.sh"
run "6/8  engine listener-kind classifier" sh "$HERE/host/engine-keys.sh"
run "7/8  package layout & executable bits" sh "$HERE/host/package-layout.sh"
if [ "$fail" = 0 ]; then
	echo "HOST SUITE: all green  (add --router <host> to also test a router)"
else
	echo "HOST SUITE: FAILURES"
fi
exit "$fail"
