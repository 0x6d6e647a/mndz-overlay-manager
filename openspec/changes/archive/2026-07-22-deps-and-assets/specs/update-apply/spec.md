## MODIFIED Requirements

### Requirement: Package policy model

The library SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, or `Bun`); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. The former technique constructor `GoVendorAndAssets` SHALL NOT remain as a distinct technique alternative.

#### Scenario: Supported GitMv technique entry

- **WHEN** policy is looked up for a package configured as `GitMvAndManifest` with a GitHub source
- **THEN** apply logic receives both the source (for version fetch) and the `GitMvAndManifest` technique

#### Scenario: Supported DepsAndAssets Go technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets` with ecosystem `Go` and a go.mod subdirectory option
- **THEN** apply logic receives both the source and the `DepsAndAssets` technique including the Go subdirectory option

#### Scenario: Supported DepsAndAssets Npm technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets Npm`
- **THEN** apply logic receives the `DepsAndAssets` technique with ecosystem `Npm`

#### Scenario: Unsupported technique entry

- **WHEN** policy is looked up for a package configured as `Unsupported` with reason text
- **THEN** apply logic can soft-skip without attempting rename or manifest regeneration

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay at the time of this change, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/opencode-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `DepsAndAssets` with ecosystem `Go`. At minimum, `dev-util/openspec` SHALL use `DepsAndAssets Npm` and `dev-util/ralph-tui` SHALL use `DepsAndAssets Bun`. Packages that still require cargo CRATES regeneration SHALL use `Unsupported`.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`

#### Scenario: openspec is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm`

#### Scenario: Cargo package is Unsupported

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `Unsupported`

### Requirement: GoVendorAndAssets is a first-class apply technique

`DepsAndAssets` SHALL be a first-class apply technique for Go, Npm, and Bun ecosystems. Apply SHALL plan via runtime lanes, materialize or reuse distfiles, publish assets on the full path, rewrite overlay ebuilds, verify Manifest digests, and commit per successful PV unit as specified by `deps-assets`, `runtime-lanes`, `go-vendor-assets`, `npm-deps-assets`, and `bun-deps-assets`. Soft-skip solely for “unsupported vendor/deps assets” SHALL NOT apply to packages configured with `DepsAndAssets`.

#### Scenario: DepsAndAssets package is not soft-skipped as unsupported

- **WHEN** apply runs for a package with technique `DepsAndAssets` that needs work
- **THEN** the program does not soft-skip solely because vendor or deps assets are required

### Requirement: GoVendorAndAssets multi-lane apply

For packages with technique `DepsAndAssets`, apply SHALL use the runtime-lane planner for the package’s ecosystem to obtain the planned set of PVs and KEYWORDS, materialize each PV that needs work (full or reuse path), commit each successful unit before the next, and perform exact-set prune of non-live ebuilds after all planned PVs succeed. Multi-PV ordering and failure isolation SHALL match existing Go multi-unit behavior (later unit failure does not roll back earlier committed units).

#### Scenario: Multiple planned PVs

- **WHEN** the plan contains two distinct PVs that both need materialization and both succeed
- **THEN** the first PV’s overlay commit exists in HEAD before the second PV’s mutation begins
