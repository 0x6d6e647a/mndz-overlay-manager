## MODIFIED Requirements

### Requirement: Per-command help is detailed and flag-only

Each work subcommand (`list`, `outdated`, `update`, `gencache`) SHALL support `--help` and `-h` that render command-scoped usage (that command’s arguments and local options when any exist), a brief description of the command’s behaviour, and a note that global options are supplied before the subcommand and are documented by top-level `--help`. Per-command help SHALL NOT be provided via a positional `help` subcommand.

#### Scenario: Update help documents package targets

- **WHEN** the user runs `update --help`
- **THEN** the usage text describes optional `PACKAGE...` targets (`category/package` or unambiguous package name)
- **AND** the usage text states that omitting targets updates packages that need work
- **AND** the program exits with status `0` without loading configuration

#### Scenario: List help is command-scoped

- **WHEN** the user runs `list --help`
- **THEN** the usage text describes the `list` command
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Outdated help is command-scoped

- **WHEN** the user runs `outdated --help`
- **THEN** the usage text describes the `outdated` command
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Gencache help is command-scoped

- **WHEN** the user runs `gencache --help`
- **THEN** the usage text describes optional `PACKAGE...` targets and the `--force` option
- **AND** the usage text states that omitting targets regenerates cache for all packages
- **AND** the program exits with status `0` without loading configuration

#### Scenario: Command help points at global options

- **WHEN** the user runs any of `list --help`, `outdated --help`, `update --help`, or `gencache --help`
- **THEN** the help text indicates that global options go before the subcommand
- **AND** the help text directs the user to top-level `--help` for global options

### Requirement: Help does not list a help subcommand

Top-level usage/help text SHALL list the work subcommands `list`, `outdated`, `update`, and `gencache` and SHALL NOT list a `help` subcommand.

#### Scenario: Available commands omit help

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `list`, `outdated`, `update`, and `gencache`
- **AND** the usage text does not list `help` as an available command

## ADDED Requirements

### Requirement: Help enumerates gencache subcommand

The top-level usage/help text SHALL list the `gencache` subcommand among available commands so users can discover md5-cache generation alongside `list`, `outdated`, and `update`.

#### Scenario: Help mentions gencache

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes the `gencache` subcommand
