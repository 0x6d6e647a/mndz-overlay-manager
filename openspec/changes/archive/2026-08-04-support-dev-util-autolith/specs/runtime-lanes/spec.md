## MODIFIED Requirements

### Requirement: Runtime-lane planning is multi-ecosystem

Runtime-lane planning for `DepsAndAssets` packages SHALL apply to all supported ecosystems (Go, Npm, Bun, Cargo, and Sbcl), not only Go. Operator-facing lane labels SHALL identify the actual runtime package atom for the ecosystem in use (for example `dev-lang/go`, `net-libs/nodejs`, `dev-lang/bun-bin`, the cargo/rust runtime atom used by planning, or `dev-lisp/sbcl`), not a hard-coded Go atom for non-Go packages.

#### Scenario: Npm labels use nodejs atom

- **WHEN** an outdated or update success line is emitted for a `DepsAndAssets Npm` package on a nodejs lane
- **THEN** the label identifies `net-libs/nodejs` (with arch/tier form) rather than `dev-lang/go`

#### Scenario: Sbcl labels use sbcl atom

- **WHEN** an outdated or update success line is emitted for a `DepsAndAssets Sbcl` package on an sbcl lane
- **THEN** the label identifies `dev-lisp/sbcl` (with arch/tier form) rather than `dev-lang/go`

#### Scenario: Cargo planning uses runtime-lane machinery

- **WHEN** a `DepsAndAssets Cargo` package is planned
- **THEN** planning uses the same runtime-lane concepts (ceilings, candidates, lane targets, collapse, zero-PV hard-fail) as other DepsAndAssets ecosystems

### Requirement: Runtime ceiling source per ecosystem

For `DepsAndAssets` planning, the library SHALL compute plain and tilde version ceilings per architecture for the package’s runtime dependency package(s):

- **Go:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lang/go`
- **Npm:** gentoo repository path, package directory `net-libs/nodejs`
- **Bun:** configured overlay path (`mndz-overlay-path`), package directory `dev-lang/bun-bin`
- **Cargo:** gentoo repository path, package directories `dev-lang/rust` and `dev-lang/rust-bin`, combined with U1 max per arch×tier as specified below
- **Sbcl:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lisp/sbcl`

The library SHALL scan non-live ebuilds only (excluding live/`9999` versions). If a required runtime package directory is missing or unreadable, ceiling discovery SHALL fail with an error suitable for the caller.

#### Scenario: Bun ceilings from overlay

- **WHEN** planning a `DepsAndAssets Bun` package and overlay contains `dev-lang/bun-bin` ebuilds
- **THEN** ceilings are computed from those overlay ebuilds, not from gentoo

#### Scenario: Node ceilings from gentoo

- **WHEN** planning a `DepsAndAssets Npm` package
- **THEN** ceilings are computed from gentoo `net-libs/nodejs` non-live ebuilds

#### Scenario: Sbcl ceilings from gentoo

- **WHEN** planning a `DepsAndAssets Sbcl` package
- **THEN** ceilings are computed from gentoo `dev-lisp/sbcl` non-live ebuilds

#### Scenario: Cargo ceilings from rust union

- **WHEN** planning a `DepsAndAssets Cargo` package
- **THEN** ceilings are computed from gentoo `dev-lang/rust` and `dev-lang/rust-bin` non-live ebuilds combined per U1 max

### Requirement: Lane targets from requirement probes

For each runtime lane (arch × plain/tilde) that has a ceiling, the library SHALL select the maximum candidate package PV such that the ecosystem requirement probe for that PV is parseable and the required runtime version is less than or equal to that lane’s ceiling (using the ecosystem’s version comparison rules). For Sbcl, the required runtime version is the floor from `sbcl.version`. A lane with no ceiling or no qualifying candidate SHALL have no target (not a package-wide failure by itself).

#### Scenario: Newer package blocked by ceiling

- **WHEN** candidates include `0.84.0` requiring runtime `1.26.5` and `0.82.0` requiring `1.26.3`, and the amd64 plain ceiling is `1.26.3`
- **THEN** the amd64 plain lane target is `0.82.0` and not `0.84.0`

#### Scenario: Autolith admitted under sbcl ceiling

- **WHEN** candidates include autolith `0.18.0` with `sbcl.version` floor `2.6.4` and the amd64 tilde SBCL ceiling is `2.6.6`
- **THEN** the amd64 tilde lane may select `0.18.0`

#### Scenario: Autolith blocked when floor above ceiling

- **WHEN** a candidate has `sbcl.version` floor `2.7.0` and the lane ceiling is `2.6.6`
- **THEN** that candidate is not selected for that lane solely due to the floor

### Requirement: Lane labels name the runtime package

Lane labels used in outdated and update success lines SHALL include the runtime package atom and arch/tier form, for example `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`, or `(dev-lisp/sbcl ~riscv)`.

#### Scenario: Npm lane label

- **WHEN** an outdated gap is reported for an npm package on the nodejs amd64 tilde lane
- **THEN** the stdout line includes a label identifying `net-libs/nodejs` and `~amd64` (or equivalent agreed formatting consistent with existing Go labels)

#### Scenario: Sbcl lane label

- **WHEN** an outdated gap is reported for an Sbcl package on the sbcl riscv tilde lane
- **THEN** the stdout line includes a label identifying `dev-lisp/sbcl` and `~riscv` (or equivalent agreed formatting consistent with other ecosystems)
