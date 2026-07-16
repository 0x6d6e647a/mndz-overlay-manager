## ADDED Requirements

### Requirement: Go tree-lane update selection

For packages with technique `GoVendorAndAssets`, `update` SHALL use the Go tree-lane planner to determine target PVs and whether the package needs work. With zero package arguments, `update` SHALL include a Go package when any lane has a gap (missing target PV ebuild, content fix needed, or exact-set prune required), not only when newest local is less than upstream latest. Explicit targets that are fully satisfied under the plan SHALL be soft-skipped.

#### Scenario: Zero-arg update includes multi-lane gap

- **WHEN** the user runs `update` with no arguments and a Go package’s newest local equals upstream latest but a second planned PV for another Go ceiling is missing
- **THEN** the program still attempts that package’s lane apply work

#### Scenario: Satisfied Go package soft-skipped

- **WHEN** the user runs `update crush` and crush’s package dir already matches the planned unique PV set with correct content
- **THEN** the package is soft-skipped without hard-fail

### Requirement: Go tree-lane update stdout

For each successfully applied Go tree lane (or coalesced same-PV apply that satisfies one or more lanes), the program SHALL write stdout lines of the form `category/package vFROM -> vTO (dev-lang/go …)` using lane labels from `go-tree-lanes`. Split mapping: one local → multiple news yields one line per target with the same `vFROM`. Converge mapping: multiple locals → one new yields one line per local `vFROM` to that `vTO`. Soft-skipped or hard-failed lanes SHALL NOT produce success lines.

#### Scenario: Split success lines

- **WHEN** a Go package had local `0.80.0` only and successfully materializes targets `0.82.0` and `0.84.0` for two lanes
- **THEN** stdout includes `… v0.80.0 -> v0.82.0 (…)` and `… v0.80.0 -> v0.84.0 (…)` with the correct lane labels

#### Scenario: Converge success lines

- **WHEN** locals `0.80.0` and `0.82.0` successfully converge to `0.84.0`
- **THEN** stdout includes `… v0.80.0 -> v0.84.0` and `… v0.82.0 -> v0.84.0` with appropriate labels

## MODIFIED Requirements

### Requirement: Latest upstream only

For packages that are not `GoVendorAndAssets`, the `update` command SHALL upgrade to the latest version obtained from the package’s configured update source. For `GoVendorAndAssets` packages, target versions SHALL be those produced by the Go tree-lane planner (per-lane maxima under Gentoo `dev-lang/go` ceilings), which MAY be older than upstream latest when latest’s `go.mod` exceeds a ceiling. The `update` command SHALL NOT accept a user-specified target version in this change.

#### Scenario: Bumps to fetched remote version for non-Go

- **WHEN** local PV is older than the fetched remote PV for a `GitMvAndManifest` package
- **THEN** the applied ebuild version is that remote PV

#### Scenario: Go package may stop below latest

- **WHEN** upstream latest requires a Go newer than every Gentoo `dev-lang/go` ceiling and an older tag fits a ceiling
- **THEN** `update` targets that older tag for the corresponding lane rather than hard-requiring latest

### Requirement: Update stdout for successful bumps

For each non-Go package successfully updated and committed, the program SHALL write exactly one line to standard output of the form `category/package vLOCAL -> vREMOTE`, using the same version pretty-rendering conventions as `outdated`. For `GoVendorAndAssets` packages, stdout SHALL follow the Go tree-lane update stdout requirement (possibly multiple labeled lines). Packages that are soft-skipped or hard-failed SHALL NOT produce a success stdout line.

#### Scenario: Successful update line

- **WHEN** `dev-util/opencode-bin` is updated from local PV `1.17.19` to remote `1.17.20` and the signed commit succeeds
- **THEN** stdout contains the line `dev-util/opencode-bin v1.17.19 -> v1.17.20`

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
