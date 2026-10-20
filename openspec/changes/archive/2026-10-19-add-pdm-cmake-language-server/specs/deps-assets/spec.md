# Spec Delta

## MODIFIED Requirements

### Requirement: DepsAndAssets technique

The program SHALL support an update technique `DepsAndAssets` parameterized by an ecosystem specification that is one of: `Go` with an optional go.mod subdirectory relative to the repository root (unset means root); `Npm` with no extra fields (npm package identity comes from the npm update source); `Bun` (GitHub-sourced, repository-root lockfile); `Cargo` with optional lock and package subdirectories relative to the repository root as specified by the `cargo-crates-assets` capability; `Sbcl` (GitHub-sourced Autolith-style deps tarball and `sbcl.version` floor as specified by the `sbcl-deps-assets` capability); `Uv` with an optional `uv.lock` subdirectory relative to the repository root (unset means root) as specified by the `uv-deps-assets` capability; or `Pdm` with an optional `pdm.lock` subdirectory relative to the repository root (unset means root) as specified by the `pdm-deps-assets` capability. Apply logic SHALL dispatch materialization, requirement probes, runtime field rendering (`BDEPEND` or `RUST_MIN_VER` or SBCL atoms or the Python slot atom), and runtime-lane ceiling sources according to the ecosystem.

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

#### Scenario: Uv ecosystem

- **WHEN** policy for `dev-util/codex-as-mcp` uses `DepsAndAssets Uv` with no lock subdirectory
- **THEN** apply uses the Uv materializer and `dev-lang/python` runtime lanes

#### Scenario: Pdm ecosystem

- **WHEN** policy for `dev-util/cmake-language-server` uses `DepsAndAssets Pdm` with no lock subdirectory
- **THEN** apply uses the Pdm materializer and `dev-lang/python` runtime lanes

### Requirement: techniqueNeedsAssets for all ecosystems

The predicate that detects assets-publishing techniques SHALL return true for every `DepsAndAssets` value (Go, Npm, Bun, Cargo, Sbcl, Uv, and Pdm) and SHALL NOT require a separate Go-only constructor.

#### Scenario: Npm needs assets path

- **WHEN** a selected package uses `DepsAndAssets Npm` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth the same way as Go deps packages

#### Scenario: Cargo needs assets path

- **WHEN** a selected package uses `DepsAndAssets Cargo` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth

#### Scenario: Sbcl needs assets path

- **WHEN** a selected package uses `DepsAndAssets Sbcl` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth

#### Scenario: Uv needs assets path

- **WHEN** a selected package uses `DepsAndAssets Uv` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth

#### Scenario: Pdm needs assets path

- **WHEN** a selected package uses `DepsAndAssets Pdm` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth

### Requirement: Distfile naming by ecosystem kind

For a package name PN and version PV (without revision), the program SHALL name Go vendor distfiles `{pn}-{pv}-vendor.tar.xz`, npm/Bun dependency distfiles `{pn}-{pv}-deps.tar.xz`, Cargo crates distfiles `{pn}-{pv}-crates.tar.xz`, Sbcl/Autolith dependency distfiles `{pn}-{pv}-deps.tar.xz`, Uv dependency distfiles `{pn}-{pv}-deps.tar.xz`, and Pdm dependency distfiles `{pn}-{pv}-deps.tar.xz`. Names SHALL use the overlay package name (PN), never an npm scope segment or a Cargo.toml package name that differs from PN. Release tags SHALL remain `{pn}-{pv}` for all ecosystems.

#### Scenario: openspec deps name

- **WHEN** publishing assets for package `openspec` at PV `1.4.2`
- **THEN** the distfile basename is `openspec-1.4.2-deps.tar.xz`

#### Scenario: crush vendor name unchanged

- **WHEN** publishing assets for package `crush` at PV `0.84.0`
- **THEN** the distfile basename is `crush-0.84.0-vendor.tar.xz`

#### Scenario: mise crates name

- **WHEN** publishing assets for package `mise` at PV `2026.7.5`
- **THEN** the distfile basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: autolith deps name

- **WHEN** publishing assets for package `autolith` at PV `0.18.0`
- **THEN** the distfile basename is `autolith-0.18.0-deps.tar.xz`

#### Scenario: Uv deps name

- **WHEN** publishing assets for package `codex-as-mcp` at PV `2026.2.2.1`
- **THEN** the distfile basename is `codex-as-mcp-2026.2.2.1-deps.tar.xz`

#### Scenario: Pdm deps name

- **WHEN** publishing assets for package `cmake-language-server` at PV `0.1.10`
- **THEN** the distfile basename is `cmake-language-server-0.1.10-deps.tar.xz`

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

#### Scenario: codex-as-mcp technique

- **WHEN** policy is resolved for `dev-util/codex-as-mcp` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets` with ecosystem `Uv` and no lock subdirectory

#### Scenario: cmake-language-server technique

- **WHEN** policy is resolved for `dev-util/cmake-language-server` (as defined by `update-apply`)
- **THEN** the technique is `DepsAndAssets` with ecosystem `Pdm` and no lock subdirectory
