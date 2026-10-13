# Changelog

`V<integer>` releases (see Releases). `main` carries unreleased work on top of
the last tag; version numbers only change when a release is requested.

## Unreleased (will ship as V3)

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

## Unreleased (second portability round, 2026-10-13)

* **Firewall zones are detected, not assumed.** The accept rules go into the
  zone(s) that actually cover the WAN device — named or anonymous, DHCP or PPPoE,
  single- or multi-WAN. If no zone can be determined the engine logs once and
  leaves the firewall alone instead of writing into a non-existent zone (which
  would have failed `fw4 check` and been undone every 5 minutes).
* **Menu no longer depends on `/etc/config/socat` existing** — the page stays
  reachable and offers its empty state instead of disappearing.
* Section names containing dots are parsed correctly (option vs. section is
  decided the way `uci show` itself does it), and such ids work with
  `restart-rule` too.
* `logger`/`socat` are resolved via `command -v` instead of assuming paths.
* Verified with an OpenWrt layout simulator: DHCP eth0.2, PPPoE pppoe-wan,
  renamed zone, device-only zone, multi-WAN, no-IPv6, unmappable zone.
