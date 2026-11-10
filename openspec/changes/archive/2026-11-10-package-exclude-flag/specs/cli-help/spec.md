# Spec Delta

## ADDED Requirements

### Requirement: Selecting-command help documents exclude

Command-scoped help for `outdated`, `update`, and `gencache` SHALL document `--exclude` as a repeatable comma-separated list of package tokens in the same form as `PACKAGE`. The help SHALL state that those tokens are removed from the positional selection, or from the whole inventory when no positionals are given, and that an empty selection is an error. That help SHALL exit with status `0` without loading configuration.

#### Scenario: Outdated help names exclude

- **WHEN** the user runs `outdated --help`
- **THEN** the usage text documents `--exclude` as a comma-separated, repeatable package list
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Update help names exclude

- **WHEN** the user runs `update --help`
- **THEN** the usage text documents `--exclude`
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Gencache help names exclude

- **WHEN** the user runs `gencache --help`
- **THEN** the usage text documents `--exclude` and still documents `--force`
- **AND** the program exits with status `0` without loading configuration

### Requirement: Exclude is not documented as a global

Top-level help SHALL NOT document `--exclude` as a global option. Help for `list`, `eclean`, and `github-token` SHALL NOT document `--exclude` as an option of those commands.

#### Scenario: Top-level help keeps exclude off the globals

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text does not document `--exclude` as a global option

#### Scenario: List help omits exclude

- **WHEN** the user runs `list --help`
- **THEN** the usage text does not document `--exclude` as a `list` option
