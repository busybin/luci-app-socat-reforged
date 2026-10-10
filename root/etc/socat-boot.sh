#!/bin/sh
LOG_TAG="socat-boot"

KEEPALIVE="keepalive,keepidle=60,keepintvl=10,keepcnt=5"
WDOG_DEV="/dev/watchdog"
MEM_WARN=20
MEM_CRIT=10

log() {
    logger -t "$LOG_TAG" "$1"
}

# Keep a dedicated WAN-accept rule in sync with rules that ask for it
# (firewall_accept=1). Only our own named rules are ever touched; the
# change is written to UCI (persists across fw4 reloads / reboot) and
# validated before reload. No-op on hosts without fw4.
sync_firewall() {
    [ -x /sbin/fw4 ] || return 0
    local TCP="" UDP="" sec en fa proto port p

    for sec in $(uci show socat 2>/dev/null | grep "=config$" | cut -d. -f2 | cut -d= -f1); do
        en=$(uci -q get socat.$sec.enable)
        [ "$en" = "1" ] || continue
        fa=$(uci -q get socat.$sec.firewall_accept)
        [ "$fa" = "1" ] || continue
        proto=$(uci -q get socat.$sec.proto)
        port=$(uci -q get socat.$sec.listen_port)
        case "$port" in ''|*[!0-9]*) continue;; esac
        case "$proto" in
            tcp) TCP="$TCP $port";;
            udp) UDP="$UDP $port";;
        esac
    done
    TCP=$(echo $TCP | tr ' ' '\n' | grep -v '^$' | sort -n -u | tr '\n' ' ')
    UDP=$(echo $UDP | tr ' ' '\n' | grep -v '^$' | sort -n -u | tr '\n' ' ')

    local NEW_SIG="tcp:$TCP udp:$UDP"
    local SIGFILE=/var/run/socat-reforged.fw.sig
    [ "$NEW_SIG" = "$(cat $SIGFILE 2>/dev/null)" ] && return 0

    # nothing to manage and nothing of ours exists -> nothing to do
    if [ -z "$TCP$UDP" ] && ! uci -q get firewall.socat_reforged_tcp >/dev/null 2>&1 \
                          && ! uci -q get firewall.socat_reforged_udp >/dev/null 2>&1; then
        echo "$NEW_SIG" > "$SIGFILE"
        return 0
    fi

    uci -q delete firewall.socat_reforged_tcp
    uci -q delete firewall.socat_reforged_udp
    if [ -n "$TCP" ]; then
        uci set firewall.socat_reforged_tcp=rule
        uci set firewall.socat_reforged_tcp.name='socat-reforged (tcp)'
        uci set firewall.socat_reforged_tcp.src='wan'
        uci set firewall.socat_reforged_tcp.proto='tcp'
        uci set firewall.socat_reforged_tcp.target='ACCEPT'
        for p in $TCP; do uci add_list firewall.socat_reforged_tcp.dest_port="$p"; done
    fi
    if [ -n "$UDP" ]; then
        uci set firewall.socat_reforged_udp=rule
        uci set firewall.socat_reforged_udp.name='socat-reforged (udp)'
        uci set firewall.socat_reforged_udp.src='wan'
        uci set firewall.socat_reforged_udp.proto='udp'
        uci set firewall.socat_reforged_udp.target='ACCEPT'
        for p in $UDP; do uci add_list firewall.socat_reforged_udp.dest_port="$p"; done
    fi
    uci commit firewall

    if /sbin/fw4 check >/dev/null 2>&1; then
        /etc/init.d/firewall reload >/dev/null 2>&1
        echo "$NEW_SIG" > "$SIGFILE"
        log "firewall synced: tcp[$TCP] udp[$UDP]"
    else
        log "WARN: fw4 check failed, removing socat-reforged rules"
        uci -q delete firewall.socat_reforged_tcp
        uci -q delete firewall.socat_reforged_udp
        uci commit firewall
    fi
}

