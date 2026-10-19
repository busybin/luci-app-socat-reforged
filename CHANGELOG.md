# Changelog

## V5 (2026-10-19)

### Packaging / service

* **An upgrade no longer leaves the previous engine in place.**  apk keeps an
  `/etc` file it will not overwrite and parks the packaged copy as
  `<file>.apk-new`; a new helper takes those, the `postinst` runs it before
  starting the engine, and `install.sh` drops stale ones.
* **The engine stops on SIGTERM instead of being SIGKILLed.**  A restart gives
  the engine time to shut down cleanly; the service allows 20 s.

### Works from the form (2026-10-19)

* **The form accepts what the engine accepts, and refuses what it refuses.**
  `mcast_iface` takes `eth0.2` / `br-lan`; `reuseaddr`, the proxy server and the
  proxy port are validated before a rule is saved, and the port fields reject
  `0`.
* **Port conflicts account for the transport and the address family.**  A TLS
  (`OPENSSL-LISTEN`) rule and a plain TCP rule on the same port are flagged now
  (both are TCP sockets), while a v4-only and a v6-only rule may share a port.
* **Engine settings save on a stock router.**  `/etc/config/socat` belongs to the
  official `socat` package; the `reforged` section is created on demand, and when
  the config file itself is missing, Save & Apply says so.

### Engine robustness (2026-10-19)

* **A rule no longer inherits the previous rule's `,reuseaddr`**, and an option
  whose value happens to be `config` no longer truncates the rest of its rule.
* **The engine survives a stock device**: it creates `/var/log` when absent,
  accepts anonymous sections (`config_foreach`-added `@config[1]`), and the
  `pgrep` used to reap a stale engine loop no longer matches an unrelated
  process whose command line merely *ends* with the script path.
* **A cached update answer is re-checked against the installed version**, and
  **the whole updater disappears when its helper script is not installed**, so a
  channel that ships no self-update never offers one.

### UI: dialog answers, updates and translations (2026-10-15/16)

* **Per-rule actions answer inside their dialog.** "Test target" and "Restart
  this rule" are modal-only buttons; their result (a busy line, then the
  reachable/unreachable or restarted/failed line) now appears in that button's
  own field instead of in a page notification hidden under the overlay.
* **Check for updates / update now.**  A "Check for updates" button next to the
  version asks the GitHub release API *from the router* (not the browser), shows
  the release notes and installs the right asset with `apk`/`opkg` when you press
  "Update now"; the Chinese language package is updated too when it is
  installed.  The install runs detached (`setsid`, progress in
  `/tmp/socat-reforged-update.{state,log}`) because the new package's `postinst`
  restarts rpcd, which would kill the RPC that started it.  The check is cached
  for six hours on the router, and the new **Engine settings → "Look for new
  versions"** flag (off by default) additionally checks automatically when the
  page is opened.  Nothing is downloaded or installed unless you press the
  button.  New ACL entries: `update_check`, `update_status`, `update_install`.
