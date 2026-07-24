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

#### Scenario: Command help points at global options

- **WHEN** the user runs any of `list --help`, `outdated --help`, `update --help`, or `gencache --help`
- **THEN** the help text indicates that global options go before the subcommand
- **AND** the help text directs the user to top-level `--help` for global options
