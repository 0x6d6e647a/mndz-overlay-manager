## ADDED Requirements

### Requirement: Gentoo dev-lang/go ceilings via portageq

The library SHALL resolve the Gentoo repository path by running `portageq get_repo_path / gentoo` (or an equivalent injectable runner). Under that path’s `dev-lang/go` directory, the library SHALL scan non-live `go-*.ebuild` files (excluding `9999` and other live versions) and, for each ebuild, parse PV and KEYWORDS. The library SHALL compute four Go version ceilings for arches `amd64` and `arm64` and keyword tiers plain vs tilde:

- plain arch: maximum Go PV among ebuilds whose KEYWORDS include the bare arch token (e.g. `amd64`) and not only the tilde form
- tilde arch: maximum Go PV among ebuilds whose KEYWORDS include `~arch` or the bare arch token

If `portageq` fails or the path/package dir is unreadable, ceiling discovery SHALL fail with an error suitable for the caller. The library SHALL NOT read a config-overridden Portage tree path for this capability.

#### Scenario: Tilde ceiling at least as new as plain

- **WHEN** gentoo has `go-1.26.3` with KEYWORDS including bare `amd64` and `go-1.26.4` with only `~amd64` among amd64-visible versions
- **THEN** the amd64 plain ceiling is `1.26.3` and the amd64 tilde ceiling is at least `1.26.4`

#### Scenario: Live ebuild ignored

- **WHEN** `go-9999.ebuild` exists alongside versioned go ebuilds
- **THEN** ceiling computation does not use `9999` as a maximum

#### Scenario: portageq failure

- **WHEN** `portageq get_repo_path / gentoo` fails
- **THEN** ceiling discovery reports failure and does not invent ceilings

### Requirement: Lane targets from upstream go.mod

For a `GoVendorAndAssets` package, given the four Go ceilings and a list of comparable upstream package versions (after configured tag-prefix strip), the library SHALL determine each lane’s target package PV as the maximum version `v` such that the package’s `go.mod` `go` directive at that version’s tag is parseable and `go_req(v) ≤` that lane’s Go ceiling (using the same Go version comparison rules as host-vs-go.mod gating). The `go.mod` path SHALL honor the package’s configured subdirectory (repository root when unset). Tags with missing or unparseable `go` directives SHALL be skipped for selection. A lane with no ceiling or no qualifying package version SHALL have no target.

#### Scenario: Older PV under plain ceiling

- **WHEN** upstream versions include `0.82.0` requiring go `1.26.3` and `0.84.0` requiring go `1.26.5`, and the amd64 plain ceiling is `1.26.3`
- **THEN** the `(dev-lang/go amd64)` lane target is `0.82.0` and not `0.84.0`

#### Scenario: Tilde ceiling admits newer PV

- **WHEN** the same versions apply and the amd64 tilde ceiling is `1.26.5` or newer
- **THEN** the `(dev-lang/go ~amd64)` lane target is `0.84.0`

#### Scenario: Subdirectory go.mod

- **WHEN** policy configures go.mod subdirectory `go` (as for dolt)
- **THEN** go_req probes read `go/go.mod` at each candidate tag

### Requirement: Unique ebuild set and KEYWORDS assembly

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV, the planned ebuild KEYWORDS SHALL be the space-separated list of `~arch` for every arch (`amd64`, `arm64`) that has at least one lane targeting that PV. KEYWORDS SHALL NOT use bare stable arch tokens without a tilde. When all successful lanes share one PV, the planned set SHALL contain exactly that one PV with the union of needed `~arch` tokens.

#### Scenario: Single PV collapse

- **WHEN** all four lanes select package PV `0.84.0`
- **THEN** the planned ebuild set is exactly `{0.84.0}` and KEYWORDS include both `~amd64` and `~arm64` when both arches have targets

#### Scenario: Arch-divergent PVs

- **WHEN** amd64 lanes select `0.84.0` and arm64 lanes select `0.82.0`
- **THEN** the planned set is `{0.84.0, 0.82.0}` with `0.84.0` KEYWORDS containing `~amd64` (not requiring `~arm64`) and `0.82.0` KEYWORDS containing `~arm64`

#### Scenario: At most four ebuilds

- **WHEN** all four lanes select pairwise distinct package PVs
- **THEN** the planned set contains four PVs

### Requirement: Exact-set package directory

When applying a Go tree-lane plan for a package, after all planned target PVs for that apply attempt have been successfully materialized (ebuild content and required assets for those PVs), the program SHALL ensure the package directory contains exactly those versioned ebuilds for the package name (non-live), and SHALL remove other non-live versioned ebuilds for that package that are not in the planned set. The program SHALL NOT leave older historical versioned ebuilds that are outside the planned set. Live/`9999` ebuilds, if present, SHALL be left untouched. The program SHALL NOT prune away existing ebuilds if a planned target PV failed to materialize in that attempt when pruning would drop a tip without its replacement.

#### Scenario: Converge deletes extras

- **WHEN** the package dir has `crush-0.80.0.ebuild` and `crush-0.82.0.ebuild` and the plan is a single PV `0.84.0` which is successfully applied
- **THEN** after apply the only non-live crush ebuild is `crush-0.84.0.ebuild`

#### Scenario: No prune on failed target

- **WHEN** the plan requires PV `0.84.0` and materializing that PV hard-fails
- **THEN** the program does not delete the only remaining older ebuild solely to force an empty package dir

### Requirement: Lane labels

Go tree-lane user-visible lines SHALL use exactly these labels for the four lanes: `(dev-lang/go amd64)`, `(dev-lang/go ~amd64)`, `(dev-lang/go arm64)`, and `(dev-lang/go ~arm64)`.

#### Scenario: Label tokens

- **WHEN** a report line is emitted for the amd64 tilde lane
- **THEN** the line includes the substring `(dev-lang/go ~amd64)`
