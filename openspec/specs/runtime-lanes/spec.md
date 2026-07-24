## Purpose

Generalized runtime-lane planning: ceilings from all arches on a runtime package, candidate selection, KEYWORDS assembly, labels, and exact-set prune for `DepsAndAssets` packages.

## Requirements

### Requirement: Runtime ceiling source per ecosystem

For `DepsAndAssets` planning, the library SHALL compute plain and tilde version ceilings per architecture for the package’s runtime dependency package(s):

- **Go:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lang/go`
- **Npm:** gentoo repository path, package directory `net-libs/nodejs`
- **Bun:** configured overlay path (`mndz-overlay-path`), package directory `dev-lang/bun-bin`
- **Cargo:** gentoo repository path, package directories `dev-lang/rust` and `dev-lang/rust-bin`, combined with U1 max per arch×tier as specified below

The library SHALL scan non-live ebuilds only (excluding live/`9999` versions). If a required runtime package directory is missing or unreadable, ceiling discovery SHALL fail with an error suitable for the caller.

#### Scenario: Bun ceilings from overlay

- **WHEN** planning a `DepsAndAssets Bun` package and overlay contains `dev-lang/bun-bin` ebuilds
- **THEN** ceilings are computed from those overlay ebuilds, not from gentoo

#### Scenario: Node ceilings from gentoo

- **WHEN** planning a `DepsAndAssets Npm` package
- **THEN** ceilings are computed from gentoo `net-libs/nodejs` non-live ebuilds

#### Scenario: Cargo ceilings from rust union

- **WHEN** planning a `DepsAndAssets Cargo` package
- **THEN** ceilings are computed from gentoo `dev-lang/rust` and `dev-lang/rust-bin` non-live ebuilds combined per U1 max

### Requirement: Arches discovered from runtime KEYWORDS

The library SHALL derive the set of architectures from KEYWORDS fields of non-live runtime ebuilds: each token is normalized by stripping a leading `~` to obtain an arch name; the token `-*` SHALL NOT be treated as an arch. For each discovered arch, the library SHALL compute a plain ceiling (maximum runtime PV among ebuilds whose KEYWORDS include the bare arch token) and a tilde ceiling (maximum runtime PV among ebuilds whose KEYWORDS include `~arch` or the bare arch). The library SHALL NOT hard-code a closed set of only `amd64` and `arm64` when other arches appear on the runtime package.

#### Scenario: Additional arch on nodejs

- **WHEN** gentoo `net-libs/nodejs` non-live ebuilds include KEYWORDS with `~loong` (or bare `loong`) among other arches
- **THEN** planning includes a loong plain and/or tilde lane according to those KEYWORDS

#### Scenario: Tilde-only runtime package

- **WHEN** overlay `dev-lang/bun-bin` has only `~amd64` and `~arm64` (no bare arch tokens)
- **THEN** plain ceilings for those arches are absent and tilde ceilings may still produce lane targets

### Requirement: Candidate versions overlay union newer

Given at least one non-live local ebuild for the package, the library SHALL form the candidate PV set as: all non-live local package PVs, union all comparable upstream package versions that are strictly greater than the maximum non-live local PV. The library SHALL NOT automatically include upstream versions older than every local non-live PV solely to satisfy a ceiling. Live ebuilds SHALL NOT contribute local PVs.

#### Scenario: Local plus newer only

- **WHEN** overlay has non-live PV `1.4.1` and upstream has `1.4.0`, `1.4.1`, `1.5.0`, and `1.6.0`
- **THEN** candidates include `1.4.1`, `1.5.0`, and `1.6.0` and do not require `1.4.0`

#### Scenario: No non-live local

- **WHEN** the package has no non-live local ebuild
- **THEN** candidate formation fails planning for `DepsAndAssets` without inventing a bootstrap set

### Requirement: Lane targets from requirement probes

For each runtime lane (arch × plain/tilde) that has a ceiling, the library SHALL select the maximum candidate package PV such that the ecosystem requirement probe for that PV is parseable and the required runtime version is less than or equal to that lane’s ceiling (using the ecosystem’s version comparison rules). A lane with no ceiling or no qualifying candidate SHALL have no target (not a package-wide failure by itself).

#### Scenario: Newer package blocked by ceiling

- **WHEN** candidates include `0.84.0` requiring runtime `1.26.5` and `0.82.0` requiring `1.26.3`, and the amd64 plain ceiling is `1.26.3`
- **THEN** the amd64 plain lane target is `0.82.0` and not `0.84.0`

### Requirement: Collapse KEYWORDS across all runtime arches

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV and each arch that appears in any lane definition for the runtime, planned KEYWORDS SHALL include bare `arch` if any plain lane for that arch targets the PV; else `~arch` if any tilde lane for that arch targets the PV; else omit that arch. Bare membership covers plain and tilde consumers for that arch.

#### Scenario: Multi-arch single PV

- **WHEN** all lanes that have targets select package PV `1.6.0` across amd64 and arm64
- **THEN** the planned ebuild set is `{1.6.0}` with KEYWORDS including the assembled amd64 and arm64 tokens for those lanes

### Requirement: Zero planned PVs hard-fails

When every lane has no target (or no planned unique PV remains), `DepsAndAssets` planning SHALL hard-fail the package with an error that planning produced no ebuild targets. Individual empty lanes alongside at least one successful lane target SHALL NOT alone hard-fail the package.

#### Scenario: Some lanes empty still plan

- **WHEN** only tilde amd64 has a target PV and plain amd64 has none
- **THEN** the plan may contain that PV with tilde-only amd64 KEYWORDS membership

#### Scenario: No targets at all

- **WHEN** no lane obtains a target PV
- **THEN** planning fails for the package

### Requirement: Lane labels name the runtime package

Lane labels used in outdated and update success lines SHALL include the runtime package atom and arch/tier form, for example `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, or `(dev-lang/bun-bin ~arm64)`.

