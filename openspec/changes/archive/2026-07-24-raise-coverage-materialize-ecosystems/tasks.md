## 1. Baseline and harness

- [x] 1.1 Run `./scripts/coverage`; note Materialize expression % and remaining eco branch darkness
- [x] 1.2 Decide module split (`Test.Apply` vs `Test.Materialize`); wire Unit/Integration exports and cabal

## 2. Npm materialize

- [x] 2.1 Integration: successful npm deps-and-assets materialize/apply path with fake ops on temp overlay
- [x] 2.2 Unit or Integration: controlled fail or soft-skip path for npm as product defines
- [x] 2.3 Reuse path test if product supports npm asset reuse

## 3. Bun materialize

- [x] 3.1 Integration: successful bun deps-and-assets materialize/apply path with fake ops
- [x] 3.2 Unit or Integration: controlled fail or soft-skip path for bun
- [x] 3.3 Reuse path test if product supports bun asset reuse

## 4. Cargo materialize

- [x] 4.1 Integration: successful cargo crates materialize/apply path with fake ops
- [x] 4.2 Unit or Integration: controlled fail or soft-skip path for cargo
- [x] 4.3 Reuse path test if product supports cargo asset reuse

## 5. Go residual and progress

- [x] 5.1 Cover any high-ROI Go Materialize residual branches still dark after prior apply tests
- [x] 5.2 Assert materialize step budgets / progress event order for at least one non-Go eco path (mirror existing Go sequence tests)

## 6. Verify

- [x] 6.1 Run `./scripts/coverage`; confirm Materialize uncov dropped substantially
- [x] 6.2 Run `hk check` and fix all gate failures
- [x] 6.3 Confirm no numeric floors were introduced
