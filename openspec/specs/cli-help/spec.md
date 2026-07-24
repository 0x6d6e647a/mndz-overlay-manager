# cli-help Specification

## Purpose

Define how the CLI exposes usage/help text via `--help` / `-h` (top-level and per-command), including bare-invocation behaviour. Help is flag-only; there is no `help` subcommand.

## Requirements

### Requirement: Help flag renders usage text

The CLI SHALL render its top-level usage/help text when invoked with the `--help` flag (or its `-h` short form), writing to standard output and exiting with status `0`. Top-level help SHALL present a brief catalog: global options and one-line descriptions of available work commands. Detailed argument and behaviour text for a single command SHALL appear on that command’s `--help`, not as a wall of detail at top level.

#### Scenario: User requests help via flag

- **WHEN** the user runs the program with `--help`
- **THEN** the program writes the top-level usage text to standard output
- **AND** the program exits with status `0`

#### Scenario: User requests help via short flag

- **WHEN** the user runs the program with `-h`
- **THEN** the program writes the top-level usage text to standard output
- **AND** the program exits with status `0`

### Requirement: Bare invocation shows top-level help and fails

When the program is invoked with no subcommand (empty command position after global options), the program SHALL write the same top-level usage/help text that `--help` produces to standard output (or the library’s equivalent full top-level help rendering) and SHALL exit with status `1`. Explicit top-level `--help` / `-h` remain the success path (exit `0`).

#### Scenario: Bare program prints full top-level help

- **WHEN** the user runs the program with no subcommand
- **THEN** the program writes top-level usage text that includes available commands and global options
- **AND** the program exits with status `1`

#### Scenario: Explicit help still succeeds

- **WHEN** the user runs the program with `--help`
- **THEN** the program writes top-level usage text
- **AND** the program exits with status `0`

### Requirement: Update help acknowledges cargo operator tools when documented

When operator-facing documentation or command-scoped update help lists conditional language/runtime tools for `DepsAndAssets`, it SHALL include `pycargoebuild` (and a crates.io fetcher such as `wget` or `aria2c`) among tools that may be required for cargo packages, consistent with README accuracy requirements in `project-docs`.

#### Scenario: README or update help names pycargoebuild

- **WHEN** an operator reads the documented runtime tools for `update`
- **THEN** `pycargoebuild` is named as a conditional requirement for cargo `DepsAndAssets` packages

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

### Requirement: Program name in help is mndz-overlay-manager

User-facing top-level help header and program description text SHALL use the name `mndz-overlay-manager` and SHALL NOT use the abbreviated form `mndz-overlay-mgr`.

#### Scenario: Top-level help uses canonical name

- **WHEN** the user runs the program with `--help`
- **THEN** the help text includes `mndz-overlay-manager`
- **AND** the help text does not present the program as `mndz-overlay-mgr`

### Requirement: Help does not list a help subcommand

Top-level usage/help text SHALL list the work subcommands `list`, `outdated`, `update`, and `gencache` and SHALL NOT list a `help` subcommand.

#### Scenario: Available commands omit help

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `list`, `outdated`, `update`, and `gencache`
- **AND** the usage text does not list `help` as an available command

### Requirement: Help enumerates gencache subcommand

The top-level usage/help text SHALL list the `gencache` subcommand among available commands so users can discover md5-cache generation alongside `list`, `outdated`, and `update`.

#### Scenario: Help mentions gencache

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes the `gencache` subcommand

### Requirement: Help enumerates outdated subcommand

The top-level usage/help text SHALL list the `outdated` subcommand among available commands so users can discover update checking alongside `list` and `update`.

#### Scenario: Help mentions outdated

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes the `outdated` subcommand

### Requirement: Help enumerates update subcommand

The top-level usage/help text SHALL list the `update` subcommand among available commands so users can discover package upgrading alongside `list` and `outdated`.

#### Scenario: Help mentions update

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes the `update` subcommand

### Requirement: Help documents progress and color flags

The top-level usage/help text SHALL document the global options `--no-progress` and `--no-color`.

#### Scenario: Help mentions no-progress

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `--no-progress`

#### Scenario: Help mentions no-color

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `--no-color`

### Requirement: Help documents jobs flag

The top-level usage/help text SHALL document the global option `--jobs` including that it limits concurrent package work and that the default is the host processor count.

#### Scenario: Help mentions jobs

- **WHEN** the user runs the program with `--help`
- **THEN** the usage text includes `--jobs`
