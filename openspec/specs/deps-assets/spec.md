## Purpose

Shared `DepsAndAssets` technique for Go vendor and npm/Bun dependency assets: ecosystem specs, distfile naming, materialize/reuse spine, and policy wiring.

## Requirements

### Requirement: DepsAndAssets technique

The library SHALL support an update technique `DepsAndAssets` parameterized by an ecosystem specification that is one of: `Go` with an optional go.mod subdirectory relative to the repository root (`Nothing` means root); `Npm` with no extra fields (npm package identity comes from `UpdateSource.Npm`); or `Bun` (GitHub-sourced, repository-root lockfile). Apply logic SHALL dispatch materialization, requirement probes, BDEPEND rendering, and runtime-lane ceiling sources according to the ecosystem.

#### Scenario: Go ecosystem with subdirectory

- **WHEN** policy for `dev-db/dolt` uses `DepsAndAssets` with ecosystem `Go` and subdirectory `go`
- **THEN** Go vendor construction runs in the `go/` directory of the temporary clone

#### Scenario: Npm ecosystem uses UpdateSource identity

- **WHEN** policy for `dev-util/openspec` uses `DepsAndAssets Npm` and source `Npm "@fission-ai/openspec"`
- **THEN** npm pack and registry probes use `@fission-ai/openspec` and asset filenames use overlay package name `openspec`

#### Scenario: Bun ecosystem

- **WHEN** policy for `dev-util/ralph-tui` uses `DepsAndAssets Bun`
- **THEN** apply uses the Bun materializer and bun-bin runtime lanes

### Requirement: techniqueNeedsAssets for all ecosystems

The predicate that detects assets-publishing techniques SHALL return true for every `DepsAndAssets` value (Go, Npm, and Bun) and SHALL NOT require a separate Go-only constructor.

#### Scenario: Npm needs assets path

- **WHEN** a selected package uses `DepsAndAssets Npm` and will attempt apply work that may publish or reuse assets
- **THEN** preflight and apply treat the package as needing the assets worktree and related auth the same way as Go deps packages

### Requirement: Distfile naming by ecosystem kind

For a package name PN and version PV (without revision), the program SHALL name Go vendor distfiles `{pn}-{pv}-vendor.tar.xz` and npm/Bun dependency distfiles `{pn}-{pv}-deps.tar.xz`. Names SHALL use the overlay package name (PN), never an npm scope segment. Release tags SHALL remain `{pn}-{pv}` for all ecosystems.

#### Scenario: openspec deps name

- **WHEN** publishing assets for package `openspec` at PV `1.4.2`
- **THEN** the distfile basename is `openspec-1.4.2-deps.tar.xz`

#### Scenario: crush vendor name unchanged

- **WHEN** publishing assets for package `crush` at PV `0.84.0`
- **THEN** the distfile basename is `crush-0.84.0-vendor.tar.xz`

### Requirement: Hardcoded packages use DepsAndAssets

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Go` for `dev-db/dolt` (subdir `go`), `dev-util/beads` (root), and `dev-util/crush` (root); `DepsAndAssets Npm` for `dev-util/openspec` with existing `Npm` source; and `DepsAndAssets Bun` for `dev-util/ralph-tui` with existing GitHub source. Those packages SHALL NOT remain `Unsupported` solely for vendor or deps assets. Cargo packages MAY remain `Unsupported`.

#### Scenario: openspec technique

- **WHEN** policy is resolved for `dev-util/openspec`
- **THEN** the technique is `DepsAndAssets Npm` and the source is `Npm`

#### Scenario: ralph-tui technique

- **WHEN** policy is resolved for `dev-util/ralph-tui`
- **THEN** the technique is `DepsAndAssets Bun`

#### Scenario: beads technique

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and no go.mod subdirectory

### Requirement: Non-live local ebuild required

For `DepsAndAssets` plan and apply, the program SHALL require at least one non-live local ebuild for the package. If only live ebuilds exist or the package directory has no versioned non-live ebuild, the program SHALL hard-fail (or fail planning) with a message that first import / empty package dirs are not supported. Live ebuilds SHALL NOT be used as candidates, targets, or apply units.

#### Scenario: Empty package dir hard-fails

- **WHEN** `DepsAndAssets` apply is attempted for a package with no non-live `*.ebuild`
- **THEN** the attempt fails without inventing a first versioned ebuild

### Requirement: Shared materialize spine

For each planned PV that needs work under `DepsAndAssets`, the program SHALL either reuse an existing assets release asset for the expected distfile name or run the ecosystem materializer, publish assets before overlay mutation on the full path, rewrite overlay ebuild content (parameterized assets SRC_URI, planned KEYWORDS, BDEPEND from requirement probe), run `ebuild … manifest`, verify Manifest SHA512 for the distfile against the published or downloaded bytes, and create the signed overlay commit for that unit before the next PV unit. Host language runtime version gates SHALL apply on the full path only and SHALL NOT apply on the reuse path.

#### Scenario: Publish before overlay on full path

- **WHEN** the expected release asset is absent and materialization succeeds
- **THEN** assets commit, push, and release upload complete before the overlay ebuild for that PV is renamed or rewritten

#### Scenario: Reuse skips rebuild

- **WHEN** release tag `{pn}-{pv}` already has the expected vendor or deps asset
- **THEN** apply does not rebuild the tarball and does not create a new release for that tag
