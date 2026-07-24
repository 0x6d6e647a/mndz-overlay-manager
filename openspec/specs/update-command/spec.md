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

The `update` command SHALL verify that `git`, `ebuild`, `egencache`, and `gpg` are available on `PATH` before package mutation (existing spine tools).

When at least one selected package will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `xz` is available on `PATH`, that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path for ecosystem `Go`, `go` SHALL be on `PATH`. When any will use the full path for ecosystem `Npm`, `npm` SHALL be on `PATH`. When any will use the full path for ecosystem `Bun`, `bun` SHALL be on `PATH`. When any selected package uses ecosystem `Cargo` (including when all units may later reuse assets), `pycargoebuild` SHALL be on `PATH` and at least one of `wget` or `aria2c`/`aria2` SHALL be on `PATH`. Missing conditional requirements SHALL log an error and exit with status `1` before package mutation. When no selected package needs `DepsAndAssets`, the program SHALL NOT fail preflight solely because `go`, `npm`, `bun`, `pycargoebuild`, fetchers, `xz`, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require the language tool (`go`/`npm`/`bun`) solely for that reuse work; Cargo still requires `pycargoebuild` and a fetcher in preflight whenever any cargo `DepsAndAssets` package is selected (P1).

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt full-path `DepsAndAssets` Go work
- **THEN** preflight requires `go` and `xz` on `PATH`

#### Scenario: npm required for openspec full path

- **WHEN** the user runs `update dev-util/openspec` and openspec will attempt full-path npm cache construction
- **THEN** preflight requires `npm` and `xz` on `PATH`

#### Scenario: bun required for ralph-tui full path

- **WHEN** the user runs `update dev-util/ralph-tui` and ralph-tui will attempt full-path bun cache construction
- **THEN** preflight requires `bun` and `xz` on `PATH`

#### Scenario: pycargoebuild required when cargo package selected

- **WHEN** the user runs `update dev-util/mise` and mise uses `DepsAndAssets Cargo`
- **THEN** preflight requires `pycargoebuild` and a supported fetcher on `PATH` even if assets may be reusable

#### Scenario: Binary package skips language tools

- **WHEN** the user runs `update dev-util/opencode-bin` and no `DepsAndAssets` package is selected
- **THEN** preflight does not fail solely because `go`, `npm`, `bun`, or `pycargoebuild` is missing from `PATH`

#### Scenario: Assets path required for deps packages

- **WHEN** the user runs `update` for a `DepsAndAssets` package and `assets-path` is unset
- **THEN** the program logs an error about the missing assets path and exits with status `1` before package mutation

### Requirement: Update package targets

The `update` subcommand SHALL accept zero or more package targets. With zero targets, the program SHALL consider all discovered packages that need work: non-`DepsAndAssets` packages that are outdated relative to their configured update source, and `DepsAndAssets` packages that have any runtime-lane gap. With one or more targets, each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. An ambiguous bare package name SHALL be a hard failure for that token. Explicit targets that do not need work under their applicable rules SHALL be soft-skipped with a warning or informational message.

#### Scenario: Zero targets includes deps-lane gaps

- **WHEN** the user runs `update` with no arguments and a `DepsAndAssets` package has a lane gap while at latest single remote for GitMv purposes
- **THEN** that package is still considered for update work

### Requirement: Update stdout for successful bumps

For each non-`DepsAndAssets` package successfully updated and committed, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, using the same version pretty-rendering conventions as `outdated` (PV form, no leading `v`). For `DepsAndAssets` packages, stdout SHALL follow the runtime-lane update stdout requirement (possibly multiple labeled lines). Packages that are soft-skipped or hard-failed SHALL NOT produce a success stdout line.

#### Scenario: GitMv single line

- **WHEN** a GitMv package updates from `1.0` to `1.1`
- **THEN** stdout contains exactly one success line without a runtime-lane label

### Requirement: Go tree-lane update selection

