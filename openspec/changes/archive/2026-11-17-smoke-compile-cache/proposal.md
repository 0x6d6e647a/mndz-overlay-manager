# Proposal

## Why

Every `smoke` run compiles the package under test from scratch, often twice per command (plain and tilde lanes), and again on every rerun and version bump. Across 8 recorded smoke commands that came to about 500 min of Rust, 182 min of nodejs dependency builds, and 22 min of Go. Measured in sandboxed smoke-style containers, a warm compiler cache cut `aria2` from 71 s to 20 s (ccache) and `dev-util/crush` from 104 s to 23 s (Go build cache). Portage's own sandboxes stay fully on in both cases.

## What Changes

- `smoke` run containers mount one Docker volume, `mndz-smoke-compile-cache`, through a per-package volume subpath (`<category>/<package>`). A build can read and write only its own package's caches; other packages' caches are not visible in the container.
- **ccache** caches C and C++ compiles (`FEATURES=ccache`, ccache installed in the smoke image from the binhost). Its configuration is pinned to a read-only file outside the cache and also set through the environment, so a build cannot change ccache's settings for later builds.
- **Go build cache**: `GOCACHE` points at the package's cache, Go builds use `-trimpath` so hits survive version bumps, and Go's automatic 5-day trim is suppressed by writing the current time to `$GOCACHE/trim.txt` before each Go build phase.
  - **Fragile mechanism, recorded on purpose:** `trim.txt` is an undocumented internal of the `go` command, not a supported interface. Go maintainers call it "an internal implementation detail" and declined to change its behaviour to support this workaround (golang/go#69565). A request for a configurable trim limit was declined (golang/go#69879). Work aimed at Go 1.28 makes automatic trimming more aggressive (golang/go#81830). When Go changes this, the cache will be trimmed again. Builds still succeed, but cross-run hits are lost. Two checks exist to notice that: a test in the test suite against the host `go`, and a per-command check inside the smoke container against the Go version each run installs. A failed check is a warning, not a run failure.
  - `GOCACHEPROG` was evaluated and rejected. It has no timeouts, Go ≤1.27 can move its files out of the cache, the helper would have to be installed before Go in the same emerge, and no packaged local-disk implementation fits (the closest, gocachez, makes warm builds 39–46% slower).
- **Autoconf configure cache**: Gentoo `econf` runs load a per-dependency, per-ABI, per-lane configure cache through `CONFIG_SITE`, and unsafe entries are filtered out. A run that fails in `src_configure` while this cache was in use says so.
- **Zig cache**: `ZIG_GLOBAL_CACHE_DIR` persists for Zig packages (none yet), using the same per-package layout.
- **Cleanup and budget**: at the start of every `smoke`, a helper container removes caches of packages that are no longer in the overlay, then caches unused for 30 days, then least-recently-used packages until the cache fits its size budget. It also deletes Go and Zig cache entries older than 30 days. The budget is a new optional config key, `smoke-compile-cache-max-size` (default 3 GiB), further limited so the cache never leaves less than a fixed reserve of free space on Docker's volume filesystem.
- New `smoke` flags:
  - `--no-compile-cache` runs without any compile cache.
  - `--reset-compile-cache` wipes the compile caches of the selected packages before their runs.
- Each run's log gets one compile-cache line: ccache hits and misses, Go cache entries added, and the Go trim check result. The same numbers are recorded in run metrics. The stdout result line is unchanged.
- The smoke image recipe adds `buildpkg` and a binary-package cache mount of its own, so a package the binhost lacks is compiled only once across image rebuilds.

## Non-goals

- sccache or any Rust compile cache. It is deferred, with a handoff (`sccache-rust-compile-cache-handoff.typ` in the operator's wiki).
- Sharing compile caches between image builds and smoke runs, BuildKit garbage-collection tuning, building images with `docker run` + `docker commit`, and the finding that Portage sandboxes are inactive inside BuildKit `RUN` steps. All are covered by a handoff (`build-run-cache-sharing-handoff.typ`).
- Compiler caches in the materialize or smoke image recipes, which compile nothing from source today.
- `zig cc` as the system C compiler, remote ccache storage, and `GOCACHEPROG`.
- Per-mechanism opt-out settings. `--no-compile-cache` turns everything off at once.
- Changing which packages `smoke` selects, how lanes are planned, or the stdout result line format.

## Capabilities

### New Capabilities
- `smoke-compile-cache`: the compile caches available to `smoke` builds. Covers the volume and per-package isolation, ccache, the Go build cache with its trim suppression and checks, the autoconf and Zig caches, cleanup and the size budget, reset and opt-out, and per-run reporting.

### Modified Capabilities
- `smoke-command`: `smoke` accepts `--no-compile-cache` and `--reset-compile-cache`.
- `smoke-environment`: the compile-cache volume is the one more piece of state that carries over between runs, alongside the binary-package and distfiles volumes.
- `smoke-image`: the image installs ccache, and the recipe builds binary packages into a smoke-image-only cache mount.
- `run-metrics`: smoke runs record compile-cache statistics.
- `cli-help`: `smoke --help` documents the two new flags.
- `project-docs`: the README documents the compile-cache volume, the new flags, the config key, and the fragile `trim.txt` mechanism.

## Impact

- Code:
  - `src/Smoke/Container.hs`: create arguments, Portage configuration, `/etc/portage/bashrc` hooks, environment.
  - `src/Smoke/Recipe.hs`: ccache, `buildpkg`, binpkgs mount, generator id bump.
  - `src/Smoke/Run.hs`: cleanup and reset before the runs, per-run statistics.
  - `src/CLI/Parser.hs`: the two flags.
  - `src/Config/Types.hs`: a byte-size config key.
  - A new compile-cache module.
- Tests: new tests for recipe and container rendering, cleanup planning, the parser, and config, plus the Go trim test, which runs only when `go` is installed.
- Docker: one new named volume (`mndz-smoke-compile-cache`) and a short-lived helper container per `smoke` command. Volume subpath mounts need Docker Engine 26 or newer; `smoke` already requires 28.0.
- Disk: up to the budget on Docker's volume filesystem.
- The first `smoke` after upgrading rebuilds the smoke image, because the generator id changes.
- Docs: `README.md` smoke sections and the config key list.
