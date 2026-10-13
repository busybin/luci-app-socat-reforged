#!/bin/sh
# tests/host/lib.sh — tiny assertion helpers (POSIX sh, no bashisms)
#
# Every host test is a list of `check "description" "expected" "actual"`.
# The runner prints one line per check and exits non-zero if anything failed.

PASS=0
FAIL=0
CURRENT=""

begin() { CURRENT="$1"; printf '  %-46s ' "$1"; }
ok()    { PASS=$((PASS + 1)); printf 'ok\n'; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL\n    expected: %s\n    actual:   %s\n' "$1" "$2"; }

check() { # check <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		begin "$1"; ok
	else
		begin "$1"; bad "$2" "$3"
	fi
}

contains() { # contains <description> <needle> <haystack>
	case "$3" in
		*"$2"*) begin "$1"; ok ;;
		*)      begin "$1"; bad "…$2…" "$3" ;;
	esac
}

absent() { # absent <description> <needle> <haystack>
	case "$3" in
		*"$2"*) begin "$1"; bad "must not contain $2" "$3" ;;
		*)      begin "$1"; ok ;;
	esac
}

summary() {
	printf '\n%s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ] || exit 1
	exit 0
}
