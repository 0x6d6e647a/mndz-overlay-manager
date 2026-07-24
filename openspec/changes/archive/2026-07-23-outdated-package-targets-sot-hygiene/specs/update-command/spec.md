## RENAMED Requirements

- FROM: `### Requirement: Latest upstream only`
- TO: `### Requirement: Automatic version selection without PV arguments`

- FROM: `### Requirement: Soft skip no longer treats Go packages as unsupported`
- TO: `### Requirement: Soft skip does not treat DepsAndAssets as unsupported`

## MODIFIED Requirements

### Requirement: Automatic version selection without PV arguments

Package selection for `update` SHALL use only package targets (`category/package`, unambiguous bare package name, or empty for all that need work) as specified by the package-targets requirement. The `update` command SHALL NOT accept a user-specified target version or PV as a CLI argument. For packages that are not `DepsAndAssets`, when an update applies, the program SHALL upgrade to the latest version obtained from the package’s configured update source. For `DepsAndAssets` packages, target versions SHALL be those produced by the runtime-lane planner (per-lane maxima under runtime ceilings), which MAY be older than upstream latest when latest’s requirement exceeds a ceiling.

#### Scenario: Lane may select older than latest

- **WHEN** upstream latest requires a runtime newer than the plain ceiling but an older candidate fits
- **THEN** update may target the older candidate for that lane

#### Scenario: No PV CLI argument

- **WHEN** the user runs `update` with package tokens only (or no tokens)
- **THEN** the program does not interpret any token as a target PV or version pin

### Requirement: Soft skip does not treat DepsAndAssets as unsupported

Packages configured with `DepsAndAssets` (Go, Npm, Bun, or Cargo) SHALL NOT be soft-skipped with an “unsupported” reason for vendor, deps, or crates assets. Soft skips for those packages remain available for not-outdated / already-fixed cases as defined by apply logic.

#### Scenario: openspec not unsupported

- **WHEN** the user runs `update dev-util/openspec` and the package needs a version bump with deps assets
- **THEN** the program does not soft-skip it solely because deps assets are required

#### Scenario: mise not unsupported

- **WHEN** the user runs `update dev-util/mise` and the package needs crates assets work
- **THEN** the program does not soft-skip it solely because crates assets are required
