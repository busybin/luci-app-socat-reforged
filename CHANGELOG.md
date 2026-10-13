# Changelog

`V<integer>` releases (see Releases). `main` carries unreleased work on top of
the last tag; version numbers only change when a release is requested.

## Unreleased

### Persistent engine log, readable in the UI

The engine already logged to syslog, but that ring buffer is small and is wiped
on every reboot — so the history around an incident (a loop that exited, a
firewall reload that failed) was often gone before anyone looked.

* **Engine** — every line is also appended to `/var/log/socat-reforged.log`,
  capped at 64 KiB (the newest half is kept), checked once per cycle. `/var/log`
  is tmpfs, so this costs RAM, never flash.
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
