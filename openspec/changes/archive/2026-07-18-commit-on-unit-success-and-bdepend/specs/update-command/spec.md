## MODIFIED Requirements

### Requirement: Go tree-lane update selection

For packages with technique `GoVendorAndAssets`, `update` SHALL use the Go tree-lane planner to determine target PVs and whether the package needs work. With zero package arguments, `update` SHALL include a Go package when any lane has a gap (missing target PV ebuild, content or Manifest fix needed—including BDEPEND not matching the PV’s known `go.mod` requirement—or exact-set prune required), not only when newest local is less than upstream latest. Explicit targets that are fully satisfied under the plan (including Manifest vendor DIST completeness and BDEPEND match when the go.mod requirement is known) SHALL be soft-skipped.

#### Scenario: Zero-arg update includes multi-lane gap

- **WHEN** the user runs `update` with no package arguments and a Go package has a tree-lane gap
- **THEN** the program still attempts that package’s lane apply work

#### Scenario: Satisfied Go package soft-skipped

- **WHEN** the user runs `update crush` and crush’s package dir already matches the planned unique PV set with correct content (including BDEPEND matching known go.mod requirements) and Manifest vendor entries
- **THEN** the package is soft-skipped without hard-fail

#### Scenario: Incomplete Manifest not soft-skipped

- **WHEN** planned PVs exist with ebuilds but Manifest lacks a vendor DIST for a planned PV
- **THEN** the package is not soft-skipped solely as already matching the plan

#### Scenario: BDEPEND mismatch not soft-skipped

- **WHEN** planned PVs exist with ebuilds, KEYWORDS, SRC_URI, and Manifest vendor DIST adequate, but BDEPEND does not match a known go.mod requirement for a planned PV
- **THEN** the package is not soft-skipped solely as already matching the plan

### Requirement: Hard failures continue others then exit one

Hard per-package or per-unit failures (including dirty involved paths, `ebuild manifest` failure, git commit or signing failure, assets commit/push/release failure, Manifest hash mismatch after vendor publish, host Go older than the package `go.mod` requirement during `GoVendorAndAssets` apply, inability to obtain go.mod when BDEPEND alignment is required, and fetch/compare errors when an update was attempted) SHALL be logged as errors. Other packages SHALL continue. After all selected packages are processed, if any hard failure occurred, the program SHALL exit with status `1`; otherwise exit with status `0` when the spine succeeded. Host Go version sufficiency for a given package’s `go.mod` is evaluated during that package’s apply (after clone on the full path), not as a spine-wide preflight that aborts all packages before any work. When one planned PV unit of a multi-PV Go package succeeds (including its signed overlay commit) and a later unit hard-fails, the program SHALL still exit with status `1` while retaining the successful unit’s commit.

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

#### Scenario: Partial multi-PV still exits one

- **WHEN** a Go package commits one planned PV successfully and hard-fails on a second planned PV
- **THEN** the program exits with status `1` and success stdout may include lines for the committed PV