* **Simplified Chinese translation**, shipped the LuCI way as its own package
  (`luci-i18n-socat-reforged-zh-cn`, built from `po/zh_Hans/`): installing a
  language does not touch the app package, and anything a catalogue misses falls
  back to English.  The backend's own `detail`/`error` strings (the Test button,
  the log) are mapped onto translatable messages in the view.  From
  [@ntbowen](https://github.com/ntbowen)'s PR #2.
* The **Start** button no longer shares `cbi-button-apply` with "Save & Apply",
  so it does not run the unsaved-changes tracker and clear the dirty marker.
  The page also owns its own padding now (a plain LuCI view has no CBI
  container), so the content is not flush against the edges.  (From
  [@ntbowen](https://github.com/ntbowen)'s PR #3, with the empty-state hint kept.)

## V4 (2026-10-15)

### Packaging fixes (2026-10-15)

Three defects in the packaging layer, all found by unpacking the built `.ipk`
and all invisible to any code test:

* **The engine, the procd init script and the ctl helper need the executable
  bit.**  `luci.mk` installs `root/` with `cp -pR`, so the mode a file is
  committed with is the mode it gets in the package; the three are `0755` now
  (`deploy.sh` too).  Without it procd cannot start the service,
  `/etc/socat-boot.sh` cannot be run and the LuCI Start/Stop/Restart buttons
  fail with "permission denied" — which a hand-run `install.sh` hides, because
  it `chmod 755`s what it copies.
* **The `postinst` must survive make's `define` expansion.**  `$$$(` reaches the
  shell as `$(`, and a bare `$` before a quote loses the dollar: the expanded
  script held a literal `init.d.socat.bak.$` and an unterminated quote, so
  `sh -n` reported `Unterminated quoted string` and an install never created
  `/etc/config/socat`, migrated the legacy init, enabled the service or stamped
  the version.  Fixed to `$$(date ...)` and `'/etc/socat-boot.sh$$'`.
* **The package metadata must use `luci.mk`'s variables.**  `luci.mk` reads
  `LUCI_MAINTAINER`/`LUCI_URL`/`LUCI_DESCRIPTION`, so a bare `PKG_MAINTAINER` is
  silently dropped and the package advertised "OpenWrt LuCI community" and the
  LuCI feed URL.  All three are set now.

`tests/host/package-layout.sh` guards the whole class: the tree bits, the
`root/` + `htdocs/` layout, the metadata variables, and the postinst **expanded
exactly the way make expands it** and syntax-checked.  Verified by mutation:
dropping a bit, retyping either escaping bug, or dropping `LUCI_MAINTAINER` each
turns it red.  The empty state no longer offers a second "Add forward" button
(the table section already renders one).

### socat 1.8.0.0 wants an explicit protocol family (2026-10-15)

The host suite runs against the distribution's `socat`, and Ubuntu 24.04 /
Debian 13 ship **1.8.0.0**, whose address types pick a different protocol family
than 1.8.1's:

* a bare `UDP-LISTEN:<port>` is refused outright with
  `xioopen_ipdgram_listen(): unknown address family 0`;
* a bare `TCP-LISTEN:<port>` becomes a **dual-stack** listener (AF_INET6 `::`
  with `v6only=0`), which then owns that port for **every IPv6 address** too.  A
  rule that also has an IPv6 listener therefore failed its `TCP6-LISTEN` with
  `bind(...): Address already in use` and stayed *partial* forever — the engine
  had started both workers, so the only symptom was a rule that never came up.
* `OPENSSL-LISTEN` does the same.  That also made the engine's liveness check
  blind to a TLS worker, because the engine looks for a TLS listener in the IPv4
  table while this socket sits in the IPv6 one — so a *deleted* TLS rule kept
  its listener running (and only a TLS-capable socat can show that, which is why
  the simulator's TLS scenario caught it).

All three IPv4 listener kinds now pin `pf=ip4`.  That is a no-op on 1.7.4 and on
1.8.1 (the version OpenWrt ships; verified on a router, where `TCP-LISTEN`
listens on `0.0.0.0`) and makes the generated commands mean the same thing on
every socat the project is tested against.  `tests/host/matrix.sh` now also
starts the v4 **and** the v6 listener of one rule at the same time: every other
check starts a single command and could not see this.

That is also what the CI job needed: it runs the suite with the privilege the
engine really has on a router (`sudo`, because `,user=nobody` makes socat chown a socket), and the job
is pinned to `ubuntu-24.04` so a future runner image cannot silently change the
socat under the tests.

### A bug sweep across the whole surface (2026-10-15)

Six real defects, each reproduced before it was touched and each with a
regression test whose assertion was verified to go red when the fix is
reverted.  Two of them could only be found by exercising a *TLS-capable*
socat and a *reused* runtime directory, so the suites grew accordingly:

* **The engine was blind to `OPENSSL-LISTEN` workers.**  The address type was
  in neither of the engine's two listener-kind lists (`scan_workers` and
  `key_kind`), so a TLS worker was never seen: deleting (or disabling) its rule
  left the listener running for good, Stop/Cleanup never killed it, "Restart
  this rule" did nothing, and the worker count was short.  A new host suite
  derives the listener kinds from the **generator** and asserts that the engine
  knows every one of them, so a new listener type can no longer be added
  without teaching the engine.
* **A stale firewall port list kept a deleted forward's WAN port open.**  The
  generator only opens its `fw` file when it has a line to write, and the
  engine did not truncate it: emptying the list (last forward deleted, or
  `firewall_accept` turned off everywhere) left the *previous* ports active and
  the firewall signature unchanged, so the accept rule was never withdrawn.
* **`nodelay` on a UDP rule killed the whole rule.**  socat refuses `,nodelay`
  on `UDP-LISTEN` ("option "nodelay" not supported with this address type");
  the option was gated per address type before (unix+keepalive, udp+retry) but
  this one slipped through.  It is now only emitted for TCP/TLS listeners (the
  dial side keeps it), and the command matrix turns it on for the UDP rule so
  the same class cannot come back unnoticed.
* **An IPv4 literal on a `tcp6`/`udp6` dial looks healthy and forwards
  nothing.**  getaddrinfo with `AF_INET6` rejects `192.168.1.9` on every
  connection, while the listener binds fine.  This is the mirror image of the
  "IPv6 target needs tcp6" guard from the previous round; it is now refused
  with a reason (a hostname is still accepted — it resolves to either family).
* **`mcast_iface` reached the command line unvalidated on a relay rule.**  On a
  `dest_proto=mcast` rule the interface name is part of the *dial* address, and
  that path runs even when no group is joined — the validation lived only in
  the multicast-*receive* branch, so a value with a space injected extra socat
  arguments.  Validated unconditionally now (and on import).
* **The `test` (reachability) rpc did not know TLS, unix or multicast
  targets**, so the Test button of a valid rule answered "unknown destination
  protocol".  All three are supported now (`OPENSSL` with `verify=0`,
  `UNIX-CONNECT`, `UDP4-DATAGRAM`), the view names the target the way the rule
  does, and a cross-file test keeps the view's rpc parameters in step with the
  backend's `args`.

Also in this round:

* Two values that cannot be honoured are now **reported instead of silently
  dropped**: a `listen_addr` on a TLS rule (socat's OpenSSL listener has no
  IPv6, and the v4 path ignores a v6 bind) and `ssl_verify` without an
  `ssl_cafile` (which silently meant "no verification at all").
* **Conflict detection no longer cries wolf**: two rules may share one port if
  they bind *different* addresses; a wildcard bind still conflicts with
  everything.
* The command matrix moved off the local ephemeral port range
  (32768-60999): a port there can be taken by any outbound connection on the
  machine, which made the matrix fail with `EADDRINUSE` through no fault of the
  generator (a stray connection held 37112 once).
* Import validation now also checks `mcast_iface`/`mcast_localip`, and the
  `TCP_NODELAY` field says that a UDP listener ignores it.
* **The listen-port hint no longer shows up inside the forward list.**  A LuCI
  grid prints a description row under the header for every column that has a
  description, so "Single port or a range (one listener is started per port,
  max 256)." appeared as stray text between the column titles and the rows.
  It still shows in the add/edit dialog.

### Feature parity with the other luci-app-socat forks (2026-10-14)

Compared every live fork on GitHub (chenmozhijin, WROIATE, mylucien, 4IceG,
hongyan3, 1522042029) and took what they had and we did not:

* **TLS / OpenSSL** (from mylucien): `proto=ssl` listens with
  `OPENSSL-LISTEN` + `ssl_cert`/`ssl_key` (+ `verify=0`, so clients are not
  asked for a certificate of their own); `dest_proto=ssl` dials with
  `OPENSSL` + optional `ssl_verify`/`ssl_cafile`. Paths validated strictly.
  **Requires a socat built with OpenSSL** — OpenWrt's `socat` package is built
  `--disable-openssl`, so `socat -V` says `#undef WITH_OPENSSL` and a TLS rule
  cannot start there (it is reported down with socat's own message). Check
  `socat -V` before blaming the rule; unix sockets, multicast and the socket
  options all work with the stock package.
* **Unix sockets** (from mylucien): `unix_path` on the listen side,
  `dst_unix_path` on the dial side; no port, no firewall involvement.
* **Multicast / IPTV** (from mylucien): `mcast_group` joins a group on the
  listen port (`ip-add-membership`, `bind=<group>` so two rules cannot mix
  streams, `so-bindtodevice` for the interface), `dest_proto=mcast` relays to
  another group with `ip-multicast-if`/`-ttl`/`-loop`, or to a plain unicast
  target. IGMP is accepted on the WAN zones while a multicast rule is on.
* **Socket options** (from mylucien/WROIATE): `nodelay`, `backlog`,
  `max_children`, `timeout` and `system_log` (per-rule `socat -ls -d`).
* **`user`/`retry`/`reuseaddr`** (from mylucien): drop privileges per rule, keep dialling a
  target that is not up yet, SO_REUSEADDR switch.
* **uninstall.sh** (from mylucien): stops the engine, removes every installed
  file and the firewall rules; keeps `/etc/config/socat` unless `--purge`.

* **`keepalive`** (from mylucien): on by default; a rule that talks to a
  device that never closes its side of a TCP stream can switch it off.
* **`listen_addr`** (from mylucien's `src_addr`): bind the listener to one
  local address instead of every address.  A v6 literal replaces the automatic
  WAN-IPv6 bind; a multicast listener ignores it (it must bind the group).

What was deliberately **not** copied, and why, is listed under "Not copied,
with reasons" below.

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
* The TLS listener **asked clients for a certificate**: socat's
  `OPENSSL-LISTEN` defaults to `verify=1`, so a browser or an ordinary client
  was rejected with "peer did not return a certificate".  The generated
  listener now carries `verify=0` (no client authentication); the *dial* side
  still honours `ssl_verify`/`ssl_cafile`.  Verified with a round-trip on the
  generated command shape, on both sides.

### Upstream parity round 2: `user`, `retry`, `reuseaddr` in the UI (2026-10-15)

* **`user`** (mylucien) — the accepted connections run as that user; socat drops
  privileges after the socket is open, so a low listen port still works. Verified
  against the real socat for **every** listener kind (TCP/TCP6/UDP/UDP6/OpenSSL/
  unix/UDP4-RECVFROM): socat accepts the option on all of them, unlike
  `keepalive`.
* **`retry`** (mylucien) — keep dialling a target that is not up yet instead of
  dropping the connection. socat rejects `retry` on a UDP address
  (`option "retry" not supported with this address type`), so it is only emitted
  for connection-oriented dials (TCP/TCP6/TLS/unix/SOCKS/proxy). This was found
  by testing the option against every address type *before* wiring it in — the
  same mistake as the unix+keepalive one would have killed every udp rule.
* **`reuseaddr`** now has a form field. The engine had always honoured it, but
  there was no input for it, so it was UI-invisible.

### Fixed: engine options that were invisible in the UI

* `ssl_cert`/`ssl_key` were exported and validated by `importCheck` but had **no
  input in the dialog**, so a TLS rule could only be created by hand-editing
  `/etc/config/socat`.
* `reuseaddr` was honoured by the engine but had no input either.

Both are now covered by a structural test that fails if any option the generator
reads lacks a form field or an export entry — and the reverse, an exported field
the engine never reads (which silently saves but does nothing). `remarks` is
exempt: it is the label the user sees, not an engine option.

### Fixed: a padded port became a different port on the router

The generator normalised ports with `v + 0`. BusyBox awk reads a leading-zero
string as **octal** (`"0443"` → 291) where mawk/gawk read 443, and the engine runs
**BusyBox awk on the router** — so `listen_port='0443'` came out as 291 on the
device and 443 on a desktop. Every test on a PC passed, and the rule forwarded
the wrong port. Ports (listen, range end, dest, proxy, mcast) and `retry` are now
normalised as strings (`plain_num()`), and the guarded comparison is explicit.

Found only because the generator suite now **re-runs itself entirely under
BusyBox awk** instead of cross-checking a single fixture: with `+ 0` restored the
mawk run stays green and the BusyBox run goes red, which is exactly the original
bug. Two more test-harness defects surfaced at the same time: `has()` did not
exist in `tests/host/lib.sh`, so four assertions were silent no-ops that printed
exit 127 and counted nothing (a suite that looks green while four checks never
ran), and `AWK=busybox` could not work because busybox reads its first argument
as an applet name — it must be `AWK="busybox awk"`.

### Not copied, with reasons

* **`src_port`** (mylucien's source port for the dial): tested and refused.
  socat's `sourceport` must be bound by every forked child, so with `fork` a
  second concurrent connection fails with `Address already in use` — measured,
  not guessed. A single-connection rule would work, but a forwarder that breaks
  on the second client is worse than no option.
* **firewall3/iptables** (we are ucode-native, 24.10+/25.x only), **a static
  `nftables.d` snippet** (every rule change needs a full `fw4 reload`, and the
  snippet is invisible to `uci` and to backup/restore) and **free-form
  `custom_opts`** (a command-injection vector; the whitelist exists so that a
  rule can never become a shell command).

### Fixed: socat cannot listen for TLS on IPv6 at all

Found by the new command-matrix suite, which starts **every** generated command
for real instead of comparing strings: `OPENSSL-LISTEN` with `bind=<v6 literal>`
fails with `getaddrinfo("...", "NULL", ...): Address family for hostname not
supported`, and it fails the same way for `bind=::`, for the bracketed spelling,
and for a hypothetical `OPENSSL6-LISTEN` (which does not exist). With no `bind=`
at all it binds IPv4 only. So every dual-stack TLS rule had a v6 listener that
died on start and left the rule **partial** forever with a getaddrinfo error.

The generator now emits the IPv4 OpenSSL listener only. A rule left on the
default family gets a warning in the log ("TLS listens on IPv4 only with this
socat"), and a rule set to *IPv6 only* is **skipped** with a reason rather than
starting something that cannot work. The TLS *dial* side is unaffected — a v6
literal target resolves and connects fine.

Also verified in the same matrix run: TCP/TCP6/UDP/UDP6, TLS, unix→unix,
unix→tcp, tcp→unix, SOCKS4A and a multicast listener all start with
`user=`, `retry=`, `keepalive`, `nodelay`, `backlog`, `max-children` and
port-range expansion switched on at the same time.

### Verified live on an OpenWrt 25.12 router (2026-10-14)

Engine 522012b, 15 rules / 30 listeners, socat 1.8.1.1:

* a unix listener started, appeared in the state file with a real pid, and its
  socket file is present in `/proc/net/unix`;
* a multicast listener started with a real pid, and the engine created
  `firewall.socat_reforged_igmp` (`proto=igmp`, `src=wan`, `target=ACCEPT`) —
  and removed it again when the rule went away;
* a rule whose port was already taken was reported **down** with socat's own
  reason (`bind(): Address in use`), and `counts.down`/`counts.errors` moved
  with it — the backend regression test now forces a real `EADDRINUSE` instead
  of trusting the port lookup;
* a disabled rule reads `disabled`.

Router suite all green: engine checks 37 (incl. 13 new ones for the new kinds:
unix listener up, socket file, `/proc/net/unix`, rebind over a stale socket
file, multicast up, igmp rule created then removed, udp port opened, and a TLS
rule on a socat without OpenSSL reported down with socat's own reason), backend
checks 41, perf ok (2.2% of one core, 30/30 listeners, 0 log lines in 120s).
Proven separately that `unlink-early` is what makes the stale-file case work:
without it socat refuses with `"<path>" exists`, so a listener killed by a crash
would block the rule forever.

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
  * Two environment-specific workarounds left the default path: they are opt-in
    UCI switches (default `0`) and never flush conntrack (V2 reloaded fw4 and
    flushed conntrack every minute on routers without the rule it was watching
    for).
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

### New: a command-matrix suite and a fuzz suite (2026-10-15)

Two suites whose job is to catch what the string comparison cannot:

* **`tests/host/matrix.sh`** — one rule per listener kind with every option
  switched on, then each generated command is *started* and its listener
  verified in `/proc/net/{tcp,tcp6,udp,udp6}` or as a unix socket file. 18/18
  with `user=`, `retry=`, `keepalive`, `nodelay`, `backlog`, `max-children`,
  `timeout` and port-range expansion on at once.
* **`tests/host/fuzz.sh`** — ~100 hostile values (shell metacharacters, spikes,
  octal-looking and out-of-range numbers) fed to every option, each in the
  profile that actually reaches it, asserting that the generator never crashes,
  never writes to stderr, never starts a listener for a value it should have
  refused, and that no command, key or firewall line contains a shell
  metacharacter. Verified by mutation: loosening `ok_host` by one character
  turns two of the checks red.

Both are part of `sh tests/run.sh` (6 suites now) and the CI host-tests job.

### Fixed: four IPv6 defects (2026-10-15)

Probed the whole IPv6 surface (every listener kind × v6 variable) against the real
`socat` and fixed what could not work:

* **An IPv6 target on a v4 dial** (`dest_proto=tcp4|udp4` + a v6 literal) was
  emitted as `TCP4:2001:db8::99:80`. socat accepts that at bind time and then
  fails on **every** connection (`TCP4: wrong number of parameters`) — a rule
  that looks healthy and forwards nothing. Now refused with
  "an IPv6 target needs dest_proto tcp6/udp6/tls".
* **A v6 proxy server** (`proxy=…` + `proxy_server=2001:db8::1`): `SOCKS4A:` and
  `PROXY:` take a hostname or an IPv4 literal, and a v6 literal supplies the
  colons their parser counts fields on, so socat refuses the whole address
  (`SOCKS4A: 3 parameters required`). The UI now types the field `ip4addr`.
* **An IPv6-only multicast rule** emitted **no listener at all and no warning**:
  multicast receive is UDP4-only. Now skipped with a reason.
* **A v6 `listen_addr` on a UDP rule** was silently ignored (socat rejects `bind=`
  on `UDP6-LISTEN`), unlike the multicast case which already warned. Now warns.

Also removed one unreachable guard (the proxy/v6-target check) once the v4-dial
guard above was in place — dead code that suggests a protection it does not give.
Every guard is verified by mutation in `fuzz.sh` or `gen-cases.sh`, and the two
IPv6-only listener forms (WAN-IPv6 bind, explicit `listen_addr`) are now started
for real in `matrix.sh`.
