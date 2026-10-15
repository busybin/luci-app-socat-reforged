# Changelog

`V<integer>` releases (see Releases). `main` carries unreleased work on top of
the last tag; version numbers only change when a release is requested.

## Unreleased

### Feature parity with the other luci-app-socat forks (2026-10-14)

Compared every live fork on GitHub (chenmozhijin, WROIATE, mylucien, 4IceG,
hongyan3, 1522042029) and took what they had and we did not:

* **TLS / OpenSSL** (from mylucien): `proto=ssl` listens with
  `OPENSSL-LISTEN` + `ssl_cert`/`ssl_key`; `dest_proto=ssl` dials with
  `OPENSSL` + optional `ssl_verify`/`ssl_cafile`. Paths validated strictly.
* **Unix sockets** (from mylucien): `unix_path` on the listen side,
  `dst_unix_path` on the dial side; no port, no firewall involvement.
* **Multicast / IPTV** (from mylucien): `mcast_group` joins a group on the
  listen port (`ip-add-membership`, `bind=<group>` so two rules cannot mix
  streams, `so-bindtodevice` for the interface), `dest_proto=mcast` relays to
  another group with `ip-multicast-if`/`-ttl`/`-loop`, or to a plain unicast
  target. IGMP is accepted on the WAN zones while a multicast rule is on.
* **Socket options** (from mylucien/WROIATE): `nodelay`, `backlog`,
  `max_children`, `timeout` and `system_log` (per-rule `socat -ls -d`).
* **uninstall.sh** (from mylucien): stops the engine, removes every installed
  file and the firewall rules; keeps `/etc/config/socat` unless `--purge`.

* **`keepalive`** (from mylucien): on by default; a rule that talks to a
  device that never closes its side of a TCP stream can switch it off.
