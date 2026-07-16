## Context

`cli-activity` already provides multi-progress for concurrent package work (`outdated`, `update` phase 1) and sequential step bars for preflight/commits. Rows today are `spinner + package key + optional phase text`; the top bar is package done/total.

Go tree-lane planning (`planGoPackage`) is the long path: portageq ceilings, GitHub version list, then sequential `mapM` go.mod fetches for every upstream tag. Status is stuck on `"fetching"`. The process-local go.mod cache holds an `MVar` for the entire HTTP fetch, serializing probes across packages. Package-level `--jobs` concurrency therefore under-delivers for Go work.

This change upgrades row presentation, wires step telemetry through check/plan/apply, and adds a separate work budget so nested Go work can overlap safely.

## Goals / Non-Goals

**Goals:**

- Multi-progress rows that show spinner, `category/package`, optional step bar + `done/total` steps, and current step name.
- Top bar remains packages completed / packages total.
- Real step updates during Go outdated checks and update phase 1 (including multi-PV apply steps).
- Work budget semaphore capacity `2 * jobs`, separate from package job pool.
- Work budget covers ceilings/portageq, list-versions, and each go.mod probe.
- Parallel go.mod probes under the work budget; cache does not hold locks across I/O.
- Same functional results and stdout contracts as today.

**Non-Goals:**

- New CLI flags (`--network-jobs`, etc.).
- Nested parallel vendor/publish storms during apply (package-level only).
- Progress for config load / discovery spine.
- Changing commit or preflight sequential step bars beyond existing behavior.
- Guaranteeing zero garbling if child processes write to the TTY outside capture.

## Decisions

### 1. Dual semaphores: package jobs + work budget

**Decision:** Keep `mapConcurrentlyN jobs` for package admission. Add a process-wide work semaphore with capacity `2 * jobs` (minimum capacity 2 when jobs resolves to 1). Package and work pools MUST be distinct QSems (or equivalent)—never one semaphore for both admission and nested probes.

**Rationale:** Avoids `jobs × nested` explosions; gives single-package runs limited nested parallelism (2 probes when jobs=1); reuses one user-facing knob.

**Alternatives:** Package-only + labels (weak for one fat Go package); independent probe-jobs flag (extra CLI surface); `4 * jobs` or capped budget (user chose `2 * jobs`).

### 2. Work budget consumers (v1)

**Decision:** Acquire one work slot for the duration of:

- Go ceiling discovery (portageq + tree scan for that call)
- List upstream versions for a Go package
- Each individual go.mod fetch

Non-Go single fetches use package slots only (no work-sem requirement in v1). Apply vendor/publish/manifest do not take nested work slots beyond whatever planning already used.

**Rationale:** Matches the stall sites; keeps apply I/O model simple.

**Alternatives:** Put all HTTP under workSem (stricter consistency, larger refactor).

### 3. Row presentation: optional nested step progress

**Decision:** Extend multi-progress job rows:

```
top:   <label> <pkgDone>/<pkgTotal> [bar]     # packages only
row:   spinner  cat/pkg  [bar]?  stepDone/stepTotal?  name
```

When `stepTotal <= 1` (or unset / single coarse phase), omit row bar and fraction; show name/phase only (e.g. `fetching`). When `stepTotal > 1`, show determinate bar and `done/total` plus current step name.

**Rationale:** User-requested dual counters; avoids `0/0` clutter on simple packages.

**Alternatives:** Always show bar; single-line focus mode when one job active (rejected for consistency).

### 4. MultiHandle API extension

**Decision:** Extend `MultiHandle` (names illustrative) roughly as:

- `mhStart :: PackageKey -> IO ()` (unchanged)
- `mhSteps :: PackageKey -> Int -> IO ()` — set or revise total steps when known
- `mhStep :: PackageKey -> Text -> IO ()` — advance completed count by 1 and set current name (or set name without advance if needed)
- `mhStatus :: PackageKey -> Text -> IO ()` — update name without advancing (optional keep)
- `mhSuccess` / `mhFail` (unchanged)

