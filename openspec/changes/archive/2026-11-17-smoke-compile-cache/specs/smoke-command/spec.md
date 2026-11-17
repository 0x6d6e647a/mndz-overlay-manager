# Spec Delta

## MODIFIED Requirements

### Requirement: Smoke package targets

`smoke` SHALL accept zero or more package targets and no subcommand-local flag other than those in "Smoke subcommand-local flags". Each target SHALL be `category/package` or an unambiguous bare package name, resolved with the rules shared with `outdated`. With zero targets the base SHALL be every discovered package. Unknown and ambiguous tokens SHALL hard-fail with exit status `1` before any smoke work. Version or PV values SHALL NOT be accepted as arguments.

#### Scenario: Zero targets selects the whole inventory

- **WHEN** the operator runs `smoke` with no package arguments
- **THEN** every discovered package is selected

#### Scenario: Bare package name

- **WHEN** the operator runs `smoke crush` and exactly one discovered package is named `crush`
- **THEN** only `dev-util/crush` is selected

#### Scenario: Unknown package hard-fails

- **WHEN** the operator runs `smoke missing/pkg`
- **THEN** the program logs an error and exits with status `1` before any container is created

#### Scenario: Refresh is rejected

- **WHEN** the operator runs `smoke --refresh`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

#### Scenario: Version atom is not a target

- **WHEN** the operator runs `smoke =dev-lang/bun-bin-1.4.4`
- **THEN** the program hard-fails as for an unknown package

#### Scenario: Reset with an unknown package

- **WHEN** the operator runs `smoke --reset-compile-cache missing/pkg`
- **THEN** the program exits with status `1` before any compile cache is deleted

## ADDED Requirements

### Requirement: Smoke subcommand-local flags

`smoke` SHALL accept the subcommand-local flags `--exclude` (see `package-exclude`), `--no-compile-cache`, and `--reset-compile-cache` (see `smoke-compile-cache`).

#### Scenario: Compile cache flags with a target

- **WHEN** the operator runs `smoke --no-compile-cache --reset-compile-cache crush`
- **THEN** option parsing succeeds and only `dev-util/crush` is selected
