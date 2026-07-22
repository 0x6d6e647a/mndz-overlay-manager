## MODIFIED Requirements

### Requirement: Gentoo dev-lang/go ceilings via portageq

The library SHALL resolve the Gentoo repository path by running `portageq get_repo_path / gentoo` (or an equivalent injectable runner). Under that path’s `dev-lang/go` directory, the library SHALL scan non-live `go-*.ebuild` files (excluding `9999` and other live versions) and, for each ebuild, parse PV and KEYWORDS. The library SHALL discover the set of architectures from those KEYWORDS (all arches present on non-live go ebuilds, not only amd64 and arm64) and compute plain and tilde Go version ceilings for each discovered arch:

- plain arch: maximum Go PV among ebuilds whose KEYWORDS include the bare arch token (e.g. `amd64`) and not only the tilde form
- tilde arch: maximum Go PV among ebuilds whose KEYWORDS include `~arch` or the bare arch token

If `portageq` fails or the path/package dir is unreadable, ceiling discovery SHALL fail with an error suitable for the caller. The library SHALL NOT read a config-overridden Portage tree path for this capability. Shared ceiling and lane semantics for non-Go ecosystems are defined by `runtime-lanes`; this requirement remains the Go ceiling source.

#### Scenario: Tilde ceiling at least as new as plain

- **WHEN** gentoo has `go-1.26.3` with KEYWORDS including bare `amd64` and `go-1.26.4` with only `~amd64` among amd64-visible versions
- **THEN** the amd64 plain ceiling is `1.26.3` and the amd64 tilde ceiling is at least `1.26.4`

#### Scenario: Live ebuild ignored

- **WHEN** `go-9999.ebuild` exists alongside versioned go ebuilds
- **THEN** ceiling computation does not use `9999` as a maximum

#### Scenario: portageq failure

- **WHEN** `portageq get_repo_path / gentoo` fails
- **THEN** ceiling discovery reports failure and does not invent ceilings

#### Scenario: Non-amd64-arm64 arch

- **WHEN** non-live go ebuilds include KEYWORDS with an arch other than amd64 and arm64
- **THEN** ceiling discovery includes plain and/or tilde ceilings for that arch

### Requirement: Lane targets from upstream go.mod

For a `DepsAndAssets` Go package, given the Go ceilings for all discovered arches and a list of candidate package versions (non-live overlay PVs union upstream versions newer than max overlay PV, as defined by `runtime-lanes`), the library SHALL determine each lane’s target package PV as the maximum version `v` such that the package’s `go.mod` `go` directive at that version’s tag is parseable and `go_req(v) ≤` that lane’s Go ceiling (using the same Go version comparison rules as host-vs-go.mod gating). The `go.mod` path SHALL honor the package’s configured subdirectory (repository root when unset). Tags with missing or unparseable `go` directives SHALL be skipped for selection. A lane with no ceiling or no qualifying package version SHALL have no target.

#### Scenario: Older PV under plain ceiling

- **WHEN** candidates include `0.82.0` requiring go `1.26.3` and `0.84.0` requiring go `1.26.5`, and the amd64 plain ceiling is `1.26.3`
- **THEN** the `(dev-lang/go amd64)` lane target is `0.82.0` and not `0.84.0`

#### Scenario: Tilde ceiling admits newer PV

- **WHEN** the same versions apply and the amd64 tilde ceiling is `1.26.5` or newer
- **THEN** the `(dev-lang/go ~amd64)` lane target is `0.84.0`

#### Scenario: Subdirectory go.mod

- **WHEN** policy configures go.mod subdirectory `go` (as for dolt)
- **THEN** go_req probes read `go/go.mod` at each candidate tag

### Requirement: Unique ebuild set and KEYWORDS assembly

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV, the planned ebuild KEYWORDS SHALL be assembled **per arch** for every arch that participates in Go runtime lanes from the tiers of lanes that target that PV:

- If at least one **plain** lane for that arch targets the PV, KEYWORDS SHALL include the bare arch token (e.g. `amd64`) and SHALL NOT include `~arch` for that arch.
- Else if at least one **tilde** lane for that arch targets the PV, KEYWORDS SHALL include `~arch` (e.g. `~amd64`).
- Else that arch SHALL be omitted from KEYWORDS.

Bare package KEYWORDS for an arch SHALL be treated as covering both plain and tilde consumers on that arch (no second `~arch` token is required when plain membership is present). When all successful lanes share one PV, the planned set SHALL contain exactly that one PV with the union of per-arch tokens under the rules above. Assembly SHALL NOT be limited to a hard-coded amd64/arm64-only arch set when other arches have lanes.

#### Scenario: Single PV collapse with plain membership

- **WHEN** all successful lanes select package PV `0.84.0` for amd64 and arm64
- **THEN** the planned ebuild set is exactly `{0.84.0}` and KEYWORDS include bare `amd64` and bare `arm64` (and do not require `~amd64` or `~arm64`)

#### Scenario: Arch-divergent PVs with plain membership

- **WHEN** both amd64 lanes (plain and tilde) select `0.84.0` and both arm64 lanes select `0.82.0`
- **THEN** the planned set is `{0.84.0, 0.82.0}` with `0.84.0` KEYWORDS containing bare `amd64` (not requiring `arm64` or `~arm64`) and `0.82.0` KEYWORDS containing bare `arm64` (not requiring `amd64` or `~amd64`)

#### Scenario: Tilde-only membership on one arch

- **WHEN** only the amd64 tilde lane targets PV `0.84.0` and no plain amd64 lane targets that PV
- **THEN** that ebuild’s KEYWORDS include `~amd64` and do not include bare `amd64`

#### Scenario: Staggered plain vs tilde on the same arch family

- **WHEN** amd64 plain targets `0.75.0`, amd64 tilde targets `0.82.0`, and both arm64 lanes target `0.82.0`
- **THEN** `0.75.0` KEYWORDS contain bare `amd64` only (for these arches) and `0.82.0` KEYWORDS contain `~amd64` and bare `arm64`
