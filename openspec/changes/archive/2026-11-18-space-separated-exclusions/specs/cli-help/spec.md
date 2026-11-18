## MODIFIED Requirements

### Requirement: Selecting-command help documents exclude

Command-scoped help for `outdated`, `update`, `gencache`, and `smoke` SHALL document `--exclude` as a repeatable whitespace-separated list of package tokens in the same form as `PACKAGE`, and explain that a list containing spaces must be quoted as one shell argument. The help SHALL state that those tokens are removed from the positional selection, or from the whole inventory when no positionals are given, and that an empty selection is an error. That help SHALL exit with status `0` without loading configuration.

#### Scenario: Outdated help names exclude

- **WHEN** the user runs `outdated --help`
- **THEN** the usage text documents `--exclude` as a whitespace-separated, repeatable package list and explains quoting
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Update help names exclude

- **WHEN** the user runs `update --help`
- **THEN** the usage text documents `--exclude`
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Gencache help names exclude

- **WHEN** the user runs `gencache --help`
- **THEN** the usage text documents `--exclude` and still documents `--force`
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Smoke help names exclude

- **WHEN** the user runs `smoke --help`
- **THEN** the usage text documents `--exclude` as a whitespace-separated, repeatable package list and explains quoting
- **AND** the program exits with status `0` without loading configuration
