## ADDED Requirements

### Requirement: Help documents progress and color flags

The top-level usage/help text SHALL document the global options `--no-progress` and `--no-color`.

#### Scenario: Help mentions no-progress

- **WHEN** the user runs the program with `--help` or the `help` subcommand
- **THEN** the usage text includes `--no-progress`

#### Scenario: Help mentions no-color

- **WHEN** the user runs the program with `--help` or the `help` subcommand
- **THEN** the usage text includes `--no-color`

### Requirement: Help documents jobs flag

The top-level usage/help text SHALL document the global option `--jobs` including that it limits concurrent package work and that the default is the host processor count.

#### Scenario: Help mentions jobs

- **WHEN** the user runs the program with `--help` or the `help` subcommand
- **THEN** the usage text includes `--jobs`
