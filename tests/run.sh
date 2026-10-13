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

case "${1:-}" in
--sim)
	exec sh "$HERE/host/sim-router.sh" ;;
--gen)
	exec sh "$HERE/host/gen-cases.sh" ;;
--zones)
	exec sh "$HERE/host/zones-cases.sh" ;;
--router)
	shift
	exec sh "$HERE/router/run.sh" "${1:-router}" ;;
-h|--help)
	sed -n '2,12p' "$0"
	exit 0 ;;
esac

fail=0
echo "=================== 1/3  generator unit tests ==================="
sh "$HERE/host/gen-cases.sh"    || fail=1
echo
echo "=================== 2/3  zone detection tests ==================="
sh "$HERE/host/zones-cases.sh"  || fail=1
echo
echo "=================== 3/3  OpenWrt layout simulator ==============="
SIM_SECS=${SIM_SECS:-9} sh "$HERE/host/sim-router.sh" || fail=1
echo
if [ "$fail" = 0 ]; then
	echo "HOST SUITE: all green  (add --router <host> to also test a router)"
else
	echo "HOST SUITE: FAILURES"
fi
exit "$fail"