Dynamic totals are allowed: after version list returns, set `total = fixedPrefix + length versions` so the bar moves during probes.

**Rationale:** Step totals are not always known at `mhStart` (Go list-versions first).

### 5. Go outdated / plan step model

**Decision:** For `GoVendorAndAssets` checks, after version list:

```
totalSteps = 2 + nVersions   # ceilings, list, then one step per go.mod probe
```

Emit names such as: `discovering go ceilings`, `listing versions`, `probing go.mod` (tag detail optional; under parallel probes, a generic probing name is acceptable).

Simple non-Go checks: single step / status `fetching` only (no row bar).

**Rationale:** Bar moves during the long phase; parallel probes may complete out of order—count completions, not “current tag index.”

### 6. Parallel probes + non-blocking cache

**Decision:**

- Replace sequential `mapM` in `buildVersionCandidates` with bounded concurrent map that acquires the work semaphore per probe (or use a shared workSem passed into PlanOps).
- Fix `withGoModCache`: lookup under lock; on miss, release lock, fetch, then insert (double-check) so concurrent misses for different keys proceed in parallel. Same-key races may duplicate one fetch; both results are equivalent—last write wins or first insert wins.

**Rationale:** Unlocks real multi-package and multi-tag overlap.

### 7. Process-wide ceiling cache (recommended in this change)

**Decision:** Cache successful ceiling discovery once per process (injectable for tests). Failed discovery is not cached as success. Work slot still acquired for the first real discovery; subsequent packages reuse the cache without re-running portageq.

**Rationale:** Three Go packages currently re-scan gentoo go ebuilds; wasteful and burns work budget.

### 8. Update phase 1 steps

**Decision:** Keep package-level concurrency only for apply. Emit multi-step progress for Go apply when there are multiple planned PVs / phases, e.g. planning (sharing plan telemetry), then per-PV vendoring / publishing / manifest as named steps with a known total when the plan is ready. GitMv stays coarse (`fetching` / `applying`) unless trivial to share the same API.

**Rationale:** User wants parity of indicator quality without nested vendor parallelism.

### 9. Wiring work budget from Main

**Decision:** Create the work semaphore once per command run from resolved `jobs` (`capacity = 2 * max(1, jobs)`), pass into `PlanOps` / check / apply env alongside existing multi handle. No global mutable singleton outside the run if avoidable—thread via env for testability.

### 10. Threaded RTS required for real concurrency

**Decision:** Link the executable and test suite with GHC `-threaded` (and default multi-capability RTS opts such as `-with-rtsopts=-N`). Document this as a `cli-concurrency` requirement.

**Rationale:** Without the threaded RTS, blocking HTTP freezes all green threads, so `mapConcurrentlyN` / nested probes appear single-package even when `--jobs > 1`. Observed in production as multi-progress showing only one row (e.g. a long Go package) while the top bar stays at `0/N`.

**Alternatives:** None for true overlap during network IO; documenting “use cabal flags” alone is insufficient—the shipping binary must be linked correctly.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| GitHub/raw rate limits under `2 * jobs` probes | User can lower `--jobs`; 2× is the conservative multiplier chosen |
| Non-threaded binary serializes all package jobs | Cabal `ghc-options: -threaded` (+ `-N`); covered by cli-concurrency spec |
| Deadlock if package and nested work share one sem | Separate semaphores only; never acquire package slot from inside work-slot waiters in reverse order |
| UI flicker with many parallel step completions | Atomic state updates; redraw loop already ~80ms |
| Double go.mod fetch on same-key race | Accept rare duplicate; cache still warms |
| Step totals wrong if list-versions fails mid-flight | Fail package; mhFail with reason; no need for perfect bar |
| Wider MultiHandle surface | Keep noop handle for tests / disabled progress |

## Migration Plan

- Purely additive UX and internal concurrency; no config file changes.
- Ship behind normal release; `--no-progress` preserves non-TTY / quiet behavior.
- Rollback: revert change; no data migration.

## Open Questions

- None blocking; step naming strings can be refined during implementation without spec churn if scenarios stay behavior-focused.
