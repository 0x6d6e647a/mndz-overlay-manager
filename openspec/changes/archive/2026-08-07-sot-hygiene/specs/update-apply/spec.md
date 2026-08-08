## MODIFIED Requirements

### Requirement: Package policy model

The program SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, `Bun`, `Cargo` with optional lock/package subdirectories, or `Sbcl`); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. There SHALL NOT be a separate legacy Go-only technique alternative outside `DepsAndAssets`. This capability is the **canonical** home for the full hardcoded package set and techniques; other ecosystem specs SHALL NOT restate a partial policy map as authoritative.

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

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay that this manager automates, each with both a source and a technique. At minimum:

- `dev-lang/bun-bin`, `dev-lang/deno-bin`, and `dev-util/grok-build-bin` SHALL use `GitMvAndManifest`
- `dev-db/dolt` (go.mod subdir `go`), `dev-util/beads` (root), `dev-util/crush` (root), and `dev-db/badger` (root) SHALL use `DepsAndAssets` with ecosystem `Go` and their existing GitHub sources (`dolthub/dolt`, `gastownhall/beads`, `charmbracelet/crush`, `dgraph-io/badger` with tag prefix `v`)
- `dev-util/openspec` SHALL use `DepsAndAssets Npm` with its npm source
- `dev-util/ralph-tui` and `dev-util/opencode` SHALL use `DepsAndAssets Bun` with GitHub sources (`subsy/ralph-tui`, `anomalyco/opencode`, tag prefix `v`)
- `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` SHALL use `DepsAndAssets Cargo` with GitHub sources (`jdx` / respective repos / tag prefix `v`); `usage` SHALL use package subdirectory `cli` when required for package metadata
- `dev-util/autolith` SHALL use `DepsAndAssets Sbcl` with GitHub source `luciusmagn/autolith` and tag prefix `v`

The map SHALL NOT include `dev-util/opencode-bin`. No package known solely for cargo CRATES list regeneration SHALL remain `Unsupported` for that reason alone.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/grok-build-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`

#### Scenario: badger is DepsAndAssets Go

- **WHEN** policy is resolved for `dev-db/badger`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go`
- **AND** the source is GitHub `dgraph-io` / `badger` with tag prefix `v`

#### Scenario: openspec is DepsAndAssets Npm

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm`

#### Scenario: opencode is DepsAndAssets Bun

- **WHEN** policy is resolved for `dev-util/opencode`
- **THEN** the technique is `DepsAndAssets Bun`
- **AND** the source is GitHub `anomalyco/opencode` with tag prefix `v`

#### Scenario: mise is DepsAndAssets Cargo

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo`

#### Scenario: usage package subdir

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is `DepsAndAssets Cargo` with package subdirectory `cli`

#### Scenario: autolith is DepsAndAssets Sbcl

- **WHEN** policy is resolved for `dev-util/autolith`
- **THEN** the technique is `DepsAndAssets Sbcl` and the source is GitHub `luciusmagn/autolith` with tag prefix `v`

#### Scenario: opencode-bin is absent

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** no policy entry is returned (unconfigured)

## REMOVED Requirements

### Requirement: Hardcoded policy for dev-util/autolith

**Reason**: Duplicate of the autolith entry and scenario under “Hardcoded policy covers known overlay packages”; single-home avoids drift.

**Migration**: Use the autolith bullets and scenarios in “Hardcoded policy covers known overlay packages”.
