# Spec Delta

## MODIFIED Requirements

### Requirement: Exclude flag is subcommand-local

`outdated`, `update`, `gencache`, and `smoke` SHALL each accept a repeatable long option `--exclude`. `list`, `eclean`, and `github-token` SHALL reject `--exclude`. The program SHALL NOT read exclusions from its configuration file, and SHALL NOT accept a short form of this option.

#### Scenario: Outdated accepts the long option

- **WHEN** the user runs `outdated --exclude dev-util/codex`
- **THEN** the program accepts `--exclude` as a subcommand option of `outdated`

#### Scenario: Repeated flags are one option

- **WHEN** the user runs `update --exclude dev-util/codex --exclude dev-util/crush`
- **THEN** the program accepts both `--exclude` options on `update`

#### Scenario: Smoke accepts the long option

- **WHEN** the user runs `smoke --exclude dev-util/codex`
- **THEN** the program accepts `--exclude` as a subcommand option of `smoke`
- **AND** `dev-util/codex` is not tested

#### Scenario: List rejects the option

- **WHEN** the user runs `list --exclude dev-util/codex`
- **THEN** option parsing fails with exit status `1` before configuration is loaded

#### Scenario: Flag before the subcommand is rejected

- **WHEN** the user runs `--exclude dev-util/codex outdated`
- **THEN** option parsing fails with exit status `1` before configuration is loaded
