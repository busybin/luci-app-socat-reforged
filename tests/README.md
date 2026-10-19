# Tests

Everything here is runnable by anyone; the only external requirement is
BusyBox/Linux userland plus `socat`, and the router suite needs `ssh` access to
an OpenWrt box.

```sh
sh tests/run.sh                 # everything that needs no router (~1 min)
sh tests/run.sh --router router # also install on + test the router (~3 min)
sh tests/run.sh --sim           # just the layout simulator
sh tests/run.sh --matrix        # just the command matrix (real socat)
sh tests/run.sh --fuzz          # just the hostile-value fuzz
sh tests/run.sh --gen           # just the generator unit tests
sh tests/run.sh --zones         # just the zone detection tests
sh tests/run.sh --keys          # just the engine listener-kind classifier
sh tests/run.sh --pkg           # just the package layout / executable bits
```

Exit code is non-zero if any check fails, so this can go straight into CI.

## What is covered

### `host/` — no router needed

| suite | checks |
| --- | --- |
| `gen-cases.sh` | the desired-state generator: dual-stack vs IPv6-less, `family`, `enable` defaults, `firewall_accept`, dotted section names, and **every** validation path (port range, protocol, family, proxy, and injection attempts like `1.2.3.4;reboot`, `$(id)`, backticks, pipes, globs). Also cross-checks the host awk against BusyBox awk. |
| `zones-cases.sh` | WAN zone detection for 12 firewall layouts: default zone, PPPoE device list, renamed zone (named *and* anonymous), device-only zone, multi-WAN, nameless anonymous zone (must be skipped), unmappable layout, no firewall config, `ifname` variant, quoted values. |
| `sim-router.sh` | the **whole engine**, booted against 10 different OpenWrt layouts with a fake `uci`/`ip` and a real `socat`. Asserts which listeners came up, which firewall zone(s) the accept rules went to, and that unmappable zones produce no rules at all. Scenarios: classic DHCP, renamed zone, no IPv6, multi-WAN, unmappable, PPPoE, nameless anonymous zone, a port range plus a shared port, multicast + unix, and (with an OpenSSL-capable socat) a TLS rule whose deletion must stop its listener. Also: the persistent capped engine log, firewall backoff, and that an emptied `firewall_accept` list really withdraws the accept rules. |
| `matrix.sh` | every generated command, started for real: one rule per listener kind (TCP/TCP6/UDP/UDP6/TLS/unix/unix/unix/TCP/SOCKS4A/multicast) with every option on — including `nodelay` on the UDP rule, which socat must have been kept away from — then each command is launched and its listener verified in `/proc/net/{tcp,tcp6,udp,udp6}` or as a unix socket file. Catches "socat refuses this option on this address type". |
| `fuzz.sh` | ~100 hostile values (shell metacharacters, spikes, out-of-range and octal-looking numbers) fed to every option, each in the profile that actually reaches it, asserting the generator never crashes, never starts a listener for a value it should have refused, and that no command/key/firewall line contains a shell metacharacter. Also asserts that a rule which cannot be honoured *says why*. |
| `engine-keys.sh` | the engine's listener recognition. Derives the address types from the generator (`TCP-LISTEN`, `TCP6-LISTEN`, `OPENSSL-LISTEN`, `UNIX-LISTEN`, `UDP-LISTEN`, `UDP6-LISTEN`, `UDP4-RECVFROM`) and asserts that `scan_workers` admits each one and that `key_kind`/`key_port`/`key_unix_path` classify it. A kind missing from those lists is invisible to the engine (never stopped, restarted or counted) — which is what happened to `OPENSSL-LISTEN`. |
| `package-layout.sh` | the *installed* package rather than the code: the executable bit on everything a device runs (engine, init script, ctl helper, hotplug, plus the repo's own scripts), the `root/`+`htdocs/` layout `luci.mk` installs (never `files/`), the package metadata (`LUCI_MAINTAINER`/`LUCI_URL`/`LUCI_DESCRIPTION`, numeric `PKG_VERSION`), and the postinst **expanded the way make expands it** and syntax-checked (`sh -n`) — a Makefile `define` turns `$$$(` into `$(` and drops a bare `$'`, which shipped a postinst that was a syntax error and never enabled the service. |

### `router/` — needs a router

| file | checks |
| --- | --- |
| `run.sh` | installs the working tree on the router (`tar \| ssh`, idempotent) and runs the three suites below; always cleans up. |
| `engine-checks.sh` | runs on the router: one loop, all listeners alive, every worker is ours, a conflicting rule reports `Address in use`, out-of-range ports and metacharacter targets are refused, `udp family=6` behaviour, disable/remove, `restart-rule` (including a bad section id), a foreign `socat` surviving a reconcile, and the new protocol kinds — a unix listener comes up, leaves its socket file, and rebinds over a stale one; a multicast listener comes up and opens the IGMP rule; a TLS rule on a socat without OpenSSL is reported down with socat's own reason. |
| `backend-checks.uc` | runs on the router: loads the real rpcd backend and calls every method — `status` shape and rule statuses, the `test` validation paths (including TLS, unix and multicast targets), the connect timeout on a black-holed target, `reload`, and `rule_restart` guards. |
| `perf.sh` | runs on the router: CPU of the loop over 120s (fail above 5% of a core), log churn (fail above 2 lines), and listener health. |

## Why these exist

Two classes of bug kept appearing while building this package, and both are
guarded by the suites above:

1. **"works only on my router"** — hard-coded WAN device names, zone names,
   chain names, `PATH` assumptions. `zones-cases.sh` + `sim-router.sh` cover it.
2. **fork-heavy / thrashing engine** — the loop must stay at a handful of
   forks per cycle. `perf.sh` covers it.

`perf.sh` uses `/proc/<pid>/stat` (utime+stime) rather than `top`, so the numbers
are exact: with a few dozen listeners the loop costs about 1% of one core and
writes no log lines at all when nothing changed.
