## 1. Baseline and module layout

- [x] 1.1 Run `./scripts/coverage`; confirm Npm.Cache / Bun.Cache / Cargo.Crates still dark (or note post–Wave-1 state)
- [x] 1.2 Add focused test module(s) for ecosystem builders (avoid unbounded `Test.Apply` growth); wire into Unit (and Integration if used) in `test/Main.hs` and cabal

## 2. Pure helpers (all three ecosystems)

- [x] 2.1 Unit-test npm pure helpers (host/node requirement, messages, exported parsers as applicable)
- [x] 2.2 Unit-test bun pure helpers (engines.bun parse, host meets requirement, messages)
- [x] 2.3 Unit-test cargo pure helpers (`crateTarballPrefix`, tree MSRV helpers as practical on temp dirs)

## 3. Builder paths with fake Ops

- [x] 3.1 Unit-test `buildNpmDepsTarball` with fake `NpmCacheOps`: success writes expected artifact shape; failure returns controlled error; progress callbacks observed if present
- [x] 3.2 Unit-test `buildBunDepsTarball` with fake `BunCacheOps`: success, failure, progress as above
- [x] 3.3 Unit-test `buildCargoCratesTarball` with fake `CargoOps`: success, failure, progress as above
- [x] 3.4 Ensure no live registry/GitHub network is required for these cases

## 4. Light Integration (optional but preferred if natural)

- [x] 4.1 If env wiring is non-trivial, add one Integration case that places fake eco ops on `ApplyEnv` (or equivalent) without full Materialize apply (Wave 4)

## 5. Verify

- [x] 5.1 Run `./scripts/coverage`; confirm the three builder modules are not 0% expressions
- [x] 5.2 Run `hk check` and fix all gate failures
- [x] 5.3 Confirm no numeric floors were introduced
