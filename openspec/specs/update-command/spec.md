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

### Requirement: Update package targets

The `update` subcommand SHALL accept zero or more package targets. With zero targets, the program SHALL consider all discovered packages that need work: non-Go packages that are outdated relative to their configured update source, and `GoVendorAndAssets` packages that have any Go tree-lane gap. With one or more targets, each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. An ambiguous bare package name SHALL be a hard failure for that token. Explicit targets that do not need work under their applicable rules SHALL be soft-skipped with a warning or informational message.

#### Scenario: No targets updates all outdated

- **WHEN** the user runs `update` with no package arguments and multiple packages need work under their applicable rules
- **THEN** the program attempts to update each such package according to its policy

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

For each non-Go package successfully updated and committed, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, using the same version pretty-rendering conventions as `outdated` (PV form, no leading `v`). For `GoVendorAndAssets` packages, stdout SHALL follow the Go tree-lane update stdout requirement (possibly multiple labeled lines). Packages that are soft-skipped or hard-failed SHALL NOT produce a success stdout line.

#### Scenario: Successful update line

- **WHEN** `dev-util/opencode-bin` is updated from local PV `1.17.19` to remote `1.17.20` and the signed commit succeeds
- **THEN** stdout contains the line `dev-util/opencode-bin 1.17.19 -> 1.17.20`

### Requirement: Go tree-lane update selection

For packages with technique `GoVendorAndAssets`, `update` SHALL use the Go tree-lane planner to determine target PVs and whether the package needs work. With zero package arguments, `update` SHALL include a Go package when any lane has a gap (missing target PV ebuild, content or Manifest fix needed—including BDEPEND not matching the PV’s known `go.mod` requirement—or exact-set prune required), not only when newest local is less than upstream latest. Explicit targets that are fully satisfied under the plan (including Manifest vendor DIST completeness and BDEPEND match when the go.mod requirement is known) SHALL be soft-skipped.

#### Scenario: Zero-arg update includes multi-lane gap

- **WHEN** the user runs `update` with no package arguments and a Go package has a tree-lane gap
- **THEN** the program still attempts that package’s lane apply work

#### Scenario: Satisfied Go package soft-skipped

- **WHEN** the user runs `update crush` and crush’s package dir already matches the planned unique PV set with correct content (including BDEPEND matching known go.mod requirements) and Manifest vendor entries
- **THEN** the package is soft-skipped without hard-fail

#### Scenario: Incomplete Manifest not soft-skipped

- **WHEN** planned PVs exist with ebuilds but Manifest lacks a vendor DIST for a planned PV
- **THEN** the package is not soft-skipped solely as already matching the plan

#### Scenario: BDEPEND mismatch not soft-skipped

- **WHEN** planned PVs exist with ebuilds, KEYWORDS, SRC_URI, and Manifest vendor DIST adequate, but BDEPEND does not match a known go.mod requirement for a planned PV
- **THEN** the package is not soft-skipped solely as already matching the plan

### Requirement: Go tree-lane update stdout

For each successfully applied Go tree lane (or coalesced same-PV apply that satisfies one or more lanes), the program SHALL write stdout lines of the form `category/package FROM -> TO (dev-lang/go …)` using lane labels from `go-tree-lanes`. Versions in these lines SHALL be pretty-rendered in PV form (no leading `v`). Split mapping: one local → multiple news yields one line per target with the same `FROM`. Converge mapping: multiple locals → one new yields one line per local `FROM` to that `TO`. Soft-skipped or hard-failed lanes SHALL NOT produce success lines.

When a success line corresponds to a PV that was materialized via the **reuse** path (existing release asset; no vendor rebuild/publish for that PV), the program SHALL append the token ` [assets reused]` to that line. Lines for PVs materialized via the full vendor+publish path SHALL NOT include that token.

#### Scenario: Split success lines

- **WHEN** a Go package had local `0.80.0` only and successfully materializes targets `0.82.0` and `0.84.0` for two lanes via the full path
- **THEN** stdout includes `… 0.80.0 -> 0.82.0 (…)` and `… 0.80.0 -> 0.84.0 (…)` with the correct lane labels and without requiring ` [assets reused]`

#### Scenario: Converge success lines

- **WHEN** locals `0.80.0` and `0.82.0` successfully converge to `0.84.0`
- **THEN** stdout includes `… 0.80.0 -> 0.84.0` and `… 0.82.0 -> 0.84.0` with appropriate labels

#### Scenario: Reuse success marked

- **WHEN** a planned PV is successfully completed via the reuse path
- **THEN** each success stdout line for that PV includes the substring ` [assets reused]`

### Requirement: Soft skips do not abort siblings

Packages that are unmapped, configured as unsupported, or not outdated SHALL be soft-skipped with a warning (or informational log), and other packages SHALL continue. Soft skips alone SHALL NOT cause a non-zero exit status.

#### Scenario: Unsupported package is skipped

- **WHEN** a package is outdated but its technique is unsupported
- **THEN** the program logs a warning naming the package and continues with remaining packages

#### Scenario: Unmapped package is skipped

- **WHEN** a package has no hardcoded policy entry
- **THEN** the program logs a warning that no hardcoded policy exists for that package and continues

