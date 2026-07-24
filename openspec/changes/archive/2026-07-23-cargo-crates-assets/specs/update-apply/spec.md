## MODIFIED Requirements

### Requirement: Package policy model

The library SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, `Bun`, or `Cargo` with optional lock/package subdirectories); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. The former technique constructor `GoVendorAndAssets` SHALL NOT remain as a distinct technique alternative.

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

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay at the time of this change, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/opencode-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `DepsAndAssets` with ecosystem `Go`. At minimum, `dev-util/openspec` SHALL use `DepsAndAssets Npm` and `dev-util/ralph-tui` SHALL use `DepsAndAssets Bun`. At minimum, `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets` with ecosystem `Cargo`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone.

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
