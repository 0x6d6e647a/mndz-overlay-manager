# update-command Specification

## Purpose

Define the `update` subcommand: spine and preflight, package targets, stdout for successful bumps, soft skips vs hard failures, and latest-upstream-only upgrades.

## Requirements

### Requirement: Update subcommand spine

The CLI SHALL provide an `update` subcommand that loads configuration, resolves the overlay path (config then optional `--overlay-path`), validates the overlay, discovers ebuilds, and runs action-scoped external-tool preflight before any package update work. Hard failures on that spine SHALL log an error and exit with status `1`. Empty inventory SHALL be treated as an error with exit status `1`.

#### Scenario: Successful spine with packages

- **WHEN** the user runs `update` against a valid overlay containing ebuilds and all required tools are on `PATH`
- **THEN** the program loads config, validates the overlay, discovers ebuilds, passes preflight, and proceeds to per-package update work

#### Scenario: Empty inventory

- **WHEN** the user runs `update` against a valid overlay with zero ebuilds
- **THEN** the program logs an error and exits with status `1` without applying updates

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

### Requirement: Update package targets

The `update` subcommand SHALL accept zero or more package targets. With zero targets, the program SHALL consider all discovered packages that are outdated relative to their configured update source. With one or more targets, each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. An ambiguous bare package name SHALL be a hard failure for that token. Explicit targets that are not outdated SHALL be soft-skipped with a warning or informational message.

#### Scenario: No targets updates all outdated

- **WHEN** the user runs `update` with no package arguments and multiple packages are outdated
- **THEN** the program attempts to update each outdated package according to its policy

#### Scenario: Multiple explicit targets

- **WHEN** the user runs `update` with arguments `dev-util/opencode-bin` and `dev-lang/deno-bin`
- **THEN** the program limits update attempts to those packages only

#### Scenario: Unambiguous bare package name

- **WHEN** the user runs `update deno-bin` and exactly one discovered package has package name `deno-bin`
- **THEN** the program resolves the target to that `category/package`

#### Scenario: Ambiguous bare package name

- **WHEN** the user runs `update foo` and discovered packages include both `bar/foo` and `baz/foo`
- **THEN** the program logs an error for the ambiguous token and does not treat it as a successful target resolution

### Requirement: Update stdout for successful bumps

For each package successfully updated and committed, the program SHALL write exactly one line to standard output of the form `category/package vLOCAL -> vREMOTE`, using the same version pretty-rendering conventions as `outdated`. Packages that are soft-skipped or hard-failed SHALL NOT produce a success stdout line.

#### Scenario: Successful update line

- **WHEN** `dev-util/opencode-bin` is updated from local PV `1.17.19` to remote `1.17.20` and the signed commit succeeds
- **THEN** stdout contains the line `dev-util/opencode-bin v1.17.19 -> v1.17.20`

### Requirement: Soft skips do not abort siblings

Packages that are unmapped, configured as unsupported, or not outdated SHALL be soft-skipped with a warning (or informational log), and other packages SHALL continue. Soft skips alone SHALL NOT cause a non-zero exit status.

#### Scenario: Unsupported package is skipped

- **WHEN** a package is outdated but its technique is unsupported
- **THEN** the program logs a warning naming the package and continues with remaining packages

#### Scenario: Unmapped package is skipped

- **WHEN** a package has no hardcoded policy entry
- **THEN** the program logs a warning that no hardcoded policy exists for that package and continues

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

### Requirement: Latest upstream only

The `update` command SHALL upgrade to the latest version obtained from the package’s configured update source. It SHALL NOT accept a user-specified target version in this change.

#### Scenario: Bumps to fetched remote version

- **WHEN** local PV is older than the fetched remote PV for a supported package
- **THEN** the applied ebuild version is that remote PV

### Requirement: Soft skip no longer treats Go packages as unsupported

Packages configured with `GoVendorAndAssets` SHALL NOT be soft-skipped with an “unsupported” reason. Soft skips for those packages remain available for not-outdated / already-fixed cases as defined by apply logic.

#### Scenario: Outdated crush is attempted

- **WHEN** `dev-util/crush` is outdated and selected for `update`
- **THEN** the program does not soft-skip it solely because vendor assets are required

### Requirement: Update preflight progress when enabled

When activity indicators are enabled, `update` SHALL show a sequential preflight progress bar covering preflight steps (tool checks and any conditional assets/token/ssh-agent preparation that runs before package mutation). The bar SHALL clear when preflight finishes or fails (failure logs after clear or without a panel when indicators are disabled).

#### Scenario: Preflight shows step progress on TTY

- **WHEN** the user runs `update` with indicators enabled
- **THEN** a sequential preflight progress bar is displayed before package mutation work begins

### Requirement: Update phase-one multi-progress when enabled

When activity indicators are enabled, `update` phase-1 package apply SHALL show multi-progress (top-level done/total and per-package rows) as specified by `cli-activity`. For `GoVendorAndAssets` (and similarly long techniques), the package row SHALL update a short sub-phase label during work (for example fetching, vendoring, publishing assets, regenerating manifest) without requiring nested progress bars.

#### Scenario: Go package shows sub-phase label

- **WHEN** indicators are enabled and a `GoVendorAndAssets` package is being applied
- **THEN** the package’s multi-progress row includes a short sub-phase description that can change as the technique advances

### Requirement: Update commit progress when enabled

When activity indicators are enabled and one or more packages proceed to signed commit, `update` SHALL show a sequential commit progress bar (done/total and current package), not multi-row spinners, and SHALL clear it when the commit phase ends.

#### Scenario: Commit phase bar on TTY

- **WHEN** indicators are enabled and two packages are committed
- **THEN** a sequential commit progress bar advances through both commits and then clears

### Requirement: Deferred update outcome emission

When activity indicators were shown for a phase, the program SHALL emit success stdout lines and soft/hard log messages for that work only after the relevant panel is cleared. Soft-skip and hard-fail packages SHALL remain visible on multi-progress rows until the phase panel clears. Machine stdout success format SHALL remain `category/package vLOCAL -> vREMOTE`.

#### Scenario: Success stdout after clear

- **WHEN** indicators are enabled and a package is successfully updated and committed
- **THEN** its success stdout line is written only after progress panels for the completed work have been cleared

#### Scenario: Soft skip stays on panel then logs

- **WHEN** indicators are enabled and a package is soft-skipped during phase 1
- **THEN** the package remains on the multi-progress panel in a non-success state until clear, after which the warning is logged
