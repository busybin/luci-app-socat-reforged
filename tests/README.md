# Tests

Everything here is runnable by anyone; the only external requirement is
BusyBox/Linux userland plus `socat`, and the router suite needs `ssh` access to
an OpenWrt box.

```sh
sh tests/run.sh                 # everything that needs no router (~1 min)
sh tests/run.sh --router router # also install on + test the router (~3 min)
sh tests/run.sh --sim           # just the layout simulator
sh tests/run.sh --gen           # just the generator unit tests
sh tests/run.sh --zones         # just the zone detection tests
```

Exit code is non-zero if any check fails, so this can go straight into CI.

## What is covered

### `host/` — no router needed

| suite | checks |
| --- | --- |
| `gen-cases.sh` | the desired-state generator: dual-stack vs IPv6-less, `family`, `enable` defaults, `firewall_accept`, dotted section names, and **every** validation path (port range, protocol, family, proxy, and injection attempts like `1.2.3.4;reboot`, `$(id)`, backticks, pipes, globs). Also cross-checks the host awk against BusyBox awk. |
| `zones-cases.sh` | WAN zone detection for 12 firewall layouts: default zone, PPPoE device list, renamed zone (named *and* anonymous), device-only zone, multi-WAN, nameless anonymous zone (must be skipped), unmappable layout, no firewall config, `ifname` variant, quoted values. |
| `sim-router.sh` | the **whole engine**, booted against 7 different OpenWrt layouts with a fake `uci`/`ip` and a real `socat`. Asserts which listeners came up, which firewall zone(s) the accept rules went to, and that unmappable zones produce no rules at all. Scenarios: classic DHCP, renamed zone, no IPv6, multi-WAN, unmappable, PPPoE, nameless anonymous zone. |

### `router/` — needs a router

| file | checks |
| --- | --- |
| `run.sh` | installs the working tree on the router (`tar \| ssh`, idempotent) and runs the three suites below; always cleans up. |
| `engine-checks.sh` | runs on the router: one loop, all listeners alive, every worker is ours, a conflicting rule reports `Address in use`, out-of-range ports and metacharacter targets are refused, `udp family=6` behaviour, disable/remove, `restart-rule` (including a bad section id), and a foreign `socat` surviving a reconcile. Removes every rule it created. |
| `backend-checks.uc` | runs on the router: loads the real rpcd backend and calls every method — `status` shape and rule statuses, all four `test` validation paths, the connect timeout on a black-holed target, `reload`, and `rule_restart` guards. |
| `perf.sh` | runs on the router: CPU of the loop over 120s (fail above 5% of a core), log churn (fail above 2 lines), and listener health. |

## Why these exist

Two classes of bug kept appearing while building this package, and both are
guarded by the suites above:

1. **"works only on my router"** — hard-coded WAN device names, zone names,
   chain names, `PATH` assumptions. `zones-cases.sh` + `sim-router.sh` cover it.
2. **fork-heavy / thrashing engine** — the loop must stay at a handful of
   forks per cycle. `perf.sh` covers it.

`perf.sh` uses `/proc/<pid>/stat` (utime+stime) rather than `top`, so the numbers
are exact: on the author's x86_64 router with 15 rules / 30 listeners the loop
costs about 1% of one core and writes no log lines at all when nothing changed.