For packages with technique `DepsAndAssets`, `update` SHALL use the runtime-lane planner for that ecosystem to determine target PVs and whether the package needs work. With zero package arguments, `update` SHALL include a deps package when any lane has a gap (missing target PV ebuild, content or Manifest fix needed—including BDEPEND not matching the PV’s known requirement—or exact-set prune required), not only when newest local is less than upstream latest. Explicit targets that are fully satisfied under the plan (including Manifest distfile DIST completeness and BDEPEND match when the requirement is known) SHALL be soft-skipped.

#### Scenario: Plan-satisfied soft skip

- **WHEN** every planned PV is present with adequate content and Manifest dist entries
- **THEN** the package may soft-skip as already matching the plan

### Requirement: Go tree-lane update stdout

For `DepsAndAssets` packages, successful update stdout SHALL emit lane-labeled lines as defined for runtime-lane reporting (including runtime package name in the label). When a success line corresponds to a PV materialized via the **reuse** path, the program SHALL append the token ` [assets reused]` to that line. Lines for PVs materialized via the full build+publish path SHALL NOT include that token.

#### Scenario: Reuse token

- **WHEN** a planned PV is materialized via reuse of an existing release asset
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

For packages that are not `DepsAndAssets`, the `update` command SHALL upgrade to the latest version obtained from the package’s configured update source. For `DepsAndAssets` packages, target versions SHALL be those produced by the runtime-lane planner (per-lane maxima under runtime ceilings), which MAY be older than upstream latest when latest’s requirement exceeds a ceiling. The `update` command SHALL NOT accept a user-specified target version in this change.

#### Scenario: Lane may select older than latest

- **WHEN** upstream latest requires a runtime newer than the plain ceiling but an older candidate fits
- **THEN** update may target the older candidate for that lane

### Requirement: Soft skip no longer treats Go packages as unsupported

Packages configured with `DepsAndAssets` (Go, Npm, or Bun) SHALL NOT be soft-skipped with an “unsupported” reason for vendor or deps assets. Soft skips for those packages remain available for not-outdated / already-fixed cases as defined by apply logic.

#### Scenario: openspec not unsupported

- **WHEN** the user runs `update dev-util/openspec` and the package needs a version bump with deps assets
- **THEN** the program does not soft-skip it solely because deps assets are required

### Requirement: Update preflight progress when enabled

When activity indicators are enabled, `update` SHALL show a sequential preflight progress bar covering preflight steps (tool checks and any conditional assets/token/ssh-agent preparation that runs before package mutation). The bar SHALL clear when preflight finishes or fails (failure logs after clear or without a panel when indicators are disabled).

#### Scenario: Preflight shows step progress on TTY

- **WHEN** the user runs `update` with indicators enabled
- **THEN** a sequential preflight progress bar is displayed before package mutation work begins

### Requirement: Update phase-one multi-progress when enabled

When activity indicators are enabled, `update` phase-1 package apply SHALL show multi-progress (top-level done/total and per-package rows) as specified by `cli-activity`. For `GoVendorAndAssets` (and similarly long techniques), the package row SHALL update short sub-phase labels and advance per-package step progress during work without requiring nested progress bars. For full-path Go vendor materialize, labels and steps SHALL follow the fine-grained sequence specified by `cli-activity` (clone, go mod download, compress, commit assets, push assets, upload release asset, regenerating manifest). For reuse-path materialize, labels and steps SHALL follow the reuse sequence specified by `cli-activity`.

#### Scenario: Go package shows sub-phase label

- **WHEN** indicators are enabled and a `GoVendorAndAssets` package is being applied
- **THEN** the package’s multi-progress row includes a short sub-phase description that can change as the technique advances

#### Scenario: Go full path advances materialize sub-phases

- **WHEN** indicators are enabled and a `GoVendorAndAssets` package PV is materialized on the full vendor+publish path
- **THEN** the package row’s sub-phase description and step progress advance through vendor construction and assets publish sub-phases as specified by `cli-activity`, not only a single frozen vendoring or publishing label for those phases

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
