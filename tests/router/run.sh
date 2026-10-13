#!/bin/sh
# ============================================================================
# tests/router/run.sh — deploy + run all router-side checks
# ============================================================================
# Usage: sh tests/router/run.sh [ssh-host]      (default: router)
#
# 1. installs the current working tree on the router (tar | ssh, idempotent)
# 2. copies the checks over and runs them
# 3. leaves the router in the state the engine chooses (temp rules are removed)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
HOST="${1:-router}"

echo "router test suite -> $HOST"
echo

echo "== installing the working tree on $HOST =="
BUILD=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo devel)
tar czf - -C "$REPO" --exclude=.git --exclude=.github --exclude='*.tar.gz' . | \
	ssh "$HOST" "rm -rf /tmp/socat-test && mkdir -p /tmp/socat-test && tar xzf - -C /tmp/socat-test &&
		echo '$BUILD' > /tmp/socat-test/.build-stamp &&
		cd /tmp/socat-test && sh install.sh '$BUILD'" | tail -3
echo "  (installed build $BUILD)"
echo

echo "== copying the checks =="
for f in "$HERE"/engine-checks.sh "$HERE"/perf.sh "$HERE"/backend-checks.uc; do
	ssh "$HOST" "cat > /tmp/socat-test/$(basename "$f")" < "$f"
done
ssh "$HOST" 'chmod +x /tmp/socat-test/*.sh; echo ok'
# The ucode import is resolved when the script is loaded, so the module has to
# exist before the check starts.  Build it locally (no remote quoting games):
#   1d                       drop the shebang (ucode's loader rejects it)
#   return { -> global.BEOBJ = {   make the object importable
sed -e 1d -e 's/^return {/global.BEOBJ = {/' \
	"$REPO/root/usr/share/rpcd/ucode/luci.socat-reforged.uc" \
	| ssh "$HOST" 'cat > /tmp/backend-under-test.uc'
ssh "$HOST" 'wc -l < /tmp/backend-under-test.uc'
ssh "$HOST" 'ls -l /tmp/backend-under-test.uc | awk "{print \$5, \$9}"'
echo

rc=0
echo "== engine checks =="
ssh "$HOST" 'sh /tmp/socat-test/engine-checks.sh' || rc=1
echo
echo "== backend checks =="
ssh "$HOST" 'ucode /tmp/socat-test/backend-checks.uc' || rc=1
echo
echo "== perf checks (120s) =="
ssh "$HOST" 'sh /tmp/socat-test/perf.sh 120' || rc=1
echo
ssh "$HOST" 'rm -rf /tmp/socat-test'
[ "$rc" = 0 ] && echo "ROUTER SUITE: all green" || echo "ROUTER SUITE: FAILURES"
exit "$rc"
