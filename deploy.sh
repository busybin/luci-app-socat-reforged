#!/bin/sh
# ============================================================================
# deploy.sh — install this tree on a router, with the real build id stamped
# ============================================================================
# The package (opkg/apk) gets its version from the Makefile; this path is for
# installing a working tree by hand.  It writes .build-stamp into the tarball
# so the LuCI page can show which commit is actually running.
#
# Usage: sh deploy.sh [ssh-host]      (default: router)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
HOST="${1:-router}"

BUILD=$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo devel)
echo "deploying $BUILD to $HOST"

tar czf - -C "$HERE" --exclude=.git --exclude=.github --exclude='*.tar.gz' . \
	| ssh "$HOST" "rm -rf /tmp/socat-app && mkdir -p /tmp/socat-app && tar xzf - -C /tmp/socat-app &&
		echo '$BUILD' > /tmp/socat-app/.build-stamp &&
		cd /tmp/socat-app && sh install.sh '$BUILD'" \
	| grep -E 'stamped|syntax|done|WARNING|removed|created' || true

echo
echo "--- what is running there now ---"
ssh "$HOST" '/etc/socat-boot.sh status | head -6'