# Echo the socat command line(s) a rule wants (one per line). reconcile()
# diffs these against the running processes so only changed rules restart.
emit_section() {
    local sec="$1" IPV6="$2"
    local enable proto family listen_port dest_proto dest_ip dest_port proxy proxy_server proxy_port reuseaddr DIAL RA
    enable=$(uci -q get socat.$sec.enable)
    [ "$enable" = "1" ] || return 0
    proto=$(uci -q get socat.$sec.proto)
    family=$(uci -q get socat.$sec.family)
    listen_port=$(uci -q get socat.$sec.listen_port)
    dest_proto=$(uci -q get socat.$sec.dest_proto)
    dest_ip=$(uci -q get socat.$sec.dest_ip)
    dest_port=$(uci -q get socat.$sec.dest_port)
    proxy=$(uci -q get socat.$sec.proxy)
    proxy_server=$(uci -q get socat.$sec.proxy_server)
    proxy_port=$(uci -q get socat.$sec.proxy_port)
    reuseaddr=$(uci -q get socat.$sec.reuseaddr)
    [ -z "$reuseaddr" ] && reuseaddr=1
    case "$proto" in tcp|udp) ;; *) log "WARN: [$sec] bad proto, skip"; return 0;; esac
    case "$listen_port" in ''|*[!0-9]*) log "WARN: [$sec] bad listen_port, skip"; return 0;; esac
    case "$dest_port" in ''|*[!0-9]*) log "WARN: [$sec] bad dest_port, skip"; return 0;; esac
    [ -n "$dest_ip" ] || { log "WARN: [$sec] empty dest_ip, skip"; return 0; }
    if [ -n "$proxy" ] && [ "$proxy" != "none" ]; then
        # reach the target through a SOCKS4a / HTTP CONNECT proxy (TCP only)
        case "$dest_proto" in
            tcp4) ;;
            *) log "WARN: [$sec] proxy only valid with tcp4 target, skip"; return 0 ;;
        esac
        [ -n "$proxy_server" ] || proxy_server=127.0.0.1
        [ -n "$proxy_port" ] || proxy_port=1080
        case "$proxy" in
            socks4|socks4a) DIAL="SOCKS4A:$proxy_server:$dest_ip:$dest_port,socksport=$proxy_port" ;;
            http|proxy)     DIAL="PROXY:$proxy_server:$dest_ip:$dest_port,proxyport=$proxy_port" ;;
            *) log "WARN: [$sec] unknown proxy '$proxy', skip"; return 0 ;;
        esac
    else
        case "$dest_proto" in
            tcp4) DIAL="TCP4:$dest_ip:$dest_port" ;;
            udp4) DIAL="UDP4:$dest_ip:$dest_port" ;;
            tcp6) DIAL="TCP6:[$dest_ip]:$dest_port" ;;
            udp6) DIAL="UDP6:[$dest_ip]:$dest_port" ;;
            *) log "WARN: [$sec] bad dest_proto, skip"; return 0 ;;
        esac
    fi
    RA=""
    [ "$reuseaddr" = "1" ] && RA=",reuseaddr"
    if [ "$proto" = "tcp" ]; then
        [ "$family" != "6" ] && echo "/usr/bin/socat TCP-LISTEN:$listen_port,fork$RA,$KEEPALIVE $DIAL,$KEEPALIVE"
        if [ "$family" != "4" ] && [ -n "$IPV6" ]; then
            echo "/usr/bin/socat TCP6-LISTEN:$listen_port,fork$RA,bind=$IPV6,ip-freebind=1,$KEEPALIVE $DIAL,$KEEPALIVE"
        fi
    else
        echo "/usr/bin/socat UDP-LISTEN:$listen_port,fork $DIAL"
    fi
}