* **`listen_addr`** (from mylucien's `src_addr`): bind the listener to one
  local address instead of every address.  A v6 literal replaces the automatic
  WAN-IPv6 bind; a multicast listener ignores it (it must bind the group).
* **`ssl_cert`/`ssl_key` form fields** — they were exported and validated but
  had no input in the dialog, so a TLS rule could only be created by hand.

Deliberately NOT copied, because our existing design is the stronger one:
firewall3 (iptables) support (we are ucode-native 24.10+/25.x only; a Lua
fallback would undo that) and the static `nftables.d` snippet mechanism
(WROIATE: every rule change needs a full `fw4 reload`; our UCI rules are
self-healing, survive backup/restore and reload only when needed).

### Fixed: three defects the real engine exposed (2026-10-14)

The unit tests compare the *generated key* (which has its spaces stripped, on
purpose) and only looked at substrings, so three real defects sailed through
them and were caught by the layout simulator, which starts the real engine and
the real `socat`:

* A missing space before the target address on an IPv4 `UDP-LISTEN` rule
  (`UDP-LISTEN:53,forkUDP4:192.168.1.11:53`): socat refused to start it, so
  the rule was silently down.  The generator now has an invariant test that
  fails if any address runs into the option before it.
* `keepalive` was added to a **unix** socket: `socat` rejects it outright
  ("`keepidle` not supported with this address type"), so every unix listener
  died on start.  Keepalive is now only added to TCP-ish addresses (a unix
  listener dialling TCP still keeps its own keepalive).
* Unix and multicast listeners were **invisible to the engine**: the worker
  scan only accepted `*-LISTEN` argv and the listener table is built from
  `/proc/net/tcp`, where neither a unix socket nor a `UDP4-RECVFROM` socket
  appears.  They were therefore restarted every cycle (and never stopped).
  The scan now accepts them; a unix listener is proven alive through
  `/proc/net/unix` (state `01`), a multicast one through its bound UDP port,
  and a stale unix socket file is unlinked before rebinding (`unlink-early`).

### Fixed: a rule's runtime options were attached to the wrong field

`dest_ip` and `dest_port` had no `depends` at all, and the pair added for
`dest_port` landed *before* the field was declared, so it was applied to
`dest_ip` (duplicated) and `dest_port` stayed visible for unix and multicast
targets, where it is meaningless but mandatory.  Both now depend on the
destination protocols that actually use them.

### Fixed: a dead rule was reported as listening (live bug)

Found while verifying the new protocols against the router: the backend's
state parser read the **third** column of the engine's state file
(`sid kind port pid error`) as the pid — i.e. the port — so a rule whose
listener had failed to bind always looked alive and its error never reached
the UI. Down/partial detection and the down-reason banner were dead code in
practice since V3. The parser now reads the pid column, and the router suite
grows a test that forces a real `EADDRINUSE` conflict and asserts the rule is
reported down with its reason. (Probe created on the router and removed after
reproduction; the same defect would have made every port-clash silent.)

### Upstream-parity round: features and the same bugs, fixed (2026-10-14)

Read the other `luci-app-socat` implementations on GitHub (chenmozhijin,
WROIATE, mylucien, 4IceG) as a bug class list — their open issues must not
become ours — and took the parts worth having:

* **Port ranges** (their issue "port range forwarding does not work").
  `listen_port` now accepts `30000-30010`; the generator expands the span into
  one listener per port (same validation as a single port: no padding, no
  out-of-range, from ≤ to), the firewall rule aggregates the ports, and a span
  longer than 256 ports is clamped with a warning — a typo can no longer fork
  tens of thousands of workers. The view field uses LuCI's `portrange` datatype
  (single port or `a-b`), the import validator accepts the same shapes, and
  conflict detection expands ranges so an overlapping range is flagged.
* **IPv6 hostname targets** (their issue "a domain that resolves to IPv6 does
  not forward"). socat accepts brackets only around a *literal* IPv6 address;
  the old `TCP6:[host]:port` made every hostname target unresolvable. Brackets
  are now only used when the target itself contains a colon, for the engine's
  dial and the Test button alike; the Test button also enforces the same
  character whitelist the generator uses.
* **Per-rule runtime files.** stderr and the pid registry were keyed by
  `kind-port`, so two rules sharing a listen port overwrote each other's
  bookkeeping (and a `restart-rule` could wipe the other rule's error text).
  Both are now keyed by `sid-kind-port`. Covered by a new simulator scenario.
* **Event-driven reconcile** (hotplug hook on `ifup`/`ifdown`/`ifupdate`):
  a WAN redial or address change is reconciled in seconds instead of up to one
  engine cycle. Reconcile is a no-op when nothing changed (same lock and fast
  path as the main loop), so extra events cost a few forks at most.
* Tests: +22 host cases (generator ranges/brackets/clamping, view datatype +
  range row, simulator scenario 8 with a range rule and a real port clash), all
  verified by mutation (reintroducing each bug turns the new assertions red).

### Audit round: three latent defects (2026-10-14)

A full read-through of the engine, the generator, the zone detector, the backend
and the view, plus a live check of the router (single loop, 30/30 listeners, no
duplicates, no warnings). Three defects found and fixed, each with a regression
test that was verified to fail on the old code:

* **Firewall back-off did not engage after the first failure.** The fail marker
  (`$RUNDIR/fw.sig`) stamps the epoch the back-off compares against, but the
  variable holding it was only assigned *inside* the back-off branch — so a
  failure wrote `fail <sig> ` with no epoch, the next cycle could not parse it,
  and the engine retried the whole rebuild 15s later instead of after
  `FW_RETRY` (300s). One premature `uci commit` + `fw4 check` per failure chain
  against a broken firewall. The epoch is now stamped on every attempt.
* **Zero-padded ports disabled the listener-identity check for that rule.** A
  `listen_port=00443` passed validation and reached the command line verbatim,
  while `/proc/net/*` and the pid registry speak plain decimal ("443"). The
  rule's listeners were therefore never matched back to their socket — exactly
  the ambiguity that duplicate-listener collapsing depends on (it would let UDP
  listeners pile up again, the failure mode of V3). The generator now
  canonicalises the listen, destination and proxy ports.
* **`proxy=proxy` worked in the engine but not in the Test button.** The legacy
  spelling of HTTP CONNECT is accepted by the generator, yet the backend refused
  it as an unknown proxy type and the import validator rejected it — so a
  hand-edited rule forwarded fine while its test always failed. All three accept
  the same set now.

### Persistent engine log, readable in the UI

The engine already logged to syslog, but that ring buffer is small and is wiped
on every reboot — so the history around an incident (a loop that exited, a
firewall reload that failed) was often gone before anyone looked.

* **Engine** — every line is also appended to `/var/log/socat-reforged.log`,
  capped at 64 KiB (the newest half is kept), checked once per cycle. `/var/log`
  is tmpfs, so this costs RAM, never flash. A steady state logs nothing, so a
  rate-limited `alive:` line every ~15 min is the log's proof of life (per-minute
  HEALTH spam is what buried real warnings in the syslog ring buffer before).
* **Backend** — new `log{lines}` (tail of that file, max 300 lines by default,
  arbitrary counts up to 2000) and `log_clear` ubus methods; ACL updated.
* **UI** — an "Engine log" section at the bottom of the page shows the last 300
  lines with Refresh / Clear buttons. It is a `<details>`: it only fetches while
  open, so a closed page never pulls the file every 5s.
* Tests: host simulator asserts the file is created, timestamped and capped; the
  view smoke test covers the new section; router suites assert the file and the
  new backend methods.

## V3 (2026-10-13)

### Listener identity, duplicate listeners, diagnostics

Follow-up audit after observing "the engine process exits and comes back" and
rules that silently stop forwarding.

* **Engine — a listener is no longer identified by its parent pid alone.** socat
  `,fork` leaves a per-connection child whose argv is *identical* to the
  listener; when the listener dies first that child is reparented to init, so
  the old ppid heuristic treated it as a healthy listener and the rule was never
  restarted. A worker now also has to still own its listening socket
  (`/proc/net/{tcp,tcp6,udp,udp6}`, checked per protocol family), so the rule is
  restarted instead of staying silently dead. Covered by a new router
  regression test (a real fork child that outlives its listener).
* **Engine — duplicate listeners are collapsed.** TCP refuses a second bind, but
  UDP honours `SO_REUSEADDR` and binds twice, so a spawn/scan race could pile up
  copies silently (observed: 60 workers for 30 rules). The reconcile now keeps
  exactly one worker per desired key, and the pid registry closes the race that
  produced them.
* **Engine — a crash is no longer invisible.** The loop traps TERM/INT/HUP and
  records a last-exit reason; on start it reports a previous run that exited
  without cleanup. `procd_set_param stderr 1` sends the engine's own stderr to
  syslog and the respawn `max_fail` went from 5/hour to effectively unlimited
  (an engine left dead = forwards silently stop). The engine no longer writes
  to `/dev/watchdog` — the hardware watchdog belongs to `watchdogd`.
* **Backend — correct engine liveness.** The state file's mtime is an *epoch*
  timestamp and was compared against `/proc/uptime`, so the staleness test never
  fired; and the state header only refreshed every 120s, so the dashboard showed
  "stopped" for ~30s out of every 2 minutes. Liveness now comes from the
  per-cycle heartbeat (`<uptime> <workers> <loop_pid>`), which the backend reads
  with matching units.
* **UI — Test uses what you typed.** `fieldVal()` read the field *wrapper* div
  (no `.value`), so it always fell back to the saved value; it now reads the
  real widget, so "Test" checks the destination in the dialog. Imports are
  validated (port range, protocol, address) before anything reaches UCI.
* **Packaging/tests.** The installer keeps only the 5 most recent engine
  backups; the router checks remove every test section on exit (even on failure).

### Engine and packaging rewrite

Engine and packaging rewrite of V2, driven by a full code audit (2026-10-13):

* **Portability (was broken for most users)**
  * IPv6 is taken from the interface holding the default IPv6 route (any WAN
    type), not hard-coded `pppoe-wan`.
  * No IPv6 no longer disables the engine: only the IPv6 listeners are omitted,
    IPv4 forwards run normally. (V2 skipped the whole reconcile and spammed a
    warning every 30s.)
  * The WireGuard DNAT watchdog and the `2000::/3` route fix left the default
    path: they are opt-in UCI switches (`wg_dnat_guard`, `fix_v6_route`, default
    `0`) and never flush conntrack (V2 reloaded fw4 and flushed conntrack every
    minute on routers without that rule).
* **Correctness**
  * UDP rules were IPv4-only and `family=6` on UDP silently meant IPv4; UDP now
    honours `family` exactly like TCP, and `family=6` without IPv6 is reported.
  * Everything is validated (port range 1-65535, IP/hostname whitelist, family,
    proxy, section id) in the generator, so a bad UCI value is skipped with a
    logged warning instead of producing a broken command line.
  * Per-rule restart validates its section id; `ctl restart` now restarts the
    service instead of leaving orphan workers when the engine was stopped.
  * Firewall sync backs off after a failed `fw4 check` (V2 fought forever),
    re-creates its rules if they are deleted, and merges consecutive ports into
    ranges.
  * The backend no longer throws on a missing/broken `/etc/config/socat`, and
    `engine.running` requires the loop process to exist (a dead loop can no
    longer look healthy).
  * `test` bounds the connect phase (`connect-timeout=5`); before, a black-holed
    target could hang the request for minutes.
* **Safety**: workers carry `SOCAT_REFORGED=1` in their environment, so the
  engine only kills its own listeners — another socat on the box is never
  touched. Engine state moved out of `/tmp` into `/var/run/socat-reforged/`.
* **Performance**: one `uci show` + one awk pass per cycle instead of ~200
  forks, plus a fast path that skips all work when nothing changed. Measured on
  the author's router: **14% of one core → 0.7%** (2.1s → 0.42s CPU per minute),
  with 30 listeners.
* **UI**: shows why a rule is down (listener stderr), partial state, an error
  banner, datatype validation for target/proxy addresses, and an Engine settings
  section for the three opt-in switches.
* **Packaging**: the generator awk file is installed by the package and
  `install.sh`; postinst/installer cache clearing fixed (missed the unsuffixed
  `/tmp/luci-indexcache` and the file form of `/tmp/luci-modulecache`); CI
  reduced from 4 SDK downloads to the 2 that produce distinct artifacts.

### Second portability round

* **Firewall zones are detected, not assumed.** The accept rules go into the
  zone(s) that actually cover the WAN device — named or anonymous, DHCP or PPPoE,
  single- or multi-WAN. An anonymous zone without a `name` option cannot be
  referenced by a rule at all, so it is skipped. If no zone can be determined
  the engine logs once and leaves the firewall alone instead of writing into a
  non-existent zone (which would have failed `fw4 check` and been undone every
  5 minutes).
* **Nothing depends on the caller's PATH.** The engine sets its own PATH and
  resolves `ip`, `uci`, `awk`, `nft`, `fw4`, `pgrep`, `logger` and `socat` once
  at startup; `/sbin/fw4` is gone as a hard path. The rpcd backend runs its
  shell helpers with an explicit PATH as well.
* **The WireGuard watchdog uses the detected zone** for the fw4 chain name
  (`dstnat_<zone>`), not a hard-coded `dstnat_wan`.
* **A missing tool can never look like "all rules disabled"** — if `awk` or
  `uci` are unavailable the engine logs once and does nothing, instead of
  stopping every forward it owns.
* **Menu no longer depends on `/etc/config/socat` existing** — the page stays
  reachable and offers its empty state instead of disappearing.
* Section names containing dots are parsed correctly (option vs. section is
  decided the way `uci show` itself does it), and such ids work with
  `restart-rule` too.
* Verified with an OpenWrt layout simulator: DHCP eth0.2, PPPoE pppoe-wan,
  renamed zone, device-only zone, multi-WAN, no-IPv6, anonymous-nameless zone,
  unmappable zone, and a restricted `PATH=/bin` start.
