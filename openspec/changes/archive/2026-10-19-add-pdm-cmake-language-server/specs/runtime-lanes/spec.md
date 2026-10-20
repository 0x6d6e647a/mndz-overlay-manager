# Spec Delta

## MODIFIED Requirements

### Requirement: Runtime-lane planning is multi-ecosystem

Runtime-lane planning for `DepsAndAssets` packages SHALL apply to all supported ecosystems (Go, Npm, Bun, Cargo, Sbcl, Uv, and Pdm), not only Go. Operator-facing lane labels SHALL identify the actual runtime package atom for the ecosystem in use (for example `dev-lang/go`, `net-libs/nodejs`, `dev-lang/bun-bin`, the cargo/rust runtime atom used by planning, `dev-lisp/sbcl`, or `dev-lang/python:<slot>`), not a hard-coded Go atom for non-Go packages.

#### Scenario: Npm labels use nodejs atom

- **WHEN** an outdated or update success line is emitted for a `DepsAndAssets Npm` package on a nodejs lane
- **THEN** the label identifies `net-libs/nodejs` (with arch/tier form) rather than `dev-lang/go`

#### Scenario: Cargo planning uses runtime-lane machinery

- **WHEN** a `DepsAndAssets Cargo` package is planned
- **THEN** planning uses the same runtime-lane concepts (ceilings, candidates, lane targets, collapse, zero-PV hard-fail) as other DepsAndAssets ecosystems

#### Scenario: Sbcl labels use sbcl atom

- **WHEN** an outdated or update success line is emitted for a `DepsAndAssets Sbcl` package on an sbcl lane
- **THEN** the label identifies `dev-lisp/sbcl` (with arch/tier form) rather than `dev-lang/go`

#### Scenario: Uv planning uses runtime-lane machinery

- **WHEN** a `DepsAndAssets Uv` package is planned
- **THEN** planning uses ceilings, candidates, lane targets, collapse, and zero-PV hard-fail, with labels that identify `dev-lang/python:<slot>`

#### Scenario: Pdm planning uses runtime-lane machinery

- **WHEN** a `DepsAndAssets Pdm` package is planned
- **THEN** planning uses ceilings, candidates, lane targets, collapse, and zero-PV hard-fail, with labels that identify `dev-lang/python:<slot>`

### Requirement: Runtime ceiling source per ecosystem

For `DepsAndAssets` planning, the library SHALL compute plain and tilde version ceilings per architecture for the package’s runtime dependency package(s):

- **Go:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lang/go`
- **Npm:** gentoo repository path, package directory `net-libs/nodejs`
- **Bun:** configured overlay path (`mndz-overlay-path`), package directory `dev-lang/bun-bin`
- **Cargo:** gentoo repository path, package directories `dev-lang/rust` and `dev-lang/rust-bin`, combined with U1 max per arch×tier as specified below
- **Sbcl:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lisp/sbcl`
- **Uv:** gentoo repository path, package directory `dev-lang/python`. Slot ceilings and the chosen slot atom SHALL follow the Uv slot requirements in this capability
- **Pdm:** gentoo repository path, package directory `dev-lang/python`. Slot ceilings and the chosen slot atom SHALL follow the Pdm slot requirements in this capability

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

#### Scenario: Sbcl ceilings from gentoo

- **WHEN** planning a `DepsAndAssets Sbcl` package
- **THEN** ceilings are computed from gentoo `dev-lisp/sbcl` non-live ebuilds

#### Scenario: Uv ceilings from python slots

- **WHEN** planning a `DepsAndAssets Uv` package
- **THEN** ceilings are computed from non-live gentoo `dev-lang/python` ebuilds as slots, not from profile `PYTHON_TARGETS`

#### Scenario: Pdm ceilings from python slots

- **WHEN** planning a `DepsAndAssets Pdm` package
- **THEN** ceilings are computed from non-live gentoo `dev-lang/python` ebuilds as slots, not from profile `PYTHON_TARGETS`

### Requirement: Plain lane syncs on the ceiling slot

For each architecture, a candidate's plain ceiling SHALL be the newest bare-keyworded slot its `requires-python` admits on that arch. It SHALL qualify only when its synced slot is that ceiling. A bare slot the specifier excludes SHALL NOT be the ceiling. When a newer candidate admits the tree-wide plain ceiling and misses it, and an older candidate hits it, the plain lane SHALL select the older candidate. When every candidate admits that slot and none syncs on it, the plain lane SHALL have no target.

#### Scenario: Newer tag misses the plain ceiling

- **WHEN** a newer candidate requires `>=3.11`, syncs only on slot `3.13`, and an older candidate syncs on slot `3.14`
- **THEN** the amd64 plain lane selects the older candidate at slot `3.14`

#### Scenario: Newer tag needs a newer tilde slot

- **WHEN** a newer candidate syncs only on tilde-only slot `3.15` and an older candidate syncs on plain ceiling slot `3.14`
- **THEN** the amd64 plain lane selects the older candidate at slot `3.14`

#### Scenario: Nothing syncs on the plain ceiling

- **WHEN** every candidate requires `>=3.11`, fails frozen sync on slot `3.14`, and succeeds on slot `3.13`
- **THEN** plain lanes have no target

#### Scenario: Specifier excludes the newer stable slot

