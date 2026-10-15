#!/bin/sh
# ============================================================================
# tests/host/engine-keys.sh — the engine must recognise every listener kind
# ============================================================================
# The engine finds its workers by scanning /proc for a socat process whose
# command line carries a *-LISTEN address, and it decides whether such a
# process is a live listener by looking for its port in the right /proc/net
# table.  Both steps are driven by small hard-coded lists inside
# socat-boot.sh, and a listener kind missing from either list is invisible to
# the engine: it is never stopped when its rule is deleted, never killed by
# Stop, and never counted.
#
# That is exactly what happened to OPENSSL-LISTEN, which no suite could see
# because only a TLS-capable socat can start one.  This suite derives the
# address types from the *generator* (the source of truth for what can be
# emitted) and asserts that the engine's two lists know all of them, so adding
# a new listener type without teaching the engine fails here immediately.
#
# Usage: sh tests/host/engine-keys.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
. "$HERE/lib.sh"

ENGINE=$REPO/root/etc/socat-boot.sh
GEN=$REPO/root/usr/libexec/socat-reforged-gen.awk
WORK=$HERE/.work-keys
rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------- helpers ---
# the listener address types the generator can emit, e.g. TCP-LISTEN
kinds=$(grep -o 'build_cmd("[A-Z0-9-]*:' "$GEN" | sed 's/.*"//; s/:$//' | sort -u | tr '\n' ' ')
kinds=${kinds% }

# the case block scan_workers uses to admit a process, as a runnable snippet
# whose "continue" means "not a listener" (it lives inside a loop in the
# engine, so outside one it has to become an exit)
sed -n '/case "\$cmd" in/,/esac/p' "$ENGINE" | sed 's/continue/exit 1/' > "$WORK/scan.sh"
# the classifiers the engine uses to turn a key into a port / a family, plus
# the one helper they call
sed -n '/^is_uint() {/,/^}/p'       "$ENGINE" > "$WORK/prelude.sh"
sed -n '/^key_kind() {/,/^}/p'      "$ENGINE" > "$WORK/kk.sh"
sed -n '/^key_port() {/,/^}/p'      "$ENGINE" > "$WORK/kp.sh"
sed -n '/^key_unix_path() {/,/^}/p' "$ENGINE" > "$WORK/kup.sh"

scan_admits() { # scan_admits <addr-type-key>
	( cmd="$1"; . "$WORK/scan.sh"; exit 0 ) 2>/dev/null
}
key_fam() { # key_fam <addr-type-key>  -> family or "none"
	( FAM=""; . "$WORK/prelude.sh"; . "$WORK/kk.sh"; if key_kind "$1"; then echo "$FAM"; else echo none; fi ) 2>/dev/null
}
key_port_of() { # key_port_of <addr-type-key>
	( KEY_PORT=""; . "$WORK/prelude.sh"; . "$WORK/kp.sh"; key_port "$1" && echo "$KEY_PORT" || echo none ) 2>/dev/null
}
key_path_of() { # key_path_of <addr-type-key>
	( KEY_PATH=""; . "$WORK/kup.sh"; key_unix_path "$1" && echo "$KEY_PATH" || echo none ) 2>/dev/null
}

echo "engine: $ENGINE"
echo "generator: $GEN"
echo "listener address types: $kinds"
echo

# ---------------------------------------------------------------- checks ----
# the invariant: at least the seven types that exist today, so this suite fails
# loudly if the generator is parsed wrong (and not silently passes on nothing)
n=$(printf '%s' "$kinds" | wc -w | tr -d ' ')
check 'the generator emits seven listener address types' 7 "$n"

# scan_workers must admit every one of them, or the engine never sees the
# worker at all
for k in $kinds; do
	if scan_admits "$k"; then admitted=yes; else admitted=no; fi
	check "scan_workers admits $k" yes "$admitted"
done

# ...and the second step must work too: a port for a network family, or a
# socket path for a unix listener.  The expected family is socat's, not the
# engine's: TCP/TCP6/UDP/UDP6 as the address type says, an OpenSSL listener is
# a TCP socket, and a datagram receiver is UDP.
for k in $kinds; do
	case "$k" in
	UNIX-LISTEN)
		check "key_unix_path reads $k" '/var/run/x.sock' "$(key_path_of 'UNIX-LISTEN:/var/run/x.sock,fork')"
		continue ;;
	TCP-LISTEN)     want=tcp ;;
	TCP6-LISTEN)    want=tcp6 ;;
	OPENSSL-LISTEN) want=tcp ;;
	UDP-LISTEN)     want=udp ;;
	UDP6-LISTEN)    want=udp6 ;;
	*RECVFROM)      want=udp ;;
	*)              want=UNKNOWN ;;
	esac
	key="$k:1234,fork"
	check "key_kind   maps $k" "$want" "$(key_fam "$key")"
	check "key_port   reads $k" 1234 "$(key_port_of "$key")"
done

# a worker that is not one of ours must still be ignored (the filter is not a
# blanket "every socat is ours")
if scan_admits 'OPENSSL-CONNECT'; then other=yes; else other=no; fi
check 'a non-listener socat is not admitted' no "$other"

rm -rf "$WORK"
summary 'engine listener-kind classifier'
