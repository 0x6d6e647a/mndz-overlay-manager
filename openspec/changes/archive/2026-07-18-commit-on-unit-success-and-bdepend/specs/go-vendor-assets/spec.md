## MODIFIED Requirements

### Requirement: Ebuild BDEPEND matches go.mod Go version

When applying overlay ebuild changes for a `GoVendorAndAssets` package after a successful assets publish, on the reuse path, or as part of any overlay mutation that rewrites assets `SRC_URI` or KEYWORDS for a planned PV, the program SHALL ensure the ebuild declares a build dependency atom `>=dev-lang/go-<version>:=` where `<version>` is the `go` directive from that package’s `go.mod` for the tag corresponding to that PV (from the temporary vendor clone on the full path, or from the go.mod probe without a vendor clone on the reuse path and for content-fix planning). The program SHALL insert such a `BDEPEND` if no `dev-lang/go` atom is present, or replace an existing `dev-lang/go` atom so it matches the required version. The program SHALL NOT remove unrelated dependency atoms. The `toolchain` directive in `go.mod`, if present, SHALL NOT be used as the BDEPEND version source.

For planning, content-fix detection, soft-skip “already matches plan,” and outdated adequacy, a local ebuild for a planned PV SHALL be treated as needing a Go BDEPEND content fix when the required `go.mod` version for that PV is known and the ebuild does **not** already contain the exact atom `>=dev-lang/go-<version>:=` (missing atom or different version). Mere presence of any `dev-lang/go` substring SHALL NOT satisfy adequacy when a required version is known. When content-fix or materialization requires BDEPEND alignment and the required `go.mod` version cannot be obtained, the program SHALL hard-fail that PV (or not soft-skip the package as fully matching) rather than silently leaving BDEPEND unchanged.

#### Scenario: Insert BDEPEND when missing

- **WHEN** the ebuild inherits `go-module` and has no `dev-lang/go` BDEPEND atom and `go.mod` requires `go 1.26.5`
- **THEN** after overlay rewrite the ebuild contains `>=dev-lang/go-1.26.5:=` in `BDEPEND`

#### Scenario: Replace outdated Go BDEPEND

- **WHEN** the ebuild has `BDEPEND=">=dev-lang/go-1.24.11:="` (or another older go atom) and `go.mod` requires `go 1.26.5`
- **THEN** after overlay rewrite the go atom is `>=dev-lang/go-1.26.5:=`

#### Scenario: Same PV missing BDEPEND is not a pure soft-skip

- **WHEN** local and remote PV are equal, assets SRC_URI is already parameterized, but the ebuild lacks the required `>=dev-lang/go-…` atom for the cloned or probed `go.mod`
- **THEN** the program does not soft-skip solely for “already at latest” or “already matches plan” and applies a content fix (including `-rN` bump when same-PV rules require it)

#### Scenario: Wrong version BDEPEND is needs-work

- **WHEN** local ebuild for planned PV has parameterized SRC_URI, correct KEYWORDS, and Manifest vendor DIST, but BDEPEND is `>=dev-lang/go-1.24.11:=` while probed `go.mod` requires `go 1.26.5`
- **THEN** the program treats that PV as needing content fix and does not soft-skip solely as already matching the plan

#### Scenario: Probe supplies go.mod for content-fix

- **WHEN** content-fix evaluation runs for a present planned PV and the go.mod probe cache (or equivalent fetch) returns `go 1.26.5` for that PV’s tag
- **THEN** adequacy of BDEPEND is judged against `1.26.5` without requiring a vendor clone solely for the content-fix decision

### Requirement: Manifest incompleteness is needs-work

For a planned `GoVendorAndAssets` PV that already has a local non-live ebuild, the program SHALL treat the PV as still needing materialization (not fully satisfied / not soft-skippable solely for “already matches plan”) when the package `Manifest` lacks a DIST entry for `{pn}-{pv}-vendor.tar.xz`, in addition to content-fix rules for assets SRC_URI parameterization, **BDEPEND matching the PV’s go.mod requirement when known**, and planned KEYWORDS. Soft-skip of a package as fully matching the tree-lane plan SHALL require that every planned PV is present with adequate ebuild content (including correct Go BDEPEND when the requirement is known) **and** a Manifest vendor DIST entry for that PV’s vendor tarball name.

#### Scenario: Good ebuild missing vendor Manifest is not pure soft-skip

- **WHEN** local ebuild for planned PV `0.84.0` has parameterized assets SRC_URI, correct BDEPEND, and correct KEYWORDS, but Manifest has no DIST line for `crush-0.84.0-vendor.tar.xz`
- **THEN** the program does not soft-skip the package solely as “already matches Go tree-lane plan” and still schedules materialization for that PV

#### Scenario: Complete PV set with Manifest is soft-skippable

- **WHEN** every planned PV has a local ebuild with adequate content (including BDEPEND matching the known go.mod requirement) and Manifest contains the corresponding vendor DIST lines
- **THEN** the package may soft-skip as already matching the plan (subject to prune-only extras rules)

#### Scenario: Mismatched BDEPEND alone prevents soft-skip

- **WHEN** every planned PV has ebuild, KEYWORDS, SRC_URI, and Manifest vendor DIST adequate except BDEPEND does not match the known go.mod requirement for at least one planned PV
- **THEN** the package is not soft-skipped solely as already matching the plan

### Requirement: Manifest SHA512 matches generated vendor hash

After a successful `ebuild … manifest` for a Go package PV unit, the program SHALL parse the package `Manifest` for the vendor distfile `{pn}-{pv}-vendor.tar.xz` and compare its SHA512 digest to the SHA512 computed for the tarball that was published or reused. On mismatch the PV unit SHALL hard-fail and the program SHALL warn that assets may already have been published. On match the unit SHALL proceed to the immediate signed overlay commit for that unit’s paths (commit-on-unit-success).

#### Scenario: Matching digests succeed

- **WHEN** Manifest SHA512 for the vendor distfile equals the published or reused tarball’s SHA512
- **THEN** the PV unit may proceed to signed overlay commit success

#### Scenario: Mismatch hard-fails with assets warning

- **WHEN** Manifest SHA512 differs from the generated or downloaded tarball SHA512
- **THEN** the PV unit is a hard failure and a warning indicates assets were published or reused while overlay update did not complete successfully

## ADDED Requirements

### Requirement: Overlay commit after each successful Go PV unit

After a `GoVendorAndAssets` planned PV successfully completes overlay ebuild mutation, `ebuild … manifest`, and vendor SHA512 verification (full or reuse path), the program SHALL create the signed overlay commit for that unit before materializing the next planned PV for the same package. The commit SHALL use message `category/package: version` with the written ebuild version string (without leading `v`). The program SHALL NOT leave that unit’s paths uncommitted solely to batch multiple PVs into a later barrier.

#### Scenario: Sequential PVs each committed before next

- **WHEN** two distinct planned PVs need materialization and both succeed
- **THEN** the first PV’s overlay commit exists in HEAD before the second PV’s dirty check and mutation begin
