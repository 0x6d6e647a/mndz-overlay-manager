## MODIFIED Requirements

### Requirement: Package policy model

The library SHALL model a package policy that binds a package key `category/package` to an update source and an update technique. The technique SHALL be one of: `GitMvAndManifest`; `GoVendorAndAssets` with an optional go.mod subdirectory; or `Unsupported` with a human-readable reason. Policy lookup SHALL use a hardcoded map only.

#### Scenario: Supported GitMv technique entry

- **WHEN** policy is looked up for a package configured as `GitMvAndManifest` with a GitHub source
- **THEN** apply logic receives both the source (for version fetch) and the `GitMvAndManifest` technique

#### Scenario: Supported GoVendor technique entry

- **WHEN** policy is looked up for a package configured as `GoVendorAndAssets` with a go.mod subdirectory option
- **THEN** apply logic receives both the source and the `GoVendorAndAssets` technique including the subdirectory option

#### Scenario: Unsupported technique entry

- **WHEN** policy is looked up for a package configured as `Unsupported` with reason text
- **THEN** apply logic can soft-skip without attempting rename or manifest regeneration

### Requirement: Hardcoded policy covers known overlay packages

The hardcoded policy map SHALL include an entry for every package known to ship in the mndz overlay at the time of this change, each with both a source and a technique. At minimum, `dev-lang/bun-bin`, `dev-lang/deno-bin`, `dev-util/grok-build-bin`, and `dev-util/opencode-bin` SHALL use `GitMvAndManifest`. At minimum, `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush` SHALL use `GoVendorAndAssets`. Packages that still require npm deps tarballs or cargo CRATES regeneration SHALL use `Unsupported`.

#### Scenario: Simple binary package is GitMvAndManifest

- **WHEN** policy is resolved for `dev-util/opencode-bin`
- **THEN** the technique is `GitMvAndManifest`

#### Scenario: Go package is GoVendorAndAssets

- **WHEN** policy is resolved for `dev-util/beads`
- **THEN** the technique is `GoVendorAndAssets`

#### Scenario: Cargo package is Unsupported

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `Unsupported`

### Requirement: Parallel work then serial signed commits

Package check, dirty verification, vendor construction, ebuild rename/rewrite, and `ebuild … manifest` work SHALL be allowed to run concurrently across packages, except that assets-repository git commit, push, and GitHub release publish for a shared assets worktree SHALL be mutually excluded. Overlay git index mutations (`git add` and `git commit`) SHALL be serialized with mutual exclusion. The program SHALL finish all successful package apply work before starting the overlay commit phase (barrier). The overlay commit phase SHALL run only when at least one package succeeded in apply. Overlay commits SHALL be ordered by `category/package` sort order. Each overlay and assets commit SHALL sign with GPG (`git commit` with signing enabled); the program SHALL NOT create unsigned commits as a fallback. The program SHALL NOT read or store the GPG passphrase; it SHALL rely on gpg-agent and pinentry.

#### Scenario: No successes skips commit phase

- **WHEN** every package is soft-skipped or hard-fails before a successful apply
- **THEN** the program creates no overlay git commits and does not need to prompt for GPG for overlay commits

#### Scenario: Isolated paths per overlay commit

- **WHEN** two packages A and B both apply successfully
- **THEN** each resulting overlay commit includes only paths belonging to that package

#### Scenario: Signing failure is hard failure

- **WHEN** git commit signing fails for a package
- **THEN** that package is recorded as a hard failure and the program does not leave an unsigned commit for it as success

#### Scenario: Assets publish serialized

- **WHEN** two packages need assets publish concurrently
- **THEN** only one package at a time performs assets commit, push, and release on the shared assets worktree

## ADDED Requirements

### Requirement: GoVendorAndAssets is a first-class apply technique

Apply dispatch SHALL invoke the Go vendor and assets publish pipeline for packages with technique `GoVendorAndAssets` instead of soft-skipping them as unsupported. Behavior of that pipeline is defined by the `go-vendor-assets` and `assets-publish` capabilities.

#### Scenario: Outdated Go package is not soft-skipped as unsupported

- **WHEN** `dev-util/crush` is outdated and policy technique is `GoVendorAndAssets`
- **THEN** the program attempts the Go vendor assets apply path rather than soft-skipping with an unsupported reason

### Requirement: Assets publish failure does not cancel sibling packages

A hard failure during assets commit, push, or release for one package SHALL NOT abort in-progress or pending apply attempts for other packages. Only that package’s overlay mutation SHALL be skipped.

#### Scenario: One assets failure others continue

- **WHEN** package A fails assets push and package B is still applying
- **THEN** package B may still complete successfully and the program continues until all selected packages are processed
