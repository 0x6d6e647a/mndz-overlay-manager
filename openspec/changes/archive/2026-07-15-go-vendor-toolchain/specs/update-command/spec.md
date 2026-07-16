## MODIFIED Requirements

### Requirement: Hard failures continue others then exit one

Hard per-package failures (including dirty involved paths, `ebuild manifest` failure, git commit or signing failure, assets commit/push/release failure, Manifest hash mismatch after vendor publish, host Go older than the package `go.mod` requirement during `GoVendorAndAssets` apply, and fetch/compare errors when an update was attempted) SHALL be logged as errors. Other packages SHALL continue. After all selected packages are processed, if any hard failure occurred, the program SHALL exit with status `1`; otherwise exit with status `0` when the spine succeeded. Host Go version sufficiency for a given package’s `go.mod` is evaluated during that package’s apply (after clone), not as a spine-wide preflight that aborts all packages before any work.

#### Scenario: One package fails others complete

- **WHEN** package A hard-fails during apply and package B completes successfully
- **THEN** package B still receives a success stdout line and a signed commit when applicable, and the program exits with status `1`

#### Scenario: Only soft skips exit zero

- **WHEN** every selected package is soft-skipped and the spine succeeded
- **THEN** the program exits with status `0`

#### Scenario: Assets publish hard-fail continues siblings

- **WHEN** package A hard-fails on assets release upload and package B uses `GitMvAndManifest` successfully
- **THEN** package B still completes and the program exits with status `1`

#### Scenario: Host Go too old hard-fails one Go package

- **WHEN** package A is `GoVendorAndAssets` and hard-fails because host Go is older than its `go.mod` requirement, and package B is selected and can succeed
- **THEN** package A is logged as an error, package B may still complete, and the program exits with status `1`

## ADDED Requirements

### Requirement: Go version gate is not spine preflight

Spine preflight for `update` SHALL continue to require only that `go` is present on `PATH` when any selected package needs `GoVendorAndAssets`. Preflight SHALL NOT parse remote or local `go.mod` files to enforce a global minimum Go version before package work begins. Per-package host vs `go.mod` checks are defined by the `go-vendor-assets` capability.

#### Scenario: Preflight passes with go on PATH even if later package needs newer Go

- **WHEN** the user runs `update` for a Go package, `go` is on `PATH`, and other Go preflight requirements are met
- **THEN** preflight succeeds even if that package’s upstream `go.mod` will later require a newer Go than the host provides
