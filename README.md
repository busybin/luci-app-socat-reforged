# luci-app-socat-reforged

A **from-scratch ("reforged") socat port-forward manager for the modern LuCI**
(ucode / JavaScript), for **OpenWrt 24.10 and newer** — including **25.10+**,
where the classic Lua/CBI LuCI (and `luci-compat`) no longer exists.

Existing socat LuCI apps (`chenmozhijin/luci-app-socat`, `big-tooth/luci-app-socatg`)
are written for the old Lua/CBI LuCI and **do not run on the new LuCI**. This is a
drop-in replacement with a modern, ucode-native view.

![screenshot](docs/screenshot.png)

## Features

* **Modern LuCI view** (`form.GridSection`, no Lua runtime): an editable
  port-forward table with live listener status, a **search box** and
  **status filters** (all / listening / down / disabled), and a friendly
  empty state.
* **rpcd / ucode backend** (ubus object `luci.socat-reforged`): the page does
  **not** shell out from the browser. One RPC returns the whole state
  (engine, every rule, active connection counts) and the actions run
  server-side — faster, no `netstat`/`ps` parsing, and the ACL grants only
  the exact methods.
* **Engine status card**: running/stopped (+ *last reconcile* age),
  `listening / total`, **live connection count**, worker count, and
  **Start / Stop / Restart** buttons.
* **Per-rule reload** — `Save & Apply` restarts **only the rule(s) you changed**
  (a diff/reconcile engine, not a blunt restart); a **Restart this rule**
  button does the same for a single rule on demand.
* **Live status per rule** (`● listening` / `○ down` / `○ disabled`) plus the
  active connection count, refreshed automatically; **inline enable checkbox**
  that applies on `Save & Apply`.
* **Reachability test** per rule (dials the configured target — optionally via
  the configured proxy) and **Clone** to duplicate a rule.
* **Import / export** all rules as JSON.
* **Port-conflict detection**: two enabled rules sharing a `proto:port` are
  flagged in the table and in a warning banner.
* **Unsaved-changes guard**: red banner + a save/discard dialog when you leave
  the page with pending edits (banner clears the moment you revert a value).
* **Automatic WAN firewall** (`firewall_accept`, on by default): keeps a dedicated
  `socat-reforged` accept rule in sync with your rules, validated before reload and
  persisted in `/etc/config/firewall`.
* **IPv6-aware**: listens on IPv4 + IPv6 by default (bind to the live WAN v6), with
  an optional IPv4-only / IPv6-only per rule.
* **Reach the target through a proxy** (SOCKS4a / HTTP CONNECT) per rule.
* **Standalone / self-healing**: the engine loop reconciles against the running
  workers every cycle (and on demand), fixes the WAN IPv6 default route, re-checks
  the WG DNAT rule and exercises the hardware watchdog. A **single-instance lock**
  guarantees only ever *one* engine loop reconciles — even if a competing init
  (e.g. a socat build shipping its own init for this engine) is present, the extra
  loop just idles, and the lock self-heals if the holder dies uncleanly.
* **Theme-aware** UI (uses the LuCI CSS variables, so light and dark themes both
  look right).

## Requirements

* OpenWrt **24.10+** with the **JavaScript LuCI** (default in 24.10; the only one
  in 25.10+). No `luci-compat` needed.
* `socat` (pulled automatically as a dependency; it is architecture-specific and
  comes from your distribution's feeds).
* **The forwarding engine is included.** The package ships `/etc/socat-boot.sh`
  and its own procd service `/etc/init.d/socat-reforged` — no separate engine is
  needed. On install it stops and removes any legacy init that runs the same
  engine (e.g. from a custom socat build) so only one loop can ever run.
* A `firewall4`/`nftables` system for the automatic WAN rule (everything else works
  without it; the firewall sync simply no-ops).
* BusyBox userland (standard on OpenWrt) for `sh`, `sort`, `grep`, `tr`, `sed`,
  `awk`, `pgrep`, `killall`, `netstat`, `nft`, `ubus`, `uci`.

## Installation

### 1. Manual install (any architecture)

The package is shell + JavaScript + JSON + ucode — **architecture-independent**.
If you can copy files to your router you can install it, no compilation:

```sh
# on the router (adjust the source dir)
tar -xzf luci-app-socat-reforged-<ver>.tar.gz
cd luci-app-socat-reforged-<ver>
sh install.sh
```

`install.sh` installs the UI, the rpcd backend, the **engine** and its **procd
service**, creates `/etc/config/socat` if missing, and migrates off a legacy
engine init. It is idempotent, backs up before touching the engine, and never
overwrites your existing `/etc/config/socat`.

The engine is managed as the procd service **`socat-reforged`**:

```sh
/etc/init.d/socat-reforged enable     # start at boot
/etc/init.d/socat-reforged start
/etc/init.d/socat-reforged stop
```

### 2. Build from source (feed / package)

Add this repository as a package or feed and build with your SDK / buildroot:

```sh
# point your OpenWrt tree at it, e.g. clone into package/ or add a feed
git clone https://github.com/busybin/luci-app-socat-reforged \
    package/luci-app-socat-reforged
make menuconfig       # LuCI -> Applications -> luci-app-socat-reforged
make package/luci-app-socat-reforged/compile V=s
```

### 3. Prebuilt packages

CI can produce `luci-app-socat-reforged_*` packages (see `.github/workflows/build.yml`
and the Releases page). Because the package is `Architecture: all`, **a single
build works on every OpenWrt architecture** — only the `socat` dependency is
per-architecture and is resolved from your own feeds.

## How different architectures are handled

* **This app is architecture-independent.** `LUCI_PKGARCH:=all`; the payload is
  `sh` + `.js` + `.json` only. One `_all` package (or the source tarball) installs
  on x86-64, aarch64, arm, mips, RISC-V, … alike.
* **`socat` is the only arch-specific piece**, and it is a normal dependency:
  `apk add socat` / `opkg install socat` picks the right build for your target.
* **No per-architecture build of this package is needed.** If you build from source,
  any target's SDK produces the same `_all` package. If you use CI, a single matrix
  entry is enough; extra entries only validate more targets.
* **Manual install needs no compilation at all** — ideal for tiny/exotic devices.

## Repository layout

The package follows the LuCI buildroot convention (`luci.mk` installs `root/`
into `/`, `htdocs/` into `/www`); the engine and its service are part of the
package:

```
root/…   -> /      (menu, ACL, ucitrack, engine + init, libexec helpers,
                    rpcd/ucode backend)
htdocs/… -> /www   (the LuCI view)
```

## Configuration (UCI: `/etc/config/socat`)

Each `config config` section is one forward:

| option | meaning |
| --- | --- |
| `enable` | `1`/`0` |
| `remarks` | label |
| `proto` | `tcp` / `udp` |
| `listen_port` | WAN-side listen port |
| `dest_proto` | `tcp4` / `udp4` / `tcp6` / `udp6` |
| `dest_ip` / `dest_port` | target |
| `family` | `''` = IPv4+IPv6, `4` = IPv4 only, `6` = IPv6 only |
| `proxy` | `''` / `socks4a` / `http` (+ `proxy_server`, `proxy_port`) |
| `firewall_accept` | `1` = keep the WAN port open automatically |
| `reuseaddr` | `1`/`0` (default `1`) |

## Credits & license

GPL-3.0-or-later. See `NOTICE` for prior art and the `socat` runtime dependency
(GPL-2.0). This is an independent reimplementation; no code was copied from the
older Lua apps.
