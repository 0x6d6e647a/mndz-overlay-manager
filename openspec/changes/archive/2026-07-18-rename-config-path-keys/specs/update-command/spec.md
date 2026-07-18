## MODIFIED Requirements

### Requirement: Update preflight requires git ebuild and gpg

Before any package mutation, `update` SHALL verify that `git`, `ebuild`, and `gpg` are available on `PATH`. If any is missing, the program SHALL log an error naming the missing tool(s) and exit with status `1` without renaming ebuilds, regenerating Manifests, or creating commits. Signing SHALL NOT be optional: `update` SHALL NOT proceed without `gpg`.

When at least one selected package will attempt a `GoVendorAndAssets` apply (including same-PV SRC_URI/revision fixes), `update` SHALL additionally verify that `go` and `xz` are available on `PATH`, that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. Missing conditional requirements SHALL log an error and exit with status `1` before package mutation. When no selected package needs `GoVendorAndAssets`, the program SHALL NOT fail preflight solely because `go`, `xz`, assets path, or token are missing.

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

- **WHEN** the user runs `update` for a `GoVendorAndAssets` package and `assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation
