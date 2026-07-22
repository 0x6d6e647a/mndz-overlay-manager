# assets-publish Specification

## Purpose

Shared mndz-overlay-assets checksum sidecars, git commit/push, and GitHub release upload for vendor/deps distfiles.

## Requirements

### Requirement: Checksum sidecars use basename only

When writing operator checksum files for a published distfile, the program SHALL compute SHA-256, SHA-512, and BLAKE3-256 digests in a single streaming pass over the file and write three sidecars named `{distfile}.sha256`, `{distfile}.sha512`, and `{distfile}.b3`. Each file SHALL contain one line of the form `{lowercase-hex}  {basename}` where `{basename}` is the distfile name without directory components.

#### Scenario: Sidecar line format

- **WHEN** hashing `crush-0.76.0-vendor.tar.xz`
- **THEN** the `.sha512` file content uses the tarball basename only (not an absolute path) after two spaces following the hex digest

#### Scenario: Three algorithms produced

- **WHEN** hashing completes for a vendor tarball
- **THEN** `.sha256`, `.sha512`, and `.b3` sidecars all exist for that tarball name

### Requirement: Assets repository layout

Checksum sidecars SHALL be written under the assets worktree at `{category}/{package}/{distfile}.{sha256,sha512,b3}` matching existing mndz-overlay-assets layout. Historical sidecars for older versions SHALL be left in place; new versions add new files.

#### Scenario: Path for dolt vendor hashes

- **WHEN** publishing `dolt-2.1.7-vendor.tar.xz` for `dev-db/dolt`
- **THEN** sidecars are created under `dev-db/dolt/` in the configured assets worktree

### Requirement: Signed assets commit and push

After writing sidecars for a package version, the program SHALL create a GPG-signed git commit in the assets worktree that stages only those new/changed sidecar paths, with commit message `category/package: version` (version without leading `v`), then `git push` to the worktree’s configured remote. Push failure SHALL be a hard failure for that package’s update attempt. The program SHALL NOT leave a successful package apply that depends on unpublished assets.

#### Scenario: Commit message matches overlay style

- **WHEN** assets commit is created for `dev-util/beads` at `1.0.5`
- **THEN** the commit message is exactly `dev-util/beads: 1.0.5`

#### Scenario: Push required

- **WHEN** the signed assets commit succeeds but `git push` fails
- **THEN** the package update hard-fails and overlay mutation for that package does not proceed

### Requirement: GitHub release with tarball asset

After a successful assets push, the program SHALL create a GitHub release on the assets repository via the HTTP API with:

- `tag_name` = `{pn}-{pv}`
- `name` = `{category}/{pn}-{pv}`
- `body` = `category/package: version` (same text as the assets commit message)
- release asset = the vendor (or deps) tarball file

The program SHALL upload the tarball as a release asset. API or upload failure SHALL hard-fail the package.

#### Scenario: Release metadata for crush

- **WHEN** publishing version `0.77.0` of `dev-util/crush`
- **THEN** the release tag is `crush-0.77.0`, the release name is `dev-util/crush-0.77.0`, and the body is `dev-util/crush: 0.77.0`

#### Scenario: Asset filename

- **WHEN** the release is created for a Go vendor tarball
- **THEN** the uploaded asset name is `{pn}-{pv}-vendor.tar.xz`

### Requirement: Assets critical section across packages

When multiple packages publish to the same assets worktree concurrently, git index mutations, commits, pushes, and release creation for that worktree SHALL be mutually excluded so only one package holds the assets critical section at a time. Tarball builds outside the critical section MAY still run in parallel.

#### Scenario: Two Go packages do not interleave assets git

- **WHEN** two `GoVendorAndAssets` packages finish tarballs at the same time
- **THEN** their assets commit/push/release steps do not interleave on the shared assets worktree

### Requirement: Forward-compatible publish API

Assets hashing, worktree commit/push, and release upload SHALL accept a distfile path and package coordinates (`category`, `package`, version, asset filename) without assuming Go-only filename suffixes in the core publish helpers, so future npm/bun `-deps.tar.xz` publishers can reuse the same path.

#### Scenario: Non-vendor filename accepted by layout helper

- **WHEN** a caller requests sidecar paths for `openspec-1.4.2-deps.tar.xz` under `dev-util/openspec`
- **THEN** the layout helper returns paths under `dev-util/openspec/` for that basename

### Requirement: Lookup release by tag and download named asset

The assets/release client SHALL support (via injectable operations suitable for tests) looking up a GitHub release on the assets repository by tag name and, when the release exists, locating an asset by exact filename and downloading its bytes to a caller-chosen path. Lookup SHALL use the configured assets owner/repo and the same authentication token rules as release create when the repository or API requires it. Absence of the release or of the named asset SHALL be reported as a distinct not-found outcome (not as a generic hard failure that implies publish failure).

#### Scenario: Release and asset found

- **WHEN** the assets repo has release tag `beads-1.0.5` with asset `beads-1.0.5-vendor.tar.xz`
- **THEN** lookup by that tag and filename succeeds and download writes the asset body to the requested path

#### Scenario: Missing tag is not-found

- **WHEN** no release exists for tag `beads-9.9.9`
- **THEN** lookup reports not-found without creating a release

#### Scenario: Tag exists but wrong asset name is not-found

- **WHEN** release `crush-0.84.0` exists but has no asset named `crush-0.84.0-vendor.tar.xz`
- **THEN** lookup for that exact asset name reports not-found

### Requirement: Deps distfile release assets

When publishing an npm or Bun dependency tarball, the GitHub release asset filename SHALL be `{pn}-{pv}-deps.tar.xz` (overlay package name and PV without revision). Checksum sidecars, assets-repo layout paths, release tag `{pn}-{pv}`, and commit message `category/package: version` SHALL use the same rules as vendor distfiles. Core publish helpers SHALL accept the deps basename without assuming a `-vendor` suffix.

#### Scenario: openspec release asset name

- **WHEN** publishing version `1.4.2` of package name `openspec`
- **THEN** the uploaded release asset name is `openspec-1.4.2-deps.tar.xz` and the release tag is `openspec-1.4.2`

#### Scenario: Lookup deps asset by name

- **WHEN** release `ralph-tui-0.12.0` has asset `ralph-tui-0.12.0-deps.tar.xz`
- **THEN** lookup by that tag and filename succeeds for the reuse path
