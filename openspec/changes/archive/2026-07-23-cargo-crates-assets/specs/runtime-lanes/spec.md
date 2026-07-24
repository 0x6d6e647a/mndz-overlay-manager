## MODIFIED Requirements

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

## ADDED Requirements

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