# Diff the desired socat command lines against the running workers and
# only start/stop what actually changed. Serialized via a mkdir lock so the
# loop and an on-demand (config-change) run can't race.
reconcile() {
    local lockdir=/var/run/socat-reforged.lock i=0 lp
    while ! mkdir "$lockdir" 2>/dev/null; do
        i=$((i + 1))
        lp=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then
            log "reconcile: clearing stale lock (pid $lp gone)"
            rm -rf "$lockdir"
            continue
        fi
        if [ -z "$lp" ] && [ "$i" -ge 3 ]; then
            log "reconcile: clearing lock without pid"
            rm -rf "$lockdir"
            continue
        fi
        [ "$i" -ge 20 ] && { log "reconcile busy, skip"; return 0; }
        sleep 1
    done
    echo $$ > "$lockdir/pid"
    trap 'rm -rf "$lockdir"; rm -f /tmp/socat-desired /tmp/socat-running /tmp/socat-desired-u /tmp/socat-running-u' EXIT INT TERM

    local IPV6 sec p c
    local DES=/tmp/socat-desired RUN=/tmp/socat-running DESU=/tmp/socat-desired-u RUNU=/tmp/socat-running-u
    IPV6=$(get_ipv6)

    : > "$DES"
    for sec in $(uci show socat 2>/dev/null | grep "=config$" | cut -d. -f2 | cut -d= -f1); do
        emit_section "$sec" "$IPV6" >> "$DES"
    done

    : > "$RUN"
    for p in $(/usr/bin/pgrep socat 2>/dev/null); do
        c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | sed 's/[[:space:]]*$//')
        case "$c" in
            *LISTEN:*) echo "$c" >> "$RUN" ;;   # only touch our own listeners
        esac
    done

    sort -u "$DES" > "$DESU" 2>/dev/null
    sort -u "$RUN" > "$RUNU" 2>/dev/null

    local killed=0 spawned=0
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        grep -Fxq "$c" "$DESU" && continue
        for p in $(/usr/bin/pgrep socat 2>/dev/null); do
            [ "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | sed 's/[[:space:]]*$//')" = "$c" ] && kill "$p" 2>/dev/null
        done
        killed=$((killed + 1))
    done < "$RUNU"

    # give killed listeners a moment to release their ports before rebinding
    [ "$killed" -gt 0 ] && sleep 1

    while IFS= read -r c; do
        [ -n "$c" ] || continue
        grep -Fxq "$c" "$RUNU" && continue
        $c >/dev/null 2>&1 &
        spawned=$((spawned + 1))
    done < "$DESU"

    rm -f "$DES" "$RUN" "$DESU" "$RUNU"
    rm -rf "$lockdir"
    trap - EXIT INT TERM

    if [ "$killed" -gt 0 ] || [ "$spawned" -gt 0 ]; then
        log "reconcile: started=$spawned stopped=$killed (ipv6=$IPV6)"
    fi
    return 0
}

get_ipv6() {
    ip -6 addr show pppoe-wan 2>/dev/null | grep 'scope global' | awk '{print $2}' | cut -d'/' -f1 | head -1
}

