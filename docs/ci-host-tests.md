# Adding the test suite to CI (one manual step)

`sh tests/run.sh` runs the whole host suite (view smoke test, generator unit
tests, zone detection, layout simulator) in about a minute, and it exits
non-zero on any failure — so it is a natural CI gate.

It cannot be pushed from here: the `gh` credential is an OAuth App whose scopes
are `gist, read:org, repo` — **no `workflow` scope**. That is deliberate (a
`workflow` scope can execute arbitrary code in CI); recreating such a token was
ruled out in `memory/platform/github/00-账户与认证.md`.

Adding a job through the GitHub **web editor** does not need that scope. Copy
the block below into the top of `jobs:` in `.github/workflows/build.yml` (the
existing `build:` job stays as it is):

```yaml
  test:
    name: host-tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          path: pkg

      - name: Install host tools
        run: |
          sudo apt-get update
          sudo apt-get install -y busybox socat nodejs

      - name: Run the test suite (view, generator, zones, layout simulator)
        run: |
          cd pkg
          sh tests/run.sh
```

What each part needs:

| tool | why |
| --- | --- |
| `busybox` | the awk/`sh` the engine actually runs with (the suite cross-checks both) |
| `socat` | the layout simulator starts real listeners |
| `nodejs` | `tests/host/view-smoke.js` renders the LuCI view with a stubbed DOM |

After merging, every push and pull request gets a `host-tests` job; the
`build:` jobs keep producing the `.ipk`/`.apk` artifacts.
