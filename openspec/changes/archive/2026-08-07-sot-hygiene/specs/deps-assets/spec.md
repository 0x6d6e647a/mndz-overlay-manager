## MODIFIED Requirements

### Requirement: DepsAndAssets technique

The program SHALL support an update technique `DepsAndAssets` parameterized by an ecosystem specification that is one of: `Go` with an optional go.mod subdirectory relative to the repository root (unset means root); `Npm` with no extra fields (npm package identity comes from the npm update source); `Bun` (GitHub-sourced, repository-root lockfile); `Cargo` with optional lock and package subdirectories relative to the repository root as specified by the `cargo-crates-assets` capability; or `Sbcl` (GitHub-sourced Autolith-style deps tarball and `sbcl.version` floor as specified by the `sbcl-deps-assets` capability). Apply logic SHALL dispatch materialization, requirement probes, runtime field rendering (`BDEPEND` or `RUST_MIN_VER` or SBCL atoms), and runtime-lane ceiling sources according to the ecosystem.

#### Scenario: Go ecosystem with subdirectory

- **WHEN** policy for `dev-db/dolt` uses `DepsAndAssets` with ecosystem `Go` and subdirectory `go`
- **THEN** Go vendor construction runs in the `go/` directory of the temporary clone

#### Scenario: Npm ecosystem uses UpdateSource identity

- **WHEN** policy for `dev-util/openspec` uses `DepsAndAssets Npm` and source `Npm "@fission-ai/openspec"`
- **THEN** npm pack and registry probes use `@fission-ai/openspec` and asset filenames use overlay package name `openspec`

#### Scenario: Bun ecosystem

- **WHEN** policy for `dev-util/ralph-tui` uses `DepsAndAssets Bun`
- **THEN** apply uses the Bun materializer and bun-bin runtime lanes

#### Scenario: Cargo ecosystem

- **WHEN** policy for `dev-util/hk` uses `DepsAndAssets Cargo`
- **THEN** apply uses the cargo crates materializer and rust runtime lanes

#### Scenario: Sbcl ecosystem

- **WHEN** policy for `dev-util/autolith` uses `DepsAndAssets Sbcl`
- **THEN** apply uses the SBCL/Autolith deps materializer and `dev-lisp/sbcl` runtime lanes

### Requirement: Hardcoded packages use DepsAndAssets

Authoritative technique and source assignments for automated packages SHALL live in `update-apply` (hardcoded policy map). This capability SHALL NOT define a second partial package list. Ecosystem-specific scenarios MAY name packages as examples of technique dispatch without owning the map. Example resolutions below SHALL match the canonical map (including packages previously omitted from this capability’s partial list such as `dev-db/badger` and `dev-util/opencode`).

#### Scenario: openspec technique

- **WHEN** policy is resolved for `dev-util/openspec` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets Npm` and the source is `Npm`

#### Scenario: ralph-tui technique

- **WHEN** policy is resolved for `dev-util/ralph-tui` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets Bun`

#### Scenario: beads technique

- **WHEN** policy is resolved for `dev-util/beads` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and no go.mod subdirectory

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets Cargo`

#### Scenario: autolith technique

- **WHEN** policy is resolved for `dev-util/autolith` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets Sbcl`
