## MODIFIED Requirements

### Requirement: Update preflight requires git ebuild and gpg

The `update` command SHALL verify that `git`, `ebuild`, `egencache`, and `gpg` are available on `PATH` before package mutation (existing spine tools).

When at least one selected package will attempt a `DepsAndAssets` apply (including same-PV content/revision fixes), `update` SHALL additionally verify that `xz` is available on `PATH`, that `assets-path` is configured and names a git work tree, and that a GitHub token can be resolved. When any such package will use the **full** materialize path for ecosystem `Go`, `go` SHALL be on `PATH`. When any will use the full path for ecosystem `Npm`, `npm` SHALL be on `PATH`. When any will use the full path for ecosystem `Bun`, `bun` SHALL be on `PATH`. Missing conditional requirements SHALL log an error and exit with status `1` before package mutation. When no selected package needs `DepsAndAssets`, the program SHALL NOT fail preflight solely because `go`, `npm`, `bun`, `xz`, assets path, or token are missing. Packages that only need the reuse path SHALL NOT require the language tool (`go`/`npm`/`bun`) solely for that reuse work.

#### Scenario: Go tools required only when Go technique selected

- **WHEN** the user runs `update dev-util/crush` and crush will attempt full-path `DepsAndAssets` Go work
- **THEN** preflight requires `go` and `xz` on `PATH`

#### Scenario: npm required for openspec full path

- **WHEN** the user runs `update dev-util/openspec` and openspec will attempt full-path npm cache construction
- **THEN** preflight requires `npm` and `xz` on `PATH`

#### Scenario: bun required for ralph-tui full path

- **WHEN** the user runs `update dev-util/ralph-tui` and ralph-tui will attempt full-path bun cache construction
- **THEN** preflight requires `bun` and `xz` on `PATH`

#### Scenario: Binary package skips language tools

- **WHEN** the user runs `update dev-util/opencode-bin` and no `DepsAndAssets` package is selected
- **THEN** preflight does not fail solely because `go`, `npm`, or `bun` is missing from `PATH`

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

### Requirement: Soft skip no longer treats Go packages as unsupported

Packages configured with `DepsAndAssets` (Go, Npm, or Bun) SHALL NOT be soft-skipped with an “unsupported” reason for vendor or deps assets. Soft skips for those packages remain available for not-outdated / already-fixed cases as defined by apply logic.

#### Scenario: openspec not unsupported

- **WHEN** the user runs `update dev-util/openspec` and the package needs a version bump with deps assets
- **THEN** the program does not soft-skip it solely because deps assets are required

### Requirement: Latest upstream only

For packages that are not `DepsAndAssets`, the `update` command SHALL upgrade to the latest version obtained from the package’s configured update source. For `DepsAndAssets` packages, target versions SHALL be those produced by the runtime-lane planner (per-lane maxima under runtime ceilings), which MAY be older than upstream latest when latest’s requirement exceeds a ceiling. The `update` command SHALL NOT accept a user-specified target version in this change.

#### Scenario: Lane may select older than latest

- **WHEN** upstream latest requires a runtime newer than the plain ceiling but an older candidate fits
- **THEN** update may target the older candidate for that lane
