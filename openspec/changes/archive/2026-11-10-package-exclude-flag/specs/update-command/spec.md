# Spec Delta

## MODIFIED Requirements

### Requirement: Update package targets

The `update` subcommand SHALL accept zero or more package targets and the subcommand-local `--exclude` flag specified by `package-exclude`. The packages considered for planning and mutation SHALL be that selection. With zero positional targets, the base is every discovered package; among the packages that remain, the program SHALL consider non-`DepsAndAssets` packages that are outdated relative to their configured update source, and `DepsAndAssets` packages that have any runtime-lane gap. With one or more positional targets, each target SHALL be either a full key `category/package` or a package name `package` that is unambiguous among discovered packages. An ambiguous bare package name SHALL be a hard failure for that token. Explicit targets that remain selected and do not need work under their applicable rules SHALL be soft-skipped with a warning or informational message. An excluded package SHALL NOT be planned or mutated.

#### Scenario: Zero targets includes deps-lane gaps

- **WHEN** the user runs `update` with no arguments and a `DepsAndAssets` package has a lane gap while at latest single remote for GitMv purposes
- **THEN** that package is still considered for update work

#### Scenario: Exclude drops a package before planning

- **WHEN** the user runs `update --exclude dev-util/codex` and that package would otherwise need work
- **THEN** the program does not plan or mutate `dev-util/codex`
- **AND** other discovered packages that need work are still considered

#### Scenario: Excluded provider is not pulled back

- **WHEN** the user runs `update --exclude dev-lang/bun-bin` and a selected DepsAndAssets Bun consumer remains
- **THEN** the program does not add `dev-lang/bun-bin` to the selection
- **AND** it does not mutate `dev-lang/bun-bin`

### Requirement: Go tree-lane update selection

For packages with technique `DepsAndAssets`, `update` SHALL use the runtime-lane planner for that ecosystem to determine target PVs and whether the package needs work. With zero package arguments, `update` SHALL include a deps package that remains after `--exclude` when any lane has a gap (missing target PV ebuild, content or Manifest fix needed—including BDEPEND not matching the PV’s known requirement—or exact-set prune required), not only when newest local is less than upstream latest. A package removed by `--exclude` SHALL NOT be included. Explicit targets that are fully satisfied under the plan (including Manifest distfile DIST completeness and BDEPEND match when the requirement is known) SHALL be soft-skipped.

#### Scenario: Plan-satisfied soft skip

- **WHEN** every planned PV is present with adequate content and Manifest dist entries
- **THEN** the package may soft-skip as already matching the plan

#### Scenario: Excluded deps package is not planned

- **WHEN** the user runs `update --exclude dev-util/codex` and that DepsAndAssets package has a runtime-lane gap
- **THEN** the program does not plan `dev-util/codex`
