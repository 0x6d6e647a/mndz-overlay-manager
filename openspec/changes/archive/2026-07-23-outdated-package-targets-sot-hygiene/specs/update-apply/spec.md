## RENAMED Requirements

- FROM: `### Requirement: GoVendorAndAssets is a first-class apply technique`
- TO: `### Requirement: DepsAndAssets is a first-class apply technique`

- FROM: `### Requirement: GoVendorAndAssets multi-lane apply`
- TO: `### Requirement: DepsAndAssets multi-lane apply`

## MODIFIED Requirements

### Requirement: Package policy model

The library SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, `Bun`, or `Cargo` with optional lock/package subdirectories); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. There SHALL NOT be a separate `GoVendorAndAssets` technique alternative.

#### Scenario: Supported GitMv technique entry

- **WHEN** policy is looked up for a package configured as `GitMvAndManifest` with a GitHub source
- **THEN** apply logic receives both the source (for version fetch) and the `GitMvAndManifest` technique

#### Scenario: Supported DepsAndAssets Go technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets` with ecosystem `Go` and a go.mod subdirectory option
- **THEN** apply logic receives both the source and the `DepsAndAssets` technique including the Go subdirectory option

#### Scenario: Supported DepsAndAssets Npm technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets Npm`
- **THEN** apply logic receives the `DepsAndAssets` technique with ecosystem `Npm`

#### Scenario: Supported DepsAndAssets Cargo technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets Cargo`
- **THEN** apply logic receives the `DepsAndAssets` technique with ecosystem `Cargo`

#### Scenario: Unsupported technique entry

- **WHEN** policy is looked up for a package configured as `Unsupported` with reason text
- **THEN** apply logic can soft-skip without attempting rename or manifest regeneration

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/opencode-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `DepsAndAssets` with ecosystem `Go`. At minimum, `dev-util/openspec` SHALL use `DepsAndAssets Npm` and `dev-util/ralph-tui` SHALL use `DepsAndAssets Bun`. At minimum, `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets` with ecosystem `Cargo`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`

#### Scenario: openspec is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm`

#### Scenario: mise is DepsAndAssets Cargo

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo`

### Requirement: Dirty involved paths block package update

Before mutating an apply unit, the program SHALL check that the unit’s involved paths are clean relative to git HEAD (not modified or staged with uncommitted changes). For `GitMvAndManifest`, involved paths are the newest ebuild file and the package `Manifest`. For each `DepsAndAssets` planned PV unit, involved paths are the template or target ebuild path for that PV and the package `Manifest`. If any involved path is dirty, the unit SHALL hard-fail without mutating. Dirtiness of unrelated paths SHALL NOT fail the unit. After a prior unit in the same package has successfully committed, dirt from that unit SHALL NOT remain uncommitted and therefore SHALL NOT cause the next unit’s dirty check to fail solely due to that prior unit’s work.

#### Scenario: Dirty Manifest fails package

- **WHEN** the package `Manifest` has uncommitted modifications before a unit starts
- **THEN** the update unit hard-fails and the ebuild is not renamed or rewritten

#### Scenario: Unrelated dirty file does not fail package

- **WHEN** only a different package’s files are dirty
- **THEN** dirty checks for the current unit still pass

#### Scenario: Prior committed PV does not dirty-fail next PV

- **WHEN** a DepsAndAssets package materializes planned PV `0.82.0` successfully (including its signed overlay commit) and then materializes planned PV `0.84.0` on a tree with no foreign dirt
- **THEN** the dirty check for `0.84.0` passes even though `0.82.0` updated the shared `Manifest` earlier in the same `update` run

### Requirement: DepsAndAssets is a first-class apply technique

`DepsAndAssets` SHALL be a first-class apply technique for Go, Npm, Bun, and Cargo ecosystems. Apply SHALL plan via runtime lanes, materialize or reuse distfiles, publish assets on the full path, rewrite overlay ebuilds, verify Manifest digests, and commit per successful PV unit as specified by `deps-assets`, `runtime-lanes`, `go-vendor-assets`, `npm-deps-assets`, `bun-deps-assets`, and `cargo-crates-assets`. Soft-skip solely for “unsupported vendor/deps/crates assets” SHALL NOT apply to packages configured with `DepsAndAssets`.

#### Scenario: DepsAndAssets package is not soft-skipped as unsupported

- **WHEN** apply runs for a package with technique `DepsAndAssets` that needs work
- **THEN** the program does not soft-skip solely because vendor, deps, or crates assets are required

### Requirement: DepsAndAssets multi-lane apply

For packages with technique `DepsAndAssets`, apply SHALL use the runtime-lane planner for the package’s ecosystem to obtain the planned set of PVs and KEYWORDS, materialize each PV that needs work (full or reuse path), commit each successful unit before the next, and perform exact-set prune of non-live ebuilds after all planned PVs succeed. Multi-PV ordering and failure isolation SHALL match multi-unit behavior (later unit failure does not roll back earlier committed units).

#### Scenario: Multiple planned PVs

- **WHEN** the plan contains two distinct PVs that both need materialization and both succeed
- **THEN** the first PV’s overlay commit exists in HEAD before the second PV’s mutation begins

### Requirement: GitMvAndManifest leaves other versions

`GitMvAndManifest` apply behavior for non-selected ebuild versions in the package directory SHALL leave other non-selected versions in place. Exact-set pruning applies only to `DepsAndAssets` runtime-lane apply.

#### Scenario: Binary update does not delete siblings

- **WHEN** a `GitMvAndManifest` package directory has two ebuild versions and newest is renamed to a new remote PV
- **THEN** the non-selected older ebuild is left in place by that technique
