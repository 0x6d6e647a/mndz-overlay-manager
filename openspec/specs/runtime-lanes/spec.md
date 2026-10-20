## Purpose

Generalized runtime-lane planning: ceilings from all arches on a runtime package, candidate selection, KEYWORDS assembly, labels, and exact-set prune for `DepsAndAssets` packages.

## Requirements

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

### Requirement: Policy arch allowlist for lane participation

`DepsAndAssets` policy MAY restrict which runtime architectures participate in lane planning and KEYWORDS collapse. When an allowlist is set, the planner SHALL create lanes only for those arches (plain and tilde still follow the runtime package’s KEYWORDS on those arches). Arches outside the allowlist SHALL NOT receive lane targets, SHALL NOT appear in planned KEYWORDS, and SHALL NOT contribute ceilings to harvest-versus-ceiling checks. When no allowlist is set, all arches discovered on the runtime package remain in the lane set.

When an allowlist is set, planned KEYWORDS for each unique PV SHALL be `-*` plus the tilde tokens for allowlisted arches that have a target (`KEYWORDS="-* ~amd64"` when only amd64 is allowed and targeted). Packages without an allowlist SHALL NOT gain a `-*` token solely from this requirement.

Policy for `dev-util/codex` SHALL allowlist `amd64` only.

#### Scenario: Codex plans amd64 only

- **WHEN** `dev-util/codex` is planned and gentoo rust/rust-bin also keyword `arm64`
- **THEN** no arm64 lane target is produced
- **AND** planned KEYWORDS are `-* ~amd64` and do not include `~arm64`

#### Scenario: Harvest ceiling ignores non-allowlisted arches

- **WHEN** a Codex full-path unit’s harvest floor is below the amd64 rust ceiling and above some rust-bin arm64 ceiling
- **THEN** harvest-versus-ceiling does not hard-fail solely because of the arm64 ceiling

#### Scenario: hk still uses every rust arch

- **WHEN** `dev-util/hk` is planned
- **THEN** lane participation still includes every arch present on `dev-lang/rust` ∪ `dev-lang/rust-bin`
- **AND** planned KEYWORDS do not include `-*` solely from this requirement

### Requirement: claude-agent-acp nodejs lanes are amd64 only

Policy for `dev-util/claude-agent-acp` SHALL allowlist `amd64` only. When that package is planned, the planner SHALL create nodejs lanes only for amd64. When amd64 has a target, planned `KEYWORDS` SHALL be `-* ~amd64`. Arches outside the allowlist SHALL NOT receive lane targets and SHALL NOT appear in planned `KEYWORDS`.

#### Scenario: arm64 nodejs is excluded

- **WHEN** `dev-util/claude-agent-acp` is planned and gentoo `net-libs/nodejs` also keywords `arm64`
- **THEN** no arm64 lane target is produced
- **AND** planned `KEYWORDS` are `-* ~amd64` and do not include `~arm64`

### Requirement: codex-acp nodejs lanes are amd64 only

Policy for `dev-util/codex-acp` SHALL allowlist `amd64` only. When that package is planned, the planner SHALL create nodejs lanes only for amd64. When amd64 has a target, planned `KEYWORDS` SHALL be `-* ~amd64`. Arches outside the allowlist SHALL NOT receive lane targets and SHALL NOT appear in planned `KEYWORDS`.

#### Scenario: arm64 nodejs is excluded

- **WHEN** `dev-util/codex-acp` is planned and gentoo `net-libs/nodejs` also keywords `arm64`
- **THEN** no arm64 lane target is produced
- **AND** planned `KEYWORDS` are `-* ~amd64` and do not include `~arm64`

### Requirement: Zero planned PVs hard-fails

When every lane has no target (or no planned unique PV remains), `DepsAndAssets` planning SHALL hard-fail the package with an error that planning produced no ebuild targets. Individual empty lanes alongside at least one successful lane target SHALL NOT alone hard-fail the package.

#### Scenario: Some lanes empty still plan

- **WHEN** only tilde amd64 has a target PV and plain amd64 has none
- **THEN** the plan may contain that PV with tilde-only amd64 KEYWORDS membership

#### Scenario: No targets at all

