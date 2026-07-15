## MODIFIED Requirements

### Requirement: Update preflight requires git ebuild and gpg

Before any package mutation, `update` SHALL verify that `git`, `ebuild`, and `gpg` are available on `PATH`. If any is missing, the program SHALL log an error naming the missing tool(s) and exit with status `1` without renaming ebuilds, regenerating Manifests, or creating commits. Signing SHALL NOT be optional: `update` SHALL NOT proceed without `gpg`.

When at least one selected package will attempt a `GoVendorAndAssets` apply (including same-PV SRC_URI/revision fixes), `update` SHALL additionally verify that `go` and `xz` are available on `PATH`, that `mndz-overlay-assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. Missing conditional requirements SHALL log an error and exit with status `1` before package mutation. When no selected package needs `GoVendorAndAssets`, the program SHALL NOT fail preflight solely because `go`, `xz`, assets path, or token are missing.

#### Scenario: Missing ebuild on PATH

- **WHEN** the user runs `update` and `ebuild` is not found on `PATH`
- **THEN** the program logs an error indicating `ebuild` is required and exits with status `1` before package work

#### Scenario: Missing gpg on PATH

- **WHEN** the user runs `update` and `gpg` is not found on `PATH`
- **THEN** the program logs an error indicating `gpg` is required and exits with status `1` before package work

#### Scenario: list and outdated do not require those tools

- **WHEN** the user runs `list` or `outdated`
- **THEN** the program does not require `git`, `ebuild`, or `gpg` on `PATH` for that command’s preflight

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt `GoVendorAndAssets`
- **THEN** preflight requires `go` and `xz` on `PATH`

#### Scenario: Binary-only update does not require go

- **WHEN** the user runs `update dev-util/opencode-bin` and no Go technique package is selected
- **THEN** preflight does not fail solely because `go` is missing from `PATH`

#### Scenario: Assets path required for Go update

- **WHEN** the user runs `update` for a `GoVendorAndAssets` package and `mndz-overlay-assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation

### Requirement: Hard failures continue others then exit one

Hard per-package failures (including dirty involved paths, `ebuild manifest` failure, git commit or signing failure, assets commit/push/release failure, Manifest hash mismatch after vendor publish, and fetch/compare errors when an update was attempted) SHALL be logged as errors. Other packages SHALL continue. After all selected packages are processed, if any hard failure occurred, the program SHALL exit with status `1`; otherwise exit with status `0` when the spine succeeded.

#### Scenario: One package fails others complete

- **WHEN** package A hard-fails during apply and package B completes successfully
- **THEN** package B still receives a success stdout line and a signed commit when applicable, and the program exits with status `1`

#### Scenario: Only soft skips exit zero

- **WHEN** every selected package is soft-skipped and the spine succeeded
- **THEN** the program exits with status `0`

#### Scenario: Assets publish hard-fail continues siblings

- **WHEN** package A hard-fails on assets release upload and package B uses `GitMvAndManifest` successfully
- **THEN** package B still completes and the program exits with status `1`

## ADDED Requirements

### Requirement: Soft skip no longer treats Go packages as unsupported

Packages configured with `GoVendorAndAssets` SHALL NOT be soft-skipped with an “unsupported” reason. Soft skips for those packages remain available for not-outdated / already-fixed cases as defined by apply logic.

#### Scenario: Outdated crush is attempted

- **WHEN** `dev-util/crush` is outdated and selected for `update`
- **THEN** the program does not soft-skip it solely because vendor assets are required
