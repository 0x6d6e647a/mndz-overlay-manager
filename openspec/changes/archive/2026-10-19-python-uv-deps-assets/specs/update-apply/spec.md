# Spec Delta

## MODIFIED Requirements

### Requirement: Package policy model

The program SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `DepsAndAssets` with an ecosystem specification (`Go` with optional go.mod subdirectory, `Npm`, `Bun`, `Cargo` with optional lock/package subdirectories, `Sbcl`, or `Uv` with an optional lock subdirectory); or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only. There SHALL NOT be a separate legacy Go-only technique alternative outside `DepsAndAssets`. This capability is the **canonical** home for the full hardcoded package set and techniques; other ecosystem specs SHALL NOT restate a partial policy map as authoritative.

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

#### Scenario: Supported DepsAndAssets Uv technique entry

- **WHEN** policy is looked up for a package configured as `DepsAndAssets Uv` with no lock subdirectory
- **THEN** apply logic receives the `DepsAndAssets` technique with ecosystem `Uv` and the root lock path

#### Scenario: Unsupported technique entry

- **WHEN** policy is looked up for a package configured as `Unsupported` with reason text
- **THEN** apply logic can soft-skip without attempting rename or manifest regeneration

### Requirement: DepsAndAssets is a first-class apply technique

`DepsAndAssets` SHALL be a first-class apply technique for Go, Npm, Bun, Cargo, Sbcl, and Uv ecosystems. Apply SHALL plan via runtime lanes, materialize or reuse distfiles, publish assets on the full path, rewrite overlay ebuilds, verify Manifest digests, and commit per successful PV unit as specified by `deps-assets`, `runtime-lanes`, `go-vendor-assets`, `npm-deps-assets`, `bun-deps-assets`, `cargo-crates-assets`, `sbcl-deps-assets`, and `uv-deps-assets`. Soft-skip solely for “unsupported vendor/deps/crates assets” SHALL NOT apply to packages configured with `DepsAndAssets`.

#### Scenario: DepsAndAssets package is not soft-skipped as unsupported

- **WHEN** apply runs for a package with technique `DepsAndAssets` that needs work
- **THEN** the program does not soft-skip solely because vendor, deps, or crates assets are required

#### Scenario: Uv package is not soft-skipped as unsupported

- **WHEN** apply runs for a `DepsAndAssets Uv` package that needs work
- **THEN** the program does not soft-skip solely because a deps tarball is required

## ADDED Requirements

### Requirement: codex-as-mcp policy entry

The canonical hardcoded policy map SHALL include `dev-util/codex-as-mcp` with GitHub source `kky42/codex-as-mcp`, tag prefix `v`, technique `DepsAndAssets` ecosystem `Uv`, lock at the repository root, and an empty runtime-lane arch allowlist. The package SHALL NOT be an overlay wait-edge provider and SHALL NOT be emerged by the materialize image.

#### Scenario: Policy resolution

- **WHEN** policy is resolved for `dev-util/codex-as-mcp`
- **THEN** the technique is `DepsAndAssets Uv` with no lock subdirectory
- **AND** the source is GitHub `kky42/codex-as-mcp` with tag prefix `v`
- **AND** the arch allowlist is empty

#### Scenario: Target does not select a version

- **WHEN** `outdated` or `update` selects `dev-util/codex-as-mcp`, or the unambiguous bare name `codex-as-mcp`
- **THEN** both tokens resolve to the same inventory key
- **AND** target PVs come from comparable tags and the Python runtime lanes
- **AND** the commands do not interpret a supplied version as a CLI version pin

#### Scenario: Not an image or wait-edge provider

- **WHEN** policy is resolved for `dev-util/codex-as-mcp`
- **THEN** the package is not an overlay wait-edge provider and is not emerged by the materialize image