### Requirement: Hard failures continue others then exit one

Hard per-package or per-unit failures (including dirty involved paths, `ebuild manifest` failure, git commit or signing failure, assets commit/push/release failure, Manifest hash mismatch after vendor publish, host Go older than the package `go.mod` requirement during `GoVendorAndAssets` apply, inability to obtain go.mod when BDEPEND alignment is required, and fetch/compare errors when an update was attempted) SHALL be logged as errors. Other packages SHALL continue. After all selected packages are processed, if any hard failure occurred, the program SHALL exit with status `1`; otherwise exit with status `0` when the spine succeeded. Host Go version sufficiency for a given package’s `go.mod` is evaluated during that package’s apply (after clone on the full path), not as a spine-wide preflight that aborts all packages before any work. When one planned PV unit of a multi-PV Go package succeeds (including its signed overlay commit) and a later unit hard-fails, the program SHALL still exit with status `1` while retaining the successful unit’s commit.

#### Scenario: One package fails others complete

- **WHEN** package A hard-fails during apply and package B completes successfully
- **THEN** package B still receives a success stdout line and a signed commit when applicable, and the program exits with status `1`

#### Scenario: Only soft skips exit zero

- **WHEN** every selected package is soft-skipped and the spine succeeded
- **THEN** the program exits with status `0`

#### Scenario: Assets publish hard-fail continues siblings

- **WHEN** package A hard-fails on assets release upload and package B uses `GitMvAndManifest` successfully
- **THEN** package B still completes and the program exits with status `1`

#### Scenario: Host Go too old hard-fails one Go package

- **WHEN** package A is `GoVendorAndAssets` and hard-fails because host Go is older than its `go.mod` requirement, and package B is selected and can succeed
- **THEN** package A is logged as an error, package B may still complete, and the program exits with status `1`

#### Scenario: Partial multi-PV still exits one

- **WHEN** a Go package commits one planned PV successfully and hard-fails on a second planned PV
- **THEN** the program exits with status `1` and success stdout may include lines for the committed PV

### Requirement: Go version gate is not spine preflight

Spine preflight for `update` SHALL continue to require only that `go` is present on `PATH` when any selected package needs `GoVendorAndAssets`. Preflight SHALL NOT parse remote or local `go.mod` files to enforce a global minimum Go version before package work begins. Per-package host vs `go.mod` checks are defined by the `go-vendor-assets` capability.

#### Scenario: Preflight passes with go on PATH even if later package needs newer Go

- **WHEN** the user runs `update` for a Go package, `go` is on `PATH`, and other Go preflight requirements are met
- **THEN** preflight succeeds even if that package’s upstream `go.mod` will later require a newer Go than the host provides

### Requirement: Latest upstream only

For packages that are not `GoVendorAndAssets`, the `update` command SHALL upgrade to the latest version obtained from the package’s configured update source. For `GoVendorAndAssets` packages, target versions SHALL be those produced by the Go tree-lane planner (per-lane maxima under Gentoo `dev-lang/go` ceilings), which MAY be older than upstream latest when latest’s `go.mod` exceeds a ceiling. The `update` command SHALL NOT accept a user-specified target version in this change.

#### Scenario: Bumps to fetched remote version for non-Go

- **WHEN** local PV is older than the fetched remote PV for a `GitMvAndManifest` package
- **THEN** the applied ebuild version is that remote PV

#### Scenario: Go package may stop below latest

- **WHEN** upstream latest requires a Go newer than every Gentoo `dev-lang/go` ceiling and an older tag fits a ceiling
- **THEN** `update` targets that older tag for the corresponding lane rather than hard-requiring latest

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

When activity indicators were shown for a phase, the program SHALL emit success stdout lines and soft/hard log messages for that work only after the relevant panel is cleared. Soft-skip and hard-fail packages SHALL remain visible on multi-progress rows until the phase panel clears. Machine stdout success format SHALL remain `category/package LOCAL -> REMOTE` (PV form, no leading `v`).

#### Scenario: Success stdout after clear

- **WHEN** indicators are enabled and a package is successfully updated and committed
- **THEN** its success stdout line is written only after progress panels for the completed work have been cleared

#### Scenario: Soft skip stays on panel then logs

- **WHEN** indicators are enabled and a package is soft-skipped during phase 1
- **THEN** the package remains on the multi-progress panel in a non-success state until clear, after which the warning is logged

### Requirement: GPG readiness teardown on update exit

When `update` runs package work that may create GPG-signed commits, the program SHALL retain process-lifetime state for any signing keygrips this run warmed and SHALL clear those keygrips from gpg-agent on process exit (success or failure), as specified by gpg-sign-readiness. Teardown SHALL run even when some packages hard-failed after an unlock. The program SHALL NOT clear keygrips that this process did not warm.

#### Scenario: Clear warmed key after update finishes

- **WHEN** `update` unlocked a cold signing keygrip during signed commits and then finishes
- **THEN** the program clears that keygrip’s agent cache on exit

#### Scenario: Exit after failure still clears what we warmed

- **WHEN** `update` unlocked GPG then a later package hard-fails
- **THEN** process exit still clears keygrips this process warmed
