## Why

After go-tree-lanes, `outdated` (and long `update` paths) can spend a long time inside a single package—especially Go ceiling discovery, version listing, and per-tag `go.mod` probes—while the multi-progress UI only shows a spinner and a coarse phase like `fetching`. That makes the CLI look stalled. Package-level concurrency already exists for both commands, but Go planning serializes probes and holds the go.mod cache lock across HTTP, so real overlap is weaker than `--jobs` suggests.

## What Changes

- Enrich multi-progress package rows: spinner, package key (`category/package`), optional per-package step progress bar with `done/total` steps, and current step name.
- Keep the top-level bar as **packages completed / packages total** only; row bars track **steps completed / steps total** within that package.
- Omit the row bar and step fraction when a package has at most one step (avoid clutter for simple fetch checks).
- Emit real step telemetry from check/plan/apply so step names and counts reflect actual work (not a frozen label).
- Introduce a process-wide **work budget** semaphore with capacity `2 * jobs`, separate from the package job pool.
- Use the work budget for Go planning work: portageq/ceiling discovery, list-versions, and each go.mod probe.
- Parallelize per-tag go.mod probes under the work budget; fix the go.mod cache so the lock is not held across network I/O.
- Apply the same richer multi-progress to `update` phase 1; heavy apply work (vendor/publish) stays package-level concurrent with step X/Y over planned PVs—no nested vendor storm.
- No new CLI flags; `--jobs` meaning (max concurrent packages) is unchanged. No **BREAKING** changes to stdout machine output or exit codes.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `cli-activity`: Multi-progress rows gain optional determinate step progress (bar + X/Y + step name); top bar remains package-level.
- `cli-concurrency`: Document the separate work budget (`2 * jobs`) for Go planning resource units; package job pool semantics unchanged.
- `go-tree-lanes`: Planning path must support concurrent go.mod probes under the work budget, non-blocking cache, and step progress callbacks for outdated/update.

## Impact

- `CLI.Progress`: multi-progress row model and `MultiHandle` API (step total / step advance / status).
- `CLI.Jobs` (or adjacent): shared work-budget helper used by Go planning.
- `Update.Check` / `Update.Go.Plan` / `Update.Go.ModFetch`: step events, parallel probes, cache lock fix; optional process-wide ceiling cache.
- `Update.Apply`: richer step updates on phase-1 package rows (including Go multi-PV steps).
- Specs: delta for `cli-activity`, `cli-concurrency`, `go-tree-lanes` (includes threaded RTS requirement so package concurrency is real under blocking HTTP).
- Tests: progress handle callbacks, work-budget bounds, concurrent cache correctness, existing outdated/update behavior preserved.
- Build: executable and test suite linked with GHC `-threaded` (and multi-capability RTS defaults).
- Dependencies: still `layoutz` for chrome; no new packages expected.
