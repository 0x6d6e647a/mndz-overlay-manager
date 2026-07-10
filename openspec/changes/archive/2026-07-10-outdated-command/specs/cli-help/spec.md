## ADDED Requirements

### Requirement: Help enumerates outdated subcommand

The top-level usage/help text SHALL list the `outdated` subcommand among available commands so users can discover update checking alongside `list` and `help`.

#### Scenario: Help mentions outdated

- **WHEN** the user runs the program with `--help` or the `help` subcommand
- **THEN** the usage text includes the `outdated` subcommand