- **WHEN** no lane obtains a target PV
- **THEN** planning fails for the package

### Requirement: Lane labels name the runtime package

Lane labels used in outdated and update success lines SHALL include the runtime package atom and arch/tier form, for example `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`, or `(dev-lisp/sbcl ~riscv)`.

#### Scenario: Npm lane label

- **WHEN** an outdated gap is reported for an npm package on the nodejs amd64 tilde lane
- **THEN** the stdout line includes a label identifying `net-libs/nodejs` and `~amd64` (or equivalent agreed formatting consistent with existing Go labels)

#### Scenario: Sbcl lane label

- **WHEN** an outdated gap is reported for an Sbcl package on the sbcl riscv tilde lane
- **THEN** the stdout line includes a label identifying `dev-lisp/sbcl` and `~riscv` (or equivalent agreed formatting consistent with other ecosystems)

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

When applying a runtime-lane plan, after all planned target PVs for that apply attempt have been successfully materialized, the program SHALL retain every non-live versioned ebuild whose PV is in the planned unique set. The program SHALL remove other non-live versioned ebuilds **except** those `overlay-atom-closure` reverse-dep keep requires. Live ebuilds, if present, SHALL be left untouched. The program SHALL NOT prune when a planned target failed to materialize if pruning would drop a tip without its replacement. Reverse-dep keep SHALL NOT change which PVs the runtime-lane planner selects.

#### Scenario: Converge deletes extras

- **WHEN** the package dir has two non-live ebuilds and the plan is a single successful PV and no remaining consumer ebuild requires the extra PV
- **THEN** after apply only that planned non-live ebuild remains

#### Scenario: Reverse-dep keep retains an unplanned PV

- **WHEN** the package dir has `6.6.1` and `6.8.0`, the plan unique set is `{6.8.0}`, and a remaining overlay consumer ebuild requires `=dev-util/usage-6.6.1`
- **THEN** after apply both `6.6.1` and `6.8.0` remain

### Requirement: Overlay ceilings rediscovered after provider commit

When `update` re-plans a `DepsAndAssets` consumer after its overlay ceiling-provider package has a successful signed overlay commit in the same run, as specified by `overlay-apply-waves`, ceiling discovery for that ecosystem SHALL read the committed overlay provider package directory (non-live ebuilds) at re-plan time. The program SHALL NOT reuse a start-of-run overlay ceiling snapshot for that re-plan. Gentoo-sourced ceilings (Go, Npm, Cargo, Sbcl) are unchanged by overlay GitMv and SHALL NOT require mid-run rediscovery solely because an overlay Bun provider committed.

#### Scenario: Bun re-plan sees new overlay ebuild

- **WHEN** `dev-lang/bun-bin` is committed from PV `1.2.0` to `1.3.0` in the same `update` and `dev-util/ralph-tui` is then re-planned
- **THEN** ralph-tui Bun lane ceilings include `1.3.0` from the overlay bun-bin directory
- **AND** the re-plan does not keep the start-of-run `1.2.0` ceiling solely because ceilings were already discovered earlier in the process

### Requirement: Cargo incomplete tag coverage is not a parseable requirement

For `DepsAndAssets Cargo`, a candidate whose tag-floor discovery is incomplete as specified by `cargo-crates-assets` SHALL NOT be a parseable runtime requirement. Lane selection SHALL skip that candidate the same way it skips an unparseable `go.mod`, and SHALL NOT substitute `"0.0.0"` for incompleteness. A later complete candidate MAY still fill the lane. Complete discovery with no declared rust-version MAY still use the selection-only `"0.0.0"` fallback. Operational fetch or parse failure SHALL still fail planning rather than skip the candidate.

#### Scenario: Incomplete newest candidate is skipped

- **WHEN** the newest Cargo candidate is incomplete because an in-tree path dependency Cargo.toml is missing, and an older candidate completes with tag floor `1.85.0` under the lane ceiling
- **THEN** that lane may select the older candidate and SHALL NOT select the incomplete newest PV as requirement `0.0.0`

#### Scenario: Complete absence still uses the zero fallback

- **WHEN** a Cargo candidate’s active local set is fully resolved and no package declares rust-version
- **THEN** lane selection MAY use `0.0.0` for that candidate

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