#### Scenario: Npm lane label

- **WHEN** an outdated gap is reported for an npm package on the nodejs amd64 tilde lane
- **THEN** the stdout line includes a label identifying `net-libs/nodejs` and `~amd64` (or equivalent agreed formatting consistent with existing Go labels)

### Requirement: Cargo U1 max ceiling union

For Cargo runtime lanes, for each architecture and keyword tier (plain/tilde), the library SHALL set the lane ceiling to the maximum of the plain or tilde tip (as applicable) from `dev-lang/rust` and from `dev-lang/rust-bin` when both exist for that lane; if only one package contributes a tip for that lane, that tip SHALL be used. The library SHALL NOT use the minimum of the two packages as the ceiling.

#### Scenario: rust-bin ahead on amd64 plain

- **WHEN** gentoo `dev-lang/rust` plain amd64 tip is `1.95.0` and `dev-lang/rust-bin` plain amd64 tip is `1.96.1`
- **THEN** the cargo amd64 plain ceiling is `1.96.1`

### Requirement: Cargo lane labels name the union runtime

Lane labels for Cargo packages SHALL identify the union runtime id `dev-lang/rust|rust-bin` (or an equivalent fixed spelling documented in operator-facing help) together with the arch/tier form, for example `(dev-lang/rust|rust-bin amd64)` or `(dev-lang/rust|rust-bin ~arm64)`.

#### Scenario: Cargo outdated label

- **WHEN** an outdated gap is reported for a cargo package on the rust amd64 tilde lane
- **THEN** the stdout line includes a label identifying `dev-lang/rust|rust-bin` and `~amd64` (or equivalent agreed formatting consistent with other ecosystems)

### Requirement: Cargo MSRV as lane requirement

For Cargo packages, the requirement used when selecting the maximum candidate PV under a lane ceiling SHALL be the MSRV determined by the `cargo-crates-assets` capability (normalized three-component version). A candidate PV whose MSRV is greater than the lane ceiling SHALL NOT be selected for that lane.

#### Scenario: High MSRV blocked by ceiling

- **WHEN** candidates include PV `A` requiring rust `1.96.0` and PV `B` requiring `1.91.0`, and the amd64 plain ceiling is `1.95.0`
- **THEN** the amd64 plain lane target is not `A` solely due to MSRV, and may be `B` if `B` is otherwise eligible

### Requirement: Exact-set package directory for DepsAndAssets

When applying a runtime-lane plan, after all planned target PVs for that apply attempt have been successfully materialized, the program SHALL ensure the package directory contains exactly those non-live versioned ebuilds for the package name and SHALL remove other non-live versioned ebuilds not in the planned set. Live ebuilds, if present, SHALL be left untouched. The program SHALL NOT prune when a planned target failed to materialize if pruning would drop a tip without its replacement.

#### Scenario: Converge deletes extras

- **WHEN** the package dir has two non-live ebuilds and the plan is a single successful PV
- **THEN** after apply only that planned non-live ebuild remains
