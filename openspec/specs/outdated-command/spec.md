# outdated-command Specification

## Purpose

Define the `outdated` subcommand: spine, package targets, per-package newest-local checks against update sources, soft warnings, exit status, and progress presentation.

## Requirements

### Requirement: Outdated subcommand spine

The CLI SHALL provide an `outdated` subcommand that, like `list`, loads configuration, resolves the overlay path (config then optional `--overlay-path`), validates the overlay, and discovers ebuilds before performing update checks. Hard failures on that spine SHALL log an error and exit with status `1`. Empty inventory SHALL be treated as an error with exit status `1`.

#### Scenario: Successful spine with packages

- **WHEN** the user runs `outdated` against a valid overlay containing ebuilds
- **THEN** the program loads config, validates the overlay, discovers ebuilds, and proceeds to per-package checks

#### Scenario: Empty inventory

- **WHEN** the user runs `outdated` against a valid overlay with zero ebuilds
- **THEN** the program logs an error and exits with status `1`

### Requirement: Per-package newest local version

For each `category/package` with one or more ebuilds, the check SHALL use the newest local version by PV ordering as the local side of the comparison. Source resolution SHALL use the hardcoded package policy only (no ebuild text inference).

#### Scenario: Multiple ebuild versions

- **WHEN** a package directory contains ebuilds for `9.4.5` and `9.6.1`
- **THEN** the local version used for the update check is `9.6.1`

#### Scenario: Source from hardcoded policy

- **WHEN** a package has a hardcoded update source in the policy map
- **THEN** the outdated check uses that source without reading the ebuild for inference

### Requirement: Unconfigured when absent from policy map

When a package has no hardcoded policy (or no source), the outdated check SHALL treat it as unconfigured and log a warning, continuing with other packages, matching the existing soft-warning behavior for unconfigured packages.

#### Scenario: Package missing from map

- **WHEN** a discovered package is not present in the hardcoded policy map
- **THEN** the program logs a warning that no update source is configured for that package and does not print an outdated stdout line for it

### Requirement: Outdated stdout format

For each non-`DepsAndAssets` package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package LOCAL -> REMOTE`, where `LOCAL` and `REMOTE` are pretty-rendered ebuild versions in PV form (no leading `v`, optional `-rN` on local when present). For `DepsAndAssets` packages, stdout lines SHALL follow the runtime-lane outdated reporting requirement (possibly multiple lines and lane labels) instead of a single latest-only comparison. Packages that are up to date under their applicable rules SHALL NOT produce a stdout line.

#### Scenario: GitMv outdated single line

- **WHEN** a GitMv package is outdated from `1.0` to `1.1`
- **THEN** stdout contains one unlabeled `LOCAL -> REMOTE` line

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `DepsAndAssets`, the `outdated` check SHALL use the runtime-lane planner for that ecosystem (runtime package ceilings, candidate set, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND or `RUST_MIN_VER` matching the PV’s known requirement / KEYWORDS; and Manifest distfile DIST present for that PV’s vendor, deps, or crates tarball as defined by the ecosystem specs), the program SHALL write a stdout line of the form `category/package FROM -> TO (…)` using the lane label from `runtime-lanes` (e.g. `(dev-lang/go amd64)`, `(net-libs/nodejs ~amd64)`, `(dev-lang/bun-bin ~arm64)`, `(dev-lang/rust|rust-bin ~amd64)`). Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `FROM`; when multiple locals converge to one target, emit one line per local `FROM` to that `TO`. Versions in these lines SHALL use PV pretty form without a leading `v`. When a gap is overlay-only for a PV that already has a reusable release asset, the line MAY include ` [assets reusable]` as specified for Go reuse signaling, generalized to deps and crates distfiles.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes both transitions with the corresponding lane labels

#### Scenario: Npm package lane line

- **WHEN** `dev-util/openspec` has a runtime-lane gap for nodejs
- **THEN** stdout includes a labeled line naming the nodejs runtime lane rather than a single unlabeled latest-only comparison only

#### Scenario: Bun package lane line

- **WHEN** `dev-util/ralph-tui` has a runtime-lane gap for bun-bin
- **THEN** stdout includes a labeled line naming the bun-bin runtime lane

#### Scenario: Cargo package lane line

- **WHEN** `dev-util/mise` has a runtime-lane gap for the rust toolchain union
- **THEN** stdout includes a labeled line naming `dev-lang/rust|rust-bin` (or equivalent) rather than remaining soft-skipped as Unsupported

### Requirement: Non-Go outdated unchanged

Packages that are not `DepsAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the single-line `category/package LOCAL -> REMOTE` format (PV form, no leading `v`) without runtime-lane labels.

#### Scenario: Binary package format

