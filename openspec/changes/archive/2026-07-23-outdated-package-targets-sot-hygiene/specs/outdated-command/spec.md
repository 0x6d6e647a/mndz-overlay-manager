## RENAMED Requirements

- FROM: `### Requirement: Outdated has no subcommand-specific options`
- TO: `### Requirement: Outdated package targets`

## MODIFIED Requirements

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
