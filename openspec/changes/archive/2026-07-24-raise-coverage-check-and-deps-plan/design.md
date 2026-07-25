## Context

`Update.Check` and `Update.Deps.Plan` dominate absolute uncov after pure/builders. Policy tests currently use a local `checkWithFakeResolve` that never enters product check/plan pipelines. Go plan is partially covered via `Test.Lanes`; npm/bun/cargo plan paths are not.

## Goals / Non-Goals

**Goals:**

- Call real `Update.Check` and `Update.Deps.Plan` APIs with injectable fetchers/`DepsPlanOps`.
- Cover **Go gaps + Npm + Bun + Cargo** plan paths under Unit and Integration.
- Remove dependence on local reimplementations of check for coverage.

**Non-Goals:**

- Materialize apply (Wave 4), agent/HTTP residual (Wave 5), live network, floors, operator-facing outdated output redesign.

## Decisions

### D1: Prefer product APIs over test doubles of the pipeline

**Choice:** Tests must invoke `checkPackage` / `checkPackageDeps` / `checkOverlayWithDepsPlan` and `planDepsPackageWithProgress` (or the documented public entry points). Delete or stop using pipeline-local clones that reimplement status selection without calling those functions.

**Rationale:** HPC only credits product modules; reimplementations are coverage theater.

### D2: Mock at Ops/fetcher boundaries

**Choice:** Provide fake `DepsPlanOps` fields (list versions, fetch engines/tomls, etc.) and fake `Fetcher` values—same pattern as Go `PlanOps` in `Test.Lanes`.

**Rationale:** Existing injectability; no new architecture.

### D3: Unit vs Integration split

**Choice:**

- **Unit:** single package `checkPackage` / pure status helpers still not covered; single-eco `planDepsPackageWithProgress` with pure mocks and no temp overlay mutation.
- **Integration:** multi-package `checkOverlayWithDepsPlan`, multi-lane plan with progress handle, temp fixtures when ebuild-local resolution is required.

**Rationale:** Matches `test-coverage` isolation definitions.

### D4: Equal ecosystems

**Choice:** Minimum viable plan scenario per eco (NpmEco, Bun, Cargo, Go) with at least one success path and one controlled failure/skip path where product defines them.

### D5: Success metric

**Choice:** Check and Deps.Plan leave single-digit expression %; Unit and Integration rows both move; gates green. Horizon ~72–75% Overall is guidance only.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Check still pulls filesystem for resolve | Use fixtures or inject resolve as product allows; do not invent new product APIs without need |
| Large test file growth | New `Test.Deps` / extend Policy carefully |
| Overlap with Materialize | Assert plan/check outcomes, not apply commit side effects |

## Migration Plan

1. Inventory current Policy check helpers; replace with product calls.
2. Add plan cases per eco.
3. Coverage + `hk check`.
4. Archive; Wave 4 next.

## Open Questions

None blocking—exact Check entrypoints chosen by what is exported and used by the executable at apply time.
