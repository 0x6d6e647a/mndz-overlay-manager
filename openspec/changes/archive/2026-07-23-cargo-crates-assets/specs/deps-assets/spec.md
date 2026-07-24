## MODIFIED Requirements

### Requirement: DepsAndAssets technique

The library SHALL support an update technique `DepsAndAssets` parameterized by an ecosystem specification that is one of: `Go` with an optional go.mod subdirectory relative to the repository root (`Nothing` means root); `Npm` with no extra fields (npm package identity comes from `UpdateSource.Npm`); `Bun` (GitHub-sourced, repository-root lockfile); or `Cargo` with optional lock and package subdirectories relative to the repository root as specified by the `cargo-crates-assets` capability. Apply logic SHALL dispatch materialization, requirement probes, runtime field rendering (`BDEPEND` or `RUST_MIN_VER`), and runtime-lane ceiling sources according to the ecosystem.

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

### Requirement: techniqueNeedsAssets for all ecosystems

The predicate that detects assets-publishing techniques SHALL return true for every `DepsAndAssets` value (Go, Npm, Bun, and Cargo) and SHALL NOT require a separate Go-only constructor.

#### Scenario: Npm needs assets path

- **WHEN** a selected package uses `DepsAndAssets Npm` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth the same way as Go deps packages

#### Scenario: Cargo needs assets path

- **WHEN** a selected package uses `DepsAndAssets Cargo` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth

### Requirement: Distfile naming by ecosystem kind

For a package name PN and version PV (without revision), the program SHALL name Go vendor distfiles `{pn}-{pv}-vendor.tar.xz`, npm/Bun dependency distfiles `{pn}-{pv}-deps.tar.xz`, and Cargo crates distfiles `{pn}-{pv}-crates.tar.xz`. Names SHALL use the overlay package name (PN), never an npm scope segment or a Cargo.toml package name that differs from PN. Release tags SHALL remain `{pn}-{pv}` for all ecosystems.

#### Scenario: openspec deps name

- **WHEN** publishing assets for package `openspec` at PV `1.4.2`
- **THEN** the distfile basename is `openspec-1.4.2-deps.tar.xz`

#### Scenario: crush vendor name unchanged

- **WHEN** publishing assets for package `crush` at PV `0.84.0`
- **THEN** the distfile basename is `crush-0.84.0-vendor.tar.xz`

#### Scenario: mise crates name

- **WHEN** publishing assets for package `mise` at PV `2026.7.5`
- **THEN** the distfile basename is `mise-2026.7.5-crates.tar.xz`

### Requirement: Hardcoded packages use DepsAndAssets

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Go` for `dev-db/dolt` (subdir `go`), `dev-util/beads` (root), and `dev-util/crush` (root); `DepsAndAssets Npm` for `dev-util/openspec` with existing `Npm` source; `DepsAndAssets Bun` for `dev-util/ralph-tui` with existing GitHub source; and `DepsAndAssets Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with existing GitHub sources. Those packages SHALL NOT remain `Unsupported` solely for vendor, deps, or cargo crates assets.

#### Scenario: openspec technique

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm` and the source is `Npm`

#### Scenario: ralph-tui technique

- **WHEN** policy is resolved for `dev-util/ralph-tui`
- **THEN** the technique is `DepsAndAssets Bun`

#### Scenario: beads technique

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and no go.mod subdirectory

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo`