- **WHEN** `dev-util/opencode-bin` is outdated
- **THEN** stdout uses a single unlabeled line

### Requirement: Soft warnings on stderr

The program SHALL log a warning (default log level includes warnings) for each package that is unconfigured (no source), fails fetch or remote version parse, or is ahead of upstream (local PV greater than remote). Soft outcomes SHALL NOT cause a non-zero exit by themselves.

#### Scenario: Unconfigured package

- **WHEN** a package has no hardcoded update source in the policy map
- **THEN** the program logs a warning naming that `category/package` and continues

#### Scenario: Ahead of upstream

- **WHEN** local PV is greater than remote PV for a package
- **THEN** the program logs a warning for that package and does not write an outdated stdout line for it

#### Scenario: Fetch failure

- **WHEN** upstream fetch fails for a package
- **THEN** the program logs a warning describing the failure and continues checking remaining packages

### Requirement: Exit zero on successful check

When the spine succeeds and the per-package check loop completes, the program SHALL exit with status `0` even if some packages are outdated, unconfigured, ahead, or soft-failed.

#### Scenario: Outdated packages still exit zero

- **WHEN** at least one package is outdated and no hard spine error occurred
- **THEN** the program exits with status `0`

#### Scenario: All current exits zero with empty stdout

- **WHEN** every configured package is up to date and there are no soft-failure warnings required beyond silence for ok packages
- **THEN** the program exits with status `0` and stdout has no outdated lines

### Requirement: Outdated package targets

The `outdated` subcommand SHALL accept zero or more package targets and SHALL NOT accept other subcommand-local flags. Each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. With zero targets, the program SHALL check every package key present in the discovered inventory. With one or more targets, the program SHALL resolve tokens with the same rules as `update` and `gencache` (shared target resolution): unknown package tokens and ambiguous bare package names SHALL be hard failures that abort the command before per-package checks (exit status `1`). After successful resolution, the program SHALL run outdated checks only for the selected package keys; packages not in the selection SHALL produce neither stdout outdated lines nor soft-warning outcomes for this run. Version or PV values SHALL NOT be accepted as CLI arguments. Global options such as `--config`, `--overlay-path`, `--jobs`, and log verbosity still apply.

#### Scenario: Zero targets checks full inventory

- **WHEN** the user runs `outdated` with only top-level flags such as `--config` or `--overlay-path` and no package arguments
- **THEN** the program checks every discovered package

#### Scenario: Category package target

- **WHEN** the user runs `outdated dev-util/crush` against an inventory that contains that package
- **THEN** the program checks only `dev-util/crush` and does not emit outdated lines or soft warnings for other packages solely because they were not selected

#### Scenario: Bare package name

- **WHEN** the user runs `outdated crush` and exactly one discovered package has package name `crush`
- **THEN** the program checks that package key

#### Scenario: Ambiguous bare name hard-fails

- **WHEN** the user runs `outdated foo` and two categories both contain package name `foo`
- **THEN** the program logs an error describing the ambiguity and exits with status `1` without running the check loop

#### Scenario: Unknown package hard-fails

- **WHEN** the user runs `outdated missing/pkg` and that key is not in the inventory
- **THEN** the program logs an error and exits with status `1` without running the check loop

### Requirement: Concurrent outdated checks

The `outdated` per-package check loop SHALL run package checks concurrently, subject to the global jobs limit. Functional outcomes (stdout outdated lines, soft warnings, exit status) SHALL remain equivalent to sequential checking aside from wall-clock timing and indicator presentation.

#### Scenario: Multiple packages checked under concurrency

- **WHEN** the user runs `outdated` against an overlay with multiple discovered packages
- **THEN** the program may check packages concurrently and still emits correct outdated stdout lines and soft warnings for each package

### Requirement: Outdated multi-progress when enabled

When activity indicators are enabled, `outdated` SHALL present multi-progress for the check phase (top-level done/total bar and per-package spinner rows as specified by `cli-activity`). Go or other technique sub-phases do not apply to checks; rows MAY show a short status such as fetching when useful.

#### Scenario: TTY outdated shows multi-progress

- **WHEN** the user runs `outdated` with indicators enabled
- **THEN** a multi-progress panel is shown during package checks and is cleared before deferred report output

### Requirement: Deferred outdated report emission

When activity indicators were shown for the check phase, the program SHALL emit `outdated` stdout lines and soft-warning log lines only after the check multi-progress panel is cleared. When indicators are disabled, emission timing MAY remain immediate after each report is known or after the batch completes, but stdout format and warning semantics SHALL be unchanged.

#### Scenario: Stdout lines appear after panel clear

- **WHEN** indicators are enabled and at least one package is outdated
- **THEN** the `category/package LOCAL -> REMOTE` lines are written to stdout only after the check progress panel has been cleared