fix_ipv6_route() {
    local GW CUR_GW
    if ! ip -6 route show 2000::/3 2>/dev/null | grep -q '2000::/3'; then
        GW=$(ip -6 route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
        if [ -n "$GW" ]; then
            ip -6 route add 2000::/3 via $GW dev pppoe-wan metric 1024 2>/dev/null
            log "Restored 2000::/3 route via $GW"
        fi
        return
    fi
    CUR_GW=$(ip -6 route show 2000::/3 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    GW=$(ip -6 route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    if [ -n "$GW" ] && [ -n "$CUR_GW" ] && [ "$GW" != "$CUR_GW" ]; then
        ip -6 route del 2000::/3 2>/dev/null
        ip -6 route add 2000::/3 via $GW dev pppoe-wan metric 1024 2>/dev/null
        log "2000::/3 route updated: $CUR_GW -> $GW"
    fi
}

check_wg_dnat() {
    if ! nft list chain inet fw4 dstnat_wan 2>/dev/null | grep -q '51820.*dnat'; then
        log "WG 51820 DNAT rule missing, reloading fw4"
        /sbin/fw4 reload 2>/dev/null
        echo f > /proc/net/nf_conntrack 2>/dev/null
        log "Conntrack flushed after fw4 reload"
    fi
}

check_mem() {
    local AVAILABLE TOTAL
    TOTAL=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    AVAILABLE=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
        echo ""
        return
    fi
    if [ -z "$AVAILABLE" ]; then
        AVAILABLE=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
    fi
    echo $((AVAILABLE * 100 / TOTAL))
}

check_health() {
    local MEM_PCT
    MEM_PCT=$(check_mem)

    if [ -n "$MEM_PCT" ] && [ "$MEM_PCT" -lt "$MEM_CRIT" ]; then
        log "CRIT: Free memory ${MEM_PCT}% < ${MEM_CRIT}%, restarting socat"
        killall -TERM socat 2>/dev/null
        sleep 1
        killall -KILL socat 2>/dev/null
        reconcile
        return
    fi

    if [ -n "$MEM_PCT" ] && [ "$MEM_PCT" -lt "$MEM_WARN" ]; then
        log "WARN: Free memory ${MEM_PCT}% < ${MEM_WARN}%"
    fi
}

pet_watchdog() {
    if [ -c "$WDOG_DEV" ]; then
        echo w > "$WDOG_DEV" 2>/dev/null || true
    fi
}

# Publish a tiny heartbeat (uptime seconds + socat worker count) so the LuCI
# backend can report engine health without spawning processes on every poll.
heartbeat() {
    echo "$(cut -d. -f1 /proc/uptime 2>/dev/null) $(/usr/bin/pgrep socat 2>/dev/null | wc -l)" \
        > /var/run/socat-reforged.hb 2>/dev/null
}

# One-shot entry point for the config-change trigger / ctl (fast, per-rule).
if [ "$1" = "reconcile" ]; then
    reconcile
    sync_firewall
    heartbeat
    exit 0
fi

# Restart exactly one rule (used by the LuCI "Restart rule" button): kill the
# worker(s) whose command line matches the section's desired listeners, then
# let reconcile respawn just those.
if [ "$1" = "restart-rule" ]; then
    _sec="$2"
    _des=/tmp/socat-rule-desired.$$
    emit_section "$_sec" "$(get_ipv6)" > "$_des" 2>/dev/null
    if [ -s "$_des" ]; then
        for p in $(/usr/bin/pgrep socat 2>/dev/null); do
            c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | sed 's/[[:space:]]*$//')
            case "$c" in *LISTEN:*) ;; *) continue;; esac
            grep -Fxq "$c" "$_des" && { kill "$p" 2>/dev/null; log "restart-rule $_sec: killed pid $p"; }
        done
        sleep 1
    else
        log "restart-rule $_sec: nothing to restart"
    fi
    rm -f "$_des"
    reconcile
    heartbeat
    exit 0
fi

# Singleton guard: only ONE engine loop may run. If a competing init (e.g. a
# socat build that ships /etc/init.d/socat running this same script) starts a
# second loop, it blocks here until the active loop exits — so two loops can
# never reconcile at once. The lock self-heals if the holder died uncleanly.
acquire_loop_lock() {
    local lockdir=/var/run/socat-reforged.engine.lock lp warned=0
    while true; do
        if mkdir "$lockdir" 2>/dev/null; then
            echo $$ > "$lockdir/pid"
            return 0
        fi
        lp=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null && grep -q 'socat-boot.sh' /proc/$lp/cmdline 2>/dev/null; then
            [ "$warned" = 0 ] && { log "another engine loop (pid $lp) is active; idling this one"; warned=1; }
            sleep 30
            continue
        fi
        log "clearing stale engine lock (holder '$lp' gone)"
        rm -rf "$lockdir"
    done
}
acquire_loop_lock

CHECK_COUNTER=0

while true; do
    CHECK_COUNTER=$((CHECK_COUNTER + 1))

    IPV6=$(get_ipv6)
    fix_ipv6_route

    if [ $((CHECK_COUNTER % 4)) -eq 0 ]; then
        check_wg_dnat
    fi

    if [ -z "$IPV6" ]; then
        log "WARN: No IPv6, retry in 30s"
        sleep 30
        continue
    fi

    # per-rule reconcile also handles IPv6-address changes (the v6 binds change)
    reconcile
    check_health
    pet_watchdog
    sync_firewall

    if [ $((CHECK_COUNTER % 4)) -eq 0 ]; then
        MEM_PCT=$(check_mem)
        SOCAT_NUM=$(/usr/bin/pgrep socat 2>/dev/null | wc -l)
        IPV6_SHORT=$(echo "$IPV6" | cut -d: -f1-4)
        UPTIME=$(cat /proc/uptime 2>/dev/null | awk '{print int($1/60)"m"}')
        log "HEALTH: mem=${MEM_PCT}% socat=$SOCAT_NUM ipv6=$IPV6_SHORT uptime=$UPTIME"
    fi

    heartbeat
    sleep 15
done
