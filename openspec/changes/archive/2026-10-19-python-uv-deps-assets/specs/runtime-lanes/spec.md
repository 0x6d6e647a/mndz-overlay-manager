# Spec Delta

## MODIFIED Requirements

### Requirement: Runtime-lane planning is multi-ecosystem

Runtime-lane planning for `DepsAndAssets` packages SHALL apply to all supported ecosystems (Go, Npm, Bun, Cargo, Sbcl, and Uv), not only Go. Operator-facing lane labels SHALL identify the actual runtime package atom for the ecosystem in use (for example `dev-lang/go`, `net-libs/nodejs`, `dev-lang/bun-bin`, the cargo/rust runtime atom used by planning, `dev-lisp/sbcl`, or `dev-lang/python:<slot>`), not a hard-coded Go atom for non-Go packages.

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

### Requirement: Runtime ceiling source per ecosystem

For `DepsAndAssets` planning, the library SHALL compute plain and tilde version ceilings per architecture for the package’s runtime dependency package(s):

- **Go:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lang/go`
- **Npm:** gentoo repository path, package directory `net-libs/nodejs`
- **Bun:** configured overlay path (`mndz-overlay-path`), package directory `dev-lang/bun-bin`
- **Cargo:** gentoo repository path, package directories `dev-lang/rust` and `dev-lang/rust-bin`, combined with U1 max per arch×tier as specified below
- **Sbcl:** gentoo repository path via `portageq get_repo_path / gentoo`, package directory `dev-lisp/sbcl`
- **Uv:** gentoo repository path, package directory `dev-lang/python`. Slot ceilings and the chosen slot atom SHALL follow the Uv slot requirements in this capability

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

### Requirement: Collapse KEYWORDS across all runtime arches

The planner SHALL collapse lane targets to the set of unique package PVs. For each unique PV and each arch that appears in any lane definition for the runtime, planned KEYWORDS SHALL include that arch when any plain or tilde lane for that arch targets the PV; else omit that arch.

For **all** `DepsAndAssets` ecosystems (Go, Cargo, npm, Bun, Sbcl, Uv, and any other ecosystem that uses this collapse path), every included arch token SHALL be the **tilde** form (`~arch`). Plain versus tilde lanes affect which PV is selected and which arches appear, not bare versus tilde stability marking on the overlay ebuild. Bare arch tokens SHALL NOT appear in planned KEYWORDS.

This matches mndz-overlay policy (GURU-aligned): overlay packages are testing-only; there is no arch-team stabilization. Runtime plain/tilde ceilings remain as defined elsewhere in this capability for candidate selection only.

#### Scenario: Multi-arch single PV

- **WHEN** all lanes that have targets select package PV `1.6.0` across amd64 and arm64
- **THEN** the planned ebuild set is `{1.6.0}` with KEYWORDS including `~amd64` and `~arm64` and not bare `amd64` or bare `arm64`

#### Scenario: Plain lane does not emit bare arch

- **WHEN** only the plain amd64 lane targets package PV `0.84.0` (any ecosystem using this collapse)
- **THEN** planned KEYWORDS for that PV include `~amd64` and do not include bare `amd64`

#### Scenario: Cargo plain membership still tilde

- **WHEN** plain and tilde rust lanes both target the same Cargo package PV on amd64
- **THEN** planned KEYWORDS include `~amd64` and do not include bare `amd64`

#### Scenario: Uv plain membership still tilde

- **WHEN** a plain python lane targets a Uv package PV on amd64
- **THEN** planned KEYWORDS include `~amd64` and do not include bare `amd64`

## ADDED Requirements

### Requirement: Uv ceilings are Python slots

For each architecture, the Uv plain ceiling SHALL be the newest `dev-lang/python` slot that has a bare keyword on that arch, and the tilde ceiling SHALL be the newest slot that has a tilde or bare keyword on that arch. Ceilings SHALL use non-live ebuilds only. The planner SHALL NOT read `PYTHON_TARGETS` or `PYTHON_SINGLE_TARGET`. A `PYVER=$(ver_cut 1-2)` ebuild SHALL use its first two version components as the slot. A `PYVER="$(ver_cut 2-3)t"` ebuild SHALL NOT be a ceiling slot.

#### Scenario: Stable slot is the plain ceiling

- **WHEN** slot `3.14` has a bare `amd64` keyword and slot `3.15` is tilde-only on `amd64`
- **THEN** the amd64 plain ceiling slot is `3.14` and the amd64 tilde ceiling slot is `3.15`

#### Scenario: PYVER assignment is the slot

- **WHEN** version `3.14.7` sets `PYVER=$(ver_cut 1-2)`, `SLOT="${PYVER}"`, and a bare `amd64` keyword
- **THEN** that ebuild contributes slot `3.14` with a bare `amd64` keyword

#### Scenario: Free-threaded PYVER is not a ceiling

- **WHEN** version `0.3.14.7` sets `PYVER="$(ver_cut 2-3)t"`
- **THEN** that ebuild does not contribute a ceiling slot

#### Scenario: Profile target is not the selector

- **WHEN** `PYTHON_TARGETS` names `python3_14` and a newer slot has a bare keyword
- **THEN** the plain ceiling follows that newer bare-keyworded slot

### Requirement: Uv probe is a frozen sync on allowed slots

Planning SHALL probe a Uv candidate with `uv sync --frozen` on slots its `requires-python` specifier allows, comparing slot `major.minor`. Order SHALL be newest satisfying bare-keyworded slot first, then newest satisfying tilde-only slot. The probe SHALL stop at the first success and SHALL record that one slot. An unreadable specifier SHALL NOT be probed. The program SHALL NOT run `uv lock`.

#### Scenario: Newest bare success stops the probe

- **WHEN** `requires-python` is `>=3.11`, slots `3.14` and `3.13` have bare keywords, and frozen sync succeeds on `3.14`
- **THEN** the recorded success is slot `3.14`
- **AND** slot `3.13` is not probed

#### Scenario: Bare failure continues to the next bare slot

- **WHEN** frozen sync fails on slot `3.14` and succeeds on slot `3.13`
- **THEN** the recorded success is slot `3.13`
- **AND** a newer tilde-only slot is not probed

#### Scenario: Tilde-only slot after every bare slot fails

- **WHEN** no satisfying bare slot syncs and frozen sync succeeds on tilde-only slot `3.15`
- **THEN** the recorded success is slot `3.15`

#### Scenario: Floor above the plain ceiling

- **WHEN** a candidate requires `>=3.15` and the amd64 plain ceiling slot is `3.14`
- **THEN** that candidate is not selected for the amd64 plain lane

#### Scenario: Upper bound excludes the slot

- **WHEN** a candidate requires `>=3.8,<3.14` and the only inventoried slots are `3.14` and `3.15`
- **THEN** that candidate is not selected for any lane

### Requirement: Missing Python interpreter hard-fails the probe

A missing interpreter for a slot that is about to be probed SHALL hard-fail planning. A non-zero sync when that interpreter exists SHALL reject the slot, and the probe SHALL continue. A missing interpreter SHALL NOT be recorded as a failed sync.

#### Scenario: Missing interpreter is not a rejection

- **WHEN** the interpreter for a probed slot is not installed
- **THEN** planning fails
- **AND** that slot is not treated as a failed sync

### Requirement: Plain lane syncs on the ceiling slot

A Uv candidate SHALL qualify for a plain lane only when that lane’s plain ceiling slot satisfies `requires-python` and is the slot whose frozen sync succeeded. When a newer candidate does not and an older candidate does, the plain lane SHALL select the older candidate. When no candidate syncs on the plain ceiling slot, the plain lane SHALL have no target.

#### Scenario: Newer tag misses the plain ceiling

- **WHEN** a newer candidate syncs only on slot `3.13` and an older candidate syncs on plain ceiling slot `3.14`
- **THEN** the amd64 plain lane selects the older candidate at slot `3.14`

#### Scenario: Newer tag needs a newer tilde slot

- **WHEN** a newer candidate syncs only on tilde-only slot `3.15` and an older candidate syncs on plain ceiling slot `3.14`
- **THEN** the amd64 plain lane selects the older candidate at slot `3.14`

#### Scenario: Nothing syncs on the plain ceiling

- **WHEN** every candidate fails frozen sync on plain ceiling slot `3.14` and succeeds on slot `3.13`
- **THEN** plain lanes have no target

### Requirement: Tilde lane uses a synced slot at or below the ceiling

A Uv candidate SHALL qualify for a tilde lane when some slot at or below that lane’s tilde ceiling satisfies `requires-python` and is a slot whose frozen sync succeeded. The lane SHALL select the newest such candidate. The ebuild slot SHALL be the slot chosen for that candidate.

#### Scenario: Tilde lane takes the newer tag the plain lane skipped

- **WHEN** a newer candidate syncs on slot `3.13` or on slot `3.15` and an older candidate syncs on slot `3.14`
- **THEN** tilde lanes select the newer candidate

#### Scenario: Both tags share a slot below the plain ceiling

- **WHEN** both candidates sync only on slot `3.13`
- **THEN** tilde lanes select the newer candidate at slot `3.13`

### Requirement: One chosen Python slot per PV

For a selected Uv PV, the ebuild slot SHALL be the newest slot that satisfies `requires-python`, whose frozen sync succeeded, and that has a bare keyword on any arch. When no such slot exists, the slot SHALL be the newest tilde-keyworded slot whose frozen sync succeeded and that satisfies the specifier. The ebuild SHALL name that one slot. The planner SHALL NOT emit one ebuild for every slot in the specifier’s range. A slot the specifier excludes SHALL NOT be chosen.

#### Scenario: Bare slot wins when it syncs

- **WHEN** `requires-python` is `>=3.11`, frozen sync succeeds on slot `3.14`, and slot `3.15` is tilde-only
- **THEN** the chosen slot is `3.14`

#### Scenario: Older bare slot when the stable slot does not sync

- **WHEN** `requires-python` is `>=3.11`, frozen sync fails on slot `3.14`, and frozen sync succeeds on slot `3.13`
- **THEN** the chosen slot is `3.13`

#### Scenario: Tilde fallback when no bare slot syncs

- **WHEN** `requires-python` is `>=3.15` and only slot `3.15` syncs
- **THEN** the chosen slot is `3.15` and plain lanes have no target from that candidate

### Requirement: Two Uv PVs when plain and tilde disagree

When plain lanes and tilde lanes select different candidate PVs, the planned set SHALL contain both PVs, each with its own chosen slot. That split SHALL include a newer candidate that syncs only on an older slot than the plain ceiling, and a newer candidate that syncs only on a newer tilde-only slot. Candidates that share a chosen slot SHALL collapse to one PV per the usual maximum-candidate rule. Both ebuilds SHALL stay tilde-keyworded.

#### Scenario: Downward split

- **WHEN** an older candidate syncs on slot `3.14` and a newer candidate syncs only on slot `3.13`, and both allow `>=3.11`
- **THEN** plain lanes select the older candidate at slot `3.14`
- **AND** tilde lanes select the newer candidate at slot `3.13`

#### Scenario: Upward split

- **WHEN** an older candidate syncs on slot `3.14` and a newer candidate syncs only on slot `3.15`, and both allow `>=3.11`
- **THEN** plain lanes select the older candidate at slot `3.14`
- **AND** tilde lanes select the newer candidate at slot `3.15`

#### Scenario: Specifier split still produces two ebuilds

- **WHEN** an older candidate requires `>=3.11` and syncs on slot `3.14`, and a newer candidate requires `>=3.15` and syncs on slot `3.15`
- **THEN** plain lanes select the older candidate at slot `3.14`
- **AND** tilde lanes select the newer candidate at slot `3.15`

#### Scenario: Shared slot collapses

- **WHEN** both candidates sync only on slot `3.13`
- **THEN** the planned set contains one PV, the newer candidate, at slot `3.13`

### Requirement: Uv KEYWORDS follow the chosen slot

Planned KEYWORDS for a Uv PV SHALL be the tilde form of each arch that the chosen slot keywords and that a lane targeting that PV includes. An empty arch allowlist SHALL NOT add a `-*` token.

#### Scenario: Empty allowlist keeps the slot’s arches

- **WHEN** the allowlist is empty and the chosen slot keywords the full python arch set
- **THEN** planned KEYWORDS list each of those arches in tilde form and do not include `-*`

### Requirement: Uv lane labels name the python slot

Uv lane labels SHALL include the atom `dev-lang/python:<slot>` and the arch/tier form. One outdated or update line SHALL be emitted per lane that has a gap.

#### Scenario: Slot in the label

- **WHEN** an outdated gap is reported for a Uv package on the python 3.14 amd64 plain lane
- **THEN** the stdout line includes a label identifying `dev-lang/python:3.14` and `amd64`

#### Scenario: Tilde-only gap names the synced slot

- **WHEN** an outdated gap is reported for a Uv package on the python 3.13 amd64 tilde lane and the plain lane has no target
- **THEN** the stdout line includes a label identifying `dev-lang/python:3.13` and `~amd64`
- **AND** no plain-lane line is emitted for that package
