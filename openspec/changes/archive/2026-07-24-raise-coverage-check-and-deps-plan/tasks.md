## 1. Baseline and inventory

- [x] 1.1 Run `./scripts/coverage`; note Check and Deps.Plan expression %
- [x] 1.2 Inventory Policy/other tests that reimplement check; list product APIs to call instead (`checkPackage`, `checkPackageDeps`, `checkOverlayWithDepsPlan`, `planDepsPackageWithProgress`, etc.)

## 2. Product Check under Unit and Integration

- [x] 2.1 Replace or supersede local check reimplementations with calls to real Check APIs and fake fetchers
- [x] 2.2 Unit-test per-package check paths for GitMvAndManifest and DepsAndAssets statuses (outdated/ok/ahead/error/unconfigured as product defines)
- [x] 2.3 Integration-test multi-package `checkOverlayWithDepsPlan` (or equivalent) with mocked `DepsPlanOps` and progress handle if required

## 3. Deps.Plan per ecosystem

- [x] 3.1 Unit or Integration: `planDepsPackageWithProgress` for Go (gaps vs existing Lanes tests)
- [x] 3.2 Unit or Integration: plan path for Npm ecosystem with mocked version list / engines.node
- [x] 3.3 Unit or Integration: plan path for Bun ecosystem with mocked version list / engines.bun
- [x] 3.4 Unit or Integration: plan path for Cargo ecosystem with mocked versions / rust-version probes
- [x] 3.5 At least one controlled plan failure or empty-candidate path per design (shared or per-eco as product allows)

## 4. Suite hygiene

- [x] 4.1 Ensure new cases sit under correct Unit vs Integration groups
- [x] 4.2 Prefer dedicated test module(s) if Policy/Lanes files become unmaintainable

## 5. Verify

- [x] 5.1 Run `./scripts/coverage`; confirm Check and Deps.Plan leave single-digit expression %
- [x] 5.2 Run `hk check` and fix all gate failures
- [x] 5.3 Confirm no numeric floors were introduced
