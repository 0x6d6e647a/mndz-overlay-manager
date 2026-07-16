## 1. Progress UI API and rendering

- [x] 1.1 Extend `MultiHandle` / multi-progress state for per-package step total, steps done, and current step name
- [x] 1.2 Render package rows with spinner, package key, optional step bar + `done/total` when step total > 1, and step name; omit bar/fraction when total ≤ 1
- [x] 1.3 Keep top-level bar as packages done/total only (inner step advances do not increment package done)
- [x] 1.4 Update `noopMultiHandle` and any tests that construct `MultiHandle` for the new fields

## 2. Work budget concurrency

- [x] 2.1 Add a work-budget helper (e.g. in `CLI.Jobs` or adjacent) with capacity `2 * max(1, jobs)` and acquire/release around a single work unit
- [x] 2.2 Create the work budget once per `outdated` / `update` run from resolved jobs and thread it through check/plan/apply env (injectable for tests)
- [x] 2.3 Ensure package job semaphore and work budget are distinct limiters (no shared QSem for both)

## 3. go.mod cache and parallel probes

- [x] 3.1 Fix `withGoModCache` so the cache lock is not held across the network fetch on miss (parallel distinct keys; correct hit path)
- [x] 3.2 Parallelize `buildVersionCandidates` go.mod probes under the work budget (bounded; not unbounded `mapConcurrently`)
- [x] 3.3 Acquire work budget for ceiling discovery and list-versions in the Go plan path
- [x] 3.4 Add process-wide successful ceiling cache (injectable; failures not cached as success)

## 4. Planning progress hooks and outdated wiring

- [x] 4.1 Add optional progress callbacks to Go planning (ceilings start, list start, total after list, per-probe completion / step names)
- [x] 4.2 Wire `checkPackageGo` / `checkOne` to multi-progress step APIs so Go outdated checks show advancing step progress
- [x] 4.3 Keep non-Go checks on single-step / phase-name-only rows (`fetching`)

## 5. Update phase 1 step feedback

- [x] 5.1 Emit multi-step progress for Go apply when plan yields multiple phases or PVs (planning + per-PV vendor/publish/manifest as named steps with known total when possible)
- [x] 5.2 Keep GitMv phase labels (`fetching` / `applying`) via the same MultiHandle APIs without requiring a step bar unless total > 1
- [x] 5.3 Do not introduce nested parallel vendor/publish beyond existing package-level jobs

## 6. Tests and quality gates

- [x] 6.1 Unit tests: go.mod cache allows concurrent distinct-key fetches; hits do not refetch
- [x] 6.2 Unit tests: work budget never exceeds `2 * jobs` concurrent acquisitions under parallel probes
- [x] 6.3 Unit tests: multi-progress state — top bar package counts vs row step counts; omit bar when total ≤ 1
- [x] 6.4 Regression: concurrent outdated still produces correct reports; Go lane selection unchanged under parallel probes (existing plan tests / fixtures)
- [x] 6.5 Run full quality pipeline (`hk check` or project-equivalent) and fix format/lint/stan/weeder issues
