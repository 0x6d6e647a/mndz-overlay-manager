# assets-publish Specification

## Purpose

Shared mndz-overlay-assets checksum sidecars, git commit/push, and GitHub release upload for vendor/deps/crates distfiles.

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

After writing sidecars for a package version, the program SHALL create a GPG-signed git commit in the assets worktree that stages only those new/changed sidecar paths (including sidecars for every distfile published for that PV), with commit message `category/package: version` (version without leading `v`), then `git push` to the worktree’s configured remote. Push failure SHALL be a hard failure for that package’s update attempt. The program SHALL NOT leave a successful package apply that depends on unpublished assets.

#### Scenario: Commit message matches overlay style

- **WHEN** assets commit is created for `dev-util/beads` at `1.0.5`
- **THEN** the commit message is exactly `dev-util/beads: 1.0.5`

#### Scenario: Push required

- **WHEN** the signed assets commit succeeds but `git push` fails
- **THEN** the package update hard-fails and overlay mutation for that package does not proceed

#### Scenario: Multi-distfile sidecars in one commit

- **WHEN** publishing `opencode-1.18.4-deps.tar.xz` and `opencode-1.18.4-models.json` for `dev-util/opencode`
- **THEN** one assets commit stages sidecars for both basenames under `dev-util/opencode/` with message `dev-util/opencode: 1.18.4`

### Requirement: GitHub release with tarball asset

After a successful assets push, the program SHALL create a GitHub release on the assets repository via the HTTP API with:

- `tag_name` = `{pn}-{pv}`
- `name` = `{category}/{pn}-{pv}`
- `body` = `category/package: version` (same text as the assets commit message)

The program SHALL upload one or more release assets for that tag (vendor, deps, crates, and/or companion distfiles such as models JSON). For packages that publish a single distfile, behavior SHALL match a one-element asset list. API or upload failure SHALL hard-fail the package. If the release is created and a subsequent asset upload fails, the program SHALL best-effort delete the release so a retry does not leave a partial release without all required assets.

#### Scenario: Release metadata for crush

- **WHEN** publishing version `0.77.0` of `dev-util/crush`
- **THEN** the release tag is `crush-0.77.0`, the release name is `dev-util/crush-0.77.0`, and the body is `dev-util/crush: 0.77.0`

#### Scenario: Asset filename

- **WHEN** the release is created for a Go vendor tarball alone
- **THEN** the uploaded asset name is `{pn}-{pv}-vendor.tar.xz`

#### Scenario: Multiple assets for one release

- **WHEN** publishing deps and models distfiles for the same PV under one tag
- **THEN** both files are attached to the same GitHub release tag `{pn}-{pv}`

### Requirement: Assets critical section across packages

When multiple packages publish to the same assets worktree concurrently, git index mutations, commits, pushes, and release creation for that worktree SHALL be mutually excluded so only one package holds the assets critical section at a time. Tarball builds outside the critical section MAY still run in parallel.

#### Scenario: Two Go packages do not interleave assets git

- **WHEN** two `DepsAndAssets` packages finish tarballs at the same time
- **THEN** their assets commit/push/release steps do not interleave on the shared assets worktree

### Requirement: Crates tarball assets use same publish spine

When publishing a Cargo crates distfile `{pn}-{pv}-crates.tar.xz`, the program SHALL use the same checksum sidecars layout, signed assets commit message form `category/package: version`, git push, and GitHub release upload behavior as for Go vendor and npm/Bun deps distfiles, with release tag `{pn}-{pv}` and asset basename `{pn}-{pv}-crates.tar.xz`.

#### Scenario: mise crates release asset name

- **WHEN** assets publish completes for `dev-util/mise` at PV `2026.7.5`
- **THEN** the GitHub release tag is `mise-2026.7.5` and the uploaded asset basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Sidecars under category package

- **WHEN** publishing `hk-1.50.0-crates.tar.xz` for `dev-util/hk`
- **THEN** sidecars are created under `dev-util/hk/` in the configured assets worktree

### Requirement: Forward-compatible publish API

Assets hashing, worktree commit/push, and release upload SHALL accept one or more distfile paths and package coordinates (`category`, `package`, version, asset filename(s)) without assuming Go-only filename suffixes in the core publish helpers, so npm/bun `-deps.tar.xz`, cargo `-crates.tar.xz`, and companion files such as `{pn}-{pv}-models.json` can reuse the same path. Single-asset publishers SHALL remain supported.

#### Scenario: Non-vendor filename accepted by layout helper

- **WHEN** a caller requests sidecar paths for `openspec-1.4.2-deps.tar.xz` under `dev-util/openspec`
- **THEN** the layout helper returns paths under `dev-util/openspec/` for that basename

#### Scenario: Models filename accepted by layout helper

- **WHEN** a caller requests sidecar paths for `opencode-1.18.4-models.json` under `dev-util/opencode`
- **THEN** the layout helper returns paths under `dev-util/opencode/` for that basename

### Requirement: Multi-asset reuse requires all basenames

When materializing a PV via reuse of an existing assets release, the program SHALL treat reuse as successful only when the release tag `{pn}-{pv}` exists and **every** required asset basename for that package/PV is present and downloadable. If the tag is missing, or any required basename is missing, the program SHALL treat the outcome as not-found for reuse and take the full materialize path (or hard-fail if full path is not applicable). Partial presence of a subset of required assets SHALL NOT count as successful reuse.

#### Scenario: Both deps and models present

- **WHEN** release `opencode-1.18.4` has assets `opencode-1.18.4-deps.tar.xz` and `opencode-1.18.4-models.json`
- **THEN** reuse for opencode at that PV downloads both files

#### Scenario: Deps without models is not reusable

- **WHEN** release `opencode-1.18.4` has only `opencode-1.18.4-deps.tar.xz`
- **THEN** reuse for opencode at that PV reports not-found (or equivalent non-success) for the multi-asset set

### Requirement: Models distfile release assets

When publishing a models companion distfile for a package that requires it, the GitHub release asset filename SHALL be `{pn}-{pv}-models.json` (overlay package name and PV without revision). Checksum sidecars, assets-repo layout paths, release tag `{pn}-{pv}`, and commit message `category/package: version` SHALL use the same rules as other distfiles and SHALL share the release with the package’s deps (or other) assets for that PV.

#### Scenario: opencode models release asset name

- **WHEN** publishing version `1.18.4` of package name `opencode` with a models snapshot
- **THEN** the uploaded models asset name is `opencode-1.18.4-models.json` and the release tag is `opencode-1.18.4`

#### Scenario: Lookup models asset by name

- **WHEN** release `opencode-1.18.4` has asset `opencode-1.18.4-models.json`
- **THEN** lookup by that tag and filename succeeds for download

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