- **WHEN** a candidate requires `>=3.8,<3.14`, slot `3.14` is bare on `amd64`, and the recorded sync is slot `3.13`
- **THEN** the amd64 plain lane selects that candidate at slot `3.13`

## ADDED Requirements

### Requirement: Pdm recorded slot follows the specifier

The recorded slot for a Pdm candidate SHALL be the newest inventoried slot that satisfies `requires-python` and has a bare keyword on any arch. When no bare slot satisfies it, the recorded slot SHALL be the newest tilde-keyworded slot that does. The program SHALL NOT run a sync to choose that slot. A slot the specifier excludes SHALL NOT be recorded.

#### Scenario: Upper bound selects the older bare slot

- **WHEN** `requires-python` is `>=3.8,<3.13`, slot `3.13` is bare, and slot `3.12` is bare
- **THEN** the recorded slot is `3.12`

#### Scenario: Ceiling slot is recorded when it satisfies

- **WHEN** `requires-python` is `>=3.8,<3.14` and slot `3.13` is the newest bare slot that satisfies it
- **THEN** the recorded slot is `3.13`

#### Scenario: No satisfying slot

- **WHEN** `requires-python` excludes every inventoried slot
- **THEN** that candidate records no slot and is not selected for a lane

### Requirement: Pdm planning ignores a missing host interpreter

A missing host interpreter for a slot that `requires-python` allows SHALL NOT fail Pdm planning and SHALL NOT be recorded as a rejected slot.

#### Scenario: Host lacks the seed slot

- **WHEN** the specifier allows slot `3.12` and the host has no Python `3.12` interpreter
- **THEN** planning records slot `3.12`
- **AND** planning does not fail because that interpreter is missing

### Requirement: Pdm plain lane uses the admitted ceiling

For each arch, a Pdm candidate's plain ceiling SHALL be the newest slot its `requires-python` admits that has a bare keyword on that arch. The candidate SHALL qualify only when its recorded slot is that ceiling. A newer bare slot the specifier excludes SHALL NOT be that ceiling. When no candidate records its admitted plain ceiling, the plain lane SHALL have no target.

#### Scenario: Upper bound keeps the older stable slot

- **WHEN** `requires-python` is `>=3.8,<3.13`, slots `3.12` and `3.13` are bare on `amd64`, and this is the only candidate
- **THEN** the amd64 plain lane selects that candidate at slot `3.12`

#### Scenario: Excluded newer stable slot stays admissible

- **WHEN** `requires-python` is `>=3.8,<3.14`, slot `3.14` is bare on `amd64`, and the candidate records slot `3.13`
- **THEN** the amd64 plain lane selects that candidate at slot `3.13`

### Requirement: Pdm tilde lane uses the recorded slot

For each arch, a Pdm candidate's tilde ceiling SHALL be the newest slot its `requires-python` admits that has a tilde or bare keyword on that arch. The candidate SHALL qualify when its recorded slot is at or below that ceiling. The lane SHALL select the newest such candidate. The ebuild slot SHALL be that candidate’s recorded slot.

#### Scenario: Tilde lane takes the newer tag

- **WHEN** an older candidate records slot `3.12`, a newer candidate records slot `3.13`, and the newer specifier admits slot `3.13`
- **THEN** tilde lanes select the newer candidate at slot `3.13`

### Requirement: Two Pdm PVs when plain and tilde disagree

When plain lanes and tilde lanes select different Pdm candidate PVs, the planned set SHALL contain both PVs, each with its recorded slot. Both ebuilds SHALL stay tilde-keyworded. Candidates that share a recorded slot SHALL collapse to one PV.

#### Scenario: Shared slot collapses

- **WHEN** the plain lane and the tilde lane both select the newer candidate at slot `3.13`
- **THEN** the planned set contains that one PV at slot `3.13`

#### Scenario: Split keeps both PVs

- **WHEN** the plain lane selects an older candidate at slot `3.13` and the tilde lane selects a newer candidate at slot `3.12`
- **THEN** the planned set contains both PVs

### Requirement: Pdm KEYWORDS follow the chosen slot

Planned KEYWORDS for a Pdm PV SHALL be the tilde form of each arch that the chosen slot keywords and that a lane targeting that PV includes. An empty arch allowlist SHALL NOT add a `-*` token.

#### Scenario: Empty allowlist keeps the slot’s arches

- **WHEN** the allowlist is empty and the chosen slot keywords `amd64` and `arm64`
- **THEN** planned KEYWORDS include `~amd64` and `~arm64` and do not include `-*`

### Requirement: Pdm lane labels name the python slot

Pdm lane labels SHALL include the atom `dev-lang/python:<slot>` and the arch/tier form. One outdated or update line SHALL be emitted per lane that has a gap.

#### Scenario: Slot in the label

- **WHEN** an outdated gap is reported for a Pdm package on the python `3.13` amd64 plain lane
- **THEN** the stdout line includes a label identifying `dev-lang/python:3.13` and `amd64`

#### Scenario: Tilde-only gap names the recorded slot

- **WHEN** an outdated gap is reported for a Pdm package on the python `3.15` amd64 tilde lane and the plain lane has no target
- **THEN** the stdout line includes a label identifying `dev-lang/python:3.15` and `~amd64`
- **AND** no plain-lane line is emitted for that package
