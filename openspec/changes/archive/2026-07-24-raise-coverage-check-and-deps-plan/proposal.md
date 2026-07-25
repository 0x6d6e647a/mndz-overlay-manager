## Why

`Update.Check` (~7% expressions) and `Update.Deps.Plan` (~2%) are nearly dark while owning the outdated/check and multi-ecosystem plan spine. Existing “check” tests largely reimplement resolve/fetch locally instead of calling product APIs. Wave 3 maximizes coverage on the real Check + Deps.Plan paths for **all ecosystems equally**, with Unit and Integration tests.

## What Changes

- Drive **real** library APIs with injectable ops/fetchers:
  - `checkPackage`, `checkPackageDeps`, `checkOverlayWithDepsPlan` (as applicable)
  - `planDepsPackageWithProgress` for **Go (gaps), Npm, Bun, Cargo** with mocked version lists / engine probes (pattern from `Test.Lanes` Go plan)
- Retire or stop relying on local reimplementations that bypass product Check code (e.g. fake resolve loops that never call `Update.Check`).
- Classify new cases as **Unit** vs **Integration** per existing isolation rules.
- Re-run `./scripts/coverage`; keep `hk check` green.
- **No** operator-visible product behavior change.

## Program context

- **Wave 3 of 5** of the post-HPC coverage-maximization program.
- **Apply order:** after `raise-coverage-ecosystem-builders`; before `raise-coverage-materialize-ecosystems`.
- **Depends on:** Wave 2 recommended so eco pure/builder fakes exist to compose into plan ops.
- **Horizon:** Overall ~65% → ~72–75% if Check + Deps.Plan leave single digits.

## Non-goals

- Materialize apply publish/reuse for npm/bun/cargo — Wave 4.
- Deep SSH/GPG process, Release create/delete HTTP — Wave 5.
- Live GitHub/npm/registry network for CI.
- Numeric floors/ratchet.
- Changing outdated CLI operator semantics or report text (tests lock current behavior).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `test-coverage`: ADDED requirements that the suite exercises product Check and Deps.Plan for all DepsAndAssets ecosystems under Unit and Integration isolation without local reimplementations of those pipelines.

## Impact

- **Code:** `test/**` (Policy/Check, Lanes/Deps plan modules); possibly shared test fakes for `DepsPlanOps` and fetchers.
- **Quality:** large absolute uncov drop expected in Check + Deps.Plan; `hk check` green.
- **Docs:** none required (`project-docs` internal-only).
- **Downstream:** Wave 4 can focus on Materialize rather than inventing plan fakes.
