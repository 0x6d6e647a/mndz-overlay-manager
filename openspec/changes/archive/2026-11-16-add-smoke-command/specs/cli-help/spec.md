# Spec Delta

## ADDED Requirements

### Requirement: Help enumerates smoke subcommand

The top-level usage/help text SHALL list the `smoke` subcommand among available commands, with a one-line description saying it installs and checks overlay packages in a clean container.

#### Scenario: Help mentions smoke

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes the `smoke` subcommand

### Requirement: Smoke help describes what a run does

`smoke --help` SHALL state that every on-disk version of each selected package is installed in a fresh Docker container and checked, that runs happen one at a time, that `--jobs` sets the build parallelism inside the container, and that the command needs Docker with the containerd image store. It SHALL NOT document `--refresh`.

#### Scenario: Smoke help content

- **WHEN** the user runs `smoke --help`
- **THEN** the usage text describes optional `PACKAGE...` targets and states that omitting targets tests all discovered packages
- **AND** the text mentions `--jobs` as build parallelism
- **AND** the text does not mention `--refresh`
- **AND** the program exits with status `0` without loading configuration

## MODIFIED Requirements

### Requirement: Per-command help is detailed and flag-only

Each work subcommand (`list`, `outdated`, `update`, `gencache`, `smoke`, `eclean`, `github-token`) SHALL support `--help` and `-h` that render command-scoped usage (that command’s arguments and local options when any exist), a brief description of the command’s behaviour, and a note that global options are supplied before the subcommand and are documented by top-level `--help`. Per-command help SHALL NOT be provided via a positional `help` subcommand.

#### Scenario: Update help documents package targets

- **WHEN** the user runs `update --help`
- **THEN** the usage text describes optional `PACKAGE...` targets (`category/package` or unambiguous package name)
- **AND** the usage text states that omitting targets updates packages that need work
- **AND** the program exits with status `0` without loading configuration

#### Scenario: List help is command-scoped

- **WHEN** the user runs `list --help`
- **THEN** the usage text describes the `list` command
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Outdated help documents package targets

- **WHEN** the user runs `outdated --help`
- **THEN** the usage text describes optional `PACKAGE...` targets (`category/package` or unambiguous package name)
- **AND** the usage text states that omitting targets checks all discovered packages
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Gencache help is command-scoped

- **WHEN** the user runs `gencache --help`
- **THEN** the usage text describes optional `PACKAGE...` targets and the `--force` option
- **AND** the usage text states that omitting targets regenerates cache for all packages
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Smoke help is command-scoped

- **WHEN** the user runs `smoke --help`
- **THEN** the usage text describes optional `PACKAGE...` targets (`category/package` or unambiguous package name)
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Command help points at global options

- **WHEN** the user runs any of `list --help`, `outdated --help`, `update --help`, `gencache --help`, `smoke --help`, `eclean --help`, or `github-token --help`
- **THEN** the help text indicates that global options go before the subcommand
- **AND** the help text directs the user to top-level `--help` for global options

### Requirement: Selecting-command help documents exclude

Command-scoped help for `outdated`, `update`, `gencache`, and `smoke` SHALL document `--exclude` as a repeatable comma-separated list of package tokens in the same form as `PACKAGE`. The help SHALL state that those tokens are removed from the positional selection, or from the whole inventory when no positionals are given, and that an empty selection is an error. That help SHALL exit with status `0` without loading configuration.

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

#### Scenario: Smoke help names exclude

- **WHEN** the user runs `smoke --help`
- **THEN** the usage text documents `--exclude` as a comma-separated, repeatable package list
- **AND** the program exits with status `0` without loading configuration
