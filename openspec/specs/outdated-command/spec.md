# outdated-command Specification

## Purpose

TBD

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

For each non-Go package whose local PV is strictly less than the fetched remote PV, the program SHALL write exactly one line to standard output of the form `category/package vLOCAL -> vREMOTE`, where `vLOCAL` and `vREMOTE` are pretty-rendered ebuild versions (leading `v`, optional `-rN` on local when present). For `GoVendorAndAssets` packages, stdout lines SHALL follow the Go tree-lane outdated reporting requirement (possibly multiple lines and lane labels) instead of a single latest-only comparison. Packages that are up to date under their applicable rules SHALL NOT produce a stdout line.

#### Scenario: Package behind upstream

- **WHEN** local newest PV is `2.1.6` and remote is `2.1.10` for a non-Go package that uses latest-only checking
- **THEN** stdout contains the line `category/package v2.1.6 -> v2.1.10` for that package

#### Scenario: Package up to date is silent on stdout

- **WHEN** a package is fully up to date under its applicable outdated rules
- **THEN** the program writes no stdout line for that package

### Requirement: Go tree-lane outdated reporting

For each package whose technique is `GoVendorAndAssets`, the `outdated` check SHALL use the Go tree-lane planner (Gentoo `dev-lang/go` ceilings, upstream candidates, per-lane target PVs) instead of comparing only newest local PV to a single latest remote. For each lane that has a target PV and is not already satisfied by a local non-live ebuild at that PV with adequate content for that tip (ebuild present; content-fix rules for assets URI / BDEPEND matching the PV’s known `go.mod` requirement / KEYWORDS; and Manifest vendor DIST present for that PV’s vendor tarball as defined by `go-vendor-assets`), the program SHALL write a stdout line of the form `category/package vFROM -> vTO (dev-lang/go …)` using the lane label from `go-tree-lanes`. Split and converge mapping SHALL follow: when one local version maps to multiple new targets, emit one line per target with the same `vFROM`; when multiple locals converge to one target, emit one line per local `vFROM` to that `vTO`. Packages that are fully satisfied for all lanes with targets SHALL NOT produce outdated lines for those lanes.

Content-fix adequacy for BDEPEND SHALL use the go.mod probe for that planned PV’s tag (shared cache with planning) when available: missing `dev-lang/go` atom or an atom that does not exactly match `>=dev-lang/go-<go.mod version>:=` SHALL count as unsatisfied. Mere presence of any `dev-lang/go` string SHALL NOT count as adequate when the required version is known.

When the reason a present planned PV is still unsatisfied is **only** overlay content or Manifest incompleteness (the local ebuild for that PV already exists) rather than a missing PV ebuild, the program SHALL append the token ` [assets reusable]` to that outdated line so operators can see that apply may complete without re-vendoring if the release asset already exists. Missing planned PV ebuilds SHALL use the normal line without requiring a GitHub probe during `outdated`.

#### Scenario: Uncollapsed two-lane gap

- **WHEN** local has only `0.80.0` and the plan targets `0.82.0` for `(dev-lang/go amd64)` and `0.84.0` for `(dev-lang/go ~amd64)` (other lanes satisfied or absent)
- **THEN** stdout includes `… v0.80.0 -> v0.82.0 (dev-lang/go amd64)` and `… v0.80.0 -> v0.84.0 (dev-lang/go ~amd64)`

#### Scenario: Converge report shape

- **WHEN** locals are `0.80.0` and `0.82.0` and the plan collapses to a single target `0.84.0` for remaining lanes
- **THEN** stdout includes lines mapping `v0.80.0 -> v0.84.0` and `v0.82.0 -> v0.84.0` with appropriate lane labels

#### Scenario: Fully planned package is silent

- **WHEN** local ebuilds exactly match the planned unique PV set and content and Manifest fixes are not required (including BDEPEND matching known go.mod requirements)
- **THEN** the program writes no outdated stdout line for that package

#### Scenario: Content-fix line marks assets reusable

- **WHEN** planned PV `0.84.0` is present locally with ebuild content that still needs Manifest vendor DIST completion (or other overlay-only content fix) for a lane
- **THEN** the outdated line for that lane includes the substring ` [assets reusable]`

#### Scenario: Wrong BDEPEND is outdated

- **WHEN** planned PV is present with adequate SRC_URI, KEYWORDS, and Manifest vendor DIST, but BDEPEND does not match the probed go.mod requirement for that PV
- **THEN** the program emits an outdated line for the affected lane(s) and does not treat the package as fully up to date

### Requirement: Non-Go outdated unchanged

Packages that are not `GoVendorAndAssets` SHALL continue to use newest-local vs single fetched latest comparison and the existing single-line `category/package vLOCAL -> vREMOTE` format without Go lane labels.

#### Scenario: Binary package single line

- **WHEN** `dev-util/opencode-bin` local is behind latest remote
- **THEN** stdout has exactly one line for that package without a `(dev-lang/go …)` suffix

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

### Requirement: Outdated has no subcommand-specific options

The `outdated` subcommand SHALL accept no arguments or subcommand-local flags in this change. Global options such as `--config`, `--overlay-path`, and log verbosity still apply.

#### Scenario: Invoked with global options only

- **WHEN** the user runs `outdated` with only top-level flags such as `--config` or `--overlay-path`
- **THEN** the program treats `outdated` as a zero-argument subcommand and proceeds with the check pipeline

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
- **THEN** the `category/package vLOCAL -> vREMOTE` lines are written to stdout only after the check progress panel has been cleared
