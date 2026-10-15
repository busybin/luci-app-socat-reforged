# The host-tests CI job

`sh tests/run.sh` runs the whole host suite (view smoke test, generator unit
tests, zone detection, layout simulator, command matrix, fuzz, engine listener
kinds, package layout) in about a minute and exits non-zero on any failure, so it
is a natural CI gate. It is now in `.github/workflows/build.yml` as the `test`
(host-tests) job and runs on every push, pull request and release.

## What it needs and why

| tool | why |
| --- | --- |
| `busybox` | the awk/sh the engine actually runs with on the router |
| `socat` | the layout simulator starts real listeners |
| `nodejs` | `tests/host/view-smoke.js` renders the LuCI view with a stubbed DOM |
| `procps` | `pgrep`, used by the simulator and the engine's worker scan |

`gen-cases.sh` re-runs the **whole** suite under BusyBox awk automatically when
it is installed, so one CI job exercises both awk implementations. That is not
redundant: BusyBox awk reads a leading-zero string as **octal** (`"0443"` → 291)
where mawk/gawk read 443, and the engine runs BusyBox awk on the router. A
generator that normalised ports with `+ 0` produced 291 on the device and 443 on
a desktop — green in every test, forwarding the wrong port. To reproduce locally:

```sh
sh tests/run.sh                              # both awks
AWK="busybox awk" sh tests/host/gen-cases.sh # only BusyBox awk
```

## History

The job was originally only a manual step because the `gh` credential is an
OAuth App that had no `workflow` scope (an OAuth App with `workflow` can execute
arbitrary code in CI, which is why it was not granted casually; see
`memory/platform/github/00-账户与认证.md`). It was granted on 2026-10-15 through
the device-code flow — `gh auth refresh -h github.com -s workflow`, authorised in
a browser on another machine — and the job was then committed.
