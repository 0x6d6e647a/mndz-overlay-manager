## Why

Happy-path Integration tests already exercise phase1 apply, materialize full/reuse, and many plan/check cases, but large branch residual remains: `applyOverlay` multi-package orchestration is barely called from tests, GitMv outcome matrix is incomplete, Check contentFix on real ebuilds is thin, runtime ceiling discover paths need empty-cache cases, and Materialize error arms stay yellow. Wave 5 is Integration-primary testmaxxing for the apply/check/plan spine without re-owning production HTTP or process bodies (A/B waves). Locked: `applyOverlay` jobs=1 **and** jobs>1 (T8 A+B); contentFix Go+Npm **then** all four ecos (T9 A+B).

## What Changes

- Integration tests calling product **`applyOverlay`** with multi-package overlays: sequential jobs=1 first, then concurrent jobs>1
- Expand GitMv / soft-hard outcome and dirty/error branches as product exposes them
- Check **contentFix** Integration on real temp ebuilds: Go+Npm depth, then Bun+Cargo content-only paths
- Deps.Plan / Runtime.Ceilings residual discover paths using empty caches and injectable portageq fakes (not production process bodies)
- Materialize residual error arms (plan-fail, prune, token/missing assets, sidecar) with ApplyEnv domain fakes
- Floor-free; no live network asset publish

### Non-goals

- ProcessOps production process adapters (prior waves)
- Fake-HTTP production GitHub/registry clients (prior wave)
- Scoring cold `app/Main`
- Numeric floors
- Replacing domain Ops fakes with live tools

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `test-coverage`: Require Integration (and Unit where pure) residual coverage for applyOverlay, contentFix, ceilings, materialize error arms; floor-free

## Impact

- **Tests:** primarily `Test.Apply`, `Test.Materialize`, `Test.CheckPlan`, `Test.Lanes`, `Test.Md5Cache` as needed
- **Product:** no intentional behavior change; tests only
- **Program order:** after process/HTTP waves preferred so residual is truly branch residual, not cold production adapters
